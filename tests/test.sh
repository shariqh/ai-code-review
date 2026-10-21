#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEMP_DIR=$(mktemp -d)
# The suite passes only if it reaches the end. A syntax error in a sourced
# script stops bash without tripping set -e, and the cleanup would otherwise
# supply the exit status.
suite_finished=false
trap 'rm -rf "$TEMP_DIR"; [ "$suite_finished" = true ] || exit 1' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

for script in "$ROOT"/scripts/*.sh; do
  bash -n "$script" || fail "$script has a syntax error"
done

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
printf ' \n\t\n' > "$TEMP_DIR/blank.md"
if is_clean_review "$TEMP_DIR/blank.md"; then
  fail "a blank reply was classified as clean"
fi

printf '%070000d' 0 > "$TEMP_DIR/long-comment.md"
node "$ROOT/scripts/truncate-comment.mjs" \
  "$TEMP_DIR/long-comment.md" "$TEMP_DIR/truncated.md" 60000
[ "$(wc -c < "$TEMP_DIR/truncated.md")" -le 60000 ] || fail "comment was not truncated"
assert_contains "$TEMP_DIR/truncated.md" "Review output truncated"

guard_output="$TEMP_DIR/guard.out"

# Runs guard.sh for an eligible owner PR; later NAME=value arguments override
# the defaults (env applies them in order).
run_guard() {
  : > "$guard_output"
  env \
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
    VERIFY_LANDED=false \
    REVIEW_MODEL=gpt-5.6-sol \
    COMMENT_MARKER=ai-code-review-sticky \
    COPILOT_GITHUB_TOKEN=copilot-token \
    REVIEW_GITHUB_TOKEN=github-token \
    GITHUB_OUTPUT="$guard_output" \
    "$@" \
    "$ROOT/scripts/guard.sh"
}

run_guard > /dev/null
assert_contains "$guard_output" "skip=false"

run_guard \
  EVENT_NAME=pull_request \
  WORKFLOW_ACTOR=contributor \
  WORKFLOW_TRIGGERING_ACTOR=contributor \
  PR_AUTHOR=contributor \
  PR_HEAD_REPOSITORY=contributor/example \
  PR_NUMBER=2 \
  OWNER_ONLY=false > /dev/null
assert_contains "$guard_output" "skip=true"
assert_contains "$guard_output" "reason=fork"

# Configuration errors fail the job, and do so before any eligibility skip,
# so a draft or fork PR cannot hide a misconfigured reviewer.
guard_errors="$TEMP_DIR/guard.err"
for bad_setting in REVIEW_MODEL= 'REVIEW_MODEL=gpt 5' \
  COMMENT_MARKER= 'COMMENT_MARKER=bad marker' VERIFY_LANDED=yes \
  ALLOW_MISSING_TOKEN=yes REVIEW_SCOPE=sometimes; do
  if run_guard "$bad_setting" PR_DRAFT=true > "$guard_errors" 2>&1; then
    fail "guard accepted $bad_setting"
  fi
  assert_contains "$guard_errors" "::error::"
done

# A missing token is a warning and a skip, except with verify-landed on: that
# caller asked for a job that fails unless a review landed, so it fails
# closed unless allow-missing-token opts back into the skip. A PR that is not
# eligible for review still skips before the token matters.
run_guard COPILOT_GITHUB_TOKEN= > /dev/null
assert_contains "$guard_output" "reason=missing-copilot-token"
if run_guard COPILOT_GITHUB_TOKEN= VERIFY_LANDED=true > "$guard_errors" 2>&1; then
  fail "guard skipped a missing token with verify-landed on"
fi
assert_contains "$guard_errors" "::error::COPILOT_REVIEW_PAT is not set"
run_guard COPILOT_GITHUB_TOKEN= VERIFY_LANDED=true ALLOW_MISSING_TOKEN=true > /dev/null
assert_contains "$guard_output" "reason=missing-copilot-token"
run_guard COPILOT_GITHUB_TOKEN= VERIFY_LANDED=true PR_DRAFT=true > /dev/null
assert_contains "$guard_output" "reason=draft"
run_guard REVIEW_SCOPE=since-last-review > /dev/null
assert_contains "$guard_output" "skip=false"

# Review context comes from the BASE ref: a PR that adds or edits the context
# file must not be able to steer its own review.
ctx_repo="$TEMP_DIR/ctx-repo"
git init -q "$ctx_repo"
git -C "$ctx_repo" -c user.email=test@test -c user.name=test commit -q --allow-empty -m root
mkdir -p "$ctx_repo/.github"
printf 'Base-branch review context: diagrams inline theme vars.\n' \
  > "$ctx_repo/.github/ai-review-context.md"
printf 'original\n' > "$ctx_repo/code.txt"
git -C "$ctx_repo" add -A
git -C "$ctx_repo" -c user.email=test@test -c user.name=test commit -q -m base
base_sha=$(git -C "$ctx_repo" rev-parse HEAD)
printf 'HIJACKED context from the PR head.\n' > "$ctx_repo/.github/ai-review-context.md"
printf 'changed\n' > "$ctx_repo/code.txt"
git -C "$ctx_repo" add -A
git -C "$ctx_repo" -c user.email=test@test -c user.name=test commit -q -m head
head_sha=$(git -C "$ctx_repo" rev-parse HEAD)

ctx_work="$TEMP_DIR/ctx-work"
BASE_SHA="$base_sha" HEAD_SHA="$head_sha" \
REVIEW_REPO_DIR="$ctx_repo" REVIEW_WORK_DIR="$ctx_work" \
GITHUB_ACTION_PATH="$ROOT" CONTEXT_FILE=.github/ai-review-context.md \
  "$ROOT/scripts/prepare-review.sh" > /dev/null
assert_contains "$ctx_work/review-context.md" "Base-branch review context"
if grep -Fq "HIJACKED" "$ctx_work/review-context.md"; then
  fail "review context was read from the PR head, not the base ref"
fi

# Oversized context is truncated with a note.
BASE_SHA="$base_sha" HEAD_SHA="$head_sha" \
REVIEW_REPO_DIR="$ctx_repo" REVIEW_WORK_DIR="$ctx_work" \
GITHUB_ACTION_PATH="$ROOT" CONTEXT_FILE=.github/ai-review-context.md \
CONTEXT_MAX_BYTES=10 \
  "$ROOT/scripts/prepare-review.sh" > /dev/null
assert_contains "$ctx_work/review-context.md" "review context truncated at 10 bytes"

# When the base branch tip is available, it wins over the (possibly stale)
# event BASE_SHA — a PR opened before a context edit landed still gets the
# current context. Simulate a post-PR context edit on origin/main.
printf 'original\n' > "$ctx_repo/code.txt"
printf 'UPDATED context landed on main after the PR opened.\n' \
  > "$ctx_repo/.github/ai-review-context.md"
git -C "$ctx_repo" add -A
git -C "$ctx_repo" -c user.email=test@test -c user.name=test commit -q -m newer-main
git -C "$ctx_repo" update-ref refs/remotes/origin/main HEAD
git -C "$ctx_repo" checkout -q "$head_sha"
BASE_SHA="$base_sha" BASE_REF=main HEAD_SHA="$head_sha" \
REVIEW_REPO_DIR="$ctx_repo" REVIEW_WORK_DIR="$ctx_work" \
GITHUB_ACTION_PATH="$ROOT" CONTEXT_FILE=.github/ai-review-context.md \
  "$ROOT/scripts/prepare-review.sh" > /dev/null
assert_contains "$ctx_work/review-context.md" "UPDATED context landed on main"

# An unknown BASE_REF falls back to BASE_SHA.
BASE_SHA="$base_sha" BASE_REF=no-such-branch HEAD_SHA="$head_sha" \
REVIEW_REPO_DIR="$ctx_repo" REVIEW_WORK_DIR="$ctx_work" \
GITHUB_ACTION_PATH="$ROOT" CONTEXT_FILE=.github/ai-review-context.md \
  "$ROOT/scripts/prepare-review.sh" > /dev/null
assert_contains "$ctx_work/review-context.md" "Base-branch review context"

# A context file that only exists on the PR head yields NO context.
BASE_SHA="$base_sha" HEAD_SHA="$head_sha" \
REVIEW_REPO_DIR="$ctx_repo" REVIEW_WORK_DIR="$ctx_work" \
GITHUB_ACTION_PATH="$ROOT" CONTEXT_FILE=.github/only-on-head.md \
  "$ROOT/scripts/prepare-review.sh" > /dev/null
if [ -s "$ctx_work/review-context.md" ]; then
  fail "missing context file should yield an empty context"
fi

# Prompt assembly: with context, the trusted section lands between the static
# instructions and the diff; without it, the section is absent entirely.
stub_bin="$TEMP_DIR/stub-bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/copilot" <<'STUB'
#!/usr/bin/env bash
echo "No issues found."
STUB
chmod +x "$stub_bin/copilot"

run_work="$TEMP_DIR/run-work"
mkdir -p "$run_work/batches"
printf 'diff --git a/code.txt b/code.txt\n+changed\n' > "$run_work/batches/batch_000.diff"
printf 'Base-branch review context: diagrams inline theme vars.\n' > "$run_work/review-context.md"
PATH="$stub_bin:$PATH" \
COPILOT_GITHUB_TOKEN=stub-token REVIEW_WORK_DIR="$run_work" \
REVIEW_MODEL=stub-model GITHUB_ACTION_PATH="$ROOT" \
  "$ROOT/scripts/run-review.sh" > /dev/null
assert_contains "$run_work/prompt.txt" "BEGIN REPO REVIEW CONTEXT"
assert_contains "$run_work/prompt.txt" "diagrams inline theme vars"
ctx_line=$(grep -n -- '^--- BEGIN REPO REVIEW CONTEXT ---$' "$run_work/prompt.txt" | cut -d: -f1)
diff_line=$(grep -n -- '^--- BEGIN DIFF ---$' "$run_work/prompt.txt" | cut -d: -f1)
[ "$ctx_line" -lt "$diff_line" ] || fail "review context must precede the diff in the prompt"

: > "$run_work/review-context.md"
PATH="$stub_bin:$PATH" \
COPILOT_GITHUB_TOKEN=stub-token REVIEW_WORK_DIR="$run_work" \
REVIEW_MODEL=stub-model GITHUB_ACTION_PATH="$ROOT" \
  "$ROOT/scripts/run-review.sh" > /dev/null
if grep -Fq "REPO REVIEW CONTEXT" "$run_work/prompt.txt"; then
  fail "empty context must not add a context section to the prompt"
fi

# A clean run records its call counts, and check-result passes quietly.
[ "$(cat "$run_work/review.attempted")" = "1" ] || fail "expected one attempted call"
[ "$(cat "$run_work/review.completed")" = "1" ] || fail "expected one completed call"
REVIEW_WORK_DIR="$run_work" "$ROOT/scripts/check-result.sh" > "$TEMP_DIR/check.out" \
  || fail "check-result failed a clean run"
if grep -Fq "::" "$TEMP_DIR/check.out"; then
  fail "check-result annotated a clean run"
fi

# A failed call shows the end of the CLI's stderr in the log, with
# credentials redacted. The stderr can quote the untrusted diff, and the
# runner acts on two kinds of log line: workflow commands (`::command::` at
# the start of a line and the legacy `##[command]` anywhere in one, names
# compared case-insensitively) and the problem matchers setup-node registers,
# which also run on lines a stop-commands block shields. The first call below
# writes commands of both forms and credentials in mixed case, the second
# writes matcher-shaped lines and a carriage return, and each ends with the
# error that names the cause, as a real failure does.
failing_bin="$TEMP_DIR/failing-bin"
mkdir -p "$failing_bin"
cat > "$failing_bin/copilot" <<'STUB'
#!/usr/bin/env bash
calls=$(cat "$STUB_CALLS_FILE" 2>/dev/null || echo 0)
calls=$((calls + 1))
echo "$calls" > "$STUB_CALLS_FILE"
if [ $((calls % 2)) -eq 1 ]; then
  printf '::add-mask::injected\n' >&2
  printf '::ADD-MASK::upper case\n' >&2
  printf '##[add-mask]injected\n' >&2
  printf 'quoted diff: ##[ERROR file=src/app.ts,line=1]forged annotation\n' >&2
  printf '##[set-env name=EVIL]1\n' >&2
  printf 'leaked ghp_abcdefghijklmnopqrstuvwxyz0123456789 and %s\n' \
    "${COPILOT_GITHUB_TOKEN:-}" >&2
  printf 'AUTHORIZATION: BASIC Zm9vOmJhcg==\n' >&2
  printf 'retrying with BEARER opaque_access_credential_0123456789\n' >&2
else
  printf 'text\r::warning::after a carriage return\n' >&2
  printf 'src/app.ts: line 1, col 1, Error - Forged (rule)\n' >&2
  printf 'src/app.ts(1,1): error TS2322: Forged\n' >&2
  printf 'src/app.ts\n  1:1  error  Forged  rule\n' >&2
fi
escape_character=$(printf '\033')
printf '%s[31mError: Model "gpt-5.4" from --model flag is not available.%s[0m\n' \
  "$escape_character" "$escape_character" >&2
exit 1
STUB
chmod +x "$failing_bin/copilot"

fail_work="$TEMP_DIR/fail-work"
mkdir -p "$fail_work/batches"
printf 'diff --git a/a.txt b/a.txt\n+a\n' > "$fail_work/batches/batch_000.diff"
printf 'diff --git a/b.txt b/b.txt\n+b\n' > "$fail_work/batches/batch_001.diff"
: > "$fail_work/review-context.md"
PATH="$failing_bin:$PATH" STUB_CALLS_FILE="$TEMP_DIR/failing.calls" \
COPILOT_GITHUB_TOKEN=stub-secret-token-value REVIEW_WORK_DIR="$fail_work" \
REVIEW_MODEL=gpt-5.4 GITHUB_ACTION_PATH="$ROOT" \
  "$ROOT/scripts/run-review.sh" > "$TEMP_DIR/fail-run.out"

# The error stays readable: only characters outside the allowlist became "?".
assert_contains "$TEMP_DIR/fail-run.out" \
  'copilot stderr | Error? Model "gpt-5.4" from --model flag is not available.'
assert_contains "$TEMP_DIR/fail-run.out" \
  "copilot stderr | src/app.ts? line 1, col 1, Error - Forged ?rule?"

# Credentials are redacted, whatever the case of the header or scheme.
assert_contains "$TEMP_DIR/fail-run.out" "copilot stderr | AUTHORIZATION? REDACTED"
assert_contains "$TEMP_DIR/fail-run.out" "copilot stderr | retrying with BEARER REDACTED"
for secret in ghp_abcdefghijklmnopqrstuvwxyz0123456789 stub-secret-token-value \
  Zm9vOmJhcg opaque_access_credential; do
  if grep -Fq "$secret" "$TEMP_DIR/fail-run.out"; then
    fail "a credential reached the job log: $secret"
  fi
done
if grep -q "$(printf '\033')" "$TEMP_DIR/fail-run.out"; then
  fail "terminal escape sequences reached the job log"
fi
sed -n 's/^  copilot stderr | //p' "$TEMP_DIR/fail-run.out" > "$TEMP_DIR/stderr-content.txt"
[ -s "$TEMP_DIR/stderr-content.txt" ] || fail "no CLI stderr was printed"
if LC_ALL=C grep -q "[^A-Za-z0-9 .,_'\"/=?-]" "$TEMP_DIR/stderr-content.txt"; then
  fail "a character outside the allowlist reached the job log"
fi

# The runner would act on nothing in that output: no workflow command, and no
# problem-matcher annotation.
commands=$(node "$ROOT/tests/workflow-commands.mjs" "$TEMP_DIR/fail-run.out")
[ -z "$commands" ] || fail "the runner would process workflow commands from CLI stderr: $commands"
matches=$(node "$ROOT/tests/problem-matchers.mjs" "$TEMP_DIR/fail-run.out")
[ -z "$matches" ] || fail "setup-node's problem matchers would annotate CLI stderr: $matches"

# Controls. Printed raw, the same stderr carries live commands of both forms
# and both cases, and all three matcher shapes. With only the line prefix the
# legacy form stays live; with the fence as well, commands stop but the
# eslint-compact line still matches, which is why the stderr is sanitized.
raw_calls="$TEMP_DIR/raw.calls"
STUB_CALLS_FILE="$raw_calls" "$failing_bin/copilot" 2> "$TEMP_DIR/raw-stderr-1.txt" || true
STUB_CALLS_FILE="$raw_calls" "$failing_bin/copilot" 2> "$TEMP_DIR/raw-stderr-2.txt" || true
cat "$TEMP_DIR/raw-stderr-1.txt" "$TEMP_DIR/raw-stderr-2.txt" > "$TEMP_DIR/raw-stderr.txt"
node "$ROOT/tests/workflow-commands.mjs" "$TEMP_DIR/raw-stderr.txt" > "$TEMP_DIR/raw-commands.txt"
for command_name in add-mask error set-env warning; do
  assert_contains "$TEMP_DIR/raw-commands.txt" ": $command_name"
done
[ "$(grep -c ': add-mask' "$TEMP_DIR/raw-commands.txt")" = "3" ] \
  || fail "expected three live add-mask commands in the raw stderr"
node "$ROOT/tests/problem-matchers.mjs" "$TEMP_DIR/raw-stderr.txt" > "$TEMP_DIR/raw-matches.txt"
for matcher_owner in eslint-compact tsc eslint-stylish; do
  assert_contains "$TEMP_DIR/raw-matches.txt" ": $matcher_owner"
done
sed 's/^/  copilot stderr | /' "$TEMP_DIR/raw-stderr.txt" > "$TEMP_DIR/prefixed-stderr.txt"
node "$ROOT/tests/workflow-commands.mjs" "$TEMP_DIR/prefixed-stderr.txt" \
  > "$TEMP_DIR/prefixed-commands.txt"
assert_contains "$TEMP_DIR/prefixed-commands.txt" ": error"
fence_token=0123456789abcdef0123456789abcdef
{
  printf '::stop-commands::%s\n' "$fence_token"
  cat "$TEMP_DIR/prefixed-stderr.txt"
  printf '::%s::\n' "$fence_token"
} > "$TEMP_DIR/fenced-stderr.txt"
[ -z "$(node "$ROOT/tests/workflow-commands.mjs" "$TEMP_DIR/fenced-stderr.txt")" ] \
  || fail "the fence should stop every command"
node "$ROOT/tests/problem-matchers.mjs" "$TEMP_DIR/fenced-stderr.txt" > "$TEMP_DIR/fenced-matches.txt"
assert_contains "$TEMP_DIR/fenced-matches.txt" ": eslint-compact"

# The command emulator itself follows the runner: names, stop-commands and the
# resume token compare case-insensitively, and CR, LF and CRLF each end a line.
printf '%s\r%s\n%s\r\n%s\n%s\n%s\n%s\n%s\n' 'plain text' '::ADD-MASK::after a CR' \
  'quoted ##[ERROR]upper case' '::STOP-COMMANDS::AbC123' '::add-mask::while stopped' \
  '##[error]while stopped' '::abc123::' '::warning::after the resume' \
  > "$TEMP_DIR/emulator-cases.txt"
emulated=$(node "$ROOT/tests/workflow-commands.mjs" "$TEMP_DIR/emulator-cases.txt")
[ "$emulated" = "$(printf '%s\n' 'line 2: add-mask' 'line 3: error' 'line 8: warning')" ] \
  || fail "the command emulator diverges from the runner: $emulated"

# Each failed call gets its own random 32-hex stop token, resumed once the
# stderr is printed, and every line in between carries the prefix.
stop_tokens=$(sed -n 's/^::stop-commands::\([0-9a-f]*\)$/\1/p' "$TEMP_DIR/fail-run.out")
[ "$(printf '%s\n' "$stop_tokens" | grep -c -E '^[0-9a-f]{32}$')" = "2" ] \
  || fail "expected a 32-hex stop token for each failed call: $stop_tokens"
[ "$(printf '%s\n' "$stop_tokens" | sort -u | wc -l | tr -d '[:space:]')" = "2" ] \
  || fail "each failed call needs its own stop token"
while IFS= read -r stop_token; do
  grep -Fxq "::$stop_token::" "$TEMP_DIR/fail-run.out" \
    || fail "stop token $stop_token is never resumed"
done <<< "$stop_tokens"
awk '
  /^::stop-commands::/ { inside = 1; next }
  inside && /^::[0-9a-f]+::$/ { inside = 0; next }
  inside && index($0, "  copilot stderr | ") != 1 { unprefixed = 1 }
  END { exit unprefixed }
' "$TEMP_DIR/fail-run.out" || fail "an unprefixed line was printed inside a stderr block"

# The bound: print_cli_stderr keeps the last 10 lines and at most 1,000 bytes,
# after redacting the whole stderr. A copilot stand-in replays a prepared
# stderr file for one batch.
replay_bin="$TEMP_DIR/replay-bin"
mkdir -p "$replay_bin"
cat > "$replay_bin/copilot" <<'STUB'
#!/usr/bin/env bash
cat "$STUB_STDERR_FILE" >&2
exit 1
STUB
chmod +x "$replay_bin/copilot"

# usage: replay_stderr <stderr file> <output file>
replay_stderr() {
  local work
  work=$(mktemp -d "$TEMP_DIR/replay.XXXXXX")
  mkdir -p "$work/batches"
  printf 'diff --git a/a.txt b/a.txt\n+a\n' > "$work/batches/batch_000.diff"
  : > "$work/review-context.md"
  PATH="$replay_bin:$PATH" STUB_STDERR_FILE="$1" \
  COPILOT_GITHUB_TOKEN=stub-token REVIEW_WORK_DIR="$work" \
  REVIEW_MODEL=stub-model GITHUB_ACTION_PATH="$ROOT" \
    "$ROOT/scripts/run-review.sh" > "$2"
  sed -n 's/^  copilot stderr | //p' "$2" > "$2.content"
}

# usage: repeat_char <count> <character>
repeat_char() {
  head -c "$1" /dev/zero | tr '\0' "$2"
}

# Copilot's case: a credential straddling byte 4,000, where the old cut fell
# before redaction, which left a fragment the patterns no longer recognised.
straddle_file="$TEMP_DIR/straddle.err"
: > "$straddle_file"
for _ in $(seq 1 39); do
  printf '%s\n' "$(repeat_char 100 f)" >> "$straddle_file"
done
printf '%s\n' "$(repeat_char 41 g)" \
  "BEARER opaque_access_credential_0123456789" "Error: the final cause" \
  >> "$straddle_file"
[ "$(head -c 4000 "$straddle_file" | tail -c 19)" = "BEARER opaque_acces" ] \
  || fail "the fixture must straddle the old 4,000-byte cut"
replay_stderr "$straddle_file" "$TEMP_DIR/straddle.out"
assert_contains "$TEMP_DIR/straddle.out.content" "BEARER REDACTED"
assert_contains "$TEMP_DIR/straddle.out.content" "Error? the final cause"
if grep -Fq "opaque" "$TEMP_DIR/straddle.out.content"; then
  fail "a fragment of a credential straddling the old cut reached the job log"
fi

# A credential straddling the new 1,000-byte cut. Redaction runs on the whole
# stderr first, so the cut never sees the credential; cutting first would
# leave "_credential_0123456789" with no scheme in front of it.
clip_file="$TEMP_DIR/clip.err"
printf '%s %s\n%s\n' "BEARER opaque_access_credential_0123456789" \
  "$(repeat_char 959 z)" "Error: the cause" > "$clip_file"
[ "$(tail -c 1000 "$clip_file" | head -c 22)" = "_credential_0123456789" ] \
  || fail "the fixture must straddle the 1,000-byte cut"
replay_stderr "$clip_file" "$TEMP_DIR/clip.out"
assert_contains "$TEMP_DIR/clip.out.content" "BEARER REDACTED"
if grep -Fq "credential_0123456789" "$TEMP_DIR/clip.out.content"; then
  fail "a fragment of a credential straddling the 1,000-byte cut reached the job log"
fi

# The last 10 lines only, after a note that earlier output was left out.
seq 1 30 | awk '{ printf "line %02d\n", $1 }' > "$TEMP_DIR/many-lines.err"
replay_stderr "$TEMP_DIR/many-lines.err" "$TEMP_DIR/many-lines.out"
[ "$(grep -c '^line ' "$TEMP_DIR/many-lines.out.content")" = "10" ] \
  || fail "expected exactly the last 10 lines of stderr"
[ "$(grep '^line ' "$TEMP_DIR/many-lines.out.content" | head -n 1)" = "line 21" ] \
  || fail "the kept lines must be the last ones"
[ "$(tail -n 1 "$TEMP_DIR/many-lines.out.content")" = "line 30" ] \
  || fail "the last stderr line must be printed last"
assert_contains "$TEMP_DIR/many-lines.out.content" "earlier stderr omitted"

# At most the last 1,000 bytes, even when fewer than 10 lines carry more.
printf '%s\n%s\n%s\n%s\n' "$(repeat_char 600 a)" "$(repeat_char 600 b)" \
  "$(repeat_char 600 c)" "Error: last line" > "$TEMP_DIR/long-lines.err"
replay_stderr "$TEMP_DIR/long-lines.err" "$TEMP_DIR/long-lines.out"
kept_bytes=$(grep -v 'earlier stderr omitted' "$TEMP_DIR/long-lines.out.content" \
  | tr -d '\n' | wc -c | tr -d '[:space:]')
[ "$kept_bytes" -le 1000 ] || fail "printed $kept_bytes bytes of stderr, more than 1,000"
[ "$kept_bytes" -ge 900 ] || fail "printed only $kept_bytes bytes of stderr"
[ "$(tail -n 1 "$TEMP_DIR/long-lines.out.content")" = "Error? last line" ] \
  || fail "the end of the stderr must be kept"
if grep -Fq "aaa" "$TEMP_DIR/long-lines.out.content"; then
  fail "bytes before the last 1,000 were printed"
fi

# A stderr larger than the 1 MiB read window still ends in its last lines.
seq 1 25000 | awk '{ printf "filler line %05d with padding to make it longer\n", $1 }' \
  > "$TEMP_DIR/huge.err"
[ "$(wc -c < "$TEMP_DIR/huge.err" | tr -d '[:space:]')" -gt 1048576 ] \
  || fail "the fixture must exceed the read window"
replay_stderr "$TEMP_DIR/huge.err" "$TEMP_DIR/huge.out"
[ "$(tail -n 1 "$TEMP_DIR/huge.out.content")" \
  = "filler line 25000 with padding to make it longer" ] \
  || fail "a stderr larger than the read window lost its end"
[ "$(cat "$fail_work/review.attempted")" = "2" ] || fail "expected two attempted calls"
[ "$(cat "$fail_work/review.completed")" = "0" ] || fail "expected no completed calls"
assert_contains "$fail_work/review.failures" "review call failed (exit 1"
assert_contains "$fail_work/review.md" "every review call failed"

# When every call failed, check-result fails the job (the sticky comment has
# already been posted by then).
if REVIEW_WORK_DIR="$fail_work" "$ROOT/scripts/check-result.sh" > "$TEMP_DIR/check.out"; then
  fail "check-result passed a run in which every call failed"
fi
assert_contains "$TEMP_DIR/check.out" "::error::every review call failed (2 of 2)"

# A partial failure warns but passes.
flaky_bin="$TEMP_DIR/flaky-bin"
mkdir -p "$flaky_bin"
cat > "$flaky_bin/copilot" <<'STUB'
#!/usr/bin/env bash
calls=$(cat "$STUB_CALLS_FILE" 2>/dev/null || echo 0)
calls=$((calls + 1))
echo "$calls" > "$STUB_CALLS_FILE"
if [ "$calls" -eq 1 ]; then
  echo "Error: rate limited" >&2
  exit 1
fi
echo "No issues found."
STUB
chmod +x "$flaky_bin/copilot"
PATH="$flaky_bin:$PATH" STUB_CALLS_FILE="$TEMP_DIR/flaky.calls" \
COPILOT_GITHUB_TOKEN=stub-token REVIEW_WORK_DIR="$fail_work" \
REVIEW_MODEL=stub-model GITHUB_ACTION_PATH="$ROOT" \
  "$ROOT/scripts/run-review.sh" > /dev/null
[ "$(cat "$fail_work/review.completed")" = "1" ] || fail "expected one completed call"
REVIEW_WORK_DIR="$fail_work" "$ROOT/scripts/check-result.sh" > "$TEMP_DIR/check.out" \
  || fail "check-result failed a partial review"
assert_contains "$TEMP_DIR/check.out" "::warning::1 of 2 review calls failed"

# A call that exits 0 with a blank reply reviewed nothing, so it is a failed
# call: listed in review.failures (the Incomplete banner) and not completed.
blank_bin="$TEMP_DIR/blank-bin"
mkdir -p "$blank_bin"
cat > "$blank_bin/copilot" <<'STUB'
#!/usr/bin/env bash
printf ' \n\t\n'
STUB
chmod +x "$blank_bin/copilot"
PATH="$blank_bin:$PATH" \
COPILOT_GITHUB_TOKEN=stub-token REVIEW_WORK_DIR="$fail_work" \
REVIEW_MODEL=stub-model GITHUB_ACTION_PATH="$ROOT" \
  "$ROOT/scripts/run-review.sh" > "$TEMP_DIR/blank-run.out"
[ "$(cat "$fail_work/review.completed")" = "0" ] || fail "a blank reply counted as a completed call"
assert_contains "$fail_work/review.failures" "returned an empty reply"
assert_contains "$fail_work/review.md" "every review call failed"
assert_contains "$TEMP_DIR/blank-run.out" "batch returned an empty reply"
if is_complete_clean_review "$fail_work"; then
  fail "a run of blank replies was reported as a clean review"
fi
if REVIEW_WORK_DIR="$fail_work" "$ROOT/scripts/check-result.sh" > /dev/null; then
  fail "check-result passed a run in which every reply was blank"
fi

# One blank reply next to a clean one is a partial failure.
half_blank_bin="$TEMP_DIR/half-blank-bin"
mkdir -p "$half_blank_bin"
cat > "$half_blank_bin/copilot" <<'STUB'
#!/usr/bin/env bash
calls=$(cat "$STUB_CALLS_FILE" 2>/dev/null || echo 0)
calls=$((calls + 1))
echo "$calls" > "$STUB_CALLS_FILE"
if [ "$calls" -eq 1 ]; then
  exit 0
fi
echo "No issues found."
STUB
chmod +x "$half_blank_bin/copilot"
PATH="$half_blank_bin:$PATH" STUB_CALLS_FILE="$TEMP_DIR/half-blank.calls" \
COPILOT_GITHUB_TOKEN=stub-token REVIEW_WORK_DIR="$fail_work" \
REVIEW_MODEL=stub-model GITHUB_ACTION_PATH="$ROOT" \
  "$ROOT/scripts/run-review.sh" > /dev/null
[ "$(cat "$fail_work/review.completed")" = "1" ] || fail "expected one completed call"
REVIEW_WORK_DIR="$fail_work" "$ROOT/scripts/check-result.sh" > "$TEMP_DIR/check.out" \
  || fail "check-result failed a partial review"
assert_contains "$TEMP_DIR/check.out" "::warning::1 of 2 review calls failed"

# No batches means nothing to review, which is not a failure.
empty_work="$TEMP_DIR/empty-work"
mkdir -p "$empty_work/batches"
: > "$empty_work/review-context.md"
PATH="$stub_bin:$PATH" \
COPILOT_GITHUB_TOKEN=stub-token REVIEW_WORK_DIR="$empty_work" \
REVIEW_MODEL=stub-model GITHUB_ACTION_PATH="$ROOT" \
  "$ROOT/scripts/run-review.sh" > /dev/null
REVIEW_WORK_DIR="$empty_work" "$ROOT/scripts/check-result.sh" > /dev/null \
  || fail "check-result failed a review with no batches"
assert_contains "$empty_work/review.md" "No issues found."

# Missing counts fail closed.
missing_work="$TEMP_DIR/missing-work"
mkdir -p "$missing_work"
if REVIEW_WORK_DIR="$missing_work" "$ROOT/scripts/check-result.sh" > /dev/null; then
  fail "check-result passed without call counts"
fi

# verify-landed.sh and post-comment.sh against a stand-in for `gh api` that
# serves fixtures from $STUB_DIR and runs each script's own --jq filter
# through the real jq, so the tests exercise the scripts' selection logic:
# `heads` holds one head SHA per read of the pull request (the last one
# repeats), `comments.json` the PR's issue comments, and `writes` logs every
# PATCH, DELETE and POST, keeping the last body written as `written-body`.
gh_bin="$TEMP_DIR/gh-bin"
mkdir -p "$gh_bin"
cat > "$gh_bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" != "api" ]; then
  echo "unexpected gh call: $*" >&2
  exit 1
fi
shift
method=GET
path=""
filter=""
body_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift 2 ;;
    --jq) filter=$2; shift 2 ;;
    --paginate) shift ;;
    -F|-f)
      case "$2" in body=@*) body_file=${2#body=@} ;; esac
      shift 2
      ;;
    *) path=$1; shift ;;
  esac
done
case "$method $path" in
  "GET repos/"*"/pulls/"*)
    reads=$(cat "$STUB_DIR/head.reads" 2>/dev/null || echo 0)
    reads=$((reads + 1))
    echo "$reads" > "$STUB_DIR/head.reads"
    head=$(sed -n "${reads}p" "$STUB_DIR/heads")
    [ -n "$head" ] || head=$(tail -n 1 "$STUB_DIR/heads")
    json=$(jq -cn --arg sha "$head" '{head: {sha: $sha}}')
    ;;
  "GET repos/"*"/issues/comments/"*)
    json=$(jq -c --argjson id "${path##*/}" '.[] | select(.id == $id)' "$STUB_DIR/comments.json")
    ;;
  "GET repos/"*"/issues/"*"/comments")
    json=$(cat "$STUB_DIR/comments.json")
    ;;
  "PATCH repos/"*|"DELETE repos/"*|"POST repos/"*)
    echo "$method $path" >> "$STUB_DIR/writes"
    if [ -n "$body_file" ]; then
      cp "$body_file" "$STUB_DIR/written-body"
    fi
    exit 0
    ;;
  *)
    echo "unexpected gh api call: $method $path" >&2
    exit 1
    ;;
esac
if [ -n "$filter" ]; then
  printf '%s\n' "$json" | jq -r "$filter"
else
  printf '%s\n' "$json"
fi
STUB
chmod +x "$gh_bin/gh"

verify_head=1111111111111111111111111111111111111111
other_head=2222222222222222222222222222222222222222
bot='github-actions[bot]'
sol=ai-code-review-sticky
astra=ai-code-review-sticky-astra

# usage: sticky_body <marker> <sha> <run> <attempt, or - for none> [findings]
sticky_body() {
  printf '%s\n' "<!-- $1 -->" "## AI code review (\`gpt-5.6-sol\` via Copilot CLI)" "" \
    "_Reviewed commit: \`$2\`_" "" "<!-- ai-code-review-run: $3 -->"
  if [ "$4" != "-" ]; then
    printf '%s\n' "<!-- ai-code-review-attempt: $4 -->"
  fi
  printf '%s\n' "<!-- ai-code-review-result: findings -->" "" "${5:-Severity: LOW}"
}

# A finding that quotes the Sol marker and a header.
# usage: quoted_sticky <sha> <run> <attempt>
quoted_sticky() {
  printf '%s\n' "Severity: LOW" "The diff adds these lines:" \
    "<!-- $sol -->" "_Reviewed commit: \`$1\`_" \
    "<!-- ai-code-review-run: $2 -->" "<!-- ai-code-review-attempt: $3 -->"
}

# usage: comment <id> <login> <body>
comment() {
  jq -cn --argjson id "$1" --arg login "$2" --arg body "$3" \
    '{id: $id, user: {login: $login}, body: $body}'
}

# Prints a new fixture directory.
# usage: gh_fixture <head reads, comma-separated> [comment JSON]...
gh_fixture() {
  local dir
  dir=$(mktemp -d "$TEMP_DIR/gh.XXXXXX")
  printf '%s\n' "$1" | tr ',' '\n' > "$dir/heads"
  shift
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" | jq -cs '.' > "$dir/comments.json"
  else
    printf '[]\n' > "$dir/comments.json"
  fi
  printf '%s\n' "$dir"
}

# usage: run_verify <fixture dir> [run attempt]
run_verify() {
  PATH="$gh_bin:$PATH" STUB_DIR="$1" \
  GH_TOKEN=stub REPOSITORY=shariqh/example PR_NUMBER=7 \
  HEAD_SHA="$verify_head" RUN_ID=4242 RUN_ATTEMPT="${2:-1}" \
  COMMENT_MARKER="$sol" GITHUB_ACTION_PATH="$ROOT" \
    "$ROOT/scripts/verify-landed.sh" > "$1/verify.out" 2>&1
}

# usage: expect_verify_failure <label> <message> <fixture dir> [run attempt]
expect_verify_failure() {
  if run_verify "$3" "${4:-1}"; then
    fail "verify-landed accepted $1"
  fi
  assert_contains "$3/verify.out" "$2"
}

fixture=$(gh_fixture "$verify_head" \
  "$(comment 12 "$bot" "$(sticky_body "$sol" "$other_head" 4242 1)")" \
  "$(comment 55 "$bot" "$(sticky_body "$sol" "$verify_head" 4242 1)")")
run_verify "$fixture" || fail "verify-landed rejected a sticky that covers the head"
assert_contains "$fixture/verify.out" \
  "verified: sticky comment 55 covers head $verify_head from run 4242 attempt 1"

fixture=$(gh_fixture "$verify_head" \
  "$(comment 55 "$bot" "$(sticky_body "$sol" "$verify_head" 4242 2)")")
run_verify "$fixture" 2 || fail "verify-landed rejected a re-run's own sticky"

current_sol=$(comment 55 "$bot" "$(sticky_body "$sol" "$verify_head" 4242 1)")
expect_verify_failure "a head that moved during the run" "PR head moved during this run" \
  "$(gh_fixture "$other_head,$verify_head" "$current_sol")"
expect_verify_failure "a head that moved during the check" "moved while this check ran" \
  "$(gh_fixture "$verify_head,$other_head" "$current_sol")"
expect_verify_failure "a sticky for another commit" "does not reflect this run" \
  "$(gh_fixture "$verify_head" \
    "$(comment 55 "$bot" "$(sticky_body "$sol" "$other_head" 4242 1)")")"
expect_verify_failure "a sticky from another run" "does not reflect this run" \
  "$(gh_fixture "$verify_head" \
    "$(comment 55 "$bot" "$(sticky_body "$sol" "$verify_head" 4241 1)")")"

# A re-run must not certify the attempt before it, or a sticky written before
# attempts were recorded.
expect_verify_failure "the previous attempt's sticky" "does not reflect this run" \
  "$(gh_fixture "$verify_head" "$current_sol")" 2
expect_verify_failure "a sticky without an attempt" "does not reflect this run" \
  "$(gh_fixture "$verify_head" \
    "$(comment 55 "$bot" "$(sticky_body "$sol" "$verify_head" 4242 -)")")"

# The sticky is the bot comment whose first line is the marker. Another
# reviewer's sticky that quotes it, or anyone else's comment that starts with
# it, is not that sticky.
quoting_astra=$(comment 60 "$bot" \
  "$(sticky_body "$astra" "$verify_head" 4242 1 "$(quoted_sticky "$verify_head" 4242 1)")")
expect_verify_failure "another reviewer's sticky quoting the marker" "no sticky comment" \
  "$(gh_fixture "$verify_head" "$quoting_astra" \
    "$(comment 70 someone "$(sticky_body "$sol" "$verify_head" 4242 1)")")"
expect_verify_failure "a stale sticky with a newer quoting one" "does not reflect this run" \
  "$(gh_fixture "$verify_head" \
    "$(comment 55 "$bot" "$(sticky_body "$sol" "$verify_head" 4241 1)")" "$quoting_astra")"

# The commit, run and attempt come from the header, never from lines quoted
# below it, and a body with no end to its header has none.
expect_verify_failure "header lines quoted in the findings" "does not reflect this run" \
  "$(gh_fixture "$verify_head" \
    "$(comment 55 "$bot" \
      "$(sticky_body "$sol" "$other_head" 4241 1 "$(quoted_sticky "$verify_head" 4242 1)")")")"
expect_verify_failure "a sticky with no header end" "does not reflect this run" \
  "$(gh_fixture "$verify_head" \
    "$(comment 55 "$bot" "$(printf '%s\n' "<!-- $sol -->" \
      "_Reviewed commit: \`$verify_head\`_" "<!-- ai-code-review-run: 4242 -->" \
      "<!-- ai-code-review-attempt: 1 -->")")")"

# post-comment.sh writes only this reviewer's stickies, never another
# reviewer's sticky that quotes the marker or someone's comment starting with
# it, and its header carries the commit, run and attempt.
post_work="$TEMP_DIR/post-work"
mkdir -p "$post_work"
printf 'Severity: LOW\nA finding.\n' > "$post_work/review.md"
: > "$post_work/review.failures"
: > "$post_work/overflow.note"
human_quote=$(comment 31 someone "$(printf '%s\n' "<!-- $sol -->" "A human comment.")")

# usage: run_post <fixture dir> [work dir]
run_post() {
  PATH="$gh_bin:$PATH" STUB_DIR="$1" \
  GH_TOKEN=stub REPOSITORY=shariqh/example PR_NUMBER=7 \
  HEAD_SHA="$verify_head" RUN_ID=777 RUN_ATTEMPT=3 REVIEW_MODEL=gpt-5.6-sol \
  REVIEW_WORK_DIR="${2:-$post_work}" COMMENT_MARKER="$sol" GITHUB_ACTION_PATH="$ROOT" \
    "$ROOT/scripts/post-comment.sh" > "$1/post.out" 2>&1
}

fixture=$(gh_fixture "$verify_head" "$quoting_astra" "$human_quote")
run_post "$fixture" || fail "post-comment.sh failed: $(cat "$fixture/post.out")"
[ "$(cat "$fixture/writes")" = "POST repos/shariqh/example/issues/7/comments" ] \
  || fail "expected one new sticky, got: $(cat "$fixture/writes")"
[ "$(head -n 1 "$fixture/written-body")" = "<!-- $sol -->" ] \
  || fail "a sticky's first line must be its marker"
[ "$(sticky_header_fields < "$fixture/written-body")" = "$verify_head 777 3" ] \
  || fail "the sticky header must carry the commit, run and attempt"

# With review-scope full there is no scope record, and the comment is exactly
# what it was before review-scope existed.
printf '%s\n' "<!-- $sol -->" "## AI code review (\`gpt-5.6-sol\` via Copilot CLI)" "" \
  "_Reviewed commit: \`$verify_head\`_" "" "<!-- ai-code-review-run: 777 -->" \
  "<!-- ai-code-review-attempt: 3 -->" "<!-- ai-code-review-result: findings -->" "" \
  "Severity: LOW" "A finding." "" \
  "_Automated, independent-model review (updated each push). Not a substitute for human judgment._" \
  > "$TEMP_DIR/full-scope-sticky.md"
cmp -s "$TEMP_DIR/full-scope-sticky.md" "$fixture/written-body" \
  || fail "a full-scope sticky changed: $(diff "$TEMP_DIR/full-scope-sticky.md" "$fixture/written-body")"

fixture=$(gh_fixture "$verify_head" "$quoting_astra" "$human_quote" \
  "$(comment 35 "$bot" "$(sticky_body "$sol" "$other_head" 700 1)")" \
  "$(comment 40 "$bot" "$(sticky_body "$sol" "$other_head" 701 1)")")
run_post "$fixture" || fail "post-comment.sh failed: $(cat "$fixture/post.out")"
[ "$(sort "$fixture/writes" | tr '\n' ' ')" \
  = "DELETE repos/shariqh/example/issues/comments/35 PATCH repos/shariqh/example/issues/comments/40 " ] \
  || fail "expected sticky 40 updated and duplicate 35 deleted, got: $(cat "$fixture/writes")"

fixture=$(gh_fixture "$other_head" "$quoting_astra")
run_post "$fixture" || fail "post-comment.sh failed: $(cat "$fixture/post.out")"
[ ! -e "$fixture/writes" ] || fail "a superseded run wrote to the PR: $(cat "$fixture/writes")"
assert_contains "$fixture/post.out" "stale review run"

# review-scope since-last-review, end to end. A round runs last-review.sh
# against a pull request whose sticky is the previous round's, then
# prepare-review.sh, run-review.sh and post-comment.sh, and the sticky that
# writes is what the next round reads. The pull request adds a file named `*`
# (a glob, were the paths not literal) and one with a newline in its name,
# then merges a base-branch change to main.txt.
scope_repo="$TEMP_DIR/scope-repo"
git init -q "$scope_repo"

# usage: scope_git <git argument>...
scope_git() {
  git -C "$scope_repo" -c user.email=test@test -c user.name=test "$@"
}

# Appends <line> to <file>, commits everything, and prints the commit.
# usage: scope_commit <file> <line>
scope_commit() {
  printf '%s\n' "$2" >> "$scope_repo/$1"
  scope_git add -A
  scope_git commit -q -m "$2"
  scope_git rev-parse HEAD
}

mkdir -p "$scope_repo/.github"
printf 'Base-branch context: early returns are intentional.\n' \
  > "$scope_repo/.github/ai-review-context.md"
printf 'a\n' > "$scope_repo/a.txt"
printf 'b\n' > "$scope_repo/b.txt"
scope_base=$(scope_commit main.txt "main")
printf 'star\n' > "$scope_repo/*"
printf 'odd\n' > "$scope_repo/$(printf 'line\nbreak.txt')"
head1=$(scope_commit a.txt "first round")
head2=$(scope_commit b.txt "second round")
scope_git checkout -q "$scope_base"
main1=$(scope_commit main.txt "base branch change")
scope_git update-ref refs/remotes/origin/main "$main1"
scope_git checkout -q "$head2"
scope_git merge -q --no-edit "$main1"
head3=$(scope_git rev-parse HEAD)
head4=$(scope_commit a.txt "after the merge")
scope_git checkout -q "$head1"
head2b=$(scope_commit b.txt "rewritten second round")

finding_bin="$TEMP_DIR/finding-bin"
down_bin="$TEMP_DIR/down-bin"
mkdir -p "$finding_bin" "$down_bin"
printf '%s\n' '#!/usr/bin/env bash' "printf 'Severity: LOW\\nA finding.\\n'" \
  > "$finding_bin/copilot"
printf '%s\n' '#!/usr/bin/env bash' 'echo "Error: down" >&2' 'exit 1' > "$down_bin/copilot"
chmod +x "$finding_bin/copilot" "$down_bin/copilot"

# Runs prepare-review.sh with review-scope since-last-review into <work dir>,
# logging to <work dir>.log. By default the last review is a complete, clean
# one of head1; later NAME=value arguments override that or anything else.
# usage: prepare_since <work dir> <head> [NAME=value]...
prepare_since() {
  local work=$1 head=$2
  shift 2
  env BASE_SHA="$scope_base" BASE_REF=main HEAD_SHA="$head" \
    REVIEW_REPO_DIR="$scope_repo" REVIEW_WORK_DIR="$work" GITHUB_ACTION_PATH="$ROOT" \
    CONTEXT_FILE=.github/ai-review-context.md REVIEW_SCOPE=since-last-review \
    LAST_REVIEWED_SHA="$head1" LAST_FULL_REVIEW_SHA="$head1" LAST_REVIEW_RESULT=clean \
    "$@" "$ROOT/scripts/prepare-review.sh" > "$work.log" 2>&1
}

# usage: run_last_review <fixture dir>
run_last_review() {
  : > "$1/last-review.out"
  PATH="$gh_bin:$PATH" STUB_DIR="$1" GH_TOKEN=stub REPOSITORY=shariqh/example \
  PR_NUMBER=7 COMMENT_MARKER="$sol" GITHUB_ACTION_PATH="$ROOT" \
  GITHUB_OUTPUT="$1/last-review.out" \
    "$ROOT/scripts/last-review.sh" > "$1/last-review.log" 2>&1
}

# One review round at <head>, on a pull request whose only comment is the
# sticky in <sticky file> (- for none). Leaves in <dir>: last-review.out and
# .log, work/ (and work.log) and sticky.md, the sticky the round wrote.
# Later NAME=value arguments go to prepare-review.sh.
# usage: scope_round <dir> <head> <copilot bin> <sticky file, or -> [NAME=value]...
scope_round() {
  local dir=$1 head=$2 bin=$3 sticky=$4 fixture
  shift 4
  mkdir -p "$dir"
  if [ "$sticky" = - ]; then
    fixture=$(gh_fixture "$head")
  else
    fixture=$(gh_fixture "$head" "$(comment 50 "$bot" "$(cat "$sticky")")")
  fi
  run_last_review "$fixture" || fail "last-review.sh failed: $(cat "$fixture/last-review.log")"
  cp "$fixture/last-review.out" "$fixture/last-review.log" "$dir/"
  prepare_since "$dir/work" "$head" \
    LAST_REVIEWED_SHA="$(sed -n 's/^reviewed-commit=//p' "$dir/last-review.out")" \
    LAST_FULL_REVIEW_SHA="$(sed -n 's/^full-review=//p' "$dir/last-review.out")" \
    LAST_REVIEW_RESULT="$(sed -n 's/^result=//p' "$dir/last-review.out")" \
    "$@" || fail "prepare-review.sh failed: $(cat "$dir/work.log")"
  PATH="$bin:$PATH" COPILOT_GITHUB_TOKEN=stub-token REVIEW_WORK_DIR="$dir/work" \
  REVIEW_MODEL=gpt-5.6-sol GITHUB_ACTION_PATH="$ROOT" \
    "$ROOT/scripts/run-review.sh" > "$dir/run.log" 2>&1 \
    || fail "run-review.sh failed: $(cat "$dir/run.log")"
  PATH="$gh_bin:$PATH" STUB_DIR="$fixture" \
  GH_TOKEN=stub REPOSITORY=shariqh/example PR_NUMBER=7 HEAD_SHA="$head" \
  RUN_ID=900 RUN_ATTEMPT=1 REVIEW_MODEL=gpt-5.6-sol REVIEW_WORK_DIR="$dir/work" \
  COMMENT_MARKER="$sol" GITHUB_ACTION_PATH="$ROOT" \
    "$ROOT/scripts/post-comment.sh" > "$dir/post.log" 2>&1 \
    || fail "post-comment.sh failed: $(cat "$dir/post.log")"
  cp "$fixture/written-body" "$dir/sticky.md"
}

# usage: expect_scope_line <sticky file> <since> <head> <full review>
expect_scope_line() {
  grep -Fxq "> **Incremental review** of \`$2..$3\`; the full review was at \`$4\`." "$1" \
    || fail "$1 lacks the scope line for $2..$3 with the full review at $4"
}

# usage: expect_full_review <round dir> <head>
expect_full_review() {
  git -C "$scope_repo" diff "$scope_base...$2" > "$1/full.diff"
  cmp -s "$1/full.diff" "$1/work/pr.diff" || fail "$1 did not review the whole pull request"
  [ ! -e "$1/work/scope.since" ] || fail "$1 is a full review, not an incremental one"
  if grep -Fq "Incremental review" "$1/sticky.md"; then
    fail "a full review's sticky must add no visible line"
  fi
  [ "$(sticky_scope_fields < "$1/sticky.md")" = "clean $2 complete" ] \
    || fail "a full review must be the one later runs build on"
}

# A first run reviews the whole pull request, and its sticky records that.
r1="$TEMP_DIR/round1"
scope_round "$r1" "$head1" "$stub_bin" -
assert_contains "$r1/last-review.log" \
  "review scope: full review, because this reviewer has not reviewed this pull request yet"
[ ! -s "$r1/last-review.out" ] || fail "a first run handed on a previous head"
expect_full_review "$r1" "$head1"
if grep -Fiq "incremental" "$r1/work/prompt.txt"; then
  fail "a full review's prompt must not mention an incremental review"
fi
[ "$(sticky_header_fields < "$r1/sticky.md")" = "$head1 900 1" ] \
  || fail "a full review's sticky must name its head"

# The second run reviews only head1..head2, says so in the prompt, and keeps
# the PR's file list (quoted, one name per line) and the maintainer context.
r2="$TEMP_DIR/round2"
scope_round "$r2" "$head2" "$stub_bin" "$r1/sticky.md"
[ "$(cat "$r2/last-review.out")" \
  = "$(printf '%s\n' "reviewed-commit=$head1" "full-review=$head1" "result=clean")" ] \
  || fail "unexpected last review: $(cat "$r2/last-review.out")"
git -C "$scope_repo" diff "$head1" "$head2" > "$r2/since.diff"
cmp -s "$r2/since.diff" "$r2/work/pr.diff" || fail "the second run must review only head1..head2"
assert_contains "$r2/work/pr.diff" "+second round"
if grep -Fq "first round" "$r2/work/pr.diff"; then
  fail "the second run reviewed a change the first run already covered"
fi
prompt="$r2/work/prompt.txt"
assert_contains "$prompt" "This is an incremental review of the commits since $head1."
assert_contains "$prompt" "Base-branch context: early returns are intentional."
for listed in '- *' '- a.txt' '- b.txt' '- "line\nbreak.txt"'; do
  grep -Fxq -- "$listed" "$prompt" || fail "the prompt's file list lacks: $listed"
done
note_line=$(grep -n '^This is an incremental review' "$prompt" | cut -d: -f1)
ctx_line=$(grep -n -- '^--- BEGIN REPO REVIEW CONTEXT ---$' "$prompt" | cut -d: -f1)
files_line=$(grep -n -- '^--- BEGIN PULL REQUEST FILES ---$' "$prompt" | cut -d: -f1)
diff_line=$(grep -n -- '^--- BEGIN DIFF ---$' "$prompt" | cut -d: -f1)
[ "$note_line" -lt "$ctx_line" ] && [ "$ctx_line" -lt "$files_line" ] \
  && [ "$files_line" -lt "$diff_line" ] \
  || fail "the prompt must run: incremental note, context, file list, diff"

# Its sticky keeps the head as the reviewed commit and adds the scope line.
grep -Fxq "_Reviewed commit: \`$head2\`_" "$r2/sticky.md" \
  || fail "an incremental review must keep the Reviewed commit line"
[ "$(sticky_header_fields < "$r2/sticky.md")" = "$head2 900 1" ] \
  || fail "an incremental review's sticky must name its head"
expect_scope_line "$r2/sticky.md" "$head1" "$head2" "$head1"
[ "$(sticky_scope_fields < "$r2/sticky.md")" = "clean $head1 complete" ] \
  || fail "an incremental review must carry the full review forward"
fixture=$(gh_fixture "$head2" "$(comment 50 "$bot" "$(cat "$r2/sticky.md")")")
PATH="$gh_bin:$PATH" STUB_DIR="$fixture" GH_TOKEN=stub REPOSITORY=shariqh/example \
PR_NUMBER=7 HEAD_SHA="$head2" RUN_ID=900 RUN_ATTEMPT=1 COMMENT_MARKER="$sol" \
GITHUB_ACTION_PATH="$ROOT" "$ROOT/scripts/verify-landed.sh" > "$fixture/verify.out" 2>&1 \
  || fail "verify-landed rejected an incremental sticky: $(cat "$fixture/verify.out")"

# A merge of the base branch into the pull request stays out of the next
# incremental diff, whether the base comes from the base branch's tip or from
# an up-to-date BASE_SHA. Its change to main.txt is in the plain diff since
# head2, and a glob `*` would have matched it.
r3="$TEMP_DIR/round3"
scope_round "$r3" "$head4" "$stub_bin" "$r2/sticky.md"
git -C "$scope_repo" diff "$head2" "$head4" > "$r3/plain.diff"
assert_contains "$r3/plain.diff" "+base branch change"
assert_contains "$r3/work/pr.diff" "+after the merge"
if grep -Fq "base branch change" "$r3/work/pr.diff"; then
  fail "a base-branch merge was reviewed as the pull request's own change"
fi
if grep -Fxq -- "- main.txt" "$r3/work/prompt.txt"; then
  fail "a base-branch file was listed as one the pull request changes"
fi
expect_scope_line "$r3/sticky.md" "$head2" "$head4" "$head1"
r3_sha="$TEMP_DIR/round3-base-sha"
scope_round "$r3_sha" "$head4" "$stub_bin" "$r2/sticky.md" BASE_SHA="$main1" BASE_REF=
cmp -s "$r3/work/pr.diff" "$r3_sha/work/pr.diff" \
  || fail "the incremental diff depends on where the base came from"

# An empty incremental diff calls no model and says so, keeping the last
# review's result: clean after a clean review, findings after findings.
r3_empty="$TEMP_DIR/round3-empty"
scope_round "$r3_empty" "$head3" "$stub_bin" "$r2/sticky.md"
[ ! -s "$r3_empty/work/pr.diff" ] || fail "a base-branch merge alone left an incremental diff"
[ "$(cat "$r3_empty/work/review.attempted")" = "0" ] \
  || fail "an empty incremental diff called the model"
REVIEW_WORK_DIR="$r3_empty/work" "$ROOT/scripts/check-result.sh" > /dev/null \
  || fail "check-result failed an empty incremental review"
assert_contains "$r3_empty/sticky.md" \
  "_Nothing new to review: the files this pull request changes are the same as at \`$head2\`, and the review of that commit found no issues._"
if grep -Fq "No issues found." "$r3_empty/sticky.md"; then
  fail "an empty incremental diff was reported as a clean review"
fi
expect_scope_line "$r3_empty/sticky.md" "$head2" "$head3" "$head1"
[ "$(sticky_scope_fields < "$r3_empty/sticky.md")" = "clean $head1 complete" ] \
  || fail "an empty incremental diff must keep a clean result"
r2_findings="$TEMP_DIR/round2-findings"
scope_round "$r2_findings" "$head2" "$finding_bin" "$r1/sticky.md"
[ "$(sticky_scope_fields < "$r2_findings/sticky.md")" = "findings $head1 complete" ] \
  || fail "a complete review with findings must be recorded as complete"
r3_empty_findings="$TEMP_DIR/round3-empty-findings"
scope_round "$r3_empty_findings" "$head3" "$stub_bin" "$r2_findings/sticky.md"
assert_contains "$r3_empty_findings/sticky.md" \
  "so the findings of the review of that commit still apply"
[ "$(sticky_scope_fields < "$r3_empty_findings/sticky.md")" = "findings $head1 complete" ] \
  || fail "an empty incremental diff must keep a findings result"

# Fallback to a full review after a force-push, a failed review or a partial
# one. A full review starts a new chain: later runs name it as the full one.
r_force="$TEMP_DIR/round-force-push"
scope_round "$r_force" "$head2b" "$stub_bin" "$r2/sticky.md"
assert_contains "$r_force/work.log" \
  "review scope: full review, because the last reviewed commit $head2 is not an ancestor of $head2b, as after a force-push or rebase"
expect_full_review "$r_force" "$head2b"
r_down="$TEMP_DIR/round-down"
scope_round "$r_down" "$head2" "$down_bin" "$r1/sticky.md"
[ "$(sticky_scope_fields < "$r_down/sticky.md")" = "findings $head1 incomplete" ] \
  || fail "a review whose calls failed must be recorded as incomplete"
r_partial="$TEMP_DIR/round-partial"
scope_round "$r_partial" "$head2" "$stub_bin" "$r1/sticky.md" FILE_MAX_BYTES=40
assert_contains "$r_partial/sticky.md" "**Partial coverage**"
[ "$(sticky_scope_fields < "$r_partial/sticky.md")" = "findings $head1 incomplete" ] \
  || fail "a partial review must be recorded as incomplete"
for previous in "$r_down" "$r_partial"; do
  after="$previous-after"
  scope_round "$after" "$head4" "$stub_bin" "$previous/sticky.md"
  assert_contains "$after/last-review.log" \
    "review scope: full review, because the last review, of $head2, was incomplete"
  expect_full_review "$after" "$head4"
done

# A sticky that cannot be built on means a full review: an unreadable comment
# list; a sticky from a run without since-last-review, or one whose scope
# lines are only quoted below the header; a malformed header; another
# reviewer's sticky quoting the marker, or someone else's comment; and a
# newer sticky without scope lines next to an older one with them.
# usage: scope_sticky_body <marker> <sha> <full review> <coverage> <result> [findings]
scope_sticky_body() {
  printf '%s\n' "<!-- $1 -->" "## AI code review (\`gpt-5.6-sol\` via Copilot CLI)" "" \
    "_Reviewed commit: \`$2\`_" "" "<!-- ai-code-review-run: 900 -->" \
    "<!-- ai-code-review-attempt: 1 -->" "<!-- ai-code-review-full-review: $3 -->" \
    "<!-- ai-code-review-coverage: $4 -->" "<!-- ai-code-review-result: $5 -->" "" \
    "${6:-No issues found.}"
}

# usage: expect_no_last_review <label> <reason> <fixture dir>
expect_no_last_review() {
  run_last_review "$3" || fail "last-review.sh failed on $1: $(cat "$3/last-review.log")"
  [ ! -s "$3/last-review.out" ] || fail "last-review.sh built on $1"
  assert_contains "$3/last-review.log" "review scope: full review, because $2"
}

fixture=$(gh_fixture "$head2" \
  "$(comment 50 "$bot" "$(scope_sticky_body "$sol" "$head2" "$head1" complete findings)")")
run_last_review "$fixture" || fail "last-review.sh failed: $(cat "$fixture/last-review.log")"
[ "$(cat "$fixture/last-review.out")" \
  = "$(printf '%s\n' "reviewed-commit=$head2" "full-review=$head1" "result=findings")" ] \
  || fail "a valid sticky was not built on: $(cat "$fixture/last-review.log")"

broken=$(gh_fixture "$head2")
printf 'not json\n' > "$broken/comments.json"
expect_no_last_review "an unreadable comment list" \
  "this reviewer's sticky comment could not be read" "$broken"
cannot_build="sticky comment 50 records no review that an incremental review can build on"
quoted_scope=$(printf '%s\n' "<!-- ai-code-review-full-review: $head1 -->" \
  "<!-- ai-code-review-coverage: complete -->")
case_number=0
for case_body in \
  "$(sticky_body "$sol" "$head1" 900 1)" \
  "$(sticky_body "$sol" "$head1" 900 1 "$quoted_scope")" \
  "$(scope_sticky_body "$sol" "$head1" "$head1" complete clean | grep -v 'ai-code-review-result')" \
  "$(scope_sticky_body "$sol" "${head1:0:12}" "$head1" complete clean)" \
  "$(scope_sticky_body "$sol" "$(printf '%s' "$head1" | tr 'a-f' 'A-F')" "$head1" complete clean)" \
  "$(scope_sticky_body "$sol" "$head1" "${head1:0:12}" complete clean)" \
  "$(scope_sticky_body "$sol" "$head1" "$head1" partly clean)" \
  "$(scope_sticky_body "$sol" "$head1" "$head1" complete maybe)"; do
  case_number=$((case_number + 1))
  expect_no_last_review "unusable sticky $case_number" "$cannot_build" \
    "$(gh_fixture "$head2" "$(comment 50 "$bot" "$case_body")")"
done
expect_no_last_review "another reviewer's quoting sticky or a non-bot comment" \
  "this reviewer has not reviewed this pull request yet" \
  "$(gh_fixture "$head2" \
    "$(comment 60 "$bot" "$(scope_sticky_body "$astra" "$head1" "$head1" complete clean \
      "$(scope_sticky_body "$sol" "$head1" "$head1" complete clean)")")" \
    "$(comment 70 someone "$(scope_sticky_body "$sol" "$head1" "$head1" complete clean)")")"
expect_no_last_review "a newer sticky without scope lines" \
  "sticky comment 45 records no review that an incremental review can build on" \
  "$(gh_fixture "$head2" \
    "$(comment 40 "$bot" "$(scope_sticky_body "$sol" "$head1" "$head1" complete clean)")" \
    "$(comment 45 "$bot" "$(sticky_body "$sol" "$head1" 900 1)")")"

# prepare-review.sh checks what last-review.sh hands it, too.
for bad_last in "LAST_REVIEWED_SHA=$head1~1" "LAST_REVIEWED_SHA=$head1$(printf '\nx')" \
  LAST_FULL_REVIEW_SHA= LAST_REVIEW_RESULT=maybe; do
  prepare_since "$TEMP_DIR/bad-last" "$head2" "$bad_last" \
    || fail "prepare-review.sh failed: $(cat "$TEMP_DIR/bad-last.log")"
  assert_contains "$TEMP_DIR/bad-last.log" \
    "review scope: full review, because the last review's details are malformed"
  [ ! -e "$TEMP_DIR/bad-last/scope.since" ] || fail "prepare-review.sh built on $bad_last"
done

# A last reviewed commit the checkout lacks is fetched from origin once; if it
# then exists but is not an ancestor, or cannot be fetched, the review is full.
scope_origin="$TEMP_DIR/scope-origin.git"
elsewhere_repo="$TEMP_DIR/elsewhere"
git init -q --bare "$scope_origin"
git init -q "$elsewhere_repo"
git -C "$elsewhere_repo" -c user.email=test@test -c user.name=test \
  commit -q --allow-empty -m elsewhere
elsewhere=$(git -C "$elsewhere_repo" rev-parse HEAD)
git -C "$elsewhere_repo" push -q "$scope_origin" HEAD:refs/heads/elsewhere
scope_git remote add origin "$scope_origin"
if scope_git cat-file -e "$elsewhere^{commit}" 2>/dev/null; then
  fail "the fetch fixture's commit must start out missing"
fi
prepare_since "$TEMP_DIR/fetched" "$head2" LAST_REVIEWED_SHA="$elsewhere" \
  || fail "prepare-review.sh failed: $(cat "$TEMP_DIR/fetched.log")"
scope_git cat-file -e "$elsewhere^{commit}" || fail "the missing commit was not fetched"
assert_contains "$TEMP_DIR/fetched.log" \
  "the last reviewed commit $elsewhere is not an ancestor of $head2"
missing_sha=0123456789abcdef0123456789abcdef01234567
prepare_since "$TEMP_DIR/unfetchable" "$head2" LAST_REVIEWED_SHA="$missing_sha" \
  || fail "prepare-review.sh failed: $(cat "$TEMP_DIR/unfetchable.log")"
assert_contains "$TEMP_DIR/unfetchable.log" \
  "review scope: full review, because the last reviewed commit $missing_sha is not in the repository"
git -C "$scope_repo" diff "$scope_base...$head2" > "$TEMP_DIR/unfetchable.full.diff"
cmp -s "$TEMP_DIR/unfetchable.full.diff" "$TEMP_DIR/unfetchable/pr.diff" \
  || fail "an unfetchable last review must mean a full review"

# A rename since the last review stays a rename, even of a file the pull
# request had not touched before: both of its sides are in the path list.
scope_git checkout -q "$head4"
scope_git mv main.txt moved.txt
scope_git commit -q -m "move main.txt"
head5=$(scope_git rev-parse HEAD)
prepare_since "$TEMP_DIR/renamed" "$head5" LAST_REVIEWED_SHA="$head4" \
  || fail "prepare-review.sh failed: $(cat "$TEMP_DIR/renamed.log")"
assert_contains "$TEMP_DIR/renamed/pr.diff" "rename from main.txt"
assert_contains "$TEMP_DIR/renamed/pr.diff" "rename to moved.txt"

# With no file of the pull request's own on either side (here the head is a
# base-branch commit), the incremental diff is empty, not every file's.
prepare_since "$TEMP_DIR/no-files" "$main1" LAST_REVIEWED_SHA="$scope_base" \
  || fail "prepare-review.sh failed: $(cat "$TEMP_DIR/no-files.log")"
[ ! -s "$TEMP_DIR/no-files/pr.diff" ] || fail "an empty path list diffed every file"
assert_contains "$TEMP_DIR/no-files/scope.files" "(none: the pull request no longer changes any file)"

# The prompt's file list is bounded.
prepare_since "$TEMP_DIR/list-cap" "$head2" FILE_LIST_MAX_BYTES=12 \
  || fail "prepare-review.sh failed: $(cat "$TEMP_DIR/list-cap.log")"
[ "$(cat "$TEMP_DIR/list-cap/scope.files")" \
  = "$(printf '%s\n' '- *' '- a.txt' '- [2 more not listed]')" ] \
  || fail "unexpected bounded file list: $(cat "$TEMP_DIR/list-cap/scope.files")"

# The scope record's values reach the comment and the prompt, so
# post-comment.sh and run-review.sh refuse one that prepare-review.sh could
# not have written: a malformed or missing full review, since or previous
# result. run-review.sh reads only the last two.
# usage: scope_case <full review, or - for none> <since> <previous result>
scope_case() {
  local work
  work=$(mktemp -d "$TEMP_DIR/scope-case.XXXXXX")
  mkdir -p "$work/batches"
  cp "$post_work/review.md" "$post_work/review.failures" "$post_work/overflow.note" "$work/"
  printf 'diff --git a/a.txt b/a.txt\n+a\n' > "$work/batches/batch_000.diff"
  if [ "$1" != - ]; then
    printf '%s\n' "$1" > "$work/scope.full-review"
  fi
  printf '%s\n' "$2" > "$work/scope.since"
  printf '%s\n' "$3" > "$work/scope.previous-result"
  printf '%s\n' "$work"
}

for scope in "not-a-sha $head1 clean" "- $head1 clean" "$head1 HEAD~1 clean" \
  "$head1 $head1 maybe"; do
  read -r scope_full scope_since scope_result <<< "$scope"
  work=$(scope_case "$scope_full" "$scope_since" "$scope_result")
  fixture=$(gh_fixture "$verify_head")
  if run_post "$fixture" "$work"; then
    fail "post-comment.sh accepted the scope record: $scope"
  fi
  assert_contains "$fixture/post.out" "::error::"
  [ ! -e "$fixture/writes" ] || fail "a malformed scope record reached the pull request"
  if [ "$scope_full" = "$head1" ]; then
    if PATH="$stub_bin:$PATH" COPILOT_GITHUB_TOKEN=stub-token REVIEW_WORK_DIR="$work" \
      REVIEW_MODEL=stub-model GITHUB_ACTION_PATH="$ROOT" \
      "$ROOT/scripts/run-review.sh" > "$work/run.out" 2>&1; then
      fail "run-review.sh accepted the scope record: $scope"
    fi
    assert_contains "$work/run.out" \
      "::error::the incremental review scope recorded by prepare-review.sh is malformed"
  fi
done

install_line=$(grep -n 'npm install --global --ignore-scripts' "$ROOT/action.yml" | cut -d: -f1)
checkout_line=$(grep -n 'name: Check out pull request' "$ROOT/action.yml" | cut -d: -f1)
[ "$install_line" -lt "$checkout_line" ] || fail "Copilot CLI must be installed before PR checkout"
assert_contains "$ROOT/action.yml" "NPM_CONFIG_USERCONFIG: /dev/null"
assert_contains "$ROOT/action.yml" "working-directory: \${{ runner.temp }}"
assert_contains "$ROOT/action.yml" "path: .ai-code-review-pr-"
assert_contains "$ROOT/examples/ai-code-review.yml" "pull_request_target:"

# The sticky comment is posted before the job is failed or verified, and the
# workspace is cleaned last.
post_line=$(grep -n 'name: Post sticky review comment' "$ROOT/action.yml" | cut -d: -f1)
result_line=$(grep -n 'name: Fail when every review call failed' "$ROOT/action.yml" | cut -d: -f1)
verify_line=$(grep -n "name: Verify the review landed on this run's head" "$ROOT/action.yml" | cut -d: -f1)
clean_line=$(grep -n 'name: Clean review workspace' "$ROOT/action.yml" | cut -d: -f1)
[ "$post_line" -lt "$result_line" ] && [ "$result_line" -lt "$verify_line" ] \
  && [ "$verify_line" -lt "$clean_line" ] \
  || fail "action steps must run post, result check, verify, then cleanup"

# review-scope defaults to full, and only since-last-review reads the sticky,
# before the batches are built.
assert_contains "$ROOT/action.yml" "REVIEW_SCOPE: \${{ inputs.review-scope }}"
assert_contains "$ROOT/action.yml" \
  "if: steps.guard.outputs.skip == 'false' && inputs.review-scope == 'since-last-review'"
[ "$(grep -A7 '^  review-scope:$' "$ROOT/action.yml" | grep -c '^    default: full$')" = "1" ] \
  || fail "the action's review-scope must default to full"
last_review_line=$(grep -n "name: Find this reviewer's last review" "$ROOT/action.yml" | cut -d: -f1)
build_line=$(grep -n 'name: Build review batches' "$ROOT/action.yml" | cut -d: -f1)
[ "$last_review_line" -lt "$build_line" ] \
  || fail "the last review must be found before the batches are built"

# The reusable workflow runs the action from its own pinned commit, never
# lets one reviewer cancel another, and verifies by default.
workflow="$ROOT/.github/workflows/review.yml"
assert_contains "$workflow" "workflow_call:"
assert_contains "$workflow" "fail-fast: false"
assert_contains "$workflow" "repository: \${{ job.workflow_repository }}"
assert_contains "$workflow" "ref: \${{ job.workflow_sha }}"
assert_contains "$workflow" "persist-credentials: false"
assert_contains "$workflow" "path: .ai-code-review-action"
assert_contains "$workflow" "uses: ./.ai-code-review-action"
assert_contains "$workflow" "verify-landed: \${{ inputs.verify-landed }}"
assert_contains "$workflow" "allow-missing-token: \${{ inputs.allow-missing-token }}"
assert_contains "$workflow" "review-scope: \${{ inputs.review-scope }}"
[ "$(grep -A7 '^      review-scope:$' "$workflow" | grep -c '^        default: full$')" = "1" ] \
  || fail "the workflow's review-scope must default to full"
# The no-token smoke jobs opt out explicitly; without that they would fail.
[ "$(grep -c 'allow-missing-token: true' "$ROOT/.github/workflows/test.yml")" = "2" ] \
  || fail "both no-token smoke jobs must set allow-missing-token"
default_models=$(node "$ROOT/tests/check-default-reviewers.mjs" "$workflow")
[ "$default_models" = "gpt-5.6-sol,gpt-6-astra" ] \
  || fail "unexpected default reviewers: $default_models"
assert_contains "$ROOT/examples/reusable-workflow.yml" "pull_request_target:"
assert_contains "$ROOT/examples/reusable-workflow.yml" \
  "COPILOT_REVIEW_PAT: \${{ secrets.COPILOT_REVIEW_PAT }}"

suite_finished=true
echo "All tests passed."
