import { readFileSync, writeFileSync } from "node:fs";

const [inputPath, outputPath, maxBytesText] = process.argv.slice(2);
if (!inputPath || !outputPath || !maxBytesText) {
  throw new Error("usage: truncate-comment.mjs <input> <output> <max-bytes>");
}

const maxBytes = Number.parseInt(maxBytesText, 10);
if (!Number.isSafeInteger(maxBytes) || maxBytes <= 0) {
  throw new Error("max bytes must be a positive integer");
}

const content = readFileSync(inputPath, "utf8");
if (Buffer.byteLength(content, "utf8") <= maxBytes) {
  writeFileSync(outputPath, content);
  process.exit(0);
}

const suffix =
  "\n\n> **Review output truncated** to fit GitHub's comment size limit.\n\n" +
  "_Automated, independent-model review. Not a substitute for human judgment._\n";
const codePoints = Array.from(content);
let low = 0;
let high = codePoints.length;

while (low < high) {
  const middle = Math.ceil((low + high) / 2);
  const candidate = codePoints.slice(0, middle).join("") + suffix;
  if (Buffer.byteLength(candidate, "utf8") <= maxBytes) {
    low = middle;
  } else {
    high = middle - 1;
  }
}

writeFileSync(outputPath, codePoints.slice(0, low).join("") + suffix);
