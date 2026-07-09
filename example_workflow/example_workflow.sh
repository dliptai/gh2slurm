#!/bin/bash
#SBATCH --job-name=workflow
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=00:01:00
#SBATCH --output="workflow-%j.out"
set -euo pipefail

# Run GitHub setup
gh_setup

# Take issue as input
ISSUE="${1:?Usage: ${BASH_SOURCE[0]} <issue>}"
ISSUE_NUMBER="$(echo "$ISSUE" | jq -r '.number')"

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

  # Partitions to use for the jobs.
  partition_compute="$SLURM_JOB_PARTITION"     # Replace with a partition that has compute nodes
  partition_internet="$SLURM_JOB_PARTITION"    # Replace with a partition that has internet access

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
  url="https://github.com/${GH_REPO}/archive/${commit_hash}.tar.gz"
  echo "Downloading code from $url"
  curl -sSL "$url" | tar xz --strip-components=1 "*/example_code"
  cd example_code

  # Run the example workflow, which consists of three jobs:

  # Submit build job
  JOB1="$(sbatch --parsable --partition="$partition_compute" build_code.sh)"

  # Submit a second job to run the benchmarks, which depends on the first job's success
  JOB2="$(sbatch --parsable --partition="$partition_compute" --dependency="afterok:$JOB1" benchmark_code.sh)"

  # Submit the final job, which runs regardless of success or failure
  JOB3="$(sbatch --parsable \
                --export="${GH_EXPORT_LIST}" \
                --partition="$partition_internet" \
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
if [ $ec -ne 0 ]; then
  echo "ERROR: sub-shell failed."
  gh issue comment "$ISSUE_NUMBER" --body "Slurm job $SLURM_JOB_ID failed"
  gh issue edit "$ISSUE_NUMBER" --remove-label "running" --add-label "failed"
  exit 1
fi
