#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_contains() {
  local file=$1
  local text=$2
  grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}

cat > "$TEMP_DIR/pr.diff" <<'DIFF'
diff --git a/one.txt b/one.txt
index 1111111..2222222 100644
--- a/one.txt
+++ b/one.txt
@@ -1 +1,2 @@
 one
+first change
diff --git a/two.txt b/two.txt
index 1111111..2222222 100644
--- a/two.txt
+++ b/two.txt
@@ -1 +1,2 @@
 two
+second change
diff --git a/three.txt b/three.txt
index 1111111..2222222 100644
--- a/three.txt
+++ b/three.txt
@@ -1 +1,2 @@
 three
+third change
DIFF

mkdir -p "$TEMP_DIR/work"
BATCH_MAX_BYTES=180 FILE_MAX_BYTES=1000 MAX_BATCHES=2 \
  "$ROOT/scripts/chunk-diff.sh" "$TEMP_DIR/pr.diff" "$TEMP_DIR/work"

[ "$(cat "$TEMP_DIR/work/batch.count")" = "2" ] || fail "expected two batches"
assert_contains "$TEMP_DIR/work/overflow.note" "batch cap (2) reached"

cat > "$TEMP_DIR/large.diff" <<'DIFF'
diff --git a/large.txt b/large.txt
index 1111111..2222222 100644
--- a/large.txt
+++ b/large.txt
@@ -1 +1,20 @@
-old
+abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz
DIFF

mkdir -p "$TEMP_DIR/large-work"
BATCH_MAX_BYTES=500 FILE_MAX_BYTES=100 MAX_BATCHES=2 \
  "$ROOT/scripts/chunk-diff.sh" "$TEMP_DIR/large.diff" "$TEMP_DIR/large-work"
assert_contains "$TEMP_DIR/large-work/overflow.note" "large.txt"
assert_contains "$TEMP_DIR/large-work/batches/batch_000.diff" "truncated at 100 bytes"

# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"
printf 'No issues found.\n' > "$TEMP_DIR/clean.md"
is_clean_review "$TEMP_DIR/clean.md" || fail "clean result was not recognized"
printf 'No issues found.No issues found.\n' > "$TEMP_DIR/repeated-clean.md"
is_clean_review "$TEMP_DIR/repeated-clean.md" || fail "repeated clean result was not recognized"
printf 'Severity: HIGH\n' > "$TEMP_DIR/finding.md"
if is_clean_review "$TEMP_DIR/finding.md"; then
  fail "finding was classified as clean"
fi

printf '%070000d' 0 > "$TEMP_DIR/long-comment.md"
node "$ROOT/scripts/truncate-comment.mjs" \
  "$TEMP_DIR/long-comment.md" "$TEMP_DIR/truncated.md" 60000
[ "$(wc -c < "$TEMP_DIR/truncated.md")" -le 60000 ] || fail "comment was not truncated"
assert_contains "$TEMP_DIR/truncated.md" "Review output truncated"

guard_output="$TEMP_DIR/guard.out"
EVENT_NAME=pull_request_target \
REPOSITORY=shariqh/example \
REPOSITORY_OWNER=shariqh \
WORKFLOW_ACTOR=shariqh \
WORKFLOW_TRIGGERING_ACTOR=shariqh \
PR_AUTHOR=shariqh \
PR_BASE_SHA=base \
PR_HEAD_SHA=head \
PR_HEAD_REPOSITORY=shariqh/example \
PR_NUMBER=1 \
PR_DRAFT=false \
OWNER_ONLY=true \
COPILOT_GITHUB_TOKEN=copilot-token \
REVIEW_GITHUB_TOKEN=github-token \
GITHUB_OUTPUT="$guard_output" \
  "$ROOT/scripts/guard.sh"
assert_contains "$guard_output" "skip=false"

: > "$guard_output"
EVENT_NAME=pull_request \
REPOSITORY=shariqh/example \
REPOSITORY_OWNER=shariqh \
WORKFLOW_ACTOR=contributor \
WORKFLOW_TRIGGERING_ACTOR=contributor \
PR_AUTHOR=contributor \
PR_BASE_SHA=base \
PR_HEAD_SHA=head \
PR_HEAD_REPOSITORY=contributor/example \
PR_NUMBER=2 \
PR_DRAFT=false \
OWNER_ONLY=false \
COPILOT_GITHUB_TOKEN=copilot-token \
REVIEW_GITHUB_TOKEN=github-token \
GITHUB_OUTPUT="$guard_output" \
  "$ROOT/scripts/guard.sh"
assert_contains "$guard_output" "skip=true"
assert_contains "$guard_output" "reason=fork"

install_line=$(grep -n 'npm install --global --ignore-scripts' "$ROOT/action.yml" | cut -d: -f1)
checkout_line=$(grep -n 'name: Check out pull request' "$ROOT/action.yml" | cut -d: -f1)
[ "$install_line" -lt "$checkout_line" ] || fail "Copilot CLI must be installed before PR checkout"
assert_contains "$ROOT/action.yml" "NPM_CONFIG_USERCONFIG: /dev/null"
assert_contains "$ROOT/action.yml" "working-directory: \${{ runner.temp }}"
assert_contains "$ROOT/action.yml" "path: .ai-code-review-pr-"
assert_contains "$ROOT/examples/ai-code-review.yml" "pull_request_target:"

echo "All tests passed."
