# AI code review

Reviews pull request diffs with GitHub Copilot CLI and maintains a sticky
review comment on the PR for each reviewer model. A finder model reports
findings in a fixed severity vocabulary, a second, cheaper call checks each
one against the code, and only confirmed findings are posted as inline review
comments (see [Findings and verification](#findings-and-verification)).

It comes in two forms:

- a **reusable workflow** (`.github/workflows/review.yml`) that runs one or
  more reviewers in parallel, by default just `gpt-5.6-sol` with
  `gpt-5.6-sol` at low effort as its verifier, and fails a reviewer's job
  when its review did not land on the PR's current head;
- the **composite action** (`action.yml`) it is built on, for a single
  reviewer in a job you write yourself.

Both use high reasoning effort and the long context tier by default, batch
large diffs at file boundaries, disclose any truncation or failed model calls,
and never report a failed or partial review as clean. By default, later
rounds review only the commits since each reviewer's last review (see
[Incremental reviews](#incremental-reviews)), no finding is reported twice,
and a reviewer pauses after three rounds that each left findings (see
[Rounds and repeats](#rounds-and-repeats)).

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
uses: shariqh/ai-code-review/.github/workflows/review.yml@<commit-sha> # v1.5.0
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
| `verifier-model` | no | Overrides the `verifier-model` input |
| `verifier-effort` | no | Overrides the `verifier-effort` input |
| `min-diff-bytes` | no | Review only pull requests whose whole diff is at least this many bytes, or that match `paths` |
| `paths` | no | Review only pull requests that change a path matching one of these shell patterns (comma-separated; `*` also matches `/`), or that reach `min-diff-bytes` |

The default is one reviewer, Sol, whose findings `gpt-5.6-sol` verifies at
low effort before they are posted:

```json
[
  {"name": "Sol", "model": "gpt-5.6-sol", "marker": "ai-code-review-sticky", "timeout-minutes": 30}
]
```

Sol keeps the marker it had as a second reviewer, so its existing comment
carries over. A repository that relied on the earlier default, Astra alone,
gets a new Sol comment; its last Astra comment stays as it was.

To run a second reviewer, pass the full list through `reviewers`, keeping the
default entry and adding another. A reviewer with `min-diff-bytes` or
`paths` reviews only pull requests that are that large or change those
paths, and otherwise skips with a notice and a green job, for example Astra
for large diffs and sensitive paths:

```yaml
with:
  reviewers: >-
    [{"name": "Sol", "model": "gpt-5.6-sol", "marker": "ai-code-review-sticky", "timeout-minutes": 30},
    {"name": "Astra", "model": "gpt-6-astra", "marker": "ai-code-review-sticky-astra", "timeout-minutes": 40,
     "min-diff-bytes": 150000, "paths": "src/billing/*,src/auth/*"}]
```

The conditions are checked against the whole pull request, not the commits
since the last review, so a reviewer that started reviewing a pull request
keeps reviewing it.

Keep the reviewers non-Claude when they review Claude-authored code; an
independent model is the point of the outside opinion. GitHub names each
check `<calling job> / <reviewer name>`, for example `review / Astra`.

### Workflow inputs

| Input | Default | Purpose |
| --- | --- | --- |
| `runs-on` | `ubuntu-latest` | Runner label, or JSON such as `["self-hosted","copilot-review"]` |
| `reviewers` | Sol alone (above) | Reviewer list |
| `timeout-minutes` | `20` | Job timeout for reviewers without their own |
| `cancel-in-progress` | `false` | Cancel a reviewer's running job when a newer push arrives |
| `verify-landed` | `true` | Fail a job whose sticky comment does not cover the current head from this run attempt |
| `allow-missing-token` | `false` | Skip with a warning instead of failing when `COPILOT_REVIEW_PAT` is absent |
| `copilot-cli-version` | `1.0.74` | Exact CLI package version |
| `node-version` | `lts/*` | Node.js version |
| `reasoning-effort` | `high` | Model reasoning effort |
| `context` | `long_context` | Model context tier |
| `verifier-model` | `gpt-5.6-sol` | Model that checks each finding; empty turns verification off |
| `verifier-effort` | `low` | Verifier reasoning effort |
| `max-verifications` | `10` | Maximum verifier calls per reviewer, one per finding |
| `max-nits` | `3` | Maximum Nit findings per review |
| `inline-comments` | `true` | Post each confirmed finding as an inline review comment |
| `batch-max-bytes` | `50000` | Target batch size |
| `file-max-bytes` | `120000` | Per-file review cap |
| `max-batches` | `8` | Maximum finder calls per reviewer |
| `owner-only` | `true` | Require the PR author to own the repository |
| `context-file` | `.github/ai-review-context.md` | Maintainer review context (base branch only; empty disables) |
| `review-file` | `REVIEW.md` | Repository review guide (base branch only; empty disables) |
| `full-files-max-bytes` | `60000` | Bytes of the touched files' head versions sent with each batch; `0` leaves them out |
| `review-scope` | `since-last-review` | Review each pull request in full once, then only the commits since each reviewer's last complete review; `full` reviews it whole every time |
| `max-rounds` | `3` | Pause after this many rounds that left findings; `0` for no cap |

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
| `model` | `gpt-5.6-sol` | Copilot CLI model identifier of the finder |
| `verifier-model` | `gpt-5.6-sol` | Model that checks each finding; empty turns verification off |
| `verifier-effort` | `low` | Verifier reasoning effort |
| `max-verifications` | `10` | Maximum verifier calls, one per finding |
| `max-nits` | `3` | Maximum Nit findings per review |
| `inline-comments` | `true` | Post each confirmed finding as an inline review comment |
| `copilot-cli-version` | `1.0.74` | Exact CLI package version |
| `node-version` | `lts/*` | Node.js version |
| `reasoning-effort` | `high` | Finder reasoning effort |
| `context` | `long_context` | Model context tier, for the finder and the verifier |
| `batch-max-bytes` | `50000` | Target batch size |
| `file-max-bytes` | `120000` | Per-file review cap |
| `max-batches` | `8` | Maximum finder calls |
| `owner-only` | `true` | Require the PR author to own the repository |
| `context-file` | `.github/ai-review-context.md` | Maintainer review context injected into the prompt (base ref only; empty disables) |
| `review-file` | `REVIEW.md` | Repository review guide injected into the prompts (base ref only; empty disables) |
| `full-files-max-bytes` | `60000` | Bytes of the touched files' head versions sent with each batch; `0` leaves them out |
| `comment-marker` | `ai-code-review-sticky` | Sticky comment identifier |
| `verify-landed` | `false` | Fail the job unless the sticky comment covers the current head from this run attempt; a missing `copilot-token` then fails the job too |
| `allow-missing-token` | `false` | With `verify-landed` on, skip with a warning instead of failing when `copilot-token` is empty |
| `review-scope` | `since-last-review` | Review each pull request in full once, then only the commits since this reviewer's last complete review; `full` reviews it whole every time |
| `max-rounds` | `3` | Pause after this many rounds that left findings; `0` for no cap |
| `min-diff-bytes` | `0` | Review only pull requests whose whole diff is at least this many bytes, or that match `paths`; `0` sets no size condition |
| `paths` | empty | Review only pull requests that change a path matching one of these shell patterns (comma- or newline-separated; `*` also matches `/`), or that reach `min-diff-bytes` |

## What the finder sees

The diff is what is under review, but the finder no longer sees only the
diff. Each batch's prompt carries, in this order:

1. the repository's review guide (`review-file`) and maintainer review
   context (`context-file`), both trusted and read from the base branch (see
   [Repository review context](#repository-review-context));
2. the pull request's title and description, and up to two issues it closes
   (`Closes #12`) or its title names (`(#12, part 1)`), read with the
   `github-token`;
3. for an incremental review, the files the whole pull request changes;
4. the batch's diff;
5. the head version of each file in the batch, numbered by line, so the
   finder can check how changed code is called and defined instead of
   guessing: whole files while they fit in `full-files-max-bytes` (60,000
   bytes by default), the 40 KB around a large file's first change, and a
   one-line note for a binary file, a submodule or a symbolic link, which is
   never followed.

The prompt asks the finder to take a trade-off the description records as
decided, or work it says lands in another pull request, as settled, and to
look for callers in the files before it calls code unused or not wired in.
Everything from the pull request, its description and linked issues
included, is marked as untrusted data, with every line prefixed so none can
end its section early.

The Copilot CLI takes the prompt as a single command-line argument, which
Linux caps at 128 KiB, so a prompt is never larger than 130,000 bytes: the
head files take what is left, whole files only, and a batch whose prompt is
over the limit without them is not sent and is listed as not reviewed. A
description over 6,000 bytes, or an issue over 3,000, is cut with a note.

## Findings and verification

The finder answers each batch with one JSON block, which the scripts parse
rather than pass through, so the comment is rendered once from the parsed
findings. (The Copilot CLI prints a reply twice, as Markdown and again as
plain text, and before this every sticky showed both.) Each finding has a
file, a line, a title, the issue, its impact, a fix, and one of three
severities:

| Severity | Meaning | Counted |
| --- | --- | --- |
| `Important` | A defect the pull request introduces that should be fixed before it merges | yes |
| `Nit` | A real but minor problem that need not block the merge | yes |
| `Pre-existing` | A real defect in code the pull request does not change | never |

A severity outside the vocabulary maps onto it (`HIGH` is Important, `LOW` is
Nit), and anything unrecognised counts as Important, so no finding is hidden
by its label. At most `max-nits` Nit findings are reported per review; the
comment says how many more were left out.

Each finding then goes to the verifier (`verifier-model`, by default
`gpt-5.6-sol` at `low` effort), in its own call, with evidence the scripts
gather from the head commit: the file it names, numbered by line (the whole
file, or the 48 KB around the cited line), what the pull request changes in
that file, and where the identifiers the finding names appear in the
repository, from `git grep`, along with the pull request's description and
the repository's review guide and context. It answers `CONFIRMED` or `REFUTED` with a
one-line reason, and is told to refute a finding the evidence contradicts,
such as code called unused that has a caller. At most `max-verifications`
findings are verified per run, Important first.

The sticky comment starts, under its header, with a summary line that opens
with the count of findings to address: confirmed Important and Nit findings.
Confirmed findings follow in full, then confirmed pre-existing issues under
their own heading. Unconfirmed findings, refuted or not verified, are listed
below the fold with the verifier's reason. With `inline-comments` on, the
confirmed findings that sit on a line of the pull request's diff are also
posted as one pull request review, with a comment on each line, after the
sticky comment is written; if that post fails, the job warns and the sticky
still lists them.

The result marker (`<!-- ai-code-review-result: ... -->`) is `findings` when
a confirmed Important or Nit finding counts, when a finding could not be
verified, or when the review was incomplete, and `clean` otherwise, so a
pre-existing issue or a refuted finding alone leaves it clean. With
`verifier-model` empty, verification is off: every finding counts as before,
listed unverified, and none is posted inline.

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

A reply that does not follow the findings format is treated the same way:
its files count as not reviewed, and the reply itself is shown below the fold.
A verification call that fails, or whose reply has no verdict, leaves its
finding unverified and adds a second **Incomplete review** note; if every
verification call failed, the job fails too.

A model that the Copilot seat no longer offers fails every call within
seconds with `Error: Model "<id>" from --model flag is not available.`,
which the log shows as `Error? Model "<id>" from --model flag is not
available.` This is how `gpt-5.4` stopped working in October 2026. Switch
that reviewer to a model the seat offers.

## Repository review context

Repository conventions the reviewer cannot know about (theming contracts,
intentional patterns) surface as recurring false positives. To teach it,
commit a `context-file` (default `.github/ai-review-context.md`) on the
default branch describing those conventions and known false positives, and a
review guide, `review-file` (default `REVIEW.md`), that says what a failure
looks like in this repository, which paths to skip and which decisions are
already taken. When present, each is injected into the finder's and the
verifier's prompts as trusted maintainer guidance, ahead of the untrusted
diff. The scripts do not parse either file; the nit cap is the `max-nits`
input.

The file is read from the **current tip of the PR's base branch** via
`git show` (falling back to the event's base SHA if the remote ref is
unavailable), never from the PR head or the checked-out working tree, so a
pull request cannot rewrite the instructions that review it — edits to
either file take effect only after they land on the base branch, and then
apply to already-open PRs on their next review. Content beyond 16 KB in
either file is truncated with a note.

## Incremental reviews

With the default `review-scope: since-last-review`, the first review of a
pull request is a full review, and each later run reviews only the commits
since the head that reviewer last reviewed, so a push that only fixes the
last round's findings is not reviewed in full again. With
`review-scope: full`, every run reviews the whole pull request. An
incremental review works like this:

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
  request changes (up to 8 KB of names), for orientation. The review guide,
  the maintainer review context and the pull request's description apply as
  usual.
- Batching, truncation and failure disclosure work as for a full review.

The run reviews the whole pull request instead, and the job log says why,
when:

- the reviewer has no sticky comment on the pull request yet, or it cannot be
  read;
- the sticky was written without `since-last-review`, or its header is
  malformed;
- the last review was incomplete: a review or verification call failed,
  coverage was partial, or the round cap paused it;
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
findings from before stand until a full review. The comment lists them under
**Earlier findings still open**, they count in its summary line, and the
`ai-code-review-result` marker stays `findings` even when the new commits
raise nothing. On an incremental review `clean` therefore means that the
review it builds on was clean and the commits since raised nothing.

To review a pull request in full again, run with `review-scope: full`. That
comment records no scope, so the next `since-last-review` run is a full
review too, and later runs build on it.

## Rounds and repeats

Every comment's header, whatever the scope, also records the round count
(`<!-- ai-code-review-round: <n> -->`) and a ledger of the findings reported
so far (`<!-- ai-code-review-ledger: <base64 JSON> -->`): each finding's id,
severity, verdict, round, file, line and title, and whether it is still
open. A round is a run in which a review call completed, so a paused run, a
run with nothing new to review, or one in which every call failed does not
count. The next run reads both from the reviewer's own sticky.

- **Ids.** Findings are numbered `F1`, `F2`, ... across rounds and never
  reused, so an id names one finding for the life of the pull request.
- **No repeats.** The finder's prompt lists the earlier findings that are
  open or were refuted, and tells it never to report them again. A finding
  that does anyway, with the same file and title, is left out, and the
  comment says how many were; one that was not verified is verified again
  under its old id.
- **Closing.** An incremental review leaves earlier findings open. A full
  review that covered every file asks the finder which open findings still
  apply (`still_present`), keeps those open, and closes the rest as fixed.
  A full review that left something out closes nothing.
- **Round cap.** When the last review was round `max-rounds` (3) or later
  and its result was `findings`, the next run calls no model. Its comment
  keeps the earlier findings, says the new commits were not reviewed, and
  asks for the approach to be reconsidered: three rounds that each left
  findings usually mean the change needs splitting or a design decision from
  a person, not another round with the reviewer. Its coverage is recorded as
  incomplete and its result stays `findings`. A round that ended `clean`
  never pauses the next. To start over, delete the reviewer's sticky comment
  and push or re-run: the next run is round 1 and a full review. With
  `max-rounds: 0` there is no cap.

A comment written before the ledger existed has neither line, so the first
run after upgrading starts at round 1 with no earlier findings.

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
  except the maintainer `context-file` and `review-file`, which are read from
  the base branch only — never from the PR head — so PRs cannot influence
  their own review instructions. The head versions of the touched files are
  read from the head commit's objects, not the working tree, and, like the
  pull request's title, description and linked issues, are marked as
  untrusted data. The description and issues are read with the
  `github-token`; an issue it cannot read is left out and the log says so
  (the reusable workflow does not request the `issues` permission).
- Copilot's tool allowlist contains only `report_intent`; file, shell, web, and
  GitHub tools are unavailable. The verifier runs with the same restrictions
  (`copilot_call` in `scripts/lib.sh`). Its evidence is gathered by
  `scripts/review-files.mjs` in a step without the Copilot token, from the
  head commit's objects rather than the working tree, so a symbolic link in
  the pull request is shown as its link text and never followed, and
  `git grep` searches only the commit's tree for fixed strings.
- Model text in the sticky comment cannot open an HTML comment, so a finding
  cannot forge a marker, or close the section it is collapsed in.
- Inline review comments use the same `github-token` and its
  `pull-requests: write` permission; they are posted only after the head is
  rechecked and the sticky comment is written.
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
  [#7](https://github.com/shariqh/ai-code-review/issues/7). The round count
  and the ledger of earlier findings come from the same header, for every
  scope, with the same trust: the ledger is checked field by field and
  ignored whole when anything is malformed, and its titles reach the prompt
  only as untrusted data. Someone who edits it can at most make the reviewer
  skip a finding as a repeat, or pause it early.
- The PR head is rechecked before the sticky comment changes.

The review is advisory and is not a substitute for human review.

## Development

Run the dependency-free test suite:

```sh
bash tests/test.sh
```

Score a prompt or model change against the eval fixtures before a release,
and tally authors' answers to posted findings, with the tools in
[`evals/`](evals/README.md).
