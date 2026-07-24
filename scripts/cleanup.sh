#!/usr/bin/env bash
set -euo pipefail

: "${REVIEW_REPO_DIR:?REVIEW_REPO_DIR is required}"
: "${REVIEW_WORK_DIR:?REVIEW_WORK_DIR is required}"
case "$REVIEW_WORK_DIR" in
  */ai-code-review-*) ;;
  *) echo "::error::unsafe REVIEW_WORK_DIR"; exit 1 ;;
esac

case "$REVIEW_REPO_DIR" in
  */.ai-code-review-pr-*) ;;
  *) echo "::error::unsafe REVIEW_REPO_DIR"; exit 1 ;;
esac

rm -rf -- "$REVIEW_WORK_DIR" "$REVIEW_REPO_DIR"
