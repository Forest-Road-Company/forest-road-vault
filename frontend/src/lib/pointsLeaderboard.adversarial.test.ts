/**
 * Adversarial tests from the independent server review of the leaderboard (11 October 2026).
 * Section A kills mutants that survived the first suite. Section B pins the behaviour each review
 * finding asked for (they failed on the first build). Section C documents a residual of the
 * completeness proof: a wallet that has fully exited is found by its events alone.
 */
import {beforeEach, describe, expect, it} from "vitest";
import {getAddress, pad, type Address, type Hex, type PublicClient} from "viem";
import {EXPECTED_CHAIN} from "@/lib/chain";
import {POINTS_MODULE_IMPLEMENTATION, type MorphoLeaderboard} from "@/lib/morphoPoints.server";
import {type PendleLeaderboardAnswer} from "@/lib/pendlePoints.server";
import {
  LEADERBOARD_TOPICS,
  LeaderboardIntegrityError,
  LeaderboardNotReadyError,
  LOG_CHUNK,
  LOG_RESULT_LIMIT,
  loadPointsLeaderboard,
  MAX_PARTICIPANTS,
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
const ERIN = wallet(0xe214);
const FR = wallet(0xf2);
const VENUE = wallet(0x4444);
const EXITED = wallet(0xe517);
const SPAMMER = wallet(0x5ba3);

const topicOf = (address: Address): Hex => pad(address.toLowerCase() as Hex);
const timeOf = (block: bigint): bigint => 1_790_000_000n + block * 12n;

type Holder = {shares: bigint; usdfr: bigint; points: bigint; blocked?: boolean; curator?: Record<number, bigint>};
type Log = {address: Address; topics: Hex[]; block: bigint};

class FakeChain {
  finalized = DEPLOY + 2n * LOG_CHUNK + 500n;
  holders = new Map<string, Holder>();
  logs: Log[] = [];
  hidden = new Set<number>();
  /** Hidden only from the next N eth_getLogs answers, like a lagging node behind a load balancer. */
  hiddenForCalls = 0;
  transientlyHidden = new Set<number>();
  logDelayMs = 0;
  getLogsCalls = 0;
  receiptsCalls = 0;
  /** Corrupt the first log of the next answer. */
  corrupt: null | "belowRange" | "foreignTopic0" | "transferTopicCount" | "ledgerTopicCount" | "firstLossTopicCount" = null;
  /** Make the next multicall answer one entry short. */
  shortMulticall = false;

  hold(address: Address, holder: Holder): void {
    this.holders.set(address.toLowerCase(), holder);
  }
  transfer(token: Address, from: Address, to: Address, block: bigint): number {
    return this.logs.push({address: token, topics: [LEADERBOARD_TOPICS.transfer, topicOf(from), topicOf(to)], block}) - 1;
  }
  accrued(who: Address, block: bigint): number {
    return this.logs.push({address: POINTS, topics: [LEADERBOARD_TOPICS.pointsAccrued, topicOf(who), pad("0x1")], block}) - 1;
  }
  reconciled(who: Address, block: bigint): number {
    return this.logs.push({address: POINTS, topics: [LEADERBOARD_TOPICS.reconciled, topicOf(who)], block}) - 1;
  }
  firstLoss(curator: Address, classId: number, block: bigint): number {
    return this.logs.push({address: CURATOR, topics: [LEADERBOARD_TOPICS.firstLossPosted, pad(`0x${classId.toString(16)}`), topicOf(curator)], block}) - 1;
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
    const holder = () => this.holders.get((c.args![0] as string).toLowerCase());
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
        return CURATOR;
      case "pointsModule":
        return POINTS;
      default:
        throw new Error(`fake chain: unexpected read ${c.functionName}`);
    }
  }
  private raw(log: Log) {
    return {address: log.address, topics: log.topics, data: "0x" as Hex, blockNumber: `0x${log.block.toString(16)}` as Hex};
  }
  getLogs(filter: {address: Address[]; topics: Hex[][]; fromBlock: Hex; toBlock: Hex}) {
    this.getLogsCalls++;
    clock += this.logDelayMs;
    const from = BigInt(filter.fromBlock);
    const to = BigInt(filter.toBlock);
    const addresses = filter.address.map((a) => a.toLowerCase());
    const wanted = filter.topics[0].map((t) => t.toLowerCase());
    const transient = this.hiddenForCalls > 0;
    if (transient) this.hiddenForCalls--;
    let answer = this.logs
      .map((log, index) => ({log, index}))
      .filter(({log, index}) => !this.hidden.has(index) && !(transient && this.transientlyHidden.has(index)) && log.block >= from && log.block <= to)
      .filter(({log}) => addresses.includes(log.address.toLowerCase()) && wanted.includes(log.topics[0].toLowerCase()))
      .map(({log}) => this.raw(log));
    if (this.corrupt && answer.length > 0) {
      const first = {...answer[0]};
      if (this.corrupt === "belowRange") first.blockNumber = `0x${(from - 1n).toString(16)}`;
      if (this.corrupt === "foreignTopic0") first.topics = [LEADERBOARD_TOPICS.firstLossPosted, ...first.topics.slice(1)];
      if (this.corrupt === "transferTopicCount" || this.corrupt === "ledgerTopicCount" || this.corrupt === "firstLossTopicCount") {
        first.topics = [...first.topics, pad("0x1")];
      }
      answer = [first, ...answer.slice(1)];
      this.corrupt = null;
    }
    return answer;
  }
  /** eth_getBlockReceipts: every log of the block, from every contract, uncapped. */
  receipts(block: bigint) {
    this.receiptsCalls++;
    return [{logs: this.logs.filter((log) => log.block === block).map((log) => ({...this.raw(log), removed: false}))}];
  }
  client(): PublicClient {
    const client = {
      getChainId: async () => EXPECTED_CHAIN.id,
      getBlock: async (args: {blockTag?: string; blockNumber?: bigint}) => {
        const n = args.blockTag === "finalized" ? this.finalized : args.blockNumber!;
        return {number: n, timestamp: timeOf(n)};
      },
      getStorageAt: async () => pad(POINTS_MODULE_IMPLEMENTATION),
      readContract: async (c: {address: Address; functionName: string; args?: readonly unknown[]}) => this.read(c),
      multicall: async (args: {contracts: {address: Address; functionName: string; args?: readonly unknown[]}[]}) => {
        const out = args.contracts.map((c) => this.read(c));
        if (this.shortMulticall) {
          this.shortMulticall = false;
          return out.slice(1);
        }
        return out;
      },
      request: async (args: {method: string; params: unknown[]}) => {
        if (args.method === "eth_getLogs") return this.getLogs(args.params[0] as never);
        if (args.method === "eth_getBlockReceipts") return this.receipts(BigInt(args.params[0] as Hex));
        throw new Error(`fake chain: unexpected ${args.method}`);
      },
    };
    return client as unknown as PublicClient;
  }
}

let chain: FakeChain;
let clock = 1_000_000;
const morphoOff: MorphoLeaderboard = {enabled: false};
const pendleOff: PendleLeaderboardAnswer = {ok: true, enabled: false};

function deps(overrides: Partial<LeaderboardDeps> = {}): LeaderboardDeps {
  return {
    client: chain.client(),
    contracts: {usdfr: USDFR, susdfr: SUSDFR, points: POINTS, curator: CURATOR, compliance: COMPLIANCE},
    protocolDeploymentBlock: DEPLOY,
    now: () => clock,
    morpho: async () => morphoOff,
    pendle: async () => pendleOff,
    forestRoad: [getAddress(FR)],
    venues: [{key: "uniswap-v4", label: "Uniswap v4 PoolManager", address: getAddress(VENUE), note: "pooled"}],
    ...overrides,
  };
}

function enabled(answer: LeaderboardWire) {
  if (!answer.enabled) throw new Error("expected an enabled leaderboard");
  return answer;
}

let aliceLogs: number[] = [];
let bobLogs: number[] = [];

beforeEach(() => {
  resetPointsLeaderboardCache();
  clock = 1_000_000;
  chain = new FakeChain();
  chain.hold(ALICE, {shares: 100n * E18, usdfr: 0n, points: 300n * E18});
  aliceLogs = [chain.transfer(SUSDFR, ZERO, ALICE, DEPLOY + 10n)];
  chain.hold(BOB, {shares: 0n, usdfr: 50n * E18, points: 100n * E18});
  bobLogs = [chain.transfer(USDFR, ZERO, BOB, DEPLOY + LOG_CHUNK + 5n), chain.accrued(BOB, DEPLOY + LOG_CHUNK + 6n)];
  chain.hold(ERIN, {shares: 0n, usdfr: 0n, points: 15n * E18, curator: {2: 10n * E18}});
  chain.firstLoss(ERIN, 2, DEPLOY + 2n * LOG_CHUNK + 3n);
  chain.hold(FR, {shares: 1_000n * E18, usdfr: 0n, points: 1_000n * E18});
  chain.transfer(SUSDFR, ZERO, FR, DEPLOY + 20n);
  chain.hold(VENUE, {shares: 0n, usdfr: 5_000n * E18, points: 5_000n * E18});
  chain.transfer(USDFR, ZERO, VENUE, DEPLOY + 30n);
});

describe("A. tests that kill mutants the shipped suite let survive", () => {
  it("L02: a USDfr-only holder whose events the provider left out fails the answer", async () => {
    for (const index of bobLogs) chain.hidden.add(index);
    await expect(loadPointsLeaderboard(deps())).rejects.toThrow(/do not account for the PointsModule's totals/);
  });

  it("L10: a jurisdiction-blocked venue stays on its venue line (precedence is venue, blocked, Forest Road)", async () => {
    chain.holders.get(VENUE.toLowerCase())!.blocked = true;
    chain.holders.get(FR.toLowerCase())!.blocked = true;
    const board = enabled(await loadPointsLeaderboard(deps()));
    expect(board.venues[0].points).toBe(String(5_000n * E18));
    expect(board.forestRoad).toEqual({wallets: 0, points: "0"});
    expect(board.notRanked).toEqual({jurisdictionBlocked: 1, belowOnePoint: 0});
  });

  it.each([
    ["L16: a Transfer log with a fourth topic", "transferTopicCount", /a Transfer log is malformed/],
    ["L20: a log below the requested range", "belowRange", /outside the requested filter/],
    ["L23: a log whose topic0 is another source's event", "foreignTopic0", /outside the requested filter/],
  ] as const)("%s is refused", async (_, corrupt, message) => {
    chain.corrupt = corrupt;
    await expect(loadPointsLeaderboard(deps())).rejects.toThrow(message);
  });

  it("L17: a PointsModule log with the wrong topic count is refused", async () => {
    // The first log of the second chunk is BOB's USDfr transfer; make the first chunk hold a ledger log first.
    chain.logs = [];
    chain.holders.clear();
    chain.hold(BOB, {shares: 0n, usdfr: 0n, points: 0n});
    chain.accrued(BOB, DEPLOY + 1n);
    chain.corrupt = "ledgerTopicCount";
    await expect(loadPointsLeaderboard(deps())).rejects.toThrow(/a PointsModule log is malformed/);
  });

  it("L18: a FirstLossPosted log with the wrong topic count is refused", async () => {
    chain.logs = [];
    chain.holders.clear();
    chain.hold(ERIN, {shares: 0n, usdfr: 0n, points: 0n});
    chain.firstLoss(ERIN, 1, DEPLOY + 1n);
    chain.corrupt = "firstLossTopicCount";
    await expect(loadPointsLeaderboard(deps())).rejects.toThrow(/a FirstLossPosted log is malformed/);
  });

  it("L25: a request that waited past its own deadline still reads one chunk", async () => {
    chain.finalized = DEPLOY + 10n * LOG_CHUNK;
    chain.logDelayMs = 1_000;
    const d = deps();
    const arrived = clock;
    clock += REQUEST_BUDGET_MS + 1; // it queued behind another build past its whole budget
    await expect(loadPointsLeaderboard(d, arrived)).rejects.toBeInstanceOf(LeaderboardNotReadyError);
    expect(chain.getLogsCalls).toBe(1);
  });

  it("L27: more participants than one answer reads fails closed", async () => {
    for (let i = 0; i <= MAX_PARTICIPANTS; i++) chain.transfer(USDFR, ZERO, wallet(0x100000 + i), DEPLOY + 100n);
    // A single block over the result limit is refused first, so spread them a log a block.
    chain.logs.forEach((log, index) => {
      if (index >= 5) log.block = DEPLOY + 100n + BigInt(index % 8_000);
    });
    await expect(loadPointsLeaderboard(deps())).rejects.toThrow(/more participants than one answer reads/);
  });

  it("L28: a multicall that answers the wrong number of reads fails closed", async () => {
    chain.shortMulticall = true;
    await expect(loadPointsLeaderboard(deps())).rejects.toThrow(/wrong number of answers/);
  });

  it("L38: a wallet named only by the PointsModule's own events is still discovered (defence in depth)", async () => {
    const ONLY_LEDGER = wallet(0x1ed6e2);
    chain.hold(ONLY_LEDGER, {shares: 3n * E18, usdfr: 0n, points: 7n * E18});
    chain.reconciled(ONLY_LEDGER, DEPLOY + 50n);
    const board = enabled(await loadPointsLeaderboard(deps()));
    expect(board.rows.map((row) => row.wallet)).toContain(getAddress(ONLY_LEDGER));
  });

  it("L34: a head below the protocol's deployment block is not ready", async () => {
    chain.finalized = DEPLOY - 1n;
    await expect(loadPointsLeaderboard(deps())).rejects.toThrow(/deployment block is not finalized yet/);
  });
});

describe("B. behaviour the findings ask for (fails on the reviewed code)", () => {
  it("F-M1: a provider that omitted a holder once does not fail the answer for the life of the instance", async () => {
    for (const index of aliceLogs) chain.transientlyHidden.add(index);
    chain.hiddenForCalls = 3; // the cold scan's three chunks come from a lagging node
    await expect(loadPointsLeaderboard(deps())).rejects.toBeInstanceOf(LeaderboardIntegrityError);
    // The node caught up. A later request (after any backoff) must be able to serve again.
    clock += 120_000;
    let served: LeaderboardWire | null = null;
    for (let attempt = 0; attempt < 3 && served === null; attempt++) {
      try {
        served = await loadPointsLeaderboard(deps());
      } catch (error) {
        if (!(error instanceof LeaderboardNotReadyError)) throw error;
        clock += 120_000;
      }
    }
    expect(enabled(served!).rows.map((row) => row.wallet)).toContain(getAddress(ALICE));
  });

  it("F-M2: a block holding LOG_RESULT_LIMIT permissionless Reconciled logs does not stop the board", async () => {
    // PointsModule.reconcile(wallet) is permissionless and always emits Reconciled(wallet): ~43.6k gas
    // a repeat on mainnet (measured with eth_estimateGas), so 1,000 fit in one ~44M-gas transaction.
    for (let i = 0; i < LOG_RESULT_LIMIT; i++) chain.reconciled(SPAMMER, DEPLOY + LOG_CHUNK + 100n);
    const board = enabled(await loadPointsLeaderboard(deps()));
    expect(board.ranked).toBe(3);
  });
});

describe("C. demonstration: the totals cannot prove an exited holder was found", () => {
  it("a wallet with points and nothing tracked, whose logs the provider omitted, is silently left out", async () => {
    chain.hold(EXITED, {shares: 0n, usdfr: 0n, points: 999n * E18}); // sold everything, kept its points
    const ins = chain.transfer(USDFR, ZERO, EXITED, DEPLOY + 40n);
    const out = chain.transfer(USDFR, EXITED, BOB, DEPLOY + 41n);
    chain.hidden.add(ins);
    chain.hidden.add(out);
    const board = enabled(await loadPointsLeaderboard(deps()));
    // Served, totals reconciled, and the top wallet is missing.
    expect(board.rows.map((row) => row.wallet)).not.toContain(getAddress(EXITED));
    expect(board.rows[0].wallet).toBe(getAddress(ALICE));
  });
});
