#!/usr/bin/env bash
set -euo pipefail

: "${BASE_SHA:?BASE_SHA is required}"
: "${HEAD_SHA:?HEAD_SHA is required}"
: "${REVIEW_REPO_DIR:?REVIEW_REPO_DIR is required}"
: "${REVIEW_WORK_DIR:?REVIEW_WORK_DIR is required}"

REVIEW_SCOPE=${REVIEW_SCOPE:-full}
case "$REVIEW_SCOPE" in
  full|since-last-review) ;;
  *) echo "::error::review-scope must be full or since-last-review"; exit 1 ;;
esac

case "$REVIEW_WORK_DIR" in
  /|""|.) echo "::error::unsafe REVIEW_WORK_DIR"; exit 1 ;;
esac

# The round cap: when the last review was round MAX_ROUNDS (0 for no cap) or
# later and left findings, the reviewer stops instead of reviewing again. STICKY_ROUND and
# STICKY_RESULT are the last review's round count and result, from
# last-review.sh.
MAX_ROUNDS=${MAX_ROUNDS:-3}
if ! [[ "$MAX_ROUNDS" =~ ^[0-9]+$ ]]; then
  echo "::error::max-rounds must be a non-negative integer"
  exit 1
fi
round_previous=${STICKY_ROUND:-0}
[[ "$round_previous" =~ ^[0-9]{1,4}$ ]] || round_previous=0

rm -rf -- "$REVIEW_WORK_DIR"
mkdir -p "$REVIEW_WORK_DIR"

# Maintainer review context (conventions, known false positives), injected
# into the review prompt. Read from the base BRANCH, never the PR head or the
# checked-out working tree, so a pull request cannot rewrite the instructions
# that review it.
#
# Prefer the base branch's CURRENT tip over the event's BASE_SHA: base.sha is
# frozen at PR creation, so a PR opened before the context file (or an edit
# to it) landed would silently review without it. The branch tip is just as
# trusted — only maintainers can move it — and always current. Fall back to
# BASE_SHA when the remote ref is absent (e.g. plain-SHA test fixtures).
CONTEXT_FILE=${CONTEXT_FILE:-}
REVIEW_FILE=${REVIEW_FILE:-}
CONTEXT_MAX_BYTES=${CONTEXT_MAX_BYTES:-16000}
BASE_REF=${BASE_REF:-}
context_rev="$BASE_SHA"
if [ -n "$BASE_REF" ] && \
    git -C "$REVIEW_REPO_DIR" rev-parse -q --verify \
      "refs/remotes/origin/$BASE_REF" > /dev/null; then
  context_rev="refs/remotes/origin/$BASE_REF"
fi

# Writes the base revision's copy of <file> to <out>, cut at
# CONTEXT_MAX_BYTES with a note; <out> is empty when <file> is empty or not
# on the base.
# usage: read_base_file <label> <file> <out>
read_base_file() {
  local label=$1 file=$2 out=$3 bytes
  : > "$out"
  [ -n "$file" ] || return 0
  if git -C "$REVIEW_REPO_DIR" show "$context_rev:$file" > "$out" 2>/dev/null; then
    bytes=$(wc -c < "$out")
    if [ "$bytes" -gt "$CONTEXT_MAX_BYTES" ]; then
      head -c "$CONTEXT_MAX_BYTES" "$out" > "$out.tmp"
      printf '\n[%s truncated at %s bytes]\n' "$label" "$CONTEXT_MAX_BYTES" >> "$out.tmp"
      mv "$out.tmp" "$out"
    fi
    echo "$label: $file ($bytes bytes from $context_rev)"
  else
    # Not on the base ref (or unreadable) — review without it. A partial
    # write from the failed `git show` must not leak into the prompt.
    : > "$out"
    echo "$label: $file not on $context_rev; skipping"
  fi
}

read_base_file "review context" "$CONTEXT_FILE" "$REVIEW_WORK_DIR/review-context.md"
# The repository's review guide (REVIEW.md by default): what failure looks
# like in this repository, paths to skip, decisions already taken. Read from
# the base branch for the same reason as the review context.
read_base_file "review guide" "$REVIEW_FILE" "$REVIEW_WORK_DIR/review-guide.md"

# The findings earlier rounds reported (STICKY_LEDGER), so none is reported
# again, and the round this one follows.
node "$GITHUB_ACTION_PATH/scripts/findings.mjs" ledger-read "$REVIEW_WORK_DIR"
printf '%s\n' "$round_previous" > "$REVIEW_WORK_DIR/round.previous"

# review-scope since-last-review: write the diff of the commits since the head
# this reviewer last reviewed (LAST_REVIEWED_SHA, found by last-review.sh),
# limited to the files the pull request itself changes, and record the scope
# for run-review.sh and post-comment.sh. Returns 1, after saying why, when the
# whole pull request must be reviewed instead. errexit does not apply inside a
# function called as an `if` condition, so every step checks its own status.
#
# usage: write_incremental_diff <base>
write_incremental_diff() {
  local base=$1
  local since=${LAST_REVIEWED_SHA:-}
  local full_review=${LAST_FULL_REVIEW_SHA:-}
  local result=${LAST_REVIEW_RESULT:-}
  local last_base_ref=${LAST_BASE_REF:-}
  local last_merge_base=${LAST_MERGE_BASE:-}
  local list_max_bytes=${FILE_LIST_MAX_BYTES:-8000}
  local merge_base head_merge_base
  local paths=()
  local path

  # last-review.sh has already said why when it found nothing to build on.
  [ -n "$since" ] || return 1
  if ! [[ "$since" =~ ^[0-9a-f]{40}$ ]] || ! [[ "$full_review" =~ ^[0-9a-f]{40}$ ]] \
    || ! [[ "$result" =~ ^(clean|findings)$ ]] \
    || ! [[ "$last_base_ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] \
    || ! [[ "$last_merge_base" =~ ^[0-9a-f]{40}$ ]]; then
    echo "review scope: full review, because the last review's details are malformed"
    return 1
  fi

  # Which commits belong to the pull request depends on its base. After a
  # retarget, commits the last review took for the old base's own can now be
  # the pull request's, and no review has covered them.
  if [ "$BASE_REF" != "$last_base_ref" ]; then
    echo "review scope: full review, because the base branch changed since the last review, which was against $last_base_ref"
    return 1
  fi

  # The checkout holds the head's whole history, so a missing commit is most
  # likely one a force-push dropped. The checkout keeps no credentials, so
  # this fetch can fail, and then the review is a full one.
  if ! git -C "$REVIEW_REPO_DIR" cat-file -e "$since^{commit}" 2>/dev/null; then
    GIT_TERMINAL_PROMPT=0 git -C "$REVIEW_REPO_DIR" fetch --quiet --no-tags \
      --no-recurse-submodules origin "$since" || true
    if ! git -C "$REVIEW_REPO_DIR" cat-file -e "$since^{commit}" 2>/dev/null; then
      echo "review scope: full review, because the last reviewed commit $since is not in the repository"
      return 1
    fi
  fi
  if ! git -C "$REVIEW_REPO_DIR" merge-base --is-ancestor "$since" "$HEAD_SHA"; then
    echo "review scope: full review, because the last reviewed commit $since is not an ancestor of $HEAD_SHA, as after a force-push or rebase"
    return 1
  fi

  # A base that was rewound or rewritten changes them too: the merge base of
  # the last reviewed head moves back, and the commits it passes over become
  # the pull request's. A base that only moved forward keeps that merge base
  # or moves it forward, so the last review's merge base stays an ancestor.
  if ! merge_base=$(git -C "$REVIEW_REPO_DIR" merge-base "$base" "$since") \
    || ! git -C "$REVIEW_REPO_DIR" merge-base --is-ancestor "$last_merge_base" "$merge_base" \
      2>/dev/null; then
    echo "review scope: full review, because the base branch $last_base_ref was rewound or rewritten since the last review"
    return 1
  fi

  # The files the pull request itself changes: those that differ between the
  # base and either head. Once the pull request merges the base branch in, the
  # base commit it merged is the merge base, so the base branch's own changes
  # stay out, while a file the pull request changed and then reverted stays
  # in. --no-renames lists both sides of a rename, so the diff below still
  # pairs them. The names are sorted bytewise, because a locale can collate
  # two different names as equal, into a file whose status is checked: a
  # variable cannot hold NUL-separated names, and a failure inside a process
  # substitution would go unseen and leave the list short.
  if ! git -C "$REVIEW_REPO_DIR" diff --name-only -z --no-renames "$base...$since" \
      > "$REVIEW_WORK_DIR/scope.paths" \
    || ! git -C "$REVIEW_REPO_DIR" diff --name-only -z --no-renames "$base...$HEAD_SHA" \
      >> "$REVIEW_WORK_DIR/scope.paths" \
    || ! LC_ALL=C sort -z -u "$REVIEW_WORK_DIR/scope.paths" \
      > "$REVIEW_WORK_DIR/scope.paths.sorted" \
    || ! head_merge_base=$(git -C "$REVIEW_REPO_DIR" merge-base "$base" "$HEAD_SHA"); then
    echo "review scope: full review, because the pull request's files could not be listed"
    return 1
  fi
  while IFS= read -r -d '' path; do
    paths+=("$path")
  done < "$REVIEW_WORK_DIR/scope.paths.sorted"

  # The paths are literal (a file named `*` is not a glob), and an empty list
  # never reaches git diff, which would then diff every file.
  : > "$REVIEW_WORK_DIR/pr.diff"
  if [ "${#paths[@]}" -gt 0 ] \
    && ! git -C "$REVIEW_REPO_DIR" --literal-pathspecs diff "$since" "$HEAD_SHA" \
      -- "${paths[@]}" > "$REVIEW_WORK_DIR/pr.diff"; then
    echo "review scope: full review, because the incremental diff could not be built"
    return 1
  fi

  # The whole pull request's file list, for the prompt's orientation only.
  # git quotes a name holding a newline or a quote, so each name is one line,
  # and the list stops at FILE_LIST_MAX_BYTES (8,000 by default).
  if ! git -C "$REVIEW_REPO_DIR" diff --name-only "$base...$HEAD_SHA" \
      > "$REVIEW_WORK_DIR/scope.names" \
    || ! LC_ALL=C awk -v max="$list_max_bytes" '
      {
        line = "- " $0
        if (stopped || bytes + length(line) + 1 > max) { stopped = 1; more++; next }
        bytes += length(line) + 1
        print line
      }
      END {
        if (NR == 0) print "- (none: the pull request no longer changes any file)"
        if (more) printf "- [%d more not listed]\n", more
      }
    ' "$REVIEW_WORK_DIR/scope.names" > "$REVIEW_WORK_DIR/scope.files"; then
    echo "review scope: full review, because the pull request's files could not be listed"
    return 1
  fi

  printf '%s\n' "$since" > "$REVIEW_WORK_DIR/scope.since"
  printf '%s\n' "$full_review" > "$REVIEW_WORK_DIR/scope.full-review"
  printf '%s\n' "$result" > "$REVIEW_WORK_DIR/scope.previous-result"
  printf '%s %s\n' "$BASE_REF" "$head_merge_base" > "$REVIEW_WORK_DIR/scope.base"
  echo "review scope: incremental review of $since..$HEAD_SHA (paths in scope: ${#paths[@]})"
}

# The incremental diff is measured from the same trusted base the review
# context is read from: the base branch's current tip, or BASE_SHA without it.
incremental=false
if [ "$REVIEW_SCOPE" = since-last-review ] && write_incremental_diff "$context_rev"; then
  incremental=true
fi
if [ "$incremental" = false ]; then
  git -C "$REVIEW_REPO_DIR" diff "$BASE_SHA...$HEAD_SHA" > "$REVIEW_WORK_DIR/pr.diff"
  # Under since-last-review, a full review is what later runs build on, so it
  # records its head and the base branch and merge base it was diffed
  # against. A branch name it cannot record means the next review is full too.
  if [ "$REVIEW_SCOPE" = since-last-review ]; then
    printf '%s\n' "$HEAD_SHA" > "$REVIEW_WORK_DIR/scope.full-review"
    if [[ "$BASE_REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] \
      && merge_base=$(git -C "$REVIEW_REPO_DIR" merge-base "$BASE_SHA" "$HEAD_SHA"); then
      printf '%s %s\n' "$BASE_REF" "$merge_base" > "$REVIEW_WORK_DIR/scope.base"
    else
      echo "review scope: the base branch could not be recorded, so the next review will be a full one too"
    fi
  fi
fi
echo "diff bytes: $(wc -c < "$REVIEW_WORK_DIR/pr.diff")"

# The pull request's whole diff, against the same trusted base, as GitHub
# shows it: the verifier reads what the pull request changes in a file from
# it, and an inline comment can sit only on a line of one of its hunks.
full_diff=built
if git -C "$REVIEW_REPO_DIR" diff "$context_rev...$HEAD_SHA" > "$REVIEW_WORK_DIR/pr-full.diff" \
  && node "$GITHUB_ACTION_PATH/scripts/review-files.mjs" commentable \
    "$REVIEW_WORK_DIR/pr-full.diff" "$REVIEW_WORK_DIR/commentable.json"; then
  :
else
  full_diff=failed
  echo "the pull request's full diff could not be built, so no finding will be posted inline"
  : > "$REVIEW_WORK_DIR/pr-full.diff"
  rm -f "$REVIEW_WORK_DIR/commentable.json"
fi

# A reviewer can be limited to large or sensitive pull requests: it reviews
# only when the pull request's whole diff is at least MIN_DIFF_BYTES, or it
# changes a path that matches one of PATHS (shell patterns, separated by
# commas or newlines, in which * also matches /). Otherwise the step output
# skip is true and the later steps do nothing. With neither set, every pull
# request is reviewed. When the conditions cannot be checked, it reviews.
MIN_DIFF_BYTES=${MIN_DIFF_BYTES:-0}
if ! [[ "$MIN_DIFF_BYTES" =~ ^[0-9]+$ ]]; then
  echo "::error::min-diff-bytes must be a non-negative integer"
  exit 1
fi
patterns=()
IFS=$',\n' read -r -d '' -a raw_patterns <<< "${PATHS:-}" || true
for pattern in ${raw_patterns[@]+"${raw_patterns[@]}"}; do
  pattern=$(printf '%s' "$pattern" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ -n "$pattern" ] && patterns+=("$pattern")
done
if [ "$MIN_DIFF_BYTES" -gt 0 ] || [ "${#patterns[@]}" -gt 0 ]; then
  gate_reason=""
  full_bytes=$(wc -c < "$REVIEW_WORK_DIR/pr-full.diff" | tr -d '[:space:]')
  if [ "$full_diff" = failed ]; then
    gate_reason="the pull request's diff could not be built to check them"
  elif [ "$MIN_DIFF_BYTES" -gt 0 ] && [ "$full_bytes" -ge "$MIN_DIFF_BYTES" ]; then
    gate_reason="its diff is $full_bytes bytes, at least min-diff-bytes ($MIN_DIFF_BYTES)"
  fi
  if [ -z "$gate_reason" ] && [ "${#patterns[@]}" -gt 0 ]; then
    if git -C "$REVIEW_REPO_DIR" diff --name-only -z "$context_rev...$HEAD_SHA" \
        > "$REVIEW_WORK_DIR/gate.paths"; then
      while IFS= read -r -d '' path && [ -z "$gate_reason" ]; do
        for pattern in "${patterns[@]}"; do
          # shellcheck disable=SC2053 # the pattern is a glob on purpose
          if [[ "$path" == $pattern ]]; then
            gate_reason="it changes $path, which matches $pattern"
            break
          fi
        done
      done < "$REVIEW_WORK_DIR/gate.paths"
    else
      gate_reason="its paths could not be listed"
    fi
  fi
  if [ -z "$gate_reason" ]; then
    paths_shown=${PATHS:-}
    paths_shown=${paths_shown//$'\n'/, }
    echo "::notice::This reviewer reviews only pull requests whose diff is at least ${MIN_DIFF_BYTES} bytes (0 means no size condition) or that change a path matching '${paths_shown}'; this one does neither, so it is skipped."
    echo "skip=true" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 0
  fi
  echo "reviewer conditions: met, because $gate_reason"
fi
echo "skip=false" >> "${GITHUB_OUTPUT:-/dev/null}"

# Paused: the last review was round MAX_ROUNDS or later and left findings,
# and there is something new to review. No model is called; the comment says
# the new commits were not reviewed and asks for the approach to be
# reconsidered. Deleting the sticky comment starts over.
if [ "$MAX_ROUNDS" -gt 0 ] && [ "$round_previous" -ge "$MAX_ROUNDS" ] \
  && [ "${STICKY_RESULT:-}" = findings ] \
  && ! { [ -s "$REVIEW_WORK_DIR/scope.since" ] && [ ! -s "$REVIEW_WORK_DIR/pr.diff" ]; }; then
  printf '%s\n' "$round_previous" > "$REVIEW_WORK_DIR/scope.paused"
  mkdir -p "$REVIEW_WORK_DIR/batches"
  : > "$REVIEW_WORK_DIR/overflow.note"
  echo "0" > "$REVIEW_WORK_DIR/batch.count"
  echo "review paused: round $round_previous of at most $MAX_ROUNDS left findings, so no model is called"
  exit 0
fi

"$GITHUB_ACTION_PATH/scripts/chunk-diff.sh" \
  "$REVIEW_WORK_DIR/pr.diff" \
  "$REVIEW_WORK_DIR"

# The head version of each file a batch touches, numbered by line, so the
# finder can see how the changed code is called and defined rather than
# guess. Read from the head commit's objects, never the working tree.
node "$GITHUB_ACTION_PATH/scripts/review-files.mjs" head-files \
  "$REVIEW_WORK_DIR" "$REVIEW_REPO_DIR" "$HEAD_SHA"
