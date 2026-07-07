#!/bin/bash
#SBATCH --job-name=workflow
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=00:01:00
#SBATCH --output="workflow-%j.out"
set -euo pipefail

#-------------------------------------------------------------
# Add CLI tools to PATH
#-------------------------------------------------------------
PATH="$GH_CLI_BIN:$PATH"

#-------------------------------------------------------------
# Check for required commands
#-------------------------------------------------------------
for item in gh gh-token jq; do
  if ! command -v $item >/dev/null 2>&1 ; then
    echo "ERROR: '$item' is required but not in PATH. Aborting." >&2
    exit 1
  fi
done

#-------------------------------------------------------------
# Useful function to generate GitHub App token
#-------------------------------------------------------------
function get_gh_token() {
  local app_id="${1:?Usage: get_gh_token <app-id> <installation-id> <key>}"
  local installation_id="${2:?Usage: get_gh_token <app-id> <installation-id> <key>}"
  local key="${3:?Usage: get_gh_token <app-id> <installation-id> <key>}"
  GH_TOKEN="$(gh-token generate \
    --app-id "$app_id" \
    --installation-id "$installation_id" \
    --key "$key" | jq -r '.token')"
  if [[ -z "$GH_TOKEN" ]]; then
    echo "Failed to generate GitHub token. Aborting." >&2
    exit 1
  else
    export GH_TOKEN
  fi
}

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

#-----------------------------------------------------------------------------
# This is an example of a workflow that could be triggered.
#-----------------------------------------------------------------------------

ISSUE="${1:?Usage: ${BASH_SOURCE[0]} <issue>}"  # Take issue as input
ISSUE_NUMBER="$(echo "$ISSUE" | jq -r '.number')"

#-----------------------------------------------------------------------------
# Partitions to use for the jobs.
# These should be replaced with partitions that have the required resources.
#-----------------------------------------------------------------------------
PARTITION_COMPUTE="$SLURM_JOB_PARTITION"     # Replace with a partition that has compute nodes
PARTITION_INTERNET="$SLURM_JOB_PARTITION"    # Replace with a partition that has internet access

#------------------------------------------------------------------------------
# Example "job", run in a sub-shell. This can submit a chain of
# dependent jobs to the queue, and then return a status code.
# e.g.
# - Download the code at the commit hash specified in the issue body.
# - Run benchmarks on the code at that commit hash.
# - Separate the build and run steps into separate jobs.
#------------------------------------------------------------------------------
set +e   # Ensure that a failure of the sub-shell doesn't kill the script
(
  set -euo pipefail # Fail fast

  # Get the commit hash we want to work with from the issue body.
  commit_hash="$(echo "$ISSUE" | jq -r '.body' | jq -r '.commit')"

  # Use run number as unique ID
  run_number="$(echo "$ISSUE" | jq -r '.body' | jq -r '.run_number')"

  # Name of the cluster we're running on.
  cluster_label="cluster"

  # Set up the job run directory, where the code will be downloaded and run.
  job_run_dir="$PWD/runs/${run_number}_${cluster_label}"
  mkdir -vp "$job_run_dir"
  cd "$job_run_dir"

  # Download the code you want to be working with.
  # This can be replaced by e.g. a git clone command, or a wget/curl command to download a tarball, etc.
  # In our case, the example code lives in the same repo, but we're showing the download as a separate step to illustrate the workflow.
  curl -sSL \
    "https://github.com/${GH_REPO}/archive/${commit_hash}.tar.gz" | \
    tar xz --strip-components=2 "*/example_workflow/example_code"

  # Run the example workflow, which consists of three jobs:
  cd example_code

  # Submit build job
  JOB1="$(sbatch --parsable --partition="$PARTITION_COMPUTE" build_code.sh)"

  # Submit a second job to run the benchmarks, which depends on the first job's success
  JOB2="$(sbatch --parsable --partition="$PARTITION_COMPUTE" --dependency="afterok:$JOB1" benchmark_code.sh)"

  # Submit the final job, which runs regardless of success or failure
  JOB3="$(sbatch --parsable \
                --export=GH_REPO,GH_APP_ID,GH_APP_INSTALL_ID,GH_APP_KEY,GH_CLI_BIN \
                --partition="$PARTITION_INTERNET" \
                --dependency="afterany:$JOB1:$JOB2" \
                publish_results.sh "$ISSUE")"

  echo "Submitted workflow:"
  sacct -j "$JOB1,$JOB2,$JOB3" -X --format=JobName,JobID

)
ec=$?  # Catch the return code of the sub-shell
set -e # Turn fail fast back on

#-------------------------------------------------------------
# Publish the results
#-------------------------------------------------------------
get_gh_token "$GH_APP_ID" "$GH_APP_INSTALL_ID" "$GH_APP_KEY"
if [ $ec -ne 0 ]; then
  echo "ERROR: sub-shell failed."
  gh issue comment "$ISSUE_NUMBER" --body "Slurm job $SLURM_JOB_ID failed"
  gh issue edit "$ISSUE_NUMBER" --remove-label "running" --add-label "failed"
  exit 1
fi
