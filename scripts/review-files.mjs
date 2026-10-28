// Reads the pull request's checkout for the review: the lines of the pull
// request's diff that can carry an inline comment, and the evidence the
// verifier gets for each finding.
//
// It runs only in steps without the Copilot token. It calls git with an
// argument list, never through a shell, and reads objects of the head commit
// only, never the working tree: a file's content comes from the commit's
// tree, so a symbolic link in the pull request is its link text, never the
// file it points at.
//
//   commentable <diff> <out.json>
//       {path: [[first, last], ...]}, the new-side line ranges of each hunk,
//       which are the lines GitHub accepts a review comment on
//   head-files <work dir> <repo dir> <head sha>
//       for each batch, batches/batch_NNN.files/NNN.txt: the head version of
//       each file the batch's diff touches, numbered by line, whole or the
//       window around its first change, for the finder
//   verify-context <work dir> <repo dir> <head sha>
//       for each finding findings.json marks for verification, the directory
//       verify/<id>/ with finding.txt, file.txt (the head version of the file
//       it names, numbered by line), changes.diff (what the pull request
//       changes in that file, from pr-full.diff) and references.txt (where
//       the identifiers it names appear at the head commit)
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const FILE_MAX_BYTES = 48000;
const HEAD_FILE_MAX_BYTES = 40000;
const BLOB_READ_MAX_BYTES = 8 * 1024 * 1024;
const CHANGES_MAX_BYTES = 12000;
const REFERENCES_MAX_BYTES = 6000;
const REFERENCE_LINE_MAX = 200;
const MAX_IDENTIFIERS = 6;
const MAX_MATCHES_PER_IDENTIFIER = 15;

// git quotes a path holding a special character as a C string.
export function unquote(raw) {
  if (!raw.startsWith('"')) return raw;
  const escapes = { a: 7, b: 8, t: 9, n: 10, v: 11, f: 12, r: 13, '"': 34, "\\": 92 };
  const bytes = [];
  for (let index = 1; index < raw.length; index += 1) {
    const character = raw[index];
    if (character === '"') break;
    if (character !== "\\") {
      bytes.push(...Buffer.from(character, "utf8"));
      continue;
    }
    index += 1;
    const next = raw[index];
    if (next in escapes) {
      bytes.push(escapes[next]);
    } else if (/[0-7]/.test(next)) {
      bytes.push(Number.parseInt(raw.slice(index, index + 3), 8));
      index += 2;
    } else if (next !== undefined) {
      bytes.push(...Buffer.from(next, "utf8"));
    }
  }
  return Buffer.from(bytes).toString("utf8");
}

// A unified diff, one fragment per file, with the paths on both sides (null
// for a side that does not exist, as for an added or deleted file).
export function splitDiff(text) {
  const fragments = [];
  let current = null;
  for (const line of text.split("\n")) {
    if (line.startsWith("diff --git ")) {
      current = { lines: [line], oldPath: null, newPath: null, inHunk: false };
      fragments.push(current);
      continue;
    }
    if (!current) continue;
    current.lines.push(line);
    if (current.inHunk) continue;
    if (line.startsWith("@@")) {
      current.inHunk = true;
    } else if (line.startsWith("--- ") || line.startsWith("+++ ")) {
      const side = line.slice(4).replace(/\t$/, "");
      if (side !== "/dev/null") {
        const path = unquote(side).replace(/^[ab]\//, "");
        if (line.startsWith("--- ")) current.oldPath = path;
        else current.newPath = path;
      }
    } else if (line.startsWith("rename to ")) {
      current.newPath = unquote(line.slice("rename to ".length));
    } else if (line.startsWith("rename from ")) {
      current.oldPath = unquote(line.slice("rename from ".length));
    }
  }
  return fragments.map(({ lines, oldPath, newPath }) => ({ text: lines.join("\n"), oldPath, newPath }));
}

export function commentableLines(diffText) {
  const ranges = {};
  for (const fragment of splitDiff(diffText)) {
    if (!fragment.newPath) continue;
    for (const line of fragment.text.split("\n")) {
      const match = /^@@ -[0-9]+(?:,[0-9]+)? \+([0-9]+)(?:,([0-9]+))? @@/.exec(line);
      if (!match) continue;
      const first = Number(match[1]);
      const count = match[2] === undefined ? 1 : Number(match[2]);
      if (count === 0) continue;
      (ranges[fragment.newPath] ??= []).push([first, first + count - 1]);
    }
  }
  return ranges;
}

function git(repoDir, args, options = {}) {
  return execFileSync("git", ["-C", repoDir, "--no-pager", ...args], {
    encoding: options.encoding ?? "utf8",
    maxBuffer: options.maxBuffer ?? BLOB_READ_MAX_BYTES,
    stdio: ["ignore", "pipe", "ignore"],
  });
}

// The head version of a file: {kind: "file", text} for a text file, or
// {kind, note} when it cannot be shown.
export function headFile(repoDir, head, path) {
  if (!path) return { kind: "none", note: "the finding names no file" };
  let entry;
  try {
    entry = git(repoDir, ["--literal-pathspecs", "ls-tree", "-z", "-l", head, "--", path]);
  } catch {
    return { kind: "none", note: "the file could not be read from the head commit" };
  }
  const match = /^([0-7]+) (\w+) ([0-9a-f]+) +(-|[0-9]+)\t/.exec(entry);
  if (!match) return { kind: "none", note: "the file does not exist at the head commit" };
  const [, mode, type, oid, size] = match;
  if (type !== "blob") return { kind: "none", note: `the path is a ${type === "commit" ? "submodule" : "directory"} at the head commit` };
  if (Number(size) > BLOB_READ_MAX_BYTES) return { kind: "none", note: `the file is ${size} bytes, too large to read` };
  const content = git(repoDir, ["cat-file", "blob", oid], { encoding: "buffer" });
  if (mode === "120000") {
    return { kind: "none", note: `the path is a symbolic link to ${content.toString("utf8").slice(0, 200)}` };
  }
  if (content.subarray(0, 8000).includes(0)) return { kind: "none", note: "the file is binary" };
  return { kind: "file", text: content.toString("utf8") };
}

// The file numbered by line, whole when it fits in maxBytes, otherwise the
// window around `line` (or the start of the file) that does.
export function numberedWindow(text, line, maxBytes) {
  const lines = text.split("\n");
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
  const width = String(lines.length).length;
  const numbered = lines.map((content, index) => `${String(index + 1).padStart(width)}  ${content}`);
  const total = numbered.reduce((sum, entry) => sum + Buffer.byteLength(entry) + 1, 0);
  if (total <= maxBytes) return { text: `${numbered.join("\n")}\n`, first: 1, last: lines.length, total: lines.length };
  const centre = Math.min(Math.max((line ?? 1) - 1, 0), Math.max(lines.length - 1, 0));
  let first = centre;
  let last = centre;
  let bytes = Buffer.byteLength(numbered[centre] ?? "") + 1;
  for (;;) {
    let grew = false;
    if (first > 0 && bytes + Buffer.byteLength(numbered[first - 1]) + 1 <= maxBytes) {
      first -= 1;
      bytes += Buffer.byteLength(numbered[first]) + 1;
      grew = true;
    }
    if (last < lines.length - 1 && bytes + Buffer.byteLength(numbered[last + 1]) + 1 <= maxBytes) {
      last += 1;
      bytes += Buffer.byteLength(numbered[last]) + 1;
      grew = true;
    }
    if (!grew) break;
  }
  return { text: `${numbered.slice(first, last + 1).join("\n")}\n`, first: first + 1, last: last + 1, total: lines.length };
}

// Identifiers a finding names: code spans first, then words that read as
// code (camelCase, snake_case, or a call), at most MAX_IDENTIFIERS. A dotted
// name is searched whole and by its last part.
export function identifiers(finding) {
  const text = [finding.title, finding.issue, finding.impact, finding.fix].join("\n");
  const found = [];
  const add = (candidate) => {
    const match = /^[A-Za-z_$][\w$]*(?:(?:\.|::)[A-Za-z_$][\w$]*)*/.exec(candidate.trim());
    if (!match) return;
    const name = match[0];
    for (const part of [name, name.split(/\.|::/).pop()]) {
      if (part.length >= 3 && part.length <= 80 && !found.includes(part)) found.push(part);
    }
  };
  for (const span of text.matchAll(/`([^`\n]{1,120})`/g)) {
    if (!span[1].includes("/")) add(span[1]);
  }
  for (const word of text.matchAll(/\b[A-Za-z_$][\w$]*(?:\(\))?/g)) {
    const value = word[0];
    if (/[a-z][A-Z]/.test(value) || /[A-Za-z]_[A-Za-z]/.test(value) || value.endsWith("()")) add(value);
  }
  return found.slice(0, MAX_IDENTIFIERS);
}

// Where each identifier appears at the head commit: git grep over the
// commit's tree, fixed strings, text files only, bounded.
export function references(repoDir, head, names) {
  const sections = [];
  let bytes = 0;
  for (const name of names) {
    let output = "";
    let failed = false;
    try {
      output = git(repoDir, ["grep", "-n", "-I", "-F", "--full-name", "-m", "3", "-e", name, head, "--"],
        { maxBuffer: 4 * 1024 * 1024 });
    } catch (error) {
      // Exit status 1 means no match; anything else is a failed search.
      if (error.status !== 1) failed = true;
    }
    const matches = output.split("\n").filter(Boolean).map((line) => {
      const relative = line.startsWith(`${head}:`) ? line.slice(head.length + 1) : line;
      return relative.length > REFERENCE_LINE_MAX ? `${relative.slice(0, REFERENCE_LINE_MAX)} [...]` : relative;
    });
    let section;
    if (failed) section = `${name}: the search failed`;
    else if (matches.length === 0) section = `${name}: no matches`;
    else {
      const shown = matches.slice(0, MAX_MATCHES_PER_IDENTIFIER);
      section = [`${name}: ${matches.length} ${matches.length === 1 ? "match" : "matches"} (at most 3 per file)${shown.length < matches.length ? `, first ${shown.length} shown` : ""}`, ...shown].join("\n");
    }
    if (bytes + Buffer.byteLength(section) + 1 > REFERENCES_MAX_BYTES) {
      sections.push(`${name}: left out, over the ${REFERENCES_MAX_BYTES}-byte limit for references`);
      continue;
    }
    bytes += Buffer.byteLength(section) + 1;
    sections.push(section);
  }
  return sections.length > 0 ? `${sections.join("\n\n")}\n` : "The finding names no identifier to look up.\n";
}

function firstChangedLine(fragment) {
  const match = /^@@ -[0-9]+(?:,[0-9]+)? \+([0-9]+)/m.exec(fragment.text);
  return match ? Number(match[1]) : 1;
}

// A file section for the finder's prompt. Every content line starts with its
// number, so no line of the file can pass for the section's end marker.
function fileSection(path, window) {
  const extent = window.first === 1 && window.last === window.total
    ? `all ${window.total} lines`
    : `lines ${window.first} to ${window.last} of ${window.total}`;
  return `--- BEGIN FILE ${JSON.stringify(path)} (head version, ${extent}) ---\n${window.text}--- END FILE ---\n`;
}

export function headFiles(workDir, repoDir, head) {
  if (!/^[0-9a-f]{40}$/.test(head)) throw new Error("the head must be a full commit SHA");
  const batchesDir = join(workDir, "batches");
  if (!existsSync(batchesDir)) return 0;
  let written = 0;
  for (const name of readdirSync(batchesDir).filter((entry) => /^batch_[0-9]+\.diff$/.test(entry)).sort()) {
    const dir = join(batchesDir, name.replace(/\.diff$/, ".files"));
    rmSync(dir, { recursive: true, force: true });
    mkdirSync(dir, { recursive: true });
    const seen = new Set();
    let index = 0;
    for (const fragment of splitDiff(readFileSync(join(batchesDir, name), "utf8"))) {
      const path = fragment.newPath;
      if (!path || seen.has(path)) continue;
      seen.add(path);
      const file = headFile(repoDir, head, path);
      const section = file.kind === "file"
        ? fileSection(path, numberedWindow(file.text, firstChangedLine(fragment), HEAD_FILE_MAX_BYTES))
        : `--- FILE ${JSON.stringify(path)} not shown: ${file.note} ---\n`;
      writeFileSync(join(dir, `${String(index).padStart(3, "0")}.txt`), section);
      index += 1;
      written += 1;
    }
  }
  return written;
}

function findingText(finding) {
  const where = finding.path
    ? `${finding.path}${finding.line ? `:${finding.line}${finding.end_line ? `-${finding.end_line}` : ""}` : ""}`
    : "(no location given)";
  const lines = [`id: ${finding.id}`, `severity: ${finding.severity}`, `location: ${where}`, `title: ${finding.title}`];
  if (finding.issue) lines.push("issue:", finding.issue);
  if (finding.impact) lines.push("impact:", finding.impact);
  if (finding.fix) lines.push("fix:", finding.fix);
  return `${lines.join("\n")}\n`;
}

export function verifyContext(workDir, repoDir, head) {
  if (!/^[0-9a-f]{40}$/.test(head)) throw new Error("the head must be a full commit SHA");
  const findingsPath = join(workDir, "findings.json");
  if (!existsSync(findingsPath)) return 0;
  const { findings } = JSON.parse(readFileSync(findingsPath, "utf8"));
  const pending = findings.filter((finding) => finding.verify === "pending");
  const fullDiffPath = join(workDir, "pr-full.diff");
  const fragments = existsSync(fullDiffPath) ? splitDiff(readFileSync(fullDiffPath, "utf8")) : [];
  for (const finding of pending) {
    if (!/^F[0-9]+$/.test(finding.id)) throw new Error(`malformed finding id: ${finding.id}`);
    const dir = join(workDir, "verify", finding.id);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "finding.txt"), findingText(finding));

    const file = headFile(repoDir, head, finding.path);
    if (file.kind === "file") {
      const window = numberedWindow(file.text, finding.line, FILE_MAX_BYTES);
      const extent = window.first === 1 && window.last === window.total
        ? `all ${window.total} lines`
        : `lines ${window.first} to ${window.last} of ${window.total}`;
      writeFileSync(join(dir, "file.txt"), `${finding.path} at the head commit, ${extent}:\n${window.text}`);
    } else {
      writeFileSync(join(dir, "file.txt"), `No file content: ${file.note}.\n`);
    }

    const changes = fragments
      .filter((fragment) => finding.path && (fragment.newPath === finding.path || fragment.oldPath === finding.path))
      .map((fragment) => fragment.text)
      .join("\n");
    const bounded = Buffer.byteLength(changes) > CHANGES_MAX_BYTES
      ? `${Buffer.from(changes).subarray(0, CHANGES_MAX_BYTES).toString("utf8")}\n[... changes truncated at ${CHANGES_MAX_BYTES} bytes ...]`
      : changes;
    writeFileSync(join(dir, "changes.diff"), bounded === "" ? "" : `${bounded}\n`);

    writeFileSync(join(dir, "references.txt"), references(repoDir, head, identifiers(finding)));
  }
  return pending.length;
}

function main(argv) {
  const [command, ...args] = argv;
  switch (command) {
    case "commentable": {
      const [diffPath, outPath] = args;
      if (!diffPath || !outPath) throw new Error("usage: review-files.mjs commentable <diff> <out.json>");
      writeFileSync(outPath, `${JSON.stringify(commentableLines(readFileSync(diffPath, "utf8")))}\n`);
      return 0;
    }
    case "head-files": {
      const [workDir, repoDir, head] = args;
      if (!workDir || !repoDir || !head) {
        throw new Error("usage: review-files.mjs head-files <work dir> <repo dir> <head sha>");
      }
      const count = headFiles(workDir, repoDir, head);
      console.log(`head versions gathered for ${count} ${count === 1 ? "file" : "files"}`);
      return 0;
    }
    case "verify-context": {
      const [workDir, repoDir, head] = args;
      if (!workDir || !repoDir || !head) {
        throw new Error("usage: review-files.mjs verify-context <work dir> <repo dir> <head sha>");
      }
      const count = verifyContext(workDir, repoDir, head);
      console.log(`verification evidence gathered for ${count} ${count === 1 ? "finding" : "findings"}`);
      return 0;
    }
    default:
      throw new Error("usage: review-files.mjs commentable|head-files|verify-context ...");
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  process.exitCode = main(process.argv.slice(2));
}
