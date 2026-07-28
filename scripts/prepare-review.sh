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
# into the review prompt. Read from the BASE ref, never the PR head or the
# checked-out working tree, so a pull request cannot rewrite the instructions
# that review it.
CONTEXT_FILE=${CONTEXT_FILE:-}
CONTEXT_MAX_BYTES=${CONTEXT_MAX_BYTES:-16000}
: > "$REVIEW_WORK_DIR/review-context.md"
if [ -n "$CONTEXT_FILE" ]; then
  if git -C "$REVIEW_REPO_DIR" show "$BASE_SHA:$CONTEXT_FILE" \
      > "$REVIEW_WORK_DIR/review-context.md" 2>/dev/null; then
    context_bytes=$(wc -c < "$REVIEW_WORK_DIR/review-context.md")
    if [ "$context_bytes" -gt "$CONTEXT_MAX_BYTES" ]; then
      head -c "$CONTEXT_MAX_BYTES" "$REVIEW_WORK_DIR/review-context.md" \
        > "$REVIEW_WORK_DIR/review-context.md.tmp"
      printf '\n[review context truncated at %s bytes]\n' "$CONTEXT_MAX_BYTES" \
        >> "$REVIEW_WORK_DIR/review-context.md.tmp"
      mv "$REVIEW_WORK_DIR/review-context.md.tmp" "$REVIEW_WORK_DIR/review-context.md"
    fi
    echo "review context: $CONTEXT_FILE ($context_bytes bytes from base ref)"
  else
    # Not on the base ref (or unreadable) — review without context. A partial
    # write from the failed `git show` must not leak into the prompt.
    : > "$REVIEW_WORK_DIR/review-context.md"
    echo "review context: $CONTEXT_FILE not on base ref; skipping"
  fi
fi

"$GITHUB_ACTION_PATH/scripts/chunk-diff.sh" \
  "$REVIEW_WORK_DIR/pr.diff" \
  "$REVIEW_WORK_DIR"
