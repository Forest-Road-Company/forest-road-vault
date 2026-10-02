import {existsSync, readdirSync, readFileSync} from "node:fs";
import {
  BaseError,
  ContractFunctionExecutionError,
  ContractFunctionRevertedError,
  RawContractError,
  UserRejectedRequestError,
  concat,
  decodeFunctionData,
  encodeAbiParameters,
  encodeErrorResult,
  encodeFunctionData,
  encodeFunctionResult,
  getAddress,
  hashTypedData,
  isAddress,
  keccak256,
  maxUint256,
  parseAbiParameters,
  sliceHex,
  toFunctionSelector,
  toHex,
  type Hex,
} from "viem";
import {describe, expect, it} from "vitest";

import {PERMIT2, POOL_KEY as SHARED_POOL_KEY, USDC, USDFR, V4_POOL_MANAGER, V4_STATE_VIEW} from "./uniswapV4Liquidity";
import {
  ACTION_SETTLE_ALL,
  ACTION_SWAP_EXACT_IN_SINGLE,
  ACTION_TAKE_ALL,
  COMMAND_PERMIT2_PERMIT,
  COMMAND_V4_SWAP,
  DEFAULT_SLIPPAGE_BPS,
  MAX_SLIPPAGE_BPS,
  MIN_SLIPPAGE_BPS,
  PERMIT2_APPROVAL_AMOUNT,
  SWAP_DEADLINE_SECONDS,
  SWAP_ERROR_MESSAGES,
  SWAP_ROUTE_ERRORS,
  UNIVERSAL_ROUTER,
  UNIVERSAL_ROUTER_ABI,
  V4_QUOTER,
  V4_QUOTER_ABI,
  assertBuyArgsMatch,
  buildBuyExecuteArgs,
  buildPermitSingle,
  buyRequest,
  buySwapFeePips,
  decodeBuyCalldata,
  decodePermit2PermitInput,
  decodeQuoteResult,
  decodeSwapError,
  decodeV4SwapInput,
  describeParity,
  describeQuoteFailure,
  describeSwapRevert,
  encodeBuyCalldata,
  encodeQuoteCall,
  encodeV4SwapInput,
  formatBpsPercent,
  formatPipsPercent,
  isBelowWarningFloor,
  minAmountOut,
  needsPermit,
  needsPermit2Approval,
  parityDeltaPpm,
  parseSlippagePercent,
  permit2ApprovalRequest,
  permitTypedData,
  priceE18,
  revertDataOf,
  swapDeadline,
  type BuyExecuteArgs,
  type SignedPermit,
} from "./uniswapV4Swap";

/**
 * The Buy tab's encoding. Every test decodes what the module built and compares it with the
 * value it was meant to carry, so a transposed argument, a flipped direction or a dropped
 * minimum fails here rather than on chain. `scripts/buy-usdfr.fork.test.ts` sends the same
 * bytes to the real pool on a mainnet fork.
 */

const USD = 10n ** 6n; // one USDC
const FR = 10n ** 18n; // one USDfr
const BUYER = "0x1111111111111111111111111111111111111111" as const;
const SIGNATURE = `0x${"ab".repeat(65)}` as Hex;
const DEADLINE = 1_790_883_395n;

function signedPermitFor(amount: bigint, deadline = DEADLINE, nonce = 7): SignedPermit {
  return {permit: buildPermitSingle({amount, nonce, deadline}), signature: SIGNATURE};
}

describe("route constants", () => {
  it("names Uniswap's mainnet Universal Router, V4Quoter and the shared pool contracts", () => {
    expect(UNIVERSAL_ROUTER.toLowerCase()).toBe("0x66a9893cc07d91d95644aedd05d03f95e1dba8af");
    expect(V4_QUOTER.toLowerCase()).toBe("0x52f0e24d1c21c8a0cb1e5a5dd6198556bd9e1203");
    expect(PERMIT2.toLowerCase()).toBe("0x000000000022d473030f116ddee9f6b43ac78ba3");
    expect(V4_POOL_MANAGER.toLowerCase()).toBe("0x000000000004444c5dc75cb358380d2e3de08a90");
  });

  it("spells every address so viem will call it: lowercase or the exact EIP-55 checksum", () => {
    // A mixed-case address with a wrong checksum is refused by viem at call time, which the
    // mainnet-fork run caught for the quoter before this test existed.
    for (const address of [UNIVERSAL_ROUTER, V4_QUOTER, PERMIT2, V4_POOL_MANAGER, USDC, USDFR, V4_STATE_VIEW]) {
      expect(isAddress(address, {strict: true}), address).toBe(true);
      if (address !== address.toLowerCase()) expect(getAddress(address)).toBe(address);
    }
  });

  it("uses the router 2.0.0 command bytes and the v4-periphery action bytes", () => {
    expect([COMMAND_PERMIT2_PERMIT, COMMAND_V4_SWAP]).toEqual([0x0a, 0x10]);
    expect([ACTION_SWAP_EXACT_IN_SINGLE, ACTION_SETTLE_ALL, ACTION_TAKE_ALL]).toEqual([0x06, 0x0c, 0x0f]);
  });

  it("encodes the execute(bytes,bytes[],uint256) overload, the one with a deadline", () => {
    expect(toFunctionSelector("function execute(bytes commands,bytes[] inputs,uint256 deadline)")).toBe("0x3593564c");
    expect(encodeBuyCalldata(buildBuyExecuteArgs({amountIn: USD, amountOutMinimum: FR / 2n, deadline: DEADLINE})).slice(0, 10)).toBe(
      "0x3593564c",
    );
  });
});

describe("quote calldata and parsing", () => {
  it("asks the quoter about the shared pool key, USDC in (zero for one), for the exact amount", () => {
    const data = encodeQuoteCall(1_234_567n);
    expect(data.slice(0, 10)).toBe(toFunctionSelector(V4_QUOTER_ABI[0]));
    const [params] = decodeAbiParametersFromCall(data);
    expect(params).toEqual({
      poolKey: {
        currency0: USDC,
        currency1: USDFR,
        fee: 375,
        tickSpacing: 4,
        hooks: "0x0000000000000000000000000000000000000000",
      },
      zeroForOne: true,
      exactAmount: 1_234_567n,
      hookData: "0x",
    });
  });

  it("parses the quoter's (amountOut, gasEstimate) return", () => {
    const data = encodeFunctionResult({
      abi: V4_QUOTER_ABI,
      functionName: "quoteExactInputSingle",
      result: [999_012_345_678_901_234_567n, 151_234n],
    });
    expect(decodeQuoteResult(1_000n * USD, data)).toEqual({
      amountIn: 1_000n * USD,
      amountOut: 999_012_345_678_901_234_567n,
      gasEstimate: 151_234n,
    });
  });

  it("refuses an empty, zero or malformed quote rather than showing it", () => {
    expect(() => decodeQuoteResult(USD, undefined)).toThrow("no data");
    expect(() => decodeQuoteResult(USD, "0x")).toThrow("no data");
    const zero = encodeFunctionResult({abi: V4_QUOTER_ABI, functionName: "quoteExactInputSingle", result: [0n, 1n]});
    expect(() => decodeQuoteResult(USD, zero)).toThrow("quoted no USDfr");
    expect(() => decodeQuoteResult(USD, "0x1234")).toThrow();
  });

  it("never quotes zero, which the router would read as the open delta", () => {
    expect(() => encodeQuoteCall(0n)).toThrow("greater than zero");
    expect(() => encodeQuoteCall(1n << 128n)).toThrow("too large");
    expect(() => encodeQuoteCall((1n << 128n) - 1n)).not.toThrow();
  });
});

describe("the V4_SWAP input", () => {
  it("decodes back to exactly SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL with the intended values", () => {
    const decoded = decodeV4SwapInput(encodeV4SwapInput(2_500n * USD, 2_487n * FR));
    expect(decoded.actions).toBe("0x060c0f");
    expect(decoded.swap).toEqual({
      poolKey: {
        currency0: USDC,
        currency1: USDFR,
        fee: 375,
        tickSpacing: 4,
        hooks: "0x0000000000000000000000000000000000000000",
      },
      zeroForOne: true,
      amountIn: 2_500n * USD,
      amountOutMinimum: 2_487n * FR,
      hookData: "0x",
    });
    expect(decoded.settle).toEqual({currency: USDC, amount: 2_500n * USD});
    expect(decoded.take).toEqual({currency: USDFR, amount: 2_487n * FR});
  });

  it("reuses the shared pool key rather than a copy of it", () => {
    expect(decodeV4SwapInput(encodeV4SwapInput(USD, FR / 2n)).swap.poolKey).toEqual(SHARED_POOL_KEY);
  });
});

describe("execute arguments", () => {
  it("is one V4_SWAP command when the router already holds a Permit2 allowance", () => {
    const args = buildBuyExecuteArgs({amountIn: 10n * USD, amountOutMinimum: 9n * FR, deadline: DEADLINE});
    const decoded = decodeBuyCalldata(encodeBuyCalldata(args));
    expect(decoded.commands).toBe("0x10");
    expect(decoded.inputs).toHaveLength(1);
    expect(decoded.deadline).toBe(DEADLINE);
    const swap = decodeV4SwapInput(decoded.inputs[0]);
    expect(swap.swap.amountIn).toBe(10n * USD);
    expect(swap.swap.amountOutMinimum).toBe(9n * FR);
    expect(swap.take.amount).toBe(9n * FR);
  });

  it("puts PERMIT2_PERMIT first, carrying the exact permit and signature, when one is signed", () => {
    const signed = signedPermitFor(10n * USD);
    const args = buildBuyExecuteArgs({amountIn: 10n * USD, amountOutMinimum: 9n * FR, deadline: DEADLINE, signedPermit: signed});
    const decoded = decodeBuyCalldata(encodeBuyCalldata(args));
    expect(decoded.commands).toBe("0x0a10");
    expect(decoded.inputs).toHaveLength(2);
    expect(decoded.deadline).toBe(DEADLINE);
    expect(decodePermit2PermitInput(decoded.inputs[0])).toEqual({
      permit: {
        details: {token: USDC, amount: 10n * USD, expiration: Number(DEADLINE), nonce: 7},
        spender: UNIVERSAL_ROUTER,
        sigDeadline: DEADLINE,
      },
      signature: SIGNATURE,
    });
    expect(decodeV4SwapInput(decoded.inputs[1]).swap.amountIn).toBe(10n * USD);
  });

  it("lays the PERMIT2_PERMIT input out as the router reads it: six static words, then the signature offset", () => {
    const [, inputs] = buildBuyExecuteArgs({
      amountIn: USD,
      amountOutMinimum: FR / 2n,
      deadline: DEADLINE,
      signedPermit: signedPermitFor(USD),
    });
    const word = (index: number) => BigInt(sliceHex(inputs[0], index * 32, (index + 1) * 32));
    expect(word(0)).toBe(BigInt(USDC));
    expect(word(1)).toBe(USD);
    expect(word(2)).toBe(DEADLINE);
    expect(word(3)).toBe(7n);
    expect(word(4)).toBe(BigInt(UNIVERSAL_ROUTER));
    expect(word(5)).toBe(DEADLINE);
    expect(word(6)).toBe(0xe0n); // inputs.toBytes(6): the offset of `bytes signature`
    expect(word(7)).toBe(65n);
  });

  it("hands the shared write flow the router, its ABI, execute and these exact arguments", () => {
    const args = buildBuyExecuteArgs({amountIn: USD, amountOutMinimum: FR / 2n, deadline: DEADLINE});
    expect(buyRequest(args)).toEqual({address: UNIVERSAL_ROUTER, abi: UNIVERSAL_ROUTER_ABI, functionName: "execute", args});
  });

  it("fails closed on a zero, oversized or unprotected trade", () => {
    const base = {amountIn: USD, amountOutMinimum: FR / 2n, deadline: DEADLINE};
    expect(() => buildBuyExecuteArgs({...base, amountIn: 0n})).toThrow("greater than zero");
    expect(() => buildBuyExecuteArgs({...base, amountIn: 1n << 128n})).toThrow("too large");
    expect(() => buildBuyExecuteArgs({...base, amountOutMinimum: 0n})).toThrow("positive minimum");
    expect(() => buildBuyExecuteArgs({...base, amountOutMinimum: 1n << 128n})).toThrow("positive minimum");
    expect(() => buildBuyExecuteArgs({...base, deadline: 0n})).toThrow("deadline");
  });

  it("refuses a permit that would not pay for this exact buy", () => {
    const base = {amountIn: 10n * USD, amountOutMinimum: 9n * FR, deadline: DEADLINE};
    const permit = signedPermitFor(10n * USD).permit;
    const variants: Array<[string, SignedPermit["permit"]]> = [
      ["not for USDC", {...permit, details: {...permit.details, token: USDFR}}],
      ["does not name the Uniswap router", {...permit, spender: BUYER}],
      ["does not cover the amount", {...permit, details: {...permit.details, amount: 10n * USD - 1n}}],
      ["lapse before the swap deadline", {...permit, sigDeadline: DEADLINE - 1n}],
      ["lapse before the swap deadline", {...permit, details: {...permit.details, expiration: Number(DEADLINE) - 1}}],
    ];
    for (const [message, bad] of variants) {
      expect(() => buildBuyExecuteArgs({...base, signedPermit: {permit: bad, signature: SIGNATURE}})).toThrow(message);
    }
  });
});

describe("the pre-submission self-check", () => {
  const expected = {amountIn: 10n * USD, amountOutMinimum: 9n * FR, deadline: DEADLINE};

  it("accepts the arguments the module built, with and without a permit", () => {
    expect(() =>
      assertBuyArgsMatch(buildBuyExecuteArgs(expected), {...expected, withPermit: false}),
    ).not.toThrow();
    expect(() =>
      assertBuyArgsMatch(buildBuyExecuteArgs({...expected, signedPermit: signedPermitFor(10n * USD)}), {
        ...expected,
        withPermit: true,
      }),
    ).not.toThrow();
  });

  it("refuses arguments that differ from what the buyer reviewed", () => {
    const built = buildBuyExecuteArgs(expected);
    const withPermit = buildBuyExecuteArgs({...expected, signedPermit: signedPermitFor(10n * USD)});
    const cases: Array<[BuyExecuteArgs, Parameters<typeof assertBuyArgsMatch>[1], string]> = [
      [built, {...expected, withPermit: true}, "commands"],
      [built, {...expected, amountOutMinimum: 9n * FR + 1n, withPermit: false}, "minimum received"],
      [built, {...expected, amountIn: 10n * USD + 1n, withPermit: false}, "amount"],
      [built, {...expected, deadline: DEADLINE + 1n, withPermit: false}, "deadline"],
      [[built[0], [built[1][0], built[1][0]], built[2]], {...expected, withPermit: false}, "inputs"],
      [
        buildBuyExecuteArgs({...expected, signedPermit: signedPermitFor(11n * USD)}),
        {...expected, withPermit: true},
        "permit amount",
      ],
      [withPermit, {...expected, deadline: DEADLINE + 1n, withPermit: true}, "deadline"],
    ];
    for (const [args, wanted, what] of cases) {
      expect(() => assertBuyArgsMatch(args, wanted)).toThrow(`(${what})`);
    }
  });
});

describe("slippage", () => {
  it("defaults to 0.05% and is bounded to 0.05% through 3%", () => {
    expect([DEFAULT_SLIPPAGE_BPS, MIN_SLIPPAGE_BPS, MAX_SLIPPAGE_BPS]).toEqual([5n, 5n, 300n]);
  });

  it("takes the minimum as the quote less the limit, rounded down, at both edges", () => {
    expect(minAmountOut(1_000_000n, 50n)).toBe(995_000n);
    expect(minAmountOut(1_000_000n, 5n)).toBe(999_500n);
    expect(minAmountOut(1_000_000n, 300n)).toBe(970_000n);
    // 999,999 x 9,950 / 10,000 = 994,999.005: rounded down, never up.
    expect(minAmountOut(999_999n, 50n)).toBe(994_999n);
    expect(minAmountOut(999n * FR, 50n)).toBe(994_005n * 10n ** 15n);
  });

  it("refuses a limit just outside the bounds and a zero quote", () => {
    expect(() => minAmountOut(1_000_000n, 4n)).toThrow("between 0.05% and 3%");
    expect(() => minAmountOut(1_000_000n, 301n)).toThrow("between 0.05% and 3%");
    expect(() => minAmountOut(0n, 50n)).toThrow("positive quote");
  });

  it("parses typed percentages exactly, with no floating point", () => {
    const ok = (text: string) => {
      const parsed = parseSlippagePercent(text);
      return parsed.ok ? parsed.bps : null;
    };
    expect(ok("0.5")).toBe(50n);
    expect(ok(".5")).toBe(50n);
    expect(ok("0.05")).toBe(5n);
    expect(ok("3")).toBe(300n);
    expect(ok("3.00")).toBe(300n);
    expect(ok(" 1.25 ")).toBe(125n);
    expect(ok("0.04")).toBeNull();
    expect(ok("3.01")).toBeNull();
    expect(ok("0.055")).toBeNull();
    expect(ok("")).toBeNull();
    expect(ok(".")).toBeNull();
    expect(ok("-1")).toBeNull();
    expect(ok("1e1")).toBeNull();
    expect(ok("abc")).toBeNull();
    expect(parseSlippagePercent("0.055")).toEqual({ok: false, message: "Use at most two decimal places, for example 0.05."});
    expect(parseSlippagePercent("5")).toEqual({ok: false, message: "Slippage must be between 0.05% and 3%."});
  });

  it("formats basis points and fee pips as percentages", () => {
    expect(formatBpsPercent(50n)).toBe("0.5%");
    expect(formatBpsPercent(5n)).toBe("0.05%");
    expect(formatBpsPercent(300n)).toBe("3%");
    expect(formatPipsPercent(375n)).toBe("0.0375%");
    expect(formatPipsPercent(100n)).toBe("0.01%");
    expect(formatPipsPercent(475n)).toBe("0.0475%");
    expect(formatPipsPercent(0n)).toBe("0%");
  });
});

describe("price, parity and the 0.99 warning", () => {
  it("states the price as USDfr per USDC, rounded down", () => {
    expect(priceE18(1_000n * USD, 999_012n * 10n ** 15n)).toBe(999_012_000_000_000_000n);
    expect(priceE18(3n * USD, 2n * FR)).toBe(666_666_666_666_666_666n);
  });

  it("describes the distance from 1:1 in both directions", () => {
    expect(describeParity(1_000n * USD, 999_012n * 10n ** 15n)).toBe("0.0988% below 1:1");
    expect(describeParity(1_000n * USD, 1_000_125n * 10n ** 15n)).toBe("0.0125% above 1:1");
    expect(describeParity(1_000n * USD, 1_000n * FR)).toBe("exactly 1:1");
    expect(parityDeltaPpm(USD, 99n * 10n ** 16n)).toBe(-10_000n);
  });

  it("warns strictly below 0.99 USDfr per USDC and not at it", () => {
    const amountIn = 1_000n * USD;
    const atFloor = 990n * FR;
    expect(isBelowWarningFloor(amountIn, atFloor)).toBe(false);
    expect(isBelowWarningFloor(amountIn, atFloor - 1n)).toBe(true);
    expect(isBelowWarningFloor(amountIn, 999n * FR)).toBe(false);
    expect(isBelowWarningFloor(1n, 990_000_000_000n)).toBe(false);
    expect(isBelowWarningFloor(1n, 989_999_999_999n)).toBe(true);
  });

  it("combines the LP fee with Uniswap's zero-for-one protocol fee as v4-core does", () => {
    // Mainnet slot0 on 1 October 2026: lpFee 375, protocolFee 409,700 (100 pips each way).
    expect(buySwapFeePips(375, 409_700)).toEqual({lpFee: 375n, protocolFee: 100n, total: 475n});
    expect(buySwapFeePips(375, 0)).toEqual({lpFee: 375n, protocolFee: 0n, total: 375n});
    // Only the low 12 bits apply to zero for one.
    expect(buySwapFeePips(375, 200 << 12)).toEqual({lpFee: 375n, protocolFee: 0n, total: 375n});
    // calculateSwapFee: 1,000 + 3,000 - 1,000 x 3,000 / 1,000,000 = 3,997.
    expect(buySwapFeePips(3_000, 1_000).total).toBe(3_997n);
  });
});

describe("Permit2", () => {
  it("approves Permit2 once, for the maximum, as Uniswap's own app does", () => {
    expect(PERMIT2_APPROVAL_AMOUNT).toBe(maxUint256);
    const request = permit2ApprovalRequest();
    expect(request.address).toBe(USDC);
    expect(request.functionName).toBe("approve");
    expect(request.args).toEqual([PERMIT2, maxUint256]);
    // The bytes a wallet is asked to sign: approve(Permit2, 2^256 - 1) on USDC.
    const decoded = decodeFunctionData({
      abi: request.abi,
      data: encodeFunctionData({abi: request.abi, functionName: request.functionName, args: request.args}),
    });
    expect(decoded.functionName).toBe("approve");
    expect(decoded.args).toEqual([PERMIT2, (1n << 256n) - 1n]);
  });

  it("asks for that approval only while USDC's allowance to Permit2 is short of the amount", () => {
    expect(needsPermit2Approval(0n, 1n)).toBe(true);
    expect(needsPermit2Approval(10n * USD - 1n, 10n * USD)).toBe(true);
    expect(needsPermit2Approval(10n * USD, 10n * USD)).toBe(false);
    // USDC decrements even a maximum allowance; what is left after a first buy covers any later one.
    expect(needsPermit2Approval(maxUint256 - 1_000n * USD, 5_000_000n * USD)).toBe(false);
  });

  it("sets the deadline twenty minutes after the block the swap was prepared against", () => {
    expect(SWAP_DEADLINE_SECONDS).toBe(1_200n);
    expect(swapDeadline(1_790_882_195n)).toBe(1_790_883_395n);
    expect(() => swapDeadline(0n)).toThrow("timestamp");
  });

  it("reuses a router allowance only when it covers the amount until the deadline", () => {
    const allowance = {amount: 10n * USD, expiration: Number(DEADLINE), nonce: 3};
    expect(needsPermit(allowance, 10n * USD, DEADLINE)).toBe(false);
    expect(needsPermit({...allowance, amount: (1n << 160n) - 1n}, 10n * USD, DEADLINE)).toBe(false);
    expect(needsPermit(allowance, 10n * USD + 1n, DEADLINE)).toBe(true);
    expect(needsPermit({...allowance, expiration: Number(DEADLINE) - 1}, 10n * USD, DEADLINE)).toBe(true);
    expect(needsPermit({amount: 0n, expiration: 0, nonce: 0}, USD, DEADLINE)).toBe(true);
  });

  it("builds a PermitSingle for exactly the amount, naming the router, lapsing at the deadline", () => {
    expect(buildPermitSingle({amount: 25n * USD, nonce: 4, deadline: DEADLINE})).toEqual({
      details: {token: USDC, amount: 25n * USD, expiration: Number(DEADLINE), nonce: 4},
      spender: UNIVERSAL_ROUTER,
      sigDeadline: DEADLINE,
    });
    expect(() => buildPermitSingle({amount: 0n, nonce: 0, deadline: DEADLINE})).toThrow();
    expect(() => buildPermitSingle({amount: USD, nonce: -1, deadline: DEADLINE})).toThrow("nonce");
    expect(() => buildPermitSingle({amount: USD, nonce: 0, deadline: 1n << 48n})).toThrow("deadline");
  });

  it("signs the digest Permit2 itself computes, under its on-chain domain separator", () => {
    const permit = buildPermitSingle({amount: 1_234n * USD, nonce: 9, deadline: DEADLINE});
    // Permit2 PermitHash.hash and EIP712._hashTypedData, by hand.
    const detailsTypehash = keccak256(toHex("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"));
    const singleTypehash = keccak256(
      toHex(
        "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)",
      ),
    );
    const detailsHash = keccak256(
      encodeAbiParameters(parseAbiParameters("bytes32,address,uint160,uint48,uint48"), [
        detailsTypehash,
        USDC,
        1_234n * USD,
        Number(DEADLINE),
        9,
      ]),
    );
    const structHash = keccak256(
      encodeAbiParameters(parseAbiParameters("bytes32,bytes32,address,uint256"), [
        singleTypehash,
        detailsHash,
        UNIVERSAL_ROUTER,
        DEADLINE,
      ]),
    );
    // Read from Permit2.DOMAIN_SEPARATOR() on mainnet, 1 October 2026.
    const domainSeparator = "0x866a5aba21966af95d6c7ab78eb2b2fc913915c28be3b9aa07cc04ff903e3f28";
    expect(hashTypedData(permitTypedData(permit))).toBe(keccak256(concat(["0x1901", domainSeparator, structHash])));
  });
});

describe("revert decoding", () => {
  const raw = (errorName: string, args: readonly unknown[] = []) =>
    encodeErrorResult({abi: SWAP_ROUTE_ERRORS, errorName, args} as never);
  const stringRevert = (reason: string) =>
    encodeErrorResult({
      abi: [{type: "error", name: "Error", inputs: [{name: "message", type: "string"}]}],
      errorName: "Error",
      args: [reason],
    });

  it("says slippage, deadline, Permit2 and allowance failures in words", () => {
    expect(describeSwapRevert(raw("V4TooLittleReceived", [9n * FR, 8n * FR]))).toEqual({
      message: SWAP_ERROR_MESSAGES.V4TooLittleReceived,
      errorName: "V4TooLittleReceived",
    });
    expect(describeSwapRevert(raw("TransactionDeadlinePassed"))?.message).toContain("deadline passed");
    expect(describeSwapRevert(raw("AllowanceExpired", [1n]))?.message).toContain("expired");
    expect(describeSwapRevert(raw("InsufficientAllowance", [1n]))?.message).toContain("below this amount");
    expect(describeSwapRevert(stringRevert("TRANSFER_FROM_FAILED"))).toEqual({
      message: SWAP_ERROR_MESSAGES.TRANSFER_FROM_FAILED,
      errorName: "TRANSFER_FROM_FAILED",
    });
  });

  it("unwraps a failed PERMIT2_PERMIT from the router's ExecutionFailed", () => {
    expect(describeSwapRevert(raw("ExecutionFailed", [0n, raw("InvalidNonce")]))).toEqual({
      message: SWAP_ERROR_MESSAGES.InvalidNonce,
      errorName: "InvalidNonce",
    });
    expect(describeSwapRevert(raw("ExecutionFailed", [0n, raw("SignatureExpired", [5n])]))?.errorName).toBe(
      "SignatureExpired",
    );
  });

  it("unwraps the PoolManager's WrappedError around USDfr refusing a jurisdiction-blocked buyer", () => {
    const blocked = raw("WrappedError", [
      USDFR,
      "0xa9059cbb",
      raw("USDfr_TransferNotAllowed", [V4_POOL_MANAGER, BUYER]),
      raw("ERC20TransferFailed"),
    ]);
    const decoded = describeSwapRevert(blocked);
    expect(decoded?.errorName).toBe("USDfr_TransferNotAllowed");
    expect(decoded?.message).toContain("jurisdiction-blocked");
    // Bytes the route cannot place still say which transfer failed.
    const unknownInner = raw("WrappedError", [USDFR, "0xa9059cbb", "0xdeadbeef", raw("ERC20TransferFailed")]);
    expect(describeSwapRevert(unknownInner)?.message).toBe("USDfr refused the pool's payment to this address, so the swap reverts.");
  });

  it("unwraps the quoter's UnexpectedRevertBytes around NotEnoughLiquidity", () => {
    const pool = "0x72ef9130b1c7bd2daa49405e618b7ad27eb90e03c893629ba1d28a4562fc7b55";
    const data = raw("UnexpectedRevertBytes", [raw("NotEnoughLiquidity", [pool])]);
    expect(describeSwapRevert(data)?.errorName).toBe("NotEnoughLiquidity");
    const err = new BaseError("eth_call reverted", {cause: new RawContractError({data})});
    expect(describeQuoteFailure(err)).toBe(SWAP_ERROR_MESSAGES.NotEnoughLiquidity);
    expect(describeQuoteFailure(new Error("fetch failed"))).toContain("fetch failed");
  });

  it("finds the revert bytes in viem's simulation and eth_call errors", () => {
    const data = raw("V4TooLittleReceived", [2n, 1n]);
    const simulated = new ContractFunctionExecutionError(
      new ContractFunctionRevertedError({abi: UNIVERSAL_ROUTER_ABI, data, functionName: "execute"}),
      {abi: UNIVERSAL_ROUTER_ABI, args: [], contractAddress: UNIVERSAL_ROUTER, functionName: "execute"},
    );
    expect(revertDataOf(simulated)).toBe(data);
    expect(decodeSwapError(simulated).errorName).toBe("V4TooLittleReceived");
    const nested = new BaseError("call failed", {cause: new RawContractError({data: {data} as never})});
    expect(revertDataOf(nested)).toBe(data);
    expect(revertDataOf(new Error("plain"))).toBeUndefined();
  });

  it("falls back to the shared decoder for wallet rejections and unplaceable bytes", () => {
    const rejected = new UserRejectedRequestError(new Error("User denied"));
    expect(decodeSwapError(rejected)).toEqual({message: rejected.shortMessage, errorName: null});
    expect(describeSwapRevert("0xdeadbeef")).toBeNull();
    expect(decodeSwapError(new Error("The prepared swap does not match"))).toEqual({
      message: "The prepared swap does not match",
      errorName: null,
    });
  });

  it("has copy only for errors the route's ABI can decode", () => {
    const names = new Set(SWAP_ROUTE_ERRORS.map((error) => error.name));
    for (const key of Object.keys(SWAP_ERROR_MESSAGES)) {
      if (key === "TRANSFER_FROM_FAILED") continue; // Permit2's string revert, decoded as Error(string)
      expect(names.has(key as never), `${key} is decodable`).toBe(true);
    }
    // Every error the route decodes is also in the router ABI handed to the write flow.
    const routerErrors = new Set(UNIVERSAL_ROUTER_ABI.filter((item) => item.type === "error").map((item) => item.name));
    for (const name of names) expect(routerErrors.has(name), `${name} in the router ABI`).toBe(true);
  });

  it("names only protocol errors that contracts/src still declares", () => {
    const src = new URL("../../../contracts/src/", import.meta.url);
    if (!existsSync(src)) return; // the frontend-only public repository has no contract tier
    const sources: string[] = [];
    const walk = (dir: URL) => {
      for (const entry of readdirSync(dir, {withFileTypes: true})) {
        const next = new URL(entry.name + (entry.isDirectory() ? "/" : ""), dir);
        if (entry.isDirectory()) walk(next);
        else if (entry.name.endsWith(".sol")) sources.push(readFileSync(next, "utf8"));
      }
    };
    walk(src);
    const solidity = sources.join("\n");
    const protocolErrors = SWAP_ROUTE_ERRORS.filter((error) => error.name.includes("_"));
    expect(protocolErrors.map((error) => error.name)).toEqual(["USDfr_TransferNotAllowed", "PointsHook_InsufficientGas"]);
    for (const error of protocolErrors) {
      const signature = `error ${error.name}(${error.inputs.map((input) => `${input.type} ${input.name}`).join(", ")});`;
      expect(solidity, signature).toContain(signature);
    }
  });
});

/** The arguments of a quoter call, read back from its calldata. */
function decodeAbiParametersFromCall(data: Hex) {
  return decodeFunctionData({abi: V4_QUOTER_ABI, data}).args;
}
