#!/usr/bin/env node
import {createHash} from "node:crypto";
import {execFileSync} from "node:child_process";
import {existsSync, readFileSync, statSync, writeFileSync} from "node:fs";
import {delimiter, dirname, join} from "node:path";
import {homedir} from "node:os";
import {fileURLToPath} from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const repository = execFileSync("git", ["-C", root, "rev-parse", "--show-toplevel"], {encoding: "utf8"}).trim();
const release = JSON.parse(readFileSync(join(root, "release-build.json"), "utf8"));
const receiptPath = join(root, "deployments", "build.json");
const artifactPath = join(root, release.canonicalArtifact);
const generatedElfPath = join(root, release.buildOutput);
const generatedIdlPath = join(root, "target", "idl", "forestroad_curator_vault.json");
const frontendIdlPath = join(repository, "frontend", "src", "config", "curator-vault.idl.json");
const sha256 = (path) => createHash("sha256").update(readFileSync(path)).digest("hex");
const toolPath = [
  process.env.PATH,
  join(homedir(), ".avm", "bin"),
  join(homedir(), ".cargo", "bin"),
  join(homedir(), ".local", "share", "solana", "install", "active_release", "bin"),
].filter(Boolean).join(delimiter);
const command = (name, args) => execFileSync(name, args, {
  encoding: "utf8",
  env: {...process.env, PATH: toolPath},
}).trim();
const git = (...args) => command("git", ["-C", repository, ...args]);
const sourceInputs = [
  "solana/curator-vault/Anchor.toml",
  "solana/curator-vault/Cargo.toml",
  "solana/curator-vault/Cargo.lock",
  "solana/curator-vault/rust-toolchain.toml",
  "solana/curator-vault/release-build.json",
  "solana/curator-vault/programs/forestroad-curator-vault/Cargo.toml",
  "solana/curator-vault/programs/forestroad-curator-vault/src",
  "solana/curator-vault/scripts/build-program.sh",
  "solana/curator-vault/scripts/build-release.mjs",
];

function requireFile(path, label) {
  if (!existsSync(path)) throw new Error(`${label} is missing: ${path}`);
}

function assertEqual(actual, expected, label) {
  if (actual !== expected) throw new Error(`${label}: expected ${expected}, got ${actual}`);
}

function validateReleaseConfig() {
  if (
    release.schemaVersion !== 1 || !release.baseImage?.includes("@sha256:") ||
    !["v0", "v1", "v2", "v3"].includes(release.sbfArch) ||
    !/^v\d+\.\d+$/.test(release.platformTools)
  ) {
    throw new Error("release-build.json must use schema 1 and a digest-pinned image");
  }
  if (release.programId !== "3ZPRvNDUDRZuZ8Hug873JtSDJueA8D7PEVE21uLLAvwh") {
    throw new Error("release-build.json names an unexpected program");
  }
}

function ensureSourceInputsClean() {
  const status = git("status", "--porcelain", "--", ...sourceInputs);
  if (status) throw new Error(`release source inputs are dirty:\n${status}`);
}

function ensureSourceCommit(sourceCommit) {
  command("git", ["-C", repository, "merge-base", "--is-ancestor", sourceCommit, "HEAD"]);
  const drift = git("diff", "--name-only", sourceCommit, "HEAD", "--", ...sourceInputs);
  if (drift) throw new Error(`release source inputs changed after ${sourceCommit}:\n${drift}`);
}

function currentHostToolchain() {
  return {
    anchor: command("anchor", ["--version"]),
    solana: command("solana", ["--version"]),
    rustc: command("rustc", ["--version"]),
    sbfArch: "v3",
    platformTools: "v1.57",
  };
}

function makeRecord(sourceCommit) {
  requireFile(artifactPath, "canonical release ELF");
  requireFile(generatedIdlPath, "generated IDL");
  const idl = JSON.parse(readFileSync(generatedIdlPath, "utf8"));
  assertEqual(idl.address, release.programId, "IDL program");
  return {
    schemaVersion: 2,
    gitCommit: sourceCommit,
    dirty: false,
    programId: release.programId,
    elfSha256: sha256(artifactPath),
    elfBytes: statSync(artifactPath).size,
    idlSha256: sha256(generatedIdlPath),
    idlBytes: statSync(generatedIdlPath).size,
    hostToolchain: currentHostToolchain(),
    releaseBuilder: {
      solanaVerify: release.solanaVerifyVersion,
      solanaCli: release.solanaCliVersion,
      sbfArch: release.sbfArch,
      platformTools: release.platformTools,
      baseImage: release.baseImage,
    },
  };
}

function verify(generated) {
  ensureSourceInputsClean();
  requireFile(receiptPath, "release build receipt");
  requireFile(artifactPath, "canonical release ELF");
  requireFile(frontendIdlPath, "committed frontend IDL");
  const expected = JSON.parse(readFileSync(receiptPath, "utf8"));
  if (expected.schemaVersion !== 2 || expected.dirty !== false) {
    throw new Error("release build receipt must be clean schema 2");
  }
  assertEqual(expected.programId, release.programId, "receipt program");
  assertEqual(expected.elfSha256, sha256(artifactPath), "canonical ELF hash");
  assertEqual(expected.elfBytes, statSync(artifactPath).size, "canonical ELF size");
  assertEqual(expected.idlSha256, sha256(frontendIdlPath), "committed IDL hash");
  assertEqual(expected.idlBytes, statSync(frontendIdlPath).size, "committed IDL size");
  assertEqual(expected.releaseBuilder?.solanaVerify, release.solanaVerifyVersion, "solana-verify pin");
  assertEqual(expected.releaseBuilder?.solanaCli, release.solanaCliVersion, "release Solana pin");
  assertEqual(expected.releaseBuilder?.sbfArch, release.sbfArch, "release SBF architecture");
  assertEqual(expected.releaseBuilder?.platformTools, release.platformTools, "release platform tools");
  assertEqual(expected.releaseBuilder?.baseImage, release.baseImage, "release image pin");
  ensureSourceCommit(expected.gitCommit);

  const frontendIdl = JSON.parse(readFileSync(frontendIdlPath, "utf8"));
  assertEqual(frontendIdl.address, release.programId, "committed IDL program");
  if (generated) {
    requireFile(generatedElfPath, "generated release ELF");
    requireFile(generatedIdlPath, "generated IDL");
    assertEqual(sha256(generatedElfPath), expected.elfSha256, "generated release ELF hash");
    assertEqual(statSync(generatedElfPath).size, expected.elfBytes, "generated release ELF size");
    assertEqual(sha256(generatedIdlPath), expected.idlSha256, "generated IDL hash");
    assertEqual(statSync(generatedIdlPath).size, expected.idlBytes, "generated IDL size");
    const actualHost = currentHostToolchain();
    assertEqual(JSON.stringify(actualHost), JSON.stringify(expected.hostToolchain), "host/IDL toolchain");
  }
  process.stdout.write(`Verified canonical curator release receipt ${expected.gitCommit}.\n`);
}

validateReleaseConfig();
if (process.argv.includes("--verify") || process.argv.includes("--verify-generated")) {
  verify(process.argv.includes("--verify-generated"));
} else if (process.argv.includes("--write")) {
  ensureSourceInputsClean();
  const index = process.argv.indexOf("--source-commit");
  const sourceCommit = index >= 0 ? process.argv[index + 1] : git("rev-parse", "HEAD");
  if (!sourceCommit) throw new Error("--source-commit requires a commit");
  ensureSourceCommit(sourceCommit);
  const record = makeRecord(sourceCommit);
  writeFileSync(receiptPath, `${JSON.stringify(record, null, 2)}\n`);
  process.stdout.write(`${receiptPath}\n`);
} else {
  throw new Error("use --write, --verify or --verify-generated");
}
