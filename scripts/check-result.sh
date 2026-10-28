#!/usr/bin/env bash
set -euo pipefail

# Runs after the sticky comment is posted. A review in which every model call
# failed reviewed nothing, so it fails the job instead of leaving a green
# check over an "Incomplete review" comment, and so does one in which every
# verification call failed, which posted none of its findings. A partial
# failure is a warning: the sticky comment already lists the files that were
# not reviewed and the findings that were not verified.

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

# verify-findings.sh writes its counts even when there was nothing to verify.
# Without them, no verification ran, and render listed every finding meant
# for the verifier as not verified.
verify_attempted=0
verify_completed=0
if [ -f verify.attempted ] || [ -f verify.completed ]; then
  verify_attempted=$(tr -d '[:space:]' < verify.attempted 2>/dev/null || true)
  verify_completed=$(tr -d '[:space:]' < verify.completed 2>/dev/null || true)
fi
if ! [[ "$verify_attempted" =~ ^[0-9]+$ ]] || ! [[ "$verify_completed" =~ ^[0-9]+$ ]] \
  || [ "$verify_completed" -gt "$verify_attempted" ]; then
  echo "::error::the verification step's call counts are malformed, so it is not known whether any finding was verified"
  exit 1
fi
verify_failed=$((verify_attempted - verify_completed))
if [ "$verify_attempted" -gt 0 ] && [ "$verify_completed" -eq 0 ]; then
  echo "::error::every verification call failed ($verify_failed of $verify_attempted), so no finding was verified or posted inline. The Copilot CLI's error output is in the log of the 'Verify findings' step."
  exit 1
fi
if [ "$verify_failed" -gt 0 ]; then
  echo "::warning::$verify_failed of $verify_attempted verification calls failed; the sticky comment lists those findings as not verified, and the Copilot CLI's error output is in the 'Verify findings' step."
fi
echo "verification calls completed: $verify_completed of $verify_attempted"
