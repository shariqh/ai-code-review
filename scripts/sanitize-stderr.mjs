// Prints a failed Copilot CLI call's stderr as lines that are safe in the job
// log, each with the "  copilot stderr | " prefix. print_cli_stderr fences
// the output in a ::stop-commands:: block. The steps, in order:
//
// 1. Read the stderr: all of it, or the complete lines of its last 1 MiB.
// 2. Remove terminal control sequences and every control character but tab
//    and newline, so an escape sequence cannot split a credential past the
//    patterns below and a carriage return cannot overwrite a log line.
// 3. Redact credentials in that whole text, case-insensitively.
// 4. Keep only the last 10 lines and at most the last 1,000 bytes, which is
//    enough to name a failure's cause. This runs after redaction, so the cut
//    can never leave a fragment of a credential the patterns would have
//    caught whole.
// 5. Replace every character outside a small allowlist (letters, digits,
//    space and . , _ - ' " / =) with "?". Without a colon, "#", brackets or
//    parentheses, neither workflow commands (`::command::`, or the legacy
//    `##[command]` anywhere in a line) nor the problem matchers setup-node
//    registers (eslint-compact, eslint-stylish, tsc) have anything to match.
import { closeSync, fstatSync, openSync, readSync } from "node:fs";

const [stderrPath] = process.argv.slice(2);
if (!stderrPath) {
  throw new Error("usage: sanitize-stderr.mjs <stderr file>");
}

const PREFIX = "  copilot stderr | ";
const MAX_LINES = 10;
const MAX_BYTES = 1000;
const WINDOW_BYTES = 1024 * 1024;

function readStderr(path) {
  const fd = openSync(path, "r");
  try {
    const size = fstatSync(fd).size;
    const start = Math.max(0, size - WINDOW_BYTES);
    const buffer = Buffer.alloc(size - start);
    let offset = 0;
    while (offset < buffer.length) {
      const read = readSync(fd, buffer, offset, buffer.length - offset, start + offset);
      if (read === 0) break;
      offset += read;
    }
    let text = buffer.subarray(0, offset).toString("utf8");
    if (start > 0) {
      // A window that starts mid-file starts mid-line. Drop that partial
      // line so redaction only ever sees complete lines.
      const newline = text.indexOf("\n");
      text = newline < 0 ? "" : text.slice(newline + 1);
    }
    return { text, size };
  } finally {
    closeSync(fd);
  }
}

function stripControls(text) {
  return text
    .replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, "")
    .replace(/[\x00-\x08\x0b-\x1f\x7f]/g, "");
}

// Every pattern is case-insensitive: header names and authentication schemes
// are, and so are the token shapes for the purpose of not printing them.
const REDACTIONS = [
  // The value of a credential-bearing header, to the end of the line.
  [/(authorization|cookie|x-api-key)(["']?\s*[:=]\s*).*$/gim, "$1$2REDACTED"],
  // GitHub tokens, JWTs and Copilot session tokens.
  [/(gh[pousr]_|github_pat_)[a-z0-9_]+/gi, "$1REDACTED"],
  [/eyj[a-z0-9_-]{4,}\.[a-z0-9_-]+(?:\.[a-z0-9_-]*)?/gi, "REDACTED"],
  [/(tid=)\S+/gi, "$1REDACTED"],
  // The credential after a Basic or Bearer scheme.
  [/\b(basic|bearer)(\s+)[^\s,;"']+/gi, "$1$2REDACTED"],
  // A value labelled as a token, password, secret or API key.
  [/((?:token|password|passwd|secret|api[_-]?key)["']?\s*[:=]\s*["']?)[^\s,;"']+/gi,
    "$1REDACTED"],
  // A credential-shaped word after "token": long, or with a digit or + / =.
  // An ordinary word, as in "token validation failed", is left alone.
  [/(token\s+)(?:[a-z0-9._~+/=-]{20,}|(?=[a-z0-9._~+/=-]*[0-9+/=])[a-z0-9._~+/=-]{8,})/gi,
    "$1REDACTED"],
];

function redact(text) {
  let redacted = text;
  const token = process.env.COPILOT_GITHUB_TOKEN || "";
  if (token.length >= 8) {
    redacted = redacted.split(token).join("REDACTED");
  }
  for (const [pattern, replacement] of REDACTIONS) {
    redacted = redacted.replace(pattern, replacement);
  }
  return redacted;
}

function keepEnd(text) {
  const lines = text.split("\n");
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
  let kept = lines.slice(-MAX_LINES).join("\n");
  let omitted = lines.length > MAX_LINES;
  const bytes = Buffer.from(kept, "utf8");
  if (bytes.length > MAX_BYTES) {
    // Cutting mid-character leaves a replacement character, which step 5
    // turns into "?".
    kept = bytes.subarray(bytes.length - MAX_BYTES).toString("utf8");
    omitted = true;
  }
  return { lines: kept === "" ? [] : kept.split("\n"), omitted };
}

function sanitize(line) {
  return line.replace(/[^A-Za-z0-9 .,_'"/=-]/g, "?");
}

const stderr = readStderr(stderrPath);
const visible = stripControls(stderr.text);
const redacted = redact(visible);
const kept = keepEnd(redacted);
const printable = kept.lines.map(sanitize);

const output = [];
if (kept.omitted) {
  output.push(`... earlier stderr omitted, showing the end of ${stderr.size} bytes`);
}
if (printable.every((line) => line.trim() === "")) {
  output.push("the Copilot CLI wrote nothing readable to stderr");
} else {
  output.push(...printable);
}
process.stdout.write(output.map((line) => PREFIX + line).join("\n") + "\n");
