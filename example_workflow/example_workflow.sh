#!/bin/bash
#SBATCH --job-name=workflow
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=00:01:00
#SBATCH --output="workflow-%j.out"
set -euo pipefail

#------------------------------------------------------------------------------
# Example "workflow".
# This can submit a chain of dependent jobs to the queue, and then return a status code.
# e.g.
# - Download the code at the commit hash specified in the issue body.
# - Run benchmarks on the code at that commit hash.
# - Separate the build and run steps into separate jobs.
#------------------------------------------------------------------------------

# Run GitHub setup
gh_setup

# Take issue as input
ISSUE="${1:?Usage: ${BASH_SOURCE[0]} <issue>}"
ISSUE_NUMBER="$(echo "$ISSUE" | jq -r '.number')"

# Note if anything above fails, GitHub won't/can't be notified.

# Partitions to use for the jobs.
partition_compute="$SLURM_JOB_PARTITION"     # Replace with a partition that has compute nodes
partition_internet="$SLURM_JOB_PARTITION"    # Replace with a partition that has internet access

handle_error() {
  # Publish error message to GitHub issue and mark it as failed
  echo "ERROR: script failed." >&2
  gh issue comment "$ISSUE_NUMBER" --body "Slurm job $SLURM_JOB_ID failed" >&2
  gh issue edit "$ISSUE_NUMBER" --remove-label "running" --add-label "failed" >&2
  exit 1
}

# Trap any subsequent errors in the script.
trap handle_error ERR

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

# Publish the job IDs to the GitHub issue
jobstr="$(cat <<EOF
Submitted workflow:
$(sacct -j "$JOB1,$JOB2,$JOB3" -X --format=JobName,JobID)
EOF
)"
gh issue comment "$ISSUE_NUMBER" --body "$jobstr"
