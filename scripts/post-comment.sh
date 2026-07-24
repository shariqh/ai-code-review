#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPOSITORY:?REPOSITORY is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${HEAD_SHA:?HEAD_SHA is required}"
: "${RUN_ID:?RUN_ID is required}"
: "${REVIEW_MODEL:?REVIEW_MODEL is required}"
: "${REVIEW_WORK_DIR:?REVIEW_WORK_DIR is required}"

COMMENT_MARKER=${COMMENT_MARKER:-ai-code-review-sticky}
if ! [[ "$COMMENT_MARKER" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "::error::comment-marker may contain only letters, numbers, underscores, and hyphens"
  exit 1
fi

# shellcheck disable=SC1091
source "$GITHUB_ACTION_PATH/scripts/lib.sh"
cd "$REVIEW_WORK_DIR"

marker="<!-- $COMMENT_MARKER -->"
{
  echo "$marker"
  echo "## AI code review (\`$REVIEW_MODEL\` via Copilot CLI)"
  echo
  echo "_Reviewed commit: \`$HEAD_SHA\`_"
  echo
  echo "<!-- ai-code-review-run: $RUN_ID -->"
  if is_complete_clean_review "$REVIEW_WORK_DIR"; then
    echo "<!-- ai-code-review-result: clean -->"
  else
    echo "<!-- ai-code-review-result: findings -->"
  fi
  echo
  if [ -s overflow.note ]; then
    echo "> **Partial coverage** - some content was not fully reviewed:"
    echo
    cat overflow.note
    echo
  fi
  if [ -s review.failures ]; then
    echo "> **Incomplete review** - one or more review calls failed; those files were NOT reviewed:"
    echo
    cat review.failures
    echo
  fi
  cat review.md
  echo
  echo "_Automated, independent-model review (updated each push). Not a substitute for human judgment._"
} > comment.full.md

node "$GITHUB_ACTION_PATH/scripts/truncate-comment.mjs" \
  comment.full.md comment.md 60000

ids=$(gh api "repos/$REPOSITORY/issues/$PR_NUMBER/comments" --paginate \
  --jq ".[] | select(.user.login == \"github-actions[bot]\" and (.body | contains(\"$marker\"))) | .id")

if ! current_head=$(gh api "repos/$REPOSITORY/pulls/$PR_NUMBER" --jq .head.sha); then
  echo "::error::could not read the current pull request head"
  exit 1
fi

if [ -z "$current_head" ]; then
  echo "::error::current pull request head is empty"
  exit 1
fi

if [ "$current_head" != "$HEAD_SHA" ]; then
  echo "stale review run: current head is $current_head, reviewed $HEAD_SHA; skipping sticky update"
  exit 0
fi

existing=$(printf '%s\n' "$ids" | awk '/^[0-9]+$/' | sort -n | tail -n 1)
if [ -n "$existing" ]; then
  gh api -X PATCH "repos/$REPOSITORY/issues/comments/$existing" \
    -F body=@comment.md >/dev/null
  echo "updated sticky comment $existing"

  while IFS= read -r duplicate; do
    [ -n "$duplicate" ] || continue
    [ "$duplicate" = "$existing" ] && continue
    if gh api -X DELETE "repos/$REPOSITORY/issues/comments/$duplicate" >/dev/null 2>&1; then
      echo "deleted duplicate sticky comment $duplicate"
    fi
  done <<< "$ids"
else
  gh api -X POST "repos/$REPOSITORY/issues/$PR_NUMBER/comments" \
    -F body=@comment.md >/dev/null
  echo "created sticky review comment"
fi
