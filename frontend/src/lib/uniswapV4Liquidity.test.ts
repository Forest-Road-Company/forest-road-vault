import {
  encodeAbiParameters,
  encodeEventTopics,
  keccak256,
  parseAbi,
  parseAbiParameters,
  pad,
  toHex,
  type Address,
  type Hex,
} from "viem";
import {describe, expect, it} from "vitest";

import {
  LIQUIDITY_OPERATOR,
  POOL_ID,
  TARGET_TOTAL_LIQUIDITY,
  TARGET_USDC_MAX,
  TARGET_USDFR_MAX,
  TICK_LOWER,
  TICK_UPPER,
  USDC,
  USDFR,
  V4_POOL_MANAGER,
  V4_POSITION_MANAGER,
  amount0Delta,
  amount1Delta,
  buildPilotPlan,
  buildRemainderPlan,
  encodeLiquidityTransaction,
  sqrtPriceAtTick,
  verifyMintReceipt,
  type LiquidityPlan,
  type ReceiptLog,
} from "./uniswapV4Liquidity";

const LIVE_SQRT_PRICE = 79_208_251_071_293_499_848_715_422_927_884_420n;
const TRANSFER_ABI = parseAbi([
  "event Transfer(address indexed from,address indexed to,uint256 value)",
]);
const MODIFY_ABI = parseAbi([
  "event ModifyLiquidity(bytes32 indexed id,address indexed sender,int24 tickLower,int24 tickUpper,int256 liquidityDelta,bytes32 salt)",
]);
const ZERO = "0x0000000000000000000000000000000000000000" as Address;

function transferLog(
  token: Address,
  from: Address,
  to: Address,
  amount: bigint,
): ReceiptLog {
  return {
    address: token,
    topics: encodeEventTopics({
      abi: TRANSFER_ABI,
      eventName: "Transfer",
      args: {from, to},
    }) as unknown as readonly [Hex, ...Hex[]],
    data: encodeAbiParameters(parseAbiParameters("uint256"), [amount]),
  };
}

function mintLog(owner: Address, tokenId: bigint): ReceiptLog {
  return {
    address: V4_POSITION_MANAGER,
    topics: [
      keccak256(toHex("Transfer(address,address,uint256)")),
      pad(ZERO, {size: 32}),
      pad(owner, {size: 32}),
      pad(toHex(tokenId), {size: 32}),
    ],
    data: "0x",
  };
}

function modifyLog(liquidity: bigint): ReceiptLog {
  return {
    address: V4_POOL_MANAGER,
    topics: encodeEventTopics({
      abi: MODIFY_ABI,
      eventName: "ModifyLiquidity",
      args: {id: POOL_ID, sender: V4_POSITION_MANAGER},
    }) as unknown as readonly [Hex, ...Hex[]],
    data: encodeAbiParameters(
      parseAbiParameters(
        "int24 tickLower,int24 tickUpper,int256 liquidityDelta,bytes32 salt",
      ),
      [TICK_LOWER, TICK_UPPER, liquidity, pad(toHex(77n), {size: 32})],
    ),
  };
}

describe("the owner-reviewed Uniswap v4 route", () => {
  it("derives the exact approved pool id and TickMath bounds", () => {
    expect(POOL_ID).toBe(
      "0x72ef9130b1c7bd2daa49405e618b7ad27eb90e03c893629ba1d28a4562fc7b55",
    );
    expect(sqrtPriceAtTick(TICK_LOWER)).toBe(
      78_064_174_697_979_964_190_878_680_004_814_636n,
    );
    expect(sqrtPriceAtTick(TICK_UPPER)).toBe(
      79_402_542_647_539_943_191_954_697_886_570_481n,
    );
  });

  it("caps the pilot at 50 USDC and selects the largest safe liquidity", () => {
    const plan = buildPilotPlan(LIVE_SQRT_PRICE);
    expect(plan.expectedUsdc).toBe(50_000_000n);
    expect(plan.expectedUsdfr).toBe(294_996_399_953_492_718_152n);
    expect(plan.maxUsdc).toBe(50_000_000n);
    expect(plan.maxUsdfr).toBe(345_093_855_744_831_734_997n);

    const upper = sqrtPriceAtTick(TICK_UPPER);
    expect(
      amount0Delta(plan.liquidity + 1n, LIVE_SQRT_PRICE, upper),
    ).toBeGreaterThan(50_000_000n);
  });

  it("makes the second position the exact remainder of the original target", () => {
    const pilot = buildPilotPlan(LIVE_SQRT_PRICE);
    const remainder = buildRemainderPlan(LIVE_SQRT_PRICE, {
      liquidity: pilot.liquidity,
      usdcSpent: pilot.expectedUsdc,
      usdfrSpent: pilot.expectedUsdfr,
    });
    expect(pilot.liquidity + remainder.liquidity).toBe(
      TARGET_TOTAL_LIQUIDITY,
    );
    expect(remainder.maxUsdc + pilot.expectedUsdc).toBe(TARGET_USDC_MAX);
    expect(remainder.maxUsdfr + pilot.expectedUsdfr).toBe(TARGET_USDFR_MAX);
    expect(remainder.expectedUsdc).toBeLessThanOrEqual(remainder.maxUsdc);
    expect(remainder.expectedUsdfr).toBeLessThanOrEqual(remainder.maxUsdfr);
  });

  it("reconstructs the failed transaction byte-for-byte from its reviewed terms", () => {
    const maxUint160 = (1n << 160n) - 1n;
    const originalPlan: LiquidityPlan = {
      liquidity: TARGET_TOTAL_LIQUIDITY,
      expectedUsdc: 0n,
      expectedUsdfr: 0n,
      maxUsdc: TARGET_USDC_MAX,
      maxUsdfr: TARGET_USDFR_MAX,
    };
    const encoded = encodeLiquidityTransaction({
      owner: LIQUIDITY_OPERATOR,
      plan: originalPlan,
      permit: {
        details: [
          {
            token: USDC,
            amount: maxUint160,
            expiration: 1_792_928_192,
            nonce: 0,
          },
          {
            token: USDFR,
            amount: maxUint160,
            expiration: 1_792_928_192,
            nonce: 0,
          },
        ],
        spender: V4_POSITION_MANAGER,
        sigDeadline: 1_790_337_992n,
      },
      signature:
        "0x0b00db3e7e2b9b3b56548e6861a0a9c9c80e5f300634e08d60b0e0beb948393f6f53ece7ca0949cf05d1f252bce5b886e14104829772b42bf656e09f98e00f401b",
      liquidityDeadline: 1_790_338_069n,
    });
    expect(encoded.length).toBe(3_466);
    expect(keccak256(encoded)).toBe(
      "0x44fd9541ca49e03c27683142f008821f165eb0d238c292f6b98ac0d0005e80e3",
    );
  });

  it("accepts only a receipt proving the exact mint and both token spends", () => {
    const liquidity = 123_456n;
    const logs = [
      mintLog(LIQUIDITY_OPERATOR, 77n),
      modifyLog(liquidity),
      transferLog(USDC, LIQUIDITY_OPERATOR, V4_POOL_MANAGER, 50_000_000n),
      transferLog(
        USDFR,
        LIQUIDITY_OPERATOR,
        V4_POOL_MANAGER,
        295n * 10n ** 18n,
      ),
    ];
    expect(
      verifyMintReceipt({
        logs,
        owner: LIQUIDITY_OPERATOR,
        expectedLiquidity: liquidity,
      }),
    ).toEqual({
      tokenId: 77n,
      usdcSpent: 50_000_000n,
      usdfrSpent: 295n * 10n ** 18n,
    });
    expect(() =>
      verifyMintReceipt({
        logs,
        owner: LIQUIDITY_OPERATOR,
        expectedLiquidity: liquidity + 1n,
      }),
    ).toThrow(/exact approved liquidity/i);
  });

  it("uses the full-range maxima expected by the reviewed transaction", () => {
    const lower = sqrtPriceAtTick(TICK_LOWER);
    const upper = sqrtPriceAtTick(TICK_UPPER);
    expect(amount1Delta(TARGET_TOTAL_LIQUIDITY, lower, upper)).toBe(
      TARGET_USDFR_MAX,
    );
  });
});
