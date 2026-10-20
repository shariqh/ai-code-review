// Parses the reusable workflow's default `reviewers` input (a folded YAML
// scalar holding JSON) and checks it: valid JSON, a model and a unique marker
// per reviewer, and no Claude model, since the reviewers exist to be
// independent of Claude-authored code. Prints the models, comma-separated.
import { readFileSync } from "node:fs";

const [workflowPath] = process.argv.slice(2);
if (!workflowPath) {
  throw new Error("usage: check-default-reviewers.mjs <workflow.yml>");
}

const lines = readFileSync(workflowPath, "utf8").split("\n");
const inputLine = lines.findIndex((line) => /^ {6}reviewers:\s*$/.test(line));
if (inputLine < 0) {
  throw new Error("the reviewers input was not found");
}
const defaultLine = lines.findIndex(
  (line, index) => index > inputLine && /^ {8}default: >-\s*$/.test(line),
);
if (defaultLine < 0) {
  throw new Error("the reviewers input has no folded default");
}

const folded = [];
for (const line of lines.slice(defaultLine + 1)) {
  if (!/^ {10}\S/.test(line)) {
    break;
  }
  folded.push(line.trim());
}

const reviewers = JSON.parse(folded.join(" "));
if (!Array.isArray(reviewers) || reviewers.length === 0) {
  throw new Error("the default reviewers must be a non-empty JSON array");
}

const markers = new Set();
for (const reviewer of reviewers) {
  const { model, marker } = reviewer;
  if (typeof model !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(model)) {
    throw new Error(`invalid default model: ${JSON.stringify(model)}`);
  }
  if (/claude/i.test(model)) {
    throw new Error(`default reviewers must not use a Claude model: ${model}`);
  }
  if (typeof marker !== "string" || !/^[A-Za-z0-9_-]+$/.test(marker)) {
    throw new Error(`invalid default marker: ${JSON.stringify(marker)}`);
  }
  if (markers.has(marker)) {
    throw new Error(`duplicate default marker: ${marker}`);
  }
  markers.add(marker);
}

console.log(reviewers.map((reviewer) => reviewer.model).join(","));
