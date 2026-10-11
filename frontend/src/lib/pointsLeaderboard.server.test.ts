import {beforeEach, describe, expect, it} from "vitest";
import {getAddress, pad, type Address, type Hex, type PublicClient} from "viem";
import {EXPECTED_CHAIN} from "@/lib/chain";
import {POINTS_MODULE_IMPLEMENTATION, type MorphoLeaderboard} from "@/lib/morphoPoints.server";
import {PendlePointsUnavailableError, type PendleLeaderboardAnswer} from "@/lib/pendlePoints.server";
import {
  addressFromTopic,
  ANSWER_FRESH_MS,
  ANSWER_STALE_IF_ERROR_MS,
  answerTooLarge,
  LEADERBOARD_TOPICS,
  MAX_SPLITS_PER_RANGE,
  servePointsLeaderboard,
  LeaderboardIntegrityError,
  LeaderboardNotReadyError,
  LOG_CHUNK,
  LOG_RESULT_LIMIT,
  loadPointsLeaderboard,
  rankLeaderboard,
  REQUEST_BUDGET_MS,
  resetPointsLeaderboardCache,
  type LeaderboardDeps,
  type LeaderboardWire,
} from "@/lib/pointsLeaderboard.server";

const USDFR: Address = "0x00000000000000000000000000000000000000a1";
const SUSDFR: Address = "0x00000000000000000000000000000000000000a2";
const POINTS: Address = "0x00000000000000000000000000000000000000a3";
const CURATOR: Address = "0x00000000000000000000000000000000000000a4";
const COMPLIANCE: Address = "0x00000000000000000000000000000000000000a5";
const ZERO: Address = "0x0000000000000000000000000000000000000000";
const DEPLOY = 1_000n;
const E18 = 10n ** 18n;

const wallet = (n: number): Address => `0x${n.toString(16).padStart(40, "0")}`;
const ALICE = wallet(0xa11ce);
const BOB = wallet(0xb0b);
const CAROL = wallet(0xca201);
const DAVE = wallet(0xda7e);
const ERIN = wallet(0xe214);
const FR = wallet(0xf2);
const VENUE = wallet(0x4444);
const BLOCKED = wallet(0xb10c);
const GONE = wallet(0x60e);

const topicOf = (address: Address): Hex => pad(address.toLowerCase() as Hex);
const timeOf = (block: bigint): bigint => 1_790_000_000n + block * 12n;

type Holder = {shares: bigint; usdfr: bigint; points: bigint; blocked?: boolean; curator?: Record<number, bigint>};
type Log = {address: Address; topics: Hex[]; block: bigint; removed?: boolean};

/** A chain the loader can read: finalized head, the four event sources, and the views it checks. */
class FakeChain {
  finalized = DEPLOY + 2n * LOG_CHUNK + 500n; // three chunks
  chainId: number = EXPECTED_CHAIN.id;
  implementation: Address = POINTS_MODULE_IMPLEMENTATION;
  sharesHook: Address = POINTS;
  usdfrHook: Address = POINTS;
  curatorModule: Address = CURATOR;
  holders = new Map<string, Holder>();
  logs: Log[] = [];
  /** Logs an unreliable provider leaves out of its answers, by index in `logs`. */
  hidden = new Set<number>();
  /** A provider that silently returns at most this many logs per answer. */
  resultCap: number | null = null;
  /** A provider that refuses, as too big, any answer longer than this (rather than truncating it). */
  refuseOver: number | null = null;
  /** Logs a block's receipts leave out, by index in `logs` (receipts are otherwise complete). */
  receiptsDrop = new Set<number>();
  /** Milliseconds each eth_getLogs answer moves the test clock on. */
  logDelayMs = 0;
  getLogsCalls = 0;
  readonly multicallBlocks: bigint[] = [];
  readonly readBlocks: bigint[] = [];
  /** Corruptions of the next answer, each tested on its own. */
  corrupt: null | "removed" | "outside" | "otherAddress" | "malformedTopic" = null;

  hold(address: Address, holder: Holder): void {
    this.holders.set(address.toLowerCase(), holder);
  }

  transfer(token: Address, from: Address, to: Address, block: bigint): void {
    this.logs.push({address: token, topics: [LEADERBOARD_TOPICS.transfer, topicOf(from), topicOf(to)], block});
  }

  accrued(who: Address, block: bigint): void {
    this.logs.push({address: POINTS, topics: [LEADERBOARD_TOPICS.pointsAccrued, topicOf(who), pad("0x1")], block});
  }

  reconciled(who: Address, block: bigint): void {
    this.logs.push({address: POINTS, topics: [LEADERBOARD_TOPICS.reconciled, topicOf(who)], block});
  }

  firstLoss(curator: Address, classId: number, block: bigint): void {
    this.logs.push({address: CURATOR, topics: [LEADERBOARD_TOPICS.firstLossPosted, pad(`0x${classId.toString(16)}`), topicOf(curator)], block});
  }

  totals(): [bigint, bigint, bigint] {
    let shares = 0n;
    let usdfr = 0n;
    let curator = 0n;
    for (const h of this.holders.values()) {
      shares += h.shares;
      usdfr += h.usdfr;
      for (const value of Object.values(h.curator ?? {})) curator += value;
    }
    return [shares, usdfr, curator];
  }

  read(c: {address: Address; functionName: string; args?: readonly unknown[]}): unknown {
    const who = () => (c.args![0] as string).toLowerCase();
    const holder = () => this.holders.get(who());
    switch (c.functionName) {
      case "pointsOfWallet":
        return holder()?.points ?? 0n;
      case "trackedBalances":
        return [holder()?.shares ?? 0n, holder()?.usdfr ?? 0n];
      case "isJurisdictionBlocked":
        return holder()?.blocked ?? false;
      case "curatorTracked":
        return holder()?.curator?.[Number(c.args![1] as bigint)] ?? 0n;
      case "totals":
        return this.totals();
      case "curatorModule":
        return this.curatorModule;
      case "pointsModule":
        return c.address.toLowerCase() === SUSDFR.toLowerCase() ? this.sharesHook : this.usdfrHook;
      default:
        throw new Error(`fake chain: unexpected read ${c.functionName}`);
    }
  }

  getLogs(filter: {address: Address | Address[]; topics: (Hex | Hex[])[]; fromBlock: Hex; toBlock: Hex}) {
    this.getLogsCalls++;
    clock += this.logDelayMs;
    const from = BigInt(filter.fromBlock);
    const to = BigInt(filter.toBlock);
    const addresses = (Array.isArray(filter.address) ? filter.address : [filter.address]).map((a) => a.toLowerCase());
    const wanted = (Array.isArray(filter.topics[0]) ? filter.topics[0] : [filter.topics[0]]).map((t) => t.toLowerCase());
    let answer = this.logs
      .map((log, index) => ({log, index}))
      .filter(({log, index}) => !this.hidden.has(index) && log.block >= from && log.block <= to)
      .filter(({log}) => addresses.includes(log.address.toLowerCase()) && wanted.includes(log.topics[0].toLowerCase()))
      .map(({log}) => ({
        address: log.address,
        topics: log.topics,
        data: "0x" as Hex,
        blockNumber: `0x${log.block.toString(16)}` as Hex,
        removed: log.removed,
      }));
    if (this.corrupt && answer.length > 0) {
      const first = {...answer[0]};
      if (this.corrupt === "removed") first.removed = true;
      if (this.corrupt === "outside") first.blockNumber = `0x${(to + 1n).toString(16)}`;
      if (this.corrupt === "otherAddress") first.address = wallet(0xbad);
      if (this.corrupt === "malformedTopic") first.topics = [first.topics[0], `0x${"ff".repeat(32)}` as Hex, ...first.topics.slice(2)];
      answer = [first, ...answer.slice(1)];
    }
    if (this.refuseOver !== null && answer.length > this.refuseOver) {
      throw Object.assign(new Error("RPC Request failed: https://archive.example/v2/SECRET"), {
        cause: {code: -32008, shortMessage: "Response is too big", details: "Response is too big"},
      });
    }
    return this.resultCap === null ? answer : answer.slice(0, this.resultCap);
  }

  client(): PublicClient {
    const client = {
      getChainId: async () => this.chainId,
      getBlock: async (args: {blockTag?: string; blockNumber?: bigint}) => {
        const n = args.blockTag === "finalized" ? this.finalized : args.blockNumber!;
        return {number: n, timestamp: timeOf(n)};
      },
      getStorageAt: async () => pad(this.implementation),
      readContract: async (c: {address: Address; functionName: string; args?: readonly unknown[]; blockNumber?: bigint}) => {
        this.readBlocks.push(c.blockNumber!);
        return this.read(c);
      },
      multicall: async (args: {contracts: {address: Address; functionName: string; args?: readonly unknown[]}[]; blockNumber?: bigint}) => {
        this.multicallBlocks.push(args.blockNumber!);
        return args.contracts.map((c) => this.read(c));
      },
      request: async (args: {method: string; params: [{address: Address | Address[]; topics: (Hex | Hex[])[]; fromBlock: Hex; toBlock: Hex}]}) => {
        if (args.method === "eth_getBlockReceipts") {
          const block = BigInt(args.params[0] as unknown as Hex);
          const logs = this.logs
            .map((log, index) => ({log, index}))
            .filter(({log, index}) => log.block === block && !this.receiptsDrop.has(index))
            .map(({log}) => ({address: log.address, topics: log.topics, data: "0x" as Hex, blockNumber: `0x${block.toString(16)}` as Hex}));
          return [{logs}];
        }
        if (args.method !== "eth_getLogs") throw new Error(`fake chain: unexpected ${args.method}`);
        return this.getLogs(args.params[0]);
      },
    };
    return client as unknown as PublicClient;
  }
}

let chain: FakeChain;
let clock = 1_000_000;
let morpho: MorphoLeaderboard;
let pendle: PendleLeaderboardAnswer;

function deps(overrides: Partial<LeaderboardDeps> = {}): LeaderboardDeps {
  return {
    client: chain.client(),
    contracts: {usdfr: USDFR, susdfr: SUSDFR, points: POINTS, curator: CURATOR, compliance: COMPLIANCE},
    protocolDeploymentBlock: DEPLOY,
    now: () => clock,
    morpho: async () => morpho,
    pendle: async () => pendle,
    forestRoad: [getAddress(FR)],
    venues: [{key: "uniswap-v4", label: "Uniswap v4 PoolManager", address: getAddress(VENUE), note: "pooled"}],
    ...overrides,
  };
}

function enabled(answer: LeaderboardWire) {
  if (!answer.enabled) throw new Error("expected an enabled leaderboard");
  return answer;
}

beforeEach(() => {
  resetPointsLeaderboardCache();
  clock = 1_000_000;
  chain = new FakeChain();
  // On-chain holders, each found by its own kind of event.
  chain.hold(ALICE, {shares: 100n * E18, usdfr: 0n, points: 300n * E18});
  chain.transfer(SUSDFR, ZERO, ALICE, DEPLOY + 10n);
  chain.hold(BOB, {shares: 0n, usdfr: 50n * E18, points: 100n * E18});
  chain.transfer(USDFR, ZERO, BOB, DEPLOY + LOG_CHUNK + 5n);
  chain.accrued(BOB, DEPLOY + LOG_CHUNK + 6n);
  chain.hold(ERIN, {shares: 0n, usdfr: 0n, points: 15n * E18, curator: {2: 10n * E18}});
  chain.firstLoss(ERIN, 2, DEPLOY + 2n * LOG_CHUNK + 3n);
  chain.hold(FR, {shares: 1_000n * E18, usdfr: 0n, points: 1_000n * E18});
  chain.transfer(SUSDFR, ZERO, FR, DEPLOY + 20n);
  chain.hold(VENUE, {shares: 0n, usdfr: 5_000n * E18, points: 5_000n * E18});
  chain.transfer(USDFR, ZERO, VENUE, DEPLOY + 30n);
  chain.hold(BLOCKED, {shares: 40n * E18, usdfr: 0n, points: 40n * E18, blocked: true});
  chain.transfer(SUSDFR, ZERO, BLOCKED, DEPLOY + 40n);
  // GONE held and sold everything: tracked at zero and no points left to rank.
  chain.hold(GONE, {shares: 0n, usdfr: 0n, points: 0n});
  chain.transfer(USDFR, ZERO, GONE, DEPLOY + 50n);
  chain.transfer(USDFR, GONE, ALICE, DEPLOY + 60n);
  chain.reconciled(GONE, DEPLOY + 70n);
  // CAROL holds only a Pendle YT and DAVE only Morpho collateral: neither appears on-chain.
  pendle = {
    ok: true,
    enabled: true,
    asOfBlock: chain.finalized + 10n,
    asOfTimestamp: Number(timeOf(chain.finalized + 10n)),
    points: new Map([
      [BOB, 250n * E18],
      [CAROL, 300n * E18],
    ]),
  };
  morpho = {
    enabled: true,
    asOfBlock: chain.finalized,
    asOfTimestamp: timeOf(chain.finalized),
    points: new Map([[DAVE, 20n * E18]]),
    withheld: 1,
  };
});

describe("loadPointsLeaderboard", () => {
  it("ranks every wallet by its on-chain, Pendle and Morpho points, with ties sharing a rank", async () => {
    const board = enabled(await loadPointsLeaderboard(deps()));
    expect(board.rows.map((row) => [row.rank, row.wallet, row.points])).toEqual([
      [1, getAddress(BOB), String(350n * E18)],
      [2, getAddress(ALICE), String(300n * E18)],
      [2, getAddress(CAROL), String(300n * E18)],
      [4, getAddress(DAVE), String(20n * E18)],
      [5, getAddress(ERIN), String(15n * E18)],
    ]);
    expect(board.rows[0]).toMatchObject({onchain: String(100n * E18), pendle: String(250n * E18), morpho: "0"});
    expect(board.rows[3]).toMatchObject({onchain: "0", pendle: "0", morpho: String(20n * E18)});
    expect(board.ranked).toBe(5);
    expect(board.rankedPoints).toBe(String(985n * E18));
    expect(board.truncated).toBe(false);
    expect(board.asOfBlock).toBe(String(chain.finalized));
    expect(board.asOfTimestamp).toBe(String(timeOf(chain.finalized)));
    expect(board.pendle).toEqual({enabled: true, asOfBlock: String(chain.finalized + 10n), asOfTimestamp: Number(timeOf(chain.finalized + 10n))});
    expect(board.morpho).toEqual({enabled: true, withheld: 1});
  });

  it("reports Forest Road's wallets, each venue and the jurisdiction-blocked count on their own lines", async () => {
    const board = enabled(await loadPointsLeaderboard(deps()));
    const listed = board.rows.map((row) => row.wallet.toLowerCase());
    for (const unranked of [FR, VENUE, BLOCKED, GONE]) expect(listed).not.toContain(unranked);
    expect(board.forestRoad).toEqual({wallets: 1, points: String(1_000n * E18)});
    expect(board.venues).toEqual([
      {key: "uniswap-v4", label: "Uniswap v4 PoolManager", address: getAddress(VENUE), note: "pooled", points: String(5_000n * E18)},
    ]);
    expect(board.notRanked).toEqual({jurisdictionBlocked: 1, belowOnePoint: 0});
  });

  it("reads every on-chain figure at the Morpho snapshot's block, or at the finalized block when Morpho is off", async () => {
    morpho = {...morpho, asOfBlock: chain.finalized - 7n, asOfTimestamp: timeOf(chain.finalized - 7n)} as MorphoLeaderboard;
    const aligned = enabled(await loadPointsLeaderboard(deps()));
    expect(aligned.asOfBlock).toBe(String(chain.finalized - 7n));
    expect(new Set([...chain.multicallBlocks, ...chain.readBlocks])).toEqual(new Set([chain.finalized - 7n]));
    resetPointsLeaderboardCache();
    morpho = {enabled: false};
    chain.multicallBlocks.length = 0;
    chain.readBlocks.length = 0;
    const off = enabled(await loadPointsLeaderboard(deps()));
    expect(off.asOfBlock).toBe(String(chain.finalized));
    expect(off.morpho).toEqual({enabled: false, withheld: 0});
    expect(off.rows.map((row) => row.wallet)).not.toContain(getAddress(DAVE));
    expect(new Set([...chain.multicallBlocks, ...chain.readBlocks])).toEqual(new Set([chain.finalized]));
  });

  it("ranks without Pendle when the points site reports it off, and fails whole when the points site is down", async () => {
    pendle = {ok: true, enabled: false};
    const off = enabled(await loadPointsLeaderboard(deps()));
    expect(off.pendle).toEqual({enabled: false});
    expect(off.rows.find((row) => row.wallet === getAddress(BOB))?.points).toBe(String(100n * E18));
    expect(off.rows.map((row) => row.wallet)).not.toContain(getAddress(CAROL));
    const down = deps({pendle: async () => Promise.reject(new PendlePointsUnavailableError("pendle points: the points site did not answer"))});
    await expect(loadPointsLeaderboard(down)).rejects.toBeInstanceOf(PendlePointsUnavailableError);
  });

  it("proves the discovery complete: a holder whose event the provider left out fails the answer", async () => {
    // Every event that names ALICE (her mint and a later transfer in) is missing from the answers.
    chain.logs.forEach((log, index) => {
      if (log.topics.slice(1).includes(topicOf(ALICE))) chain.hidden.add(index);
    });
    expect(chain.hidden.size).toBe(2);
    await expect(loadPointsLeaderboard(deps())).rejects.toThrow(/do not account for the PointsModule's totals/);
  });

  it("proves curator first-loss complete too: a curator whose posting the provider left out fails the answer", async () => {
    chain.hidden.add(chain.logs.findIndex((log) => log.topics[0] === LEADERBOARD_TOPICS.firstLossPosted));
    await expect(loadPointsLeaderboard(deps())).rejects.toBeInstanceOf(LeaderboardIntegrityError);
  });

  it("splits a range a provider may have cut short, and reads a single crowded block from its receipts", async () => {
    // 1,500 holders minted in one range; the provider silently returns at most LOG_RESULT_LIMIT logs.
    for (let i = 0; i < 1_500; i++) {
      const holder = wallet(0x100000 + i);
      chain.hold(holder, {shares: 1n, usdfr: 0n, points: E18});
      chain.transfer(SUSDFR, ZERO, holder, DEPLOY + 100n + BigInt(i));
    }
    chain.resultCap = LOG_RESULT_LIMIT;
    const board = enabled(await loadPointsLeaderboard(deps()));
    expect(board.ranked).toBe(5 + 1_500);
    resetPointsLeaderboardCache();
    for (let i = 0; i < LOG_RESULT_LIMIT; i++) {
      const holder = wallet(0x200000 + i);
      chain.hold(holder, {shares: 1n, usdfr: 0n, points: E18});
      chain.transfer(SUSDFR, ZERO, holder, DEPLOY + 90n);
    }
    // A block with LOG_RESULT_LIMIT logs (anyone can fill one with permissionless Reconciled logs) is
    // read from its receipts instead of stopping the board for good.
    const crowded = enabled(await loadPointsLeaderboard(deps()));
    expect(crowded.ranked).toBe(5 + 1_500 + LOG_RESULT_LIMIT);
    // Receipts that hold fewer of the sources' logs than the capped answer did fail closed.
    resetPointsLeaderboardCache();
    chain.receiptsDrop.add(chain.logs.length - 1);
    await expect(loadPointsLeaderboard(deps())).rejects.toThrow(/receipts hold fewer logs than its log answer/);
  });

  it.each([
    ["removed", "a removed log"],
    ["outside", "a log past the requested range"],
    ["otherAddress", "a log from another contract"],
  ] as const)("refuses %s answer (%s)", async (corrupt, _description) => {
    chain.corrupt = corrupt;
    await expect(loadPointsLeaderboard(deps())).rejects.toThrow(/outside the requested filter/);
  });

  it("refuses an indexed address topic that is not an address", async () => {
    chain.corrupt = "malformedTopic";
    await expect(loadPointsLeaderboard(deps())).rejects.toThrow(/topic is malformed/);
    expect(() => addressFromTopic(undefined)).toThrow(LeaderboardIntegrityError);
    expect(addressFromTopic(topicOf(getAddress(ALICE)))).toBe(ALICE);
  });

  it.each([
    ["the archive RPC serves another chain", () => (chain.chainId = EXPECTED_CHAIN.id + 1), /another chain/],
    ["the PointsModule was upgraded", () => (chain.implementation = wallet(0x1234)), /implementation changed/],
    ["sUSDfr reports another PointsModule", () => (chain.sharesHook = wallet(0x5678)), /no longer reports this PointsModule/],
    ["USDfr reports another PointsModule", () => (chain.usdfrHook = wallet(0x5678)), /no longer reports this PointsModule/],
    ["the PointsModule reports another CuratorModule", () => (chain.curatorModule = wallet(0x9abc)), /another CuratorModule/],
  ])("fails closed when %s", async (_, change, message) => {
    change();
    await expect(loadPointsLeaderboard(deps())).rejects.toThrow(message);
  });

  it("extends the discovery from where it stopped, reading only the new chunks", async () => {
    await loadPointsLeaderboard(deps());
    const first = chain.getLogsCalls;
    expect(first).toBe(3); // three chunks, one request each for all four sources
    chain.finalized += LOG_CHUNK; // one more chunk, with a newcomer
    const NEW = wallet(0x0e3);
    chain.hold(NEW, {shares: 0n, usdfr: 9n * E18, points: 2n * E18});
    chain.transfer(USDFR, ZERO, NEW, chain.finalized - 1n);
    morpho = {...morpho, asOfBlock: chain.finalized, asOfTimestamp: timeOf(chain.finalized)} as MorphoLeaderboard;
    const board = enabled(await loadPointsLeaderboard(deps()));
    expect(chain.getLogsCalls - first).toBe(1);
    expect(board.rows.map((row) => row.wallet)).toContain(getAddress(NEW));
  });

  it("stops a slow cold discovery at its time budget, keeps what it read, and converges", async () => {
    chain.finalized = DEPLOY + 40n * LOG_CHUNK;
    morpho = {...morpho, asOfBlock: chain.finalized, asOfTimestamp: timeOf(chain.finalized)} as MorphoLeaderboard;
    chain.logDelayMs = 1_000;
    const d = deps();
    let served: LeaderboardWire | null = null;
    let attempts = 0;
    while (served === null && attempts < 20) {
      attempts++;
      try {
        served = await loadPointsLeaderboard(d, clock);
      } catch (error) {
        expect(error).toBeInstanceOf(LeaderboardNotReadyError);
      }
    }
    expect(attempts).toBeGreaterThan(1);
    expect(enabled(served!).ranked).toBe(5);
    // Nothing was read twice: 41 chunks, one request each.
    expect(chain.getLogsCalls).toBe(41);
    expect(REQUEST_BUDGET_MS).toBe(20_000);
  });

  it("answers off on a testnet build without reading anything", async () => {
    expect(await loadPointsLeaderboard()).toEqual({ok: true, enabled: false});
  });
});

describe("rankLeaderboard", () => {
  const base = {
    onchain: {points: new Map<string, bigint>(), blocked: new Set<string>()},
    morpho: new Map<string, bigint>(),
    pendle: new Map<string, bigint>(),
    forestRoad: [] as Address[],
    venues: [],
  };

  it("drops wallets whose parts add to nothing and orders equal totals by address", () => {
    const board = rankLeaderboard({
      ...base,
      onchain: {points: new Map([[BOB, 5n * E18], [ALICE, 5n * E18], [GONE, 0n]]), blocked: new Set()},
    });
    expect(board.ranked.map((row) => [row.rank, row.wallet])).toEqual([
      [1, getAddress(BOB)],
      [1, getAddress(ALICE)],
    ].sort((a, b) => ((a[1] as string).toLowerCase() < (b[1] as string).toLowerCase() ? -1 : 1)));
  });

  it("counts a Forest Road wallet's Pendle and Morpho points in its line, never in the ranks", () => {
    const board = rankLeaderboard({
      ...base,
      pendle: new Map([[FR, 7n]]),
      morpho: new Map([[FR, 3n]]),
      forestRoad: [getAddress(FR)],
    });
    expect(board.ranked).toEqual([]);
    expect(board.forestRoad).toEqual({wallets: 1, points: 10n});
  });
});

describe("review fixes", () => {
  it("does not rank a wallet below one whole point, and counts it", async () => {
    const DUST = wallet(0xd057);
    chain.hold(DUST, {shares: 0n, usdfr: 1n, points: E18 - 1n});
    chain.transfer(USDFR, ZERO, DUST, DEPLOY + 80n);
    const board = enabled(await loadPointsLeaderboard(deps()));
    expect(board.rows.map((row) => row.wallet)).not.toContain(getAddress(DUST));
    expect(board.notRanked).toEqual({jurisdictionBlocked: 1, belowOnePoint: 1});
  });

  it("splits a range a provider refuses as too big, and reads a refused single block from its receipts", async () => {
    // 300 mints over 150 blocks; the provider refuses any answer of more than 200 logs.
    for (let i = 0; i < 300; i++) {
      const holder = wallet(0x300000 + i);
      chain.hold(holder, {shares: 1n, usdfr: 0n, points: E18});
      chain.transfer(SUSDFR, ZERO, holder, DEPLOY + 100n + BigInt(i % 150));
    }
    chain.refuseOver = 200;
    expect(enabled(await loadPointsLeaderboard(deps())).ranked).toBe(5 + 300);
    // 250 more in one block: that block's own answer is refused, so its receipts are read.
    resetPointsLeaderboardCache();
    for (let i = 0; i < 250; i++) {
      const holder = wallet(0x350000 + i);
      chain.hold(holder, {shares: 1n, usdfr: 0n, points: E18});
      chain.transfer(SUSDFR, ZERO, holder, DEPLOY + 95n);
    }
    expect(enabled(await loadPointsLeaderboard(deps())).ranked).toBe(5 + 300 + 250);
  });

  it("stops splitting when a provider refuses every range, rather than reading every block", async () => {
    for (let i = 0; i < 64; i++) {
      const holder = wallet(0x400000 + i);
      chain.hold(holder, {shares: 1n, usdfr: 0n, points: E18});
      chain.transfer(SUSDFR, ZERO, holder, DEPLOY + 100n + BigInt(i * 97));
    }
    chain.refuseOver = 0; // refuses any answer at all
    const before = chain.getLogsCalls;
    await expect(loadPointsLeaderboard(deps())).rejects.toThrow(/refused or capped too many log ranges/);
    expect(chain.getLogsCalls - before).toBeLessThanOrEqual(MAX_SPLITS_PER_RANGE + 1);
  });

  it("recognises only a provider's too-large refusal, never a transport error carrying a URL", () => {
    expect(answerTooLarge({cause: {code: -32008, shortMessage: "Response is too big"}})).toBe(true);
    expect(answerTooLarge({code: -32005, shortMessage: "query returned more than 10000 results"})).toBe(true);
    expect(answerTooLarge({code: -32602, details: "Log response size exceeded"})).toBe(true);
    expect(answerTooLarge({code: -32602, shortMessage: "invalid argument 0: hex string"})).toBe(false);
    expect(answerTooLarge(new Error("fetch failed: https://archive.example/limit/too-big"))).toBe(false);
    expect(answerTooLarge({code: -32000, shortMessage: "header not found"})).toBe(false);
    expect(answerTooLarge(undefined)).toBe(false);
  });

  it("serves one load to concurrent requests and reuses a whole answer for a minute", async () => {
    let now = 0;
    let loads = 0;
    let release!: () => void;
    const gate = new Promise<void>((resolve) => (release = resolve));
    const load = async () => {
      loads++;
      await gate;
      return enabled(await loadPointsLeaderboard(deps()));
    };
    const first = servePointsLeaderboard(0, load, () => now);
    const second = servePointsLeaderboard(0, load, () => now);
    release();
    const [a, b] = await Promise.all([first, second]);
    expect(loads).toBe(1);
    expect(a).toEqual(b);
    now = ANSWER_FRESH_MS - 1;
    await servePointsLeaderboard(now, load, () => now);
    expect(loads).toBe(1);
    now = ANSWER_FRESH_MS;
    await servePointsLeaderboard(now, load, () => now);
    expect(loads).toBe(2);
  });

  it("stands in with the last whole answer while the loader fails, for a bounded time, never otherwise", async () => {
    let now = 0;
    const good = enabled(await loadPointsLeaderboard(deps()));
    await servePointsLeaderboard(0, async () => good, () => now);
    const failing = async (): Promise<LeaderboardWire> => {
      throw new LeaderboardIntegrityError("leaderboard: the discovered wallets do not account for the PointsModule's totals");
    };
    now = ANSWER_FRESH_MS + 1;
    const stale = await servePointsLeaderboard(now, failing, () => now);
    expect(stale.stale).toBe(true);
    expect(stale.answer).toBe(good);
    expect(stale.stale && stale.error).toBeInstanceOf(LeaderboardIntegrityError);
    now = ANSWER_STALE_IF_ERROR_MS;
    await expect(servePointsLeaderboard(now, failing, () => now)).rejects.toBeInstanceOf(LeaderboardIntegrityError);
    resetPointsLeaderboardCache();
    // With no whole answer yet, a failure is a failure; an "off" answer is never kept.
    await expect(servePointsLeaderboard(0, failing, () => 0)).rejects.toBeInstanceOf(LeaderboardIntegrityError);
    let offLoads = 0;
    const off = async (): Promise<LeaderboardWire> => {
      offLoads++;
      return {ok: true, enabled: false};
    };
    await servePointsLeaderboard(0, off, () => 0);
    await servePointsLeaderboard(1, off, () => 1);
    expect(offLoads).toBe(2);
  });
});
