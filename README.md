# AI code review

A composite GitHub Action that reviews pull request diffs with GitHub Copilot
CLI and maintains one sticky review comment on the PR.

The default reviewer is `gpt-5.6-sol`, with high reasoning effort and the long
context tier. The action batches large diffs at file boundaries, discloses any
truncation or failed model calls, and never reports a failed or partial review
as clean.

## Use it

Copy [`examples/ai-code-review.yml`](examples/ai-code-review.yml) into the
consumer repository as `.github/workflows/ai-code-review.yml`.

The example uses `pull_request_target`. GitHub loads that workflow and its
action reference from the repository's default branch, so a pull request cannot
replace the trusted workflow before secrets are made available. The action
checks out the PR head only as data and never executes repository code.

For the first pilot, the example follows `@main`. After the pilot is successful,
pin the action to an immutable commit SHA. A moving `v1` tag will be created
after the initial rollout is proven.

Add a repository secret named `COPILOT_REVIEW_PAT`. It must be a fine-grained
personal access token with:

- Account permission: **Copilot Requests**
- Repository access: every repository that will run reviews

The Copilot CLI uses the token owner's Copilot seat and model allowance.

## Organization repositories

The example intentionally restricts personal repositories to PRs authored by
the repository owner. In an organization repository,
`github.repository_owner` is the organization rather than a user. Remove the
author clause from the job-level `if` and disable the action's matching
defense-in-depth guard:

```yaml
jobs:
  review:
    if: >-
      github.event.pull_request.head.repo.full_name == github.repository &&
      github.event.pull_request.draft == false
    runs-on: ubuntu-latest
    timeout-minutes: 20
    steps:
      - uses: shariqh/ai-code-review@main
        with:
          copilot-token: ${{ secrets.COPILOT_REVIEW_PAT }}
          github-token: ${{ github.token }}
          owner-only: false
```

Organization policy may need to allow actions from `shariqh/ai-code-review`
before this can run.

## Self-hosted runners

The caller controls `runs-on`, so the same action can use a dedicated review
lane:

```yaml
runs-on: [self-hosted, copilot-review]
```

The runner must be Linux with Bash, Git, and GitHub CLI (`gh`). The action
installs its pinned Node.js and Copilot CLI versions. Standard Unix utilities
such as `awk`, `sed`, `grep`, `head`, `wc`, `sort`, `tail`, and `tr` must also
be present.

## Inputs

| Input | Default | Purpose |
| --- | --- | --- |
| `copilot-token` | required | PAT used by Copilot CLI |
| `github-token` | required | Caller `github.token` used for PR comments |
| `model` | `gpt-5.6-sol` | Copilot CLI model identifier |
| `copilot-cli-version` | `1.0.74` | Exact CLI package version |
| `node-version` | `lts/*` | Node.js version |
| `reasoning-effort` | `high` | Model reasoning effort |
| `context` | `long_context` | Model context tier |
| `batch-max-bytes` | `50000` | Target batch size |
| `file-max-bytes` | `120000` | Per-file review cap |
| `max-batches` | `8` | Maximum model calls |
| `owner-only` | `true` | Require the PR author to own the repository |
| `comment-marker` | `ai-code-review-sticky` | Sticky comment identifier |

## Security model

- Fork PRs and drafts are skipped.
- The caller must use `pull_request_target` and keep the job-level guard and
  concurrency from the example. A secret-bearing `pull_request` workflow is
  mutable by the PR branch and is unsafe on a persistent self-hosted runner.
- Personal-repository reviews require the PR author, workflow actor, and rerun
  actor to match the repository owner.
- The pinned Copilot CLI is installed before PR checkout, from the public npm
  registry, in the runner temp directory, with project npm configuration and
  lifecycle scripts disabled.
- Checkout does not persist `GITHUB_TOKEN` credentials.
- PR contents are checked out into an isolated subdirectory and removed after
  the review, including on persistent self-hosted runners.
- Copilot receives the diff inline and loads no repository instructions.
- Copilot's tool allowlist contains only `report_intent`; file, shell, web, and
  GitHub tools are unavailable.
- Built-in MCP servers and remote session export are disabled.
- `COPILOT_GITHUB_TOKEN` is marked as a secret environment variable so it is
  removed from tool environments and redacted from output.
- Only bot-authored comments containing this action's marker are updated.
- The PR head is rechecked before the sticky comment changes.

The review is advisory and is not a substitute for human review.

## Development

Run the dependency-free test suite:

```sh
bash tests/test.sh
```
