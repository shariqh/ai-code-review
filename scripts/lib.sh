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

# A review is complete when nothing was truncated or left out by the batch
# cap and no review call failed, whatever it found. Only a complete review can
# be the starting point of a since-last-review run.
is_complete_review() {
  local work_dir=${1:?work directory is required}
  [ ! -s "$work_dir/overflow.note" ] && [ ! -s "$work_dir/review.failures" ]
}

# An incremental review with an empty diff: none of the pull request's files
# changed since the head this reviewer last reviewed (prepare-review.sh
# writes scope.since only for an incremental review).
is_empty_incremental_review() {
  local work_dir=${1:?work directory is required}
  [ -s "$work_dir/scope.since" ] && [ ! -s "$work_dir/pr.diff" ]
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

# Print the result, full-review commit, coverage, base branch and merge base
# recorded in a sticky comment's header as
# "<result> <full-review> <coverage> <base branch> <merge base>", with "-" for
# anything missing. The result comes from the result marker that ends the
# header; post-comment.sh writes the other lines only for review-scope
# since-last-review. Like sticky_header_fields, it reads the header only.
sticky_scope_fields() {
  awk '
    { sub(/\r$/, "") }
    /^<!-- ai-code-review-result: / {
      complete = 1
      if ($0 ~ /^<!-- ai-code-review-result: [a-z]+ -->$/) {
        result = $0
        sub(/^<!-- ai-code-review-result: /, "", result)
        sub(/ -->$/, "", result)
      }
      exit
    }
    full == "" && /^<!-- ai-code-review-full-review: [0-9a-f]+ -->$/ {
      full = $0
      sub(/^<!-- ai-code-review-full-review: /, "", full)
      sub(/ -->$/, "", full)
    }
    coverage == "" && /^<!-- ai-code-review-coverage: [a-z]+ -->$/ {
      coverage = $0
      sub(/^<!-- ai-code-review-coverage: /, "", coverage)
      sub(/ -->$/, "", coverage)
    }
    base == "" && $0 ~ "^<!-- ai-code-review-base: [A-Za-z0-9][A-Za-z0-9._/-]* [0-9a-f]+ -->$" {
      base = $0
      sub(/^<!-- ai-code-review-base: /, "", base)
      sub(/ -->$/, "", base)
    }
    END {
      if (!complete) { result = ""; full = ""; coverage = ""; base = "" }
      if (result == "") result = "-"
      if (full == "") full = "-"
      if (coverage == "") coverage = "-"
      if (base == "") base = "- -"
      printf "%s %s %s %s\n", result, full, coverage, base
    }
  '
}

# Print a failed Copilot CLI call's stderr into the job log.
#
# sanitize-stderr.mjs does the text work, in this order: strip terminal
# control sequences, redact credentials in the WHOLE stderr
# (case-insensitively), keep only the last 10 lines and at most 1,000 bytes,
# then replace every character outside a small allowlist with "?" and prefix
# each line. Redacting before cutting means the cut can never leave a
# fragment of a credential, and the allowlist (no colon, "#", brackets or
# parentheses) leaves nothing for workflow commands or for setup-node's
# problem matchers to act on, though the stderr can quote the untrusted diff.
#
# As defence in depth this wraps that output in a ::stop-commands:: block
# whose resume token is random for every call and generated after the CLI
# exited. The fence stops workflow commands, but not problem matchers, which
# is why the allowlist is the primary defence. The fence is printed here
# rather than by the script, so it is closed even if the script fails.
print_cli_stderr() {
  local file=${1:?stderr file is required}
  local prefix='  copilot stderr | '
  local stop_token

  if [ ! -s "$file" ]; then
    printf '%s%s\n' "$prefix" "the Copilot CLI wrote nothing to stderr"
    return 0
  fi

  stop_token=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || stop_token=""
  if ! [[ "$stop_token" =~ ^[0-9a-f]{32}$ ]]; then
    printf '%s%s\n' "$prefix" "stderr withheld, no random token to fence it from workflow commands"
    return 0
  fi

  # This runs inside the batch loop, so a failure here must not end the
  # review.
  printf '::stop-commands::%s\n' "$stop_token"
  node "$GITHUB_ACTION_PATH/scripts/sanitize-stderr.mjs" "$file" \
    || printf '%s%s\n' "$prefix" "the Copilot CLI stderr could not be printed"
  printf '::%s::\n' "$stop_token"
}
