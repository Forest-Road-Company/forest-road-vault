import {
  decodeEventLog,
  encodeAbiParameters,
  encodeFunctionData,
  keccak256,
  parseAbi,
  parseAbiParameters,
  pad,
  toHex,
  type Address,
  type Hex,
} from "viem";

import {
  LIQUIDITY_OPERATOR,
  PERMIT2,
  PERMIT2_DOMAIN,
  PERMIT2_TYPES,
  USDC,
  V4_POOL_MANAGER,
  V4_POSITION_MANAGER,
  amount0Delta,
  amount1Delta,
  sqrtPriceAtTick,
} from "./uniswapV4Liquidity";

/**
 * A fixed two-position USDC/sUSDfr operation:
 *
 * 1. initialize the new pool at 1.0061 USDC/sUSDfr and mint a small in-range
 *    position capped at 50 USDC; then
 * 2. mint a USDC-only wall from approximately 0.85 to 0.95 USDC/sUSDfr.
 *
 * The two positions together may spend at most 250,000 USDC.  Every token,
 * pool parameter, range, recipient and amount ceiling is fixed in this file.
 */
export const SUSDFR =
  "0xAF559d1D59B33ca4b950AB2091372Af8a773E234" as const;
export const SUSDFR_DECIMALS = 24;
export const SUSDFR_POOL_FEE = 375;
export const SUSDFR_TICK_SPACING = 4;
export const SUSDFR_INITIAL_SQRT_PRICE_X96 =
  78_987_616_558_622_955_295_902_997_146_760_324_135n;
export const SUSDFR_INITIAL_TICK = 414_425;

export const SEED_TICK_LOWER = 414_192; // 1.0298390169 USDC/sUSDfr
export const SEED_TICK_UPPER = 414_536; // 0.9950166739 USDC/sUSDfr
export const WALL_TICK_LOWER = 415_000; // 0.9499048432 USDC/sUSDfr
export const WALL_TICK_UPPER = 416_112; // 0.8499413730 USDC/sUSDfr
export const SEED_USDC_CAP = 50n * 10n ** 6n;
export const TOTAL_USDC_CAP = 250_000n * 10n ** 6n;
export const SUSDFR_LIQUIDITY_TX_GAS = 2_000_000n;

const Q96 = 1n << 96n;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const ACTIONS_MINT_AND_SETTLE_PAIR = "0x020d" as const;

export const SUSDFR_POOL_KEY = {
  currency0: USDC,
  currency1: SUSDFR,
  fee: SUSDFR_POOL_FEE,
  tickSpacing: SUSDFR_TICK_SPACING,
  hooks: ZERO_ADDRESS,
} as const;

const POOL_KEY_PARAMETERS = parseAbiParameters(
  "address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks",
);
const MINT_POSITION_PARAMETERS = parseAbiParameters(
  "(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) poolKey,int24 tickLower,int24 tickUpper,uint256 liquidity,uint128 amount0Max,uint128 amount1Max,address recipient,bytes hookData",
);
const SETTLE_PAIR_PARAMETERS = parseAbiParameters(
  "address currency0,address currency1",
);
const ACTION_PAYLOAD_PARAMETERS = parseAbiParameters(
  "bytes actions,bytes[] params",
);

export const SUSDFR_POOL_ID = keccak256(
  encodeAbiParameters(POOL_KEY_PARAMETERS, [
    USDC,
    SUSDFR,
    SUSDFR_POOL_FEE,
    SUSDFR_TICK_SPACING,
    ZERO_ADDRESS,
  ]),
);

export const SUSDFR_POSITION_MANAGER_ABI = parseAbi([
  "function multicall(bytes[] data) payable returns (bytes[] results)",
  "function initializePool((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key,uint160 sqrtPriceX96) payable returns (int24)",
  "function permitBatch(address owner,((address token,uint160 amount,uint48 expiration,uint48 nonce)[] details,address spender,uint256 sigDeadline) permitBatch,bytes signature)",
  "function modifyLiquidities(bytes unlockData,uint256 deadline) payable",
  "function getPositionLiquidity(uint256 tokenId) view returns (uint128 liquidity)",
  "function ownerOf(uint256 tokenId) view returns (address owner)",
]);

const POOL_MANAGER_EVENT_ABI = parseAbi([
  "event Initialize(bytes32 indexed id,address indexed currency0,address indexed currency1,uint24 fee,int24 tickSpacing,address hooks,uint160 sqrtPriceX96,int24 tick)",
  "event ModifyLiquidity(bytes32 indexed id,address indexed sender,int24 tickLower,int24 tickUpper,int256 liquidityDelta,bytes32 salt)",
]);

const TRANSFER_TOPIC = keccak256(toHex("Transfer(address,address,uint256)"));

export type SusdfrOperationKind = "seed" | "wall";

export type SusdfrLiquidityPlan = {
  kind: SusdfrOperationKind;
  tickLower: number;
  tickUpper: number;
  liquidity: bigint;
  expectedUsdc: bigint;
  expectedSusdfr: bigint;
  maxUsdc: bigint;
  maxSusdfr: bigint;
};

export type SusdfrPermitAllowance = {
  amount: bigint;
  expiration: number;
  nonce: number;
};

export type SusdfrPermitBatchMessage = {
  details: readonly [
    {token: typeof USDC; amount: bigint; expiration: number; nonce: number},
    {token: typeof SUSDFR; amount: bigint; expiration: number; nonce: number},
  ];
  spender: typeof V4_POSITION_MANAGER;
  sigDeadline: bigint;
};

export type SusdfrReceiptLog = {
  address: Address;
  topics: readonly [Hex, ...Hex[]];
  data: Hex;
};

export type SusdfrMintEvidence = {
  tokenId: bigint;
  usdcSpent: bigint;
  susdfrSpent: bigint;
  initialized: boolean;
};

function maximumLiquidityForAmount0(
  amount0Cap: bigint,
  sqrtPriceAX96: bigint,
  sqrtPriceBX96: bigint,
): bigint {
  if (amount0Cap <= 0n || sqrtPriceAX96 <= 0n || sqrtPriceAX96 >= sqrtPriceBX96) {
    throw new Error("Invalid amount0 liquidity bounds.");
  }
  let low = 0n;
  let high =
    (amount0Cap * sqrtPriceAX96 * sqrtPriceBX96) /
      (Q96 * (sqrtPriceBX96 - sqrtPriceAX96)) +
    2n;
  while (amount0Delta(high, sqrtPriceAX96, sqrtPriceBX96) <= amount0Cap) {
    high *= 2n;
  }
  while (low + 1n < high) {
    const midpoint = (low + high) / 2n;
    if (amount0Delta(midpoint, sqrtPriceAX96, sqrtPriceBX96) <= amount0Cap) {
      low = midpoint;
    } else {
      high = midpoint;
    }
  }
  if (low === 0n) throw new Error("The approved USDC cap is too small.");
  return low;
}

function assertPlan(plan: SusdfrLiquidityPlan): void {
  const seed = plan.kind === "seed";
  if (
    plan.liquidity <= 0n ||
    plan.tickLower !== (seed ? SEED_TICK_LOWER : WALL_TICK_LOWER) ||
    plan.tickUpper !== (seed ? SEED_TICK_UPPER : WALL_TICK_UPPER) ||
    plan.expectedUsdc <= 0n ||
    plan.expectedUsdc > plan.maxUsdc ||
    plan.expectedSusdfr > plan.maxSusdfr ||
    (seed && (plan.maxUsdc !== SEED_USDC_CAP || plan.expectedSusdfr <= 0n)) ||
    (!seed && (plan.maxSusdfr !== 0n || plan.expectedSusdfr !== 0n))
  ) {
    throw new Error("The liquidity plan is outside the approved operation.");
  }
}

export function buildSusdfrSeedPlan(poolSqrtPriceX96: bigint): SusdfrLiquidityPlan {
  if (poolSqrtPriceX96 !== 0n) {
    throw new Error("The approved USDC/sUSDfr pool is already initialized.");
  }
  const lower = sqrtPriceAtTick(SEED_TICK_LOWER);
  const upper = sqrtPriceAtTick(SEED_TICK_UPPER);
  if (
    SUSDFR_INITIAL_SQRT_PRICE_X96 <= lower ||
    SUSDFR_INITIAL_SQRT_PRICE_X96 >= upper
  ) {
    throw new Error("The approved initial price is outside the seed range.");
  }
  const liquidity = maximumLiquidityForAmount0(
    SEED_USDC_CAP,
    SUSDFR_INITIAL_SQRT_PRICE_X96,
    upper,
  );
  const plan: SusdfrLiquidityPlan = {
    kind: "seed",
    tickLower: SEED_TICK_LOWER,
    tickUpper: SEED_TICK_UPPER,
    liquidity,
    expectedUsdc: amount0Delta(
      liquidity,
      SUSDFR_INITIAL_SQRT_PRICE_X96,
      upper,
    ),
    expectedSusdfr: amount1Delta(
      liquidity,
      lower,
      SUSDFR_INITIAL_SQRT_PRICE_X96,
    ),
    maxUsdc: SEED_USDC_CAP,
    maxSusdfr: amount1Delta(liquidity, lower, upper),
  };
  assertPlan(plan);
  return plan;
}

export function buildSusdfrWallPlan(
  poolSqrtPriceX96: bigint,
  seed: Pick<SusdfrMintEvidence, "usdcSpent" | "susdfrSpent">,
): SusdfrLiquidityPlan {
  const lower = sqrtPriceAtTick(WALL_TICK_LOWER);
  const upper = sqrtPriceAtTick(WALL_TICK_UPPER);
  if (poolSqrtPriceX96 === 0n) throw new Error("The USDC/sUSDfr pool is not initialized.");
  if (poolSqrtPriceX96 > lower) {
    throw new Error("The pool price has entered the wall range; the USDC-only operation is locked.");
  }
  if (
    seed.usdcSpent <= 0n ||
    seed.usdcSpent > SEED_USDC_CAP ||
    seed.susdfrSpent <= 0n
  ) {
    throw new Error("The confirmed seed spend is outside the approved operation.");
  }
  const remainingUsdc = TOTAL_USDC_CAP - seed.usdcSpent;
  const liquidity = maximumLiquidityForAmount0(remainingUsdc, lower, upper);
  const plan: SusdfrLiquidityPlan = {
    kind: "wall",
    tickLower: WALL_TICK_LOWER,
    tickUpper: WALL_TICK_UPPER,
    liquidity,
    expectedUsdc: amount0Delta(liquidity, lower, upper),
    expectedSusdfr: 0n,
    maxUsdc: remainingUsdc,
    maxSusdfr: 0n,
  };
  assertPlan(plan);
  return plan;
}

export function buildSusdfrPermitBatchMessage(args: {
  plan: SusdfrLiquidityPlan;
  usdcNonce: number;
  susdfrNonce: number;
  timestamp: number;
}): SusdfrPermitBatchMessage {
  assertPlan(args.plan);
  if (!Number.isInteger(args.timestamp) || args.timestamp <= 0) {
    throw new Error("A valid chain timestamp is required.");
  }
  const expiration = args.timestamp + 60 * 60;
  return {
    details: [
      {
        token: USDC,
        amount: args.plan.maxUsdc,
        expiration,
        nonce: args.usdcNonce,
      },
      {
        token: SUSDFR,
        amount: args.plan.maxSusdfr,
        expiration,
        nonce: args.susdfrNonce,
      },
    ],
    spender: V4_POSITION_MANAGER,
    sigDeadline: BigInt(args.timestamp + 30 * 60),
  };
}

function encodeModifyLiquidityCall(args: {
  owner: Address;
  plan: SusdfrLiquidityPlan;
  deadline: bigint;
}): Hex {
  const mintParameters = encodeAbiParameters(MINT_POSITION_PARAMETERS, [
    SUSDFR_POOL_KEY,
    args.plan.tickLower,
    args.plan.tickUpper,
    args.plan.liquidity,
    args.plan.maxUsdc,
    args.plan.maxSusdfr,
    args.owner,
    "0x",
  ]);
  const settleParameters = encodeAbiParameters(SETTLE_PAIR_PARAMETERS, [
    USDC,
    SUSDFR,
  ]);
  const unlockData = encodeAbiParameters(ACTION_PAYLOAD_PARAMETERS, [
    ACTIONS_MINT_AND_SETTLE_PAIR,
    [mintParameters, settleParameters],
  ]);
  return encodeFunctionData({
    abi: SUSDFR_POSITION_MANAGER_ABI,
    functionName: "modifyLiquidities",
    args: [unlockData, args.deadline],
  });
}

export function encodeSusdfrLiquidityTransaction(args: {
  owner: Address;
  plan: SusdfrLiquidityPlan;
  permit: SusdfrPermitBatchMessage;
  signature: Hex;
}): Hex {
  if (args.owner.toLowerCase() !== LIQUIDITY_OPERATOR.toLowerCase()) {
    throw new Error("The recipient is not the approved treasury wallet.");
  }
  assertPlan(args.plan);
  if (
    args.permit.spender.toLowerCase() !== V4_POSITION_MANAGER.toLowerCase() ||
    args.permit.details[0].token.toLowerCase() !== USDC.toLowerCase() ||
    args.permit.details[1].token.toLowerCase() !== SUSDFR.toLowerCase() ||
    args.permit.details[0].amount !== args.plan.maxUsdc ||
    args.permit.details[1].amount !== args.plan.maxSusdfr
  ) {
    throw new Error("The Permit2 message does not match the approved plan.");
  }
  const calls: Hex[] = [];
  if (args.plan.kind === "seed") {
    calls.push(
      encodeFunctionData({
        abi: SUSDFR_POSITION_MANAGER_ABI,
        functionName: "initializePool",
        args: [SUSDFR_POOL_KEY, SUSDFR_INITIAL_SQRT_PRICE_X96],
      }),
    );
  }
  calls.push(
    encodeFunctionData({
      abi: SUSDFR_POSITION_MANAGER_ABI,
      functionName: "permitBatch",
      args: [args.owner, args.permit, args.signature],
    }),
  );
  calls.push(
    encodeModifyLiquidityCall({
      owner: args.owner,
      plan: args.plan,
      deadline: args.permit.sigDeadline,
    }),
  );
  return encodeFunctionData({
    abi: SUSDFR_POSITION_MANAGER_ABI,
    functionName: "multicall",
    args: [calls],
  });
}

function addressTopic(address: Address): Hex {
  return pad(address, {size: 32});
}

export function verifySusdfrMintReceipt(args: {
  logs: readonly SusdfrReceiptLog[];
  owner: Address;
  plan: SusdfrLiquidityPlan;
}): SusdfrMintEvidence {
  assertPlan(args.plan);
  const ownerTopic = addressTopic(args.owner).toLowerCase();
  const poolManagerTopic = addressTopic(V4_POOL_MANAGER).toLowerCase();
  const zeroTopic = addressTopic(ZERO_ADDRESS).toLowerCase();
  let tokenId: bigint | undefined;
  let usdcSpent = 0n;
  let susdfrSpent = 0n;
  let matchingLiquidityEvent = false;
  let matchingInitializeEvent = false;

  for (const log of args.logs) {
    const logAddress = log.address.toLowerCase();
    if (
      log.topics[0]?.toLowerCase() === TRANSFER_TOPIC.toLowerCase() &&
      log.topics.length === 3 &&
      log.topics[1]?.toLowerCase() === ownerTopic &&
      log.topics[2]?.toLowerCase() === poolManagerTopic
    ) {
      if (logAddress === USDC.toLowerCase()) usdcSpent += BigInt(log.data);
      if (logAddress === SUSDFR.toLowerCase()) susdfrSpent += BigInt(log.data);
    }
    if (
      logAddress === V4_POSITION_MANAGER.toLowerCase() &&
      log.topics[0]?.toLowerCase() === TRANSFER_TOPIC.toLowerCase() &&
      log.topics.length === 4 &&
      log.topics[1]?.toLowerCase() === zeroTopic &&
      log.topics[2]?.toLowerCase() === ownerTopic
    ) {
      tokenId = BigInt(log.topics[3]);
    }
    if (logAddress !== V4_POOL_MANAGER.toLowerCase()) continue;
    try {
      const decoded = decodeEventLog({
        abi: POOL_MANAGER_EVENT_ABI,
        data: log.data,
        topics: [...log.topics],
        strict: true,
      });
      if (
        decoded.eventName === "ModifyLiquidity" &&
        decoded.args.id.toLowerCase() === SUSDFR_POOL_ID.toLowerCase() &&
        decoded.args.sender.toLowerCase() === V4_POSITION_MANAGER.toLowerCase() &&
        decoded.args.tickLower === args.plan.tickLower &&
        decoded.args.tickUpper === args.plan.tickUpper &&
        decoded.args.liquidityDelta === args.plan.liquidity
      ) {
        matchingLiquidityEvent = true;
      }
      if (
        decoded.eventName === "Initialize" &&
        decoded.args.id.toLowerCase() === SUSDFR_POOL_ID.toLowerCase() &&
        decoded.args.currency0.toLowerCase() === USDC.toLowerCase() &&
        decoded.args.currency1.toLowerCase() === SUSDFR.toLowerCase() &&
        decoded.args.fee === SUSDFR_POOL_FEE &&
        decoded.args.tickSpacing === SUSDFR_TICK_SPACING &&
        decoded.args.hooks.toLowerCase() === ZERO_ADDRESS &&
        decoded.args.sqrtPriceX96 === SUSDFR_INITIAL_SQRT_PRICE_X96 &&
        decoded.args.tick === SUSDFR_INITIAL_TICK
      ) {
        matchingInitializeEvent = true;
      }
    } catch {
      // The required events are checked after scanning every PoolManager log.
    }
  }
  if (tokenId === undefined) {
    throw new Error("The receipt did not mint a Uniswap position to the treasury.");
  }
  if (!matchingLiquidityEvent) {
    throw new Error("The receipt did not add the exact approved liquidity.");
  }
  if (args.plan.kind === "seed" && !matchingInitializeEvent) {
    throw new Error("The receipt did not initialize the exact approved pool.");
  }
  if (
    usdcSpent !== args.plan.expectedUsdc ||
    susdfrSpent !== args.plan.expectedSusdfr
  ) {
    throw new Error("The receipt token spends do not match the approved plan.");
  }
  return {
    tokenId,
    usdcSpent,
    susdfrSpent,
    initialized: matchingInitializeEvent,
  };
}

export function usdcPerSusdfrAtTick(tick: number): number {
  return 1e18 / Math.pow(1.0001, tick);
}

export {PERMIT2, PERMIT2_DOMAIN, PERMIT2_TYPES};
