#!/usr/bin/env bash

# A reply is clean when it says "No issues found." and nothing else. An empty
# or whitespace-only reply is not clean: it reviewed nothing.
is_clean_review() {
  local file=${1:?review file is required}
  local stripped
  local remainder
  stripped=$(tr -d '[:space:]' < "$file")
  [ -n "$stripped" ] || return 1
  remainder=$stripped

  while [ "${remainder#Noissuesfound.}" != "$remainder" ]; do
    remainder=${remainder#Noissuesfound.}
  done

  [ -z "$remainder" ] || [ "$remainder" = "Noissuesfound" ]
}

is_complete_clean_review() {
  local work_dir=${1:?work directory is required}
  [ ! -s "$work_dir/overflow.note" ] \
    && [ ! -s "$work_dir/review.failures" ] \
    && [ "$(tr -d '[:space:]' < "$work_dir/review.md")" = "Noissuesfound." ]
}

# The jq filter that lists one reviewer's sticky comment ids: comments by
# github-actions[bot] whose FIRST line is exactly that reviewer's marker. The
# body carries model output, so a marker found anywhere else in it may be a
# quotation (for example one reviewer quoting another's marker) and must not
# make the comment that reviewer's sticky.
sticky_ids_jq() {
  local marker=${1:?marker is required}
  printf '.[] | select((.user.login == "github-actions[bot]") and ((((.body // "") | split("\\n") | .[0]) | rtrimstr("\\r")) == "<!-- %s -->")) | .id' "$marker"
}

# Print the reviewed commit, run id and run attempt recorded in a sticky
# comment's header as "<sha> <run> <attempt>", with "-" for anything missing.
# The header is every line before the "ai-code-review-result" marker, which
# post-comment.sh writes ahead of any model output, so a review that quotes
# these lines cannot override them. A body without that marker has no header.
sticky_header_fields() {
  awk '
    { sub(/\r$/, "") }
    /^<!-- ai-code-review-result: / { complete = 1; exit }
    sha == "" && /^_Reviewed commit: `[0-9a-f]+`_$/ {
      sha = $0
      sub(/^_Reviewed commit: `/, "", sha)
      sub(/`_$/, "", sha)
    }
    run == "" && /^<!-- ai-code-review-run: [0-9]+ -->$/ {
      run = $0
      sub(/^<!-- ai-code-review-run: /, "", run)
      sub(/ -->$/, "", run)
    }
    attempt == "" && /^<!-- ai-code-review-attempt: [0-9]+ -->$/ {
      attempt = $0
      sub(/^<!-- ai-code-review-attempt: /, "", attempt)
      sub(/ -->$/, "", attempt)
    }
    END {
      if (!complete) { sha = ""; run = ""; attempt = "" }
      if (sha == "") sha = "-"
      if (run == "") run = "-"
      if (attempt == "") attempt = "-"
      printf "%s %s %s\n", sha, run, attempt
    }
  '
}

# Replace anything token-like on stdin: GitHub token formats, JWTs, and the
# values of Authorization headers and bearer/token pairs. The CLI already
# redacts COPILOT_GITHUB_TOKEN and Actions masks registered secrets; this
# covers credentials neither of them knows about.
redact_secrets() {
  sed -E \
    -e 's/(gh[pousr]_|github_pat_)[A-Za-z0-9_]+/\1[REDACTED]/g' \
    -e 's/eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]*)?/[REDACTED]/g' \
    -e 's/([Aa]uthorization["'\'']?[[:space:]]*[:=][[:space:]]*)[^[:space:],;]+([[:space:]]+[^[:space:],;"'\'']+)?/\1[REDACTED]/g' \
    -e 's/([Bb]earer|[Tt]oken)([[:space:]]+|[[:space:]]*[:=][[:space:]]*)[A-Za-z0-9._~+\/=-]{20,}/\1\2[REDACTED]/g' \
    -e 's/(tid=)[^[:space:]]+/\1[REDACTED]/g'
}

# Print a failed Copilot CLI call's stderr into the job log: at most
# CLI_STDERR_MAX_BYTES bytes and CLI_STDERR_MAX_LINES lines, terminal control
# sequences removed, secrets redacted.
#
# The stderr can quote the untrusted diff, and the runner acts on two kinds of
# log line: workflow commands (`::command::` at the start of a line, and the
# legacy `##[command]` anywhere in one) and problem matchers (setup-node
# registers eslint-compact, eslint-stylish and tsc, whose patterns need a
# colon, brackets or parentheses, and which run even on lines a stop-commands
# block shields from the command parser). So every character outside a small
# allowlist (letters, digits, space and . , _ - ' " / =) becomes "?", which
# leaves the error readable but gives neither the command parser nor those
# matchers anything to match.
# As defence in depth the text is also printed inside a ::stop-commands::
# block whose resume token is random for every call and generated after the
# CLI exited, and every line carries a prefix.
print_cli_stderr() {
  local file=${1:?stderr file is required}
  local max_bytes=${CLI_STDERR_MAX_BYTES:-4000}
  local max_lines=${CLI_STDERR_MAX_LINES:-40}
  local prefix='  copilot stderr | '
  local token=${COPILOT_GITHUB_TOKEN-}
  local stop_token
  local escape_character
  local text
  local total_bytes
  local total_lines

  if [ ! -s "$file" ]; then
    printf '%s%s\n' "$prefix" "(the Copilot CLI wrote nothing to stderr)"
    return 0
  fi

  stop_token=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || stop_token=""
  if ! [[ "$stop_token" =~ ^[0-9a-f]{32}$ ]]; then
    printf '%s%s\n' "$prefix" "(stderr withheld: no random token to fence it from workflow commands)"
    return 0
  fi

  # CSI sequences (ESC [ parameters intermediates final) first, then every
  # remaining control byte except tab and newline, so a carriage return
  # cannot overwrite a line in the rendered log. This runs inside the batch
  # loop, so a failure here must not end the review.
  escape_character=$(printf '\033')
  text=$(head -c "$max_bytes" "$file" \
    | LC_ALL=C sed "s#${escape_character}\\[[0-9;?]*[ -/]*[@-~]##g" \
    | LC_ALL=C tr -d '\000-\010\013-\037\177') \
    || text="(the Copilot CLI's stderr could not be read)"
  if [ "${#token}" -ge 8 ]; then
    text=${text//"$token"/[REDACTED]}
  fi

  # tr maps byte for byte (LC_ALL=C, so a multibyte character becomes one "?"
  # per byte), which keeps the byte and line bounds above intact.
  printf '::stop-commands::%s\n' "$stop_token"
  printf '%s\n' "$text" \
    | redact_secrets \
    | LC_ALL=C tr -c "A-Za-z0-9 .,_'\"/=\n-" '?' \
    | head -n "$max_lines" \
    | cut -c1-400 \
    | sed "s/^/$prefix/" \
    || true

  total_bytes=$(wc -c < "$file" | tr -d '[:space:]')
  total_lines=$(printf '%s\n' "$text" | wc -l | tr -d '[:space:]')
  if [ "$total_bytes" -gt "$max_bytes" ] || [ "$total_lines" -gt "$max_lines" ]; then
    printf '%s[... stderr truncated; %s bytes in total ...]\n' "$prefix" "$total_bytes"
  fi
  printf '::%s::\n' "$stop_token"
}
