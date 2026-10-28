#!/usr/bin/env bash
set -euo pipefail

skip() {
  echo "::notice::$1"
  echo "skip=true" >> "$GITHUB_OUTPUT"
  echo "reason=$2" >> "$GITHUB_OUTPUT"
  exit 0
}

case "${OWNER_ONLY:-true}" in
  true|false) ;;
  *)
    echo "::error::owner-only must be true or false"
    exit 1
    ;;
esac

case "${VERIFY_LANDED:-false}" in
  true|false) ;;
  *)
    echo "::error::verify-landed must be true or false"
    exit 1
    ;;
esac

case "${ALLOW_MISSING_TOKEN:-false}" in
  true|false) ;;
  *)
    echo "::error::allow-missing-token must be true or false"
    exit 1
    ;;
esac

case "${REVIEW_SCOPE:-full}" in
  full|since-last-review) ;;
  *)
    echo "::error::review-scope must be full or since-last-review"
    exit 1
    ;;
esac

# Checked before any skip, so a misconfigured reviewer fails loudly on its
# first run rather than on the first PR that is eligible for review. An empty
# model must never reach the CLI, which would fall back to its own default.
if ! [[ "${REVIEW_MODEL:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "::error::model must be a Copilot CLI model identifier such as gpt-5.6-sol"
  exit 1
fi

if ! [[ "${COMMENT_MARKER:-}" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "::error::comment-marker may contain only letters, numbers, underscores, and hyphens"
  exit 1
fi

# An empty verifier model turns verification off.
if [ -n "${VERIFIER_MODEL:-}" ] && ! [[ "$VERIFIER_MODEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "::error::verifier-model must be empty or a Copilot CLI model identifier such as gpt-5.6-sol"
  exit 1
fi

case "${VERIFIER_EFFORT:-low}" in
  none|minimal|low|medium|high|xhigh|max) ;;
  *)
    echo "::error::verifier-effort must be one of none, minimal, low, medium, high, xhigh, max"
    exit 1
    ;;
esac

for setting in "max-verifications=${MAX_VERIFICATIONS:-10}" "max-nits=${MAX_NITS:-3}" \
  "full-files-max-bytes=${FULL_FILES_MAX_BYTES:-60000}" "max-rounds=${MAX_ROUNDS:-3}"; do
  if ! [[ "${setting#*=}" =~ ^[0-9]+$ ]]; then
    echo "::error::${setting%%=*} must be a non-negative integer"
    exit 1
  fi
done

case "${INLINE_COMMENTS:-true}" in
  true|false) ;;
  *)
    echo "::error::inline-comments must be true or false"
    exit 1
    ;;
esac

case "${EVENT_NAME:-}" in
  pull_request|pull_request_target) ;;
  *) skip "AI code review only runs for pull request events." "not-pull-request" ;;
esac

if [ -z "${PR_NUMBER:-}" ] || [ -z "${PR_BASE_SHA:-}" ] || [ -z "${PR_HEAD_SHA:-}" ]; then
  echo "::error::pull request metadata is incomplete"
  exit 1
fi

if [ "${PR_HEAD_REPOSITORY:-}" != "${REPOSITORY:-}" ]; then
  skip "AI code review skips fork pull requests because repository secrets are unavailable." "fork"
fi

if [ "${PR_DRAFT:-false}" = "true" ]; then
  skip "AI code review waits until the pull request is ready for review." "draft"
fi

if [ "$OWNER_ONLY" = "true" ] && [ "${PR_AUTHOR:-}" != "${REPOSITORY_OWNER:-}" ]; then
  skip "AI code review is configured for repository-owner pull requests only." "not-owner"
fi

if [ "$OWNER_ONLY" = "true" ] && [ "${WORKFLOW_ACTOR:-}" != "${REPOSITORY_OWNER:-}" ]; then
  skip "AI code review is configured for workflow activity by the repository owner only." "not-owner-actor"
fi

if [ "$OWNER_ONLY" = "true" ] \
  && [ "${WORKFLOW_TRIGGERING_ACTOR:-}" != "${REPOSITORY_OWNER:-}" ]; then
  skip "AI code review reruns must also be started by the repository owner." "not-owner-triggering-actor"
fi

if [ -z "${COPILOT_GITHUB_TOKEN:-}" ]; then
  # With verify-landed on, the caller asked for a job that fails unless a
  # review landed, so a missing token must not turn into a green skip.
  if [ "${VERIFY_LANDED:-false}" = "true" ] \
    && [ "${ALLOW_MISSING_TOKEN:-false}" != "true" ]; then
    echo "::error::COPILOT_REVIEW_PAT is not set, so this pull request cannot be reviewed. Add the secret, or set allow-missing-token to skip instead."
    exit 1
  fi
  echo "::warning::COPILOT_REVIEW_PAT is not set; skipping AI code review."
  echo "skip=true" >> "$GITHUB_OUTPUT"
  echo "reason=missing-copilot-token" >> "$GITHUB_OUTPUT"
  exit 0
fi

if [ -z "${REVIEW_GITHUB_TOKEN:-}" ]; then
  echo "::error::github-token is required to post the review comment"
  exit 1
fi

echo "skip=false" >> "$GITHUB_OUTPUT"
echo "reason=eligible" >> "$GITHUB_OUTPUT"
