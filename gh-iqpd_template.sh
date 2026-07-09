#!/bin/bash
#SBATCH --job-name=gh-iqpd
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=00:01:00
#SBATCH --open-mode=append
#SBATCH --output=gh-iqpd.log
set -euo pipefail

#------------------------------------------------------------------------------------------------------
# GitHub Issue Queue Poller Daemon (gh-iqpd) for SLURM
#------------------------------------------------------------------------------------------------------

# Configuration
RESUBMIT_FREQ=1week
CLUSTER_LABEL="<<CLUSTER_NAME>>"
QUEUE_LABEL="<<QUEUE_LABEL>>"
export GH_APP_ID="<<GH_APP_ID>>"
export GH_APP_INSTALL_ID="<<GH_APP_INSTALL_ID>>"
export GH_APP_KEY="<</path/to/GH_APP_KEY>>"
export GH_REPO="<<GH_USERNAME/GH_REPONAME>>"
export GH_CLI_BIN="$PWD/bin"  # Path to the directory containing the gh and gh-token CLI tools

# Set up GitHub things
gh_setup() {
  local item
  local req_vars=(GH_APP_ID GH_APP_INSTALL_ID GH_APP_KEY GH_REPO GH_CLI_BIN)

  # Check for required commands
  for item in gh gh-token jq; do
    if ! command -v $item >/dev/null 2>&1 ; then
      echo "ERROR: '$item' is required but not in PATH. Aborting." >&2
      exit 1
    fi
  done

  # Check for required environment variables
  for item in "${req_vars[@]}"; do
    if [ -z "${!item}" ]; then
      echo "Error: Required environment variable '$item' is not set." >&2
      exit 1
    fi
  done

  # export all the required environment variables
  export "${req_vars[@]}"

  # Add CLI tools to PATH
  PATH="$GH_CLI_BIN:$PATH"

  # Generate and export GitHub App token
  GH_TOKEN="$(gh-token generate --token-only \
    --app-id "$GH_APP_ID" \
    --installation-id "$GH_APP_INSTALL_ID" \
    --key "$GH_APP_KEY"
  )"
  if [[ -z "$GH_TOKEN" ]]; then
    echo "ERROR: Failed to generate GitHub token. Aborting." >&2
    exit 1
  else
    export GH_TOKEN
  fi

  # Create a list of variables to export to child jobs if they need github access
  GH_EXPORT_LIST="GH_EXPORT_LIST,${FUNCNAME[0]},$(IFS=,; echo "${req_vars[*]}")"s
  export GH_EXPORT_LIST
}

#------------------------------------------------------------------------------------------------------
# Helpful functions
#------------------------------------------------------------------------------------------------------
gh_get_issue() {
  local queue_label="${1:?Usage: gh_get_issue <queue-label> <cluster-name>}"
  local cluster_name="${2:?Usage: gh_get_issue <queue-label> <cluster-name>}"
  gh issue list \
    --label "$queue_label" \
    --label "$cluster_name" \
    --state open \
    --limit 1 \
    --search "sort:created-asc author:app/github-actions -label:running -label:failed" \
    --json number,title,body,milestone \
    --jq '.[0] // empty'
}

gh_claim_issue() {
  local issue_number="${1:?Usage: gh_claim_issue <issue-number>}"
  gh issue edit "$issue_number" --add-label running
}
#------------------------------------------------------------------------------------------------------

# Run GitHub setup and export the setup function.
gh_setup && export -f gh_setup

# Re-submit self before doing any work
# afterok means the next job queues up only after this one exits cleanly.
# Capturing the new job ID isn't needed; the chain is self-sustaining.
echo
echo "+++++++++++++++ Starting daemon job $SLURM_JOB_ID [$(date "+%Y-%b-%d %H:%M:%S")] +++++++++++++++"
echo "Submitting next poller job to run in: ${RESUBMIT_FREQ}"
sbatch "--dependency=afterok:${SLURM_JOB_ID}" "--begin=now+${RESUBMIT_FREQ}" "${BASH_SOURCE[0]}"
echo "Searching for work"
ISSUE="$(gh_get_issue "$QUEUE_LABEL" "$CLUSTER_LABEL")"

if [[ -z "$ISSUE" ]]; then
  echo "No work found"
  echo "Trying again in ${RESUBMIT_FREQ}"
else
  NUMBER="$(echo "$ISSUE" | jq -r '.number')"
  echo "Found: '$(echo "$ISSUE" | jq -r '.title')'"
  gh_claim_issue "$NUMBER"
  echo "$ISSUE" | jq -r '.body'

  # Submit the work job to the queue, passing the issue as an argument.
  # Also pass the GitHub App credentials to the job, so it can generate it's own token if needed.
  job="$(sbatch \
    --parsable \
    --export="${GH_EXPORT_LIST}" \
    --chdir ./example_workflow \
    ./example_workflow/example_workflow.sh "$ISSUE" \
  )"

  jobstr="Submitted workflow job: $job"
  gh issue comment "$NUMBER" --body "$jobstr" > /dev/null
  echo "$jobstr"
fi
echo "+++++++++++++++ Stopping daemon job $SLURM_JOB_ID [$(date "+%Y-%b-%d %H:%M:%S")] +++++++++++++++"
