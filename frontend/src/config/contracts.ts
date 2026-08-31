/**
 * Typed deployment configuration, the single source of truth for every public
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
export const PROTOCOL_DEPLOYMENT_BLOCK = BigInt(deploymentBlock ?? 11_489_206);
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
  USDfr: "0xd16224a766153F83F446935026E86d4170c21f76",
  sUSDfr: "0xdEf257Ee5b822a1eC5c97d130FD8C8212C2BE72d",
  ComplianceRegistry: "0xd7401aeC10A4f6A19Be27a3eF790F7305348C766",
  USDC: "0x570a53Bfcf6E5E5A2828a48DAc99D61c11Ca1C8D",
  MintRedeemController: "0xeEf3487685d0c11546be0c000149C72D4B663291",
  ReserveManager: "0x707c8017aC743604f2EB946712c4c605ee40fBf8",
  RedemptionQueue: "0x006B46825300f3eAEA6E6322BDB161617D334654",
  ClaimBridge: "0x6a090Fe2bC4BA03438BE4d8f06818C07825d99Fc",
  CollateralRegistry: "0x084E8899B5202d315177161D858c4A196aF954E4",
  CuratorModule: "0x81c81F0bbbaf6869062662D1347a9C05F52D59f2",
  WaterfallEngine: "0xF5F71bCeE5BAA75c5E3d457d2B9b9aa69Ce8113A",
  DefaultManager: "0xa3c983385DA8A3db432E22EA34Ae358A6D28B5e7",
  AssessedImpairmentSource: "0xE0c04120db843AB8AF49FB8bd8524A73D778fA13",
  AttestationOracle: "0xcbE2679034a3ae7163Ef3cf8e6A72C8f8588495B",
  PointsModule: "0x3660Bb79bE24A858905177B90CEE8Ba9A6B2631C",
  GROVE: "0x3ABfE8Ee839D99BDb4b863702AC264Aa04Cc5C65",
  sGROVE: "0x7Ee2FF890aC55D34aA27787b5Bd3AC501e30655f",
  GroveVotesAggregator: "0x76d7d431482cCe2b1720e7F40F06aE82b0917476",
  Governor: "0xED0c1870Fd0b52b62BDCA09F696b2B74cDe2BA1B",
  Timelock: "0xeaa4C93f48503E075D70371BCCd2ce1f5efe9e7e",
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
