#!/bin/bash
#SBATCH --job-name=workflow-manager
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=00:01:00
#SBATCH --output="workflow-manager-%j.out"
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
  gh issue comment "$ISSUE_NUMBER" --body "\`$SLURM_JOB_ID failed\`" >&2
  gh issue edit "$ISSUE_NUMBER" --remove-label "running" --add-label "failed" >&2
  exit 1
}

# Trap any subsequent errors in the script.
trap handle_error ERR


#--------------------------------------------
# Validate json paylod
#--------------------------------------------
payload=$(jq -r '.body' <<< "$ISSUE")

commit_hash="$(jq -r '.commit' <<< "$payload")"
if ! [[ "$commit_hash" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
  echo "ERROR: 'commit' must be a 7-40 char hex git SHA, got: $commit_hash" >&2
  exit 1
fi

run_number="$(jq -r '.run_number' <<< "$payload")"
if ! [[ "$run_number" =~ ^[0-9]+$ ]]; then
  echo "ERROR: 'run_number' must be a positive integer, got: $run_number" >&2
  exit 1
fi


#--------------------------------------------
# Code set up
#--------------------------------------------

# Create a job run directory based off the unique run_number, and change into it.
job_run_dir="run${run_number}"
mkdir -vp "$job_run_dir"
cd "$job_run_dir"

# Download the code and benchmarking scripts to a temp file first, so we can
# check it for path-traversal / symlink entries before extracting anywhere.
# This can be replaced by e.g. a git clone command.
# (In our case, the example code happens to live in the same repo)
url="https://github.com/${GH_REPO}/archive/${commit_hash}.tar.gz"
echo "Downloading code from $url"

tmp_archive="$(mktemp)"
trap 'rm -f "$tmp_archive"' RETURN
curl -sSL "$url" -o "$tmp_archive"

if tar tzf "$tmp_archive" | grep -qE '(^|/)\.\.(/|$)|^/'; then
  echo "ERROR: archive contains path-traversal or absolute-path entries, refusing to extract" >&2
  exit 1
fi

tar xzf "$tmp_archive" --strip-components=3 "*/example/codebase"


#--------------------------------------------
# Job submissions
#--------------------------------------------

# Submit build job
JOB1="$(sbatch --parsable --partition="$partition_compute" build.sh)"

# Submit a second job to run the benchmarks, which depends on the first job's success
JOB2="$(sbatch --parsable --partition="$partition_compute" --dependency="afterok:$JOB1" benchmark.sh)"

# Submit the final job, which runs regardless of success or failure
JOB3="$(sbatch --parsable \
              --export="${GH_EXPORT_LIST}" \
              --partition="$partition_internet" \
              --dependency="afterany:$JOB1:$JOB2" \
              publish.sh "$ISSUE")"


#--------------------------------------------
# # Publish the job IDs to the GitHub issue
#--------------------------------------------
JOBSTR="$(cat <<EOF
Workflow:
\`\`\`
$(sacct -j "$JOB1,$JOB2,$JOB3" -X --format=JobName,JobID)
\`\`\`
EOF
)"
gh issue comment "$ISSUE_NUMBER" --body "$JOBSTR"
