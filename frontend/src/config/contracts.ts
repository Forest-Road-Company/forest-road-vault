/**
 * Typed deployment configuration — the single source of truth for every public
 * address, chain identifier, RPC endpoint, network label, and explorer link.
 *
 * Sepolia retains committed defaults for the public test deployment. Ethereum
 * mainnet has no address fallback: every deployed module and deployment block must
 * be supplied at build time, so a Vercel promotion cannot silently point a
 * mainnet-labelled UI at Sepolia or at a partial deployment.
 */

import type {Address} from "viem";
import {isLocalRpcUrl} from "@/lib/rpcAlignment";
import {resolveVaultFeeAbi} from "@/config/vaultFeeAbi";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const ZERO_BYTES32 = `0x${"0".repeat(64)}`;
const ZERO_SHA256 = "0".repeat(64);

const configuredChainId = process.env.NEXT_PUBLIC_CHAIN_ID;
if (!configuredChainId) {
  throw new Error(
    "NEXT_PUBLIC_CHAIN_ID is required; choose Ethereum (1), Sepolia (11155111), or a local Sepolia fork (31337).",
  );
}
export const CHAIN_ID = Number(configuredChainId);
export const IS_LOCAL_FORK = CHAIN_ID === 31337;
export const IS_MAINNET = CHAIN_ID === 1;
export const IS_TESTNET = !IS_MAINNET;
const vaultFeeAbi = resolveVaultFeeAbi({
  isMainnet: IS_MAINNET,
  configuredVersion: process.env.NEXT_PUBLIC_SUSDFR_FEE_ABI_VERSION,
  configuredVaultAddress: process.env.NEXT_PUBLIC_SUSDFR_ADDRESS,
});
export const VAULT_FEE_ABI_VERSION = vaultFeeAbi.version;
export const SUPPORTS_VAULT_FEE_ACCOUNTING = vaultFeeAbi.supportsFeeAccounting;
export const NETWORK_NAME = IS_MAINNET
  ? "Ethereum mainnet"
  : IS_LOCAL_FORK
    ? "local Sepolia fork"
    : "Sepolia testnet";
export const STABLE_SYMBOL = IS_MAINNET ? "USDC" : "tUSDC";
export const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL ?? "";
export const EXPLORER_BASE_URL = IS_LOCAL_FORK
  ? null
  : IS_MAINNET
    ? "https://etherscan.io"
    : "https://sepolia.etherscan.io";

if (CHAIN_ID !== 1 && CHAIN_ID !== 11155111 && CHAIN_ID !== 31337) {
  throw new Error(
    `Unsupported NEXT_PUBLIC_CHAIN_ID ${CHAIN_ID}; expected Ethereum (1), Sepolia (11155111), or a local Sepolia fork (31337).`,
  );
}
if (IS_LOCAL_FORK && (!RPC_URL || !isLocalRpcUrl(RPC_URL))) {
  throw new Error(
    "A local-fork build requires NEXT_PUBLIC_RPC_URL to be localhost or a loopback address.",
  );
}
if (!IS_LOCAL_FORK && isLocalRpcUrl(RPC_URL)) {
  throw new Error(
    "A loopback RPC must use the dedicated local-fork chain ID 31337, never Ethereum or Sepolia's live chain ID.",
  );
}
if (IS_MAINNET && !RPC_URL) {
  throw new Error("NEXT_PUBLIC_RPC_URL is required for a mainnet build.");
}

const deploymentBlock = process.env.NEXT_PUBLIC_PROTOCOL_DEPLOYMENT_BLOCK;
if (IS_MAINNET && !deploymentBlock) {
  throw new Error("NEXT_PUBLIC_PROTOCOL_DEPLOYMENT_BLOCK is required for a mainnet build.");
}
export const PROTOCOL_DEPLOYMENT_BLOCK = BigInt(deploymentBlock ?? 11_386_371);
if (IS_MAINNET && PROTOCOL_DEPLOYMENT_BLOCK <= 0n) {
  throw new Error("NEXT_PUBLIC_PROTOCOL_DEPLOYMENT_BLOCK must be a positive mainnet block.");
}

const deploymentHash = process.env.NEXT_PUBLIC_MAINNET_DEPLOYMENT_HASH;
if (
  IS_MAINNET &&
  (!deploymentHash ||
    !/^0x[0-9a-fA-F]{64}$/.test(deploymentHash) ||
    deploymentHash.toLowerCase() === ZERO_BYTES32)
) {
  throw new Error(
    "NEXT_PUBLIC_MAINNET_DEPLOYMENT_HASH must be the non-zero independently approved deployment receipt.",
  );
}
export const MAINNET_DEPLOYMENT_HASH = deploymentHash;

const manifestSha256 = process.env.NEXT_PUBLIC_MAINNET_MANIFEST_SHA256;
if (
  IS_MAINNET &&
  (!manifestSha256 ||
    !/^[0-9a-fA-F]{64}$/.test(manifestSha256) ||
    manifestSha256.toLowerCase() === ZERO_SHA256)
) {
  throw new Error(
    "NEXT_PUBLIC_MAINNET_MANIFEST_SHA256 must identify the independently approved production manifest.",
  );
}
export const MAINNET_MANIFEST_SHA256 = manifestSha256;

export type ContractName =
  | "USDfr"
  | "sUSDfr"
  | "ComplianceRegistry"
  | "USDC"
  | "MintRedeemController"
  | "ReserveManager"
  | "RedemptionQueue"
  | "ClaimBridge"
  | "CollateralRegistry"
  | "CuratorModule"
  | "WaterfallEngine"
  | "DefaultManager"
  | "AssessedImpairmentSource"
  | "AttestationOracle"
  | "PointsModule"
  | "GROVE"
  | "sGROVE"
  | "GroveVotesAggregator"
  | "Governor"
  | "Timelock";

function optionalAddress(name: string, value: string | undefined): Address | undefined {
  if (!value) return undefined;
  if (!/^0x[0-9a-fA-F]{40}$/.test(value)) {
    throw new Error(`${name} is not a valid EVM address.`);
  }
  if (value.toLowerCase() === ZERO_ADDRESS) {
    throw new Error(`${name} must not be the zero address.`);
  }
  return value as Address;
}

const SEPOLIA_CONTRACTS: Record<ContractName, Address> = {
  USDfr: "0x8485ECb761036e8eCfD9f67706D803028AFc0022",
  sUSDfr: "0x197bb3701e964bfb367449a6754C845Fc8f7d0F4",
  ComplianceRegistry: "0x164bB5F4Fc4Da517e9FD75875b71e8ecF33DD5C6",
  USDC: "0x64F05363e3AB6EE537dDb23Eca0AaF497a5aB681",
  MintRedeemController: "0x98481a8EE33E3E2F616bFE6123E6A6B514BCb97f",
  ReserveManager: "0x203c7fb0ed0CF28FeEC3eDa17d7D771E11DE0BAD",
  RedemptionQueue: "0x0159ec5274462AC77C1fD70f8482011B53b6C269",
  ClaimBridge: "0x9F4586B163c06696da05d35A79d3C885e2aA0814",
  CollateralRegistry: "0x70eB239415FB8B068e08E6EBc8b0c54aCE42CF8c",
  CuratorModule: "0xC23e46508371C95994A32A1F18FEbe34fA0D3b1A",
  WaterfallEngine: "0x1a208366e67bD3976Bd2D3918C85a11044989115",
  DefaultManager: "0xCB1429369fb7BF5f57d2C5076deafC00C06C8124",
  AssessedImpairmentSource: "0x8b45fCDB60EF02022a7560F8A72F16E4620bbaE4",
  AttestationOracle: "0x6022F732974e637345f7cE2336e13b354aAFEcff",
  PointsModule: "0x6C5a7A5dE7Beb7f64C664058a736c5f2bcB2Bf83",
  GROVE: "0x842Ecc2BA49499cc81bC65260A8D4a2246733DAC",
  sGROVE: "0xD2DF4509daAd87c6ac8B1a5FB7B1495038100EcF",
  GroveVotesAggregator: "0x14Ff5f360A7E7eC1fF20680C3Db5210100AB8140",
  Governor: "0x6734bF21eEc6f253920247a010240E0f4319C2B3",
  Timelock: "0x9B37a0940090d09Feb9B68280E9DAee39637cadF",
};

const ENV_CONTRACTS: Partial<Record<ContractName, Address>> = {
  USDfr: optionalAddress("NEXT_PUBLIC_USDFR_ADDRESS", process.env.NEXT_PUBLIC_USDFR_ADDRESS),
  sUSDfr: optionalAddress("NEXT_PUBLIC_SUSDFR_ADDRESS", process.env.NEXT_PUBLIC_SUSDFR_ADDRESS),
  ComplianceRegistry: optionalAddress(
    "NEXT_PUBLIC_COMPLIANCE_REGISTRY_ADDRESS",
    process.env.NEXT_PUBLIC_COMPLIANCE_REGISTRY_ADDRESS,
  ),
  USDC: optionalAddress("NEXT_PUBLIC_USDC_ADDRESS", process.env.NEXT_PUBLIC_USDC_ADDRESS),
  MintRedeemController: optionalAddress(
    "NEXT_PUBLIC_MINT_REDEEM_CONTROLLER_ADDRESS",
    process.env.NEXT_PUBLIC_MINT_REDEEM_CONTROLLER_ADDRESS,
  ),
  ReserveManager: optionalAddress(
    "NEXT_PUBLIC_RESERVE_MANAGER_ADDRESS",
    process.env.NEXT_PUBLIC_RESERVE_MANAGER_ADDRESS,
  ),
  RedemptionQueue: optionalAddress(
    "NEXT_PUBLIC_REDEMPTION_QUEUE_ADDRESS",
    process.env.NEXT_PUBLIC_REDEMPTION_QUEUE_ADDRESS,
  ),
  ClaimBridge: optionalAddress("NEXT_PUBLIC_CLAIM_BRIDGE_ADDRESS", process.env.NEXT_PUBLIC_CLAIM_BRIDGE_ADDRESS),
  CollateralRegistry: optionalAddress(
    "NEXT_PUBLIC_COLLATERAL_REGISTRY_ADDRESS",
    process.env.NEXT_PUBLIC_COLLATERAL_REGISTRY_ADDRESS,
  ),
  CuratorModule: optionalAddress(
    "NEXT_PUBLIC_CURATOR_MODULE_ADDRESS",
    process.env.NEXT_PUBLIC_CURATOR_MODULE_ADDRESS,
  ),
  WaterfallEngine: optionalAddress(
    "NEXT_PUBLIC_WATERFALL_ENGINE_ADDRESS",
    process.env.NEXT_PUBLIC_WATERFALL_ENGINE_ADDRESS,
  ),
  DefaultManager: optionalAddress(
    "NEXT_PUBLIC_DEFAULT_MANAGER_ADDRESS",
    process.env.NEXT_PUBLIC_DEFAULT_MANAGER_ADDRESS,
  ),
  AssessedImpairmentSource: optionalAddress(
    "NEXT_PUBLIC_ASSESSED_IMPAIRMENT_SOURCE_ADDRESS",
    process.env.NEXT_PUBLIC_ASSESSED_IMPAIRMENT_SOURCE_ADDRESS,
  ),
  AttestationOracle: optionalAddress(
    "NEXT_PUBLIC_ATTESTATION_ORACLE_ADDRESS",
    process.env.NEXT_PUBLIC_ATTESTATION_ORACLE_ADDRESS,
  ),
  PointsModule: optionalAddress("NEXT_PUBLIC_POINTS_MODULE_ADDRESS", process.env.NEXT_PUBLIC_POINTS_MODULE_ADDRESS),
  GROVE: optionalAddress("NEXT_PUBLIC_GROVE_ADDRESS", process.env.NEXT_PUBLIC_GROVE_ADDRESS),
  sGROVE: optionalAddress("NEXT_PUBLIC_SGROVE_ADDRESS", process.env.NEXT_PUBLIC_SGROVE_ADDRESS),
  GroveVotesAggregator: optionalAddress(
    "NEXT_PUBLIC_GROVE_VOTES_AGGREGATOR_ADDRESS",
    process.env.NEXT_PUBLIC_GROVE_VOTES_AGGREGATOR_ADDRESS,
  ),
  Governor: optionalAddress("NEXT_PUBLIC_GOVERNOR_ADDRESS", process.env.NEXT_PUBLIC_GOVERNOR_ADDRESS),
  Timelock: optionalAddress("NEXT_PUBLIC_TIMELOCK_ADDRESS", process.env.NEXT_PUBLIC_TIMELOCK_ADDRESS),
};

export const CONTRACTS: Partial<Record<ContractName, Address>> = IS_MAINNET
  ? {
      ...ENV_CONTRACTS,
      // Canonical Ethereum USDC is additionally pinned by DeployMainnet and
      // ValidateMainnet; the frontend refuses any alternative here too.
      USDC: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    }
  : {...SEPOLIA_CONTRACTS, ...Object.fromEntries(Object.entries(ENV_CONTRACTS).filter(([, value]) => value))};

if (IS_MAINNET) {
  const missing = (Object.keys(SEPOLIA_CONTRACTS) as ContractName[]).filter((name) => !CONTRACTS[name]);
  if (missing.length > 0) {
    throw new Error(`Mainnet contract configuration incomplete: ${missing.join(", ")}`);
  }
  const configured = (Object.keys(SEPOLIA_CONTRACTS) as ContractName[]).map((name) => [
    name,
    CONTRACTS[name]!.toLowerCase(),
  ] as const);
  const firstNameByAddress = new Map<string, ContractName>();
  for (const [name, address] of configured) {
    const firstName = firstNameByAddress.get(address);
    if (firstName) {
      throw new Error(`Mainnet contract configuration reuses ${address} for ${firstName} and ${name}.`);
    }
    firstNameByAddress.set(address, name);
  }
  const suppliedUSDC = ENV_CONTRACTS.USDC;
  if (
    suppliedUSDC &&
    suppliedUSDC.toLowerCase() !== "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48".toLowerCase()
  ) {
    throw new Error("NEXT_PUBLIC_USDC_ADDRESS must be canonical Ethereum USDC.");
  }
}

export function contractAddress(name: ContractName): Address | undefined {
  return CONTRACTS[name];
}

export function isProtocolLive(): boolean {
  return Boolean(CONTRACTS.USDfr && CONTRACTS.sUSDfr && CONTRACTS.MintRedeemController);
}
