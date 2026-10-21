#!/usr/bin/env bash
set -euo pipefail

# review-scope since-last-review: find the head this reviewer last reviewed,
# and hand it to prepare-review.sh as the step outputs reviewed-commit,
# full-review, result, base-ref and merge-base. With no earlier review an
# incremental review can build on, it sets no outputs and says why, and
# prepare-review.sh reviews the whole pull request.
#
# The previous head comes from this reviewer's own sticky comment, never from
# the push event's `before`: a run that a newer push cancelled never reviewed
# its `before`, but the sticky only ever names a head that was reviewed. The
# sticky is the bot comment whose first line is this reviewer's marker, as in
# post-comment.sh and verify-landed.sh, and every value is read from its
# header, which ends before any model output, then checked against a strict
# pattern, because the comment is untrusted input.

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPOSITORY:?REPOSITORY is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

COMMENT_MARKER=${COMMENT_MARKER:-ai-code-review-sticky}
if ! [[ "$COMMENT_MARKER" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "::error::comment-marker may contain only letters, numbers, underscores, and hyphens"
  exit 1
fi

# shellcheck disable=SC1091
source "$GITHUB_ACTION_PATH/scripts/lib.sh"

full_review() {
  echo "review scope: full review, because $1"
  exit 0
}

if ! ids=$(gh api "repos/$REPOSITORY/issues/$PR_NUMBER/comments" --paginate \
    --jq "$(sticky_ids_jq "$COMMENT_MARKER")"); then
  full_review "this reviewer's sticky comment could not be read"
fi
existing_id=$(printf '%s\n' "$ids" | awk '/^[0-9]+$/' | sort -n | tail -n 1)
if [ -z "$existing_id" ]; then
  full_review "this reviewer has not reviewed this pull request yet"
fi

if ! sticky_body=$(gh api "repos/$REPOSITORY/issues/comments/$existing_id" --jq .body); then
  full_review "this reviewer's sticky comment could not be read"
fi
read -r reviewed_sha _ _ <<< "$(printf '%s\n' "$sticky_body" | sticky_header_fields)"
read -r result full_review_sha coverage base_ref merge_base \
  <<< "$(printf '%s\n' "$sticky_body" | sticky_scope_fields)"

# A sticky written without since-last-review records neither the full review
# nor the coverage, so it cannot be built on, and neither can one that does
# not record the base branch and merge base the review was made against.
if ! [[ "$reviewed_sha" =~ ^[0-9a-f]{40}$ ]] \
  || ! [[ "$full_review_sha" =~ ^[0-9a-f]{40}$ ]] \
  || ! [[ "$result" =~ ^(clean|findings)$ ]] \
  || ! [[ "$coverage" =~ ^(complete|incomplete)$ ]] \
  || ! [[ "$base_ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] \
  || ! [[ "$merge_base" =~ ^[0-9a-f]{40}$ ]]; then
  full_review "sticky comment $existing_id records no review that an incremental review can build on"
fi
if [ "$coverage" != complete ]; then
  full_review "the last review, of $reviewed_sha, was incomplete: a review call failed or coverage was partial"
fi

{
  echo "reviewed-commit=$reviewed_sha"
  echo "full-review=$full_review_sha"
  echo "result=$result"
  echo "base-ref=$base_ref"
  echo "merge-base=$merge_base"
} >> "$GITHUB_OUTPUT"
echo "last review: $reviewed_sha (sticky comment $existing_id, result $result), against $base_ref at merge base $merge_base; the full review was at $full_review_sha"
