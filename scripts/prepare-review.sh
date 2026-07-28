#!/usr/bin/env bash
set -euo pipefail

: "${BASE_SHA:?BASE_SHA is required}"
: "${HEAD_SHA:?HEAD_SHA is required}"
: "${REVIEW_REPO_DIR:?REVIEW_REPO_DIR is required}"
: "${REVIEW_WORK_DIR:?REVIEW_WORK_DIR is required}"

case "$REVIEW_WORK_DIR" in
  /|""|.) echo "::error::unsafe REVIEW_WORK_DIR"; exit 1 ;;
esac

rm -rf -- "$REVIEW_WORK_DIR"
mkdir -p "$REVIEW_WORK_DIR"

git -C "$REVIEW_REPO_DIR" diff "$BASE_SHA...$HEAD_SHA" > "$REVIEW_WORK_DIR/pr.diff"
echo "diff bytes: $(wc -c < "$REVIEW_WORK_DIR/pr.diff")"

# Maintainer review context (conventions, known false positives), injected
# into the review prompt. Read from the base BRANCH, never the PR head or the
# checked-out working tree, so a pull request cannot rewrite the instructions
# that review it.
#
# Prefer the base branch's CURRENT tip over the event's BASE_SHA: base.sha is
# frozen at PR creation, so a PR opened before the context file (or an edit
# to it) landed would silently review without it. The branch tip is just as
# trusted — only maintainers can move it — and always current. Fall back to
# BASE_SHA when the remote ref is absent (e.g. plain-SHA test fixtures).
CONTEXT_FILE=${CONTEXT_FILE:-}
CONTEXT_MAX_BYTES=${CONTEXT_MAX_BYTES:-16000}
BASE_REF=${BASE_REF:-}
context_rev="$BASE_SHA"
if [ -n "$BASE_REF" ] && \
    git -C "$REVIEW_REPO_DIR" rev-parse -q --verify \
      "refs/remotes/origin/$BASE_REF" > /dev/null; then
  context_rev="refs/remotes/origin/$BASE_REF"
fi
: > "$REVIEW_WORK_DIR/review-context.md"
if [ -n "$CONTEXT_FILE" ]; then
  if git -C "$REVIEW_REPO_DIR" show "$context_rev:$CONTEXT_FILE" \
      > "$REVIEW_WORK_DIR/review-context.md" 2>/dev/null; then
    context_bytes=$(wc -c < "$REVIEW_WORK_DIR/review-context.md")
    if [ "$context_bytes" -gt "$CONTEXT_MAX_BYTES" ]; then
      head -c "$CONTEXT_MAX_BYTES" "$REVIEW_WORK_DIR/review-context.md" \
        > "$REVIEW_WORK_DIR/review-context.md.tmp"
      printf '\n[review context truncated at %s bytes]\n' "$CONTEXT_MAX_BYTES" \
        >> "$REVIEW_WORK_DIR/review-context.md.tmp"
      mv "$REVIEW_WORK_DIR/review-context.md.tmp" "$REVIEW_WORK_DIR/review-context.md"
    fi
    echo "review context: $CONTEXT_FILE ($context_bytes bytes from $context_rev)"
  else
    # Not on the base ref (or unreadable) — review without context. A partial
    # write from the failed `git show` must not leak into the prompt.
    : > "$REVIEW_WORK_DIR/review-context.md"
    echo "review context: $CONTEXT_FILE not on $context_rev; skipping"
  fi
fi

"$GITHUB_ACTION_PATH/scripts/chunk-diff.sh" \
  "$REVIEW_WORK_DIR/pr.diff" \
  "$REVIEW_WORK_DIR"
