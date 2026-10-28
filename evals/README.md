# Evals

A fixture set of pull requests with known outcomes, to score every prompt or
model change against before a release, and a tally of how authors answered
the findings that were posted. This is the start of the set described in
[#9](https://github.com/shariqh/ai-code-review/issues/9): the target is the
three confirmed real catches and four false-positive classes from the oris
sample, and two fixtures are here so far.

```text
evals/
  fixtures/<id>/fixture.json   one pull request at one head, and what a review of it must do
  run-fixture.sh               reviews a fixture locally with the action's own scripts, then scores it
  score.mjs                    scores a review's review.json against a fixture
  tally-responses.mjs          tallies review-response comments
```

## Fixtures

Each fixture is one pull request at one head commit, reviewed in full:

| Key | Meaning |
| --- | --- |
| `version` | `1` |
| `id` | The directory name, `<repository>-<pull request>` |
| `repository`, `pull_request` | Where the pull request is, for its description |
| `private` | `true` when the repository is private (see below) |
| `base`, `head` | The merge base and the head commit the review covers |
| `source` | Where the expected outcome comes from |
| `expectations` | What a review of it must do |

Each expectation has an `id`, a `kind` and a `note`, and says which findings
it is about:

| Key | Meaning |
| --- | --- |
| `kind` | `real-catch`: a posted finding must match. `false-positive`: no posted finding may match, whether the verifier refuted it or the finder no longer reports it |
| `class` | For a false positive: `not-wired`, `wrong-library-fact`, `stacked-pr` or `decided-trade-off` |
| `locations` | Files, each as `path_sha256` (the SHA-256 of its path) and optionally `lines` (first and last), give or take 10 lines |
| `severity` | The severities a matching finding may have; any when absent |
| `keywords` | Words one of which a matching finding's text contains |

A finding matches when it is in one of the locations, has an allowed
severity, and its text matches the class's pattern (`score.mjs` has one for
`not-wired`) or contains a keyword, when the expectation has either. Posted
means confirmed by the verifier, or listed unverified because verification
was off.

This repository is public. A fixture drawn from a private repository holds
nothing from it but commit SHAs, hashed paths, line ranges, class names,
generic keywords and a one-line note: the diff, the files and the
description are read at run time by someone with access.

| Fixture | Expectations |
| --- | --- |
| `oris-1605` | A real catch (a new table's rows outlive the deletion path), and a `not-wired` false positive that recurred three rounds |
| `oris-1613` | A `stacked-pr` false positive: work the description assigns to the stacked part 2, reported as missing |

## Running a fixture

```sh
git clone https://github.com/shariqh/oris /tmp/oris
COPILOT_GITHUB_TOKEN=... evals/run-fixture.sh evals/fixtures/oris-1605/fixture.json /tmp/oris
```

It runs `prepare-review.sh`, `pr-context.sh` (with `gh`'s login),
`run-review.sh`, the verifier's evidence step, `verify-findings.sh` and the
render step, as the action does, with the action's defaults and any of its
environment variables overriding them, and posts nothing. It prints the
summary line, writes the run's findings to `review.json` in the work
directory, and prints one `PASS` or `FAIL` line per expectation, exiting 1
if any failed. Every model call is billed to the token's Copilot seat. To
score a review made elsewhere, pass its `review.json` to `score.mjs`.

## Author responses

When an author answers the findings on a pull request, a comment whose first
line is `review-response` gives one answer per finding, by id:

```text
review-response
Sol F3 wrong: helper() is called from app.ts:177
F4 fixed
F5 intentional: decided in #12
F6 pre-existing
```

The answers are `fixed`, `wrong`, `intentional` and `pre-existing`. The
reviewer's name in front of the id is optional; it tells reviewers apart on
a pull request with more than one. A later answer to the same finding
replaces an earlier one. `tally-responses.mjs` reads issue comments as the
API returns them, from any number of pull requests, and prints the counts
and shares of each answer, per reviewer and per pull request:

```sh
for pr in 1605 1613; do
  gh api "repos/shariqh/oris/issues/$pr/comments" --paginate
done | node evals/tally-responses.mjs
```
