import {
  decodeFunctionData,
  encodeAbiParameters,
  encodeEventTopics,
  keccak256,
  pad,
  parseAbi,
  parseAbiParameters,
  toHex,
  type Address,
  type Hex,
} from "viem";
import {describe, expect, it} from "vitest";

import {LIQUIDITY_OPERATOR, USDC, V4_POOL_MANAGER, V4_POSITION_MANAGER, sqrtPriceAtTick} from "./uniswapV4Liquidity";
import {
  SEED_TICK_LOWER,
  SEED_TICK_UPPER,
  SEED_USDC_CAP,
  SUSDFR,
  SUSDFR_INITIAL_SQRT_PRICE_X96,
  SUSDFR_INITIAL_TICK,
  SUSDFR_POOL_ID,
  SUSDFR_POSITION_MANAGER_ABI,
  TOTAL_USDC_CAP,
  WALL_TICK_LOWER,
  WALL_TICK_UPPER,
  buildSusdfrPermitBatchMessage,
  buildSusdfrSeedPlan,
  buildSusdfrWallPlan,
  encodeSusdfrLiquidityTransaction,
  usdcPerSusdfrAtTick,
  verifySusdfrMintReceipt,
  type SusdfrLiquidityPlan,
  type SusdfrReceiptLog,
} from "./uniswapV4SusdfrLiquidity";

const ZERO = "0x0000000000000000000000000000000000000000" as Address;
const TRANSFER_ABI = parseAbi([
  "event Transfer(address indexed from,address indexed to,uint256 value)",
]);
const POOL_EVENTS = parseAbi([
  "event Initialize(bytes32 indexed id,address indexed currency0,address indexed currency1,uint24 fee,int24 tickSpacing,address hooks,uint160 sqrtPriceX96,int24 tick)",
  "event ModifyLiquidity(bytes32 indexed id,address indexed sender,int24 tickLower,int24 tickUpper,int256 liquidityDelta,bytes32 salt)",
]);

function transferLog(
  token: Address,
  amount: bigint,
  recipient: Address = V4_POOL_MANAGER,
): SusdfrReceiptLog {
  return {
    address: token,
    topics: encodeEventTopics({
      abi: TRANSFER_ABI,
      eventName: "Transfer",
      args: {from: LIQUIDITY_OPERATOR, to: recipient},
    }) as unknown as readonly [Hex, ...Hex[]],
    data: encodeAbiParameters(parseAbiParameters("uint256"), [amount]),
  };
}

function mintLog(tokenId: bigint): SusdfrReceiptLog {
  return {
    address: V4_POSITION_MANAGER,
    topics: [
      keccak256(toHex("Transfer(address,address,uint256)")),
      pad(ZERO, {size: 32}),
      pad(LIQUIDITY_OPERATOR, {size: 32}),
      pad(toHex(tokenId), {size: 32}),
    ],
    data: "0x",
  };
}

function modifyLog(plan: SusdfrLiquidityPlan): SusdfrReceiptLog {
  return {
    address: V4_POOL_MANAGER,
    topics: encodeEventTopics({
      abi: POOL_EVENTS,
      eventName: "ModifyLiquidity",
      args: {id: SUSDFR_POOL_ID, sender: V4_POSITION_MANAGER},
    }) as unknown as readonly [Hex, ...Hex[]],
    data: encodeAbiParameters(
      parseAbiParameters(
        "int24 tickLower,int24 tickUpper,int256 liquidityDelta,bytes32 salt",
      ),
      [plan.tickLower, plan.tickUpper, plan.liquidity, pad(toHex(1n), {size: 32})],
    ),
  };
}

function initializeLog(): SusdfrReceiptLog {
  return {
    address: V4_POOL_MANAGER,
    topics: encodeEventTopics({
      abi: POOL_EVENTS,
      eventName: "Initialize",
      args: {id: SUSDFR_POOL_ID, currency0: USDC, currency1: SUSDFR},
    }) as unknown as readonly [Hex, ...Hex[]],
    data: encodeAbiParameters(
      parseAbiParameters(
        "uint24 fee,int24 tickSpacing,address hooks,uint160 sqrtPriceX96,int24 tick",
      ),
      [375, 4, ZERO, SUSDFR_INITIAL_SQRT_PRICE_X96, SUSDFR_INITIAL_TICK],
    ),
  };
}

describe("the fixed USDC/sUSDfr liquidity operation", () => {
  it("binds the exact uninitialized pool, initial price, and owner-reviewed ranges", () => {
    expect(SUSDFR_POOL_ID).toBe(
      "0x1d8694445872d16931c729de06086ccbdc4089875ee73fb6119963a922c92d5a",
    );
    expect(sqrtPriceAtTick(SUSDFR_INITIAL_TICK)).toBeLessThanOrEqual(
      SUSDFR_INITIAL_SQRT_PRICE_X96,
    );
    expect(sqrtPriceAtTick(SUSDFR_INITIAL_TICK + 1)).toBeGreaterThan(
      SUSDFR_INITIAL_SQRT_PRICE_X96,
    );
    expect(usdcPerSusdfrAtTick(SEED_TICK_LOWER)).toBeCloseTo(1.0298390169, 9);
    expect(usdcPerSusdfrAtTick(SEED_TICK_UPPER)).toBeCloseTo(0.9950166739, 9);
    expect(usdcPerSusdfrAtTick(WALL_TICK_LOWER)).toBeCloseTo(0.9499048432, 9);
    expect(usdcPerSusdfrAtTick(WALL_TICK_UPPER)).toBeCloseTo(0.8499413730, 9);
  });

  it("caps the seed at 50 USDC with a pinned deterministic vector", () => {
    const plan = buildSusdfrSeedPlan(0n);
    expect(plan.liquidity).toBe(9_025_046_136_134_563_291n);
    expect(plan.expectedUsdc).toBe(SEED_USDC_CAP);
    expect(plan.expectedSusdfr).toBe(104_307_831_564_546_415_545_314_933n);
    expect(plan.maxSusdfr).toBe(154_280_696_779_167_521_424_784_843n);
  });

  it("makes the second position USDC-only and preserves the aggregate 250,000 cap", () => {
    const seed = buildSusdfrSeedPlan(0n);
    const wall = buildSusdfrWallPlan(SUSDFR_INITIAL_SQRT_PRICE_X96, {
      usdcSpent: seed.expectedUsdc,
      susdfrSpent: seed.expectedSusdfr,
    });
    expect(wall.liquidity).toBe(4_742_167_199_772_113_672_802n);
    expect(wall.expectedSusdfr).toBe(0n);
    expect(wall.maxSusdfr).toBe(0n);
    expect(wall.expectedUsdc).toBe(249_950_000_000n);
    expect(wall.expectedUsdc).toBe(wall.maxUsdc);
    expect(seed.expectedUsdc + wall.maxUsdc).toBe(TOTAL_USDC_CAP);
  });

  it("refuses an already initialized seed or a wall after price enters its range", () => {
    expect(() => buildSusdfrSeedPlan(SUSDFR_INITIAL_SQRT_PRICE_X96)).toThrow(
      /already initialized/i,
    );
    const seed = buildSusdfrSeedPlan(0n);
    expect(() =>
      buildSusdfrWallPlan(sqrtPriceAtTick(WALL_TICK_LOWER + 1), {
        usdcSpent: seed.expectedUsdc,
        susdfrSpent: seed.expectedSusdfr,
      }),
    ).toThrow(/entered the wall range/i);
  });

  it("includes initialization only in the seed multicall", () => {
    const seed = buildSusdfrSeedPlan(0n);
    const permit = buildSusdfrPermitBatchMessage({
      plan: seed,
      usdcNonce: 1,
      susdfrNonce: 2,
      timestamp: 1_790_000_000,
    });
    const data = encodeSusdfrLiquidityTransaction({
      owner: LIQUIDITY_OPERATOR,
      plan: seed,
      permit,
      signature: `0x${"11".repeat(65)}`,
    });
    const outer = decodeFunctionData({abi: SUSDFR_POSITION_MANAGER_ABI, data});
    expect(outer.functionName).toBe("multicall");
    const calls = (outer.args as readonly [readonly Hex[]])[0];
    expect(calls).toHaveLength(3);
    expect(
      decodeFunctionData({abi: SUSDFR_POSITION_MANAGER_ABI, data: calls[0]}).functionName,
    ).toBe("initializePool");
    expect(
      decodeFunctionData({abi: SUSDFR_POSITION_MANAGER_ABI, data: calls[1]}).functionName,
    ).toBe("permitBatch");
    expect(
      decodeFunctionData({abi: SUSDFR_POSITION_MANAGER_ABI, data: calls[2]}).functionName,
    ).toBe("modifyLiquidities");
  });

  it("accepts only a seed receipt proving initialization, exact liquidity, and exact spends", () => {
    const plan = buildSusdfrSeedPlan(0n);
    const logs = [
      initializeLog(),
      mintLog(17n),
      modifyLog(plan),
      transferLog(USDC, plan.expectedUsdc),
      transferLog(SUSDFR, plan.expectedSusdfr),
    ];
    expect(
      verifySusdfrMintReceipt({logs, owner: LIQUIDITY_OPERATOR, plan}),
    ).toEqual({
      tokenId: 17n,
      usdcSpent: plan.expectedUsdc,
      susdfrSpent: plan.expectedSusdfr,
      initialized: true,
    });
    expect(() =>
      verifySusdfrMintReceipt({logs: logs.slice(1), owner: LIQUIDITY_OPERATOR, plan}),
    ).toThrow(/initialize the exact approved pool/i);
    expect(() =>
      verifySusdfrMintReceipt({
        logs: [...logs.slice(0, -1), transferLog(SUSDFR, plan.expectedSusdfr - 1n)],
        owner: LIQUIDITY_OPERATOR,
        plan,
      }),
    ).toThrow(/token spends/i);
    expect(() =>
      verifySusdfrMintReceipt({
        logs: [...logs.slice(0, -1), transferLog(SUSDFR, plan.expectedSusdfr, ZERO)],
        owner: LIQUIDITY_OPERATOR,
        plan,
      }),
    ).toThrow(/token spends/i);
  });
});
