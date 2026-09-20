#!/usr/bin/env node

import {spawnSync} from "node:child_process";
import {readFileSync, writeFileSync} from "node:fs";
import {dirname, join} from "node:path";
import {fileURLToPath} from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const cases = [
  {
    name: "a vanished class cannot retarget an Ethereum write",
    file: "src/components/curators/EthereumCuratorPanel.tsx",
    testFile: "src/components/curators/EthereumCuratorPanel.test.tsx",
    test: "binds the initial default so its disappearance cannot retarget a write",
    needle: "  const effectiveSelected = selected ?? defaultClass;",
    replacement: "  const effectiveSelected = defaultClass;",
  },
  {
    name: "a failed record write releases its source admission gate",
    file: "src/app/api/curators/interest/route.ts",
    testFile: "src/app/api/curators/interest/route.test.ts",
    test: "releases only its own source gate when the durable record write fails",
    needle: "        await releaseGates(admissionGates);",
    replacement: "        void admissionGates;",
  },
  {
    name: "a conflicting source gate is a bounded refusal",
    file: "src/app/api/curators/interest/route.ts",
    testFile: "src/app/api/curators/interest/route.test.ts",
    test: "returns 429 after one constant-cost write when the current source sub-window is occupied",
    needle: "    if (!conflict(error)) throw error;",
    replacement: "    if (conflict(error)) throw error;",
  },
  {
    name: "a corrected submission gets the next source sub-window",
    file: "src/app/api/curators/interest/route.ts",
    testFile: "src/app/api/curators/interest/route.test.ts",
    test: "stores a corrected resubmission in a later sub-window instead of treating the email as a duplicate",
    needle: "  const sourceSlot = Math.floor(now / SOURCE_SLOT_MS);",
    replacement: "  const sourceSlot = Math.floor(now / SOURCE_WINDOW_MS);",
  },
  {
    name: "independent sources do not share one admission gate",
    file: "src/app/api/curators/interest/route.ts",
    testFile: "src/app/api/curators/interest/route.test.ts",
    test: "has no shared email gate that can delete a concurrent request's admission",
    needle: "  const sourceDigest = digest(secret, `source:${sourceAddress(request)}`);",
    replacement: "  const sourceDigest = digest(secret, \"source:shared\");",
  },
  {
    name: "a filled automation trap cannot report success",
    file: "src/app/api/curators/interest/route.ts",
    testFile: "src/app/api/curators/interest/route.test.ts",
    test: "visibly refuses a filled non-semantic trap without writing",
    needle: "  if (text(raw.faxExtension, 200)) return json({ok: false, error: \"Malformed request.\"}, 400);",
    replacement: "  if (text(raw.faxExtension, 200)) return json({ok: true}, 200);",
  },
  {
    name: "the gate cleanup remains authenticated",
    file: "src/app/api/internal/curator-rate-cleanup/route.ts",
    testFile: "src/app/api/internal/curator-rate-cleanup/route.test.ts",
    test: "requires the Vercel cron bearer secret",
    needle: "  if (!authorized(request, secret)) {",
    replacement: "  if (false && !authorized(request, secret)) {",
  },
  {
    name: "the served revision body remains bound to the Vercel commit",
    file: "src/app/api/revision/route.ts",
    testFile: "src/app/api/revision/route.test.ts",
    test: "returns the exact Vercel source commit in the body and header",
    needle: "      commit,",
    replacement: "      commit: commit.slice(1),",
  },
  {
    name: "an allowlisted empty position cannot be closed by accident",
    file: "src/components/curators/CuratorVaultPanel.tsx",
    testFile: "src/components/curators/CuratorVaultPanel.connected.test.tsx",
    test: "does not offer to close a freshly allowlisted empty position",
    needle: "  const canClose =\n    revoked\n    && p.principal === 0n",
    replacement: "  const canClose =\n    p.principal === 0n",
  },
  {
    name: "a late confirmation cannot restore the previous wallet's book",
    file: "src/components/curators/CuratorVaultPanel.tsx",
    testFile: "src/components/curators/CuratorVaultPanel.connected.test.tsx",
    test: "ignores wallet A's late confirmation refresh after switching to wallet B",
    needle: "        if (!actionWalletIsCurrent()) return;",
    replacement: "        if (false && !actionWalletIsCurrent()) return;",
  },
];

for (const control of cases) {
  const path = join(root, control.file);
  const original = readFileSync(path, "utf8");
  const matches = original.split(control.needle).length - 1;
  if (matches !== 1) {
    throw new Error(`${control.name}: expected one mutation target, found ${matches}`);
  }
  const mutated = original.replace(control.needle, control.replacement);
  if (mutated === original) throw new Error(`${control.name}: source did not change`);
  try {
    writeFileSync(path, mutated);
    const result = spawnSync(
      join(root, "node_modules/.bin/vitest"),
      ["run", control.testFile, "-t", control.test],
      {cwd: root, encoding: "utf8"},
    );
    if (result.status === 0) throw new Error(`${control.name}: mutation survived`);
    const output = `${result.stdout ?? ""}\n${result.stderr ?? ""}`;
    if (!output.includes("failed")) {
      process.stderr.write(output);
      throw new Error(`${control.name}: test failed for an unrelated reason`);
    }
    process.stdout.write(`Mutation killed: ${control.name}.\n`);
  } finally {
    writeFileSync(path, original);
    if (readFileSync(path, "utf8") !== original) {
      throw new Error(`${control.name}: failed to restore ${control.file}`);
    }
  }
}

process.stdout.write(`All ${cases.length} frontend mutation controls passed.\n`);
