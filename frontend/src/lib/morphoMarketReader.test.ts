// @vitest-environment node
import {readFileSync} from "node:fs";
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";
import {keccak256, type Address, type Hex, type PublicClient} from "viem";
import {MORPHO_MARKET} from "./morphoMarket";
import {readMorphoMarket} from "./morphoMarketReader";

// Public deployed bytecode supplied with the sealed review's rM2 evidence, block 26,233,881.
const CODE = readFileSync(new URL("../test/fixtures/morpho-oracle-runtime.hex", import.meta.url), "utf8").trim() as Hex;
const WALLET = "0x1111111111111111111111111111111111111111" as Address;
const HASH = `0x${"aa".repeat(32)}` as Hex;
const NOW = 1_792_500_000n;
const BLOCK = 26_234_000n;
type Overrides = Partial<{chain: number; timestamp: bigint; number: bigint | null; hash: Hex | null; closingHash: Hex | null;
  params: Record<string, unknown>; stored: bigint[]; code: Hex | undefined; loanDecimals: number; collateralDecimals: number;
  price: bigint; failure: string}>;

function fakeClient(o: Overrides = {}) {
  const calls: {kind: string; functionName?: string; blockNumber?: bigint; address?: Address; args?: unknown[]}[] = [];
  const client = {
    getChainId: vi.fn(async () => o.chain ?? 1),
    getBlock: vi.fn(async (a: {blockTag?: string; blockNumber?: bigint}) => {
      calls.push({kind: "getBlock", blockNumber: a.blockNumber});
      return {number: "number" in o ? o.number : BLOCK, timestamp: o.timestamp ?? NOW,
        hash: a.blockTag === "latest" ? ("hash" in o ? o.hash : HASH) : ("closingHash" in o ? o.closingHash : HASH)};
    }),
    getCode: vi.fn(async (a: {address: Address; blockNumber: bigint}) => {
      calls.push({kind: "getCode", ...a});return "code" in o ? o.code : CODE;
    }),
    readContract: vi.fn(async (a: {address: Address; functionName: string; args?: unknown[]; blockNumber?: bigint}) => {
      calls.push({kind: "readContract", ...a});
      if (o.failure === a.functionName) throw new Error("Provider unavailable");
      switch (a.functionName) {
        case "idToMarketParams": return {...MORPHO_MARKET.params, ...o.params};
        case "market": return o.stored ?? [1_000_000n, 1_000_000_000_000n, 500_000n, 500_000_000_000n, NOW - 1000n, 100_000_000_000_000_000n];
        case "price": return o.price ?? 10n ** 18n;
        case "decimals": return a.address === MORPHO_MARKET.params.loanToken ? o.loanDecimals ?? 6 : o.collateralDecimals ?? 24;
        case "borrowRateView": return 10n ** 12n;
        case "position": return [1_000_000_000_000n, 500_000_000_000n, 10n ** 24n];
        case "balanceOf": return a.address === MORPHO_MARKET.params.loanToken ? 123_456n : 7n * 10n ** 24n;
        case "allowance": return a.address === MORPHO_MARKET.params.loanToken ? 234_567n : 8n * 10n ** 24n;
        case "nonce": return 15n;
        default: throw new Error(`Unexpected function: ${a.functionName}`);
      }
    }),
  };
  return {client: client as unknown as PublicClient, calls, methods: client};
}
beforeEach(() => vi.spyOn(Date, "now").mockReturnValue(Number(NOW) * 1000));
afterEach(() => {vi.restoreAllMocks();vi.useRealTimers();});

describe("verified Morpho reader (real oracle bytes, no network)", () => {
  it("pins the public deployed oracle bytecode independently", () => {
    expect(keccak256(CODE)).toBe("0x26ef6287f527737bb7b5a37bea8681a08d5f98ddcd941338570408621c2035b3");
    expect(MORPHO_MARKET.oracleCodehash).toBe(keccak256(CODE));
  });
  it("accrues exact values and pins every state read, including the final hash check", async () => {
    const {client, calls} = fakeClient();
    const s = await readMorphoMarket(client, WALLET);
    expect(s).toMatchObject({block: BLOCK, blockHash: HASH, timestamp: NOW, readAt: Number(NOW) * 1000,
      issuedAt: Number(NOW) * 1000, expiresAt: Number(NOW) * 1000 + 300_000,
      projectedThrough: NOW + 357n, projectionSeconds: 357n,
      liquidity: 500_000n, market: {totalSupplyAssets: 1_000_500n, totalBorrowAssets: 500_500n, totalSupplyShares: 1_000_049_977_510n},
      account: {wallet: WALLET, usdc: 123_456n, collateral: 7n * 10n ** 24n, usdcAllowance: 234_567n,
        collateralAllowance: 8n * 10n ** 24n, safeNonce: null, values: {supplied: 1_000_449n, borrowed: 500_500n, collateralValue: 1_000_000n}}});
    const reads = calls.filter(c => c.kind !== "getBlock");
    expect(reads).toHaveLength(13);
    expect(reads.every(c => c.blockNumber === BLOCK)).toBe(true);
    expect(calls.slice(-2)).toEqual([{kind: "getBlock", blockNumber: BLOCK}, {kind: "getBlock", blockNumber: undefined}]);
    expect(calls.find(c => c.functionName === "allowance")).toMatchObject({args: [WALLET, "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb"]});
  });
  it("projects from the original stored market with the exact future IRM average at the same block", async () => {
    const {client, calls, methods} = fakeClient();
    const original = methods.readContract.getMockImplementation()!;
    methods.readContract.mockImplementation(async a => {
      if (a.functionName === "borrowRateView") {
        calls.push({kind: "readContract", ...a});
        const m = a.args![1] as {lastUpdate: bigint};
        return m.lastUpdate === NOW - 1357n ? 2n * 10n ** 12n : 10n ** 12n;
      }
      return original(a);
    });
    const s = await readMorphoMarket(client, WALLET);
    expect(s.market.totalBorrowAssets).toBe(500_500n);
    expect(s.projectedMarket.totalBorrowAssets).toBe(501_358n);
    expect(s.projectedMarket.lastUpdate).toBe(NOW + 357n);
    const rateCalls = calls.filter(c => c.functionName === "borrowRateView");
    expect(rateCalls).toHaveLength(2);expect(rateCalls.every(c => c.blockNumber === BLOCK)).toBe(true);
    expect(rateCalls.map(c => c.args![1])).toEqual([
      expect.objectContaining({lastUpdate: NOW - 1000n, totalBorrowAssets: 500_000n}),
      expect.objectContaining({lastUpdate: NOW - 1357n, totalBorrowAssets: 500_000n}),
    ]);
  });
  it("fails closed when only the forward IRM view fails instead of reusing the current rate", async () => {
    const {client, methods} = fakeClient(), original = methods.readContract.getMockImplementation()!;
    methods.readContract.mockImplementation(async a => {
      if (a.functionName === "borrowRateView" && (a.args![1] as {lastUpdate: bigint}).lastUpdate === NOW - 1357n) throw new Error("Forward projection unavailable");
      return original(a);
    });
    await expect(readMorphoMarket(client, WALLET)).rejects.toThrow("Forward projection unavailable");
  });
  it("does not invent an account or read wallet state when disconnected", async () => {
    const {client, calls} = fakeClient();expect((await readMorphoMarket(client)).account).toBeNull();
    expect(calls.filter(c => c.functionName === "position" || c.functionName === "nonce" || c.functionName === "balanceOf")).toHaveLength(0);
  });
  it("handles a created but empty market without dividing utilization by zero", async () => {
    const s=await readMorphoMarket(fakeClient({stored:[0n,0n,0n,0n,NOW,0n]}).client);
    expect(s.liquidity).toBe(0n);expect(s.supplyRate).toBe(0n);expect(s.account).toBeNull();
  });
  it("reads the Treasury nonce at the same pinned block", async () => {
    const {client, calls} = fakeClient();expect((await readMorphoMarket(client, MORPHO_MARKET.treasury)).account!.safeNonce).toBe(15n);
    expect(calls.find(c => c.functionName === "nonce")).toMatchObject({blockNumber: BLOCK, address: MORPHO_MARKET.treasury});
  });
  it("refuses a wrong chain before any block or account read", async () => {
    const {client, calls} = fakeClient({chain: 5});await expect(readMorphoMarket(client, WALLET)).rejects.toThrow(/Ethereum mainnet/);expect(calls).toHaveLength(0);
  });
  it.each([
    ["91-second-old head", {timestamp: NOW - 91n}], ["31-second future head", {timestamp: NOW + 31n}],
    ["missing block number", {number: null}], ["zero block number", {number: 0n}], ["missing block hash", {hash: null}],
  ] as const)("refuses %s", async (_name, overrides) => {
    const {client, methods} = fakeClient(overrides);await expect(readMorphoMarket(client, WALLET)).rejects.toThrow(/Current Ethereum state is unavailable/);
    expect(methods.readContract).not.toHaveBeenCalled();
  });
  it.each([NOW - 90n, NOW + 30n])("accepts the timestamp boundary %s", async timestamp => {
    await expect(readMorphoMarket(fakeClient({timestamp}).client)).resolves.toMatchObject({timestamp});
  });
  it.each([0n, 89n, 90n])("issues a full five-minute quote after delayed reads from a %ss-old head", async age => {
    const {client, methods, calls} = fakeClient({timestamp: NOW - age});
    let clock = Number(NOW) * 1_000, latestReads = 0;
    vi.mocked(Date.now).mockImplementation(() => clock);
    const read = methods.readContract.getMockImplementation()!, head = methods.getBlock.getMockImplementation()!;
    methods.readContract.mockImplementation(async a => {
      const result = await read(a);
      if (a.functionName === "market") clock += 6_000;
      if (a.functionName === "borrowRateView" && (a.args![1] as {lastUpdate: bigint}).lastUpdate !== NOW - 1000n) clock += 4_000;
      return result;
    });
    methods.getBlock.mockImplementation(async a => {
      const result = await head(a);
      if (a.blockTag === "latest" && ++latestReads > 1) {
        if (latestReads === 3) clock += 3_000;
        return {...result, number: BLOCK + 1n, hash: `0x${"bb".repeat(32)}` as Hex, timestamp: BigInt(clock / 1_000)};
      }
      return result;
    });
    const s = await readMorphoMarket(client, WALLET);
    expect(s.issuedAt).toBe(Number(NOW) * 1_000 + 13_000);
    expect(s.expiresAt).toBe(s.issuedAt + 300_000);
    expect(s.readAt).toBe(s.issuedAt);
    expect(s.projectedThrough).toBe(NOW + 363n);
    expect(s.projectionSeconds).toBe(363n + age);
    expect(s.projectedThrough).toBeGreaterThanOrEqual(BigInt(s.expiresAt / 1_000) + 42n);
    expect(s.projectedMarket.lastUpdate).toBe(s.projectedThrough);
    expect((calls.filter(c => c.functionName === "borrowRateView").at(-1)!.args![1] as {lastUpdate: bigint}).lastUpdate)
      .toBe(NOW - 1000n - 363n - age);
    expect(latestReads).toBe(3);
  });
  it("rounds a fractional issuance clock up rather than losing a second of protection", async () => {
    vi.mocked(Date.now).mockReturnValue(Number(NOW) * 1_000 + 999);
    const s = await readMorphoMarket(fakeClient().client);
    expect(s.projectedThrough).toBe(NOW + 358n);
    expect(s.expiresAt).toBe(Number(NOW) * 1_000 + 300_999);
  });
  it.each(["stale", "future", "regressed", "same-height reorg", "missing height", "missing hash", "older timestamp"])("rejects a %s final head instead of issuing a fresh label", async failure => {
    const {client, methods} = fakeClient();
    const head = methods.getBlock.getMockImplementation()!;let latestReads = 0;
    methods.getBlock.mockImplementation(async a => {
      const result = await head(a);
      if (a.blockTag !== "latest" || ++latestReads !== 3) return result;
      if (failure === "stale") {vi.mocked(Date.now).mockReturnValue(Number(NOW + 1n) * 1_000);return {...result, number: BLOCK + 1n, timestamp: NOW - 90n};}
      if (failure === "future") return {...result, timestamp: NOW + 31n};
      if (failure === "regressed") return {...result, number: BLOCK - 1n};
      if (failure === "same-height reorg") return {...result, hash: `0x${"bb".repeat(32)}` as Hex};
      if (failure === "missing height") return {...result, number: null};
      if (failure === "missing hash") return {...result, number: BLOCK + 1n, hash: null};
      return {...result, number: BLOCK + 1n, timestamp: NOW - 1n};
    });
    await expect(readMorphoMarket(client, WALLET)).rejects.toThrow(/unavailable|reorganized/);
  });
  it("checks canonicality again after the forward IRM RPC, not only before it", async () => {
    const {client, methods} = fakeClient(), head = methods.getBlock.getMockImplementation()!;let canonicalReads = 0;
    methods.getBlock.mockImplementation(async a => {
      const result = await head(a);
      return a.blockNumber && ++canonicalReads === 2 ? {...result, hash: null} : result;
    });
    await expect(readMorphoMarket(client)).rejects.toThrow(/reorganized/);
  });
  it.each(["wall deadline", "monotonic deadline", "backward clock", "invalid clock"])("rejects a %s before issuing a quote", async reason => {
    const {client, methods} = fakeClient(), read = methods.readContract.getMockImplementation()!;
    const monotonic = vi.spyOn(performance, "now").mockReturnValue(100);
    methods.readContract.mockImplementation(async a => {
      const result = await read(a);
      if (a.functionName === "market") {
        if (reason === "wall deadline") vi.mocked(Date.now).mockReturnValue(Number(NOW) * 1_000 + 15_000);
        if (reason === "monotonic deadline") monotonic.mockReturnValue(15_100);
        if (reason === "backward clock") vi.mocked(Date.now).mockReturnValue(Number(NOW) * 1_000 - 1);
        if (reason === "invalid clock") vi.mocked(Date.now).mockReturnValue(NaN);
      }
      return result;
    });
    await expect(readMorphoMarket(client)).rejects.toThrow(/timed out or its clock changed/);
    expect(methods.readContract.mock.calls.some(([a]) => a.functionName === "borrowRateView")).toBe(false);
  });
  it("times out a stalled RPC and refuses its late continuation", async () => {
    vi.useFakeTimers({toFake: ["setTimeout", "clearTimeout"]});
    const {client, methods} = fakeClient();let finish!: (id: number) => void;
    methods.getChainId.mockImplementation(() => new Promise(resolve => {finish = resolve;}));
    const running = readMorphoMarket(client), rejected = expect(running).rejects.toThrow(/timed out/);
    await vi.advanceTimersByTimeAsync(15_000);await rejected;
    finish(1);await Promise.resolve();await Promise.resolve();
    expect(methods.getBlock).not.toHaveBeenCalled();
  });
  it("refuses an underflow in the larger shifted IRM interval", async () => {
    await expect(readMorphoMarket(fakeClient({stored: [0n, 0n, 0n, 0n, 356n, 0n]}).client)).rejects.toThrow(/could not be verified/);
  });
  it.each(["loanToken", "collateralToken", "oracle", "irm"])("refuses changed %s", async key => {
    await expect(readMorphoMarket(fakeClient({params: {[key]: WALLET}}).client, WALLET)).rejects.toThrow(/identity differs/);
  });
  it.each([
    ["LLTV", {params: {lltv: 945_000_000_000_000_000n}}], ["uncreated market", {stored: [0n, 0n, 0n, 0n, 0n, 0n]}],
    ["invalid last update", {stored: [0n, 0n, 0n, 0n, 299n, 0n]}],
    ["future last update", {stored: [0n, 0n, 0n, 0n, NOW + 1n, 0n]}],
    ["missing code", {code: undefined}], ["empty code", {code: "0x"}], ["changed oracle code", {code: `${CODE}00`}],
    ["USDC decimals", {loanDecimals: 18}], ["sUSDfr decimals", {collateralDecimals: 23}],
  ] as const)("refuses unverifiable %s", async (_name, overrides) => {
    await expect(readMorphoMarket(fakeClient(overrides as Overrides).client, WALLET)).rejects.toThrow(/could not be verified/);
  });
  it("refuses accounting where borrow exceeds supply", async () => {
    await expect(readMorphoMarket(fakeClient({stored: [10n, 10n, 11n, 11n, NOW, 0n]}).client)).rejects.toThrow(/inconsistent/);
  });
  it.each([`0x${"bb".repeat(32)}` as Hex, null])("refuses a reorg or lost hash at the closing read", async closingHash => {
    await expect(readMorphoMarket(fakeClient({closingHash}).client, WALLET)).rejects.toThrow(/reorganized/);
  });
  it("accepts a genuine zero oracle price without inventing collateral value", async () => {
    const s = await readMorphoMarket(fakeClient({price: 0n}).client, WALLET);
    expect(s.account!.values.collateralValue).toBe(0n);expect(s.account!.values.borrowAvailable).toBe(0n);expect(s.account!.values.borrowed).toBe(500_500n);
  });
  it.each(["price", "position", "balanceOf", "allowance", "borrowRateView"])("propagates failed %s reads without assumed balances", async failure => {
    await expect(readMorphoMarket(fakeClient({failure}).client, WALLET)).rejects.toThrow("Provider unavailable");
  });
});
