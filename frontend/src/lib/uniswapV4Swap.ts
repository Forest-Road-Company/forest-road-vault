import {
  BaseError,
  ContractFunctionRevertedError,
  decodeAbiParameters,
  decodeErrorResult,
  decodeFunctionData,
  decodeFunctionResult,
  encodeAbiParameters,
  encodeFunctionData,
  maxUint256,
  type Address,
  type Hex,
} from "viem";

import {ERC20_ABI} from "./abi";
import {decodeWriteError, type DecodedError} from "./errors";
import {PERMIT2, PERMIT2_DOMAIN, PERMIT2_TYPES, POOL_KEY, USDC, USDFR} from "./uniswapV4Liquidity";

/**
 * Buying USDfr with USDC through Uniswap's own contracts, for the site's Buy tab.
 *
 * One route only: exact USDC in, through the USDfr/USDC Uniswap v4 pool whose key
 * `uniswapV4Liquidity.ts` derives (USDC currency0, USDfr currency1, fee 375, tick spacing 4,
 * no hooks), executed by Uniswap's Universal Router with one V4_SWAP command whose actions are
 * SWAP_EXACT_IN_SINGLE, SETTLE_ALL and TAKE_ALL. USDC reaches the pool through Permit2: a
 * one-time maximum ERC-20 approval to Permit2, as Uniswap's own app grants it, then for each buy
 * a PermitSingle signed for exactly the amount being sold and spent in the same `execute` call
 * (PERMIT2_PERMIT). There is no recipient parameter anywhere: TAKE_ALL pays the router's caller.
 * Every amount here is a bigint; no amount touches floating point.
 *
 * Addresses verified on Ethereum mainnet on 1 October 2026 (block 26,099,500), against Uniswap's
 * own records (github.com/Uniswap/docs content/protocols/v4/deployments.mdx and
 * github.com/Uniswap/universal-router deploy-addresses/mainnet.json) and on chain: each has code;
 * the router, quoter and state view each return the canonical PoolManager from `poolManager()`;
 * the router's runtime code embeds the Permit2 and PoolManager addresses as immutables; and
 * Permit2's `DOMAIN_SEPARATOR()` equals the domain signed below. The pool key matches the
 * PoolManager's own Initialize event for this pool id (block 26,026,849).
 */

/** Universal Router 2.0.0, the first release with Uniswap v4 support. */
export const UNIVERSAL_ROUTER = "0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af" as const;
/**
 * Uniswap's V4Quoter (v4-periphery), in its EIP-55 checksum form. The mixed case quoted in some
 * references ("0x52f0E24D...") fails the checksum, and viem refuses to call such an address.
 */
export const V4_QUOTER = "0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203" as const;

/** Universal Router command bytes (Commands.sol, router 2.0.0). */
export const COMMAND_PERMIT2_PERMIT = 0x0a;
export const COMMAND_V4_SWAP = 0x10;
/** v4-periphery Actions.sol, at the revision the 2.0.0 router pins. */
export const ACTION_SWAP_EXACT_IN_SINGLE = 0x06;
export const ACTION_SETTLE_ALL = 0x0c;
export const ACTION_TAKE_ALL = 0x0f;

const COMMANDS_SWAP_ONLY: Hex = "0x10";
const COMMANDS_PERMIT_THEN_SWAP: Hex = "0x0a10";
const BUY_ACTIONS: Hex = "0x060c0f";

/**
 * USDC is currency0, so paying USDC for USDfr swaps zero for one. The guard below fails the
 * module load if the shared pool key ever disagrees.
 */
const BUY_ZERO_FOR_ONE = true;
if (POOL_KEY.currency0.toLowerCase() !== USDC.toLowerCase() || POOL_KEY.currency1.toLowerCase() !== USDFR.toLowerCase()) {
  throw new Error("The USDfr/USDC pool key no longer has USDC as currency0 and USDfr as currency1.");
}

export const USDC_DECIMALS = 6;
export const USDFR_DECIMALS = 18;
/** USDfr base units per USDC base unit at exactly 1:1 (10^18 / 10^6). */
const PARITY_SCALE = 10n ** 12n;
const PPM = 1_000_000n;
const BPS = 10_000n;

/**
 * Default, minimum and maximum slippage limits, in basis points (0.05%, 0.05%, 3%). The default is
 * the minimum (Forest Road, 2 October 2026): the pair trades near 1:1 and the quote already counts
 * the pool's fees and price impact, so the limit only covers movement before inclusion; a buyer can
 * raise it.
 */
export const DEFAULT_SLIPPAGE_BPS = 5n;
export const MIN_SLIPPAGE_BPS = 5n;
export const MAX_SLIPPAGE_BPS = 300n;
/** A swap must be mined within 20 minutes of the block it was prepared against. */
export const SWAP_DEADLINE_SECONDS = 20n * 60n;
/** Quotes below 0.99 USDfr per USDC carry a warning that names the 1:1 mint. */
export const WARNING_FLOOR_BPS = 9_900n;

const UINT128_MAX = (1n << 128n) - 1n;
const UINT160_MAX = (1n << 160n) - 1n;
const UINT48_MAX = (1n << 48n) - 1n;

const POOL_KEY_COMPONENTS = [
  {name: "currency0", type: "address"},
  {name: "currency1", type: "address"},
  {name: "fee", type: "uint24"},
  {name: "tickSpacing", type: "int24"},
  {name: "hooks", type: "address"},
] as const;

/**
 * Every revert the buy route can surface, at any nesting depth, so a simulation failure decodes
 * to a name and then to words. The router bubbles reverts from inside the PoolManager's unlock
 * callback unchanged; it wraps a failed PERMIT2_PERMIT in ExecutionFailed; the PoolManager wraps a
 * failed token payout (USDfr refusing the transfer to the buyer) in WrappedError; and the quoter
 * wraps a failed quote in UnexpectedRevertBytes.
 */
export const SWAP_ROUTE_ERRORS = [
  // UniversalRouter 2.0.0
  {type: "error", name: "ExecutionFailed", inputs: [{name: "commandIndex", type: "uint256"}, {name: "message", type: "bytes"}]},
  {type: "error", name: "TransactionDeadlinePassed", inputs: []},
  {type: "error", name: "LengthMismatch", inputs: []},
  {type: "error", name: "ContractLocked", inputs: []},
  {type: "error", name: "InvalidCommandType", inputs: [{name: "commandType", type: "uint256"}]},
  // V4Router, BaseActionsRouter and DeltaResolver (v4-periphery)
  {type: "error", name: "V4TooLittleReceived", inputs: [{name: "minAmountOutReceived", type: "uint256"}, {name: "amountReceived", type: "uint256"}]},
  {type: "error", name: "V4TooMuchRequested", inputs: [{name: "maxAmountInRequested", type: "uint256"}, {name: "amountRequested", type: "uint256"}]},
  {type: "error", name: "DeltaNotPositive", inputs: [{name: "currency", type: "address"}]},
  {type: "error", name: "DeltaNotNegative", inputs: [{name: "currency", type: "address"}]},
  {type: "error", name: "UnsupportedAction", inputs: [{name: "action", type: "uint256"}]},
  {type: "error", name: "InputLengthMismatch", inputs: []},
  {type: "error", name: "SliceOutOfBounds", inputs: []},
  // PoolManager (v4-core)
  {type: "error", name: "WrappedError", inputs: [{name: "target", type: "address"}, {name: "selector", type: "bytes4"}, {name: "reason", type: "bytes"}, {name: "details", type: "bytes"}]},
  {type: "error", name: "ERC20TransferFailed", inputs: []},
  {type: "error", name: "PoolNotInitialized", inputs: []},
  {type: "error", name: "CurrencyNotSettled", inputs: []},
  {type: "error", name: "SwapAmountCannotBeZero", inputs: []},
  {type: "error", name: "PriceLimitAlreadyExceeded", inputs: [{name: "sqrtPriceCurrentX96", type: "uint160"}, {name: "sqrtPriceLimitX96", type: "uint160"}]},
  // Permit2
  {type: "error", name: "AllowanceExpired", inputs: [{name: "deadline", type: "uint256"}]},
  {type: "error", name: "InsufficientAllowance", inputs: [{name: "amount", type: "uint256"}]},
  {type: "error", name: "InvalidNonce", inputs: []},
  {type: "error", name: "SignatureExpired", inputs: [{name: "signatureDeadline", type: "uint256"}]},
  {type: "error", name: "InvalidSignature", inputs: []},
  {type: "error", name: "InvalidSigner", inputs: []},
  {type: "error", name: "InvalidSignatureLength", inputs: []},
  {type: "error", name: "InvalidContractSignature", inputs: []},
  // V4Quoter
  {type: "error", name: "UnexpectedRevertBytes", inputs: [{name: "revertData", type: "bytes"}]},
  {type: "error", name: "NotEnoughLiquidity", inputs: [{name: "poolId", type: "bytes32"}]},
  // USDfr, reached when the pool pays the buyer (wrapped by the PoolManager)
  {type: "error", name: "USDfr_TransferNotAllowed", inputs: [{name: "from", type: "address"}, {name: "to", type: "address"}]},
  {type: "error", name: "EnforcedPause", inputs: []},
  {type: "error", name: "PointsHook_InsufficientGas", inputs: [{name: "available", type: "uint256"}, {name: "required", type: "uint256"}]},
] as const;

export const UNIVERSAL_ROUTER_ABI = [
  {
    type: "function",
    name: "execute",
    stateMutability: "payable",
    inputs: [
      {name: "commands", type: "bytes"},
      {name: "inputs", type: "bytes[]"},
      {name: "deadline", type: "uint256"},
    ],
    outputs: [],
  },
  ...SWAP_ROUTE_ERRORS,
] as const;

/** `quoteExactInputSingle` changes state inside a reverted unlock, so it is read with eth_call. */
export const V4_QUOTER_ABI = [
  {
    type: "function",
    name: "quoteExactInputSingle",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "params",
        type: "tuple",
        components: [
          {name: "poolKey", type: "tuple", components: POOL_KEY_COMPONENTS},
          {name: "zeroForOne", type: "bool"},
          {name: "exactAmount", type: "uint128"},
          {name: "hookData", type: "bytes"},
        ],
      },
    ],
    outputs: [
      {name: "amountOut", type: "uint256"},
      {name: "gasEstimate", type: "uint256"},
    ],
  },
  ...SWAP_ROUTE_ERRORS,
] as const;

const EXACT_INPUT_SINGLE_PARAMS = [
  {
    name: "params",
    type: "tuple",
    components: [
      {name: "poolKey", type: "tuple", components: POOL_KEY_COMPONENTS},
      {name: "zeroForOne", type: "bool"},
      {name: "amountIn", type: "uint128"},
      {name: "amountOutMinimum", type: "uint128"},
      {name: "hookData", type: "bytes"},
    ],
  },
] as const;
const CURRENCY_AND_AMOUNT = [
  {name: "currency", type: "address"},
  {name: "amount", type: "uint256"},
] as const;
const ACTIONS_AND_PARAMS = [
  {name: "actions", type: "bytes"},
  {name: "params", type: "bytes[]"},
] as const;
/** PERMIT2_PERMIT input: `abi.encode(IAllowanceTransfer.PermitSingle, bytes signature)`. */
const PERMIT_SINGLE_AND_SIGNATURE = [
  {
    name: "permitSingle",
    type: "tuple",
    components: [
      {
        name: "details",
        type: "tuple",
        components: [
          {name: "token", type: "address"},
          {name: "amount", type: "uint160"},
          {name: "expiration", type: "uint48"},
          {name: "nonce", type: "uint48"},
        ],
      },
      {name: "spender", type: "address"},
      {name: "sigDeadline", type: "uint256"},
    ],
  },
  {name: "signature", type: "bytes"},
] as const;

/** EIP-712 types for Permit2's PermitSingle, sharing PermitDetails with the treasury helper. */
export const PERMIT_SINGLE_TYPES = {
  PermitDetails: PERMIT2_TYPES.PermitDetails,
  PermitSingle: [
    {name: "details", type: "PermitDetails"},
    {name: "spender", type: "address"},
    {name: "sigDeadline", type: "uint256"},
  ],
} as const;

export type PermitSingle = {
  details: {token: Address; amount: bigint; expiration: number; nonce: number};
  spender: Address;
  sigDeadline: bigint;
};
export type SignedPermit = {permit: PermitSingle; signature: Hex};
export type PermitAllowance = {amount: bigint; expiration: number; nonce: number};
export type BuyExecuteArgs = readonly [commands: Hex, inputs: readonly Hex[], deadline: bigint];
export type BuyQuote = {amountIn: bigint; amountOut: bigint; gasEstimate: bigint};

function assertAmountIn(amountIn: bigint): void {
  // Zero is not merely useless here: the router reads amountIn 0 as "use the open delta".
  if (amountIn <= 0n) throw new Error("Enter a USDC amount greater than zero.");
  if (amountIn > UINT128_MAX) throw new Error("That USDC amount is too large to swap.");
}

// ── Quote ─────────────────────────────────────────────────────────────────

/** Calldata for the V4Quoter's exact-input quote of selling `amountIn` USDC for USDfr. */
export function encodeQuoteCall(amountIn: bigint): Hex {
  assertAmountIn(amountIn);
  return encodeFunctionData({
    abi: V4_QUOTER_ABI,
    functionName: "quoteExactInputSingle",
    args: [{poolKey: POOL_KEY, zeroForOne: BUY_ZERO_FOR_ONE, exactAmount: amountIn, hookData: "0x"}],
  });
}

/** Decodes the quoter's return data. A quote of zero USDfr is refused rather than shown. */
export function decodeQuoteResult(amountIn: bigint, data: Hex | undefined): BuyQuote {
  if (!data || data === "0x") throw new Error("The quoter returned no data.");
  const [amountOut, gasEstimate] = decodeFunctionResult({
    abi: V4_QUOTER_ABI,
    functionName: "quoteExactInputSingle",
    data,
  });
  if (amountOut <= 0n) throw new Error("The pool quoted no USDfr for this amount.");
  return {amountIn, amountOut, gasEstimate};
}

// ── Pricing, slippage and fees ────────────────────────────────────────────

/** The fewest USDfr the swap may return: the quote less the slippage limit, rounded down. */
export function minAmountOut(quotedOut: bigint, slippageBps: bigint): bigint {
  if (quotedOut <= 0n) throw new Error("A positive quote is required.");
  if (slippageBps < MIN_SLIPPAGE_BPS || slippageBps > MAX_SLIPPAGE_BPS) {
    throw new Error("Slippage must be between 0.05% and 3%.");
  }
  return (quotedOut * (BPS - slippageBps)) / BPS;
}

export type SlippageParse = {ok: true; bps: bigint} | {ok: false; message: string};

/** Parses a slippage limit typed as a percentage ("0.5" is 50 bps), exactly, without floats. */
export function parseSlippagePercent(text: string): SlippageParse {
  const match = /^(\d*)(?:\.(\d*))?$/.exec(text.trim());
  if (!match || (match[1] === "" && (match[2] ?? "") === "")) {
    return {ok: false, message: "Enter a slippage limit between 0.05% and 3%."};
  }
  const fraction = match[2] ?? "";
  if (fraction.length > 2) {
    return {ok: false, message: "Use at most two decimal places, for example 0.05."};
  }
  const whole = match[1] === "" ? 0n : BigInt(match[1]);
  const bps = whole * 100n + BigInt(fraction.padEnd(2, "0"));
  if (bps < MIN_SLIPPAGE_BPS || bps > MAX_SLIPPAGE_BPS) {
    return {ok: false, message: "Slippage must be between 0.05% and 3%."};
  }
  return {ok: true, bps};
}

function formatScaled(value: bigint, scale: bigint, digits: number): string {
  const whole = value / scale;
  const fraction = (value % scale).toString().padStart(digits, "0").replace(/0+$/, "");
  return fraction ? `${whole}.${fraction}` : whole.toString();
}

/** 50n is "0.5%", 5n is "0.05%", 300n is "3%". */
export function formatBpsPercent(bps: bigint): string {
  if (bps < 0n) throw new Error("Basis points cannot be negative.");
  return `${formatScaled(bps, 100n, 2)}%`;
}

/** Hundredths of a basis point (Uniswap fee units, parts per million): 475 is "0.0475%". */
export function formatPipsPercent(pips: bigint): string {
  if (pips < 0n) throw new Error("A fee cannot be negative.");
  return `${formatScaled(pips, 10_000n, 4)}%`;
}

/** USDfr per USDC as an 18-decimal fixed-point number, rounded down. */
export function priceE18(amountIn: bigint, amountOut: bigint): bigint {
  assertAmountIn(amountIn);
  return (amountOut * 10n ** BigInt(USDC_DECIMALS)) / amountIn;
}

/** Signed distance of the quote from 1:1, in parts per million of the input, rounded down. */
export function parityDeltaPpm(amountIn: bigint, amountOut: bigint): bigint {
  assertAmountIn(amountIn);
  return (amountOut * PPM) / (amountIn * PARITY_SCALE) - PPM;
}

/** "0.0988% below 1:1", "0.0125% above 1:1" or "exactly 1:1". */
export function describeParity(amountIn: bigint, amountOut: bigint): string {
  const delta = parityDeltaPpm(amountIn, amountOut);
  if (delta === 0n) return "exactly 1:1";
  const size = formatPipsPercent(delta < 0n ? -delta : delta);
  return delta < 0n ? `${size} below 1:1` : `${size} above 1:1`;
}

/** True when the quote is worse than 0.99 USDfr per USDC. Exactly 0.99 is not warned. */
export function isBelowWarningFloor(amountIn: bigint, amountOut: bigint): boolean {
  assertAmountIn(amountIn);
  return amountOut * BPS < amountIn * PARITY_SCALE * WARNING_FLOOR_BPS;
}

/**
 * The fee a USDC-to-USDfr swap pays, in pips, from the pool's slot0: Uniswap's protocol fee for
 * the zero-for-one direction (the low 12 bits) combined with the LP fee exactly as v4-core's
 * ProtocolFeeLibrary.calculateSwapFee does.
 */
export function buySwapFeePips(lpFee: number, protocolFee: number): {lpFee: bigint; protocolFee: bigint; total: bigint} {
  const lp = BigInt(lpFee);
  const protocol = BigInt(protocolFee) & 0xfffn;
  return {lpFee: lp, protocolFee: protocol, total: protocol + lp - (protocol * lp) / PPM};
}

// ── Permit2 ───────────────────────────────────────────────────────────────

/**
 * What the one-time USDC approval grants Permit2: the maximum, as Uniswap's own app does (Forest
 * Road owner decision, 1 October 2026). Permit2 moves the buyer's USDC only for a spender the
 * buyer has authorized in Permit2 itself, and the Buy tab authorizes the router with a
 * PermitSingle for exactly one buy's amount, expiring at that buy's deadline. USDC decrements
 * even a maximum allowance, so a later buy needs this approval again only after
 * 2^256 - 1 base units have been spent.
 */
export const PERMIT2_APPROVAL_AMOUNT = maxUint256;

/** True when USDC's allowance to Permit2 cannot cover this buy, so the one-time approval comes first. */
export function needsPermit2Approval(allowance: bigint, amountIn: bigint): boolean {
  return allowance < amountIn;
}

/** The one-time approval the Buy tab hands to the shared write flow (and the fork test sends). */
export function permit2ApprovalRequest() {
  return {
    address: USDC,
    abi: ERC20_ABI,
    functionName: "approve" as const,
    args: [PERMIT2, PERMIT2_APPROVAL_AMOUNT] as const,
  };
}

export function swapDeadline(blockTimestamp: bigint): bigint {
  if (blockTimestamp <= 0n) throw new Error("A chain timestamp is required.");
  return blockTimestamp + SWAP_DEADLINE_SECONDS;
}

/**
 * Whether the router needs a fresh signed allowance: an existing Permit2 allowance is reused only
 * when it covers the whole amount and outlasts the swap's deadline.
 */
export function needsPermit(allowance: PermitAllowance, amountIn: bigint, deadline: bigint): boolean {
  return allowance.amount < amountIn || BigInt(allowance.expiration) < deadline;
}

/** A PermitSingle for exactly `amount` USDC, spendable by the router until the swap deadline. */
export function buildPermitSingle(args: {amount: bigint; nonce: number; deadline: bigint}): PermitSingle {
  assertAmountIn(args.amount);
  if (args.amount > UINT160_MAX) throw new Error("That USDC amount is too large for Permit2.");
  if (!Number.isSafeInteger(args.nonce) || args.nonce < 0 || BigInt(args.nonce) > UINT48_MAX) {
    throw new Error("Permit2 returned an invalid nonce.");
  }
  if (args.deadline <= 0n || args.deadline > UINT48_MAX) throw new Error("The swap deadline is invalid.");
  return {
    details: {token: USDC, amount: args.amount, expiration: Number(args.deadline), nonce: args.nonce},
    spender: UNIVERSAL_ROUTER,
    sigDeadline: args.deadline,
  };
}

/** The exact EIP-712 payload the wallet signs. The domain is Permit2's own, verified on chain. */
export function permitTypedData(permit: PermitSingle) {
  return {
    domain: PERMIT2_DOMAIN,
    types: PERMIT_SINGLE_TYPES,
    primaryType: "PermitSingle" as const,
    message: permit,
  };
}

function assertPermitCoversBuy(permit: PermitSingle, amountIn: bigint, deadline: bigint): void {
  if (permit.details.token.toLowerCase() !== USDC.toLowerCase()) throw new Error("The permit is not for USDC.");
  if (permit.spender.toLowerCase() !== UNIVERSAL_ROUTER.toLowerCase()) {
    throw new Error("The permit does not name the Uniswap router.");
  }
  if (permit.details.amount < amountIn) throw new Error("The permit does not cover the amount.");
  if (permit.sigDeadline < deadline || BigInt(permit.details.expiration) < deadline) {
    throw new Error("The permit would lapse before the swap deadline.");
  }
}

// ── Router calldata ───────────────────────────────────────────────────────

/** V4_SWAP input: sell exactly `amountIn` USDC, settle it, take at least `amountOutMinimum` USDfr. */
export function encodeV4SwapInput(amountIn: bigint, amountOutMinimum: bigint): Hex {
  const minimum = amountOutMinimum;
  const swap = encodeAbiParameters(EXACT_INPUT_SINGLE_PARAMS, [
    {poolKey: POOL_KEY, zeroForOne: BUY_ZERO_FOR_ONE, amountIn, amountOutMinimum: minimum, hookData: "0x"},
  ]);
  const settle = encodeAbiParameters(CURRENCY_AND_AMOUNT, [USDC, amountIn]);
  const take = encodeAbiParameters(CURRENCY_AND_AMOUNT, [USDFR, minimum]);
  return encodeAbiParameters(ACTIONS_AND_PARAMS, [BUY_ACTIONS, [swap, settle, take]]);
}

export function encodePermit2PermitInput(signed: SignedPermit): Hex {
  return encodeAbiParameters(PERMIT_SINGLE_AND_SIGNATURE, [signed.permit, signed.signature]);
}

/**
 * Arguments for `UniversalRouter.execute(commands, inputs, deadline)`: an optional
 * PERMIT2_PERMIT followed by the V4_SWAP. Fails closed on any amount, deadline or permit that
 * does not describe this buy.
 */
export function buildBuyExecuteArgs(args: {
  amountIn: bigint;
  amountOutMinimum: bigint;
  deadline: bigint;
  signedPermit?: SignedPermit | null;
}): BuyExecuteArgs {
  assertAmountIn(args.amountIn);
  if (args.amountOutMinimum <= 0n || args.amountOutMinimum > UINT128_MAX) {
    throw new Error("A positive minimum USDfr amount is required.");
  }
  if (args.deadline <= 0n) throw new Error("A swap deadline is required.");
  const swapInput = encodeV4SwapInput(args.amountIn, args.amountOutMinimum);
  let commands = COMMANDS_SWAP_ONLY;
  let inputs: readonly Hex[] = [swapInput];
  if (args.signedPermit) {
    assertPermitCoversBuy(args.signedPermit.permit, args.amountIn, args.deadline);
    commands = COMMANDS_PERMIT_THEN_SWAP;
    inputs = [encodePermit2PermitInput(args.signedPermit), swapInput];
  }
  return [commands, inputs, args.deadline] as const;
}

/** The exact write the Buy tab hands to the shared write flow (and the fork test sends). */
export function buyRequest(args: BuyExecuteArgs) {
  return {
    address: UNIVERSAL_ROUTER,
    abi: UNIVERSAL_ROUTER_ABI,
    functionName: "execute" as const,
    args,
  };
}

export function encodeBuyCalldata(args: BuyExecuteArgs): Hex {
  return encodeFunctionData({abi: UNIVERSAL_ROUTER_ABI, functionName: "execute", args});
}

// ── Decoders: tests and the pre-submission self-check read the calldata back ──

export type DecodedSwapInput = {
  actions: Hex;
  swap: {
    poolKey: {currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address};
    zeroForOne: boolean;
    amountIn: bigint;
    amountOutMinimum: bigint;
    hookData: Hex;
  };
  settle: {currency: Address; amount: bigint};
  take: {currency: Address; amount: bigint};
};

export function decodeV4SwapInput(input: Hex): DecodedSwapInput {
  const [actions, params] = decodeAbiParameters(ACTIONS_AND_PARAMS, input);
  if (params.length !== 3) throw new Error("The swap does not carry exactly three actions.");
  const [swap] = decodeAbiParameters(EXACT_INPUT_SINGLE_PARAMS, params[0]);
  const [settleCurrency, settleAmount] = decodeAbiParameters(CURRENCY_AND_AMOUNT, params[1]);
  const [takeCurrency, takeAmount] = decodeAbiParameters(CURRENCY_AND_AMOUNT, params[2]);
  return {
    actions,
    swap,
    settle: {currency: settleCurrency, amount: settleAmount},
    take: {currency: takeCurrency, amount: takeAmount},
  };
}

export function decodePermit2PermitInput(input: Hex): SignedPermit {
  const [permit, signature] = decodeAbiParameters(PERMIT_SINGLE_AND_SIGNATURE, input);
  return {permit, signature};
}

export function decodeBuyCalldata(data: Hex): {commands: Hex; inputs: readonly Hex[]; deadline: bigint} {
  const decoded = decodeFunctionData({abi: UNIVERSAL_ROUTER_ABI, data});
  if (decoded.functionName !== "execute") throw new Error("Not a Universal Router execute call.");
  const [commands, inputs, deadline] = decoded.args;
  return {commands, inputs, deadline};
}

/**
 * Reads the built arguments back and refuses to continue unless they say exactly what the
 * buyer agreed to: this pool, zero for one, this amount, this minimum, this deadline and, when
 * present, a permit for this amount naming the router.
 */
export function assertBuyArgsMatch(
  args: BuyExecuteArgs,
  expected: {amountIn: bigint; amountOutMinimum: bigint; deadline: bigint; withPermit: boolean},
): void {
  const [commands, inputs, deadline] = args;
  const swapIndex = expected.withPermit ? 1 : 0;
  const fail = (what: string) => {
    throw new Error(`The prepared swap does not match the quote you reviewed (${what}); nothing was sent.`);
  };
  if (commands !== (expected.withPermit ? COMMANDS_PERMIT_THEN_SWAP : COMMANDS_SWAP_ONLY)) fail("commands");
  if (inputs.length !== swapIndex + 1) fail("inputs");
  if (deadline !== expected.deadline) fail("deadline");
  const swap = decodeV4SwapInput(inputs[swapIndex]);
  const key = swap.swap.poolKey;
  if (
    swap.actions !== BUY_ACTIONS ||
    key.currency0.toLowerCase() !== USDC.toLowerCase() ||
    key.currency1.toLowerCase() !== USDFR.toLowerCase() ||
    key.fee !== POOL_KEY.fee ||
    key.tickSpacing !== POOL_KEY.tickSpacing ||
    key.hooks.toLowerCase() !== POOL_KEY.hooks.toLowerCase() ||
    swap.swap.zeroForOne !== true ||
    swap.swap.hookData !== "0x"
  ) {
    fail("pool");
  }
  if (swap.swap.amountIn !== expected.amountIn || swap.settle.amount !== expected.amountIn) fail("amount");
  if (swap.settle.currency.toLowerCase() !== USDC.toLowerCase()) fail("input token");
  if (swap.take.currency.toLowerCase() !== USDFR.toLowerCase()) fail("output token");
  if (swap.swap.amountOutMinimum !== expected.amountOutMinimum || swap.take.amount !== expected.amountOutMinimum) {
    fail("minimum received");
  }
  if (expected.withPermit) {
    const {permit} = decodePermit2PermitInput(inputs[0]);
    try {
      assertPermitCoversBuy(permit, expected.amountIn, expected.deadline);
    } catch {
      fail("permit");
    }
    if (permit.details.amount !== expected.amountIn) fail("permit amount");
  }
}

// ── Revert decoding ───────────────────────────────────────────────────────

/**
 * Copy for the route's reverts. Keys are error names from SWAP_ROUTE_ERRORS, plus
 * "TRANSFER_FROM_FAILED", the string Permit2's token transfer reverts with when USDC cannot be
 * pulled from the buyer (balance or Permit2 approval too low).
 */
export const SWAP_ERROR_MESSAGES: Record<string, string> = {
  V4TooLittleReceived:
    "The price moved past your slippage limit, so this swap would return less than the minimum received. Refresh the quote or raise the slippage limit, then try again.",
  V4TooMuchRequested: "The pool asked for more USDC than this swap allows. Refresh the quote and try again.",
  TransactionDeadlinePassed:
    "The swap's 20-minute deadline passed before it could be included. Buy again to set a new deadline.",
  SignatureExpired: "The Permit2 signature expired before the swap was submitted. Buy again to sign a fresh one.",
  InvalidNonce: "That Permit2 signature was already used or replaced. Buy again to sign a fresh one.",
  InvalidSignature: "Permit2 did not accept the signature for this wallet. Buy again and sign with the connected wallet.",
  InvalidSigner: "Permit2 did not accept the signature for this wallet. Buy again and sign with the connected wallet.",
  InvalidSignatureLength:
    "Permit2 did not accept the signature for this wallet. Buy again and sign with the connected wallet.",
  InvalidContractSignature:
    "This smart-contract wallet did not validate the Permit2 signature. Buy again and approve the signature in the wallet.",
  AllowanceExpired: "This wallet's Permit2 allowance for the Uniswap router has expired. Buy again to sign a new one.",
  InsufficientAllowance:
    "This wallet's Permit2 allowance for the Uniswap router is below this amount. Buy again to sign a new one.",
  NotEnoughLiquidity: "The pool does not hold enough USDfr to fill this amount. Try a smaller amount.",
  PoolNotInitialized: "The Uniswap pool is not initialized, so it cannot quote or fill this swap.",
  USDfr_TransferNotAllowed:
    "This address cannot receive USDfr: it is jurisdiction-blocked, so USDfr refuses the pool's payment to it and the swap reverts.",
  EnforcedPause: "USDfr transfers are paused, so the pool cannot pay out USDfr right now. Try again once they resume.",
  PointsHook_InsufficientGas:
    "The transaction's gas limit was too low for USDfr's transfer bookkeeping. Try again; the app adds a margin to the estimate.",
  TRANSFER_FROM_FAILED:
    "The pool could not collect the USDC: this wallet's USDC balance, or its USDC approval for Permit2, is below the amount.",
};

const WRAPPERS = new Set(["WrappedError", "ExecutionFailed", "UnexpectedRevertBytes"]);

/** The raw revert bytes behind a viem error, wherever in the cause chain they sit. */
export function revertDataOf(err: unknown): Hex | undefined {
  if (!(err instanceof BaseError)) return undefined;
  const reverted = err.walk((e) => e instanceof ContractFunctionRevertedError);
  if (reverted instanceof ContractFunctionRevertedError && reverted.raw && reverted.raw !== "0x") {
    return reverted.raw;
  }
  const withData = err.walk((e) => {
    const data = (e as {data?: unknown}).data;
    const nested = typeof data === "object" && data !== null ? (data as {data?: unknown}).data : data;
    return typeof nested === "string" && /^0x[0-9a-fA-F]{8,}$/.test(nested);
  }) as {data?: unknown} | null;
  if (!withData) return undefined;
  const data = withData.data;
  const raw = typeof data === "object" && data !== null ? (data as {data?: unknown}).data : data;
  return typeof raw === "string" ? (raw as Hex) : undefined;
}

/**
 * Decodes raw revert bytes from the buy route into words, unwrapping the router's, the
 * PoolManager's and the quoter's wrappers. Returns null for bytes it cannot place, so the caller
 * can fall back to the generic decoder.
 */
export function describeSwapRevert(data: Hex, depth = 0): DecodedError | null {
  if (depth > 3) return null;
  let decoded: {errorName: string; args: readonly unknown[] | undefined};
  try {
    decoded = decodeErrorResult({abi: SWAP_ROUTE_ERRORS, data}) as typeof decoded;
  } catch {
    return null;
  }
  const {errorName, args = []} = decoded;
  if (WRAPPERS.has(errorName)) {
    const inner = (errorName === "WrappedError" ? args[2] : errorName === "ExecutionFailed" ? args[1] : args[0]) as Hex;
    const innerDecoded = describeSwapRevert(inner, depth + 1);
    if (innerDecoded) return innerDecoded;
    if (errorName === "WrappedError" && String(args[0]).toLowerCase() === USDFR.toLowerCase()) {
      return {message: "USDfr refused the pool's payment to this address, so the swap reverts.", errorName};
    }
    return {message: `The Uniswap route reverted (${errorName}).`, errorName};
  }
  if (errorName === "Error") {
    const reason = String(args[0] ?? "");
    return {message: SWAP_ERROR_MESSAGES[reason] ?? `The swap reverted: ${reason}`, errorName: reason || "Error"};
  }
  if (errorName === "Panic") return {message: "The swap reverted with an arithmetic panic.", errorName};
  return {message: SWAP_ERROR_MESSAGES[errorName] ?? `The Uniswap route reverted (${errorName}).`, errorName};
}

/** The Buy tab's decoder for the shared write flow: route reverts first, then the generic copy. */
export function decodeSwapError(err: unknown): DecodedError {
  const data = revertDataOf(err);
  const described = data ? describeSwapRevert(data) : null;
  return described ?? decodeWriteError(err);
}

/** Words for a quote that could not be fetched. */
export function describeQuoteFailure(err: unknown): string {
  const data = revertDataOf(err);
  const described = data ? describeSwapRevert(data) : null;
  if (described?.errorName === "NotEnoughLiquidity") return described.message;
  if (described) return `No quote: ${described.message}`;
  const short = err instanceof BaseError ? err.shortMessage : err instanceof Error ? err.message : "unknown error";
  return `No quote right now (${short}). It retries automatically.`;
}

export {PERMIT2, USDC, USDFR};
