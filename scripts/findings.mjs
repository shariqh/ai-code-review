// The review's findings, from the finder's reply to the sticky comment.
//
// The finder answers with one JSON block (the prompt is in run-review.sh), so
// the scripts parse what it found instead of passing its Markdown through:
// the severity is one of a fixed vocabulary, every finding gets an id, nits
// are capped, each finding is handed to the verifier (verify-findings.sh) on
// its own, and the sticky comment is rendered here, once, from the parsed
// findings. The Copilot CLI prints a reply twice, as Markdown and again as
// plain text; only the first JSON block counts.
//
// No network and no git: every subcommand reads and writes files in the
// review work directory, and the bash scripts pass settings in the
// environment.
//
//   parse <reply> <out.json>    one finder reply; exits 3 when the reply
//                               does not follow the findings format
//   collect <work dir>          every batch's findings into findings.json
//   verdict <reply> <out.json>  one verifier reply; exits 3 when the reply
//                               does not follow the verdict format
//   ledger-read <work dir>      STICKY_LEDGER, the earlier findings from
//                               the sticky comment, into ledger.json and
//                               earlier-findings.txt
//   render <work dir>           findings, verdicts and the ledger into
//                               summary.md, body.md, result, round,
//                               ledger.b64, review.json and, when a confirmed
//                               finding sits on a line the pull request
//                               changes, inline.json
import { existsSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

export const UNSTRUCTURED = 3;
export const SEVERITIES = ["Important", "Nit", "Pre-existing"];

// The vocabulary the prompt asks for, and the words a model falls back to.
// Anything else counts as Important, so a finding is never hidden because
// its severity was unexpected.
const SEVERITY_WORDS = new Map([
  ["important", "Important"], ["critical", "Important"], ["high", "Important"],
  ["medium", "Important"], ["major", "Important"], ["blocker", "Important"],
  ["nit", "Nit"], ["nitpick", "Nit"], ["low", "Nit"], ["minor", "Nit"],
  ["pre-existing", "Pre-existing"], ["preexisting", "Pre-existing"],
]);

export function normalizeSeverity(value) {
  const key = typeof value === "string"
    ? value.trim().toLowerCase().replace(/[\s_]+/g, "-")
    : "";
  return SEVERITY_WORDS.get(key) ?? "Important";
}

// Model text, without control characters (tab and newline stay) and bounded.
export function cleanText(value, max) {
  if (typeof value !== "string") return "";
  let text = value
    .replace(/\r\n?/g, "\n")
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, "")
    .trim();
  if (text.length > max) text = `${text.slice(0, max).trimEnd()} [...]`;
  return text;
}

export function oneLine(value, max) {
  return cleanText(typeof value === "string" ? value.replace(/\s+/g, " ") : "", max);
}

function lineRange(line, endLine) {
  let start = null;
  let end = null;
  if (Number.isSafeInteger(line)) {
    start = line;
  } else if (typeof line === "string") {
    const match = /^\s*L?(\d{1,7})(?:\s*[-\u2013]\s*L?(\d{1,7}))?/.exec(line);
    if (match) {
      start = Number(match[1]);
      if (match[2]) end = Number(match[2]);
    }
  }
  if (start !== null && start < 1) start = null;
  if (start !== null && Number.isSafeInteger(endLine)) end = endLine;
  if (end !== null && (start === null || end <= start)) end = null;
  return { start, end };
}

// One finding from a reply, or null when it names nothing.
export function normalizeFinding(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  let path = oneLine(raw.path ?? raw.file ?? "", 300).replace(/^\.\//, "");
  let { start, end } = lineRange(raw.line ?? raw.start_line, raw.end_line);
  const located = /^(.+?):(\d+)(?:-(\d+))?$/.exec(path);
  if (located && start === null) {
    path = located[1];
    ({ start, end } = lineRange(located[3] ? `${located[2]}-${located[3]}` : located[2]));
  }
  const issue = cleanText(raw.issue ?? raw.description ?? "", 2000);
  let title = oneLine(raw.title ?? raw.summary ?? "", 200);
  if (!title && issue) title = oneLine(issue.split(/(?<=[.!?])\s/)[0], 200);
  if (!title) return null;
  return {
    severity: normalizeSeverity(raw.severity),
    path,
    line: start,
    end_line: end,
    title,
    issue,
    impact: cleanText(raw.impact ?? "", 1000),
    fix: cleanText(raw.fix ?? raw.suggestion ?? "", 1500),
  };
}

// The first balanced {...} at or after `from`, reading strings correctly.
function balancedObject(text, from) {
  const start = text.indexOf("{", from);
  if (start < 0) return null;
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let index = start; index < text.length; index += 1) {
    const character = text[index];
    if (inString) {
      if (escaped) escaped = false;
      else if (character === "\\") escaped = true;
      else if (character === '"') inString = false;
    } else if (character === '"') {
      inString = true;
    } else if (character === "{") {
      depth += 1;
    } else if (character === "}") {
      depth -= 1;
      if (depth === 0) return text.slice(start, index + 1);
    }
  }
  return null;
}

// A finder reply: {findings, still_present, malformed}, or null when it does
// not follow the findings format. Fenced blocks are tried first, then the
// first JSON object in the reply. A reply of "No issues found.", the format
// before structured findings, is a clean reply.
export function parseReply(text) {
  const candidates = [];
  for (const match of text.matchAll(/```[^\n`]*\n([\s\S]*?)```/g)) candidates.push(match[1]);
  const object = balancedObject(text, 0);
  if (object) candidates.push(object);
  for (const candidate of candidates) {
    let value;
    try {
      value = JSON.parse(candidate.trim());
    } catch {
      continue;
    }
    const list = Array.isArray(value)
      ? value
      : value && typeof value === "object" && Array.isArray(value.findings) ? value.findings : null;
    if (!list) continue;
    const findings = list.map(normalizeFinding).filter(Boolean);
    const stillPresent = !Array.isArray(value) && Array.isArray(value.still_present)
      ? value.still_present
        .filter((id) => typeof id === "string" && /^F[0-9]{1,6}$/.test(id.trim()))
        .map((id) => id.trim())
      : [];
    return { findings, still_present: stillPresent, malformed: list.length - findings.length };
  }
  const stripped = text.replace(/\s+/g, "");
  if (stripped !== "" && /^(?:Noissuesfound\.?)+$/.test(stripped)) {
    return { findings: [], still_present: [], malformed: 0 };
  }
  return null;
}

// Two findings are the same when they name the same file and, ignoring case
// and punctuation, the same title.
export function fingerprint(finding) {
  const title = finding.title.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
  return `${finding.path.toLowerCase()}\n${title}`;
}

function nonNegative(value, fallback) {
  if (value === undefined || value === "") return fallback;
  if (!/^[0-9]+$/.test(value)) throw new Error(`not a non-negative integer: ${value}`);
  return Number(value);
}

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

function plural(count, one, many) {
  return count === 1 ? one : many;
}

const SEVERITY_ORDER = { Important: 0, Nit: 1, "Pre-existing": 2 };

// The ledger: the findings earlier rounds reported on this pull request,
// carried in the sticky comment's header as base64 JSON, so that a later
// round never reports one again and the comment can list those still open.
// Each entry is {id, s: severity (I, N or P), v: verdict (c confirmed,
// r refuted, u unverified, s not verified because verification was off),
// r: the round that reported it, o: 1 while it is open, p: path, l: line,
// t: title}; `next` is the next id's number, so ids are never reused.
const SEVERITY_CODES = { Important: "I", Nit: "N", "Pre-existing": "P" };
const SEVERITY_NAMES = { I: "Important", N: "Nit", P: "Pre-existing" };
const VERDICT_CODES = { confirmed: "c", refuted: "r", unverified: "u", skipped: "s" };
const VERDICT_NAMES = { c: "confirmed", r: "refuted", u: "unverified", s: "not verified" };
export const LEDGER_MAX_ENTRIES = 40;
export const LEDGER_MAX_CHARS = 24000;

export function emptyLedger() {
  return { v: 1, next: 1, f: [] };
}

// A ledger from the sticky comment, which anyone with write access can edit,
// so every field is checked; anything malformed means no ledger.
export function decodeLedger(encoded) {
  if (typeof encoded !== "string" || encoded === "" || encoded.length > LEDGER_MAX_CHARS
    || !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) {
    return null;
  }
  let value;
  try {
    value = JSON.parse(Buffer.from(encoded, "base64").toString("utf8"));
  } catch {
    return null;
  }
  if (!value || value.v !== 1 || !Number.isSafeInteger(value.next) || value.next < 1
    || !Array.isArray(value.f) || value.f.length > LEDGER_MAX_ENTRIES) {
    return null;
  }
  const ids = new Set();
  const entries = [];
  for (const entry of value.f) {
    if (!entry || typeof entry !== "object") return null;
    const { id, s, v, r, o, p, l, t } = entry;
    if (typeof id !== "string" || !/^F[0-9]{1,6}$/.test(id) || ids.has(id)
      || Number(id.slice(1)) >= value.next
      || !(s in SEVERITY_NAMES) || !(v in VERDICT_NAMES)
      || !Number.isSafeInteger(r) || r < 1 || r > 9999 || (o !== 0 && o !== 1)
      || typeof p !== "string" || p.length > 300
      || !(l === null || (Number.isSafeInteger(l) && l > 0))
      || typeof t !== "string" || t === "" || t.length > 200) {
      return null;
    }
    ids.add(id);
    entries.push({ id, s, v, r, o, p: oneLine(p, 300), l, t: oneLine(t, 200) });
  }
  return { v: 1, next: value.next, f: entries };
}

export function encodeLedger(ledger) {
  return Buffer.from(JSON.stringify(ledger)).toString("base64");
}

// At most LEDGER_MAX_ENTRIES entries and LEDGER_MAX_CHARS once encoded: the
// oldest closed entries go first, then the oldest refuted ones, then the
// oldest open ones.
function trimLedger(ledger) {
  const entries = [...ledger.f];
  const drop = () => {
    let index = entries.findIndex((entry) => entry.o === 0 && entry.v !== "r");
    if (index < 0) index = entries.findIndex((entry) => entry.v === "r");
    entries.splice(index < 0 ? 0 : index, 1);
  };
  while (entries.length > LEDGER_MAX_ENTRIES) drop();
  while (entries.length > 0 && encodeLedger({ ...ledger, f: entries }).length > LEDGER_MAX_CHARS) drop();
  return { ...ledger, f: entries };
}

function entryAsFinding(entry) {
  return { path: entry.p, title: entry.t };
}

function entryLine(entry) {
  const where = entry.p ? ` ${entry.p}${entry.l ? `:${entry.l}` : ""}` : "";
  return `${entry.id} [${SEVERITY_NAMES[entry.s]}, ${VERDICT_NAMES[entry.v]}${entry.o ? ", open" : ""}]${where} - ${entry.t}`;
}

// The entries a later round must not report again: the open ones and the
// refuted ones. A confirmed finding that a full review closed was fixed, so
// it can be reported again if it comes back.
function remembered(entry) {
  return entry.o === 1 || entry.v === "r";
}

// STICKY_LEDGER (from last-review.sh) into ledger.json, and the earlier
// findings the finder must not report again into earlier-findings.txt.
export function readLedger(workDir, env) {
  const encoded = env.STICKY_LEDGER ?? "";
  let ledger = emptyLedger();
  let note = "none";
  if (encoded !== "") {
    const decoded = decodeLedger(encoded);
    if (decoded) {
      ledger = decoded;
      note = `${decoded.f.length} earlier ${plural(decoded.f.length, "finding", "findings")}`;
    } else {
      note = "malformed, so this review starts a new one";
    }
  }
  writeFileSync(join(workDir, "ledger.json"), `${JSON.stringify(ledger)}\n`);
  const lines = ledger.f.filter(remembered).map(entryLine);
  writeFileSync(join(workDir, "earlier-findings.txt"), lines.length > 0 ? `${lines.join("\n")}\n` : "");
  return note;
}

// Every batch's parsed reply (batches/batch_NNN.json) into findings.json:
// duplicates merged, repeats of an earlier finding (ledger.json) left out,
// Important first, nits past MAX_NITS left out, ids assigned after the
// ledger's, and the first MAX_VERIFICATIONS findings marked for the verifier
// unless VERIFIER_MODEL is empty. A repeat of a finding that could not be
// verified keeps its id and is verified again. Findings past the verification
// cap are not verified, which verify.overflow discloses as partial coverage.
// For a full review, the earlier findings the finder says still apply
// (still_present) or reports again stay open.
export function collect(workDir, env) {
  const maxNits = nonNegative(env.MAX_NITS, 3);
  const maxVerifications = nonNegative(env.MAX_VERIFICATIONS, 10);
  const verify = (env.VERIFIER_MODEL ?? "") !== "";
  const incremental = existsSync(join(workDir, "scope.since"))
    && readFileSync(join(workDir, "scope.since"), "utf8").trim() !== "";
  const ledger = readJson(join(workDir, "ledger.json")) ?? emptyLedger();
  const earlier = new Map();
  for (const entry of ledger.f.filter(remembered)) earlier.set(fingerprint(entryAsFinding(entry)), entry);
  const open = new Set(ledger.f.filter((entry) => entry.o === 1).map((entry) => entry.id));

  const batchesDir = join(workDir, "batches");
  const names = existsSync(batchesDir)
    ? readdirSync(batchesDir).filter((name) => /^batch_[0-9]+\.json$/.test(name)).sort()
    : [];
  const seen = new Set();
  const found = [];
  const stillPresent = new Set();
  let duplicates = 0;
  let malformed = 0;
  let repeats = 0;
  for (const name of names) {
    const parsed = JSON.parse(readFileSync(join(batchesDir, name), "utf8"));
    malformed += parsed.malformed ?? 0;
    for (const id of parsed.still_present ?? []) {
      if (open.has(id)) stillPresent.add(id);
    }
    for (const finding of parsed.findings) {
      const key = fingerprint(finding);
      if (seen.has(key)) {
        duplicates += 1;
        continue;
      }
      seen.add(key);
      const entry = earlier.get(key);
      if (entry && entry.v === "u" && entry.o === 1) {
        finding.id = entry.id;
      } else if (entry) {
        repeats += 1;
        if (entry.o === 1) stillPresent.add(entry.id);
        continue;
      }
      found.push(finding);
    }
  }
  found.sort((a, b) => SEVERITY_ORDER[a.severity] - SEVERITY_ORDER[b.severity]);

  const kept = [];
  let nits = 0;
  let nitsOverCap = 0;
  for (const finding of found) {
    if (finding.severity === "Nit" && ++nits > maxNits) {
      nitsOverCap += 1;
      continue;
    }
    kept.push(finding);
  }

  let next = ledger.next;
  let verifications = 0;
  let overCap = 0;
  for (const finding of kept) {
    if (!finding.id) {
      finding.id = `F${next}`;
      next += 1;
    }
    if (!verify) {
      finding.verify = "off";
    } else if (verifications < maxVerifications) {
      finding.verify = "pending";
      verifications += 1;
    } else {
      finding.verify = "over-cap";
      overCap += 1;
    }
  }
  kept.sort((a, b) => SEVERITY_ORDER[a.severity] - SEVERITY_ORDER[b.severity]
    || Number(a.id.slice(1)) - Number(b.id.slice(1)));

  const result = {
    findings: kept,
    still_present: incremental ? [] : [...stillPresent],
    next,
    dropped: { duplicates, malformed, nits_over_cap: nitsOverCap, repeats },
    max_nits: maxNits,
    max_verifications: maxVerifications,
  };
  writeFileSync(join(workDir, "findings.json"), `${JSON.stringify(result, null, 2)}\n`);
  rmSync(join(workDir, "verify.overflow"), { force: true });
  if (overCap > 0) {
    writeFileSync(
      join(workDir, "verify.overflow"),
      `- verification cap (${maxVerifications}) reached: ${overCap} ${plural(overCap, "finding was", "findings were")} NOT verified and ${plural(overCap, "is", "are")} listed below the fold\n`,
    );
  }
  return result;
}

// A verifier reply: {verdict: "confirmed" | "refuted", reason}, or null. The
// first line that starts with CONFIRMED or REFUTED counts, with any Markdown
// emphasis around the word.
export function parseVerdict(text) {
  for (const line of text.split(/\r?\n/)) {
    const match = /^[\s>#*_`-]*(CONFIRMED|REFUTED)[*_`\s]*[:\u2013\u2014-][*_\s]*(.*?)[*_\s]*$/i
      .exec(line);
    if (match) {
      return { verdict: match[1].toLowerCase(), reason: oneLine(match[2], 300) || "no reason given" };
    }
  }
  return null;
}

// Model text in the comment cannot open an HTML comment, where a forged
// marker could hide, or close the collapsed section it sits in.
function safe(text) {
  return text.replace(/<!--/g, "&lt;!--").replace(/<(\/?)details/gi, "&lt;$1details");
}

function location(finding) {
  if (!finding.path) return "";
  const path = finding.path.replace(/`/g, "'");
  if (!finding.line) return `\`${path}\``;
  return `\`${path}:${finding.line}${finding.end_line ? `-${finding.end_line}` : ""}\``;
}

function verdictLine(finding, verifierModel) {
  switch (finding.verdict) {
    case "confirmed": return `_Confirmed by \`${verifierModel}\`: ${safe(finding.reason)}_`;
    case "refuted": return `_Refuted by \`${verifierModel}\`: ${safe(finding.reason)}_`;
    case "unverified": return `_Not verified: ${safe(finding.reason)}._`;
    default: return "_Not verified: verification is off._";
  }
}

function findingBlock(finding, verifierModel) {
  const lines = [
    `#### ${finding.id} · ${finding.severity}${finding.path ? ` · ${location(finding)}` : ""}`,
    `**${safe(finding.title)}**`,
  ];
  if (finding.issue) lines.push("", safe(finding.issue));
  if (finding.impact) lines.push("", `**Impact:** ${safe(finding.impact)}`);
  if (finding.fix) lines.push("", `**Fix:** ${safe(finding.fix)}`);
  lines.push("", verdictLine(finding, verifierModel));
  return lines.join("\n");
}

function inlineBody(finding, verifierModel) {
  const lines = [`**${finding.severity}** · ${finding.id} · ${safe(finding.title)}`];
  if (finding.issue) lines.push("", safe(finding.issue));
  if (finding.impact) lines.push("", `**Impact:** ${safe(finding.impact)}`);
  if (finding.fix) lines.push("", `**Fix:** ${safe(finding.fix)}`);
  lines.push("", verdictLine(finding, verifierModel));
  return lines.join("\n");
}

function fence(text) {
  let ticks = "```";
  while (text.includes(ticks)) ticks += "`";
  return ticks;
}

function onDiff(ranges, line) {
  return Array.isArray(ranges)
    && ranges.some((range) => Array.isArray(range) && line >= range[0] && line <= range[1]);
}

const COUNTED = new Set(["Important", "Nit"]);
const VISIBLE = new Set(["confirmed", "skipped"]);

function earlierLine(entry) {
  const where = entry.p
    ? ` · \`${entry.p.replace(/`/g, "'")}${entry.l ? `:${entry.l}` : ""}\``
    : "";
  return `- **${entry.id}** · ${SEVERITY_NAMES[entry.s]}${where} — ${safe(entry.t)} (round ${entry.r})`;
}

// findings.json, the verifier's verdicts (verify/<id>/verdict.json) and the
// ledger into the parts of the sticky comment post-comment.sh does not write
// itself:
//
// - summary.md, the first line of the review, which starts with the count of
//   open findings to address, this round's and earlier rounds' (confirmed
//   or, with verification off, unverified; Important and Nit only, so a
//   pre-existing issue never counts);
// - body.md, everything after the coverage banners: a paused or empty
//   round's note, this round's confirmed findings in full, earlier findings
//   still open, pre-existing issues under their own heading, and unconfirmed
//   findings (refuted, or not verified) below the fold;
// - result, "findings" when anything counts, when any finding could not be
//   verified, or when the review was incomplete or paused, and "clean"
//   otherwise;
// - round and ledger.b64, the round count and ledger for the next run; a
//   round counts only when a review call completed;
// - review.json, every finding with its verdict, for evals/score.mjs;
// - inline.json, the review that posts each confirmed finding on its line,
//   when INLINE_COMMENTS is not "false" and a confirmed finding sits on a
//   line of the pull request's diff (commentable.json).
export function render(workDir, env) {
  const read = (name) => (existsSync(join(workDir, name)) ? readFileSync(join(workDir, name), "utf8") : "");
  const data = readJson(join(workDir, "findings.json")) ?? { findings: [], dropped: {}, still_present: [] };
  const ledger = readJson(join(workDir, "ledger.json")) ?? emptyLedger();
  const verifierModel = env.VERIFIER_MODEL ?? "";
  const verifierEffort = env.VERIFIER_EFFORT ?? "low";
  const since = read("scope.since").trim();
  const previousResult = read("scope.previous-result").trim();
  const paused = read("scope.paused").trim() !== "";
  const attempted = Number(read("review.attempted").trim() || "0");
  const completed = Number(read("review.completed").trim() || "0");
  const previousRound = Number(read("round.previous").trim() || "0");
  const round = previousRound + (completed > 0 ? 1 : 0);
  const diffPath = join(workDir, "pr.diff");
  const emptyIncremental = since !== "" && (!existsSync(diffPath) || statSync(diffPath).size === 0);
  const unstructuredDir = join(workDir, "unstructured");
  const unstructured = existsSync(unstructuredDir)
    ? readdirSync(unstructuredDir).filter((name) => /^batch_[0-9]+\.md$/.test(name)).sort()
    : [];

  for (const finding of data.findings) {
    if (finding.verify === "off") {
      finding.verdict = "skipped";
      finding.reason = "";
    } else if (finding.verify === "over-cap") {
      finding.verdict = "unverified";
      finding.reason = `over the verification cap of ${data.max_verifications}`;
    } else {
      const verdict = readJson(join(workDir, "verify", finding.id, "verdict.json"));
      if (verdict && ["confirmed", "refuted", "unverified"].includes(verdict.verdict)) {
        finding.verdict = verdict.verdict;
        finding.reason = oneLine(verdict.reason ?? "", 300) || "no reason given";
      } else {
        finding.verdict = "unverified";
        finding.reason = "the verification step did not run";
      }
    }
  }
  const findings = data.findings;
  const finderComplete = read("overflow.note").trim() === "" && read("review.failures").trim() === ""
    && unstructured.length === 0;

  // The ledger after this round. A full review that covered every file
  // closes each earlier finding it did not report again or name as still
  // present: it was fixed, or was never real. An incremental, paused or
  // partial review leaves them as they were.
  const stillPresent = new Set(data.still_present ?? []);
  const entries = ledger.f.map((entry) => ({ ...entry }));
  if (since === "" && !paused && completed > 0 && finderComplete) {
    for (const entry of entries) {
      if (entry.o === 1 && !findings.some((f) => f.id === entry.id)) entry.o = stillPresent.has(entry.id) ? 1 : 0;
    }
  }
  for (const finding of findings) {
    const entry = {
      id: finding.id,
      s: SEVERITY_CODES[finding.severity],
      v: VERDICT_CODES[finding.verdict],
      r: Math.max(round, 1),
      o: finding.verdict === "refuted" ? 0 : 1,
      p: finding.path,
      l: finding.line,
      t: oneLine(finding.title, 200),
    };
    const index = entries.findIndex((existing) => existing.id === finding.id);
    if (index >= 0) entries[index] = entry;
    else entries.push(entry);
  }
  // Ids are never reused: the next one is past every id ever handed out.
  const next = Math.max(data.next ?? 1, ledger.next,
    ...entries.map((entry) => Number(entry.id.slice(1)) + 1));
  const updated = trimLedger({ v: 1, next, f: entries });
  const thisRound = new Set(findings.map((f) => f.id));
  const earlierOpen = updated.f.filter((entry) => entry.o === 1 && !thisRound.has(entry.id)
    && (entry.v === "c" || entry.v === "s"));

  const countedEntries = updated.f.filter((entry) => entry.o === 1 && (entry.s === "I" || entry.s === "N")
    && (entry.v === "c" || entry.v === "s"));
  const important = countedEntries.filter((entry) => entry.s === "I").length;
  const nits = countedEntries.length - important;
  const counted = findings.filter((f) => COUNTED.has(f.severity) && VISIBLE.has(f.verdict));
  const main = findings.filter((f) => f.severity !== "Pre-existing" && VISIBLE.has(f.verdict));
  const preExisting = findings.filter((f) => f.severity === "Pre-existing" && VISIBLE.has(f.verdict));
  const unconfirmed = findings.filter((f) => !VISIBLE.has(f.verdict));
  const incomplete = ["overflow.note", "review.failures", "verify.failures", "verify.overflow"]
    .some((name) => read(name).trim() !== "")
    || findings.some((f) => f.verdict === "unverified")
    || unstructured.length > 0
    || paused;
  // A sticky from before the ledger records no findings, so the result of
  // the review an incremental one builds on stands.
  const carried = since !== "" && previousResult === "findings" && ledger.f.length === 0;
  const result = countedEntries.length > 0 || incomplete || carried ? "findings" : "clean";

  let summary;
  if (attempted > 0 && completed === 0) {
    summary = `**0 of ${attempted} review ${plural(attempted, "call", "calls")} succeeded**, so nothing was reviewed.`;
  } else {
    const total = countedEntries.length;
    summary = `**${total} ${plural(total, "finding", "findings")} to address**`
      + (total > 0 ? ` (${important} Important, ${nits} Nit)` : "");
    if (earlierOpen.length > 0 && total > 0) {
      summary += counted.length === 0
        ? "; none is new in this review."
        : `; ${counted.length} ${plural(counted.length, "is", "are")} new in this review.`;
    } else {
      summary += ".";
    }
    if (preExisting.length > 0) {
      summary += ` ${preExisting.length} pre-existing ${plural(preExisting.length, "issue is", "issues are")} listed but not counted.`;
    }
    if (unconfirmed.length > 0) {
      summary += ` ${unconfirmed.length} unconfirmed ${plural(unconfirmed.length, "finding is", "findings are")} below the fold.`;
    }
  }

  const listed = earlierOpen.length > 0 ? "They are listed below." : "This comment's edit history has them.";
  const body = [];
  if (paused) {
    const commits = since !== "" ? `the commits since \`${since}\`` : "the commits since the last review";
    body.push(`> **Review paused** after ${previousRound} rounds - ${commits} were NOT reviewed. `
      + "Three rounds that each left findings to address usually mean the approach needs another look: "
      + "reconsider it (split the change, or settle the design with a person) rather than iterating with the reviewer. "
      + "To start over with a full review, delete this comment and push or re-run.");
  } else if (emptyIncremental) {
    body.push(countedEntries.length === 0 && previousResult === "clean"
      ? `_Nothing new to review: the files this pull request changes are the same as at \`${since}\`, and the review of that commit found no issues._`
      : `_Nothing new to review: the files this pull request changes are the same as at \`${since}\`, so the findings of the review of that commit still apply. ${listed}_`);
  } else if (since !== "" && completed > 0 && counted.length === 0
    && (earlierOpen.length > 0 || carried)) {
    body.push(`_No new issues in the commits since \`${since}\`, but the findings of the review of that commit were not re-checked and still stand. ${listed}_`);
  }
  if (main.length > 0) {
    body.push("### Findings", ...main.map((f) => findingBlock(f, verifierModel)));
  }
  if (earlierOpen.length > 0) {
    const note = since === "" && !paused && completed > 0
      ? "_Reported in an earlier round and still present in this review._"
      : "_Reported in an earlier round and not re-checked by this review._";
    body.push("### Earlier findings still open", note, earlierOpen.map(earlierLine).join("\n"));
  }
  if (preExisting.length > 0) {
    body.push(
      "### Pre-existing issues",
      "_Real issues in code this pull request does not change. They do not count against it._",
      ...preExisting.map((f) => findingBlock(f, verifierModel)),
    );
  }
  if (unconfirmed.length > 0) {
    body.push(
      `<details><summary>${unconfirmed.length} unconfirmed ${plural(unconfirmed.length, "finding", "findings")}, not posted inline</summary>`,
      ...unconfirmed.map((f) => findingBlock(f, verifierModel)),
      "</details>",
    );
  }
  for (const name of unstructured) {
    const raw = cleanText(readFileSync(join(unstructuredDir, name), "utf8"), 8000);
    const ticks = fence(raw);
    body.push(
      `<details><summary>The reply for ${name.replace(/\.md$/, "")}, which did not follow the findings format</summary>`,
      `${ticks}text\n${raw}\n${ticks}`,
      "</details>",
    );
  }
  const notes = [];
  const { nits_over_cap: overCap = 0, malformed = 0, repeats = 0 } = data.dropped ?? {};
  if (overCap > 0) {
    notes.push(`${overCap} more ${plural(overCap, "nit was", "nits were")} left out, over the cap of ${data.max_nits} per review.`);
  }
  if (repeats > 0) {
    notes.push(`${repeats} ${plural(repeats, "finding repeated an earlier one and was", "findings repeated earlier ones and were")} left out.`);
  }
  if (malformed > 0) {
    notes.push(`${malformed} ${plural(malformed, "finding", "findings")} without a title ${plural(malformed, "was", "were")} left out.`);
  }
  if (findings.length > 0) {
    notes.push(verifierModel !== ""
      ? `Each finding is checked by \`${verifierModel}\` (${verifierEffort} reasoning effort) before it is posted; only confirmed findings are posted inline.`
      : "Verification is off, so no finding is posted inline.");
  }
  if (notes.length > 0) body.push(`_${notes.join(" ")}_`);

  const commentable = readJson(join(workDir, "commentable.json")) ?? {};
  const inline = findings
    .filter((f) => f.verdict === "confirmed" && f.path && f.line && onDiff(commentable[f.path], f.line))
    .slice(0, 20);

  writeFileSync(join(workDir, "summary.md"), `${summary}\n`);
  writeFileSync(join(workDir, "body.md"), body.length > 0 ? `${body.join("\n\n")}\n` : "");
  writeFileSync(join(workDir, "result"), `${result}\n`);
  writeFileSync(join(workDir, "round"), `${round}\n`);
  writeFileSync(join(workDir, "ledger.b64"),
    updated.f.length > 0 || updated.next > 1 ? `${encodeLedger(updated)}\n` : "");
  writeFileSync(join(workDir, "review.json"), `${JSON.stringify({ result, round, findings }, null, 2)}\n`);
  rmSync(join(workDir, "inline.json"), { force: true });
  if (inline.length > 0 && env.INLINE_COMMENTS !== "false") {
    const head = env.HEAD_SHA ?? "";
    writeFileSync(join(workDir, "inline.json"), `${JSON.stringify({
      commit_id: head,
      event: "COMMENT",
      body: `AI code review (\`${env.REVIEW_MODEL ?? ""}\`): ${inline.length} confirmed ${plural(inline.length, "finding", "findings")} on \`${head.slice(0, 12)}\`. The sticky comment has the summary.`,
      comments: inline.map((f) => ({ path: f.path, line: f.line, side: "RIGHT", body: inlineBody(f, verifierModel) })),
    }, null, 2)}\n`);
  }
  return { result, summary, inline: inline.length };
}

function main(argv) {
  const [command, ...args] = argv;
  switch (command) {
    case "parse": {
      const [replyPath, outPath] = args;
      if (!replyPath || !outPath) throw new Error("usage: findings.mjs parse <reply> <out.json>");
      const parsed = parseReply(readFileSync(replyPath, "utf8"));
      if (!parsed) return UNSTRUCTURED;
      writeFileSync(outPath, `${JSON.stringify(parsed, null, 2)}\n`);
      return 0;
    }
    case "collect": {
      const [workDir] = args;
      if (!workDir) throw new Error("usage: findings.mjs collect <work dir>");
      const { findings, dropped } = collect(workDir, process.env);
      console.log(`findings: ${findings.length} (duplicates merged: ${dropped.duplicates}, nits over the cap: ${dropped.nits_over_cap})`);
      return 0;
    }
    case "verdict": {
      const [replyPath, outPath] = args;
      if (!replyPath || !outPath) throw new Error("usage: findings.mjs verdict <reply> <out.json>");
      const verdict = parseVerdict(readFileSync(replyPath, "utf8"));
      if (!verdict) return UNSTRUCTURED;
      writeFileSync(outPath, `${JSON.stringify(verdict)}\n`);
      return 0;
    }
    case "ledger-read": {
      const [workDir] = args;
      if (!workDir) throw new Error("usage: findings.mjs ledger-read <work dir>");
      console.log(`earlier findings: ${readLedger(workDir, process.env)}`);
      return 0;
    }
    case "render": {
      const [workDir] = args;
      if (!workDir) throw new Error("usage: findings.mjs render <work dir>");
      const { result, inline } = render(workDir, process.env);
      console.log(`result: ${result}; inline comments: ${inline}`);
      return 0;
    }
    default:
      throw new Error("usage: findings.mjs parse|collect|verdict|ledger-read|render ...");
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  process.exitCode = main(process.argv.slice(2));
}
