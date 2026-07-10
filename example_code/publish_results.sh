#!/bin/bash
#SBATCH --job-name=publish
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=00:01:00
#SBATCH --output="publish-%j.out"
set -euo pipefail

# Run GitHub setup
gh_setup

# Take the issue as input
ISSUE="${1:?Usage: ${BASH_SOURCE[0]} <issue>}"
ISSUE_NUMBER="$(echo "$ISSUE" | jq -r '.number')"

# Get parent jobs. Remove the prefix 'afterany:' or 'afterok:'
RAW_IDS="${SLURM_JOB_DEPENDENCY#*:}"

# Replace colons with commas so sacct can read them all at once
PARENT_IDS="${RAW_IDS//:/,}"

# Query the state of parent jobs
STATES="$(sacct -j "$PARENT_IDS" -X --format=JobName,JobID,State,ExitCode || echo '[no parent jobs found]')"

# Check if any parent jobs not in "COMPLETED" state
if sacct -j "$PARENT_IDS" -X --format=State --noheader --parsable2 | grep -qv '^COMPLETED$'; then
  STATE=FAILED
else
  STATE=COMPLETED
fi

# Construct the header
HEADER="$(cat << EOF
\`$SLURM_JOB_NAME $SLURM_JOB_ID $STATE\`
Parent jobs:
\`\`\`
$STATES
\`\`\`
EOF
)"

# Construct the footer
if [[ "$STATE" == "FAILED" ]]; then
  FOOTER="Please check the Slurm job logs for details."
else
  FOOTER="$(cat << EOF

Timing results:
\`\`\`
$(grep 'Execution time' timings.txt || echo "No timing information found")
\`\`\`
EOF
)"
fi

# Construct full body
BODY="$(cat << EOF
$HEADER
$FOOTER
EOF
)"

# Print to logfile
echo "$BODY"

# Publish and un-claim
gh issue comment "$ISSUE_NUMBER" --body "$BODY"
gh issue edit "$ISSUE_NUMBER" --remove-label "running"

# Close or mark as failed
if [[ "$STATE" == "FAILED" ]]; then
  gh issue edit "$ISSUE_NUMBER" --add-label "failed"
  exit 1
else
  gh issue close "$ISSUE_NUMBER" 2>&1 | sed 's/✓ //g'
fi
