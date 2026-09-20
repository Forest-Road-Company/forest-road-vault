#!/usr/bin/env node

import {readFileSync} from "node:fs";
import {dirname, join} from "node:path";
import {fileURLToPath} from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const program = join(root, "programs/forestroad-curator-vault");
const read = (relative) => readFileSync(join(program, relative), "utf8");
const libSource = read("src/lib.rs");
const errorsSource = read("src/error.rs");
const eventsSource = read("src/events.rs");
const lifecycleSource = read("tests/lifecycle.rs");
const mathSource = read("src/math.rs");

// Keep string literals, which carry named-error assertions, but mask comments. A call or type name
// written only in prose can no longer satisfy the executable census.
function stripComments(source) {
  let output = "";
  let mode = "code";
  let blockDepth = 0;
  let escaped = false;
  for (let index = 0; index < source.length; index += 1) {
    const char = source[index];
    const next = source[index + 1];
    if (mode === "line") {
      if (char === "\n") {
        mode = "code";
        output += "\n";
      } else output += " ";
      continue;
    }
    if (mode === "block") {
      if (char === "/" && next === "*") {
        blockDepth += 1;
        output += "  ";
        index += 1;
      } else if (char === "*" && next === "/") {
        blockDepth -= 1;
        output += "  ";
        index += 1;
        if (blockDepth === 0) mode = "code";
      } else output += char === "\n" ? "\n" : " ";
      continue;
    }
    if (mode === "string" || mode === "char") {
      output += char;
      if (escaped) escaped = false;
      else if (char === "\\") escaped = true;
      else if ((mode === "string" && char === '"') || (mode === "char" && char === "'")) {
        mode = "code";
      }
      continue;
    }
    if (char === "/" && next === "/") {
      mode = "line";
      output += "  ";
      index += 1;
    } else if (char === "/" && next === "*") {
      mode = "block";
      blockDepth = 1;
      output += "  ";
      index += 1;
    } else {
      output += char;
      if (char === '"') mode = "string";
      else if (char === "'") mode = "char";
    }
  }
  if (mode === "block") throw new Error("unterminated block comment in census input");
  return output;
}

function callBodies(source, callee) {
  const bodies = [];
  const needle = `${callee}(`;
  let cursor = 0;
  while ((cursor = source.indexOf(needle, cursor)) !== -1) {
    const start = cursor + needle.length;
    let depth = 1;
    let mode = "code";
    let escaped = false;
    let end = start;
    for (; end < source.length && depth > 0; end += 1) {
      const char = source[end];
      if (mode === "string" || mode === "char") {
        if (escaped) escaped = false;
        else if (char === "\\") escaped = true;
        else if ((mode === "string" && char === '"') || (mode === "char" && char === "'")) {
          mode = "code";
        }
      } else if (char === '"') mode = "string";
      else if (char === "'") mode = "char";
      else if (char === "(") depth += 1;
      else if (char === ")") depth -= 1;
    }
    if (depth !== 0) throw new Error(`unterminated ${callee} call`);
    bodies.push(source.slice(start, end - 1));
    cursor = end;
  }
  return bodies;
}

function functionBody(source, functionName) {
  const marker = `fn ${functionName}(`;
  const start = source.indexOf(marker);
  if (start === -1) throw new Error(`missing function ${functionName}`);
  const brace = source.indexOf("{", start);
  let depth = 1;
  let cursor = brace + 1;
  for (; cursor < source.length && depth > 0; cursor += 1) {
    if (source[cursor] === "{") depth += 1;
    else if (source[cursor] === "}") depth -= 1;
  }
  if (depth !== 0) throw new Error(`unterminated function ${functionName}`);
  return source.slice(brace + 1, cursor - 1);
}

const lib = stripComments(libSource);
const errorsCode = stripComments(errorsSource);
const eventsCode = stripComments(eventsSource);
const lifecycle = stripComments(lifecycleSource);
const instructions = [...lib.matchAll(/^    pub fn (\w+)\(/gm)].map((match) => match[1]);
const errors = [...errorsCode.matchAll(/^    ([A-Z][A-Za-z0-9_]+),$/gm)].map(
  (match) => match[1],
);
const eventStructs = [...eventsCode.matchAll(
  /^pub struct ([A-Z][A-Za-z0-9_]+)\s*\{([\s\S]*?)^\}/gm,
)].map((match) => ({
  name: match[1],
  fields: [...match[2].matchAll(/^    pub (\w+):/gm)].map((field) => field[1]),
}));
const lifecycleTests = [...lifecycle.matchAll(/^#\[test\]$/gm)].length;
const arithmeticTests = [...stripComments(mathSource).matchAll(/^\s+#\[test\]$/gm)].length;
const pascal = (name) => name.split("_").map(
  (part) => part[0].toUpperCase() + part.slice(1),
).join("");

const missingInstructions = instructions.filter((name) => {
  const expression = new RegExp(`\\bix::${pascal(name)}\\s*\\{`);
  return !expression.test(lifecycle);
});
const assertedErrors = new Set();
for (const body of callBodies(lifecycle, "expect_error")) {
  for (const match of body.matchAll(/"([A-Z][A-Za-z0-9_]+)"/g)) assertedErrors.add(match[1]);
}
for (const match of lifecycle.matchAll(/\.contains\(\s*"([A-Z][A-Za-z0-9_]+)"\s*\)/g)) {
  assertedErrors.add(match[1]);
}
const missingErrors = errors.filter((name) => !assertedErrors.has(name));
const missingEventFields = [];
for (const event of eventStructs) {
  const decode = new RegExp(
    `let\\s+(\\w+)\\s*=\\s*w\\.last_event::<events::${event.name}>\\(\\);`,
    "g",
  );
  const matches = [...lifecycle.matchAll(decode)];
  if (matches.length === 0) {
    missingEventFields.push(`${event.name}.*`);
    continue;
  }
  for (const field of event.fields) {
    const asserted = matches.some((match) => {
      const start = match.index + match[0].length;
      const nextDecode = lifecycle.indexOf(".last_event::<events::", start);
      const window = lifecycle.slice(start, nextDecode === -1 ? start + 4_000 : nextDecode);
      return new RegExp(`\\b${match[1]}\\.${field}\\b`).test(window)
        && /assert(?:_eq|_ne)?!\s*\(/.test(window);
    });
    if (!asserted) missingEventFields.push(`${event.name}.${field}`);
  }
}

if (instructions.length !== 25 || missingInstructions.length !== 0) {
  throw new Error(
    `instruction census: ${instructions.length}/25 declared; missing tests: ${missingInstructions.join(", ")}`,
  );
}
if (errors.length !== 38 || missingErrors.length !== 0) {
  throw new Error(`error census: ${errors.length}/38 declared; missing tests: ${missingErrors.join(", ")}`);
}
if (eventStructs.length !== 23 || missingEventFields.length !== 0) {
  throw new Error(
    `event census: ${eventStructs.length}/23 declared; missing decoded field assertions: ${missingEventFields.join(", ")}`,
  );
}
if (/\blet\s+_[A-Za-z0-9_]*\s*=/.test(lifecycle)) {
  throw new Error("lifecycle suite contains a deliberately discarded result");
}
const campaign = functionBody(
  lifecycle,
  "stateful_instruction_sequences_preserve_the_program_invariants",
);
const seedLoop = campaign.match(/for seed in (\d+)u64\.\.=(\d+)/);
const stepLoop = campaign.match(/for step in (\d+)\.\.(\d+)/);
if (!seedLoop || !stepLoop) throw new Error("stateful campaign loop bounds are not structural");
const books = Number(seedLoop[2]) - Number(seedLoop[1]) + 1;
const stepsPerBook = Number(stepLoop[2]) - Number(stepLoop[1]);
const checkedSteps = books * stepsPerBook;
if (checkedSteps < 3_072) {
  throw new Error(`stateful campaign was reduced below 3,072 checked steps: ${checkedSteps}`);
}
if (!campaign.includes("assert_campaign_guard_oracles()")) {
  throw new Error("stateful campaign lost its deterministic guard oracles");
}
for (const marker of [
  "successful_transactions",
  "rejected_transactions",
  "successful_withdrawals",
  "eligible_states_observed",
]) {
  if (!campaign.includes(marker)) throw new Error(`stateful campaign lost ${marker}`);
}

process.stdout.write(
  [
    `instructions ${instructions.length}/${instructions.length}`,
    `declared errors ${errors.length}/${errors.length}`,
    `event types ${eventStructs.length}/${eventStructs.length}`,
    "event fields complete",
    `arithmetic tests ${arithmeticTests}`,
    `lifecycle tests ${lifecycleTests}`,
    `stateful checked steps ${checkedSteps}`,
    "guard oracles 9",
  ].join("; ") + "\n",
);
