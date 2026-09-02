/**
 * Contract ↔ frontend synchronization gate.
 *
 * Run after `forge build`: npm run test:sync
 *
 * This deliberately tests structure, not a mocked copy of contract state:
 *  - every function/event used by the frontend must exactly match the compiled ABI;
 *  - every public write must use the shared simulate/sign/receipt/invalidate flow;
 *  - every displayed on-chain dependency must either poll or refresh on events;
 *  - the app, transparency, yield, and points surfaces must keep their complete
 *    dependency sets wired.
 */
import {existsSync, readFileSync} from "node:fs";
import {
  ATTESTATION_ORACLE_ABI,
  BRIDGE_ABI,
  BRIDGE_HISTORY_ABI,
  COMPLIANCE_ABI,
  CONTROLLER_ABI,
  CURATOR_ABI,
  DEFAULT_HISTORY_ABI,
  ERC20_ABI,
  IMPAIRMENT_SOURCE_ABI,
  POINTS_ABI,
  QUEUE_ABI,
  REGISTRY_ABI,
  RESERVES_ABI,
  SGROVE_ABI,
  TEST_STABLE_ABI,
  VAULT_ABI,
  VAULT_HISTORY_ABI,
  WATERFALL_ABI,
  WATERFALL_HISTORY_ABI,
} from "./src/lib/abi.ts";

type AbiParameter = {
  type: string;
  components?: readonly AbiParameter[];
  indexed?: boolean;
};
type AbiItem = {
  type: string;
  name?: string;
  stateMutability?: string;
  anonymous?: boolean;
  inputs?: readonly AbiParameter[];
  outputs?: readonly AbiParameter[];
};

/**
 * Every check in this file compares the frontend against the compiled contract artifacts
 * in ../contracts/out and the deployment manifest beside them. The curated public
 * repository ships frontend/ without the contract tier, so there is nothing to compare
 * against and the gate is not applicable rather than failing.
 *
 * Exit cleanly and say so plainly. Reporting this as a pass would assert a comparison that
 * never happened, the precise failure this gate exists to prevent.
 */
if (!existsSync(new URL("../contracts/out/", import.meta.url))) {
  console.log(
    "SKIP contract↔frontend synchronization: ../contracts/out is not present in this\n" +
      "     checkout. In a full checkout run `cd contracts && forge build` first; this gate\n" +
      "     is inapplicable to the frontend-only public repository.",
  );
  process.exit(0);
}

let failures = 0;
let checks = 0;

function check(name: string, condition: boolean, detail?: string) {
  checks++;
  if (condition) {
    console.log(`ok   ${name}`);
    return;
  }
  failures++;
  console.log(`FAIL ${name}${detail ? `: ${detail}` : ""}`);
}

function source(path: string): string {
  return readFileSync(new URL(path, import.meta.url), "utf8");
}

function canonicalType(parameter: AbiParameter): string {
  if (!parameter.type.startsWith("tuple")) return parameter.type;
  const suffix = parameter.type.slice("tuple".length);
  return `(${(parameter.components ?? []).map(canonicalType).join(",")})${suffix}`;
}

function selector(item: AbiItem): string {
  return `${item.name ?? ""}(${(item.inputs ?? []).map(canonicalType).join(",")})`;
}

function outputs(item: AbiItem): string {
  return (item.outputs ?? []).map(canonicalType).join(",");
}

function artifactAbi(solidityFile: string, contractName: string): AbiItem[] {
  const raw = source(`../contracts/out/${solidityFile}.sol/${contractName}.json`);
  return JSON.parse(raw).abi as AbiItem[];
}

function checkAbi(label: string, frontendAbi: readonly AbiItem[], compiledAbi: AbiItem[]) {
  for (const item of frontendAbi) {
    if (item.type !== "function" && item.type !== "event") continue;
    const signature = selector(item);
    const compiled = compiledAbi.find(
      (candidate) => candidate.type === item.type && selector(candidate) === signature,
    );
    check(`${label}: ${item.type} ${signature} exists`, compiled !== undefined);
    if (!compiled) continue;
    if (item.type === "function") {
      check(
        `${label}: ${signature} output schema`,
        outputs(item) === outputs(compiled),
        `${outputs(item)} != ${outputs(compiled)}`,
      );
      check(
        `${label}: ${signature} mutability`,
        item.stateMutability === compiled.stateMutability,
        `${item.stateMutability} != ${compiled.stateMutability}`,
      );
    } else {
      const frontendIndexed = (item.inputs ?? []).map((input) => Boolean(input.indexed)).join(",");
      const compiledIndexed = (compiled.inputs ?? [])
        .map((input) => Boolean(input.indexed))
        .join(",");
      check(
        `${label}: ${signature} indexed fields`,
        frontendIndexed === compiledIndexed,
        `${frontendIndexed} != ${compiledIndexed}`,
      );
    }
  }
}

const usdfr = artifactAbi("USDfr", "USDfr");
const vault = artifactAbi("sUSDfr", "SUSDfr");
checkAbi("ERC20/USDfr", ERC20_ABI, usdfr);
checkAbi("ERC20/sUSDfr", ERC20_ABI, vault);
checkAbi("TestStable", TEST_STABLE_ABI, artifactAbi("MockERC20", "MockERC20"));
checkAbi(
  "MintRedeemController",
  CONTROLLER_ABI,
  artifactAbi("MintRedeemController", "MintRedeemController"),
);
checkAbi("sUSDfr", VAULT_ABI, vault);
checkAbi("sUSDfr history", VAULT_HISTORY_ABI, vault);
checkAbi(
  "AssessedImpairmentSource",
  IMPAIRMENT_SOURCE_ABI,
  artifactAbi("AssessedImpairmentSource", "AssessedImpairmentSource"),
);
checkAbi("RedemptionQueue", QUEUE_ABI, artifactAbi("RedemptionQueue", "RedemptionQueue"));
checkAbi(
  "ComplianceRegistry",
  COMPLIANCE_ABI,
  artifactAbi("ComplianceRegistry", "ComplianceRegistry"),
);
checkAbi("ReserveManager", RESERVES_ABI, artifactAbi("ReserveManager", "ReserveManager"));
checkAbi("ClaimBridge", BRIDGE_ABI, artifactAbi("ClaimBridge", "ClaimBridge"));
checkAbi("ClaimBridge history", BRIDGE_HISTORY_ABI, artifactAbi("ClaimBridge", "ClaimBridge"));
checkAbi("WaterfallEngine", WATERFALL_ABI, artifactAbi("WaterfallEngine", "WaterfallEngine"));
checkAbi(
  "WaterfallEngine history",
  WATERFALL_HISTORY_ABI,
  artifactAbi("WaterfallEngine", "WaterfallEngine"),
);
checkAbi(
  "DefaultManager history",
  DEFAULT_HISTORY_ABI,
  artifactAbi("DefaultManager", "DefaultManager"),
);
checkAbi(
  "AttestationOracle",
  ATTESTATION_ORACLE_ABI,
  artifactAbi("AttestationOracle", "AttestationOracle"),
);
checkAbi("CuratorModule", CURATOR_ABI, artifactAbi("CuratorModule", "CuratorModule"));
checkAbi("PointsModule", POINTS_ABI, artifactAbi("PointsModule", "PointsModule"));
checkAbi("SGrove", SGROVE_ABI, artifactAbi("SGrove", "SGrove"));
checkAbi(
  "CollateralRegistry",
  REGISTRY_ABI,
  artifactAbi("CollateralRegistry", "CollateralRegistry"),
);

const writeFlow = source("./src/components/app/useWriteFlow.ts");
const contractConfig = source("./src/config/contracts.ts");
const vaultFeeAbiConfig = source("./src/config/vaultFeeAbi.ts");
const stakeCard = source("./src/components/app/StakeCard.tsx");
const transparencyDashboard = source("./src/components/app/TransparencyDashboard.tsx");
const yieldPositionPanel = source("./src/components/app/YieldPositionPanel.tsx");
const sepoliaManifest = JSON.parse(
  source("../contracts/deployments/11155111.json"),
) as Record<string, string | number>;
const sepoliaAddressBindings = [
  ["USDfr", "usdfr"],
  ["sUSDfr", "vault"],
  ["ComplianceRegistry", "compliance"],
  ["USDC", "stable"],
  ["MintRedeemController", "controller"],
  ["ReserveManager", "reserves"],
  ["RedemptionQueue", "queue"],
  ["ClaimBridge", "bridge"],
  ["CollateralRegistry", "registry"],
  ["CuratorModule", "curator"],
  ["WaterfallEngine", "waterfall"],
  ["DefaultManager", "defaultManager"],
  ["AssessedImpairmentSource", "assessedImpairmentSource"],
  ["AttestationOracle", "oracle"],
  ["PointsModule", "points"],
  ["GROVE", "grove"],
  ["sGROVE", "sGrove"],
  ["GroveVotesAggregator", "votesAggregator"],
  ["Governor", "governor"],
  ["Timelock", "timelock"],
] as const;
for (const [frontendName, manifestKey] of sepoliaAddressBindings) {
  check(
    `Sepolia config: ${frontendName} matches canonical manifest`,
    contractConfig.includes(`${frontendName}: "${sepoliaManifest[manifestKey]}"`),
  );
}
const defaultDeploymentBlock = /deploymentBlock \?\? ([0-9_]+)/.exec(contractConfig)?.[1];
check(
  "Sepolia config: deployment block matches canonical manifest",
  Number(defaultDeploymentBlock?.replaceAll("_", "")) ===
    Number(sepoliaManifest.deployedAtBlock),
);
check(
  "Sepolia config: current vault fee ABI is the default",
  vaultFeeAbiConfig.includes('configuredVersion ?? "1"'),
);
const simulateAt = writeFlow.indexOf("simulateContract");
const submitAt = writeFlow.indexOf("await writeContractAsync");
const receiptAt = writeFlow.indexOf("waitForTransactionReceipt");
const invalidateAt = writeFlow.indexOf("await queryClient.invalidateQueries()");
const successAt = writeFlow.indexOf('setCurrentStatus({phase: "success"');
check(
  "write flow ordering: simulate → submit → receipt → invalidate → success",
  simulateAt >= 0 &&
    simulateAt < submitAt &&
    submitAt < receiptAt &&
    receiptAt < invalidateAt &&
    invalidateAt < successAt,
);
check(
  "write flow refreshes after uncertain receipt timeout",
  writeFlow.includes("void queryClient.invalidateQueries()"),
);
check(
  "write flow binds submission to configured chain",
  writeFlow.includes("chainId: EXPECTED_CHAIN.id"),
);
check(
  "write flow reports the mined replacement hash and rejects cancel/different-call replacement",
  writeFlow.includes("onReplaced: ({reason})") &&
    writeFlow.includes("hash: minedHash") &&
    writeFlow.includes('replacement.reason === "cancelled"') &&
    writeFlow.includes('replacement.reason === "replaced"'),
);
check(
  "write flow suppresses stale results after an account switch",
  writeFlow.includes("flowGeneration.current") &&
    writeFlow.includes("getConnection(config).address") &&
    writeFlow.includes("if (!isCurrentFlow()) return;"),
);
check(
  "vault fee selectors are version-gated and explicit addresses require explicit versions",
  contractConfig.includes("NEXT_PUBLIC_SUSDFR_FEE_ABI_VERSION") &&
    contractConfig.includes("SUPPORTS_VAULT_FEE_ACCOUNTING") &&
    vaultFeeAbiConfig.includes("required whenever NEXT_PUBLIC_SUSDFR_ADDRESS is set") &&
    vaultFeeAbiConfig.includes("known legacy sUSDfr address"),
);
for (const [label, body] of [
  ["StakeCard", stakeCard],
  ["TransparencyDashboard", transparencyDashboard],
  ["YieldPositionPanel", yieldPositionPanel],
] as const) {
  check(
    `${label}: ADR-0031 reads are disabled for the legacy deployment`,
    body.includes("SUPPORTS_VAULT_FEE_ACCOUNTING") &&
      body.includes("enabled: SUPPORTS_VAULT_FEE_ACCOUNTING"),
  );
}

const publicWriteSurfaces: Array<[string, string, string[]]> = [
  [
    "MintCard",
    "./src/components/app/MintCard.tsx",
    ['functionName: "approve"', 'functionName: "mint"'],
  ],
  [
    "StakeCard",
    "./src/components/app/StakeCard.tsx",
    ['functionName: "approve"', 'functionName: "deposit"'],
  ],
  [
    "RedeemCard",
    "./src/components/app/RedeemCard.tsx",
    [
      'functionName: "redeem"',
      'functionName: "approve"',
      'functionName: "requestRedeem"',
      'functionName: "claim"',
    ],
  ],
];
for (const [label, path, functions] of publicWriteSurfaces) {
  const body = source(path);
  check(`${label}: centralized write flow`, body.includes("useWriteFlow"));
  for (const functionName of functions) {
    check(`${label}: ${functionName}`, body.includes(functionName));
  }
}

const componentFiles = [
  "./src/components/app/AppSurface.tsx",
  "./src/components/app/MintCard.tsx",
  "./src/components/app/StakeCard.tsx",
  "./src/components/app/RedeemCard.tsx",
  "./src/components/app/PointsDashboard.tsx",
  "./src/components/app/TransparencyDashboard.tsx",
  "./src/components/app/YieldPositionPanel.tsx",
  "./src/components/app/useBookEconomics.ts",
  "./src/components/app/useCollateralValue.ts",
];
for (const path of componentFiles) {
  const body = source(path);
  if (path.endsWith("useWriteFlow.ts")) continue;
  check(
    `${path}: no direct wallet submission bypass`,
    !body.includes("writeContractAsync") && !body.includes("simulateContract"),
  );
}

const readSurfaces: Array<[string, string, string[], string]> = [
  [
    "app KYC",
    "./src/components/app/AppSurface.tsx",
    ["isAllowed"],
    "refetchInterval: 30_000",
  ],
  [
    "mint state",
    "./src/components/app/MintCard.tsx",
    ["balanceOf", "allowance"],
    "refetchInterval: 30_000",
  ],
  [
    "stake state",
    "./src/components/app/StakeCard.tsx",
    [
      "balanceOf",
      "allowance",
      "currentExchangeRate",
      "previewDeposit",
      "previewRedeem",
      "impairmentSource",
      "pendingSeniorImpairment",
      "performanceFeeBps",
      "highWaterMark",
      "feeExchangeRate",
      "maxPerformanceFeeBps",
      "managementFeeBps",
      "maxManagementFeeBps",
    ],
    "refetchInterval: 30_000",
  ],
  [
    "redeem and queue state",
    "./src/components/app/RedeemCard.tsx",
    [
      "balanceOf",
      "allowance",
      "epochEndsAt",
      "isSettling",
      "totalRequests",
      "redeemCooldown",
      "previewRedeem",
      "convertToAssets",
      "request",
    ],
    "useWatchContractEvent",
  ],
  [
    "transparency headline",
    "./src/components/app/TransparencyDashboard.tsx",
    [
      "totalSupply",
      "totalBackingValue",
      "idleReserve",
      "deployedPrincipal",
      "totalAssets",
      "currentExchangeRate",
      "totalBookExposure",
      "totalOriginated",
      "coverageCapacity",
      "coverageReserve",
      "currentEpoch",
      "epochEndsAt",
      "totalQueuedShares",
      "availableLiquidity",
      "protocolFeeBps",
      "feeRecipient",
      "poolBalance",
      "performanceFeeBps",
      "maxPerformanceFeeBps",
      "managementFeeBps",
      "maxManagementFeeBps",
      "managementFeeYear",
      "highWaterMark",
      "feeExchangeRate",
      "lastFeeAccrual",
    ],
    "refetchInterval: 60_000",
  ],
  [
    "book economics",
    "./src/components/app/useBookEconomics.ts",
    ["totalOriginated", "facility", "deployedTo", "protocolFeeBps"],
    "refetchInterval: 60_000",
  ],
  [
    "collateral valuation",
    "./src/components/app/useCollateralValue.ts",
    ["facility", "deployedTo", "latestValuation", "classParams"],
    "refetchInterval: 60_000",
  ],
  [
    "yield position",
    "./src/components/app/YieldPositionPanel.tsx",
    [
      "totalAssets",
      "totalSupply",
      "unvestedYield",
      "balanceOf",
      "previewRedeem",
      "performanceFeeBps",
      "maxPerformanceFeeBps",
      "managementFeeBps",
      "maxManagementFeeBps",
    ],
    "refetchInterval: 60_000",
  ],
  [
    "points",
    "./src/components/app/PointsDashboard.tsx",
    [
      "pointsOfWallet",
      "pointsBreakdown",
      "trackedBalances",
      "ratePerUnitDay",
      "usdfrMultiplierBps",
      "curatorMultiplierBps",
      "rateEpochCount",
      "curatorTracked",
      "curatorPointsInClass",
      "curatorFreezeStatus",
    ],
    "refetchInterval: 30_000",
  ],
];

for (const [label, path, dependencies, refreshEvidence] of readSurfaces) {
  const body = source(path);
  for (const dependency of dependencies) {
    check(`${label}: reads ${dependency}`, body.includes(`"${dependency}"`));
  }
  check(`${label}: external-state refresh policy`, body.includes(refreshEvidence));
}

const transparency = source("./src/components/app/TransparencyDashboard.tsx");
for (const historyEvent of [
  "Originated",
  "Funded",
  "OriginationFeeCharged",
  "Distributed",
  "PerformanceFeeAccrued",
  "ManagementFeeAccrued",
  "LossRealized",
]) {
  check(
    `transparency history: ${historyEvent}`,
    transparency.includes(`eventName: "${historyEvent}"`),
  );
}
check(
  "transparency history is block-triggered",
  transparency.includes("blockNumber") && transparency.includes("useEffect"),
);

if (failures > 0) {
  console.error(`\n${failures}/${checks} contract↔frontend synchronization checks failed.`);
  process.exit(1);
}
console.log(`\n${checks}/${checks} contract↔frontend synchronization checks passed.`);
