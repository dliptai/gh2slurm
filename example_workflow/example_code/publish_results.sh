#!/bin/bash
#SBATCH --job-name=publish
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=00:01:00
#SBATCH --output="publish-%j.out"
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
# Take the issue as input
#-------------------------------------------------------------
ISSUE="${1:?Usage: ${BASH_SOURCE[0]} <issue>}"
ISSUE_NUMBER="$(echo "$ISSUE" | jq -r '.number')"

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

#-------------------------------------------------------------
# Get parent jobs
#-------------------------------------------------------------
# Remove the prefix 'afterany:' or 'afterok:'
RAW_IDS="${SLURM_JOB_DEPENDENCY#*:}"

# Replace colons with commas so sacct can read them all at once
PARENT_IDS="${RAW_IDS//:/,}"

#-------------------------------------------------------------
# Collect and publish the results
#-------------------------------------------------------------
get_gh_token "$GH_APP_ID" "$GH_APP_INSTALL_ID" "$GH_APP_KEY"

# Query all parents simultaneously
echo "Checking parents: $PARENT_IDS"
results_table="$(sacct -j "$PARENT_IDS" -X --format=JobName,JobID,State,ExitCode)"
echo "$results_table"

if sacct -j "$PARENT_IDS" -X --format=State --noheader --parsable2 | grep -qv '^COMPLETED$'; then
  echo "ERROR: Some jobs are not 'COMPLETED'"

  body="$(cat << EOF
Some jobs failed. Please check the Slurm job logs for details.
\`\`\`
$results_table
\`\`\`
EOF
)"

  gh issue comment "$ISSUE_NUMBER" --body "$body"
  gh issue edit "$ISSUE_NUMBER" --remove-label "running" --add-label "failed"
  exit 1

else

  # Collect job timing
  timing="$(grep 'Execution time' timings.txt || echo "No timing information found")"

  body="$(cat << EOF
All jobs completed successfully.
\`\`\`
$results_table
\`\`\`

Timing:
\`\`\`
$timing
\`\`\`

EOF
)"

  gh issue edit "$ISSUE_NUMBER" --remove-label "running"
  gh issue close "$ISSUE_NUMBER" --comment "$body" 2>&1 | sed 's/✓ //g'
  exit 0
fi
