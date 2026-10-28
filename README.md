# AI code review

Reviews pull request diffs with GitHub Copilot CLI and maintains a sticky
review comment on the PR for each reviewer model.

It comes in two forms:

- a **reusable workflow** (`.github/workflows/review.yml`) that runs one or
  more reviewers in parallel, by default just `gpt-6-astra`, and
  fails a reviewer's job when its review did not land on the PR's current
  head;
- the **composite action** (`action.yml`) it is built on, for a single
  reviewer in a job you write yourself.

Both use high reasoning effort and the long context tier by default, batch
large diffs at file boundaries, disclose any truncation or failed model calls,
and never report a failed or partial review as clean. Optionally, later
rounds review only the commits since each reviewer's last review (see
[Incremental reviews](#incremental-reviews)).

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
uses: shariqh/ai-code-review/.github/workflows/review.yml@<commit-sha> # v1.4.0
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

The default is one reviewer, Astra:

```json
[
  {"name": "Astra", "model": "gpt-6-astra", "marker": "ai-code-review-sticky-astra", "timeout-minutes": 40}
]
```

To run a second reviewer, pass the full list through `reviewers`, keeping the
default entry and adding another, for example Sol:

```yaml
with:
  reviewers: >-
    [{"name": "Astra", "model": "gpt-6-astra", "marker": "ai-code-review-sticky-astra", "timeout-minutes": 40},
    {"name": "Sol", "model": "gpt-5.6-sol", "marker": "ai-code-review-sticky"}]
```

Keep the reviewers non-Claude when they review Claude-authored code; an
independent model is the point of the outside opinion. GitHub names each
check `<calling job> / <reviewer name>`, for example `review / Astra`.

### Workflow inputs

| Input | Default | Purpose |
| --- | --- | --- |
| `runs-on` | `ubuntu-latest` | Runner label, or JSON such as `["self-hosted","copilot-review"]` |
| `reviewers` | Astra alone (above) | Reviewer list |
| `timeout-minutes` | `20` | Job timeout for reviewers without their own |
| `cancel-in-progress` | `false` | Cancel a reviewer's running job when a newer push arrives |
| `verify-landed` | `true` | Fail a job whose sticky comment does not cover the current head from this run attempt |
| `allow-missing-token` | `false` | Skip with a warning instead of failing when `COPILOT_REVIEW_PAT` is absent |
| `copilot-cli-version` | `1.0.74` | Exact CLI package version |
| `node-version` | `lts/*` | Node.js version |
| `reasoning-effort` | `high` | Model reasoning effort |
| `context` | `long_context` | Model context tier |
| `batch-max-bytes` | `50000` | Target batch size |
| `file-max-bytes` | `120000` | Per-file review cap |
| `max-batches` | `8` | Maximum model calls per reviewer |
| `owner-only` | `true` | Require the PR author to own the repository |
| `context-file` | `.github/ai-review-context.md` | Maintainer review context (base branch only; empty disables) |
| `review-scope` | `full` | `since-last-review` reviews each pull request in full once, then only the commits since each reviewer's last complete review |

The only secret is `COPILOT_REVIEW_PAT`. Without it, a reviewer job on an
eligible pull request fails, since `verify-landed` asks for a job that fails
unless a review landed. Set `allow-missing-token` for a smoke test that runs
without the secret; the job then skips with a warning.

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
| `verify-landed` | `false` | Fail the job unless the sticky comment covers the current head from this run attempt; a missing `copilot-token` then fails the job too |
| `allow-missing-token` | `false` | With `verify-landed` on, skip with a warning instead of failing when `copilot-token` is empty |
| `review-scope` | `full` | `since-last-review` reviews each pull request in full once, then only the commits since this reviewer's last complete review |

## When a review call fails

A failed model call is listed in the sticky comment's **Incomplete review**
note, and the end of the Copilot CLI's error output is printed in the job log
under the review step: the last 10 lines and at most 1,000 bytes, which is
where a failure names its cause. Credentials are redacted from the whole
output before it is cut, and punctuation outside a small allowlist is shown
as `?`. A call that exits successfully with an empty reply counts as failed
too, since it reviewed nothing. If every call failed, the job fails after
posting the comment, so nothing reports success over a review that never
happened; a partial failure is a warning.

A model that the Copilot seat no longer offers fails every call within
seconds with `Error: Model "<id>" from --model flag is not available.`,
which the log shows as `Error? Model "<id>" from --model flag is not
available.` This is how `gpt-5.4` stopped working in October 2026. Switch
that reviewer to a model the seat offers.

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

## Incremental reviews

By default every run reviews the whole pull request, so a push that only
fixes the last round's findings is reviewed in full again. With
`review-scope: since-last-review`, the first review of a pull request is a
full review, and each later run reviews only the commits since the head that
reviewer last reviewed:

- The previous head is the reviewed commit in the reviewer's own sticky
  comment, never the push event's `before`, so only a review that landed
  counts; a run that a newer push cancelled never does.
- The diff is `git diff <previous head> <head>`, limited to the files the pull
  request itself changes: those that differ between the base and the previous
  head, or between the base and the new head. A merge of the base branch into
  the pull request is therefore not reviewed as its own change, while a file
  it changed and then reverted still is. As for the review context, the base
  is the base branch's current tip, or the event's base SHA when the checkout
  lacks it.
- The prompt says the review is incremental and lists the files the whole pull
  request changes (up to 8 KB of names), for orientation. The maintainer
  review context applies as usual.
- Batching, truncation and failure disclosure work as for a full review.

The run reviews the whole pull request instead, and the job log says why,
when:

- the reviewer has no sticky comment on the pull request yet, or it cannot be
  read;
- the sticky was written without `since-last-review`, or its header is
  malformed;
- the last review was incomplete: a review call failed, or coverage was
  partial;
- the last reviewed head is not an ancestor of the new head, as after a
  force-push or rebase, or the checkout lacks it and fetching it fails;
- the base changed since the last review: the pull request was retargeted to
  another branch, or its base branch was rewound or rewritten, which can make
  commits that review took for the base's own part of the pull request (a
  base that only moved forward is fine);
- the incremental diff cannot be built, for example because the base and the
  head share no history.

A full review, including a fallback, adds no visible line. An incremental
review keeps the `_Reviewed commit: <head>_` line, so `verify-landed` and
anything else that reads it work unchanged, and adds a line below it:

> **Incremental review** of `<previous head>..<head>`; the full review was at `<sha>`.

`<sha>` is the head the full review covered, carried forward from round to
round. When none of the pull request's files changed since the last review,
for example after merging the base branch in or when a run is re-run on the
same head, no model is called: the comment says there was nothing new to
review and keeps the last review's result.

Under `since-last-review` the comment's header also records, for the next
run, the full review's commit (`<!-- ai-code-review-full-review: <sha> -->`),
the base branch and merge base the review was diffed against
(`<!-- ai-code-review-base: <branch> <sha> -->`, written only for a branch
name of letters, digits and `. _ / -`, so any other name means full reviews),
and whether the review covered everything
(`<!-- ai-code-review-coverage: complete -->` or `incomplete`).

An incremental review re-checks only the commits since the last review, so
findings from before stand until a full review. After a review with findings,
the `ai-code-review-result` marker stays `findings` even when the new commits
raise nothing, and the comment says that the earlier findings were not
re-checked. On an incremental review `clean` therefore means that the review
it builds on was clean and the commits since raised nothing.

To review a pull request in full again, run with `review-scope: full`. That
comment records no scope, so the next `since-last-review` run is a full
review too, and later runs build on it.

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
  printed after a failed call goes through `scripts/sanitize-stderr.mjs`,
  which first strips terminal control sequences, then redacts credentials in
  the whole output, case-insensitively: the token value, Authorization,
  Cookie and X-Api-Key header values, Basic and Bearer credentials, values
  labelled as a token, password, secret or API key, and GitHub, JWT and
  Copilot session token shapes. Only then does it keep the last 10 lines and
  1,000 bytes, so the cut cannot leave a fragment of a credential behind.
  Because the output can quote the diff, every character outside a small
  allowlist (letters, digits, space and `. , _ - ' " /` `=`) becomes `?`, so
  no colon, `#`, bracket or parenthesis survives. That leaves nothing for the
  runner's workflow commands (`::command::`, or the legacy `##[command]`
  anywhere in a line) or for the problem matchers setup-node registers
  (eslint-compact, eslint-stylish, tsc) to act on. As defence in depth it is
  printed inside a `::stop-commands::` block with a random per-call resume
  token, which stops commands but not matchers, and each line carries a
  prefix.
- The reusable workflow checks out this repository at its own pinned commit
  without persisting credentials, and requests only `contents: read` and
  `pull-requests: write`.
- A reviewer's sticky comment is the bot-authored comment whose first line is
  exactly its marker. Only those are updated or deleted, so a review that
  quotes another reviewer's marker cannot take over that reviewer's comment.
- The reviewed commit, run id and run attempt are read only from the
  comment's header, which ends before any model output, so quoted copies of
  those lines further down are ignored.
- With `review-scope: since-last-review`, the previous head comes from the
  same header of the reviewer's own sticky, read with the same `github-token`
  that posts it. It is used only if it is a full 40-hex commit SHA from a
  complete review, the base branch is the same one and has not been rewound
  past the recorded merge base, and the SHA is an ancestor of the PR head.
  Every value is checked against a strict pattern before it reaches git or
  the prompt, and no comment text reaches a shell command. Besides reading the
  PR's comments, the only added network access is one
  `git fetch --no-tags --no-recurse-submodules origin <sha>`, without
  credentials, when the checkout lacks that commit. The PR's file names, which
  the prompt lists, are marked as untrusted data like the diff. It trusts
  anyone with write access to the repository, who can edit the bot's sticky
  or post one as `github-actions[bot]` and so narrow the next review, just as
  they can already read the workflow's secrets; later hardening is tracked in
  [#7](https://github.com/shariqh/ai-code-review/issues/7).
- The PR head is rechecked before the sticky comment changes.

The review is advisory and is not a substitute for human review.

## Development

Run the dependency-free test suite:

```sh
bash tests/test.sh
```
