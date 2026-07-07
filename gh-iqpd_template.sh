#!/bin/bash
#SBATCH --job-name=gh-iqpd
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=00:01:00
#SBATCH --open-mode=append
#SBATCH --output=gh-iqpd.log
set -euo pipefail

#-------------------------------------------------------------
# GitHub Issue Queue Poller Daemon (gh-iqpd) for SLURM
#-------------------------------------------------------------

#-------------------------------------------------------------
# Configuration
#-------------------------------------------------------------
RESUBMIT_FREQ=1week
CLUSTER_LABEL="<<CLUSTER_NAME>>"
QUEUE_LABEL="<<QUEUE_LABEL>>"
export GH_APP_ID="<<GH_APP_ID>>"
export GH_APP_INSTALL_ID="<<GH_APP_INSTALL_ID>>"
export GH_APP_KEY="<</path/to/GH_APP_KEY>>"
export GH_REPO="<<GH_USERNAME/GH_REPONAME>>"

#-------------------------------------------------------------
# Add CLI tools to PATH
#-------------------------------------------------------------
export GH_CLI_BIN="$PWD/bin"
PATH="$GH_CLI_BIN:$PATH"

#-------------------------------------------------------------
# Check for required commands
#-------------------------------------------------------------
for item in gh gh-token jq; do
  if ! command -v $item >/dev/null 2>&1 ; then
    echo "ERROR: '$item' is required but not in PATH. Aborting." >&2
  fi
done

#-------------------------------------------------------------
# Helpful functions
#-------------------------------------------------------------
function get_gh_token() {
  local app_id="${1:?Usage: get_gh_token <app-id> <installation-id> <key>}"
  local installation_id="${2:?Usage: get_gh_token <app-id> <installation-id> <key>}"
  local key="${3:?Usage: get_gh_token <app-id> <installation-id> <key>}"
  GH_TOKEN="$(gh-token generate --app-id "$app_id" --installation-id "$installation_id" --key "$key" | jq -r '.token')"
  if [[ -z "$GH_TOKEN" ]]; then
    echo "Failed to generate GitHub token. Aborting." >&2
    exit 1
  else
    export GH_TOKEN
  fi
}

function get_issue() {
  local cluster_name="${1:?Usage: get_issue <cluster-name>}"
  gh issue list \
    --label "$QUEUE_LABEL" \
    --label "$cluster_name" \
    --label unclaimed \
    --state open \
    --limit 1 \
    --search "sort:created-asc author:app/github-actions" \
    --json number,title,body,milestone \
    --jq '.[0] // empty'
}

function claim_issue() {
  local issue_number="${1:?Usage: claim_issue <issue-number>}"
  gh issue edit "$issue_number" --remove-label unclaimed
}

#-------------------------------------------------------------

# Re-submit self before doing any work
# afterok means the next job queues up only after this one exits cleanly.
# Capturing the new job ID isn't needed; the chain is self-sustaining.
echo
echo "+++++++++++++++ Starting daemon job $SLURM_JOB_ID [$(date "+%Y-%b-%d %H:%M:%S")] +++++++++++++++"
echo "Submitting next poller job to run in: ${RESUBMIT_FREQ}"
sbatch "--dependency=afterok:${SLURM_JOB_ID}" "--begin=now+${RESUBMIT_FREQ}" "${BASH_SOURCE[0]}"

get_gh_token "$GH_APP_ID" "$GH_APP_INSTALL_ID" "$GH_APP_KEY"

echo "Searching for work"
ISSUE="$(get_issue $CLUSTER_LABEL)"

if [[ -z "$ISSUE" ]]; then
  echo "No work found"
  echo "Trying again in ${RESUBMIT_FREQ}"
else
  NUMBER="$(echo "$ISSUE" | jq -r '.number')"
  echo "Found: '$(echo "$ISSUE" | jq -r '.title')'"
  claim_issue "$NUMBER"
  echo "$ISSUE" | jq -r '.body'
  # Submit the work job to the queue, passing the issue as an argument.
  # Also pass the GitHub App credentials to the job, so it can generate it's own token if needed.
  job="$(sbatch --export=ALL --parsable --chdir ./example_workflow ./example_workflow/example_workflow.sh "$ISSUE")"
  jobstr="Submitted workflow, jobid: $job"
  gh issue comment "$NUMBER" --body "$jobstr" > /dev/null
  echo "$jobstr"
fi
echo "+++++++++++++++ Stopping daemon job $SLURM_JOB_ID [$(date "+%Y-%b-%d %H:%M:%S")] +++++++++++++++"
