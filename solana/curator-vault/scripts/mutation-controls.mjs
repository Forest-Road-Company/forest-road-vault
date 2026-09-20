#!/usr/bin/env node

import {createHash} from "node:crypto";
import {spawnSync} from "node:child_process";
import {existsSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync} from "node:fs";
import {userInfo} from "node:os";
import {dirname, join} from "node:path";
import {fileURLToPath} from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const artifactPath = join(root, "target/deploy/forestroad_curator_vault.so");
const source = (relative) => join(root, "programs/forestroad-curator-vault/src", relative);
const files = {
  state: source("state.rs"),
  admin: source("instructions/admin.rs"),
  curator: source("instructions/curator.rs"),
  treasury: source("instructions/treasury.rs"),
};
const originals = new Map(Object.values(files).map((path) => [path, readFileSync(path, "utf8")]));
const toolHome = userInfo().homedir;
const harnessHome = process.env.HOME ?? toolHome;
const createdToolLinks = [];

// Keep the caller's isolated HOME while making only the pinned build-tool installations visible.
// No Solana wallet/config directory is linked into the harness.
if (harnessHome !== toolHome) {
  for (const relative of [
    ".avm/bin",
    ".avm/.version",
    ".cargo",
    ".rustup",
    ".cache/solana/v1.57",
    ".local/share/solana",
  ]) {
    const target = join(toolHome, relative);
    const link = join(harnessHome, relative);
    if (!existsSync(target) || existsSync(link)) continue;
    mkdirSync(dirname(link), {recursive: true});
    symlinkSync(target, link);
    createdToolLinks.push(link);
  }
}

function removeToolLinks() {
  for (const link of createdToolLinks.reverse()) rmSync(link, {force: true});
}
process.once("exit", removeToolLinks);
const env = {
  ...process.env,
  CARGO_HOME: process.env.CARGO_HOME ?? join(toolHome, ".cargo"),
  RUSTUP_HOME: process.env.RUSTUP_HOME ?? join(toolHome, ".rustup"),
  PATH: [
    process.env.PATH,
    join(toolHome, ".cargo/bin"),
    join(toolHome, ".avm/bin"),
    join(toolHome, ".local/share/solana/install/active_release/bin"),
  ].filter(Boolean).join(":"),
};

function digest(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function run(command, args) {
  return spawnSync(command, args, {cwd: root, env, encoding: "utf8"});
}

function requireSuccess(result, label) {
  if (result.status !== 0) {
    process.stderr.write(result.stdout ?? "");
    process.stderr.write(result.stderr ?? "");
    throw new Error(`${label} failed with status ${result.status}`);
  }
}

function replaceExactly(text, needle, replacement, expected = 1) {
  const matches = text.split(needle).length - 1;
  if (matches !== expected) {
    throw new Error(`expected ${expected} mutation target(s), found ${matches}: ${needle.trim()}`);
  }
  return text.split(needle).join(replacement);
}

function replaceWithinStruct(text, structName, needle, replacement = "") {
  const startMarker = `pub struct ${structName}<'info> {`;
  const start = text.indexOf(startMarker);
  if (start === -1) throw new Error(`mutation target ${structName} was not found`);
  const end = text.indexOf("\n}\n", start);
  if (end === -1) throw new Error(`mutation target ${structName} has no closing brace`);
  const block = text.slice(start, end);
  const changed = replaceExactly(block, needle, replacement);
  return text.slice(0, start) + changed + text.slice(end);
}

function restoreSources() {
  for (const [path, contents] of originals) writeFileSync(path, contents);
}

let restoringAfterSignal = false;
function restoreAfterSignal(signal) {
  if (restoringAfterSignal) return;
  restoringAfterSignal = true;
  try {
    restoreSources();
    requireSuccess(run("npm", ["run", "build:program"]), `restore after ${signal}`);
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.stack : String(error)}\n`);
  } finally {
    removeToolLinks();
    process.exit(signal === "SIGINT" ? 130 : 143);
  }
}
process.once("SIGINT", () => restoreAfterSignal("SIGINT"));
process.once("SIGTERM", () => restoreAfterSignal("SIGTERM"));

const ownerConstraint =
  "        constraint = treasury_ata.owner == config.treasury_authority @ VaultError::WrongTokenAccount\n";

const mutations = [
  {
    name: "post-boundary coupon cannot be paid early",
    test: "midmonth_checkpoints_never_pay_coupon_past_the_completed_boundary",
    apply() {
      const before = originals.get(files.state);
      const needle = "        self.accrue(position, to)\n    }\n\n    /// Advances a position";
      const replacement =
        "        self.accrue(position, to)?;\n" +
        "        position.coupon_payable = position.coupon_owed;\n" +
        "        Ok(())\n" +
        "    }\n\n    /// Advances a position";
      writeFileSync(files.state, replaceExactly(before, needle, replacement));
    },
  },
  {
    name: "loss attribution remains per position",
    test: "draws_returns_losses_and_withdrawals_are_attributed_per_position",
    apply() {
      const before = originals.get(files.treasury);
      writeFileSync(
        files.treasury,
        replaceExactly(
          before,
          "    require!(amount <= position.drawn, VaultError::LossExceedsDrawn);",
          "    require!(amount <= config.drawn, VaultError::LossExceedsDrawn);",
        ),
      );
    },
  },
  {
    name: "coupon liability remains reserved from sweeps",
    test: "accrued_coupon_is_reserved_against_every_sweep",
    apply() {
      const before = originals.get(files.treasury);
      const guard =
        "    require!(\n" +
        "        amount <= unaccounted_surplus,\n" +
        "        VaultError::CouponLiabilityReserved\n" +
        "    );\n";
      writeFileSync(files.treasury, replaceExactly(before, guard, ""));
    },
  },
  {
    name: "emergency actions retain their authority constraints",
    test: "emergency_authority_is_one_way_and_existing_positions_keep_their_terms",
    apply() {
      const adminNeedle =
        "    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump, has_one = emergency_authority)]\n";
      const curatorNeedle =
        "    #[account(seeds = [CONFIG_SEED], bump = config.bump, has_one = emergency_authority)]\n";
      writeFileSync(files.admin, replaceExactly(originals.get(files.admin), adminNeedle, ""));
      writeFileSync(
        files.curator,
        replaceExactly(originals.get(files.curator), curatorNeedle, ""),
      );
    },
  },
  {
    name: "existing positions retain their snapshotted notice term",
    test: "emergency_authority_is_one_way_and_existing_positions_keep_their_terms",
    apply() {
      const before = originals.get(files.curator);
      writeFileSync(
        files.curator,
        replaceExactly(
          before,
          "        .checked_add(position.notice_seconds as i64)",
          "        .checked_add(config.notice_seconds as i64)",
        ),
      );
    },
  },
  {
    name: "sweeps re-check the live treasury owner",
    test: "treasury_destination_owner_is_rechecked_by_every_sweep",
    apply() {
      let mutated = originals.get(files.treasury);
      mutated = replaceWithinStruct(mutated, "SweepCoupons", ownerConstraint);
      mutated = replaceWithinStruct(mutated, "SweepPrincipalSurplus", ownerConstraint);
      writeFileSync(files.treasury, mutated);
    },
  },
  {
    name: "accounted coupon funding remains locked until every position closes",
    test: "unused_coupon_funding_is_withdrawable_only_after_every_position_closes",
    apply() {
      const before = originals.get(files.treasury);
      const guard =
        "    require!(\n" +
        "        config.positions == 0 && config.coupon_owed_total == 0,\n" +
        "        VaultError::VaultNotEmpty\n" +
        "    );\n";
      writeFileSync(files.treasury, replaceExactly(before, guard, ""));
    },
  },
  {
    name: "a pending notice blocks new draws once the exit window opens",
    test: "treasury_draws_continue_during_lock_and_stop_at_the_exit_window",
    apply() {
      const before = originals.get(files.treasury);
      const guard =
        "    require!(\n" +
        "        position.notice_requested_at == 0 || now < position.lock_end,\n" +
        "        VaultError::NoticePending\n" +
        "    );\n";
      writeFileSync(files.treasury, replaceExactly(before, guard, ""));
    },
  },
  {
    name: "terminal coupon-funding withdrawal respects the global pause",
    test: "unused_coupon_funding_is_withdrawable_only_after_every_position_closes",
    apply() {
      const before = originals.get(files.treasury);
      const anchor =
        "pub fn handle_withdraw_unused_coupon_funding(\n" +
        "    ctx: Context<SweepCoupons>,\n" +
        "    amount: u64,\n" +
        ") -> Result<()> {";
      const start = before.indexOf(anchor);
      if (start === -1) throw new Error("terminal withdrawal handler was not found");
      const end = before.indexOf("\n}\n", start);
      if (end === -1) throw new Error("terminal withdrawal handler has no closing brace");
      const block = before.slice(start, end);
      const guard = "    require!(!config.paused, VaultError::Paused);\n";
      const changed = replaceExactly(block, guard, "");
      writeFileSync(files.treasury, before.slice(0, start) + changed + before.slice(end));
    },
  },
];

if (!existsSync(artifactPath)) {
  throw new Error("missing program artifact; run npm run build:program first");
}

// Normalize a canonical release artifact or a developer artifact to the pinned host build before
// comparing bytes. The canonical Docker build is intentionally not byte-identical to this build.
requireSuccess(run("npm", ["run", "build:program"]), "pristine host program build");
const pristineHash = digest(artifactPath);
let completed = false;
try {
  for (const mutation of mutations) {
    restoreSources();
    mutation.apply();
    const changedFiles = [...originals].filter(
      ([path, contents]) => readFileSync(path, "utf8") !== contents,
    );
    if (changedFiles.length === 0) throw new Error(`${mutation.name}: source did not change`);

    requireSuccess(run("npm", ["run", "build:program"]), `${mutation.name}: program build`);
    const mutatedHash = digest(artifactPath);
    if (mutatedHash === pristineHash) {
      throw new Error(`${mutation.name}: artifact is byte-identical to the pristine build`);
    }

    const test = run("cargo", [
      "test",
      "-p", "forestroad-curator-vault",
      "--locked",
      "--test", "lifecycle",
      mutation.test,
      "--", "--exact", "--nocapture",
    ]);
    const output = `${test.stdout ?? ""}\n${test.stderr ?? ""}`;
    if (test.status === 0) throw new Error(`${mutation.name}: mutation survived its regression`);
    if (!output.includes(`test ${mutation.test} ... FAILED`)) {
      process.stderr.write(output);
      throw new Error(`${mutation.name}: regression failed for an unrelated reason`);
    }
    const campaignName = "stateful_instruction_sequences_preserve_the_program_invariants";
    const campaign = run("cargo", [
      "test",
      "-p", "forestroad-curator-vault",
      "--locked",
      "--test", "lifecycle",
      campaignName,
      "--", "--exact", "--nocapture",
    ]);
    const campaignOutput = `${campaign.stdout ?? ""}\n${campaign.stderr ?? ""}`;
    if (campaign.status === 0) {
      throw new Error(`${mutation.name}: mutation survived the stateful campaign`);
    }
    if (!campaignOutput.includes(`test ${campaignName} ... FAILED`)) {
      process.stderr.write(campaignOutput);
      throw new Error(`${mutation.name}: campaign failed for an unrelated reason`);
    }
    process.stdout.write(`Mutation killed: ${mutation.name} (${mutatedHash}).\n`);
  }
  completed = true;
} finally {
  process.removeAllListeners("SIGINT");
  process.removeAllListeners("SIGTERM");
  restoreSources();
  const restoredBuild = run("npm", ["run", "build:program"]);
  requireSuccess(restoredBuild, "restored program build");
  for (const [path, contents] of originals) {
    if (readFileSync(path, "utf8") !== contents) {
      throw new Error(`failed to restore ${path}`);
    }
  }
  const restoredHash = digest(artifactPath);
  if (restoredHash !== pristineHash) {
    throw new Error(
      `restored artifact hash ${restoredHash} differs from pristine ${pristineHash}`,
    );
  }
}

if (!completed) throw new Error("mutation controls did not complete");
removeToolLinks();
process.stdout.write(`All ${mutations.length} mutation controls passed; pristine ${pristineHash}.\n`);
