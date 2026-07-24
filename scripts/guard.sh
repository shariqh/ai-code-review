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

if [ "${EVENT_NAME:-}" != "pull_request" ]; then
  skip "AI code review only runs for pull_request events." "not-pull-request"
fi

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

if [ -z "${COPILOT_GITHUB_TOKEN:-}" ]; then
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
