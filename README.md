# AI code review

Reviews pull request diffs with GitHub Copilot CLI and maintains a sticky
review comment on the PR for each reviewer model.

It comes in two forms:

- a **reusable workflow** (`.github/workflows/review.yml`) that runs several
  reviewers in parallel, by default `gpt-5.6-sol` and `gpt-6-astra`, and
  fails a reviewer's job when its review did not land on the PR's current
  head;
- the **composite action** (`action.yml`) it is built on, for a single
  reviewer in a job you write yourself.

Both use high reasoning effort and the long context tier by default, batch
large diffs at file boundaries, disclose any truncation or failed model calls,
and never report a failed or partial review as clean.

## Copilot token

Add a repository secret named `COPILOT_REVIEW_PAT`. It must be a fine-grained
personal access token with:

- Account permission: **Copilot Requests**
- Repository access: every repository that will run reviews

The Copilot CLI uses the token owner's Copilot seat and model allowance.

## Use the reusable workflow

Copy [`examples/reusable-workflow.yml`](examples/reusable-workflow.yml) into
the consumer repository as `.github/workflows/ai-code-review.yml`.

The example uses `pull_request_target`. GitHub loads that workflow from the
repository's default branch, including its reference to the reusable
workflow, so a pull request cannot replace the trusted workflow before secrets
are made available. It also means a pull request that changes the calling
workflow is reviewed by the default branch's version until it merges. The
review checks out the PR head only as data and never executes repository code.

Pin the call to a release commit SHA:

```yaml
uses: shariqh/ai-code-review/.github/workflows/review.yml@<commit-sha> # v1.2.0
```

Each reviewer job checks out this repository at the commit it was called at
(`job.workflow_sha`) and runs the action from that checkout, so the pin covers
the action code too. That needs GitHub.com and Actions runner v2.334.0 or
newer; on anything older the job fails with an error saying so.

Pass the Copilot token explicitly rather than with `secrets: inherit`, so the
reviewer jobs receive only that secret.

### Reviewers

The `reviewers` input is a JSON array with one entry per reviewer. Each runs
as its own job, posts its own sticky comment and has its own concurrency
queue, so reviewers never cancel or wait for each other, and one failing does
not stop the others.

| Key | Required | Purpose |
| --- | --- | --- |
| `model` | yes | Copilot CLI model identifier |
| `marker` | yes | Sticky comment identifier; every reviewer needs its own |
| `name` | no | Job name, defaulting to the model |
| `timeout-minutes` | no | Job timeout, defaulting to the `timeout-minutes` input |
| `reasoning-effort` | no | Overrides the `reasoning-effort` input |
| `context` | no | Overrides the `context` input |

The default is:

```json
[
  {"name": "Sol", "model": "gpt-5.6-sol", "marker": "ai-code-review-sticky"},
  {"name": "Astra", "model": "gpt-6-astra", "marker": "ai-code-review-sticky-astra", "timeout-minutes": 40}
]
```

Keep the reviewers non-Claude when they review Claude-authored code; an
independent model is the point of the second opinion. GitHub names each
check `<calling job> / <reviewer name>`, for example `review / Astra`.

### Workflow inputs

| Input | Default | Purpose |
| --- | --- | --- |
| `runs-on` | `ubuntu-latest` | Runner label, or JSON such as `["self-hosted","copilot-review"]` |
| `reviewers` | Sol and Astra (above) | Reviewer list |
| `timeout-minutes` | `20` | Job timeout for reviewers without their own |
| `cancel-in-progress` | `false` | Cancel a reviewer's running job when a newer push arrives |
| `verify-landed` | `true` | Fail a job whose sticky comment does not cover the current head from this run |
| `copilot-cli-version` | `1.0.74` | Exact CLI package version |
| `node-version` | `lts/*` | Node.js version |
| `reasoning-effort` | `high` | Model reasoning effort |
| `context` | `long_context` | Model context tier |
| `batch-max-bytes` | `50000` | Target batch size |
| `file-max-bytes` | `120000` | Per-file review cap |
| `max-batches` | `8` | Maximum model calls per reviewer |
| `owner-only` | `true` | Require the PR author to own the repository |
| `context-file` | `.github/ai-review-context.md` | Maintainer review context (base branch only; empty disables) |

The only secret is `COPILOT_REVIEW_PAT`. Without it the review is skipped with
a warning.

`cancel-in-progress` is off because a review takes longer than a fast push
cycle: cancelling on every push can stop every review from finishing. With it
off, a running review always finishes and the newest push waits as the single
pending run. A review that finished after a newer push landed then fails the
`verify-landed` check instead of reporting success for a head it did not
review.

## Use the action directly

Copy [`examples/ai-code-review.yml`](examples/ai-code-review.yml) into the
consumer repository as `.github/workflows/ai-code-review.yml`. It runs one
reviewer, and the same `pull_request_target` reasoning applies. Pin the action
to a release commit SHA once the pilot works.

## Organization repositories

The examples intentionally restrict personal repositories to PRs authored by
the repository owner. In an organization repository,
`github.repository_owner` is the organization rather than a user. Remove the
author clause from the job-level `if` and disable the matching
defense-in-depth guard. With the reusable workflow:

```yaml
jobs:
  review:
    if: >-
      github.event.pull_request.head.repo.full_name == github.repository &&
      github.event.pull_request.draft == false
    uses: shariqh/ai-code-review/.github/workflows/review.yml@<commit-sha>
    with:
      owner-only: false
    secrets:
      COPILOT_REVIEW_PAT: ${{ secrets.COPILOT_REVIEW_PAT }}
```

With the action:

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

Organization policy may need to allow actions and reusable workflows from
`shariqh/ai-code-review` before this can run.

## Self-hosted runners

The caller controls the runner, so the same review can use a dedicated
lane. With the reusable workflow, pass it as JSON:

```yaml
with:
  runs-on: '["self-hosted","copilot-review"]'
```

With the action, set the job's own `runs-on`:

```yaml
runs-on: [self-hosted, copilot-review]
```

The runner must be Linux with Bash, Git, and GitHub CLI (`gh`). The action
installs its pinned Node.js and Copilot CLI versions. Standard Unix utilities
such as `awk`, `sed`, `grep`, `head`, `wc`, `sort`, `tail`, and `tr` must also
be present.

## Action inputs

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
| `context-file` | `.github/ai-review-context.md` | Maintainer review context injected into the prompt (base ref only; empty disables) |
| `comment-marker` | `ai-code-review-sticky` | Sticky comment identifier |
| `verify-landed` | `false` | Fail the job unless the sticky comment covers the current head from this run |

## When a review call fails

A failed model call is listed in the sticky comment's **Incomplete review**
note, and the Copilot CLI's error output is printed in the job log under the
review step, at most 4,000 bytes and 40 lines, with token-like strings
redacted. If every call failed, the job fails after posting the comment, so
nothing reports success over a review that never happened; a partial failure
is a warning.

A model that the Copilot seat no longer offers fails every call within
seconds with `Error: Model "<id>" from --model flag is not available.` (this
is how `gpt-5.4` stopped working in October 2026). Switch that reviewer to a
model the seat offers.

## Repository review context

The reviewer sees only the diff, so repository conventions it cannot know
about (theming contracts, intentional patterns) surface as recurring false
positives. To teach it, commit a `context-file` (default
`.github/ai-review-context.md`) on the default branch describing those
conventions and known false positives. When present, its content is injected
into the prompt as trusted maintainer guidance, ahead of the untrusted diff.

The file is read from the **current tip of the PR's base branch** via
`git show` (falling back to the event's base SHA if the remote ref is
unavailable), never from the PR head or the checked-out working tree, so a
pull request cannot rewrite the instructions that review it — edits to the
context file take effect only after they land on the base branch, and then
apply to already-open PRs on their next review. Content beyond 16 KB is
truncated with a note.

## Security model

- Fork PRs and drafts are skipped.
- The caller must use `pull_request_target` and keep the job-level guard from
  the examples (and, for the action, the concurrency block). A secret-bearing
  `pull_request` workflow is mutable by the PR branch and is unsafe on a
  persistent self-hosted runner.
- Personal-repository reviews require the PR author, workflow actor, and rerun
  actor to match the repository owner.
- The pinned Copilot CLI is installed before PR checkout, from the public npm
  registry, in the runner temp directory, with project npm configuration and
  lifecycle scripts disabled.
- Checkout does not persist `GITHUB_TOKEN` credentials.
- PR contents are checked out into an isolated subdirectory and removed after
  the review, including on persistent self-hosted runners.
- Copilot receives the diff inline and loads no repository instructions,
  except the maintainer `context-file`, which is read from the base branch
  only — never from the PR head — so PRs cannot influence their own review
  prompt.
- Copilot's tool allowlist contains only `report_intent`; file, shell, web, and
  GitHub tools are unavailable.
- Built-in MCP servers and remote session export are disabled.
- `COPILOT_GITHUB_TOKEN` is marked as a secret environment variable so it is
  removed from tool environments and redacted from output. CLI error output
  printed after a failed call is also stripped of token-like strings and
  prefixed line by line, so it cannot issue workflow commands.
- The reusable workflow checks out this repository at its own pinned commit
  without persisting credentials, and requests only `contents: read` and
  `pull-requests: write`.
- Only bot-authored comments containing this action's marker are updated.
- The PR head is rechecked before the sticky comment changes.

The review is advisory and is not a substitute for human review.

## Development

Run the dependency-free test suite:

```sh
bash tests/test.sh
```
