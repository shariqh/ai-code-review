#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPOSITORY:?REPOSITORY is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${HEAD_SHA:?HEAD_SHA is required}"
: "${RUN_ID:?RUN_ID is required}"
: "${RUN_ATTEMPT:?RUN_ATTEMPT is required}"
: "${REVIEW_MODEL:?REVIEW_MODEL is required}"
: "${REVIEW_WORK_DIR:?REVIEW_WORK_DIR is required}"

COMMENT_MARKER=${COMMENT_MARKER:-ai-code-review-sticky}
if ! [[ "$COMMENT_MARKER" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "::error::comment-marker may contain only letters, numbers, underscores, and hyphens"
  exit 1
fi
if ! [[ "$RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]]; then
  echo "::error::RUN_ATTEMPT must be a positive integer"
  exit 1
fi

# shellcheck disable=SC1091
source "$GITHUB_ACTION_PATH/scripts/lib.sh"
cd "$REVIEW_WORK_DIR"

# review-scope since-last-review: prepare-review.sh writes scope.full-review,
# the commit of the full review this one builds on (the head itself for a full
# review), and scope.base, the base branch and merge base this review was
# diffed against, and for an incremental review also scope.since, the head
# this reviewer last reviewed, and scope.previous-result, that review's
# result. With review-scope full there are none, and the comment is
# unchanged. The values go into the header, so each must be exactly what
# prepare-review.sh writes.
full_review=""
base=""
since=""
previous_result=""
if [ -s scope.full-review ]; then
  full_review=$(cat scope.full-review)
  if ! [[ "$full_review" =~ ^[0-9a-f]{40}$ ]]; then
    echo "::error::scope.full-review does not hold a commit SHA"
    exit 1
  fi
fi
if [ -s scope.base ]; then
  base=$(cat scope.base)
  if ! [[ "$base" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*\ [0-9a-f]{40}$ ]] \
    || [ -z "$full_review" ]; then
    echo "::error::scope.base does not hold a branch name and a commit SHA"
    exit 1
  fi
fi
if [ -s scope.since ]; then
  since=$(cat scope.since)
  previous_result=$(cat scope.previous-result 2>/dev/null || true)
  if ! [[ "$since" =~ ^[0-9a-f]{40}$ ]] || [ -z "$full_review" ] \
    || ! [[ "$previous_result" =~ ^(clean|findings)$ ]]; then
    echo "::error::the incremental review scope recorded by prepare-review.sh is malformed"
    exit 1
  fi
fi

marker="<!-- $COMMENT_MARKER -->"
{
  echo "$marker"
  echo "## AI code review (\`$REVIEW_MODEL\` via Copilot CLI)"
  echo
  echo "_Reviewed commit: \`$HEAD_SHA\`_"
  echo
  # An incremental review says so under the reviewed commit, which stays the
  # head so that verify-landed and other readers work unchanged. A full
  # review adds nothing visible.
  if [ -n "$since" ]; then
    echo "> **Incremental review** of \`$since..$HEAD_SHA\`; the full review was at \`$full_review\`."
    echo
  fi
  echo "<!-- ai-code-review-run: $RUN_ID -->"
  echo "<!-- ai-code-review-attempt: $RUN_ATTEMPT -->"
  # What the next since-last-review run reads (sticky_scope_fields): the full
  # review to name, the base it must still match, and whether this review
  # covered everything it was given.
  if [ -n "$full_review" ]; then
    echo "<!-- ai-code-review-full-review: $full_review -->"
    if [ -n "$base" ]; then
      echo "<!-- ai-code-review-base: $base -->"
    fi
    if is_complete_review "$REVIEW_WORK_DIR"; then
      echo "<!-- ai-code-review-coverage: complete -->"
    else
      echo "<!-- ai-code-review-coverage: incomplete -->"
    fi
  fi
  # The result marker ends the header that sticky_header_fields reads; model
  # output only ever follows it. An incremental review re-checks only the
  # commits since the last review, so findings from before stand until a
  # full review: after findings it stays findings, even with nothing new
  # found. An empty incremental diff after a clean review stays clean.
  if [ "$previous_result" = findings ]; then
    echo "<!-- ai-code-review-result: findings -->"
  elif is_empty_incremental_review "$REVIEW_WORK_DIR" \
    || is_complete_clean_review "$REVIEW_WORK_DIR"; then
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

# This reviewer's stickies only: a bot comment whose first line is its marker.
# Another reviewer's sticky can quote the marker in its findings, and must not
# be updated or deleted here.
ids=$(gh api "repos/$REPOSITORY/issues/$PR_NUMBER/comments" --paginate \
  --jq "$(sticky_ids_jq "$COMMENT_MARKER")")

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
