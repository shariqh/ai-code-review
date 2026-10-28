// Scores one review of an eval fixture against the fixture's expectations.
//
//   node evals/score.mjs <fixture.json> <review.json>
//
// review.json is what scripts/findings.mjs render writes into the review work
// directory: every finding of the run with its verdict. evals/run-fixture.sh
// produces one.
//
// An expectation of kind "real-catch" passes when a posted finding matches it:
// confirmed by the verifier, or listed unverified because verification was
// off. One of kind "false-positive" passes when no posted finding matches it,
// whether the verifier refuted it or the finder no longer reports it.
//
// A finding matches an expectation when:
// - the SHA-256 of its path is one of the expectation's locations, and its
//   line is within that location's lines, give or take LINE_SLACK, when the
//   location has lines;
// - its severity is one the expectation allows, when it lists any; and
// - its title, issue, impact and fix match the class's pattern (CLASSES),
//   or contain one of the expectation's keywords, when it has either.
//
// Prints one PASS or FAIL line per expectation and exits 1 if any failed.
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

export const LINE_SLACK = 10;

// False-positive classes a pattern can recognise. The others (a wrong
// library fact, a stacked pull request, a decided trade-off) are matched by
// location and keywords.
export const CLASSES = {
  "not-wired": /\b(dead code|never (imported|called|invoked|used|wired)|not (wired|called|imported|invoked|used|reachable)|no (callers?|call sites?)|unused|unreachable)\b/i,
};

const POSTED = new Set(["confirmed", "skipped"]);

function sha256(text) {
  return createHash("sha256").update(text).digest("hex");
}

export function matches(expectation, finding) {
  const locations = expectation.locations ?? [];
  if (locations.length > 0) {
    const hash = sha256(finding.path ?? "");
    const located = locations.some((location) => {
      if (location.path_sha256 !== hash) return false;
      if (!Array.isArray(location.lines)) return true;
      const [first, last] = location.lines;
      return Number.isInteger(finding.line)
        && finding.line >= first - LINE_SLACK && finding.line <= last + LINE_SLACK;
    });
    if (!located) return false;
  }
  if (Array.isArray(expectation.severity) && !expectation.severity.includes(finding.severity)) return false;
  const text = [finding.title, finding.issue, finding.impact, finding.fix].join("\n");
  const pattern = CLASSES[expectation.class];
  const keywords = expectation.keywords ?? [];
  if (!pattern && keywords.length === 0) return true;
  return (pattern ? pattern.test(text) : false)
    || keywords.some((keyword) => text.toLowerCase().includes(keyword.toLowerCase()));
}

export function score(fixture, review) {
  const posted = (review.findings ?? []).filter((finding) => POSTED.has(finding.verdict));
  return fixture.expectations.map((expectation) => {
    const hits = posted.filter((finding) => matches(expectation, finding));
    const pass = expectation.kind === "real-catch" ? hits.length > 0 : hits.length === 0;
    const detail = hits.length > 0
      ? `posted ${hits.map((finding) => `${finding.id} (${finding.severity}, line ${finding.line ?? "none"})`).join(", ")}`
      : "no posted finding matches";
    return { id: expectation.id, kind: expectation.kind, pass, detail };
  });
}

function main([fixturePath, reviewPath]) {
  if (!fixturePath || !reviewPath) throw new Error("usage: score.mjs <fixture.json> <review.json>");
  const fixture = JSON.parse(readFileSync(fixturePath, "utf8"));
  const review = JSON.parse(readFileSync(reviewPath, "utf8"));
  const results = score(fixture, review);
  for (const result of results) {
    console.log(`${result.pass ? "PASS" : "FAIL"} ${fixture.id} ${result.id} (${result.kind}): ${result.detail}`);
  }
  return results.every((result) => result.pass) ? 0 : 1;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  process.exitCode = main(process.argv.slice(2));
}
