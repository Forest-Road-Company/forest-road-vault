import {BorshAccountsCoder, type Idl} from "@anchor-lang/core";
import {Connection, PublicKey} from "@solana/web3.js";
import {createHash} from "node:crypto";
import {readFileSync, writeFileSync} from "node:fs";
import {dirname, join} from "node:path";
import {fileURLToPath} from "node:url";
import {inflateSync} from "node:zlib";
import {associatedTokenAddress, TOKEN_ACCOUNT_SIZE, TOKEN_PROGRAM_ID} from "./token-client.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");
const DEVNET_GENESIS = "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG";
const UPGRADEABLE_LOADER = new PublicKey("BPFLoaderUpgradeab1e11111111111111111111111");
const PROGRAM_METADATA = new PublicKey("ProgM6JCCvbYkfKqJYHePx4xxSUSqJp7rh8Lyv7nk7S");
const RPC_URL = process.env.ANCHOR_PROVIDER_URL ?? "https://api.devnet.solana.com";
const DAY = 86_400n;
const wait = (milliseconds: number) => new Promise((resolve) => setTimeout(resolve, milliseconds));
const integer = (value: unknown) => BigInt((value as {toString(): string}).toString());
const key = (value: unknown) => value as PublicKey;
const sha256 = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");

async function retry<T>(label: string, operation: () => Promise<T | null>): Promise<T> {
  let lastError: unknown;
  for (let attempt = 1; attempt <= 8; attempt += 1) {
    try {
      const value = await operation();
      if (value !== null) return value;
    } catch (error) {
      lastError = error;
    }
    await wait(1_000);
  }
  throw new Error(`${label} failed after bounded retries: ${lastError instanceof Error ? lastError.message : "empty response"}`);
}

function requireEqual(actual: unknown, expected: unknown, label: string) {
  if (String(actual) !== String(expected)) throw new Error(`${label}: expected ${expected}, got ${actual}`);
}

function requireTransactionAccounts(
  transaction: {transaction: {message: {staticAccountKeys: PublicKey[]}}},
  expected: PublicKey[],
  label: string,
) {
  const keys = new Set(transaction.transaction.message.staticAccountKeys.map((account) => account.toBase58()));
  for (const account of expected) {
    if (!keys.has(account.toBase58())) throw new Error(`${label} does not name ${account.toBase58()}`);
  }
}

function tokenAccount(data: Buffer, expectedMint: PublicKey, expectedOwner: PublicKey) {
  if (data.length !== TOKEN_ACCOUNT_SIZE) throw new Error("classic SPL token account has the wrong size");
  requireEqual(new PublicKey(data.subarray(0, 32)), expectedMint, "token mint");
  requireEqual(new PublicKey(data.subarray(32, 64)), expectedOwner, "token owner");
  return data.readBigUInt64LE(64);
}

async function main() {
  const connection = new Connection(RPC_URL, "finalized");
  requireEqual(await retry("devnet genesis", () => connection.getGenesisHash()), DEVNET_GENESIS, "cluster genesis");

  const manifest = JSON.parse(readFileSync(join(ROOT, "deployments", "devnet.json"), "utf8"));
  const build = JSON.parse(readFileSync(join(ROOT, "deployments", "build.json"), "utf8"));
  const release = JSON.parse(readFileSync(join(ROOT, "release-build.json"), "utf8"));
  const idlBytes = readFileSync(join(ROOT, "..", "..", "frontend", "src", "config", "curator-vault.idl.json"));
  const idl = JSON.parse(idlBytes.toString("utf8")) as Idl;
  const elf = readFileSync(join(ROOT, release.canonicalArtifact));
  const programId = new PublicKey(manifest.programId);
  const deployer = new PublicKey(manifest.deployer);
  const mint = new PublicKey(manifest.mint);
  const configAddress = new PublicKey(manifest.config);
  const positionAddress = new PublicKey(manifest.curatorPosition);
  const vaultAddress = new PublicKey(manifest.vaultAta);
  const couponAddress = new PublicKey(manifest.couponAta);
  const curator = new PublicKey(manifest.curator);
  const curatorAta = new PublicKey(manifest.curatorAta);
  const treasuryAta = new PublicKey(manifest.treasuryAta);
  const metadataAddress = new PublicKey(manifest.idlMetadata.address);

  requireEqual(build.schemaVersion, 2, "build receipt schema");
  requireEqual(build.programId, programId, "build program");
  requireEqual(release.programId, programId, "release program");
  requireEqual(build.elfSha256, sha256(elf), "canonical ELF hash");
  requireEqual(build.elfBytes, elf.length, "canonical ELF size");
  requireEqual(build.idlSha256, sha256(idlBytes), "committed IDL hash");
  requireEqual(build.idlBytes, idlBytes.length, "committed IDL size");
  requireEqual(build.releaseBuilder?.solanaVerify, release.solanaVerifyVersion, "solana-verify pin");
  requireEqual(build.releaseBuilder?.solanaCli, release.solanaCliVersion, "release Solana pin");
  requireEqual(build.releaseBuilder?.sbfArch, release.sbfArch, "release SBF architecture");
  requireEqual(build.releaseBuilder?.platformTools, release.platformTools, "release platform tools");
  requireEqual(build.releaseBuilder?.baseImage, release.baseImage, "release image pin");
  requireEqual(idl.address, programId, "IDL program");
  requireEqual(PublicKey.findProgramAddressSync([Buffer.from("config")], programId)[0], configAddress, "config PDA");
  requireEqual(PublicKey.findProgramAddressSync([Buffer.from("vault")], programId)[0], vaultAddress, "vault PDA");
  requireEqual(PublicKey.findProgramAddressSync([Buffer.from("coupon")], programId)[0], couponAddress, "coupon PDA");
  requireEqual(PublicKey.findProgramAddressSync([Buffer.from("position"), curator.toBuffer()], programId)[0], positionAddress, "position PDA");
  requireEqual(associatedTokenAddress(mint, curator), curatorAta, "curator ATA");
  const metadataSeed = Buffer.alloc(16);
  metadataSeed.write("idl", "utf8");
  requireEqual(
    PublicKey.findProgramAddressSync([programId.toBuffer(), metadataSeed], PROGRAM_METADATA)[0],
    metadataAddress,
    "canonical IDL metadata PDA",
  );

  const addresses = [programId, configAddress, positionAddress, vaultAddress, couponAddress, mint, curatorAta, treasuryAta];
  const infos = await retry("devnet account set", () => connection.getMultipleAccountsInfo(addresses, "finalized"));
  if (infos.some((info) => info === null)) throw new Error("one or more deployment accounts are absent");
  const [programInfo, configInfo, positionInfo, vaultInfo, couponInfo, mintInfo, curatorAtaInfo, treasuryAtaInfo] = infos as NonNullable<(typeof infos)[number]>[];
  if (!programInfo.executable || !programInfo.owner.equals(UPGRADEABLE_LOADER)) throw new Error("program account is not upgradeable-loader executable");
  requireEqual(configInfo.owner, programId, "config owner");
  requireEqual(positionInfo.owner, programId, "position owner");
  requireEqual(configInfo.data.length, 650, "Config allocation");
  requireEqual(positionInfo.data.length, 260, "Position allocation");
  if (!vaultInfo.owner.equals(TOKEN_PROGRAM_ID) || !couponInfo.owner.equals(TOKEN_PROGRAM_ID) || !mintInfo.owner.equals(TOKEN_PROGRAM_ID)) {
    throw new Error("mint or pool is not owned by the classic SPL Token program");
  }
  if (mintInfo.data.length !== 82 || mintInfo.data[44] !== 6 || mintInfo.data[45] !== 1) {
    throw new Error("rehearsal mint is not an initialized six-decimal classic SPL mint");
  }

  const programDataAddress = new PublicKey(programInfo.data.subarray(4, 36));
  requireEqual(programDataAddress, manifest.programData, "programdata address");
  const programData = await retry("programdata", () => connection.getAccountInfo(programDataAddress, "finalized"));
  if (!programData.owner.equals(UPGRADEABLE_LOADER) || programData.data[12] !== 1) {
    throw new Error("programdata is not upgradeable or has no authority");
  }
  requireEqual(programData.data.readBigUInt64LE(4), manifest.canonicalBuildActivatedAtSlot, "canonical build activation slot");
  requireEqual(new PublicKey(programData.data.subarray(13, 45)), deployer, "upgrade authority");
  const deployedElf = programData.data.subarray(45);
  if (!elf.equals(deployedElf.subarray(0, elf.length)) || deployedElf.subarray(elf.length).some((byte) => byte !== 0)) {
    throw new Error("finalized program bytes differ from the clean local ELF");
  }

  const metadataInfo = await retry("canonical IDL metadata", () => connection.getAccountInfo(metadataAddress, "finalized"));
  if (!metadataInfo.owner.equals(PROGRAM_METADATA) || metadataInfo.executable) {
    throw new Error("canonical IDL account has the wrong owner or is executable");
  }
  // Program Metadata v0.9.3 stores a fixed 96-byte header followed by the direct payload.
  // Validate every format selector before decoding so a future layout cannot be mistaken for this one.
  requireEqual(metadataInfo.data[0], 2, "IDL metadata discriminator");
  requireEqual(new PublicKey(metadataInfo.data.subarray(1, 33)), programId, "IDL metadata program");
  if (metadataInfo.data.subarray(33, 65).some((byte) => byte !== 0)) {
    throw new Error("canonical IDL metadata unexpectedly names an additional authority");
  }
  requireEqual(metadataInfo.data[65], 1, "IDL metadata mutable flag");
  requireEqual(metadataInfo.data[66], 1, "IDL metadata canonical flag");
  requireEqual(metadataInfo.data.subarray(67, 83).toString("utf8").replaceAll("\0", ""), "idl", "IDL metadata seed");
  requireEqual(metadataInfo.data[83], 1, "IDL metadata UTF-8 encoding");
  requireEqual(metadataInfo.data[84], 2, "IDL metadata zlib compression");
  requireEqual(metadataInfo.data[85], 1, "IDL metadata JSON format");
  requireEqual(metadataInfo.data[86], 0, "IDL metadata direct data source");
  requireEqual(metadataInfo.data.readUInt32LE(87), metadataInfo.data.length - 96, "IDL metadata payload length");
  const publishedIdl = inflateSync(metadataInfo.data.subarray(96));
  if (!publishedIdl.equals(idlBytes)) throw new Error("published canonical IDL differs from the clean local IDL");

  const coder = new BorshAccountsCoder(idl);
  const config = coder.decode("Config", configInfo.data) as Record<string, unknown>;
  const position = coder.decode("Position", positionInfo.data) as Record<string, unknown>;
  for (const [label, actual, expected] of [
    ["config version", config.version, 1],
    ["position version", position.version, 1],
    ["admin", key(config.admin), deployer],
    ["allowlist authority", key(config.allowlist_authority), deployer],
    ["treasury authority", key(config.treasury_authority), deployer],
    ["emergency authority", key(config.emergency_authority), deployer],
    ["mint", key(config.usdc_mint), mint],
    ["vault account", key(config.vault_ata), vaultAddress],
    ["coupon account", key(config.coupon_ata), couponAddress],
    ["treasury account", key(config.treasury_ata), treasuryAta],
    ["position owner", key(position.owner), curator],
  ] as const) requireEqual(actual, expected, label);
  requireEqual(key(config.pending_admin), PublicKey.default, "pending admin");
  requireEqual(config.paused, false, "pause state");
  requireEqual(config.principal_at_risk, true, "at-risk policy");
  requireEqual(config.day_count, 0, "day-count convention");
  requireEqual(integer(config.lock_seconds), 90n * DAY, "lock term");
  requireEqual(integer(config.notice_seconds), 90n * DAY, "notice term");
  requireEqual(integer(position.lock_seconds), 90n * DAY, "position lock snapshot");
  requireEqual(integer(position.notice_seconds), 90n * DAY, "position notice snapshot");
  requireEqual(config.rate_epoch_count, 1, "rate epoch count");
  requireEqual((config.rate_epochs as Array<{bps: number}>)[0].bps, 1_250, "initial rate");
  requireEqual(config.positions, 1, "position count");
  requireEqual(position.allowlisted, true, "allowlist state");
  requireEqual(position.payout_halted, false, "payout halt");
  requireEqual(integer(position.notice_requested_at), 0n, "notice cleared");
  requireEqual(integer(position.withdrawal_eligible_at), 0n, "eligibility cleared");
  requireEqual(integer(position.principal), 9_900_000_000n, "position principal");
  requireEqual(integer(position.drawn), 0n, "position draw");
  requireEqual(integer(position.losses_recorded), 100_000_000n, "recorded loss");
  requireEqual(integer(config.total_principal), 9_900_000_000n, "total principal");
  requireEqual(integer(config.drawn), 0n, "total draw");
  requireEqual(integer(config.coupon_funded), 500_000_000n, "coupon funding");
  requireEqual(integer(config.coupon_paid), 0n, "coupon paid");
  requireEqual(integer(config.coupon_owed_total), integer(position.coupon_owed), "coupon aggregate");
  requireEqual(integer(position.coupon_payable), 0n, "coupon payable before boundary");

  const vaultBalance = tokenAccount(vaultInfo.data, mint, configAddress);
  const couponBalance = tokenAccount(couponInfo.data, mint, configAddress);
  tokenAccount(curatorAtaInfo.data, mint, curator);
  tokenAccount(treasuryAtaInfo.data, mint, deployer);
  requireEqual(vaultBalance + integer(config.drawn), integer(config.total_principal), "principal conservation");
  requireEqual(couponBalance, integer(config.coupon_funded) - integer(config.coupon_paid), "coupon conservation");

  const signatures = [...new Set([
    ...(Object.values(manifest.signatures) as string[]),
    manifest.idlMetadata.replacedPartialBufferCloseSignature,
    ...(manifest.idlMetadata.signatures as string[]),
  ])];
  const statuses = await retry("signature statuses", () =>
    connection.getSignatureStatuses(signatures, {searchTransactionHistory: true}));
  if (statuses.value.length !== signatures.length || statuses.value.some((status) => !status || status.err || status.confirmationStatus !== "finalized")) {
    throw new Error("one or more deployment/rehearsal signatures are not finalized and successful");
  }
  const deployment = await retry("deployment transaction", () =>
    connection.getTransaction(manifest.signatures.deployProgram, {commitment: "finalized", maxSupportedTransactionVersion: 0}));
  requireEqual(deployment.slot, manifest.deployedAtSlot, "deployment slot");
  requireTransactionAccounts(
    deployment,
    [programId, programDataAddress, deployer, UPGRADEABLE_LOADER],
    "deployment transaction",
  );
  const activation = await retry("canonical build activation transaction", () =>
    connection.getTransaction(manifest.signatures.canonicalBuildActivation, {commitment: "finalized", maxSupportedTransactionVersion: 0}));
  requireEqual(activation.slot, manifest.canonicalBuildActivatedAtSlot, "canonical build activation transaction slot");
  requireTransactionAccounts(
    activation,
    [programId, programDataAddress, deployer, UPGRADEABLE_LOADER],
    "canonical build activation transaction",
  );

  const checkedAtSlot = await retry("verification slot", () => connection.getSlot("finalized"));
  const receipt = {
    schemaVersion: 2,
    cluster: "devnet",
    programId: programId.toBase58(),
    programData: programDataAddress.toBase58(),
    checkedAt: new Date().toISOString(),
    checkedAtSlot,
    build,
    canonicalBuildActivation: {
      signature: manifest.signatures.canonicalBuildActivation,
      slot: manifest.canonicalBuildActivatedAtSlot,
    },
    accounts: {
      config: configAddress.toBase58(),
      configBytes: configInfo.data.length,
      position: positionAddress.toBase58(),
      positionBytes: positionInfo.data.length,
      vault: vaultAddress.toBase58(),
      coupon: couponAddress.toBase58(),
      idlMetadata: metadataAddress.toBase58(),
      idlMetadataBytes: metadataInfo.data.length,
    },
    state: {
      totalPrincipal: integer(config.total_principal).toString(),
      drawn: integer(config.drawn).toString(),
      couponFunded: integer(config.coupon_funded).toString(),
      couponPaid: integer(config.coupon_paid).toString(),
      couponOwed: integer(config.coupon_owed_total).toString(),
      lossesRecorded: integer(position.losses_recorded).toString(),
      vaultBalance: vaultBalance.toString(),
      couponBalance: couponBalance.toString(),
    },
    finalizedSignatures: signatures.length,
    idlPublication: {
      tool: manifest.idlMetadata.tool,
      publishedAtSlot: manifest.idlMetadata.publishedAtSlot,
      exactIdlSha256: sha256(publishedIdl),
    },
  };
  writeFileSync(join(ROOT, "deployments", "devnet-verification.json"), `${JSON.stringify(receipt, null, 2)}\n`);
  process.stdout.write(`Verified ${signatures.length} finalized signatures and exact deployed bytes at slot ${checkedAtSlot}.\n`);
}

main().catch((error) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`${message.replaceAll(RPC_URL, "[RPC endpoint]")}\n`);
  process.exit(1);
});
