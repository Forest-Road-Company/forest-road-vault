#!/usr/bin/env node

import {readFileSync} from "node:fs";
import {dirname, join} from "node:path";
import {fileURLToPath} from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const program = join(root, "programs/forestroad-curator-vault");
const read = (relative) => readFileSync(join(program, relative), "utf8");
const lib = read("src/lib.rs");
const errorsSource = read("src/error.rs");
const eventsSource = read("src/events.rs");
const lifecycle = read("tests/lifecycle.rs");
const mathTests = read("src/math.rs");

const instructions = [...lib.matchAll(/^    pub fn (\w+)\(/gm)].map((match) => match[1]);
const errors = [...errorsSource.matchAll(/^    ([A-Z][A-Za-z0-9_]+),$/gm)].map(
  (match) => match[1],
);
const events = [...eventsSource.matchAll(/^pub struct ([A-Z][A-Za-z0-9_]+)/gm)].map(
  (match) => match[1],
);
const lifecycleTests = [...lifecycle.matchAll(/^#\[test\]$/gm)].length;
const arithmeticTests = [...mathTests.matchAll(/^\s+#\[test\]$/gm)].length;
const pascal = (name) => name.split("_").map((part) => part[0].toUpperCase() + part.slice(1)).join("");

const missingInstructions = instructions.filter((name) => !lifecycle.includes(`ix::${pascal(name)}`));
const missingErrors = errors.filter((name) => !lifecycle.includes(`"${name}"`));
const missingEvents = events.filter((name) => !lifecycle.includes(`events::${name}`));

if (instructions.length !== 25 || missingInstructions.length !== 0) {
  throw new Error(
    `instruction census: ${instructions.length}/25 declared; missing tests: ${missingInstructions.join(", ")}`,
  );
}
if (errors.length !== 38 || missingErrors.length !== 0) {
  throw new Error(`error census: ${errors.length}/38 declared; missing tests: ${missingErrors.join(", ")}`);
}
if (events.length !== 23 || missingEvents.length !== 0) {
  throw new Error(`event census: ${events.length}/23 declared; missing tests: ${missingEvents.join(", ")}`);
}
if (!lifecycle.includes("for seed in 1u64..=32") || !lifecycle.includes("for step in 0..96")) {
  throw new Error("stateful campaign no longer contains 32 books of 96 checked steps");
}
const campaign = lifecycle.slice(lifecycle.indexOf("fn stateful_instruction_sequences"));
if (/let _ = w\./.test(campaign)) {
  throw new Error("stateful campaign discards a transaction result");
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
    `event types ${events.length}/${events.length}`,
    `arithmetic tests ${arithmeticTests}`,
    `lifecycle tests ${lifecycleTests}`,
    "stateful checked steps 3072",
  ].join("; ") + "\n",
);
