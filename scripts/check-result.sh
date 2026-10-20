#!/usr/bin/env bash
set -euo pipefail

# Runs after the sticky comment is posted. A review in which every model call
# failed reviewed nothing, so it fails the job instead of leaving a green
# check over an "Incomplete review" comment. A partial failure is a warning:
# the sticky comment already lists the files that were not reviewed.

: "${REVIEW_WORK_DIR:?REVIEW_WORK_DIR is required}"
cd "$REVIEW_WORK_DIR"

attempted=""
completed=""
if [ -f review.attempted ] && [ -f review.completed ]; then
  attempted=$(tr -d '[:space:]' < review.attempted)
  completed=$(tr -d '[:space:]' < review.completed)
fi

if ! [[ "$attempted" =~ ^[0-9]+$ ]] || ! [[ "$completed" =~ ^[0-9]+$ ]] \
  || [ "$completed" -gt "$attempted" ]; then
  echo "::error::the review step's call counts are missing or malformed, so it is not known whether anything was reviewed"
  exit 1
fi

failed=$((attempted - completed))

if [ "$attempted" -gt 0 ] && [ "$completed" -eq 0 ]; then
  echo "::error::every review call failed ($failed of $attempted), so nothing was reviewed. The Copilot CLI's error output is in the log of the 'Run adversarial review' step."
  exit 1
fi

if [ "$failed" -gt 0 ]; then
  echo "::warning::$failed of $attempted review calls failed; the sticky comment lists the files that were not reviewed, and the Copilot CLI's error output is in the 'Run adversarial review' step."
fi

echo "review calls completed: $completed of $attempted"
