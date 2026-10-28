// Tallies authors' answers to review findings, from `review-response`
// comments on pull requests.
//
//   gh api repos/<owner>/<repo>/issues/<n>/comments --paginate > comments.json
//   node evals/tally-responses.mjs comments.json [more.json ...]
//
// The input is issue comments as the GitHub API returns them; gh prints one
// JSON array per page, and any number of arrays, from any number of pull
// requests, can be concatenated, in files or on stdin.
//
// A response is a comment whose first non-empty line is `review-response`,
// with one line per finding after it:
//
//   [reviewer] F<n> fixed | wrong | intentional | pre-existing [: reason]
//
// for example `Sol F3 wrong: imported at app.ts:177`, or `F4 fixed`. The
// reviewer is optional and names whose finding it is, for a pull request
// with more than one reviewer. A later answer to the same finding on the same
// pull request replaces an earlier one. Lines that are not answers are
// ignored.
//
// Prints JSON: the number of answers, the count and share of each answer,
// the counts per reviewer and per pull request, and every answer.
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

export const ANSWERS = ["fixed", "wrong", "intentional", "pre-existing"];

// Concatenated JSON values, as gh --paginate prints them.
export function parseConcatenated(text) {
  const values = [];
  let depth = 0;
  let start = -1;
  let inString = false;
  let escaped = false;
  for (let index = 0; index < text.length; index += 1) {
    const character = text[index];
    if (inString) {
      if (escaped) escaped = false;
      else if (character === "\\") escaped = true;
      else if (character === '"') inString = false;
      continue;
    }
    if (character === '"') {
      inString = true;
    } else if (character === "[" || character === "{") {
      if (depth === 0) start = index;
      depth += 1;
    } else if (character === "]" || character === "}") {
      depth -= 1;
      if (depth === 0) values.push(JSON.parse(text.slice(start, index + 1)));
    }
  }
  if (depth !== 0) throw new Error("the input ends inside a JSON value");
  return values;
}

function pullRequestOf(comment) {
  const match = /\/(?:issues|pull)\/([0-9]+)/.exec(comment.issue_url ?? comment.html_url ?? "");
  return match ? Number(match[1]) : null;
}

const ANSWER_LINE = new RegExp(
  `^\\s*(?:[-*]\\s+)?(?:([A-Za-z][\\w.-]*)\\s+)?(F[0-9]+)\\s*[:\\-\\u2013\\u2014]?\\s*(${ANSWERS.join("|")})\\b\\s*[:\\-\\u2013\\u2014]?\\s*(.*)$`,
  "i",
);

export function answersIn(comment) {
  const lines = (comment.body ?? "").replace(/\r\n?/g, "\n").split("\n");
  const first = lines.findIndex((line) => line.trim() !== "");
  if (first < 0 || lines[first].trim().toLowerCase() !== "review-response") return [];
  const answers = [];
  for (const line of lines.slice(first + 1)) {
    const match = ANSWER_LINE.exec(line);
    if (!match) continue;
    answers.push({
      pull_request: pullRequestOf(comment),
      reviewer: match[1] ?? "",
      finding: match[2].toUpperCase(),
      answer: match[3].toLowerCase(),
      reason: match[4].trim(),
      author: comment.user?.login ?? "",
      created_at: comment.created_at ?? "",
    });
  }
  return answers;
}

export function tally(comments) {
  const latest = new Map();
  const ordered = [...comments].sort((a, b) => String(a.created_at ?? "").localeCompare(String(b.created_at ?? "")));
  for (const comment of ordered) {
    for (const answer of answersIn(comment)) {
      latest.set(`${answer.pull_request}\n${answer.reviewer.toLowerCase()}\n${answer.finding}`, answer);
    }
  }
  const answers = [...latest.values()];
  const count = (list) => Object.fromEntries(ANSWERS.map((name) => [name, list.filter((a) => a.answer === name).length]));
  const group = (key) => {
    const groups = {};
    for (const answer of answers) (groups[answer[key] || "(unnamed)"] ??= []).push(answer);
    return Object.fromEntries(Object.entries(groups).map(([name, list]) => [name, count(list)]));
  };
  const counts = count(answers);
  return {
    answers: answers.length,
    counts,
    shares: Object.fromEntries(ANSWERS.map((name) => [name,
      answers.length === 0 ? 0 : Math.round((counts[name] / answers.length) * 1000) / 1000])),
    by_reviewer: group("reviewer"),
    by_pull_request: group("pull_request"),
    responses: answers,
  };
}

function main(paths) {
  const texts = paths.length > 0 ? paths.map((path) => readFileSync(path, "utf8")) : [readFileSync(0, "utf8")];
  const comments = texts.flatMap(parseConcatenated).flatMap((value) => (Array.isArray(value) ? value : [value]));
  console.log(JSON.stringify(tally(comments), null, 2));
  return 0;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  process.exitCode = main(process.argv.slice(2));
}
