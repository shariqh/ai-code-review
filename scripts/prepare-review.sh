#!/usr/bin/env bash
set -euo pipefail

: "${BASE_SHA:?BASE_SHA is required}"
: "${HEAD_SHA:?HEAD_SHA is required}"
: "${REVIEW_WORK_DIR:?REVIEW_WORK_DIR is required}"

case "$REVIEW_WORK_DIR" in
  /|""|.) echo "::error::unsafe REVIEW_WORK_DIR"; exit 1 ;;
esac

rm -rf -- "$REVIEW_WORK_DIR"
mkdir -p "$REVIEW_WORK_DIR"

git diff "$BASE_SHA...$HEAD_SHA" > "$REVIEW_WORK_DIR/pr.diff"
echo "diff bytes: $(wc -c < "$REVIEW_WORK_DIR/pr.diff")"

"$GITHUB_ACTION_PATH/scripts/chunk-diff.sh" \
  "$REVIEW_WORK_DIR/pr.diff" \
  "$REVIEW_WORK_DIR"
