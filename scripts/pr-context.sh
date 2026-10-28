#!/usr/bin/env bash
set -euo pipefail

# The pull request's intent, for the finder and the verifier: its title and
# description, and the issues it says it closes or its title names, read with
# the github-token into pr-context.md. All of it is written by whoever opened
# the pull request or the issue, so the prompts mark it as untrusted data. It
# is best effort: what cannot be read is left out, and the log says so. An
# issue in a repository whose token cannot read issues is one of those.

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPOSITORY:?REPOSITORY is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${REVIEW_WORK_DIR:?REVIEW_WORK_DIR is required}"

DESCRIPTION_MAX_BYTES=${DESCRIPTION_MAX_BYTES:-6000}
ISSUE_MAX_BYTES=${ISSUE_MAX_BYTES:-3000}
MAX_ISSUES=2

cd "$REVIEW_WORK_DIR"
: > pr-context.md

# Control characters other than tab and newline go (so does the carriage
# return of a CRLF line end), and the text stops at <max> bytes with a note.
# usage: bounded <max bytes> < text
bounded() {
  LC_ALL=C tr -d '\000-\010\013-\037\177' > pr-context.part
  if [ "$(wc -c < pr-context.part)" -gt "$1" ]; then
    head -c "$1" pr-context.part
    printf '\n[... truncated at %s bytes ...]\n' "$1"
  else
    cat pr-context.part
  fi
  rm -f pr-context.part
}

# A title has no newline, so the first line is the title and the rest the
# description.
if ! gh api "repos/$REPOSITORY/pulls/$PR_NUMBER" \
    --jq '"\(.title // "")\n\(.body // "")"' > pr.json.txt; then
  echo "pull request description: could not be read, so the review goes without it"
  rm -f pr.json.txt
  exit 0
fi
title=$(head -n 1 pr.json.txt | LC_ALL=C tr -d '\000-\010\013-\037\177')
tail -n +2 pr.json.txt > pr-body.txt
rm -f pr.json.txt
{
  printf 'Title: %s\n\n' "$title"
  if [ -n "$(tr -d '[:space:]' < pr-body.txt)" ]; then
    printf 'Description:\n'
    bounded "$DESCRIPTION_MAX_BYTES" < pr-body.txt
  else
    printf 'Description: (none)\n'
  fi
} > pr-context.md
echo "pull request description: $(wc -c < pr-body.txt | tr -d '[:space:]') bytes"

# Issues the description says it closes ("Closes #12", "fixes: #12"), then
# issue numbers in the title, other than the pull request's own.
issues=$(
  {
    LC_ALL=C grep -oiE '(^|[^A-Za-z])(close[sd]?|fix(e[sd])?|resolve[sd]?):?[[:space:]]+#[0-9]+' \
      pr-body.txt | grep -oE '[0-9]+$' || true
    printf '%s\n' "$title" | grep -oE '#[0-9]+' | tr -d '#' || true
  } | awk -v own="$PR_NUMBER" '$0 != own && !seen[$0]++' | head -n "$MAX_ISSUES"
)
rm -f pr-body.txt
for issue in $issues; do
  if ! gh api "repos/$REPOSITORY/issues/$issue" \
      --jq 'if .pull_request then "" else "\(.title // "")\n\(.body // "")" end' > issue.txt; then
    echo "issue #$issue: could not be read with the github-token, so the review goes without it"
    continue
  fi
  if [ ! -s issue.txt ] || [ -z "$(tr -d '[:space:]' < issue.txt)" ]; then
    echo "issue #$issue: a pull request, not an issue; left out"
    continue
  fi
  {
    printf '\nLinked issue #%s: %s\n' "$issue" \
      "$(head -n 1 issue.txt | LC_ALL=C tr -d '\000-\010\013-\037\177')"
    tail -n +2 issue.txt | bounded "$ISSUE_MAX_BYTES"
  } >> pr-context.md
  echo "issue #$issue: included"
done
rm -f issue.txt
