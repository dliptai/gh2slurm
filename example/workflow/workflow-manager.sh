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
  # Report error to GitHub issue and mark it as failed
  echo "ERROR: script failed." >&2
  gh issue comment "$ISSUE_NUMBER" --body "Workflow $SLURM_JOB_ID failed" >&2
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

# param1: free text. Nothing downstream currently treats it as a path or
# a command, so no character-level restriction — just a sanity length cap.
param1="$(jq -r '.param1' <<< "$payload")"
if (( ${#param1} > 256 )); then
  echo "ERROR: 'param1' exceeds 256 characters (${#param1})" >&2
  return 1
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
JOB1="$(sbatch --parsable --partition="$partition_compute" \
        build.sh)"

# Submit a second job to run the benchmarks, which depends on the first job's success
JOB2="$(sbatch --parsable --partition="$partition_compute" \
        --dependency="afterok:$JOB1" \
        benchmark.sh)"

# Submit the final job, which runs regardless of success or failure
JOB3="$(sbatch --parsable --partition="$partition_internet" \
        --dependency="afterok:$JOB2" \
        --export="${GH_EXPORT_LIST}" \
        results.sh "$ISSUE_NUMBER")"


#--------------------------------------------
# Report the job IDs to the GitHub issue
#--------------------------------------------
gh issue comment "$ISSUE_NUMBER" --body "$(cat <<EOF
Workflow:
\`\`\`
$(sacct -j "$JOB1,$JOB2,$JOB3" -X --format=JobName,JobID)
\`\`\`
EOF
)"


#--------------------------------------------
# Submit a final report on all jobs submitted
#--------------------------------------------

sbatch --dependency="afterany:$JOB1:$JOB2:$JOB3" \
      --export="${GH_EXPORT_LIST},ISSUE_NUMBER" \
      --partition="$partition_internet" \
      --job-name=Report \
      --ntasks=1 \
      --cpus-per-task=1 \
      --time=00:01:00 \
      --output="report-%j.out" \
<< 'EOF' || gh issue comment "$ISSUE_NUMBER" --body "workflow "  # Post if this fails to submit
#!/bin/bash
set -euo pipefail

gh_setup

# Get parent jobs. Remove the prefix 'afterany:' or 'afterok:'
RAW_IDS="${SLURM_JOB_DEPENDENCY#*:}"

# Replace colons with commas so sacct can read them all at once
PARENT_IDS="${RAW_IDS//:/,}"

# Query the state of parent jobs
STATES="$(sacct -j "$PARENT_IDS" -X --format=JobName,JobID,State,ExitCode || echo '[no parent jobs found]')"

# Check if any parent jobs not in "COMPLETED" state
if sacct -j "$PARENT_IDS" -X --format=State --noheader --parsable2 | grep -qv '^COMPLETED$'; then
  STATE=FAILED
  JOBSTR="Some jobs FAILED"
else
  STATE=COMPLETED
  JOBSTR="All jobs COMPLETED"
fi

# Construct the header
BODY="$(cat << BODY_EOF
$JOBSTR

\`\`\`
$STATES
\`\`\`
BODY_EOF
)"

# Print to logfile
echo "$BODY"

# Report and un-claim
gh issue comment "$ISSUE_NUMBER" --body "$BODY"
gh issue edit "$ISSUE_NUMBER" --remove-label "running"

# Close or mark as failed
if [[ "$STATE" == "FAILED" ]]; then
  gh issue edit "$ISSUE_NUMBER" --add-label "failed"
  exit 1
else
  gh issue close "$ISSUE_NUMBER" 2>&1 | sed 's/✓ //g'
fi

EOF
