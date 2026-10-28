#!/usr/bin/env bash
set -euo pipefail

# Reviews one eval fixture locally with the action's own scripts, and scores
# the result with evals/score.mjs. Nothing is posted anywhere.
#
# usage: evals/run-fixture.sh <fixture.json> <clone of the fixture's repository> [work dir]
#
# The clone must contain the fixture's base and head commits (they are
# fetched from its origin when it does not). COPILOT_GITHUB_TOKEN is the
# Copilot CLI's token, as in the action, and every model call is billed to
# it. With gh logged in, the pull request's description is read too; set
# EVAL_NO_DESCRIPTION=1 to review without it. The action's settings apply,
# with the action's defaults: REVIEW_MODEL, REASONING_EFFORT, VERIFIER_MODEL,
# VERIFIER_EFFORT, CONTEXT_TIER, MAX_NITS, MAX_VERIFICATIONS, CONTEXT_FILE,
# REVIEW_FILE and the rest. Exits 1 when an expectation fails.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=${1:?usage: run-fixture.sh <fixture.json> <repository clone> [work dir]}
repo=${2:?usage: run-fixture.sh <fixture.json> <repository clone> [work dir]}
work=${3:-$(mktemp -d)/ai-code-review-eval}
: "${COPILOT_GITHUB_TOKEN:?COPILOT_GITHUB_TOKEN is required}"

read -r base head repository pull_request < <(node -e '
  const f = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  console.log([f.base, f.head, f.repository, f.pull_request].join(" "));
' "$fixture")
for sha in "$base" "$head"; do
  if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "the fixture's base and head must be commit SHAs" >&2
    exit 1
  fi
  if ! git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null; then
    git -C "$repo" fetch --quiet --no-tags origin "$sha"
  fi
done

export GITHUB_ACTION_PATH="$ROOT"
export REVIEW_MODEL=${REVIEW_MODEL:-gpt-5.6-sol}
export VERIFIER_MODEL=${VERIFIER_MODEL-gpt-5.6-sol}
export CONTEXT_FILE=${CONTEXT_FILE-.github/ai-review-context.md}
export REVIEW_FILE=${REVIEW_FILE-REVIEW.md}
export REVIEW_WORK_DIR="$work"

echo "== $(basename "$(dirname "$fixture")"): $repository#$pull_request at $head"
BASE_SHA="$base" HEAD_SHA="$head" REVIEW_REPO_DIR="$repo" REVIEW_SCOPE=full \
  "$ROOT/scripts/prepare-review.sh"
if [ -z "${EVAL_NO_DESCRIPTION:-}" ] && command -v gh >/dev/null 2>&1; then
  GH_TOKEN=${GH_TOKEN:-$(gh auth token 2>/dev/null || true)} REPOSITORY="$repository" \
    PR_NUMBER="$pull_request" "$ROOT/scripts/pr-context.sh" || true
fi
"$ROOT/scripts/run-review.sh"
node "$ROOT/scripts/review-files.mjs" verify-context "$work" "$repo" "$head"
"$ROOT/scripts/verify-findings.sh"
HEAD_SHA="$head" INLINE_COMMENTS=false node "$ROOT/scripts/findings.mjs" render "$work"
echo "review: $work/review.json"
cat "$work/summary.md"
node "$ROOT/evals/score.mjs" "$fixture" "$work/review.json"
