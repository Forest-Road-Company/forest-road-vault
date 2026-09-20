#!/usr/bin/env node
import {createHash} from "node:crypto";
import {spawnSync} from "node:child_process";
import {existsSync, readFileSync} from "node:fs";
import {dirname, join} from "node:path";
import {fileURLToPath} from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const config = JSON.parse(readFileSync(join(root, "release-build.json"), "utf8"));

if (
  config.schemaVersion !== 1 || !config.libraryName || !config.baseImage || !config.buildOutput ||
  !["v0", "v1", "v2", "v3"].includes(config.sbfArch) ||
  !/^v\d+\.\d+$/.test(config.platformTools)
) {
  throw new Error("invalid release-build.json");
}
if (!config.baseImage.includes("@sha256:")) {
  throw new Error("release base image must be pinned by digest");
}

const version = spawnSync("solana-verify", ["--version"], {encoding: "utf8"});
if (version.status !== 0) throw new Error("solana-verify is unavailable");
const versionText = `${version.stdout}${version.stderr}`.trim();
if (!versionText.includes(config.solanaVerifyVersion)) {
  throw new Error(`wrong solana-verify version: expected ${config.solanaVerifyVersion}, got ${versionText}`);
}

const result = spawnSync(
  "solana-verify",
  [
    "build",
    "--library-name", config.libraryName,
    "--base-image", config.baseImage,
    "--arch", config.sbfArch,
    `--cargo-build-sbf-args=--tools-version ${config.platformTools}`,
  ],
  {cwd: root, env: process.env, stdio: "inherit"},
);
if (result.status !== 0) process.exit(result.status ?? 1);

const output = join(root, config.buildOutput);
if (!existsSync(output)) throw new Error(`release build did not produce ${config.buildOutput}`);
const bytes = readFileSync(output);
const hash = createHash("sha256").update(bytes).digest("hex");
process.stdout.write(`Canonical release ELF ${bytes.length} bytes, SHA-256 ${hash}\n`);
