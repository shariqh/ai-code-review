// Reads a step's log output and prints every workflow command the Actions
// runner would process from it, other than ::stop-commands:: and its resume
// token, as "line <n>: <command>" (lowercased). It follows the runner's
// ActionCommandManager: ActionCommand.TryParseV2 (`::name ...::data`, at the
// start of the line after leading whitespace) is tried first, then the
// legacy ActionCommand.TryParse (`##[name ...]data`, found anywhere in the
// line). Either form counts only for a registered command name, compared
// case-insensitively (OrdinalIgnoreCase), as are stop-commands and its
// resume token; while commands are stopped only that token resumes them.
// Output is split into lines the way the runner reads it: at CR, LF or CRLF.
import { readFileSync } from "node:fs";

const [logPath] = process.argv.slice(2);
if (!logPath) {
  throw new Error("usage: workflow-commands.mjs <log>");
}

const registered = new Set([
  "stop-commands", "set-env", "set-output", "save-state", "add-path",
  "add-mask", "add-matcher", "remove-matcher", "warning", "error", "notice",
  "debug", "group", "endgroup", "echo",
]);

function commandName(info) {
  const space = info.indexOf(" ");
  return (space < 0 ? info : info.slice(0, space)).toLowerCase();
}

function parseV2(line) {
  const message = line.trimStart();
  if (!message.startsWith("::")) return null;
  const end = message.indexOf("::", 2);
  if (end < 0) return null;
  return { name: commandName(message.slice(2, end)), data: message.slice(end + 2) };
}

function parseV1(line) {
  const start = line.indexOf("##[");
  if (start < 0) return null;
  const end = line.indexOf("]", start);
  if (end < 0) return null;
  return { name: commandName(line.slice(start + 3, end)), data: line.slice(end + 1) };
}

let stopToken = null;
readFileSync(logPath, "utf8").split(/\r\n|\r|\n/).forEach((line, index) => {
  const command = [parseV2(line), parseV1(line)]
    .find((candidate) => candidate && registered.has(candidate.name));
  if (!command) return;
  if (stopToken !== null) {
    if (command.name === stopToken) {
      registered.delete(stopToken);
      stopToken = null;
    }
    return;
  }
  if (command.name === "stop-commands") {
    stopToken = command.data.toLowerCase();
    registered.add(stopToken);
    return;
  }
  console.log(`line ${index + 1}: ${command.name}`);
});
