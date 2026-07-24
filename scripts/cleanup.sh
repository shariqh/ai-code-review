#!/usr/bin/env bash
set -euo pipefail

: "${REVIEW_WORK_DIR:?REVIEW_WORK_DIR is required}"
case "$REVIEW_WORK_DIR" in
  /|""|.) echo "::error::unsafe REVIEW_WORK_DIR"; exit 1 ;;
esac

rm -rf -- "$REVIEW_WORK_DIR"
