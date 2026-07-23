#!/bin/bash
#SBATCH --job-name=results
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=00:01:00
#SBATCH --output="results-%j.out"
set -euo pipefail

# Run GitHub setup
gh_setup

# Take the issue number as input
ISSUE_NUMBER="${1:?Usage: ${BASH_SOURCE[0]} <issue_number>}"

timings_file=timings.txt

BODY="$(cat << EOF
Timing results:
\`\`\`
$(grep 'Execution time' ${timings_file} || echo "No timing information found")
\`\`\`
EOF
)"

# Print to logfile
echo "$BODY"

# Publish and un-claim
gh issue comment "$ISSUE_NUMBER" --body "$BODY"
