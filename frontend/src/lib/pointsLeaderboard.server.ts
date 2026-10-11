import {
  createPublicClient,
  getAddress,
  http,
  isAddress,
  keccak256,
  toHex,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import {CONTRACTS, IS_MAINNET, PROTOCOL_DEPLOYMENT_BLOCK} from "@/config/contracts";
import {LEADERBOARD_MAX_ROWS, POINTS_VENUES} from "@/config/pointsLeaderboard";
import {OWNER_STATUS_ABI, POINTS_ABI, VAULT_POINTS_ABI} from "@/lib/abi";
import {EXPECTED_CHAIN} from "@/lib/chain";
import {
  loadMorphoCollateralLeaderboard,
  POINTS_MODULE_IMPLEMENTATION,
  type MorphoLeaderboard,
} from "@/lib/morphoPoints.server";
import {loadPendleLeaderboard, type PendleLeaderboardAnswer} from "@/lib/pendlePoints.server";
import {archiveRpcUrl} from "@/lib/transparencyHistory.server";

/**
 * The public points leaderboard (Forest Road direction, 11 October 2026): every wallet ranked by its
 * on-chain PointsModule points plus the points Forest Road computes for sUSDfr and USDfr it holds
 * through Pendle and Morpho.
 *
 * The on-chain part is read, never computed: each wallet's `pointsOfWallet` at one finalized block.
 * Who to read is discovered from the events that can create a position (both tokens' transfers, the
 * curator first-loss postings and the PointsModule's own accrual and reconcile events), and the
 * discovery is proven complete for every current holder before anything is served: the tracked
 * balances of every discovered wallet must add up, exactly, to the PointsModule's own totals at that
 * block, so a missed wallet that still holds a position leaves the sums short and the answer fails
 * closed. A wallet that has fully exited keeps its points with nothing tracked, so it is found by its
 * events alone: every path that gives a position a balance names the wallet in an event read here.
 *
 * Forest Road's own wallets and the venue contracts that hold tokens for many people (Uniswap,
 * Pendle's SY contracts, Morpho Blue) are not ranked; each is reported on its own line. A
 * jurisdiction-blocked wallet is not ranked either, as neither mirror credits one (decision D16).
 */

/** A state that is expected to clear on its own (still indexing, nothing finalized yet). Safe to log. */
export class LeaderboardNotReadyError extends Error {
  override name = "LeaderboardNotReadyError";
}

/** Something does not add up; nothing is served until it does. Safe to log. */
export class LeaderboardIntegrityError extends Error {
  override name = "LeaderboardIntegrityError";
}

/**
 * Blocks per `eth_getLogs` range while discovering participants: the Morpho loader's `BLOCK_CHUNK`, a
 * range the archive RPC serves. One request per range carries all four event sources.
 */
export const LOG_CHUNK = 9_000n;
/** An answer this long may have been cut short by a provider's cap, so its range is split and read again. */
export const LOG_RESULT_LIMIT = 1_000;
/** Participants one answer may read; past it the answer fails closed rather than run long. */
export const MAX_PARTICIPANTS = 20_000;
/** How long one request may extend the discovery before it answers "not ready", keeping its progress. */
export const REQUEST_BUDGET_MS = 20_000;
/**
 * After the totals proof fails, the committed discovery is dropped and rebuilt from the deployment
 * block, at most this often. Without it, one answer a lagging node left short would fail every later
 * request on the instance (or, for a holder that has since exited, drop it from every later board).
 */
export const REBUILD_BACKOFF_MS = 60_000;
/** Wallets below one whole point (dust, or a contract holding a few wei) are counted, not ranked. */
export const RANK_FLOOR = 10n ** 18n;
/** The PointsModule's curator classes (`Config.NUM_CLASSES`). */
export const CURATOR_CLASSES = 5;
const READ_BATCH = 200;
const READ_CONCURRENCY = 4;
/** Calldata one multicall may carry (viem's default of 1,024 bytes would split each batch many ways). */
const CALLDATA_BYTES = 16_384;
const IMPLEMENTATION_SLOT: Hex = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const ZERO = "0x0000000000000000000000000000000000000000";

export const LEADERBOARD_TOPICS = {
  transfer: keccak256(toHex("Transfer(address,address,uint256)")),
  pointsAccrued: keccak256(toHex("PointsAccrued(address,uint8,uint256)")),
  reconciled: keccak256(toHex("Reconciled(address)")),
  firstLossPosted: keccak256(toHex("FirstLossPosted(uint256,address,uint256,uint256,uint256)")),
} as const;

/** The PointsModule views the completeness proof reads, beside POINTS_ABI. */
export const LEDGER_ABI = [
  {
    type: "function",
    name: "totals",
    stateMutability: "view",
    inputs: [],
    outputs: [
      {name: "shares", type: "uint256"},
      {name: "usdfr", type: "uint256"},
      {name: "curator", type: "uint256"},
    ],
  },
  {type: "function", name: "curatorModule", stateMutability: "view", inputs: [], outputs: [{type: "address"}]},
] as const;

export type LeaderboardVenue = {key: string; label: string; address: Address; note: string};

/** Everything the loader reads through; injectable so tests can drive it without a network. */
export type LeaderboardDeps = {
  client: PublicClient;
  contracts: {usdfr: Address; susdfr: Address; points: Address; curator: Address; compliance: Address};
  protocolDeploymentBlock: bigint;
  now: () => number;
  morpho: (arrivedAt: number) => Promise<MorphoLeaderboard>;
  pendle: () => Promise<PendleLeaderboardAnswer>;
  forestRoad: readonly Address[];
  venues: readonly LeaderboardVenue[];
};

export type LeaderboardRow = {
  rank: number;
  wallet: Address;
  /** Raw points, 1e18 to a point: the sum of the three parts. */
  points: string;
  onchain: string;
  pendle: string;
  morpho: string;
};

export type LeaderboardWire =
  | {ok: true; enabled: false}
  | {
      ok: true;
      enabled: true;
      /** The finalized block every on-chain and Morpho figure is read at. */
      asOfBlock: string;
      asOfTimestamp: string;
      pendle: {enabled: false} | {enabled: true; asOfBlock: string; asOfTimestamp: number};
      morpho: {enabled: boolean; withheld: number};
      /** Every ranked wallet, though `rows` carries at most LEADERBOARD_MAX_ROWS of them. */
      ranked: number;
      rankedPoints: string;
      truncated: boolean;
      rows: LeaderboardRow[];
      forestRoad: {wallets: number; points: string};
      venues: (LeaderboardVenue & {points: string})[];
      /** Wallets left out of the ranks: jurisdiction-blocked, and those below one whole point. */
      notRanked: {jurisdictionBlocked: number; belowOnePoint: number};
    };

type RawLog = {
  address: Address;
  topics: Hex[];
  data: Hex;
  blockNumber: Hex;
  removed?: boolean;
};

type Discovery = {key: string; scannedTo: bigint; wallets: Set<string>; curators: Set<string>};

let discovery: Discovery | null = null;
let rebuildAfter = 0;
let queue: Promise<unknown> = Promise.resolve();

/** How long a whole answer is reused, so query spellings Next.js strips cannot each run the loader. */
export const ANSWER_FRESH_MS = 60_000;
/** How long the last whole answer, with its own block, may stand in while the loader fails. */
export const ANSWER_STALE_IF_ERROR_MS = 15 * 60_000;

let lastAnswer: {answer: LeaderboardWire; at: number} | null = null;
let answerInFlight: Promise<LeaderboardWire> | null = null;

/** Clears the per-instance discovery and answers. Tests only. */
export function resetPointsLeaderboardCache(): void {
  discovery = null;
  rebuildAfter = 0;
  queue = Promise.resolve();
  lastAnswer = null;
  answerInFlight = null;
}

function hex(n: bigint): Hex {
  return `0x${n.toString(16)}`;
}

/** The address a 32-byte indexed topic carries, or a refusal for anything else. */
export function addressFromTopic(topic: Hex | undefined): string {
  if (typeof topic !== "string" || !/^0x0{24}[0-9a-fA-F]{40}$/.test(topic)) {
    throw new LeaderboardIntegrityError("leaderboard: an indexed address topic is malformed");
  }
  return `0x${topic.slice(26).toLowerCase()}`;
}

/** The event sources one discovery request reads: each contract with the events it may answer. */
type Source = {address: Address; topics: readonly Hex[]};

/**
 * `eth_getLogs` over one range for every source at once, refusing any log that is not one of the
 * sources' own events, outside the range or removed. An answer of LOG_RESULT_LIMIT entries or more may
 * be truncated: the range is halved and each half read again, down to a single block, which then
 * fails closed.
 */
/**
 * Splits one discovery range may make, refused or capped answers together. A crowded block costs
 * about two per level, some 28 for a 9,000-block range; a provider that refuses every range runs out
 * here instead of splitting down to every block.
 */
export const MAX_SPLITS_PER_RANGE = 64;

async function getLogs(
  deps: LeaderboardDeps,
  sources: readonly Source[],
  from: bigint,
  to: bigint,
  budget: {splits: number} = {splits: MAX_SPLITS_PER_RANGE},
): Promise<RawLog[]> {
  const split = async (): Promise<RawLog[]> => {
    budget.splits -= 2;
    if (budget.splits < 0) {
      throw new LeaderboardIntegrityError("leaderboard: the RPC refused or capped too many log ranges to prove the answer complete");
    }
    const middle = from + (to - from) / 2n;
    return [...(await getLogs(deps, sources, from, middle, budget)), ...(await getLogs(deps, sources, middle + 1n, to, budget))];
  };
  let logs: RawLog[];
  try {
    logs = (await deps.client.request({
      method: "eth_getLogs",
      params: [
        {
          address: sources.map((source) => source.address),
          topics: [[...new Set(sources.flatMap((source) => source.topics))]],
          fromBlock: hex(from),
          toBlock: hex(to),
        },
      ],
    } as never)) as RawLog[];
  } catch (error) {
    // A provider that refuses an answer as too large (rather than truncating it) is asked for halves;
    // a single block is read from its receipts. Any other failure is thrown as it is, so an outage
    // costs one request, not a split down to every block of the range.
    if (!answerTooLarge(error)) throw error;
    if (from === to) return blockLogs(deps, sources, from, 0);
    return split();
  }
  if (!Array.isArray(logs)) throw new LeaderboardIntegrityError("leaderboard: the RPC's log answer is not a list");
  for (const log of logs) {
    const n = BigInt(log.blockNumber);
    const source = sources.find((candidate) => candidate.address.toLowerCase() === log.address?.toLowerCase());
    if (
      log.removed ||
      n < from ||
      n > to ||
      !source ||
      !source.topics.some((topic) => topic.toLowerCase() === log.topics?.[0]?.toLowerCase())
    ) {
      throw new LeaderboardIntegrityError("leaderboard: the RPC returned a log outside the requested filter");
    }
  }
  if (logs.length < LOG_RESULT_LIMIT) return logs;
  if (from === to) return blockLogs(deps, sources, from, logs.length);
  return split();
}

/** RPC codes providers use to refuse a log answer as too large, as opposed to failing outright. */
const TOO_LARGE_CODES = new Set([-32005, -32008, -32602]);

/**
 * Whether an `eth_getLogs` failure is a provider's "this answer is too large" refusal (seen live as
 * -32008 "Response is too big"; others answer -32005 "query returned more than 10000 results" or
 * -32602 "Log response size exceeded"). Only the error's code and short message are examined; a
 * transport error, whose message can carry the endpoint URL, never matches.
 */
export function answerTooLarge(error: unknown): boolean {
  for (let e: unknown = error, depth = 0; e && typeof e === "object" && depth < 5; e = (e as {cause?: unknown}).cause, depth++) {
    const {code, shortMessage, details} = e as {code?: unknown; shortMessage?: unknown; details?: unknown};
    const text = `${typeof shortMessage === "string" ? shortMessage : ""} ${typeof details === "string" ? details : ""}`;
    if (typeof code === "number" && TOO_LARGE_CODES.has(code) && /too big|too large|too many|more than|exceed|limit/i.test(text)) {
      return true;
    }
  }
  return false;
}

/**
 * Every source log of one block, from `eth_getBlockReceipts`: the receipts carry every log the block
 * emitted, so no result cap can cut them short. Anyone can fill a block with LOG_RESULT_LIMIT
 * permissionless `Reconciled` logs (about 44M gas), so refusing such a block would let them stop the
 * board for good. The capped `eth_getLogs` answer is a lower bound the receipts must meet.
 */
async function blockLogs(deps: LeaderboardDeps, sources: readonly Source[], block: bigint, atLeast: number): Promise<RawLog[]> {
  const receipts = (await deps.client.request({method: "eth_getBlockReceipts", params: [hex(block)]} as never)) as
    | {logs?: RawLog[]}[]
    | null;
  if (!Array.isArray(receipts)) throw new LeaderboardIntegrityError("leaderboard: the RPC's receipts answer is not a list");
  const out: RawLog[] = [];
  for (const receipt of receipts) {
    if (!Array.isArray(receipt?.logs)) throw new LeaderboardIntegrityError("leaderboard: a receipt carries no log list");
    for (const log of receipt.logs) {
      if (log.removed || BigInt(log.blockNumber) !== block) {
        throw new LeaderboardIntegrityError("leaderboard: a receipt log is not from the requested block");
      }
      const source = sources.find((candidate) => candidate.address.toLowerCase() === log.address?.toLowerCase());
      if (source && source.topics.some((topic) => topic.toLowerCase() === log.topics?.[0]?.toLowerCase())) out.push(log);
    }
  }
  if (out.length < atLeast) {
    throw new LeaderboardIntegrityError("leaderboard: a block's receipts hold fewer logs than its log answer");
  }
  return out;
}

function discoveryFor(deps: LeaderboardDeps): Discovery {
  const key = [deps.contracts.usdfr, deps.contracts.susdfr, deps.contracts.points, deps.contracts.curator]
    .map((address) => address.toLowerCase())
    .concat(String(deps.protocolDeploymentBlock))
    .join(":");
  if (discovery && discovery.key === key) return discovery;
  if (deps.now() < rebuildAfter) {
    throw new LeaderboardNotReadyError("leaderboard: rebuilding the participant discovery");
  }
  discovery = {key, scannedTo: 0n, wallets: new Set(), curators: new Set()};
  return discovery;
}

/** Every address one chunk of events names, checked shape by shape. */
async function readChunk(
  deps: LeaderboardDeps,
  from: bigint,
  to: bigint,
): Promise<{wallets: Set<string>; curators: Set<string>}> {
  const {contracts} = deps;
  const t = LEADERBOARD_TOPICS;
  const logs = await getLogs(
    deps,
    [
      {address: contracts.susdfr, topics: [t.transfer]},
      {address: contracts.usdfr, topics: [t.transfer]},
      {address: contracts.points, topics: [t.pointsAccrued, t.reconciled]},
      {address: contracts.curator, topics: [t.firstLossPosted]},
    ],
    from,
    to,
  );
  const of = (address: Address) => logs.filter((log) => log.address.toLowerCase() === address.toLowerCase());
  const [shares, usdfr, ledger, firstLoss] = [of(contracts.susdfr), of(contracts.usdfr), of(contracts.points), of(contracts.curator)];
  const wallets = new Set<string>();
  const curators = new Set<string>();
  for (const log of [...shares, ...usdfr]) {
    if (log.topics.length !== 3) throw new LeaderboardIntegrityError("leaderboard: a Transfer log is malformed");
    for (const topic of [log.topics[1], log.topics[2]]) {
      const address = addressFromTopic(topic);
      if (address !== ZERO) wallets.add(address);
    }
  }
  for (const log of ledger) {
    const expected = log.topics[0].toLowerCase() === t.pointsAccrued.toLowerCase() ? 3 : 2;
    if (log.topics.length !== expected) throw new LeaderboardIntegrityError("leaderboard: a PointsModule log is malformed");
    wallets.add(addressFromTopic(log.topics[1]));
  }
  for (const log of firstLoss) {
    if (log.topics.length !== 3) throw new LeaderboardIntegrityError("leaderboard: a FirstLossPosted log is malformed");
    const curator = addressFromTopic(log.topics[2]);
    wallets.add(curator);
    curators.add(curator);
  }
  return {wallets, curators};
}

/**
 * Extends the discovery to `toBlock`, committing each finalized chunk as it is read, so a cold
 * instance converges over successive requests. Past `deadline` it stops with "not ready", though
 * every request reads at least one chunk.
 */
async function extendDiscovery(deps: LeaderboardDeps, toBlock: bigint, deadline: number): Promise<Discovery> {
  const d = discoveryFor(deps);
  let from = d.scannedTo === 0n ? deps.protocolDeploymentBlock : d.scannedTo + 1n;
  let first = true;
  while (from <= toBlock) {
    if (!first && deps.now() > deadline) {
      throw new LeaderboardNotReadyError("leaderboard: still indexing participants");
    }
    first = false;
    const to = from + LOG_CHUNK - 1n < toBlock ? from + LOG_CHUNK - 1n : toBlock;
    const chunk = await readChunk(deps, from, to);
    const grown = new Set([...d.wallets, ...chunk.wallets]);
    if (grown.size > MAX_PARTICIPANTS) {
      throw new LeaderboardIntegrityError("leaderboard: more participants than one answer reads");
    }
    if (discovery !== d) throw new LeaderboardNotReadyError("leaderboard: the discovery was reset");
    d.wallets = grown;
    for (const curator of chunk.curators) d.curators.add(curator);
    d.scannedTo = to;
    from = to + 1n;
  }
  return d;
}

/** One discovery extension at a time; a request waiting behind another keeps its own deadline. */
function discoverTo(deps: LeaderboardDeps, toBlock: bigint, deadline: number): Promise<Discovery> {
  const run = () => extendDiscovery(deps, toBlock, deadline);
  const promise = queue.then(run, run);
  queue = promise.catch(() => undefined);
  return promise;
}

/** The chain, the ledger's implementation and every hook that feeds it, as the discovery assumes them. */
async function checkWiring(deps: LeaderboardDeps, block: bigint): Promise<void> {
  const {client, contracts} = deps;
  if ((await client.getChainId()) !== EXPECTED_CHAIN.id) {
    throw new LeaderboardIntegrityError("leaderboard: the archive RPC serves another chain");
  }
  const [slot, sharesHook, usdfrHook, curatorModule] = await Promise.all([
    client.getStorageAt({address: contracts.points, slot: IMPLEMENTATION_SLOT, blockNumber: block}),
    client.readContract({address: contracts.susdfr, abi: VAULT_POINTS_ABI, functionName: "pointsModule", blockNumber: block}),
    client.readContract({address: contracts.usdfr, abi: VAULT_POINTS_ABI, functionName: "pointsModule", blockNumber: block}),
    client.readContract({address: contracts.points, abi: LEDGER_ABI, functionName: "curatorModule", blockNumber: block}),
  ]);
  const implementation = slot ? `0x${slot.slice(-40)}` : "";
  if (implementation.toLowerCase() !== POINTS_MODULE_IMPLEMENTATION.toLowerCase()) {
    throw new LeaderboardIntegrityError("leaderboard: the PointsModule implementation changed; re-verify the discovery");
  }
  const points = contracts.points.toLowerCase();
  if ((sharesHook as Address).toLowerCase() !== points || (usdfrHook as Address).toLowerCase() !== points) {
    throw new LeaderboardIntegrityError("leaderboard: a token no longer reports this PointsModule");
  }
  if ((curatorModule as Address).toLowerCase() !== contracts.curator.toLowerCase()) {
    throw new LeaderboardIntegrityError("leaderboard: the PointsModule reports another CuratorModule");
  }
}

/** Runs `work` over `items` in batches, a few at a time, keeping the batches' order. */
async function inBatches<T, R>(items: readonly T[], work: (batch: readonly T[]) => Promise<R[]>): Promise<R[]> {
  const batches: T[][] = [];
  for (let i = 0; i < items.length; i += READ_BATCH) batches.push(items.slice(i, i + READ_BATCH));
  const out: R[] = [];
  for (let i = 0; i < batches.length; i += READ_CONCURRENCY) {
    const done = await Promise.all(batches.slice(i, i + READ_CONCURRENCY).map(work));
    for (const part of done) out.push(...part);
  }
  return out;
}

async function multicall(deps: LeaderboardDeps, block: bigint, calls: unknown[], expected: number): Promise<unknown[]> {
  if (calls.length === 0) return [];
  const reads = (await deps.client.multicall({
    contracts: calls as never,
    blockNumber: block,
    allowFailure: false,
    batchSize: CALLDATA_BYTES,
  })) as unknown[];
  if (reads.length !== expected) throw new LeaderboardIntegrityError("leaderboard: a read returned the wrong number of answers");
  return reads;
}

type Onchain = {points: Map<string, bigint>; blocked: Set<string>};

/**
 * Every discovered wallet's PointsModule points and jurisdiction status at `block`, and the proof the
 * discovery is complete: the wallets' tracked shares and USDfr, and the curators' tracked first-loss
 * in every class, must equal the PointsModule's own totals at the same block.
 */
async function readOnchain(
  deps: LeaderboardDeps,
  block: bigint,
  wallets: readonly string[],
  curators: readonly string[],
): Promise<Onchain> {
  const {contracts} = deps;
  const per = await inBatches(wallets, async (batch) => {
    const calls = batch.flatMap((wallet) => {
      const account = wallet as Address;
      return [
        {address: contracts.points, abi: POINTS_ABI, functionName: "pointsOfWallet", args: [account]},
        {address: contracts.points, abi: POINTS_ABI, functionName: "trackedBalances", args: [account]},
        {address: contracts.compliance, abi: OWNER_STATUS_ABI, functionName: "isJurisdictionBlocked", args: [account]},
      ];
    });
    const reads = await multicall(deps, block, calls, batch.length * 3);
    return batch.map((wallet, j) => ({
      wallet,
      points: reads[j * 3] as bigint,
      tracked: reads[j * 3 + 1] as readonly [bigint, bigint],
      blocked: reads[j * 3 + 2] as boolean,
    }));
  });
  const classes = Array.from({length: CURATOR_CLASSES}, (_, i) => BigInt(i + 1));
  const curatorTracked = await inBatches(curators, async (batch) => {
    const calls = batch.flatMap((curator) =>
      classes.map((classId) => ({
        address: contracts.points,
        abi: POINTS_ABI,
        functionName: "curatorTracked",
        args: [curator as Address, classId],
      })),
    );
    return (await multicall(deps, block, calls, batch.length * CURATOR_CLASSES)) as bigint[];
  });
  const totals = (await deps.client.readContract({
    address: contracts.points,
    abi: LEDGER_ABI,
    functionName: "totals",
    blockNumber: block,
  })) as readonly [bigint, bigint, bigint];
  let shares = 0n;
  let usdfr = 0n;
  for (const row of per) {
    shares += row.tracked[0];
    usdfr += row.tracked[1];
  }
  const curator = curatorTracked.reduce((sum, value) => sum + value, 0n);
  if (shares !== totals[0] || usdfr !== totals[1] || curator !== totals[2]) {
    throw new LeaderboardIntegrityError("leaderboard: the discovered wallets do not account for the PointsModule's totals");
  }
  const points = new Map<string, bigint>();
  const blocked = new Set<string>();
  for (const row of per) {
    if (row.blocked) blocked.add(row.wallet);
    if (row.points > 0n) points.set(row.wallet, row.points);
  }
  return {points, blocked};
}

type Settled<T> = {ok: true; value: T} | {ok: false; error: unknown};

function settle<T>(promise: Promise<T>): Promise<Settled<T>> {
  return promise.then(
    (value) => ({ok: true as const, value}),
    (error: unknown) => ({ok: false as const, error}),
  );
}

/** Ranks every credited wallet. Pure: the same inputs give the same board. */
export function rankLeaderboard(input: {
  onchain: Onchain;
  morpho: Map<string, bigint>;
  pendle: Map<string, bigint>;
  forestRoad: readonly Address[];
  venues: readonly LeaderboardVenue[];
}): {
  ranked: LeaderboardRow[];
  rankedPoints: bigint;
  forestRoad: {wallets: number; points: bigint};
  venues: (LeaderboardVenue & {points: bigint})[];
  jurisdictionBlocked: number;
  belowFloor: number;
} {
  const own = new Set(input.forestRoad.map((address) => address.toLowerCase()));
  const venueOf = new Map(input.venues.map((venue) => [venue.address.toLowerCase(), venue]));
  const venuePoints = new Map<string, bigint>();
  let ownWallets = 0;
  let ownPoints = 0n;
  let jurisdictionBlocked = 0;
  let belowFloor = 0;
  const candidates = new Set([...input.onchain.points.keys(), ...input.pendle.keys(), ...input.morpho.keys()]);
  const rows: {wallet: string; points: bigint; onchain: bigint; pendle: bigint; morpho: bigint}[] = [];
  for (const wallet of candidates) {
    const onchain = input.onchain.points.get(wallet) ?? 0n;
    const pendle = input.pendle.get(wallet) ?? 0n;
    const morpho = input.morpho.get(wallet) ?? 0n;
    const points = onchain + pendle + morpho;
    if (points === 0n) continue;
    const venue = venueOf.get(wallet);
    if (venue) {
      venuePoints.set(venue.key, (venuePoints.get(venue.key) ?? 0n) + points);
      continue;
    }
    if (input.onchain.blocked.has(wallet)) {
      jurisdictionBlocked += 1;
      continue;
    }
    if (own.has(wallet)) {
      ownWallets += 1;
      ownPoints += points;
      continue;
    }
    if (points < RANK_FLOOR) {
      belowFloor += 1;
      continue;
    }
    rows.push({wallet, points, onchain, pendle, morpho});
  }
  rows.sort((a, b) => (a.points === b.points ? (a.wallet < b.wallet ? -1 : 1) : a.points > b.points ? -1 : 1));
  const ranked: LeaderboardRow[] = [];
  let rankedPoints = 0n;
  rows.forEach((row, index) => {
    // Equal totals share a rank (1, 2, 2, 4).
    const rank = index > 0 && rows[index - 1].points === row.points ? ranked[index - 1].rank : index + 1;
    rankedPoints += row.points;
    ranked.push({
      rank,
      wallet: getAddress(row.wallet),
      points: row.points.toString(),
      onchain: row.onchain.toString(),
      pendle: row.pendle.toString(),
      morpho: row.morpho.toString(),
    });
  });
  return {
    ranked,
    rankedPoints,
    forestRoad: {wallets: ownWallets, points: ownPoints},
    venues: input.venues.map((venue) => ({...venue, points: venuePoints.get(venue.key) ?? 0n})),
    jurisdictionBlocked,
    belowFloor,
  };
}

/** The server-only setting naming Forest Road's own wallets, comma-separated. */
export const FOREST_ROAD_WALLETS_ENV = "POINTS_LEADERBOARD_FOREST_ROAD_WALLETS";

/**
 * Forest Road's own wallets, from server-only configuration: Forest Road chose not to publish them
 * (11 October 2026), so they are in neither the source nor the client bundle. Without the list each
 * of them would rank as a participant, so a missing, empty or malformed setting fails the board
 * instead. An error names an entry by its position, never its value.
 */
export function forestRoadWallets(env: Record<string, string | undefined> = process.env): Address[] {
  const raw = env[FOREST_ROAD_WALLETS_ENV]?.trim();
  if (!raw) throw new LeaderboardIntegrityError(`leaderboard: ${FOREST_ROAD_WALLETS_ENV} is not set`);
  const seen = new Set<string>();
  return raw.split(",").map((entry, index) => {
    const value = entry.trim();
    if (!isAddress(value, {strict: true})) {
      throw new LeaderboardIntegrityError(`leaderboard: ${FOREST_ROAD_WALLETS_ENV} entry ${index + 1} is not an address`);
    }
    if (seen.has(value.toLowerCase())) {
      throw new LeaderboardIntegrityError(`leaderboard: ${FOREST_ROAD_WALLETS_ENV} entry ${index + 1} is listed twice`);
    }
    seen.add(value.toLowerCase());
    return getAddress(value);
  });
}

function defaultDeps(): LeaderboardDeps | null {
  if (!IS_MAINNET) return null;
  const {USDfr, sUSDfr, PointsModule, CuratorModule, ComplianceRegistry} = CONTRACTS;
  if (!USDfr || !sUSDfr || !PointsModule || !CuratorModule || !ComplianceRegistry) {
    throw new LeaderboardIntegrityError("leaderboard: protocol addresses are not configured");
  }
  const forestRoad = forestRoadWallets();
  const client = createPublicClient({
    chain: EXPECTED_CHAIN,
    transport: http(archiveRpcUrl(), {timeout: 15_000, retryCount: 2, batch: true}),
  }) as PublicClient;
  return {
    client,
    contracts: {usdfr: USDfr, susdfr: sUSDfr, points: PointsModule, curator: CuratorModule, compliance: ComplianceRegistry},
    protocolDeploymentBlock: PROTOCOL_DEPLOYMENT_BLOCK,
    now: () => Date.now(),
    morpho: (arrivedAt) => loadMorphoCollateralLeaderboard(undefined, arrivedAt),
    pendle: () => loadPendleLeaderboard(),
    forestRoad,
    venues: POINTS_VENUES,
  };
}

/**
 * The leaderboard at the newest finalized block. The Morpho snapshot, when the market is configured,
 * fixes that block (it may be a little newer than this request's own finalized read), and every
 * on-chain read is taken there. Pendle points come from the points site as of its newest stored
 * block, which the answer reports separately. Any part that cannot be shown whole fails the answer:
 * no rank is published from a partial view.
 */
export async function loadPointsLeaderboard(injected?: LeaderboardDeps, arrivedAt?: number): Promise<LeaderboardWire> {
  const deps = injected ?? defaultDeps();
  if (!deps) return {ok: true, enabled: false};
  const started = arrivedAt ?? deps.now();
  const deadline = started + REQUEST_BUDGET_MS;
  const pendlePending = settle(deps.pendle());
  const morpho = await deps.morpho(started);
  let asOf: {number: bigint; timestamp: bigint};
  if (morpho.enabled) {
    asOf = {number: morpho.asOfBlock, timestamp: morpho.asOfTimestamp};
  } else {
    const finalized = await deps.client.getBlock({blockTag: "finalized"});
    if (finalized.number === null) throw new LeaderboardNotReadyError("leaderboard: no finalized block");
    asOf = {number: finalized.number, timestamp: finalized.timestamp};
  }
  if (asOf.number < deps.protocolDeploymentBlock) {
    throw new LeaderboardNotReadyError("leaderboard: the protocol's deployment block is not finalized yet");
  }
  await checkWiring(deps, asOf.number);
  const d = await discoverTo(deps, asOf.number, deadline);
  let onchain: Onchain;
  try {
    onchain = await readOnchain(deps, asOf.number, [...d.wallets], [...d.curators]);
  } catch (error) {
    if (error instanceof LeaderboardIntegrityError && discovery === d) {
      discovery = null;
      rebuildAfter = deps.now() + REBUILD_BACKOFF_MS;
    }
    throw error;
  }
  const pendleSettled = await pendlePending;
  if (!pendleSettled.ok) throw pendleSettled.error;
  const pendle = pendleSettled.value;
  const board = rankLeaderboard({
    onchain,
    morpho: morpho.enabled ? morpho.points : new Map(),
    pendle: pendle.enabled ? pendle.points : new Map(),
    forestRoad: deps.forestRoad,
    venues: deps.venues,
  });
  const rows = board.ranked.slice(0, LEADERBOARD_MAX_ROWS);
  return {
    ok: true,
    enabled: true,
    asOfBlock: asOf.number.toString(),
    asOfTimestamp: asOf.timestamp.toString(),
    pendle: pendle.enabled
      ? {enabled: true, asOfBlock: pendle.asOfBlock.toString(), asOfTimestamp: pendle.asOfTimestamp}
      : {enabled: false},
    morpho: {enabled: morpho.enabled, withheld: morpho.enabled ? morpho.withheld : 0},
    ranked: board.ranked.length,
    rankedPoints: board.rankedPoints.toString(),
    truncated: board.ranked.length > rows.length,
    rows,
    forestRoad: {wallets: board.forestRoad.wallets, points: board.forestRoad.points.toString()},
    venues: board.venues.map((venue) => ({...venue, points: venue.points.toString()})),
    notRanked: {jurisdictionBlocked: board.jurisdictionBlocked, belowOnePoint: board.belowFloor},
  };
}

export type ServedLeaderboard = {answer: LeaderboardWire; stale: false} | {answer: LeaderboardWire; stale: true; error: unknown};

/**
 * The route's view of the leaderboard. One load runs at a time and concurrent requests share it; a
 * whole answer is reused for ANSWER_FRESH_MS, so a query spelling Next.js strips before the handler
 * (each its own CDN key) cannot make every request a full load. While the loader fails, the last
 * whole answer stands in for up to ANSWER_STALE_IF_ERROR_MS, still showing the block it was read at;
 * the failure is returned beside it so the route still logs it. Never a partial view.
 */
export async function servePointsLeaderboard(
  arrivedAt: number,
  load: (arrivedAt: number) => Promise<LeaderboardWire> = (at) => loadPointsLeaderboard(undefined, at),
  now: () => number = Date.now,
): Promise<ServedLeaderboard> {
  if (lastAnswer && now() - lastAnswer.at < ANSWER_FRESH_MS) return {answer: lastAnswer.answer, stale: false};
  if (!answerInFlight) {
    const pending = load(arrivedAt);
    answerInFlight = pending;
    void pending.then(
      () => undefined,
      () => undefined,
    ).finally(() => {
      if (answerInFlight === pending) answerInFlight = null;
    });
  }
  try {
    const answer = await answerInFlight;
    if (answer.enabled) lastAnswer = {answer, at: now()};
    return {answer, stale: false};
  } catch (error) {
    if (lastAnswer && now() - lastAnswer.at < ANSWER_STALE_IF_ERROR_MS) return {answer: lastAnswer.answer, stale: true, error};
    throw error;
  }
}
