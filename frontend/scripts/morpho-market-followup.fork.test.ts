import {afterAll, beforeAll, beforeEach, describe, expect, it, vi} from "vitest";
import {createPublicClient, encodeAbiParameters, encodeFunctionData, http, keccak256, numberToHex, parseAbi, type Address, type Hex} from "viem";
import {MARKET_TOKEN_ABI, MORPHO_MARKET, MORPHO_MARKET_ABI, marketAction} from "../src/lib/morphoMarket";
import {repaymentQuote, postActionValues, safeBorrowMaximum, safeCollateralMaximum, withinMarketBuffer} from "../src/lib/morphoMarketActions";
import {readMorphoMarket} from "../src/lib/morphoMarketReader";
import {assertMarketQuoteCurrent} from "../src/lib/morphoMarketProjection";
import {simulateSafeMarketCalls} from "../src/lib/morphoSafe";

// Local, explicitly provisioned Anvil only. All balances and impersonations are synthetic.
const endpoint = process.env.MORPHO_FRONTEND_TEST_RPC_URL;
if (endpoint) {
  const u = new URL(endpoint);
  if (u.protocol !== "http:" || u.hostname !== "127.0.0.1" || !u.port || u.username || u.password) throw new Error("Only disposable loopback Anvil is accepted.");
}
const client = createPublicClient({transport: http(endpoint ?? "http://127.0.0.1:1", {retryCount: 0}), cacheTime: 0,
  pollingInterval: 100}); // Disposable loopback receipts; production reader configuration is unchanged.
const P = MORPHO_MARKET.params, M = MORPHO_MARKET.address, SAFE = MORPHO_MARKET.treasury;
const BORROWER = "0x0000000000000000000000000000000000000B0b" as const;
const ERC20_STORAGE = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00n;
const accrueAbi = parseAbi(["struct MarketParams {address loanToken;address collateralToken;address oracle;address irm;uint256 lltv;}", "function accrueInterest(MarketParams marketParams)"]);
let base: string, start: bigint, clock: bigint;
async function local(method: string, params: unknown[] = []) {
  const r = await fetch(endpoint!, {method: "POST", headers: {"content-type": "application/json"}, body: JSON.stringify({jsonrpc: "2.0", id: 1, method, params})});
  const b = await r.json();if (b.error) throw new Error(`Disposable fork method failed: ${method}`);return b.result;
}
async function send(from: Address, to: Address, data: Hex) {
  await local("anvil_setBalance", [from, "0x4563918244f40000"]);
  await local("anvil_impersonateAccount", [from]);
  const hash = await local("eth_sendTransaction", [{from, to, data, gas: "0x2dc6c0"}]);
  expect((await client.waitForTransactionReceipt({hash})).status).toBe("success");
  await local("anvil_stopImpersonatingAccount", [from]);
}
async function fund(token: Address, owner: Address, value: bigint, slot: bigint) {
  const index = keccak256(encodeAbiParameters([{type: "address"}, {type: "uint256"}], [owner, slot]));
  await local("anvil_setStorageAt", [token, index, numberToHex(value, {size: 32})]);
  expect(await client.readContract({address: token, abi: MARKET_TOKEN_ABI, functionName: "balanceOf", args: [owner]})).toBe(value);
}
async function action(who: Address, name: "supply" | "supplyCollateral" | "borrow" | "repay" | "withdrawCollateral", assets: bigint, shares = 0n) {
  await send(who, M, encodeFunctionData(marketAction(name, assets, who, shares) as Parameters<typeof encodeFunctionData>[0]));
}
async function approve(who: Address, token: Address, assets: bigint) {
  await send(who, token, encodeFunctionData({abi: MARKET_TOKEN_ABI, functionName: "approve", args: [M, assets]}));
}
async function setup(who: Address, ceiling = false, assets = 49_000_000_000n) {
  await fund(P.loanToken, SAFE, 100_000_000_000n, 9n);
  await approve(SAFE, P.loanToken, 50_000_000_000n);await action(SAFE, "supply", 50_000_000_000n);
  await fund(P.collateralToken, who, 70_000n * 10n ** 24n, ERC20_STORAGE);
  await approve(who, P.collateralToken, 70_000n * 10n ** 24n);await action(who, "supplyCollateral", 70_000n * 10n ** 24n);
  await action(who, "borrow", assets);
  if (ceiling) {
    // Set AFTER the automined setup: otherwise the initially empty market decays
    // the target during setup and never actually exercises the full 800% ceiling.
    const slot = keccak256(encodeAbiParameters([{type: "bytes32"}, {type: "uint256"}], [MORPHO_MARKET.id, 0n]));
    await local("anvil_setStorageAt", [P.irm, slot, numberToHex(2n * 10n ** 18n / 31_536_000n, {size: 32})]);
  }
  start = (await client.getBlock()).timestamp;clock = start;
}
async function mineAt(timestamp: bigint) {
  await local("evm_setNextBlockTimestamp", [Number(timestamp)]);await local("evm_mine");clock = timestamp;
}
async function readAtClock(who: Address) {
  // Mock freshness only around the reader. Do not freeze viem's receipt-polling clock.
  const now = vi.spyOn(Date, "now").mockReturnValue(Number(clock) * 1000);
  try {return await readMorphoMarket(client, who);} finally {now.mockRestore();}
}

async function delayedQuote(who: Address, age: bigint, latency: number) {
  const pinned = await client.getBlock();
  let wall = Number(pinned.timestamp + age) * 1_000;
  const now = vi.spyOn(Date, "now").mockImplementation(() => wall);
  const original = client.readContract.bind(client);
  let delayed = false;
  const read = vi.spyOn(client, "readContract").mockImplementation(async args => {
    const result = await original(args);
    if (!delayed && args.functionName === "market") {
      delayed = true;wall += latency;
      // A fresh canonical head arrives while the pinned state read is in flight.
      // All state reads still use the original block, not the new head.
      if (latency) await mineAt(BigInt(wall / 1_000));
    }
    return result;
  });
  try {
    const s = await readMorphoMarket(client, who);
    expect(s.timestamp).toBe(pinned.timestamp);
    expect(s.issuedAt).toBe(Number(pinned.timestamp + age) * 1_000 + latency);
    expect(s.expiresAt).toBe(s.issuedAt + 300_000);
    expect(s.projectedThrough).toBeGreaterThanOrEqual(BigInt(s.expiresAt / 1_000) + 42n);
    return s;
  } finally {read.mockRestore();now.mockRestore();}
}

describe.skipIf(!endpoint)("Morpho follow-up: real AdaptiveCurveIrm, debt closure, delayed Safe and forward Max", () => {
  beforeAll(async () => {
    expect(await local("web3_clientVersion")).toMatch(/anvil/i);expect(await client.getChainId()).toBe(1);
    clock = (await client.getBlock()).timestamp;
    base = await local("evm_snapshot");
  });
  beforeEach(async () => {expect(await local("evm_revert", [base])).toBe(true);base = await local("evm_snapshot");});
  afterAll(() => {vi.restoreAllMocks();});

  it.each([0, 86_400, 7 * 86_400, 30 * 86_400])("covers rising rates after %i idle seconds with only the required balance and allowance", async idle => {
    await setup(BORROWER);await mineAt(start + BigInt(idle) + 1n);
    const s = await readAtClock(BORROWER), quote = repaymentQuote(s);
    expect(s.market.totalBorrowAssets * 10n).toBeGreaterThan(s.market.totalSupplyAssets * 9n);
    let quoted = await local("evm_snapshot");
    for (const delay of [12n, 150n, 300n]) {
      expect(await local("evm_revert", [quoted])).toBe(true);
      // Renew the snapshot id after each revert; Anvil invalidates a consumed id.
      quoted = await local("evm_snapshot");
      await fund(P.loanToken, BORROWER, quote.required, 9n);await approve(BORROWER, P.loanToken, quote.required);
      await local("evm_setNextBlockTimestamp", [Number(s.timestamp + delay)]);clock = s.timestamp + delay;
      await action(BORROWER, "repay", 0n, s.account!.position.borrowShares);
      const pos = await client.readContract({address: M, abi: MORPHO_MARKET_ABI, functionName: "position", args: [MORPHO_MARKET.id, BORROWER]});
      expect(pos[1]).toBe(0n);
      expect(await client.readContract({address: P.loanToken, abi: MARKET_TOKEN_ABI, functionName: "balanceOf", args: [BORROWER]})).toBeGreaterThanOrEqual(2n);
    }
  });

  it.each([1n, 30n * 86_400n])("time-shifted IRM view equals actual future accrual after %s idle seconds", async idle => {
    await setup(BORROWER);await mineAt(start + idle);
    const stored = await client.readContract({address: M, abi: MORPHO_MARKET_ABI, functionName: "market", args: [MORPHO_MARKET.id]});
    const state = {totalSupplyAssets: stored[0], totalSupplyShares: stored[1], totalBorrowAssets: stored[2], totalBorrowShares: stored[3], lastUpdate: stored[4], fee: stored[5]};
    const s = await readAtClock(BORROWER);
    const forwardRate = await client.readContract({address: P.irm, abi: MORPHO_MARKET_ABI, functionName: "borrowRateView", args: [P, {...state, lastUpdate: state.lastUpdate - s.projectionSeconds}], blockNumber: s.block});
    const quoted = await local("evm_snapshot");
    await mineAt(s.projectedThrough);
    const actualRate = await client.readContract({address: P.irm, abi: MORPHO_MARKET_ABI, functionName: "borrowRateView", args: [P, state]});
    expect(actualRate).toBe(forwardRate);
    // Execute at exactly the projected timestamp, not one automined second later.
    expect(await local("evm_revert", [quoted])).toBe(true);
    await local("evm_setNextBlockTimestamp", [Number(s.projectedThrough)]);
    await send(BORROWER, M, encodeFunctionData({abi: accrueAbi, functionName: "accrueInterest", args: [P]}));
    const actual = await client.readContract({address: M, abi: MORPHO_MARKET_ABI, functionName: "market", args: [MORPHO_MARKET.id]});
    expect(actual.slice(0, 5)).toEqual([s.projectedMarket.totalSupplyAssets, s.projectedMarket.totalSupplyShares,
      s.projectedMarket.totalBorrowAssets, s.projectedMarket.totalBorrowShares, s.projectedMarket.lastUpdate]);
  });

  it("closes all debt with exactly the required allowance and balance at the full 800% APR ceiling", async () => {
    await setup(BORROWER, true, 50_000_000_000n);
    const s = await readAtClock(BORROWER), quote = repaymentQuote(s);
    expect(s.rate).toBe(4n * (2n * 10n ** 18n / 31_536_000n));
    await fund(P.loanToken, BORROWER, quote.required, 9n);await approve(BORROWER, P.loanToken, quote.required);
    await local("evm_setNextBlockTimestamp", [Number(s.timestamp + 300n)]);clock = s.timestamp + 300n;
    await action(BORROWER, "repay", 0n, s.account!.position.borrowShares);
    expect((await client.readContract({address: M, abi: MORPHO_MARKET_ABI, functionName: "position", args: [MORPHO_MARKET.id, BORROWER]}))[1]).toBe(0n);
  });

  it.each([false, true])("retains the cushioned Safe batch after ten minutes (ceiling=%s)", async ceiling => {
    await setup(SAFE, ceiling);const s = await readAtClock(SAFE), quote = repaymentQuote(s);
    await approve(SAFE, P.loanToken, quote.required);
    await mineAt(s.timestamp + 600n);
    const target = {to: M, value: "0" as const, data: encodeFunctionData(marketAction("repay", 0n, SAFE, s.account!.position.borrowShares) as Parameters<typeof encodeFunctionData>[0])};
    await expect(simulateSafeMarketCalls(client, SAFE, [target])).rejects.toThrow(/did not simulate/);
    const approval = {to: P.loanToken, value: "0" as const, data: encodeFunctionData({abi: MARKET_TOKEN_ABI, functionName: "approve", args: [M, quote.approval]})};
    await expect(simulateSafeMarketCalls(client, SAFE, [approval, target])).resolves.toBeUndefined();
    expect((await client.readContract({address: M, abi: MORPHO_MARKET_ABI, functionName: "position", args: [MORPHO_MARKET.id, SAFE]}))[1]).toBe(s.account!.position.borrowShares);
  });

  it("keeps both Max amounts inside the buffer after five minutes at the rising-rate ceiling", async () => {
    await setup(BORROWER, true);
    let s = await readAtClock(BORROWER);
    const value = 49_500_000_000n * 10_000n / 8_000n;
    const retained = (value * 10n ** 36n + s.price - 1n) / s.price;
    await action(BORROWER, "withdrawCollateral", s.account!.position.collateral - retained);
    s = await readAtClock(BORROWER);
    const borrow = safeBorrowMaximum(s), collateral = safeCollateralMaximum(s);
    expect(borrow).toBeGreaterThan(0n);expect(borrow).toBeLessThan(s.liquidity);expect(collateral).toBeGreaterThan(0n);
    await mineAt(s.timestamp + 300n);const fresh = await readAtClock(BORROWER);
    // No credit for the real oracle's drift: hold the original price in the check.
    const unchangedPrice = {...fresh, price: s.price};
    expect(withinMarketBuffer(postActionValues("borrow", borrow, false, unchangedPrice)!)).toBe(true);
    expect(withinMarketBuffer(postActionValues("withdrawCollateral", collateral, false, unchangedPrice)!)).toBe(true);
    await action(BORROWER, "borrow", borrow);
  });

  const timings = [0n, 89n, 90n].flatMap(age => [0, 13_000].map(latency => ({age, latency})));
  it.each(timings)("closes exact-balance EOA debt five minutes after issuance at 800% APR, age=$age latency=$latency", async ({age, latency}) => {
    await setup(BORROWER, true, 50_000_000_000n);
    const s = await delayedQuote(BORROWER, age, latency), quote = repaymentQuote(s);
    expect(s.rate).toBe(4n * (2n * 10n ** 18n / 31_536_000n));
    await fund(P.loanToken, BORROWER, quote.required, 9n);await approve(BORROWER, P.loanToken, quote.required);
    expect(() => assertMarketQuoteCurrent(s, s.expiresAt - 1)).not.toThrow();
    expect(() => assertMarketQuoteCurrent(s, s.expiresAt)).toThrow(/Quote expired/);
    expect(() => assertMarketQuoteCurrent(s, s.expiresAt + 1)).toThrow(/Quote expired/);
    // A request handed over while live may mine at expiry; the projection still covers it.
    await local("evm_setNextBlockTimestamp", [s.expiresAt / 1_000]);
    await action(BORROWER, "repay", 0n, s.account!.position.borrowShares);
    expect((await client.readContract({address: M, abi: MORPHO_MARKET_ABI, functionName: "position", args: [MORPHO_MARKET.id, BORROWER]}))[1]).toBe(0n);
    expect(await client.readContract({address: P.loanToken, abi: MARKET_TOKEN_ABI, functionName: "balanceOf", args: [BORROWER]})).toBeGreaterThanOrEqual(2n);
  });
  it.each(timings)("simulates exact-balance Safe repay-all through issuance expiry at 800% APR, age=$age latency=$latency", async ({age, latency}) => {
    await setup(SAFE, true, 50_000_000_000n);
    const s = await delayedQuote(SAFE, age, latency), quote = repaymentQuote(s);
    await fund(P.loanToken, SAFE, quote.required, 9n);
    const approval = {to: P.loanToken, value: "0" as const, data: encodeFunctionData({abi: MARKET_TOKEN_ABI, functionName: "approve", args: [M, quote.required]})};
    const repay = {to: M, value: "0" as const, data: encodeFunctionData(marketAction("repay", 0n, SAFE, s.account!.position.borrowShares) as Parameters<typeof encodeFunctionData>[0])};
    await mineAt(BigInt(s.expiresAt / 1_000));
    await expect(simulateSafeMarketCalls(client, SAFE, [approval, repay])).resolves.toBeUndefined();
    // Safe simulation intentionally reverts the entire batch and never submits a proposal.
    expect((await client.readContract({address: M, abi: MORPHO_MARKET_ABI, functionName: "position", args: [MORPHO_MARKET.id, SAFE]}))[1]).toBe(s.account!.position.borrowShares);
    expect(await client.readContract({address: P.loanToken, abi: MARKET_TOKEN_ABI, functionName: "balanceOf", args: [SAFE]})).toBe(quote.required);
  });
  it.each(timings)("keeps both Max calculations executable through issuance expiry, age=$age latency=$latency", async ({age, latency}) => {
    await setup(BORROWER, true);
    let s = await readAtClock(BORROWER);
    const value = 49_500_000_000n * 10_000n / 8_000n;
    const retained = (value * 10n ** 36n + s.price - 1n) / s.price;
    await action(BORROWER, "withdrawCollateral", s.account!.position.collateral - retained);
    s = await delayedQuote(BORROWER, age, latency);
    const borrow = safeBorrowMaximum(s), collateral = safeCollateralMaximum(s);
    expect(borrow).toBeGreaterThan(0n);expect(collateral).toBeGreaterThan(0n);
    const quoted = await local("evm_snapshot");
    await mineAt(BigInt(s.expiresAt / 1_000));const fresh = await readAtClock(BORROWER);
    const unchangedPrice = {...fresh, price: s.price};
    expect(withinMarketBuffer(postActionValues("borrow", borrow, false, unchangedPrice)!)).toBe(true);
    expect(withinMarketBuffer(postActionValues("withdrawCollateral", collateral, false, unchangedPrice)!)).toBe(true);
    await action(BORROWER, "borrow", borrow);
    expect(await local("evm_revert", [quoted])).toBe(true);
    await local("evm_setNextBlockTimestamp", [s.expiresAt / 1_000]);
    await action(BORROWER, "withdrawCollateral", collateral);
  });
});
