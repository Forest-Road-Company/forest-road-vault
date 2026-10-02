import {
  decodeEventLog,
  encodeFunctionData,
  parseAbi,
  type Address,
  type Hex,
} from "viem";

import {LIQUIDITY_OPERATOR, USDC} from "./uniswapV4Liquidity";
import {SUSDFR, SUSDFR_DECIMALS} from "./uniswapV4SusdfrLiquidity";

export const V2_FACTORY =
  "0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f" as const;
export const V2_ROUTER =
  "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D" as const;
export const V2_USDC_AMOUNT = 25_000n * 10n ** 6n;
export const V2_USDFR_VALUE = 25_000n * 10n ** 18n;
export const V2_APPROVAL_GAS = 200_000n;
// Pair creation deploys the V2 pair and the sUSDfr transfer runs the current
// points hook.  The pinned production fork estimated 3,187,130 gas and used
// 2,886,484; unused gas is refunded, so 5m preserves comfortable headroom.
export const V2_ADD_LIQUIDITY_GAS = 5_000_000n;
export const V2_DEADLINE_SECONDS = 30n * 60n;
export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

export const V2_ERC20_ABI = parseAbi([
  "function balanceOf(address account) view returns (uint256)",
  "function allowance(address owner,address spender) view returns (uint256)",
  "function approve(address spender,uint256 amount) returns (bool)",
  "event Transfer(address indexed from,address indexed to,uint256 value)",
]);

export const V2_SUSDFR_ABI = parseAbi([
  "function convertToShares(uint256 assets) view returns (uint256 shares)",
  "function convertToAssets(uint256 shares) view returns (uint256 assets)",
]);

export const V2_FACTORY_ABI = parseAbi([
  "function getPair(address tokenA,address tokenB) view returns (address pair)",
  "event PairCreated(address indexed token0,address indexed token1,address pair,uint256 allPairsLength)",
]);

export const V2_ROUTER_ABI = parseAbi([
  "function factory() pure returns (address)",
  "function addLiquidity(address tokenA,address tokenB,uint256 amountADesired,uint256 amountBDesired,uint256 amountAMin,uint256 amountBMin,address to,uint256 deadline) returns (uint256 amountA,uint256 amountB,uint256 liquidity)",
]);

export const V2_PAIR_ABI = parseAbi([
  "function token0() view returns (address)",
  "function token1() view returns (address)",
  "function balanceOf(address account) view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function getReserves() view returns (uint112 reserve0,uint112 reserve1,uint32 blockTimestampLast)",
  "event Transfer(address indexed from,address indexed to,uint256 value)",
  "event Mint(address indexed sender,uint256 amount0,uint256 amount1)",
  "event Sync(uint112 reserve0,uint112 reserve1)",
]);

export type V2LiquidityPlan = {
  usdc: bigint;
  susdfr: bigint;
  susdfrAssets: bigint;
};

export type V2ReceiptLog = {
  address: Address;
  topics: readonly [Hex, ...Hex[]];
  data: Hex;
};

export type V2MintEvidence = {
  pair: Address;
  lpTokens: bigint;
  usdcSpent: bigint;
  susdfrSpent: bigint;
};

export function buildV2LiquidityPlan(args: {
  sharesForTargetAssets: bigint;
  assetsRepresented: bigint;
}): V2LiquidityPlan {
  if (
    args.sharesForTargetAssets <= 0n ||
    args.assetsRepresented <= 0n ||
    args.assetsRepresented > V2_USDFR_VALUE ||
    V2_USDFR_VALUE - args.assetsRepresented > 2n
  ) {
    throw new Error("The live sUSDfr conversion is outside the approved operation.");
  }
  return {
    usdc: V2_USDC_AMOUNT,
    susdfr: args.sharesForTargetAssets,
    susdfrAssets: args.assetsRepresented,
  };
}

export function encodeV2AddLiquidity(args: {
  plan: V2LiquidityPlan;
  recipient?: Address;
  deadline: bigint;
}): Hex {
  if (args.deadline <= 0n) throw new Error("A positive transaction deadline is required.");
  const recipient = args.recipient ?? LIQUIDITY_OPERATOR;
  if (recipient.toLowerCase() !== LIQUIDITY_OPERATOR.toLowerCase()) {
    throw new Error("The V2 liquidity recipient must be the approved treasury.");
  }
  return encodeFunctionData({
    abi: V2_ROUTER_ABI,
    functionName: "addLiquidity",
    args: [
      USDC,
      SUSDFR,
      args.plan.usdc,
      args.plan.susdfr,
      args.plan.usdc,
      args.plan.susdfr,
      recipient,
      args.deadline,
    ],
  });
}

function sameAddress(a: string, b: string): boolean {
  return a.toLowerCase() === b.toLowerCase();
}

function tokenOrderIsCorrect(token0: Address, token1: Address): boolean {
  return sameAddress(token0, USDC) && sameAddress(token1, SUSDFR);
}

export function verifyV2MintReceipt(args: {
  logs: readonly V2ReceiptLog[];
  owner: Address;
  plan: V2LiquidityPlan;
}): V2MintEvidence {
  if (!sameAddress(args.owner, LIQUIDITY_OPERATOR)) {
    throw new Error("The receipt owner is not the approved treasury.");
  }

  const creations: Array<{token0: Address; token1: Address; pair: Address}> = [];
  for (const log of args.logs) {
    if (!sameAddress(log.address, V2_FACTORY)) continue;
    try {
      const decoded = decodeEventLog({
        abi: V2_FACTORY_ABI,
        eventName: "PairCreated",
        data: log.data,
        topics: [...log.topics],
      });
      creations.push({
        token0: decoded.args.token0,
        token1: decoded.args.token1,
        pair: decoded.args.pair,
      });
    } catch {
      // Other factory logs are irrelevant.
    }
  }
  if (creations.length !== 1 || !tokenOrderIsCorrect(creations[0].token0, creations[0].token1)) {
    throw new Error("The receipt does not create exactly the approved USDC/sUSDfr pair.");
  }
  const creation = creations[0];
  if (sameAddress(creation.pair, ZERO_ADDRESS)) {
    throw new Error("The factory emitted a zero pair address.");
  }

  let usdcSpent = 0n;
  let susdfrSpent = 0n;
  for (const log of args.logs) {
    const isUsdc = sameAddress(log.address, USDC);
    const isSusdfr = sameAddress(log.address, SUSDFR);
    if (!isUsdc && !isSusdfr) continue;
    try {
      const decoded = decodeEventLog({
        abi: V2_ERC20_ABI,
        eventName: "Transfer",
        data: log.data,
        topics: [...log.topics],
      });
      if (!sameAddress(decoded.args.from, args.owner)) continue;
      if (!sameAddress(decoded.args.to, creation.pair)) {
        throw new Error("A contributed token was sent somewhere other than the canonical pair.");
      }
      if (isUsdc) usdcSpent += decoded.args.value;
      else susdfrSpent += decoded.args.value;
    } catch (error) {
      if (error instanceof Error && error.message.includes("somewhere other")) throw error;
    }
  }
  if (usdcSpent !== args.plan.usdc || susdfrSpent !== args.plan.susdfr) {
    throw new Error("The receipt token spends do not match the exact approved contributions.");
  }

  let lpTokens = 0n;
  let mintCount = 0;
  let syncCount = 0;
  for (const log of args.logs) {
    if (!sameAddress(log.address, creation.pair)) continue;
    try {
      const decoded = decodeEventLog({abi: V2_PAIR_ABI, data: log.data, topics: [...log.topics]});
      if (decoded.eventName === "Transfer") {
        if (sameAddress(decoded.args.from, ZERO_ADDRESS) && sameAddress(decoded.args.to, args.owner)) {
          lpTokens += decoded.args.value;
        }
      } else if (decoded.eventName === "Mint") {
        mintCount += 1;
        if (!sameAddress(decoded.args.sender, V2_ROUTER)) {
          throw new Error("The LP mint was not initiated by the approved router.");
        }
        const expected0 = sameAddress(creation.token0, USDC) ? args.plan.usdc : args.plan.susdfr;
        const expected1 = sameAddress(creation.token1, SUSDFR) ? args.plan.susdfr : args.plan.usdc;
        if (decoded.args.amount0 !== expected0 || decoded.args.amount1 !== expected1) {
          throw new Error("The pair minted against different token amounts.");
        }
      } else if (decoded.eventName === "Sync") {
        syncCount += 1;
        const expected0 = sameAddress(creation.token0, USDC) ? args.plan.usdc : args.plan.susdfr;
        const expected1 = sameAddress(creation.token1, SUSDFR) ? args.plan.susdfr : args.plan.usdc;
        if (decoded.args.reserve0 !== expected0 || decoded.args.reserve1 !== expected1) {
          throw new Error("The fresh pair reserves do not match the approved opening ratio.");
        }
      }
    } catch (error) {
      if (
        error instanceof Error &&
        (error.message.includes("different token amounts") ||
          error.message.includes("approved router") ||
          error.message.includes("approved opening ratio"))
      ) {
        throw error;
      }
    }
  }
  if (mintCount !== 1 || syncCount !== 1 || lpTokens <= 0n) {
    throw new Error("The receipt does not prove one fresh LP mint to the treasury.");
  }
  return {pair: creation.pair, lpTokens, usdcSpent, susdfrSpent};
}

export {LIQUIDITY_OPERATOR, SUSDFR, SUSDFR_DECIMALS, USDC};
