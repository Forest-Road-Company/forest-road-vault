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

/**
 * A deliberately narrow Uniswap v4 operation for the Forest Road treasury.
 *
 * These constants are taken from the failed, owner-reviewed transaction
 * 0x4858173f610793c1aa8448712026d3ffc794674d140a9c888500044acb24aae5.
 * The helper has no arbitrary-token, arbitrary-recipient, arbitrary-range, or
 * arbitrary-calldata surface.
 */
export const LIQUIDITY_OPERATOR =
  "0x7FDe637d685A5486CCb1B0a8eF658Ad1a08e8337" as const;
export const USDC =
  "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48" as const;
export const USDFR =
  "0xcC07e7c4E5E35AFFD47b351E420A22C667D7f83d" as const;
export const PERMIT2 =
  "0x000000000022D473030F116dDEE9F6B43aC78BA3" as const;
export const V4_POOL_MANAGER =
  "0x000000000004444c5dc75cB358380D2e3dE08A90" as const;
export const V4_POSITION_MANAGER =
  "0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e" as const;
export const V4_STATE_VIEW =
  "0x7ffe42c4a5deea5b0fec41c94c136cf115597227" as const;

export const TICK_LOWER = 276_028;
export const TICK_UPPER = 276_368;
export const POOL_FEE = 375;
export const TICK_SPACING = 4;
export const PILOT_USDC_CAP = 50n * 10n ** 6n;
export const TARGET_TOTAL_LIQUIDITY = 138_501_527_279_400_417_396n;
export const TARGET_USDC_MAX = 2_103_852_527_328n;
export const TARGET_USDFR_MAX = 2_339_647_912_981_486_927_614_300n;

// The exact failed call succeeds on the pinned mainnet fork at 1,300,000 gas
// (495,599 consumed). The additional 200,000 is unused and refunded; it keeps
// the old USDfr points hook above its absolute 500,000-gas entry requirement.
export const LIQUIDITY_TX_GAS = 1_500_000n;

const Q96 = 1n << 96n;
const MAX_UINT256 = (1n << 256n) - 1n;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const ACTIONS_MINT_AND_SETTLE_PAIR = "0x020d" as const;

export const POOL_KEY = {
  currency0: USDC,
  currency1: USDFR,
  fee: POOL_FEE,
  tickSpacing: TICK_SPACING,
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

export const POOL_ID = keccak256(
  encodeAbiParameters(POOL_KEY_PARAMETERS, [
    USDC,
    USDFR,
    POOL_FEE,
    TICK_SPACING,
    ZERO_ADDRESS,
  ]),
);

export const POSITION_MANAGER_ABI = parseAbi([
  "function multicall(bytes[] data) payable returns (bytes[] results)",
  "function permitBatch(address owner,((address token,uint160 amount,uint48 expiration,uint48 nonce)[] details,address spender,uint256 sigDeadline) permitBatch,bytes signature)",
  "function modifyLiquidities(bytes unlockData,uint256 deadline) payable",
  "function getPositionLiquidity(uint256 tokenId) view returns (uint128 liquidity)",
  "function ownerOf(uint256 tokenId) view returns (address owner)",
]);

export const STATE_VIEW_ABI = parseAbi([
  "function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96,int24 tick,uint24 protocolFee,uint24 lpFee)",
]);

export const PERMIT2_ABI = parseAbi([
  "function allowance(address user,address token,address spender) view returns (uint160 amount,uint48 expiration,uint48 nonce)",
]);

export const ERC20_ABI = parseAbi([
  "function balanceOf(address account) view returns (uint256)",
  "function allowance(address owner,address spender) view returns (uint256)",
  "function approve(address spender,uint256 amount) returns (bool)",
]);

const POOL_MANAGER_EVENT_ABI = parseAbi([
  "event ModifyLiquidity(bytes32 indexed id,address indexed sender,int24 tickLower,int24 tickUpper,int256 liquidityDelta,bytes32 salt)",
]);

export const PERMIT2_TYPES = {
  PermitDetails: [
    {name: "token", type: "address"},
    {name: "amount", type: "uint160"},
    {name: "expiration", type: "uint48"},
    {name: "nonce", type: "uint48"},
  ],
  PermitBatch: [
    {name: "details", type: "PermitDetails[]"},
    {name: "spender", type: "address"},
    {name: "sigDeadline", type: "uint256"},
  ],
} as const;

export const PERMIT2_DOMAIN = {
  name: "Permit2",
  chainId: 1,
  verifyingContract: PERMIT2,
} as const;

export type PermitAllowance = {
  amount: bigint;
  expiration: number;
  nonce: number;
};

export type PermitBatchMessage = {
  details: readonly [
    {token: typeof USDC; amount: bigint; expiration: number; nonce: number},
    {token: typeof USDFR; amount: bigint; expiration: number; nonce: number},
  ];
  spender: typeof V4_POSITION_MANAGER;
  sigDeadline: bigint;
};

export type LiquidityPlan = {
  liquidity: bigint;
  expectedUsdc: bigint;
  expectedUsdfr: bigint;
  maxUsdc: bigint;
  maxUsdfr: bigint;
};

export type ReceiptLog = {
  address: Address;
  topics: readonly [Hex, ...Hex[]];
  data: Hex;
};

export type MintEvidence = {
  tokenId: bigint;
  usdcSpent: bigint;
  usdfrSpent: bigint;
};

function divRoundingUp(numerator: bigint, denominator: bigint): bigint {
  if (denominator === 0n) throw new Error("Division by zero.");
  return numerator / denominator + (numerator % denominator === 0n ? 0n : 1n);
}

/** Exact port of Uniswap TickMath.getSqrtPriceAtTick for the supported range. */
export function sqrtPriceAtTick(tick: number): bigint {
  if (!Number.isInteger(tick) || tick < -887_272 || tick > 887_272) {
    throw new Error("Tick is outside the Uniswap range.");
  }
  const absoluteTick = BigInt(tick < 0 ? -tick : tick);
  let ratio =
    (absoluteTick & 1n) !== 0n
      ? 0xfffcb933bd6fad37aa2d162d1a594001n
      : 0x100000000000000000000000000000000n;
  const factors: readonly (readonly [bigint, bigint])[] = [
    [2n, 0xfff97272373d413259a46990580e213an],
    [4n, 0xfff2e50f5f656932ef12357cf3c7fdccn],
    [8n, 0xffe5caca7e10e4e61c3624eaa0941cd0n],
    [16n, 0xffcb9843d60f6159c9db58835c926644n],
    [32n, 0xff973b41fa98c081472e6896dfb254c0n],
    [64n, 0xff2ea16466c96a3843ec78b326b52861n],
    [128n, 0xfe5dee046a99a2a811c461f1969c3053n],
    [256n, 0xfcbe86c7900a88aedcffc83b479aa3a4n],
    [512n, 0xf987a7253ac413176f2b074cf7815e54n],
    [1_024n, 0xf3392b0822b70005940c7a398e4b70f3n],
    [2_048n, 0xe7159475a2c29b7443b29c7fa6e889d9n],
    [4_096n, 0xd097f3bdfd2022b8845ad8f792aa5825n],
    [8_192n, 0xa9f746462d870fdf8a65dc1f90e061e5n],
    [16_384n, 0x70d869a156d2a1b890bb3df62baf32f7n],
    [32_768n, 0x31be135f97d08fd981231505542fcfa6n],
    [65_536n, 0x9aa508b5b7a84e1c677de54f3e99bc9n],
    [131_072n, 0x5d6af8dedb81196699c329225ee604n],
    [262_144n, 0x2216e584f5fa1ea926041bedfe98n],
    [524_288n, 0x48a170391f7dc42444e8fa2n],
  ];
  for (const [mask, factor] of factors) {
    if ((absoluteTick & mask) !== 0n) ratio = (ratio * factor) >> 128n;
  }
  if (tick > 0) ratio = MAX_UINT256 / ratio;
  const remainderMask = (1n << 32n) - 1n;
  return (ratio >> 32n) + ((ratio & remainderMask) === 0n ? 0n : 1n);
}

export function amount0Delta(
  liquidity: bigint,
  sqrtPriceAX96: bigint,
  sqrtPriceBX96: bigint,
): bigint {
  let lower = sqrtPriceAX96;
  let upper = sqrtPriceBX96;
  if (lower > upper) [lower, upper] = [upper, lower];
  if (lower <= 0n) throw new Error("The lower square-root price must be positive.");
  const numerator = divRoundingUp(
    (liquidity << 96n) * (upper - lower),
    upper,
  );
  return divRoundingUp(numerator, lower);
}

export function amount1Delta(
  liquidity: bigint,
  sqrtPriceAX96: bigint,
  sqrtPriceBX96: bigint,
): bigint {
  let lower = sqrtPriceAX96;
  let upper = sqrtPriceBX96;
  if (lower > upper) [lower, upper] = [upper, lower];
  return divRoundingUp(liquidity * (upper - lower), Q96);
}

export function quoteLiquidity(
  sqrtPriceX96: bigint,
  liquidity: bigint,
): {usdc: bigint; usdfr: bigint} {
  const lower = sqrtPriceAtTick(TICK_LOWER);
  const upper = sqrtPriceAtTick(TICK_UPPER);
  if (sqrtPriceX96 <= lower) {
    return {usdc: amount0Delta(liquidity, lower, upper), usdfr: 0n};
  }
  if (sqrtPriceX96 >= upper) {
    return {usdc: 0n, usdfr: amount1Delta(liquidity, lower, upper)};
  }
  return {
    usdc: amount0Delta(liquidity, sqrtPriceX96, upper),
    usdfr: amount1Delta(liquidity, lower, sqrtPriceX96),
  };
}

function maxLiquidityForUsdc(
  sqrtPriceX96: bigint,
  usdcCap: bigint,
): bigint {
  const lower = sqrtPriceAtTick(TICK_LOWER);
  const upper = sqrtPriceAtTick(TICK_UPPER);
  if (sqrtPriceX96 <= lower || sqrtPriceX96 >= upper) {
    throw new Error("The pool price is outside the approved liquidity range.");
  }
  let low = 0n;
  let high =
    (usdcCap * sqrtPriceX96 * upper) /
      (Q96 * (upper - sqrtPriceX96)) +
    2n;
  while (amount0Delta(high, sqrtPriceX96, upper) <= usdcCap) high *= 2n;
  while (low + 1n < high) {
    const midpoint = (low + high) / 2n;
    if (amount0Delta(midpoint, sqrtPriceX96, upper) <= usdcCap) {
      low = midpoint;
    } else {
      high = midpoint;
    }
  }
  if (low === 0n) throw new Error("The 50 USDC pilot is too small at this price.");
  return low;
}

export function buildPilotPlan(sqrtPriceX96: bigint): LiquidityPlan {
  const liquidity = maxLiquidityForUsdc(sqrtPriceX96, PILOT_USDC_CAP);
  const expected = quoteLiquidity(sqrtPriceX96, liquidity);
  return {
    liquidity,
    expectedUsdc: expected.usdc,
    expectedUsdfr: expected.usdfr,
    maxUsdc: PILOT_USDC_CAP,
    // Across the approved range, this is the largest amount of USDfr this
    // exact liquidity can consume. It is a hard cap, not an estimate.
    maxUsdfr: amount1Delta(
      liquidity,
      sqrtPriceAtTick(TICK_LOWER),
      sqrtPriceAtTick(TICK_UPPER),
    ),
  };
}

export function buildRemainderPlan(
  sqrtPriceX96: bigint,
  pilot: Pick<MintEvidence, "usdcSpent" | "usdfrSpent"> & {liquidity: bigint},
): LiquidityPlan {
  if (pilot.liquidity <= 0n || pilot.liquidity >= TARGET_TOTAL_LIQUIDITY) {
    throw new Error("The confirmed pilot liquidity is outside the approved target.");
  }
  if (
    pilot.usdcSpent > TARGET_USDC_MAX ||
    pilot.usdfrSpent > TARGET_USDFR_MAX
  ) {
    throw new Error("The pilot spend exceeds the owner-reviewed total caps.");
  }
  const liquidity = TARGET_TOTAL_LIQUIDITY - pilot.liquidity;
  const expected = quoteLiquidity(sqrtPriceX96, liquidity);
  const maxUsdc = TARGET_USDC_MAX - pilot.usdcSpent;
  const maxUsdfr = TARGET_USDFR_MAX - pilot.usdfrSpent;
  if (expected.usdc > maxUsdc || expected.usdfr > maxUsdfr) {
    throw new Error(
      "The live price would exceed the remaining owner-reviewed token caps.",
    );
  }
  return {
    liquidity,
    expectedUsdc: expected.usdc,
    expectedUsdfr: expected.usdfr,
    maxUsdc,
    maxUsdfr,
  };
}

export function buildPermitBatchMessage(args: {
  plan: LiquidityPlan;
  usdcNonce: number;
  usdfrNonce: number;
  timestamp: number;
}): PermitBatchMessage {
  if (!Number.isInteger(args.timestamp) || args.timestamp <= 0) {
    throw new Error("A valid chain timestamp is required.");
  }
  const expiration = args.timestamp + 60 * 60;
  const sigDeadline = BigInt(args.timestamp + 30 * 60);
  return {
    details: [
      {
        token: USDC,
        amount: args.plan.maxUsdc,
        expiration,
        nonce: args.usdcNonce,
      },
      {
        token: USDFR,
        amount: args.plan.maxUsdfr,
        expiration,
        nonce: args.usdfrNonce,
      },
    ],
    spender: V4_POSITION_MANAGER,
    sigDeadline,
  };
}

export function encodeLiquidityTransaction(args: {
  owner: Address;
  plan: LiquidityPlan;
  permit: PermitBatchMessage;
  signature: Hex;
  liquidityDeadline?: bigint;
}): Hex {
  if (args.owner.toLowerCase() !== LIQUIDITY_OPERATOR.toLowerCase()) {
    throw new Error("The recipient is not the approved treasury wallet.");
  }
  const liquidityCall = encodeModifyLiquidityCall({
    owner: args.owner,
    plan: args.plan,
    deadline: args.liquidityDeadline ?? args.permit.sigDeadline,
  });
  const permitCall = encodeFunctionData({
    abi: POSITION_MANAGER_ABI,
    functionName: "permitBatch",
    args: [args.owner, args.permit, args.signature],
  });
  return encodeFunctionData({
    abi: POSITION_MANAGER_ABI,
    functionName: "multicall",
    args: [[permitCall, liquidityCall]],
  });
}

export function encodeModifyLiquidityCall(args: {
  owner: Address;
  plan: LiquidityPlan;
  deadline: bigint;
}): Hex {
  if (args.owner.toLowerCase() !== LIQUIDITY_OPERATOR.toLowerCase()) {
    throw new Error("The recipient is not the approved treasury wallet.");
  }
  const mintParameters = encodeAbiParameters(MINT_POSITION_PARAMETERS, [
    POOL_KEY,
    TICK_LOWER,
    TICK_UPPER,
    args.plan.liquidity,
    args.plan.maxUsdc,
    args.plan.maxUsdfr,
    args.owner,
    "0x",
  ]);
  const settleParameters = encodeAbiParameters(SETTLE_PAIR_PARAMETERS, [
    USDC,
    USDFR,
  ]);
  const unlockData = encodeAbiParameters(ACTION_PAYLOAD_PARAMETERS, [
    ACTIONS_MINT_AND_SETTLE_PAIR,
    [mintParameters, settleParameters],
  ]);
  return encodeFunctionData({
    abi: POSITION_MANAGER_ABI,
    functionName: "modifyLiquidities",
    args: [unlockData, args.deadline],
  });
}

const TRANSFER_TOPIC = keccak256(
  toHex("Transfer(address,address,uint256)"),
);

function addressTopic(address: Address): Hex {
  return pad(address, {size: 32});
}

/**
 * Rejects a receipt unless it proves the exact pool, range, liquidity, owner,
 * and token spends requested by this helper.
 */
export function verifyMintReceipt(args: {
  logs: readonly ReceiptLog[];
  owner: Address;
  expectedLiquidity: bigint;
}): MintEvidence {
  const ownerTopic = addressTopic(args.owner).toLowerCase();
  const zeroTopic = addressTopic(ZERO_ADDRESS).toLowerCase();
  let tokenId: bigint | undefined;
  let usdcSpent = 0n;
  let usdfrSpent = 0n;
  let matchingLiquidityEvent = false;

  for (const log of args.logs) {
    const logAddress = log.address.toLowerCase();
    if (
      log.topics[0]?.toLowerCase() === TRANSFER_TOPIC.toLowerCase() &&
      log.topics[1]?.toLowerCase() === ownerTopic
    ) {
      if (logAddress === USDC.toLowerCase()) usdcSpent += BigInt(log.data);
      if (logAddress === USDFR.toLowerCase()) usdfrSpent += BigInt(log.data);
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
    if (logAddress === V4_POOL_MANAGER.toLowerCase()) {
      try {
        const decoded = decodeEventLog({
          abi: POOL_MANAGER_EVENT_ABI,
          data: log.data,
          topics: [...log.topics],
          strict: true,
        });
        if (
          decoded.eventName === "ModifyLiquidity" &&
          decoded.args.id.toLowerCase() === POOL_ID.toLowerCase() &&
          decoded.args.sender.toLowerCase() ===
            V4_POSITION_MANAGER.toLowerCase() &&
          decoded.args.tickLower === TICK_LOWER &&
          decoded.args.tickUpper === TICK_UPPER &&
          decoded.args.liquidityDelta === args.expectedLiquidity
        ) {
          matchingLiquidityEvent = true;
        }
      } catch {
        // Other PoolManager events are irrelevant; the required event is
        // checked after the loop.
      }
    }
  }
  if (tokenId === undefined) {
    throw new Error("The receipt did not mint a Uniswap position to the treasury.");
  }
  if (!matchingLiquidityEvent) {
    throw new Error("The receipt did not add the exact approved liquidity.");
  }
  if (usdcSpent === 0n || usdfrSpent === 0n) {
    throw new Error("The receipt did not prove both token contributions.");
  }
  return {tokenId, usdcSpent, usdfrSpent};
}
