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

# Collect and publish the results. Query all parents simultaneously
echo "Checking parents: $PARENT_IDS"
results_table="$(sacct -j "$PARENT_IDS" -X --format=JobName,JobID,State,ExitCode)"
echo "$results_table"

if sacct -j "$PARENT_IDS" -X --format=State --noheader --parsable2 | grep -qv '^COMPLETED$'; then
  echo "ERROR: Some jobs are not 'COMPLETED'" >&2

  body="$(cat << EOF
Some jobs failed. Please check the Slurm job logs for details.
\`\`\`
$results_table
\`\`\`
EOF
)"

  echo "$body" >&2

  gh issue comment "$ISSUE_NUMBER" --body "$body" >&2
  gh issue edit "$ISSUE_NUMBER" --remove-label "running" --add-label "failed" >&2
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
