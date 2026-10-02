import {
  decodeFunctionData,
  encodeAbiParameters,
  encodeEventTopics,
  parseAbiParameters,
  type Address,
  type Hex,
} from "viem";
import {describe, expect, it} from "vitest";

import {
  LIQUIDITY_OPERATOR,
  SUSDFR,
  USDC,
  V2_FACTORY,
  V2_FACTORY_ABI,
  V2_PAIR_ABI,
  V2_ROUTER_ABI,
  V2_USDC_AMOUNT,
  V2_USDFR_VALUE,
  ZERO_ADDRESS,
  buildV2LiquidityPlan,
  encodeV2AddLiquidity,
  verifyV2MintReceipt,
  type V2LiquidityPlan,
  type V2ReceiptLog,
} from "./uniswapV2SusdfrLiquidity";

const PAIR = "0x1111111111111111111111111111111111111111" as Address;
const WRONG = "0x2222222222222222222222222222222222222222" as Address;
const SHARES = 24_831_725_419_194_553_652_032_816_501n;

function plan(): V2LiquidityPlan {
  return buildV2LiquidityPlan({
    sharesForTargetAssets: SHARES,
    assetsRepresented: V2_USDFR_VALUE - 1n,
  });
}

function log(args: {
  address: Address;
  abi: typeof V2_FACTORY_ABI | typeof V2_PAIR_ABI;
  eventName: string;
  indexed: Record<string, unknown>;
  parameters: string;
  values: readonly unknown[];
}): V2ReceiptLog {
  return {
    address: args.address,
    topics: encodeEventTopics({
      abi: args.abi,
      eventName: args.eventName,
      args: args.indexed,
    } as never) as unknown as readonly [Hex, ...Hex[]],
    data: encodeAbiParameters(parseAbiParameters(args.parameters), args.values as never),
  };
}

function tokenTransfer(token: Address, from: Address, to: Address, value: bigint): V2ReceiptLog {
  return log({
    address: token,
    abi: V2_PAIR_ABI,
    eventName: "Transfer",
    indexed: {from, to},
    parameters: "uint256 value",
    values: [value],
  });
}

function validLogs(currentPlan = plan()): V2ReceiptLog[] {
  const lp = 788_000n;
  return [
    log({
      address: V2_FACTORY,
      abi: V2_FACTORY_ABI,
      eventName: "PairCreated",
      indexed: {token0: USDC, token1: SUSDFR},
      parameters: "address pair,uint256 allPairsLength",
      values: [PAIR, 99n],
    }),
    tokenTransfer(USDC, LIQUIDITY_OPERATOR, PAIR, currentPlan.usdc),
    tokenTransfer(SUSDFR, LIQUIDITY_OPERATOR, PAIR, currentPlan.susdfr),
    tokenTransfer(PAIR, ZERO_ADDRESS as Address, ZERO_ADDRESS as Address, 1_000n),
    tokenTransfer(PAIR, ZERO_ADDRESS as Address, LIQUIDITY_OPERATOR, lp),
    log({
      address: PAIR,
      abi: V2_PAIR_ABI,
      eventName: "Sync",
      indexed: {},
      parameters: "uint112 reserve0,uint112 reserve1",
      values: [currentPlan.usdc, currentPlan.susdfr],
    }),
    log({
      address: PAIR,
      abi: V2_PAIR_ABI,
      eventName: "Mint",
      indexed: {sender: "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D"},
      parameters: "uint256 amount0,uint256 amount1",
      values: [currentPlan.usdc, currentPlan.susdfr],
    }),
  ];
}

describe("the fixed full-range USDC/sUSDfr V2 operation", () => {
  it("uses 25,000 USDC and exactly the shares representing the approved USDfr value", () => {
    const result = plan();
    expect(result.usdc).toBe(V2_USDC_AMOUNT);
    expect(result.susdfr).toBe(SHARES);
    expect(result.susdfrAssets).toBe(V2_USDFR_VALUE - 1n);
  });

  it("rejects a conversion that does not round-trip to 25,000 USDfr", () => {
    expect(() =>
      buildV2LiquidityPlan({
        sharesForTargetAssets: SHARES,
        assetsRepresented: V2_USDFR_VALUE - 3n,
      }),
    ).toThrow(/outside the approved operation/);
  });

  it("encodes exact desired and minimum amounts with the treasury as LP recipient", () => {
    const currentPlan = plan();
    const deadline = 1_790_400_000n;
    const decoded = decodeFunctionData({
      abi: V2_ROUTER_ABI,
      data: encodeV2AddLiquidity({plan: currentPlan, deadline}),
    });
    expect(decoded.functionName).toBe("addLiquidity");
    expect(decoded.args).toEqual([
      USDC,
      SUSDFR,
      currentPlan.usdc,
      currentPlan.susdfr,
      currentPlan.usdc,
      currentPlan.susdfr,
      LIQUIDITY_OPERATOR,
      deadline,
    ]);
  });

  it("proves pair creation, exact spends, opening reserves and LP ownership", () => {
    const evidence = verifyV2MintReceipt({
      logs: validLogs(),
      owner: LIQUIDITY_OPERATOR,
      plan: plan(),
    });
    expect(evidence.pair).toBe(PAIR);
    expect(evidence.usdcSpent).toBe(V2_USDC_AMOUNT);
    expect(evidence.susdfrSpent).toBe(SHARES);
    expect(evidence.lpTokens).toBe(788_000n);
  });

  it("rejects any token transfer to a destination other than the created pair", () => {
    const logs = validLogs();
    logs[1] = tokenTransfer(USDC, LIQUIDITY_OPERATOR, WRONG, V2_USDC_AMOUNT);
    expect(() => verifyV2MintReceipt({logs, owner: LIQUIDITY_OPERATOR, plan: plan()})).toThrow(
      /somewhere other than the canonical pair/,
    );
  });

  it("rejects a reduced token contribution even by one raw unit", () => {
    const logs = validLogs();
    logs[1] = tokenTransfer(USDC, LIQUIDITY_OPERATOR, PAIR, V2_USDC_AMOUNT - 1n);
    expect(() => verifyV2MintReceipt({logs, owner: LIQUIDITY_OPERATOR, plan: plan()})).toThrow(
      /do not match the exact approved contributions/,
    );
  });

  it("rejects LP issuance to someone other than the treasury", () => {
    const logs = validLogs();
    logs[4] = tokenTransfer(PAIR, ZERO_ADDRESS as Address, WRONG, 788_000n);
    expect(() => verifyV2MintReceipt({logs, owner: LIQUIDITY_OPERATOR, plan: plan()})).toThrow(
      /does not prove one fresh LP mint/,
    );
  });

  it("rejects an opening reserve ratio that differs by one unit", () => {
    const logs = validLogs();
    logs[5] = log({
      address: PAIR,
      abi: V2_PAIR_ABI,
      eventName: "Sync",
      indexed: {},
      parameters: "uint112 reserve0,uint112 reserve1",
      values: [V2_USDC_AMOUNT - 1n, SHARES],
    });
    expect(() => verifyV2MintReceipt({logs, owner: LIQUIDITY_OPERATOR, plan: plan()})).toThrow(
      /approved opening ratio/,
    );
  });

  it("rejects a pair mint attributed to any caller other than the canonical router", () => {
    const logs = validLogs();
    logs[6] = log({
      address: PAIR,
      abi: V2_PAIR_ABI,
      eventName: "Mint",
      indexed: {sender: WRONG},
      parameters: "uint256 amount0,uint256 amount1",
      values: [V2_USDC_AMOUNT, SHARES],
    });
    expect(() => verifyV2MintReceipt({logs, owner: LIQUIDITY_OPERATOR, plan: plan()})).toThrow(
      /approved router/,
    );
  });

  it("rejects a different LP recipient before calldata is encoded", () => {
    expect(() =>
      encodeV2AddLiquidity({plan: plan(), recipient: WRONG, deadline: 1_790_400_000n}),
    ).toThrow(/approved treasury/);
  });
});
