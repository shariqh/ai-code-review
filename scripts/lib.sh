#!/usr/bin/env bash

is_clean_review() {
  local file=${1:?review file is required}
  local stripped
  local remainder
  stripped=$(tr -d '[:space:]' < "$file")
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
# sequences removed, secrets redacted. Every line is prefixed, so nothing the
# CLI echoes back (it can quote the untrusted diff) can start a workflow
# command such as ::add-mask:: or ::stop-commands::.
print_cli_stderr() {
  local file=${1:?stderr file is required}
  local max_bytes=${CLI_STDERR_MAX_BYTES:-4000}
  local max_lines=${CLI_STDERR_MAX_LINES:-40}
  local prefix='  copilot stderr | '
  local token=${COPILOT_GITHUB_TOKEN-}
  local escape_character
  local text
  local total_bytes
  local total_lines

  if [ ! -s "$file" ]; then
    printf '%s%s\n' "$prefix" "(the Copilot CLI wrote nothing to stderr)"
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

  printf '%s\n' "$text" \
    | redact_secrets \
    | head -n "$max_lines" \
    | cut -c1-400 \
    | sed "s/^/$prefix/" \
    || true

  total_bytes=$(wc -c < "$file" | tr -d '[:space:]')
  total_lines=$(printf '%s\n' "$text" | wc -l | tr -d '[:space:]')
  if [ "$total_bytes" -gt "$max_bytes" ] || [ "$total_lines" -gt "$max_lines" ]; then
    printf '%s[... stderr truncated; %s bytes in total ...]\n' "$prefix" "$total_bytes"
  fi
}
