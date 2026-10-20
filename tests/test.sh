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
  ALLOW_MISSING_TOKEN=yes; do
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

# usage: run_post <fixture dir>
run_post() {
  PATH="$gh_bin:$PATH" STUB_DIR="$1" \
  GH_TOKEN=stub REPOSITORY=shariqh/example PR_NUMBER=7 \
  HEAD_SHA="$verify_head" RUN_ID=777 RUN_ATTEMPT=3 REVIEW_MODEL=gpt-5.6-sol \
  REVIEW_WORK_DIR="$post_work" COMMENT_MARKER="$sol" GITHUB_ACTION_PATH="$ROOT" \
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
