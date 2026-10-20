#!/usr/bin/env bash
set -euo pipefail

# Fail unless the sticky comment now covers the pull request's CURRENT head
# from THIS run.
#
# post-comment.sh skips the sticky update when a push superseded the reviewed
# head mid-run, and that step is continue-on-error (a transient posting error
# must not discard a finished review). Without this check, a run that posted
# nothing for the current head would still report success. GitHub Actions has
# no neutral step conclusion, so a failure is the honest outcome. This never
# cancels or delays anything; it only stops a no-op run from claiming it
# covered the current head.
#
# Ground truth is re-read from the API rather than taken from earlier steps:
# the live head (checked before and again right after the sticky checks, to
# keep the window between "confirmed current" and "reported success" as
# small as the API calls in between allow) and the sticky comment's own
# "Reviewed commit" and run markers.

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPOSITORY:?REPOSITORY is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${HEAD_SHA:?HEAD_SHA is required}"
: "${RUN_ID:?RUN_ID is required}"

COMMENT_MARKER=${COMMENT_MARKER:-ai-code-review-sticky}
if ! [[ "$COMMENT_MARKER" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "::error::comment-marker may contain only letters, numbers, underscores, and hyphens"
  exit 1
fi

current_head=$(gh api "repos/$REPOSITORY/pulls/$PR_NUMBER" --jq .head.sha)
if [ "$current_head" != "$HEAD_SHA" ]; then
  echo "::error::the PR head moved during this run (this run reviewed $HEAD_SHA, the head is now $current_head), so this run cannot certify the current head."
  exit 1
fi

marker="<!-- $COMMENT_MARKER -->"
ids=$(gh api "repos/$REPOSITORY/issues/$PR_NUMBER/comments" --paginate \
  --jq ".[] | select(.user.login == \"github-actions[bot]\" and (.body | contains(\"$marker\"))) | .id")
existing_id=$(printf '%s\n' "$ids" | awk '/^[0-9]+$/' | sort -n | tail -n 1)
if [ -z "$existing_id" ]; then
  echo "::error::no sticky comment with marker '$marker' was found on PR #$PR_NUMBER, so the review did not post."
  exit 1
fi

sticky_body=$(gh api "repos/$REPOSITORY/issues/comments/$existing_id" --jq .body)
# shellcheck disable=SC2016  # backticks are literal Markdown delimiters
reviewed_sha=$(printf '%s\n' "$sticky_body" \
  | sed -n 's/^_Reviewed commit: `\([0-9a-f][0-9a-f]*\)`_$/\1/p' | tail -n 1)
reviewed_run=$(printf '%s\n' "$sticky_body" \
  | sed -n 's/^<!-- ai-code-review-run: \([0-9][0-9]*\) -->$/\1/p' | tail -n 1)

if [ "$reviewed_sha" != "$HEAD_SHA" ] || [ "$reviewed_run" != "$RUN_ID" ]; then
  echo "::error::the sticky comment does not reflect this run: reviewed_sha='$reviewed_sha' (want $HEAD_SHA), reviewed_run='$reviewed_run' (want $RUN_ID). The review did not land on the current head."
  exit 1
fi

final_head=$(gh api "repos/$REPOSITORY/pulls/$PR_NUMBER" --jq .head.sha)
if [ "$final_head" != "$HEAD_SHA" ]; then
  echo "::error::the PR head moved while this check ran (now $final_head), so this run's result is discarded."
  exit 1
fi

echo "verified: sticky comment $existing_id covers head $HEAD_SHA from run $RUN_ID"
