#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import {createHash} from "node:crypto";
import {createRequire} from "node:module";
import {fileURLToPath} from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const frontendDir = path.join(here, "..", "frontend");
const requireFromFrontend = createRequire(path.join(frontendDir, "package.json"));
const {loadEnvConfig} = requireFromFrontend("@next/env");
// This script runs before Next.js. Load the same .env* files Next will consume so
// a mainnet profile in `.env.local` cannot make this gate mistakenly take the
// non-mainnet no-op branch.
loadEnvConfig(frontendDir);
const args = process.argv.slice(2);
const verifyBuildEnv = args.includes("--verify-build-env");
const manifestArgument = args.find((arg) => arg !== "--verify-build-env");
const configuredBuildChainId = process.env.NEXT_PUBLIC_CHAIN_ID;
if (verifyBuildEnv && !configuredBuildChainId) {
  throw new Error(
    "NEXT_PUBLIC_CHAIN_ID is required for every frontend build; no network profile is selected implicitly",
  );
}
const buildChainId = Number(configuredBuildChainId);
if (
  verifyBuildEnv &&
  (!Number.isSafeInteger(buildChainId) ||
    (buildChainId !== 1 && buildChainId !== 11155111 && buildChainId !== 31337))
) {
  throw new Error(
    "NEXT_PUBLIC_CHAIN_ID must be Ethereum (1), Sepolia (11155111), or the local-fork profile (31337)",
  );
}

// `npm run build` invokes this mode for every profile. Sepolia and the dedicated
// local-fork profile use committed addresses and therefore have no mainnet
// manifest to bind. Mainnet must proceed through the full check below.
if (verifyBuildEnv && buildChainId !== 1) {
  process.stdout.write("Frontend manifest gate: non-mainnet build; no production manifest required.\n");
  process.exit(0);
}

const manifestPath = path.resolve(
  manifestArgument ??
    process.env.MAINNET_FRONTEND_MANIFEST ??
    path.join(here, "..", "contracts", "deployments", "1.json"),
);
if (!fs.existsSync(manifestPath)) {
  throw new Error(`Deployment manifest not found: ${manifestPath}`);
}

const manifestBytes = fs.readFileSync(manifestPath);
const deployment = JSON.parse(manifestBytes.toString("utf8"));
const mainnet = Number(deployment.chainId) === 1;

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const ZERO_BYTES32 = `0x${"0".repeat(64)}`;
const ZERO_SHA256 = "0".repeat(64);
const isAddress = (value) => /^0x[0-9a-fA-F]{40}$/.test(String(value ?? ""));
const isNonZeroAddress = (value) =>
  isAddress(value) && String(value).toLowerCase() !== ZERO_ADDRESS;
const isBytes32 = (value) =>
  /^0x[0-9a-fA-F]{64}$/.test(String(value ?? "")) &&
  String(value).toLowerCase() !== ZERO_BYTES32;

function requireMainnetRpcUrl(value) {
  let parsed;
  try {
    parsed = new URL(String(value));
  } catch {
    throw new Error("NEXT_PUBLIC_RPC_URL must be a valid HTTPS URL");
  }
  if (parsed.protocol !== "https:") {
    throw new Error("NEXT_PUBLIC_RPC_URL must use HTTPS for a mainnet build");
  }
  if (parsed.username || parsed.password || parsed.hash) {
    throw new Error("NEXT_PUBLIC_RPC_URL must not contain URL credentials or a fragment");
  }
  const hostname = parsed.hostname.toLowerCase();
  if (
    hostname === "localhost" ||
    hostname.startsWith("127.") ||
    hostname === "0.0.0.0" ||
    hostname === "::1" ||
    hostname === "[::1]" ||
    hostname.endsWith(".example") ||
    hostname === "example.com" ||
    hostname.endsWith(".example.com")
  ) {
    throw new Error("NEXT_PUBLIC_RPC_URL must be a real remote mainnet endpoint");
  }
  return parsed.toString();
}

let rpcRequestId = 0;
async function rpcCall(rpcUrl, method, params = []) {
  let response;
  const requestId = ++rpcRequestId;
  try {
    response = await fetch(rpcUrl, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: requestId,
        method,
        params,
      }),
      signal: AbortSignal.timeout(10_000),
    });
  } catch (error) {
    throw new Error(
      `Mainnet RPC ${method} request failed: ${error instanceof Error ? error.message : "unknown error"}`,
    );
  }
  if (!response.ok) {
    throw new Error(`Mainnet RPC ${method} returned HTTP ${response.status}`);
  }
  const payload = await response.json();
  if (
    typeof payload !== "object" ||
    payload === null ||
    payload.error ||
    payload.jsonrpc !== "2.0" ||
    payload.id !== requestId ||
    !("result" in payload)
  ) {
    throw new Error(`Mainnet RPC ${method} returned an invalid JSON-RPC response`);
  }
  return payload.result;
}

async function verifyMainnetRpc(rpcUrl, deployment, addressMappings) {
  const chainIdRaw = await rpcCall(rpcUrl, "eth_chainId");
  if (
    typeof chainIdRaw !== "string" ||
    !/^0x[0-9a-fA-F]+$/.test(chainIdRaw) ||
    BigInt(chainIdRaw) !== 1n
  ) {
    throw new Error("NEXT_PUBLIC_RPC_URL does not report Ethereum mainnet chain ID 1");
  }

  const blockNumberRaw = await rpcCall(rpcUrl, "eth_blockNumber");
  if (
    typeof blockNumberRaw !== "string" ||
    !/^0x[0-9a-fA-F]+$/.test(blockNumberRaw) ||
    BigInt(blockNumberRaw) < BigInt(deployment.deployedAtBlock)
  ) {
    throw new Error("NEXT_PUBLIC_RPC_URL has not reached the manifest deployment block");
  }

  // Limit concurrency so a correct but rate-limited release RPC is not rejected
  // merely because the frontend gate opened twenty simultaneous requests.
  for (let i = 0; i < addressMappings.length; i += 4) {
    const group = addressMappings.slice(i, i + 4);
    await Promise.all(
      group.map(async ([, key]) => {
        const code = await rpcCall(rpcUrl, "eth_getCode", [deployment[key], "latest"]);
        if (
          typeof code !== "string" ||
          !/^0x[0-9a-fA-F]*$/.test(code) ||
          /^0x0*$/i.test(code)
        ) {
          throw new Error(`NEXT_PUBLIC_RPC_URL has no deployed code at manifest .${key}`);
        }
      }),
    );
  }
}

if (mainnet) {
  if (deployment.production !== true || deployment.profile !== "mainnet-v1") {
    throw new Error("Refusing to export a mainnet frontend config from a non-production manifest");
  }
  const canonical = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48";
  if (String(deployment.stable).toLowerCase() !== canonical) {
    throw new Error("Mainnet manifest does not use canonical Ethereum USDC");
  }
  if (String(deployment.canonicalUSDC).toLowerCase() !== canonical) {
    throw new Error("Mainnet manifest does not pin canonical Ethereum USDC");
  }
  const receiptFields = [
    "mainnetConfigHash",
    "mainnetDeploymentScriptRuntimeHash",
    "mainnetArtifactSetHash",
    "mainnetPrincipalSetHash",
    "mainnetGasPolicyHash",
    "mainnetDeploymentHash",
    "mainnetApprovedDeploymentHash",
  ];
  for (const field of receiptFields) {
    if (!isBytes32(deployment[field])) {
      throw new Error(`Mainnet manifest is missing a non-zero .${field} receipt`);
    }
  }
  if (deployment.keepOpsAdmin !== false) {
    throw new Error("Mainnet manifest retains an ops administrator");
  }
  if (
    !Number.isSafeInteger(Number(deployment.mainnetExpectedDeployerNonce)) ||
    Number(deployment.mainnetExpectedDeployerNonce) < 0
  ) {
    throw new Error("Mainnet manifest has an invalid deployer nonce");
  }
  const gasPolicyFields = [
    "mainnetApprovedTotalGasLimit",
    "mainnetMaxFeePerGasWei",
    "mainnetPriorityFeePerGasWei",
    "mainnetMinDeployerEthWei",
  ];
  const gasPolicy = Object.fromEntries(
    gasPolicyFields.map((field) => {
      if (
        typeof deployment[field] !== "string" ||
        !/^(0|[1-9][0-9]*)$/.test(deployment[field])
      ) {
        throw new Error(`Mainnet manifest has an invalid .${field}`);
      }
      return [field, BigInt(deployment[field])];
    }),
  );
  if (gasPolicy.mainnetApprovedTotalGasLimit === 0n) {
    throw new Error("Mainnet manifest gas limit must be greater than zero");
  }
  if (gasPolicy.mainnetMaxFeePerGasWei === 0n) {
    throw new Error("Mainnet manifest max fee must be greater than zero");
  }
  if (gasPolicy.mainnetPriorityFeePerGasWei > gasPolicy.mainnetMaxFeePerGasWei) {
    throw new Error("Mainnet manifest priority fee exceeds its max fee");
  }
  const approvedMaximumGasCost =
    gasPolicy.mainnetApprovedTotalGasLimit * gasPolicy.mainnetMaxFeePerGasWei;
  if (gasPolicy.mainnetMinDeployerEthWei < approvedMaximumGasCost) {
    throw new Error("Mainnet manifest deployer funding is below its maximum gas cost");
  }

  const approvedDeploymentHash = process.env.MAINNET_APPROVED_DEPLOYMENT_HASH;
  if (!isBytes32(approvedDeploymentHash)) {
    throw new Error(
      "Set MAINNET_APPROVED_DEPLOYMENT_HASH to the independently approved deployment receipt",
    );
  }
  if (
    String(deployment.mainnetApprovedDeploymentHash).toLowerCase() !==
      approvedDeploymentHash.toLowerCase() ||
    String(deployment.mainnetDeploymentHash).toLowerCase() !==
      approvedDeploymentHash.toLowerCase()
  ) {
    throw new Error("Manifest deployment receipt differs from the independent approval");
  }

  const approvedManifestSha256 = process.env.MAINNET_APPROVED_MANIFEST_SHA256;
  if (
    !/^[0-9a-fA-F]{64}$/.test(String(approvedManifestSha256 ?? "")) ||
    String(approvedManifestSha256).toLowerCase() === ZERO_SHA256
  ) {
    throw new Error(
      "Set MAINNET_APPROVED_MANIFEST_SHA256 to the independently archived manifest checksum",
    );
  }
  const actualManifestSha256 = createHash("sha256").update(manifestBytes).digest("hex");
  if (actualManifestSha256.toLowerCase() !== approvedManifestSha256.toLowerCase()) {
    throw new Error("Production manifest checksum differs from the independent approval");
  }

  const {encodeAbiParameters, getContractAddress, keccak256, stringToHex} =
    await import(requireFromFrontend.resolve("viem"));
  const principalKeys = [
    "deployer",
    "opsAdmin",
    "frTreasury",
    "feeRecipient",
    "anchorCurator",
    "attester1",
    "attester2",
    "canonicalUSDC",
  ];
  for (const key of principalKeys) {
    if (!isNonZeroAddress(deployment[key])) {
      throw new Error(`Mainnet manifest is missing a non-zero .${key} principal`);
    }
  }
  const principalSetHash = keccak256(
    encodeAbiParameters(
      [
        {type: "string"},
        ...principalKeys.map(() => ({type: "address"})),
      ],
      [
        "FOREST_ROAD_MAINNET_V1_PRINCIPAL_SET",
        ...principalKeys.map((key) => deployment[key]),
      ],
    ),
  );
  if (principalSetHash.toLowerCase() !== String(deployment.mainnetPrincipalSetHash).toLowerCase()) {
    throw new Error("Mainnet principal-set receipt does not match the manifest principals");
  }

  const gasPolicyHash = keccak256(
    encodeAbiParameters(
      [
        {type: "string"},
        {type: "uint256"},
        {type: "uint256"},
        {type: "uint256"},
        {type: "uint256"},
      ],
      [
        "FOREST_ROAD_MAINNET_V1_GAS_POLICY",
        gasPolicy.mainnetApprovedTotalGasLimit,
        gasPolicy.mainnetMaxFeePerGasWei,
        gasPolicy.mainnetPriorityFeePerGasWei,
        gasPolicy.mainnetMinDeployerEthWei,
      ],
    ),
  );
  if (gasPolicyHash.toLowerCase() !== String(deployment.mainnetGasPolicyHash).toLowerCase()) {
    throw new Error("Mainnet gas-policy receipt does not match the manifest policy");
  }

  const deploymentHash = keccak256(
    encodeAbiParameters(
      [
        {type: "string"},
        {type: "uint256"},
        {type: "bytes32"},
        {type: "bytes32"},
        {type: "bytes32"},
        {type: "bytes32"},
        {type: "bytes32"},
        {type: "uint256"},
      ],
      [
        "FOREST_ROAD_MAINNET_V1_DEPLOYMENT",
        1n,
        keccak256(stringToHex("mainnet-v1")),
        deployment.mainnetConfigHash,
        deployment.mainnetArtifactSetHash,
        principalSetHash,
        gasPolicyHash,
        BigInt(deployment.mainnetExpectedDeployerNonce),
      ],
    ),
  );
  if (deploymentHash.toLowerCase() !== approvedDeploymentHash.toLowerCase()) {
    throw new Error("Mainnet deployment receipt does not recompute to the independent approval");
  }

  const proxyCreateKeys = [
    "timelock",
    "grove",
    "compliance",
    "usdfr",
    "reserves",
    "controller",
    "vault",
    "points",
    "registry",
    "oracle",
    "bridge",
    "curator",
    "waterfall",
    "defaultManager",
    "assessedImpairmentSource",
    "queue",
    "sGrove",
  ];
  let createNonce = BigInt(deployment.mainnetExpectedDeployerNonce);
  for (const key of proxyCreateKeys) {
    const expectedImplementation = getContractAddress({
      from: deployment.deployer,
      nonce: createNonce,
    });
    createNonce += 1n;
    const expectedProxy = getContractAddress({
      from: deployment.deployer,
      nonce: createNonce,
    });
    createNonce += 1n;
    if (
      !isNonZeroAddress(deployment[`impl_${key}`]) ||
      String(deployment[`impl_${key}`]).toLowerCase() !== expectedImplementation.toLowerCase()
    ) {
      throw new Error(`Manifest .impl_${key} does not match the approved CREATE sequence`);
    }
    if (
      !isNonZeroAddress(deployment[key]) ||
      String(deployment[key]).toLowerCase() !== expectedProxy.toLowerCase()
    ) {
      throw new Error(`Manifest .${key} does not match the approved CREATE sequence`);
    }
  }
  const expectedVotesAggregator = getContractAddress({
    from: deployment.deployer,
    nonce: createNonce,
  });
  createNonce += 1n;
  if (
    String(deployment.votesAggregator).toLowerCase() !==
    expectedVotesAggregator.toLowerCase()
  ) {
    throw new Error("Manifest .votesAggregator does not match the approved CREATE sequence");
  }
  const expectedGovernorImplementation = getContractAddress({
    from: deployment.deployer,
    nonce: createNonce,
  });
  createNonce += 1n;
  const expectedGovernor = getContractAddress({
    from: deployment.deployer,
    nonce: createNonce,
  });
  if (
    String(deployment.impl_governor).toLowerCase() !==
      expectedGovernorImplementation.toLowerCase() ||
    String(deployment.governor).toLowerCase() !== expectedGovernor.toLowerCase()
  ) {
    throw new Error("Manifest governor does not match the approved CREATE sequence");
  }
  createNonce += 1n;
  const expectedMtmExecutor = getContractAddress({
    from: deployment.deployer,
    nonce: createNonce,
  });
  if (
    !isNonZeroAddress(deployment.mtmExecutor) ||
    String(deployment.mtmExecutor).toLowerCase() !== expectedMtmExecutor.toLowerCase()
  ) {
    throw new Error("Manifest .mtmExecutor does not match the approved CREATE sequence");
  }
}

const mappings = [
  ["NEXT_PUBLIC_USDFR_ADDRESS", "usdfr"],
  ["NEXT_PUBLIC_SUSDFR_ADDRESS", "vault"],
  ["NEXT_PUBLIC_COMPLIANCE_REGISTRY_ADDRESS", "compliance"],
  ["NEXT_PUBLIC_USDC_ADDRESS", "stable"],
  ["NEXT_PUBLIC_MINT_REDEEM_CONTROLLER_ADDRESS", "controller"],
  ["NEXT_PUBLIC_RESERVE_MANAGER_ADDRESS", "reserves"],
  ["NEXT_PUBLIC_REDEMPTION_QUEUE_ADDRESS", "queue"],
  ["NEXT_PUBLIC_CLAIM_BRIDGE_ADDRESS", "bridge"],
  ["NEXT_PUBLIC_COLLATERAL_REGISTRY_ADDRESS", "registry"],
  ["NEXT_PUBLIC_CURATOR_MODULE_ADDRESS", "curator"],
  ["NEXT_PUBLIC_WATERFALL_ENGINE_ADDRESS", "waterfall"],
  ["NEXT_PUBLIC_DEFAULT_MANAGER_ADDRESS", "defaultManager"],
  ["NEXT_PUBLIC_ASSESSED_IMPAIRMENT_SOURCE_ADDRESS", "assessedImpairmentSource"],
  ["NEXT_PUBLIC_ATTESTATION_ORACLE_ADDRESS", "oracle"],
  ["NEXT_PUBLIC_POINTS_MODULE_ADDRESS", "points"],
  ["NEXT_PUBLIC_GROVE_ADDRESS", "grove"],
  ["NEXT_PUBLIC_SGROVE_ADDRESS", "sGrove"],
  ["NEXT_PUBLIC_GROVE_VOTES_AGGREGATOR_ADDRESS", "votesAggregator"],
  ["NEXT_PUBLIC_GOVERNOR_ADDRESS", "governor"],
  ["NEXT_PUBLIC_TIMELOCK_ADDRESS", "timelock"],
];

const lines = [
  `NEXT_PUBLIC_CHAIN_ID=${deployment.chainId}`,
  "NEXT_PUBLIC_RPC_URL=<PUBLIC_RPC_URL>",
  `NEXT_PUBLIC_PROTOCOL_DEPLOYMENT_BLOCK=${deployment.deployedAtBlock}`,
  "NEXT_PUBLIC_SUSDFR_FEE_ABI_VERSION=1",
];
if (!Number.isSafeInteger(Number(deployment.deployedAtBlock)) || Number(deployment.deployedAtBlock) <= 0) {
  throw new Error("Manifest is missing a positive deployment block");
}

const seenAddresses = new Map();
for (const [envName, key] of mappings) {
  const value = deployment[key];
  if (!isNonZeroAddress(value)) {
    throw new Error(`Manifest is missing a non-zero .${key} address`);
  }
  const normalized = String(value).toLowerCase();
  const firstKey = seenAddresses.get(normalized);
  if (firstKey) {
    throw new Error(`Manifest reuses ${value} for .${firstKey} and .${key}`);
  }
  seenAddresses.set(normalized, key);
  lines.push(`${envName}=${value}`);
}
if (mainnet) {
  lines.push(`NEXT_PUBLIC_MAINNET_DEPLOYMENT_HASH=${deployment.mainnetDeploymentHash}`);
  lines.push(
    `NEXT_PUBLIC_MAINNET_MANIFEST_SHA256=${createHash("sha256").update(manifestBytes).digest("hex")}`,
  );
}

if (verifyBuildEnv) {
  if (!mainnet) {
    throw new Error("A mainnet frontend build must use a chain-1 production manifest");
  }
  let mainnetRpcUrl;
  for (const line of lines) {
    const separator = line.indexOf("=");
    const name = line.slice(0, separator);
    const expected = line.slice(separator + 1);
    const actual = process.env[name];
    if (name === "NEXT_PUBLIC_RPC_URL") {
      if (!actual || actual.trim() === "" || actual === "<PUBLIC_RPC_URL>") {
        throw new Error("NEXT_PUBLIC_RPC_URL must be a real public mainnet RPC URL");
      }
      mainnetRpcUrl = requireMainnetRpcUrl(actual);
      continue;
    }
    const addressField = /^NEXT_PUBLIC_.*_ADDRESS$/.test(name);
    const matches =
      actual !== undefined &&
      (addressField
        ? actual.toLowerCase() === expected.toLowerCase()
        : actual === expected);
    if (!matches) {
      throw new Error(
        `${name} does not match the independently approved production manifest`,
      );
    }
  }
  // The roleless executor is not a frontend address, but it is part of the approved
  // deployment receipt and must exist at build time just like every exported module.
  await verifyMainnetRpc(mainnetRpcUrl, deployment, [...mappings, ["", "mtmExecutor"]]);
  process.stdout.write(
    `Frontend manifest gate: ${manifestPath} matches its independent approvals, every mainnet build variable, and live chain-1 contract code.\n`,
  );
} else {
  process.stdout.write(`${lines.join("\n")}\n`);
}
