// Reads a step's log output and prints every line that the problem matchers
// actions/setup-node registers would turn into an annotation, as
// "line <n>: <owner>". The patterns are copied verbatim from
// .github/{eslint-compact,eslint-stylish,tsc}.json in actions/setup-node at
// 48b55a011bda9f5d6aeb4c2d9c7362e8dae4041e (v6), the version action.yml pins.
// Matchers run on lines that a stop-commands block shields from the command
// parser too, so every line is checked. Lines are split the way the runner
// reads them: at CR, LF or CRLF. For the two-line eslint-stylish matcher, a
// second-pattern line counts after a line matching either pattern (it
// loops), which can only over-report.
import { readFileSync } from "node:fs";

const [logPath] = process.argv.slice(2);
if (!logPath) {
  throw new Error("usage: problem-matchers.mjs <log>");
}

const compact = /^(.+):\sline\s(\d+),\scol\s(\d+),\s([Ee]rror|[Ww]arning|[Ii]nfo)\s-\s(.+)\s\((.+)\)$/;
const tsc = /^([^\s].*)[\(:](\d+)[,:](\d+)(?:\):\s+|\s+-\s+)(error|warning|info)\s+TS(\d+)\s*:\s*(.*)$/;
const stylishFile = /^\s*([^\s].*)$/;
const stylishProblem = /^\s+(\d+):(\d+)\s+(error|warning|info)\s+(.*)\s\s+(.*)$/;

const lines = readFileSync(logPath, "utf8").split(/\r\n|\r|\n/);
lines.forEach((line, index) => {
  if (compact.test(line)) console.log(`line ${index + 1}: eslint-compact`);
  if (tsc.test(line)) console.log(`line ${index + 1}: tsc`);
  const previous = index > 0 ? lines[index - 1] : null;
  if (previous !== null && stylishProblem.test(line)
    && (stylishFile.test(previous) || stylishProblem.test(previous))) {
    console.log(`line ${index + 1}: eslint-stylish`);
  }
});
