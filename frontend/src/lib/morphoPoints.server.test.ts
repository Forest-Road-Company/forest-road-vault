import {beforeEach, describe, expect, it} from "vitest";
import {
  createPublicClient,
  custom,
  decodeFunctionData,
  encodeAbiParameters,
  encodeEventTopics,
  encodeFunctionResult,
  keccak256,
  multicall3Abi,
  pad,
  toHex,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import {POINTS_HISTORY_ABI} from "@/lib/abi";
import {EXPECTED_CHAIN} from "@/lib/chain";
import {replayCollateralPoints, type CollateralEvent, type RateEpoch} from "@/lib/morphoPoints";
import {
  ADAPTIVE_CURVE_IRM,
  BLOCK_CHUNK,
  LOG_RESULT_LIMIT,
  loadMorphoCollateralPoints,
  MARKET_LLTV,
  MAX_CHUNKS_PER_REQUEST,
  MORPHO_BLUE,
  MORPHO_COLLATERAL_ABI,
  MorphoPointsIntegrityError,
  MorphoPointsNotReadyError,
  POINTS_MODULE_IMPLEMENTATION,
  REQUEST_BUDGET_MS,
  resetMorphoPointsCache,
  ZERO_HELD_GRID_CHUNKS,
  type MorphoPointsDeps,
  type MorphoPointsWire,
  type RawLog,
} from "@/lib/morphoPoints.server";

const USDC: Address = "0x00000000000000000000000000000000000000a0";
const SUSDFR: Address = "0x00000000000000000000000000000000000000af";
const CONTROLLER: Address = "0x00000000000000000000000000000000000000c0";
const POINTS: Address = "0x00000000000000000000000000000000000000d0";
const COMPLIANCE: Address = "0x00000000000000000000000000000000000000cc";
const ORACLE: Address = "0x00000000000000000000000000000000000000e0";
const BUNDLER: Address = "0x00000000000000000000000000000000000000f0";
const ALICE: Address = "0x000000000000000000000000000000000000a11c";
const BOB: Address = "0x0000000000000000000000000000000000000b0b";
const CAROL: Address = "0x000000000000000000000000000000000000ca01";
const MARKET: Hex = `0x${"11".repeat(32)}`;
const FROM = 100n;
const SHARE = 10n ** 24n;
const WAD = 10n ** 18n;

const hashOf = (block: bigint): Hex => keccak256(toHex(block));
const timeOf = (block: bigint): bigint => 1_790_000_000n + block * 12n;

type Change = {block: bigint; logIndex: number; kind: CollateralEvent["kind"]; owner: Address; assets: bigint; tx?: Hex};

function collateralLog(c: Change): RawLog {
  const base = {
    address: MORPHO_BLUE,
    blockNumber: toHex(c.block),
    blockHash: hashOf(c.block),
    logIndex: toHex(c.logIndex),
    transactionHash: c.tx ?? keccak256(toHex(c.block * 1000n + BigInt(c.logIndex))),
  };
  if (c.kind === "supply") {
    return {
      ...base,
      topics: encodeEventTopics({
        abi: MORPHO_COLLATERAL_ABI,
        eventName: "SupplyCollateral",
        args: {id: MARKET, caller: BUNDLER, onBehalf: c.owner},
      }) as Hex[],
      data: encodeAbiParameters([{type: "uint256"}], [c.assets]),
    };
  }
  if (c.kind === "withdraw") {
    return {
      ...base,
      topics: encodeEventTopics({
        abi: MORPHO_COLLATERAL_ABI,
        eventName: "WithdrawCollateral",
        args: {id: MARKET, onBehalf: c.owner, receiver: BUNDLER},
      }) as Hex[],
      data: encodeAbiParameters([{type: "address"}, {type: "uint256"}], [BUNDLER, c.assets]),
    };
  }
  return {
    ...base,
    topics: encodeEventTopics({
      abi: MORPHO_COLLATERAL_ABI,
      eventName: "Liquidate",
      args: {id: MARKET, caller: BUNDLER, borrower: c.owner},
    }) as Hex[],
    data: encodeAbiParameters(
      [{type: "uint256"}, {type: "uint256"}, {type: "uint256"}, {type: "uint256"}, {type: "uint256"}],
      [1n, 1n, c.assets, 0n, 0n],
    ),
  };
}

function epochLog(index: bigint, block: bigint, rate: bigint): RawLog {
  return {
    address: POINTS,
    topics: encodeEventTopics({abi: POINTS_HISTORY_ABI, eventName: "RateEpochAppended", args: {index}}) as Hex[],
    data: encodeAbiParameters([{type: "uint256"}, {type: "uint32"}, {type: "uint32"}], [rate, 30_000, 50_000]),
    blockNumber: toHex(block),
    blockHash: hashOf(block),
    logIndex: toHex(0),
    transactionHash: keccak256(toHex(block * 7n)),
  };
}

function topicMatches(filter: Hex | Hex[] | null | undefined, topic: Hex | undefined): boolean {
  if (filter === null || filter === undefined) return true;
  const options = Array.isArray(filter) ? filter : [filter];
  return topic !== undefined && options.some((o) => o.toLowerCase() === topic.toLowerCase());
}

function deferred(): {promise: Promise<void>; resolve: () => void} {
  let resolve = () => {};
  const promise = new Promise<void>((r) => {
    resolve = r;
  });
  return {promise, resolve};
}

/** A chain the loader can read: finalized head, headers, logs, and the views it checks. */
class FakeChain {
  finalized = 200n;
  marketFrom = FROM;
  changes: Change[] = [];
  epochs: {block: bigint; rate: bigint}[] = [{block: 50n, rate: WAD}];
  hiddenLogs = new Set<string>();
  forgedHashBlocks = new Set<bigint>();
  exempt = new Set<string>();
  blocked = new Set<string>();
  lltv = MARKET_LLTV;
  marketOracle: Address = ORACLE;
  oracleVault: Address = SUSDFR;
  marketExistsBefore = false;
  implementation: Address = POINTS_MODULE_IMPLEMENTATION;
  vaultPointsModule: Address = POINTS;
  epochCountOverride: bigint | null = null;
  /** rateEpochCount reads that fail like a transport error before one succeeds. */
  failEpochCountReads = 0;
  /** Milliseconds each eth_getLogs answer moves the test clock on, like a slow archive RPC. */
  logDelayMs = 0;
  /** The same, added for Morpho Blue's collateral logs alone. */
  collateralLogDelayMs = 0;
  /** Every multicall the loader made: the block it read at and the owners whose positions it carried. */
  readonly multicalls: {block: bigint; size: number; owners: string[]}[] = [];
  multicallsInFlight = 0;
  maxMulticallsInFlight = 0;
  /** PointsModule.trackedBalances(wallet).shares and sUSDfr.balanceOf(wallet); both 0 by default. */
  tracked = new Map<string, bigint>();
  walletShares = new Map<string, bigint>();
  /** Collateral a per-wallet position() read reports instead of the canonical value. */
  positionOverride = new Map<string, bigint>();
  /** Awaited inside the per-wallet position() read, so a test can hold one request mid-flight. */
  positionGate: ((owner: string) => Promise<void>) | null = null;
  /** A provider that silently returns at most this many logs per eth_getLogs answer. */
  resultCap: number | null = null;
  getLogsCalls = 0;
  readonly getLogsByAddress = new Map<string, number>();

  logCalls(address: Address): number {
    return this.getLogsByAddress.get(address.toLowerCase()) ?? 0;
  }

  collateralAt(owner: Address, block: bigint): bigint {
    let total = 0n;
    for (const c of this.changes) {
      if (c.block > block || c.owner.toLowerCase() !== owner.toLowerCase()) continue;
      total = c.kind === "supply" ? total + c.assets : total - c.assets;
    }
    return total;
  }

  read(args: {address: Address; functionName: string; args?: readonly unknown[]; blockNumber?: bigint}): unknown {
    const block = args.blockNumber ?? this.finalized;
    const who = () => (args.args![args.functionName === "position" ? 1 : 0] as string).toLowerCase();
    switch (args.functionName) {
      case "idToMarketParams":
        if (block < this.marketFrom && !this.marketExistsBefore) {
          return ["0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000", 0n];
        }
        return [USDC, SUSDFR, this.marketOracle, ADAPTIVE_CURVE_IRM, this.lltv];
      case "vault":
        return this.oracleVault;
      case "controller":
        return CONTROLLER;
      case "loanToken":
        return USDC;
      case "ONE_SHARE":
        return SHARE;
      case "rateEpochCount":
        if (this.failEpochCountReads > 0) {
          this.failEpochCountReads--;
          throw new Error("fake chain: transport error");
        }
        return this.epochCountOverride ?? BigInt(this.epochs.filter((e) => e.block <= block).length);
      case "pointsModule":
        return this.vaultPointsModule;
      case "position":
        return [0n, 0n, this.collateralAt(args.args![1] as Address, block)];
      case "isProtocolExempt":
        return this.exempt.has(who());
      case "isJurisdictionBlocked":
        return this.blocked.has(who());
      case "trackedBalances":
        return [this.tracked.get(who()) ?? 0n, 0n];
      case "balanceOf":
        return this.walletShares.get(who()) ?? 0n;
      default:
        throw new Error(`fake chain: unexpected read ${args.functionName}`);
    }
  }

  logs(filter: {address: Address; topics: (Hex | Hex[] | null)[]; fromBlock: Hex; toBlock: Hex}): RawLog[] {
    this.getLogsCalls++;
    const key = filter.address.toLowerCase();
    clock += this.logDelayMs + (key === MORPHO_BLUE.toLowerCase() ? this.collateralLogDelayMs : 0);
    this.getLogsByAddress.set(key, (this.getLogsByAddress.get(key) ?? 0) + 1);
    const from = BigInt(filter.fromBlock);
    const to = BigInt(filter.toBlock);
    const all: RawLog[] = [...this.changes.map(collateralLog), ...this.epochs.map((e, i) => epochLog(BigInt(i), e.block, e.rate))];
    const matched = all
      .filter((log) => {
        const n = BigInt(log.blockNumber);
        if (n < from || n > to || log.address.toLowerCase() !== key) return false;
        if (this.hiddenLogs.has(`${n}:${BigInt(log.logIndex)}`)) return false;
        return filter.topics.every((t, i) => topicMatches(t, log.topics[i]));
      })
      .map((log) => (this.forgedHashBlocks.has(BigInt(log.blockNumber)) ? {...log, blockHash: hashOf(999_999n)} : log));
    return this.resultCap === null ? matched : matched.slice(0, this.resultCap);
  }

  client(): PublicClient {
    const client = {
      getChainId: async () => EXPECTED_CHAIN.id,
      getBlock: async (args: {blockTag?: string; blockNumber?: bigint}) => {
        const n = args.blockTag === "finalized" ? this.finalized : args.blockNumber!;
        return {number: n, hash: hashOf(n), timestamp: timeOf(n)};
      },
      getStorageAt: async () => pad(this.implementation),
      readContract: async (args: {address: Address; functionName: string; args?: readonly unknown[]; blockNumber?: bigint}) => {
        if (args.functionName === "position") {
          const owner = (args.args![1] as string).toLowerCase();
          if (this.positionGate) await this.positionGate(owner);
          const forced = this.positionOverride.get(owner);
          if (forced !== undefined) return [0n, 0n, forced];
        }
        return this.read(args);
      },
      multicall: async (args: {contracts: {address: Address; functionName: string; args?: readonly unknown[]}[]; blockNumber?: bigint}) => {
        this.multicalls.push({
          block: args.blockNumber ?? this.finalized,
          size: args.contracts.length,
          owners: args.contracts.map((c) => (c.args![1] as string).toLowerCase()),
        });
        this.multicallsInFlight++;
        this.maxMulticallsInFlight = Math.max(this.maxMulticallsInFlight, this.multicallsInFlight);
        await new Promise((resolve) => setTimeout(resolve, 0)); // an RPC round trip others can overlap
        this.multicallsInFlight--;
        return args.contracts.map((c) => this.read({...c, blockNumber: args.blockNumber}));
      },
      request: async (args: {method: string; params: [{address: Address; topics: (Hex | Hex[] | null)[]; fromBlock: Hex; toBlock: Hex}]}) => {
        if (args.method !== "eth_getLogs") throw new Error(`fake chain: unexpected ${args.method}`);
        return this.logs(args.params[0]);
      },
    };
    return client as unknown as PublicClient;
  }
}

let chain: FakeChain;
let clock = 1_000_000;

function deps(overrides: Partial<MorphoPointsDeps> = {}): MorphoPointsDeps {
  return {
    client: chain.client(),
    config: {marketId: MARKET, fromBlock: chain.marketFrom, oracle: ORACLE},
    contracts: {usdc: USDC, susdfr: SUSDFR, controller: CONTROLLER, points: POINTS, compliance: COMPLIANCE},
    protocolDeploymentBlock: 40n,
    now: () => clock,
    ...overrides,
  };
}

/** The same replay, computed independently from the fake chain's canonical history. */
function expectedPoints(owner: Address, asOf: bigint): bigint {
  const epochs: RateEpoch[] = chain.epochs.map((e) => ({start: timeOf(e.block), ratePerUnitDay: e.rate}));
  const events: CollateralEvent[] = chain.changes
    .filter((c) => c.block <= asOf)
    .map((c) => ({blockNumber: c.block, logIndex: c.logIndex, timestamp: timeOf(c.block), kind: c.kind, owner: c.owner, assets: c.assets}));
  return replayCollateralPoints(events, epochs, timeOf(asOf)).get(owner.toLowerCase())?.points ?? 0n;
}

/** Narrows an answer to one that credits points, failing the test on any other state. */
function credited(answer: MorphoPointsWire) {
  if (!answer.enabled || !("points" in answer)) throw new Error(`expected credited points, got ${JSON.stringify(answer)}`);
  return answer;
}

beforeEach(() => {
  resetMorphoPointsCache();
  clock = 1_000_000;
  chain = new FakeChain();
  chain.changes = [
    {block: 110n, logIndex: 3, kind: "supply", owner: ALICE, assets: 1_000n * SHARE},
    {block: 120n, logIndex: 1, kind: "supply", owner: BOB, assets: 500n * SHARE},
    {block: 130n, logIndex: 2, kind: "withdraw", owner: ALICE, assets: 200n * SHARE},
    {block: 140n, logIndex: 0, kind: "liquidate", owner: BOB, assets: 50n * SHARE},
  ];
});

describe("loadMorphoCollateralPoints", () => {
  it("serves each owner's replayed points at the finalized block", async () => {
    const alice = credited(await loadMorphoCollateralPoints(ALICE, deps()));
    expect(alice).toMatchObject({ok: true, enabled: true, asOfBlock: "200", collateral: (800n * SHARE).toString(), rateEpochs: 1});
    expect(BigInt(alice.points)).toBe(expectedPoints(ALICE, 200n));
    expect(BigInt(alice.points)).toBeGreaterThan(0n);
    const bob = credited(await loadMorphoCollateralPoints(BOB, deps()));
    expect(bob.collateral).toBe((450n * SHARE).toString());
    expect(BigInt(bob.points)).toBe(expectedPoints(BOB, 200n));
  });

  it("answers zero for an owner who never posted collateral", async () => {
    const stranger = await loadMorphoCollateralPoints("0x0000000000000000000000000000000000005555", deps());
    expect(stranger).toMatchObject({collateral: "0", points: "0"});
  });

  it("extends only the new range and replays once per block", async () => {
    await loadMorphoCollateralPoints(ALICE, deps());
    const calls = chain.getLogsCalls;
    await loadMorphoCollateralPoints(BOB, deps());
    expect(chain.getLogsCalls).toBe(calls); // same finalized block: served from the snapshot
    chain.finalized = 210n;
    chain.changes.push({block: 205n, logIndex: 0, kind: "supply", owner: ALICE, assets: 5n * SHARE});
    const later = await loadMorphoCollateralPoints(ALICE, deps());
    expect(later).toMatchObject({asOfBlock: "210", collateral: (805n * SHARE).toString()});
    expect(chain.getLogsCalls - calls).toBe(2); // one epoch range and one collateral range
  });

  it("never serves an older snapshot when the RPC's finalized head lags", async () => {
    await loadMorphoCollateralPoints(ALICE, deps());
    chain.finalized = 180n;
    expect(await loadMorphoCollateralPoints(ALICE, deps())).toMatchObject({asOfBlock: "200"});
  });

  it("shares one extension between concurrent requests", async () => {
    const [a, b] = await Promise.all([loadMorphoCollateralPoints(ALICE, deps()), loadMorphoCollateralPoints(BOB, deps())]);
    expect(a.enabled && b.enabled).toBe(true);
    expect(chain.getLogsCalls).toBe(2);
  });

  it("is not ready until the market's creation block is finalized", async () => {
    chain.finalized = 90n;
    await expect(loadMorphoCollateralPoints(ALICE, deps())).rejects.toBeInstanceOf(MorphoPointsNotReadyError);
  });

  it("withholds points from protocol-exempt and jurisdiction-blocked owners", async () => {
    chain.exempt.add(ALICE.toLowerCase());
    chain.blocked.add(BOB.toLowerCase());
    expect(await loadMorphoCollateralPoints(ALICE, deps())).toMatchObject({points: "0", excluded: "protocol-exempt"});
    expect(await loadMorphoCollateralPoints(BOB, deps())).toMatchObject({points: "0", excluded: "jurisdiction-blocked"});
  });
});

describe("a cold instance far past the deployment block (MORPHO-10)", () => {
  const D = 1_000n;
  const CAP = BigInt(MAX_CHUNKS_PER_REQUEST) * BLOCK_CHUNK;

  beforeEach(() => {
    chain.epochs = [
      {block: D + 1n, rate: WAD},
      {block: D + CAP + 10n, rate: 2n * WAD}, // beyond the first request's reach
    ];
    chain.marketFrom = D + CAP + 1_000n;
    chain.finalized = D + CAP + 5_000n;
    chain.changes = [{block: D + CAP + 2_000n, logIndex: 0, kind: "supply", owner: ALICE, assets: 10n * SHARE}];
  });

  it("commits each epoch chunk and converges on the next request instead of rescanning from deployment", async () => {
    const d = deps({protocolDeploymentBlock: D});
    await expect(loadMorphoCollateralPoints(ALICE, d)).rejects.toBeInstanceOf(MorphoPointsNotReadyError);
    expect(chain.logCalls(POINTS)).toBe(MAX_CHUNKS_PER_REQUEST);
    expect(chain.logCalls(MORPHO_BLUE)).toBe(0); // nothing is replayed on a partial epoch list
    const served = credited(await loadMorphoCollateralPoints(ALICE, d));
    expect(chain.logCalls(POINTS)).toBe(MAX_CHUNKS_PER_REQUEST + 1); // resumed, not restarted
    expect(served.rateEpochs).toBe(2);
    expect(BigInt(served.points)).toBe(expectedPoints(ALICE, chain.finalized));
  });

  it("still refuses a resumed history that does not match rateEpochCount", async () => {
    const d = deps({protocolDeploymentBlock: D});
    await expect(loadMorphoCollateralPoints(ALICE, d)).rejects.toBeInstanceOf(MorphoPointsNotReadyError);
    chain.epochCountOverride = 3n;
    await expect(loadMorphoCollateralPoints(ALICE, d)).rejects.toThrow(/rateEpochCount/);
  });
});

describe("a request in flight while another request drops the history (MORPHO-11)", () => {
  /** Holds ALICE's per-wallet reads until `release`, after her request has taken its snapshot. */
  function holdAlice() {
    const reached = deferred();
    const gate = deferred();
    chain.positionGate = async (owner) => {
      if (owner !== ALICE.toLowerCase()) return;
      reached.resolve();
      await gate.promise;
    };
    return {reached: reached.promise, release: gate.resolve};
  }

  async function dropWithBobAt(block: bigint) {
    chain.changes.push({block, logIndex: 0, kind: "supply", owner: CAROL, assets: SHARE});
    chain.forgedHashBlocks.add(block);
    chain.finalized = block;
    await expect(loadMorphoCollateralPoints(BOB, deps())).rejects.toThrow(/canonical block/);
  }

  it("answers from its own snapshot, epoch count included, after the history is dropped", async () => {
    const held = holdAlice();
    const alice = loadMorphoCollateralPoints(ALICE, deps());
    await held.reached;
    await dropWithBobAt(201n);
    held.release();
    const served = credited(await alice);
    expect(served).toMatchObject({asOfBlock: "200", rateEpochs: 1});
    expect(BigInt(served.points)).toBe(expectedPoints(ALICE, 200n));
  });

  it("drops only the history that produced its snapshot, never a newer one", async () => {
    const held = holdAlice();
    const alice = loadMorphoCollateralPoints(ALICE, deps());
    await held.reached;
    await dropWithBobAt(201n);
    chain.forgedHashBlocks.clear();
    clock += 61_000;
    expect(await loadMorphoCollateralPoints(CAROL, deps())).toMatchObject({asOfBlock: "201", collateral: SHARE.toString()});
    // Alice's old snapshot now disagrees with what the RPC reports for her.
    chain.positionOverride.set(ALICE.toLowerCase(), 1n);
    held.release();
    await expect(alice).rejects.toThrow(/disagrees with Morpho Blue/);
    chain.positionOverride.clear();
    const calls = chain.getLogsCalls;
    expect(await loadMorphoCollateralPoints(CAROL, deps())).toMatchObject({asOfBlock: "201"});
    expect(chain.getLogsCalls).toBe(calls); // the newer history survived; nothing was rebuilt
  });
});

describe("history that nets back to the same end balance (MORPHO-12)", () => {
  const DAY = 7_200n;

  it("fails closed when a withdrawal and the later equal re-supply are both missing", async () => {
    chain.finalized = FROM + 97n * DAY;
    chain.changes = [
      {block: FROM + DAY / 4n, logIndex: 0, kind: "supply", owner: ALICE, assets: 1_000n * SHARE},
      {block: FROM + DAY, logIndex: 0, kind: "supply", owner: BOB, assets: 50n * SHARE},
      {block: FROM + 14n * DAY, logIndex: 0, kind: "withdraw", owner: ALICE, assets: 900n * SHARE},
      {block: FROM + 83n * DAY, logIndex: 0, kind: "supply", owner: ALICE, assets: 900n * SHARE},
    ];
    const honest = credited(await loadMorphoCollateralPoints(ALICE, deps()));
    expect(BigInt(honest.points)).toBe(expectedPoints(ALICE, chain.finalized));
    resetMorphoPointsCache();
    chain.hiddenLogs.add(`${FROM + 14n * DAY}:0`);
    chain.hiddenLogs.add(`${FROM + 83n * DAY}:0`);
    await expect(loadMorphoCollateralPoints(ALICE, deps())).rejects.toThrow(/disagrees with Morpho Blue/);
  });

  it("reads a range again in halves when an answer reaches the result limit", async () => {
    chain.finalized = FROM + 7_000n;
    chain.changes = Array.from({length: 1_200}, (_, i) => ({
      block: FROM + 1n + BigInt(i) * 5n,
      logIndex: 0,
      kind: "supply" as const,
      owner: i % 2 === 0 ? ALICE : BOB,
      assets: SHARE,
    }));
    chain.resultCap = LOG_RESULT_LIMIT; // a provider that silently truncates at the limit
    const served = credited(await loadMorphoCollateralPoints(ALICE, deps()));
    expect(served.collateral).toBe((600n * SHARE).toString());
    expect(BigInt(served.points)).toBe(expectedPoints(ALICE, chain.finalized));
  });

  it("fails closed when one block alone reaches the result limit", async () => {
    chain.changes = Array.from({length: LOG_RESULT_LIMIT}, (_, i) => ({
      block: FROM + 5n,
      logIndex: i,
      kind: "supply" as const,
      owner: ALICE,
      assets: SHARE,
    }));
    await expect(loadMorphoCollateralPoints(ALICE, deps())).rejects.toThrow(/too many logs/);
  });
});

describe("the on-chain ledger check (MORPHO-14)", () => {
  it("withholds an owner's points while the ledger tracks more sUSDfr than the wallet holds", async () => {
    // A hook that failed on the owner's leg of a routed supply left 900 shares tracked.
    chain.tracked.set(ALICE.toLowerCase(), 900n * SHARE);
    const answer = await loadMorphoCollateralPoints(ALICE, deps());
    expect(answer).toMatchObject({
      enabled: true,
      reconcileRequired: true,
      trackedShares: (900n * SHARE).toString(),
      walletShares: "0",
      collateral: (800n * SHARE).toString(),
    });
    expect(answer).not.toHaveProperty("points");
    expect(credited(await loadMorphoCollateralPoints(BOB, deps())).points).not.toBe("0");
  });

  it("serves the owner again once reconcile brings the ledger back to the balance", async () => {
    chain.tracked.set(ALICE.toLowerCase(), 900n * SHARE);
    chain.walletShares.set(ALICE.toLowerCase(), 100n * SHARE);
    expect(await loadMorphoCollateralPoints(ALICE, deps())).toMatchObject({reconcileRequired: true});
    chain.tracked.set(ALICE.toLowerCase(), 100n * SHARE); // reconcile(wallet) at the next block
    chain.finalized = 201n;
    const served = credited(await loadMorphoCollateralPoints(ALICE, deps()));
    expect(BigInt(served.points)).toBe(expectedPoints(ALICE, 201n));
  });

  it("does not hold back a ledger that is level with or below the wallet balance", async () => {
    chain.tracked.set(ALICE.toLowerCase(), 50n * SHARE);
    chain.walletShares.set(ALICE.toLowerCase(), 50n * SHARE);
    chain.walletShares.set(BOB.toLowerCase(), 7n * SHARE); // a dropped incoming leg: under-credited
    expect(BigInt(credited(await loadMorphoCollateralPoints(ALICE, deps())).points)).toBe(expectedPoints(ALICE, 200n));
    expect(BigInt(credited(await loadMorphoCollateralPoints(BOB, deps())).points)).toBe(expectedPoints(BOB, 200n));
  });

  it("does not hold back a wallet with no collateral history in the market", async () => {
    const stranger: Address = "0x0000000000000000000000000000000000005555";
    chain.tracked.set(stranger, 3n * SHARE);
    expect(await loadMorphoCollateralPoints(stranger, deps())).toMatchObject({collateral: "0", points: "0"});
  });

  it("still reports an exempt owner as exempt", async () => {
    chain.exempt.add(ALICE.toLowerCase());
    chain.tracked.set(ALICE.toLowerCase(), 900n * SHARE);
    expect(await loadMorphoCollateralPoints(ALICE, deps())).toMatchObject({points: "0", excluded: "protocol-exempt"});
  });
});

describe("loadMorphoCollateralPoints refuses history it cannot trust", () => {
  async function rejects(pattern: RegExp) {
    await expect(loadMorphoCollateralPoints(ALICE, deps())).rejects.toThrow(pattern);
  }

  it("a missing supply, instead of clamping the later withdrawal (reviewer M1)", async () => {
    chain.hiddenLogs.add("110:3");
    await rejects(/never saw supplied/);
  });

  it("an owner whose whole history is missing, through Morpho Blue's own position", async () => {
    chain.hiddenLogs.add("110:3");
    chain.hiddenLogs.add("130:2");
    await rejects(/disagrees with Morpho Blue/);
  });

  it("another owner's missing log, even when the requested wallet's own history is intact", async () => {
    chain.hiddenLogs.add("140:0"); // Bob's liquidation; Alice is the one asking
    await rejects(/disagrees with Morpho Blue/);
  });

  it("a log whose block hash is not the canonical block", async () => {
    chain.forgedHashBlocks.add(120n);
    await rejects(/canonical block/);
  });

  it("a market with other parameters", async () => {
    chain.lltv = 915_000_000_000_000_000n;
    await rejects(/not Forest Road's USDC\/sUSDfr market/);
  });

  it("a market priced by another oracle", async () => {
    chain.oracleVault = "0x0000000000000000000000000000000000009999";
    await rejects(/exit-value oracle/);
  });

  it("a look-alike market whose oracle answers the same wiring views from another address (MORPHO-16)", async () => {
    chain.marketOracle = "0x00000000000000000000000000000000000000e1";
    await rejects(/pinned MORPHO_SUSDFR_ORACLE/);
  });

  it("a creation block that is not the market's", async () => {
    chain.marketExistsBefore = true;
    await rejects(/creation block/);
  });

  it("an upgraded PointsModule, or a vault wired to another one", async () => {
    chain.implementation = "0x0000000000000000000000000000000000001234";
    await rejects(/implementation changed/);
    resetMorphoPointsCache();
    chain.implementation = POINTS_MODULE_IMPLEMENTATION;
    chain.vaultPointsModule = "0x0000000000000000000000000000000000001234";
    await rejects(/no longer reports this PointsModule/);
  });

  it("a rate history that does not match rateEpochCount", async () => {
    chain.epochCountOverride = 2n;
    await rejects(/rateEpochCount/);
  });

  it("drops the cache after an integrity failure and backs off before rebuilding", async () => {
    chain.hiddenLogs.add("110:3");
    await expect(loadMorphoCollateralPoints(ALICE, deps())).rejects.toBeInstanceOf(MorphoPointsIntegrityError);
    chain.hiddenLogs.clear();
    await expect(loadMorphoCollateralPoints(ALICE, deps())).rejects.toBeInstanceOf(MorphoPointsNotReadyError);
    clock += 61_000;
    expect(await loadMorphoCollateralPoints(ALICE, deps())).toMatchObject({collateral: (800n * SHARE).toString()});
  });
});

describe("an epoch history is replayed only after its count is checked (MORPHO-32)", () => {
  const D = 1_000n;
  const CAP = BigInt(MAX_CHUNKS_PER_REQUEST) * BLOCK_CHUNK;

  it("refuses, at the same head, a history whose count read failed after its last chunk", async () => {
    chain.epochs = [
      {block: 50n, rate: WAD},
      {block: 150n, rate: WAD / 2n}, // governance halves the rate while Alice holds collateral
    ];
    chain.hiddenLogs.add("150:0"); // and the RPC omits that log
    chain.failEpochCountReads = 1;
    await expect(loadMorphoCollateralPoints(ALICE, deps())).rejects.toThrow(/transport error/);
    await expect(loadMorphoCollateralPoints(ALICE, deps())).rejects.toThrow(/rateEpochCount/);
  });

  it("serves the right points at the same head after a failed count read when nothing is missing", async () => {
    chain.epochs = [
      {block: 50n, rate: WAD},
      {block: 150n, rate: WAD / 2n},
    ];
    chain.failEpochCountReads = 1;
    await expect(loadMorphoCollateralPoints(ALICE, deps())).rejects.toThrow(/transport error/);
    const served = credited(await loadMorphoCollateralPoints(ALICE, deps()));
    expect(served.rateEpochs).toBe(2);
    expect(BigInt(served.points)).toBe(expectedPoints(ALICE, 200n));
  });

  function lagAfterCap(hidden: boolean) {
    chain.epochs = [
      {block: D + 1n, rate: WAD},
      {block: D + CAP - 1_000n, rate: WAD / 2n}, // inside what the capped request commits
    ];
    if (hidden) chain.hiddenLogs.add(`${D + CAP - 1_000n}:0`);
    chain.marketFrom = D + CAP - 2_000n;
    chain.changes = [{block: D + CAP - 1_500n, logIndex: 0, kind: "supply", owner: ALICE, assets: 10n * SHARE}];
    chain.finalized = D + CAP + 5_000n;
  }

  it("refuses a lagging head at or below what a capped request committed, when an epoch log was missing", async () => {
    lagAfterCap(true);
    const d = deps({protocolDeploymentBlock: D});
    await expect(loadMorphoCollateralPoints(ALICE, d)).rejects.toBeInstanceOf(MorphoPointsNotReadyError);
    chain.finalized = D + CAP - 10n; // another backend node, behind the committed boundary
    await expect(loadMorphoCollateralPoints(ALICE, d)).rejects.toThrow(/rateEpochCount/);
  });

  it("serves the right points at such a lagging head when nothing is missing", async () => {
    lagAfterCap(false);
    const d = deps({protocolDeploymentBlock: D});
    await expect(loadMorphoCollateralPoints(ALICE, d)).rejects.toBeInstanceOf(MorphoPointsNotReadyError);
    chain.finalized = D + CAP - 10n;
    const served = credited(await loadMorphoCollateralPoints(ALICE, d));
    expect(served.rateEpochs).toBe(2);
    expect(BigInt(served.points)).toBe(expectedPoints(ALICE, D + CAP - 10n));
  });
});

describe("owners the replay holds at zero (MORPHO-55, M1001-m4-06 and -07)", () => {
  const GRID = BLOCK_CHUNK * ZERO_HELD_GRID_CHUNKS;
  /** The last block of chunk n, counted from 1 at the market's first block. */
  const chunkEnd = (n: bigint): bigint => FROM + n * BLOCK_CHUNK - 1n;

  /**
   * Alice holds throughout. Bob, the second owner seen, leaves early, so he is checked at the end of
   * chunks 1, 17, 33 and so on; later he supplies and withdraws again, and the RPC omits both logs.
   */
  function bobsUnseenRoundTrip(supplyAt: bigint, withdrawAt: bigint): void {
    chain.finalized = FROM + GRID + 2n * BLOCK_CHUNK;
    chain.changes = [
      {block: FROM + 10n, logIndex: 0, kind: "supply", owner: ALICE, assets: 10n * SHARE},
      {block: FROM + 20n, logIndex: 0, kind: "supply", owner: BOB, assets: 5n * SHARE},
      {block: FROM + 30n, logIndex: 0, kind: "withdraw", owner: BOB, assets: 5n * SHARE},
      {block: supplyAt, logIndex: 0, kind: "supply", owner: BOB, assets: 100n * SHARE},
      {block: withdrawAt, logIndex: 0, kind: "withdraw", owner: BOB, assets: 100n * SHARE},
    ];
    chain.hiddenLogs.add(`${supplyAt}:0`);
    chain.hiddenLogs.add(`${withdrawAt}:0`);
  }

  it("fails closed when the omitted round trip spans one of the owner's check blocks", async () => {
    bobsUnseenRoundTrip(chunkEnd(17n) - 1_000n, chunkEnd(17n) + 1_000n);
    await expect(loadMorphoCollateralPoints(ALICE, deps())).rejects.toThrow(/disagrees with Morpho Blue/);
  });

  it("between its check blocks under-counts and never over-counts, and checks an owner at zero once in 16 chunks", async () => {
    bobsUnseenRoundTrip(FROM + 2n * BLOCK_CHUNK + 10n, FROM + 4n * BLOCK_CHUNK + 10n);
    const served = credited(await loadMorphoCollateralPoints(BOB, deps()));
    expect(served.collateral).toBe("0");
    expect(BigInt(served.points)).toBeGreaterThan(0n);
    expect(BigInt(served.points)).toBeLessThan(expectedPoints(BOB, chain.finalized));
    // Chunk 1 touches both; chunks 2 to 16 check Alice alone; chunk 17 checks Bob at zero too; then
    // Alice alone to the served block, the first of chunk 19.
    const sizes = chain.multicalls.map((m) => m.size);
    expect(sizes).toEqual([2, ...Array<number>(15).fill(1), 2, 1, 1]);
  });

  it("checks them at the same blocks when the history was extended from a head mid-chunk (M1001-m4-06)", async () => {
    // Bob's round trip spans his check block at the end of chunk 17 and closes inside chunk 18.
    bobsUnseenRoundTrip(chunkEnd(17n) - 500n, chunkEnd(17n) + 2_000n);
    chain.finalized = chunkEnd(17n) + 4_000n;
    await expect(loadMorphoCollateralPoints(ALICE, deps())).rejects.toThrow(/disagrees with Morpho Blue/); // cold
    resetMorphoPointsCache();
    chain.multicalls.length = 0;
    // The same market on an instance first asked when the finalized head was 5,000 blocks in.
    const head = chain.finalized;
    chain.finalized = FROM + 5_000n;
    credited(await loadMorphoCollateralPoints(ALICE, deps()));
    chain.finalized = head;
    await expect(loadMorphoCollateralPoints(ALICE, deps())).rejects.toThrow(/disagrees with Morpho Blue/);
    // It finished chunk 1 before starting chunk 2, so every later check fell where a cold build's does.
    const ends = Array.from({length: 17}, (_, i) => chunkEnd(BigInt(i + 1)));
    expect(chain.multicalls.map((m) => m.block)).toEqual([FROM + 5_000n, ...ends]);
  });

  it("checks a sixteenth of the owners held at zero at each chunk's end, each once in 16 chunks (M1001-m4-07)", async () => {
    const owners = Array.from({length: 32}, (_, i) => `0x${(0x2000 + i).toString(16).padStart(40, "0")}` as Address);
    // Each supplies and leaves inside chunk 1, so from chunk 2 on the replay holds all 32 at zero.
    chain.changes = owners.flatMap((owner, i) => [
      {block: FROM + 1n + BigInt(i), logIndex: 0, kind: "supply" as const, owner, assets: SHARE},
      {block: FROM + 100n + BigInt(i), logIndex: 0, kind: "withdraw" as const, owner, assets: SHARE},
    ]);
    chain.finalized = chunkEnd(2n * ZERO_HELD_GRID_CHUNKS);
    credited(await loadMorphoCollateralPoints(owners[0], deps()));
    const [first, ...rest] = chain.multicalls;
    expect(first.size).toBe(32); // chunk 1 touched them all
    expect(rest).toHaveLength(31); // one read per chunk to the served block, never a pass over all 32
    rest.forEach((m, k) => {
      const n = k + 2;
      expect(m.block).toBe(chunkEnd(BigInt(n)));
      expect(m.owners).toEqual(owners.filter((_, i) => i % 16 === n % 16).map((owner) => owner.toLowerCase()));
    });
  });
});

describe("the cost of reconciling with Morpho Blue (MORPHO-31)", () => {
  /** The loader's multicalls go through viem's real multicall; every eth_call it sends is counted. */
  function countingClient(): {client: PublicClient; ethCalls: () => number} {
    let ethCalls = 0;
    const real = createPublicClient({
      chain: {...EXPECTED_CHAIN, contracts: {multicall3: {address: "0xcA11bde05977b3631167028862bE2a173976CA11", blockCreated: 0}}},
      transport: custom({
        async request({method, params}: {method: string; params?: unknown}) {
          if (method === "eth_chainId") return toHex(EXPECTED_CHAIN.id);
          if (method !== "eth_call") throw new Error(`counting client: unexpected ${method}`);
          ethCalls++;
          const [call, tag] = params as [{data: Hex}, Hex];
          const {args} = decodeFunctionData({abi: multicall3Abi, data: call.data});
          const inner = args[0] as readonly {target: Address; callData: Hex}[];
          const results = inner.map((c) => {
            const decoded = decodeFunctionData({abi: MORPHO_COLLATERAL_ABI, data: c.callData});
            const value = chain.read({address: c.target, functionName: decoded.functionName, args: decoded.args, blockNumber: BigInt(tag)});
            return {success: true, returnData: encodeFunctionResult({abi: MORPHO_COLLATERAL_ABI, functionName: "position", result: value as never})};
          });
          return encodeFunctionResult({abi: multicall3Abi, functionName: "aggregate3", result: results});
        },
      }),
    });
    const fake = chain.client();
    return {client: {...fake, multicall: (args: never) => real.multicall(args)} as unknown as PublicClient, ethCalls: () => ethCalls};
  }

  function manyOwners(count: number): Address[] {
    return Array.from({length: count}, (_, i) => `0x${(0x1000 + i).toString(16).padStart(40, "0")}` as Address);
  }

  it("reads each 200-owner batch in one eth_call and does not reconcile the served block twice", async () => {
    const owners = manyOwners(600);
    chain.changes = owners.map((owner, i) => ({block: FROM + 1n + BigInt(i), logIndex: 0, kind: "supply" as const, owner, assets: SHARE}));
    chain.finalized = FROM + 3n * BLOCK_CHUNK; // four chunks: three full and one of a single block
    const counting = countingClient();
    const served = credited(await loadMorphoCollateralPoints(owners[0], deps({client: counting.client})));
    expect(served.collateral).toBe(SHARE.toString());
    // Four chunks x three batches, one eth_call each, and no second pass at the served block.
    // Before the fix: 14 calls per batch (viem's 1,024-byte default) and the pass repeated: 210.
    expect(counting.ethCalls()).toBe(12);
  });

  it("checks at each boundary only the owners it could over-award, and the served block once", async () => {
    const DAVE: Address = "0x000000000000000000000000000000000000da7e";
    chain.changes = [
      {block: FROM + 10n, logIndex: 0, kind: "supply", owner: ALICE, assets: 10n * SHARE},
      {block: FROM + 20n, logIndex: 0, kind: "supply", owner: CAROL, assets: 5n * SHARE},
      {block: FROM + 30n, logIndex: 0, kind: "withdraw", owner: CAROL, assets: 5n * SHARE}, // Carol leaves in chunk 1
      {block: FROM + BLOCK_CHUNK + 40n, logIndex: 0, kind: "supply", owner: DAVE, assets: SHARE},
    ];
    chain.finalized = FROM + 3n * BLOCK_CHUNK - 1n; // exactly three chunks
    credited(await loadMorphoCollateralPoints(ALICE, deps()));
    // Chunk 1: Alice and Carol, both touched. Chunk 2: Alice (held) and Dave (touched), not Carol
    // at zero. Chunk 3: Alice and Dave, both held. The served block is the last chunk's end.
    expect(chain.multicalls.map((m) => m.size)).toEqual([2, 2, 2]);
    expect(chain.multicalls.filter((m) => m.block === chain.finalized)).toHaveLength(1);
    // Carol, held at zero, still gets her own position read when she asks.
    expect(await loadMorphoCollateralPoints(CAROL, deps())).toMatchObject({collateral: "0"});
  });

  it("overlaps a reconcile's batches, at most four at a time", async () => {
    const owners = manyOwners(1_000);
    chain.changes = owners.map((owner, i) => ({block: FROM + 1n + BigInt(i % 90), logIndex: Math.floor(i / 90), kind: "supply" as const, owner, assets: SHARE}));
    credited(await loadMorphoCollateralPoints(owners[0], deps()));
    expect(chain.multicalls.map((m) => m.size)).toEqual([200, 200, 200, 200, 200]); // one chunk, served block reused
    expect(chain.maxMulticallsInFlight).toBe(4);
  });

  it("measures its budget from the request's arrival, so a request that waited does one chunk and stops (MORPHO-71)", async () => {
    chain.finalized = FROM + 3n * BLOCK_CHUNK;
    const late = clock - REQUEST_BUDGET_MS - 1;
    await expect(loadMorphoCollateralPoints(ALICE, deps(), late)).rejects.toBeInstanceOf(MorphoPointsNotReadyError);
    expect(chain.logCalls(POINTS)).toBe(1);
    expect(chain.logCalls(MORPHO_BLUE)).toBe(0);
    // The next request, on time, carries on from what the first committed.
    credited(await loadMorphoCollateralPoints(ALICE, deps(), clock));
    expect(chain.logCalls(POINTS)).toBe(4);
  });

  it("bounds a request queued behind another build by the budget, what that build ran past its deadline and its own first chunk of each scan (M1001-m4-07)", async () => {
    chain.finalized = FROM + 100n * BLOCK_CHUNK;
    credited(await loadMorphoCollateralPoints(ALICE, deps())); // a warm instance
    chain.finalized += 60n * BLOCK_CHUNK;
    chain.collateralLogDelayMs = 1_000; // every collateral chunk now takes a second
    const start = clock;
    const before = chain.logCalls(MORPHO_BLUE);
    const first = loadMorphoCollateralPoints(ALICE, deps()).catch((error: unknown) => error);
    chain.finalized += 32n; // the second request sees a newer finalized head, so it queues
    const second = loadMorphoCollateralPoints(BOB, deps()).then(
      () => ({error: null as unknown, at: clock}),
      (error: unknown) => ({error, at: clock}),
    );
    expect(await first).toBeInstanceOf(MorphoPointsNotReadyError);
    // The first build started its last chunk at its deadline, 20 seconds in, and ended a second later.
    expect(chain.logCalls(MORPHO_BLUE) - before).toBe(REQUEST_BUDGET_MS / 1_000 + 1);
    const queued = await second;
    expect(queued.error).toBeInstanceOf(MorphoPointsNotReadyError);
    // The second waited for that, then ran its first rate chunk (no time here) and its first
    // collateral chunk, and stopped: the budget plus two chunks of a second, from its arrival.
    expect(chain.logCalls(MORPHO_BLUE) - before).toBe(REQUEST_BUDGET_MS / 1_000 + 2);
    expect(queued.at - start).toBe(REQUEST_BUDGET_MS + 2_000);
  });

  it("stops a slow cold build at its time budget, keeps what it committed, and converges", async () => {
    const D = 1_000n;
    chain.epochs = [{block: D + 1n, rate: WAD}];
    chain.marketFrom = D + 10n * BLOCK_CHUNK; // 91 collateral chunks after 101 epoch chunks
    chain.changes = [{block: D + 10n * BLOCK_CHUNK + 50n, logIndex: 0, kind: "supply", owner: ALICE, assets: SHARE}];
    chain.finalized = D + 100n * BLOCK_CHUNK + 100n;
    chain.logDelayMs = 1_000; // a one-second archive read
    const d = deps({protocolDeploymentBlock: D});
    const perRequest: number[] = [];
    let served: MorphoPointsWire | null = null;
    for (let attempt = 0; attempt < 20 && served === null; ++attempt) {
      const before = chain.getLogsCalls;
      try {
        served = await loadMorphoCollateralPoints(ALICE, d);
      } catch (error) {
        expect(error).toBeInstanceOf(MorphoPointsNotReadyError);
      }
      perRequest.push(chain.getLogsCalls - before);
    }
    expect(served).not.toBeNull();
    expect(BigInt(credited(served!).points)).toBe(expectedPoints(ALICE, chain.finalized));
    // The build took several requests, each stopped at the budget: at most its seconds of reads,
    // plus the first chunk of each of the two scans, which always runs so every request progresses.
    expect(perRequest.length).toBeGreaterThan(5);
    for (const n of perRequest) expect(n).toBeLessThanOrEqual(REQUEST_BUDGET_MS / 1_000 + 2);
    // Nothing was read twice: 101 epoch chunks and 91 collateral chunks in all.
    expect(chain.logCalls(POINTS)).toBe(101);
    expect(chain.logCalls(MORPHO_BLUE)).toBe(91);
  });
});
