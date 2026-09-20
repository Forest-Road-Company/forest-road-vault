/**
 * Snapshots the devnet vault's accounts into `deployments/devnet-snapshot.json` so the LiteSVM
 * fork test (`tests/devnet_fork.rs`) can load the LIVE state and fast-forward the clock to the
 * month boundaries devnet itself cannot reach yet. Addresses and account data only; no keys.
 *
 *   ANCHOR_PROVIDER_URL=https://api.devnet.solana.com npx tsx scripts/snapshot-devnet.ts
 */
import { Connection, PublicKey } from "@solana/web3.js";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const DEVNET_GENESIS = "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG";
const RPC_URL = process.env.ANCHOR_PROVIDER_URL ?? "https://api.devnet.solana.com";

async function main() {
  const connection = new Connection(RPC_URL, "finalized");
  if ((await connection.getGenesisHash()) !== DEVNET_GENESIS) throw new Error("not devnet");
  const manifest = JSON.parse(readFileSync(join(HERE, "..", "deployments", "devnet.json"), "utf8"));
  const build = JSON.parse(readFileSync(join(HERE, "..", "deployments", "build.json"), "utf8"));
  const release = JSON.parse(readFileSync(join(HERE, "..", "release-build.json"), "utf8"));
  const names = ["config", "vaultAta", "couponAta", "curatorPosition", "mint", "curatorAta", "treasuryAta"] as const;
  const keys = [
    ...names.map((n) => new PublicKey(manifest[n] as string)),
    new PublicKey(manifest.idlMetadata.address as string),
  ];
  const programId = new PublicKey(manifest.programId as string);
  // The upgradeable loader keeps the executable bytes in a separate programdata account.
  const programAccount = await connection.getAccountInfo(programId);
  if (!programAccount?.executable || programAccount.owner.toBase58() !== "BPFLoaderUpgradeab1e11111111111111111111111") {
    throw new Error("upgradeable program not found");
  }
  const programData = new PublicKey(programAccount.data.subarray(4, 36));
  const {context, value: infos} = await connection.getMultipleAccountsInfoAndContext(
    [...keys, programData],
    "finalized",
  );
  // Bind the snapshot to the bank that supplied the account values. A later standalone getSlot()
  // can only approximate that relationship when the cluster advances between the two calls.
  const slot = context.slot;
  const accounts: Record<string, unknown> = {};
  [...names, "idlMetadata", "programData"].forEach((name, i) => {
    const info = infos[i];
    if (!info) throw new Error(`missing account ${name}`);
    accounts[name] = {
      address: i < keys.length ? keys[i].toBase58() : programData.toBase58(),
      lamports: info.lamports,
      owner: info.owner.toBase58(),
      executable: info.executable,
      data: Buffer.from(info.data).toString("base64"),
    };
  });
  const localElf = readFileSync(join(HERE, "..", release.canonicalArtifact));
  const programDataBytes = Buffer.from((infos.at(-1))!.data);
  const deployedElf = programDataBytes.subarray(45);
  const localHash = createHash("sha256").update(localElf).digest("hex");
  if (
    manifest.programId !== programId.toBase58() ||
    manifest.programData !== programData.toBase58() ||
    build.schemaVersion !== 2 ||
    build.programId !== programId.toBase58() ||
    release.programId !== programId.toBase58() ||
    JSON.stringify(manifest.build) !== JSON.stringify(build) ||
    build.releaseBuilder?.solanaVerify !== release.solanaVerifyVersion ||
    build.releaseBuilder?.solanaCli !== release.solanaCliVersion ||
    build.releaseBuilder?.sbfArch !== release.sbfArch ||
    build.releaseBuilder?.platformTools !== release.platformTools ||
    build.releaseBuilder?.baseImage !== release.baseImage ||
    build.elfSha256 !== localHash ||
    build.elfBytes !== localElf.length ||
    programDataBytes[12] !== 1 ||
    programDataBytes.readBigUInt64LE(4) !== BigInt(manifest.canonicalBuildActivatedAtSlot) ||
    !localElf.equals(deployedElf.subarray(0, localElf.length)) ||
    deployedElf.subarray(localElf.length).some((byte) => byte !== 0)
  ) {
    throw new Error("deployed program, local ELF and clean build receipt do not match");
  }
  const out = {
    cluster: "devnet",
    programId: programId.toBase58(),
    build,
    deploymentSignature: manifest.signatures?.deployProgram,
    canonicalBuildActivationSignature: manifest.signatures?.canonicalBuildActivation,
    canonicalBuildActivatedAtSlot: manifest.canonicalBuildActivatedAtSlot,
    takenAtSlot: slot,
    takenAt: new Date().toISOString(),
    accounts,
  };
  const path = join(HERE, "..", "deployments", "devnet-snapshot.json");
  writeFileSync(path, JSON.stringify(out, null, 2) + "\n");
  console.log("snapshot written", path, "slot", slot);
}

main().catch((e) => {
  const message = e instanceof Error ? e.message : String(e);
  console.error(message.replaceAll(RPC_URL, "[RPC endpoint]"));
  process.exit(1);
});
