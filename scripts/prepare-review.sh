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
CONTEXT_MAX_BYTES=${CONTEXT_MAX_BYTES:-16000}
BASE_REF=${BASE_REF:-}
context_rev="$BASE_SHA"
if [ -n "$BASE_REF" ] && \
    git -C "$REVIEW_REPO_DIR" rev-parse -q --verify \
      "refs/remotes/origin/$BASE_REF" > /dev/null; then
  context_rev="refs/remotes/origin/$BASE_REF"
fi
: > "$REVIEW_WORK_DIR/review-context.md"
if [ -n "$CONTEXT_FILE" ]; then
  if git -C "$REVIEW_REPO_DIR" show "$context_rev:$CONTEXT_FILE" \
      > "$REVIEW_WORK_DIR/review-context.md" 2>/dev/null; then
    context_bytes=$(wc -c < "$REVIEW_WORK_DIR/review-context.md")
    if [ "$context_bytes" -gt "$CONTEXT_MAX_BYTES" ]; then
      head -c "$CONTEXT_MAX_BYTES" "$REVIEW_WORK_DIR/review-context.md" \
        > "$REVIEW_WORK_DIR/review-context.md.tmp"
      printf '\n[review context truncated at %s bytes]\n' "$CONTEXT_MAX_BYTES" \
        >> "$REVIEW_WORK_DIR/review-context.md.tmp"
      mv "$REVIEW_WORK_DIR/review-context.md.tmp" "$REVIEW_WORK_DIR/review-context.md"
    fi
    echo "review context: $CONTEXT_FILE ($context_bytes bytes from $context_rev)"
  else
    # Not on the base ref (or unreadable) — review without context. A partial
    # write from the failed `git show` must not leak into the prompt.
    : > "$REVIEW_WORK_DIR/review-context.md"
    echo "review context: $CONTEXT_FILE not on $context_rev; skipping"
  fi
fi

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

"$GITHUB_ACTION_PATH/scripts/chunk-diff.sh" \
  "$REVIEW_WORK_DIR/pr.diff" \
  "$REVIEW_WORK_DIR"
