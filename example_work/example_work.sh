#!/bin/bash
#SBATCH --job-name=example_work
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=00:01:00
set -euo pipefail

#-------------------------------------------------------------
# Add CLI tools to PATH
#-------------------------------------------------------------
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PATH="$SCRIPT_DIR/../bin:$PATH"

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
# This is an example of some "work" that could be triggered.
#-----------------------------------------------------------------------------

ISSUE="${1:?Usage: ${BASH_SOURCE[0]} <issue>}"  # Take issue as input
ISSUE_NUMBER="$(echo "$ISSUE" | jq -r '.number')"

#-------------------------------------------------------------
# Example "job", run in a sub-shell. This can submit a chain of
# dependent jobs to the queue, and then return a status code.
#-------------------------------------------------------------
set +e   # Ensure that a failure of the sub-shell doesn't kill the script
(
  set -euo pipefail # Fail fast
  # Get the commit hash we want to work with from the issue body.
  commit_hash="$(echo "$ISSUE" | jq -r '.body' | jq -r '.commit')"
  cat << EOF
#--------------------
# An example job:
#--------------------

# Clone the repo at the specified commit hash
cd /path/to/some/work/dir
git clone --revision=$commit_hash --depth 1 <repository-url>

# Run benchmarks on the code at that commit hash.
# Separate the build and run steps into separate jobs.
# (This is just an example, replace with actual commands)

# Submit build job
JOB1=\$(sbatch --parsable build_code.sh)

# Submit a second job to run the benchmarks, which depends on the first job's success
JOB2=\$(sbatch --parsable --dependency=afterok:\$JOB1 benchmark_code.sh)

# Submit the final job, which runs regardless of success or failure
sbatch --partition="<part_with_internet_access>" --dependency=afterany:\$JOB1:\$JOB2 post_results.sh

EOF
exit 0
)
ecode=$? # Catch the return code of the sub-shell
set -e # Turn fail fast back on

#-------------------------------------------------------------
# Publish the results
#-------------------------------------------------------------
get_gh_token "$GH_APP_ID" "$GH_APP_INSTALL_ID" "$GH_APP_KEY"
if [ $ecode -ne 0 ]; then
  echo "ERROR: sub-shell failed."
  gh issue comment "$ISSUE_NUMBER" --body "Slurm job $SLURM_JOB_ID failed"
  gh issue edit "$ISSUE_NUMBER" --add-label "failed"
  exit 1
else
  results="$(cat << EOF
Slurm job $SLURM_JOB_ID suceeded.
Some other info, if you want.
EOF
)"
  gh issue close "$ISSUE_NUMBER" --comment "$results" 2>&1 | sed 's/✓ //g'
  exit 0
fi
