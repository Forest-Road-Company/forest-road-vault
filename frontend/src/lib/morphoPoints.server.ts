import {get as getBlob, put as putBlob} from "@vercel/blob";
import {
  createPublicClient,
  decodeEventLog,
  encodeEventTopics,
  getAddress,
  isAddress,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import {CONTRACTS, IS_MAINNET, PROTOCOL_DEPLOYMENT_BLOCK} from "@/config/contracts";
import {ERC20_ABI, ORACLE_WIRING_ABI, OWNER_STATUS_ABI, POINTS_ABI, POINTS_HISTORY_ABI, VAULT_POINTS_ABI} from "@/lib/abi";
import {createArchiveRpcTransport, isLogSizeLimitError} from "@/lib/archiveTransport.server";
import {EXPECTED_CHAIN} from "@/lib/chain";
import {
  MorphoPointsIntegrityError,
  replayCollateralPoints,
  type CollateralEvent,
  type OwnerPoints,
  type RateEpoch,
} from "@/lib/morphoPoints";
import {archiveRpcUrl} from "@/lib/transparencyHistory.server";

export {MorphoPointsIntegrityError};

/** A state that is expected to clear on its own (catching up, market not yet final). Safe to log. */
export class MorphoPointsNotReadyError extends Error {
  override name = "MorphoPointsNotReadyError";
}

/** Morpho Blue on Ethereum mainnet. */
export const MORPHO_BLUE: Address = "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb";
/** The only market parameters this credit applies to, beside the two tokens and the oracle. */
export const ADAPTIVE_CURVE_IRM: Address = "0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC";
export const MARKET_LLTV = 860_000_000_000_000_000n;
/**
 * The PointsModule implementations this mirror was verified against:
 *  - v2 launch (`impl_points` in contracts/deployments/1-production-v2.json): 0x63AA...E801
 *  - Stage 2 LMV remediation (audited commit ee9b228a, Sourcify exact_match): 0x84f0...978F
 * An unverified upgrade can change the formula, so the loader refuses to answer for any
 * implementation outside this reviewed allowlist.
 */
export const POINTS_MODULE_IMPLEMENTATION: Address = "0x63AA0ae03DDc7f938B7C5a22878bd02898c7E801";
export const STAGE2_POINTS_MODULE_IMPLEMENTATION: Address = "0x84f0e4DD9453865c27EFF43c955A4eA42A3D978F";
export const VERIFIED_POINTS_MODULE_IMPLEMENTATIONS: readonly Address[] = Object.freeze([
  POINTS_MODULE_IMPLEMENTATION,
  STAGE2_POINTS_MODULE_IMPLEMENTATION,
]);

export function isVerifiedPointsModuleImplementation(address: string): boolean {
  const lower = address.toLowerCase();
  return VERIFIED_POINTS_MODULE_IMPLEMENTATIONS.some((allowed) => allowed.toLowerCase() === lower);
}
const IMPLEMENTATION_SLOT: Hex = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const ONE_SHARE = 10n ** 24n;
export const BLOCK_CHUNK = 9_000n;
export const MAX_CHUNKS_PER_REQUEST = 400;
const HEADER_CONCURRENCY = 8;
const RECONCILE_BATCH = 200;
/** Batches of one reconcile in flight at once, so a large book does not wait on each in turn. */
const RECONCILE_CONCURRENCY = 4;
/**
 * Calldata one multicall may carry. viem splits at 1,024 bytes by default, which turns one
 * 200-owner batch (68 bytes a position read) into 14 archive calls; this keeps it to one.
 */
const RECONCILE_CALLDATA_BYTES = 16_384;
/**
 * How long one request may spend extending the history before it stops with "not ready",
 * keeping every chunk it committed, so a large cold build converges across requests instead of
 * running past the function's limit. It runs from the request's arrival (MORPHO-71) and is checked
 * only between chunks, and a build always runs the first chunk of each scan so every request makes
 * progress (MORPHO-10). So a request can take this long, plus what the build it waited behind ran
 * past its own deadline (at most one chunk of each scan, rate epochs and collateral), plus its own
 * first chunk of each scan, plus a few single reads (the wiring checks, the epoch count and the
 * wallet's own); each further build queued ahead of it, one per newer finalized head, adds its
 * first chunks (Corrovera M1001-m4-07). A collateral chunk reads one position for each owner it
 * touched or holds non-zero, and for a sixteenth of the owners held at zero
 * (`ZERO_HELD_GRID_CHUNKS`). A build that scans no chunk up to its head (a finalized head at or
 * below what a stopped build committed) reads every known owner's position at that head instead.
 */
export const REQUEST_BUDGET_MS = 20_000;
/**
 * Every known owner the replay holds at zero is reconciled once every this many chunks. Chunk n,
 * counted from 1, ends at the market's first block plus n * `BLOCK_CHUNK` - 1, and an owner is
 * checked at the end of each chunk n congruent to its index modulo this (its place, from 0, in the
 * order the history first saw it): the first owner at every 16th chunk's end, the second at the end
 * of chunks 1, 17, 33 and so on. An omitted supply and withdrawal of a known owner held at zero is
 * caught when one of its check blocks falls between them, which one always does when they are 16
 * chunks (144,000 blocks, about 20 days) or more apart; a shorter one can under-count the owner and
 * never over-counts (Corrovera MORPHO-55; the residual sits with MORPHO-12's). Spread this way,
 * each chunk reads a sixteenth of the owners held at zero, where every 16th chunk used to read
 * every owner ever seen (M1001-m4-07).
 */
export const ZERO_HELD_GRID_CHUNKS = 16n;
const REBUILD_BACKOFF_MS = 60_000;
/**
 * An `eth_getLogs` answer this long may have been cut short by a provider's result cap, so its
 * range is split and read again. Far above what one 9,000-block range of this market holds.
 */
export const LOG_RESULT_LIMIT = 1_000;
/**
 * Splits one log range may make, refused or capped answers together. Bounds adaptive halving so a
 * provider that refuses every range fails closed instead of splitting down to every block.
 */
export const MAX_SPLITS_PER_RANGE = 64;
const MAX_BLOCK_HEADER_CACHE = 5_000;
const WALLET_CACHE_TTL_MS = 60_000;
const MAX_WALLET_CACHE = 500;

/** Morpho Blue's collateral events and the two views the loader checks against. */
export const MORPHO_COLLATERAL_ABI = [
  {
    type: "event",
    name: "SupplyCollateral",
    anonymous: false,
    inputs: [
      {name: "id", type: "bytes32", indexed: true},
      {name: "caller", type: "address", indexed: true},
      {name: "onBehalf", type: "address", indexed: true},
      {name: "assets", type: "uint256", indexed: false},
    ],
  },
  {
    type: "event",
    name: "WithdrawCollateral",
    anonymous: false,
    inputs: [
      {name: "id", type: "bytes32", indexed: true},
      {name: "caller", type: "address", indexed: false},
      {name: "onBehalf", type: "address", indexed: true},
      {name: "receiver", type: "address", indexed: true},
      {name: "assets", type: "uint256", indexed: false},
    ],
  },
  {
    type: "event",
    name: "Liquidate",
    anonymous: false,
    inputs: [
      {name: "id", type: "bytes32", indexed: true},
      {name: "caller", type: "address", indexed: true},
      {name: "borrower", type: "address", indexed: true},
      {name: "repaidAssets", type: "uint256", indexed: false},
      {name: "repaidShares", type: "uint256", indexed: false},
      {name: "seizedAssets", type: "uint256", indexed: false},
      {name: "badDebtAssets", type: "uint256", indexed: false},
      {name: "badDebtShares", type: "uint256", indexed: false},
    ],
  },
  {
    type: "function",
    name: "idToMarketParams",
    stateMutability: "view",
    inputs: [{name: "id", type: "bytes32"}],
    outputs: [
      {name: "loanToken", type: "address"},
      {name: "collateralToken", type: "address"},
      {name: "oracle", type: "address"},
      {name: "irm", type: "address"},
      {name: "lltv", type: "uint256"},
    ],
  },
  {
    type: "function",
    name: "position",
    stateMutability: "view",
    inputs: [
      {name: "id", type: "bytes32"},
      {name: "user", type: "address"},
    ],
    outputs: [
      {name: "supplyShares", type: "uint256"},
      {name: "borrowShares", type: "uint128"},
      {name: "collateral", type: "uint128"},
    ],
  },
] as const;

/** topic0 of each collateral event, verified against Morpho Blue mainnet logs on 28 Sep 2026. */
export const MORPHO_COLLATERAL_TOPICS = {
  SupplyCollateral: "0xa3b9472a1399e17e123f3c2e6586c23e504184d504de59cdaa2b375e880c6184",
  WithdrawCollateral: "0xe80ebd7cc9223d7382aab2e0d1d6155c65651f83d53c8b9b06901d167e321142",
  Liquidate: "0xa4946ede45d0c6f06a0f5ce92c9ad3b4751452d2fe0e25010783bcab57a67e41",
} as const;
export const RATE_EPOCH_TOPIC = encodeEventTopics({abi: POINTS_HISTORY_ABI, eventName: "RateEpochAppended"})[0];

export type MorphoPointsConfig = {marketId: Hex; fromBlock: bigint; oracle: Address};

/**
 * The market to credit, from server-only configuration: its id, its `createMarket` block and the
 * SUSDfrExitValueOracle it was created with. All three are required together and only on
 * mainnet; with none set the feature is off. Set them once the creation block is finalized,
 * about fifteen minutes after `createMarket`.
 */
export function morphoPointsConfig(
  env: Record<string, string | undefined> = process.env,
  mainnet = IS_MAINNET,
): MorphoPointsConfig | null {
  if (!mainnet) return null;
  const id = env.MORPHO_SUSDFR_MARKET_ID?.trim();
  const from = env.MORPHO_SUSDFR_MARKET_FROM_BLOCK?.trim();
  const oracle = env.MORPHO_SUSDFR_ORACLE?.trim();
  if (!id && !from && !oracle) return null;
  if (!id || !from || !oracle) {
    throw new MorphoPointsIntegrityError(
      "MORPHO_SUSDFR_MARKET_ID, MORPHO_SUSDFR_MARKET_FROM_BLOCK and MORPHO_SUSDFR_ORACLE must be set together",
    );
  }
  if (!/^0x[0-9a-fA-F]{64}$/.test(id)) {
    throw new MorphoPointsIntegrityError("MORPHO_SUSDFR_MARKET_ID is not a bytes32 market id");
  }
  if (!/^[1-9][0-9]*$/.test(from)) {
    throw new MorphoPointsIntegrityError("MORPHO_SUSDFR_MARKET_FROM_BLOCK is not a block number");
  }
  if (!isAddress(oracle, {strict: true})) {
    throw new MorphoPointsIntegrityError("MORPHO_SUSDFR_ORACLE is not an address");
  }
  return {marketId: id.toLowerCase() as Hex, fromBlock: BigInt(from), oracle: getAddress(oracle)};
}

/** A raw `eth_getLogs` entry. */
export type RawLog = {
  address: Address;
  topics: Hex[];
  data: Hex;
  blockNumber: Hex;
  blockHash: Hex;
  logIndex: Hex;
  transactionHash: Hex;
  removed?: boolean;
};

/** Decodes one raw Morpho log into a collateral change, or throws on anything unexpected. */
export function decodeCollateralLog(
  log: {topics: readonly Hex[]; data: Hex; blockNumber: bigint | null; logIndex: number | null},
  marketId: Hex,
  timestamp: bigint,
): CollateralEvent {
  if (log.blockNumber === null || log.logIndex === null) {
    throw new MorphoPointsIntegrityError("points: pending log in history");
  }
  const decoded = decodeEventLog({
    abi: MORPHO_COLLATERAL_ABI,
    topics: log.topics as [Hex, ...Hex[]],
    data: log.data,
    strict: true,
  });
  if (decoded.args.id.toLowerCase() !== marketId.toLowerCase()) {
    throw new MorphoPointsIntegrityError("points: log from another market");
  }
  const base = {blockNumber: log.blockNumber, logIndex: log.logIndex, timestamp};
  switch (decoded.eventName) {
    case "SupplyCollateral":
      return {...base, kind: "supply", owner: decoded.args.onBehalf, assets: decoded.args.assets};
    case "WithdrawCollateral":
      return {...base, kind: "withdraw", owner: decoded.args.onBehalf, assets: decoded.args.assets};
    case "Liquidate":
      return {...base, kind: "liquidate", owner: decoded.args.borrower, assets: decoded.args.seizedAssets};
  }
}

export type MorphoHistorySnapshot = {
  epochsScannedTo: bigint;
  epochs: RateEpoch[];
  scannedTo: bigint;
  events: CollateralEvent[];
  owners: string[];
  balances: Array<[string, bigint]>;
};

export type MorphoHistorySnapshotStore = {
  load: (expectedKey: string) => Promise<MorphoHistorySnapshot | null>;
  save: (key: string, snapshot: MorphoHistorySnapshot) => Promise<void>;
};

/** Everything the loader reads through; injectable so tests can drive it without a network. */
export type MorphoPointsDeps = {
  client: PublicClient;
  config: MorphoPointsConfig;
  contracts: {usdc: Address; susdfr: Address; controller: Address; points: Address; compliance: Address};
  protocolDeploymentBlock: bigint;
  now: () => number;
  snapshotStore?: MorphoHistorySnapshotStore;
};

/**
 * One finalized answer. It carries everything the per-wallet step reads after its own awaits, so
 * a concurrent integrity drop of the module-level history cannot change what it serves.
 */
type Snapshot = {
  asOfBlock: bigint;
  asOfTimestamp: bigint;
  owners: Map<string, OwnerPoints>;
  rateEpochs: number;
  history: History;
};
type History = {
  key: string;
  verified: boolean;
  hydratedFromStore: boolean;
  events: CollateralEvent[];
  scannedTo: bigint;
  epochs: RateEpoch[];
  epochsScannedTo: bigint;
  /** The block at which `epochs` last matched `rateEpochCount`. Only a verified history is replayed. */
  epochsVerifiedTo: bigint;
  owners: Set<string>;
  /** Each owner's collateral after the last committed chunk, checked against Morpho Blue there. */
  balances: Map<string, bigint>;
  snapshot: Snapshot | null;
};

const MORPHO_SNAPSHOT_BLOB_PATH = "morpho-points/history-v1.json";
const MORPHO_SNAPSHOT_IO_TIMEOUT_MS = 4_000;
const MORPHO_SNAPSHOT_MAX_BYTES = 4 * 1024 * 1024;
const MORPHO_SNAPSHOT_MAX_EVENTS = 100_000;
const MORPHO_SNAPSHOT_MAX_EPOCHS = 10_000;
const MORPHO_SNAPSHOT_MAX_OWNERS = 20_000;
const UINT_STR = /^(0|[1-9][0-9]*)$/;
const LOWER_ADDR = /^0x[0-9a-f]{40}$/;

async function readBoundedBlobText(stream: ReadableStream<Uint8Array>, maxBytes: number): Promise<string | null> {
  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const {done, value} = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) return null;
      chunks.push(value);
    }
  } finally {
    await reader.cancel().catch(() => undefined);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder("utf-8", {fatal: true}).decode(bytes);
}

function blobMorphoHistoryStore(): MorphoHistorySnapshotStore | undefined {
  if (!process.env.BLOB_READ_WRITE_TOKEN) return undefined;
  return {
    async load(expectedKey: string): Promise<MorphoHistorySnapshot | null> {
      try {
        const result = await getBlob(MORPHO_SNAPSHOT_BLOB_PATH, {
          access: "private",
          useCache: false,
          abortSignal: AbortSignal.timeout(MORPHO_SNAPSHOT_IO_TIMEOUT_MS),
        });
        if (!result || result.statusCode !== 200 || !result.stream) return null;
        const text = await readBoundedBlobText(result.stream, MORPHO_SNAPSHOT_MAX_BYTES);
        if (text === null) return null;
        const parsed = JSON.parse(text) as Record<string, unknown>;
        if (
          parsed.version !== 1 ||
          parsed.key !== expectedKey ||
          typeof parsed.epochsScannedTo !== "string" ||
          !UINT_STR.test(parsed.epochsScannedTo) ||
          typeof parsed.scannedTo !== "string" ||
          !UINT_STR.test(parsed.scannedTo) ||
          !Array.isArray(parsed.epochs) ||
          parsed.epochs.length > MORPHO_SNAPSHOT_MAX_EPOCHS ||
          !Array.isArray(parsed.events) ||
          parsed.events.length > MORPHO_SNAPSHOT_MAX_EVENTS ||
          !Array.isArray(parsed.owners) ||
          parsed.owners.length > MORPHO_SNAPSHOT_MAX_OWNERS ||
          !Array.isArray(parsed.balances) ||
          parsed.balances.length > MORPHO_SNAPSHOT_MAX_OWNERS
        ) {
          return null;
        }
        const epochs: RateEpoch[] = [];
        for (const rawEpoch of parsed.epochs) {
          if (!rawEpoch || typeof rawEpoch !== "object" || Array.isArray(rawEpoch)) return null;
          const e = rawEpoch as Record<string, unknown>;
          if (
            typeof e.start !== "string" ||
            !UINT_STR.test(e.start) ||
            typeof e.ratePerUnitDay !== "string" ||
            !UINT_STR.test(e.ratePerUnitDay)
          ) {
            return null;
          }
          epochs.push({start: BigInt(e.start), ratePerUnitDay: BigInt(e.ratePerUnitDay)});
        }
        const events: CollateralEvent[] = [];
        for (const rawEvent of parsed.events) {
          if (!rawEvent || typeof rawEvent !== "object" || Array.isArray(rawEvent)) return null;
          const ev = rawEvent as Record<string, unknown>;
          if (
            (ev.kind !== "supply" && ev.kind !== "withdraw" && ev.kind !== "liquidate") ||
            typeof ev.blockNumber !== "string" ||
            !UINT_STR.test(ev.blockNumber) ||
            typeof ev.logIndex !== "number" ||
            !Number.isSafeInteger(ev.logIndex) ||
            ev.logIndex < 0 ||
            typeof ev.timestamp !== "string" ||
            !UINT_STR.test(ev.timestamp) ||
            typeof ev.owner !== "string" ||
            !isAddress(ev.owner) ||
            typeof ev.assets !== "string" ||
            !UINT_STR.test(ev.assets)
          ) {
            return null;
          }
          events.push({
            kind: ev.kind,
            blockNumber: BigInt(ev.blockNumber),
            logIndex: ev.logIndex,
            timestamp: BigInt(ev.timestamp),
            owner: getAddress(ev.owner),
            assets: BigInt(ev.assets),
          });
        }
        const owners: string[] = [];
        for (const owner of parsed.owners) {
          if (typeof owner !== "string" || !LOWER_ADDR.test(owner)) return null;
          owners.push(owner);
        }
        const balances: Array<[string, bigint]> = [];
        for (const entry of parsed.balances) {
          if (
            !Array.isArray(entry) ||
            entry.length !== 2 ||
            typeof entry[0] !== "string" ||
            !LOWER_ADDR.test(entry[0]) ||
            typeof entry[1] !== "string" ||
            !UINT_STR.test(entry[1])
          ) {
            return null;
          }
          balances.push([entry[0], BigInt(entry[1])]);
        }
        return {
          epochsScannedTo: BigInt(parsed.epochsScannedTo),
          epochs,
          scannedTo: BigInt(parsed.scannedTo),
          events,
          owners,
          balances,
        };
      } catch (error) {
        const name = error instanceof Error ? error.name : "UnknownError";
        console.error(`morpho.snapshot load failed: ${name}`);
        return null;
      }
    },
    async save(key: string, snapshot: MorphoHistorySnapshot): Promise<void> {
      await putBlob(
        MORPHO_SNAPSHOT_BLOB_PATH,
        JSON.stringify({
          version: 1,
          key,
          epochsScannedTo: snapshot.epochsScannedTo.toString(),
          epochs: snapshot.epochs.map((e) => ({
            start: e.start.toString(),
            ratePerUnitDay: e.ratePerUnitDay.toString(),
          })),
          scannedTo: snapshot.scannedTo.toString(),
          events: snapshot.events.map((ev) => ({
            kind: ev.kind,
            blockNumber: ev.blockNumber.toString(),
            logIndex: ev.logIndex,
            timestamp: ev.timestamp.toString(),
            owner: ev.owner,
            assets: ev.assets.toString(),
          })),
          owners: snapshot.owners,
          balances: snapshot.balances.map(([owner, bal]) => [owner, bal.toString()]),
        }),
        {
          access: "private",
          contentType: "application/json",
          addRandomSuffix: false,
          allowOverwrite: true,
          abortSignal: AbortSignal.timeout(MORPHO_SNAPSHOT_IO_TIMEOUT_MS),
        },
      );
    },
  };
}

let history: History | null = null;
let rebuildAfter = 0;
let skipHistorySnapshotUntilVerified = false;
let lastSavedHistoryCursor = "";
let queue: Promise<unknown> = Promise.resolve();
let inflight: {target: bigint; promise: Promise<Snapshot>} | null = null;
const blockHeaderCache = new Map<bigint, {hash: Hex; timestamp: bigint}>();
const walletAnswerCache = new Map<string, {answer: MorphoPointsWire; at: number}>();
const walletAnswerInFlight = new Map<string, Promise<MorphoPointsWire>>();

/** Clears the per-instance cache. Tests only. */
export function resetMorphoPointsCache(): void {
  history = null;
  rebuildAfter = 0;
  skipHistorySnapshotUntilVerified = false;
  lastSavedHistoryCursor = "";
  queue = Promise.resolve();
  inflight = null;
  blockHeaderCache.clear();
  walletAnswerCache.clear();
  walletAnswerInFlight.clear();
}

function historyCursorKey(h: History): string {
  return `${h.key}:${h.epochsScannedTo}:${h.scannedTo}`;
}

async function persistHistorySnapshot(deps: MorphoPointsDeps, h: History): Promise<void> {
  if (!deps.snapshotStore || (h.epochsScannedTo === 0n && h.scannedTo === 0n)) return;
  const cursor = historyCursorKey(h);
  if (cursor === lastSavedHistoryCursor) return;
  try {
    await deps.snapshotStore.save(h.key, {
      epochsScannedTo: h.epochsScannedTo,
      epochs: [...h.epochs],
      scannedTo: h.scannedTo,
      events: [...h.events],
      owners: [...h.owners],
      balances: [...h.balances.entries()],
    });
    lastSavedHistoryCursor = cursor;
  } catch (error) {
    const name = error instanceof Error ? error.name : "UnknownError";
    console.error(`morpho.snapshot save failed: ${name}`);
  }
}

/** Drops `h` after an integrity failure, unless a newer history has already replaced it. */
function dropHistory(deps: MorphoPointsDeps, h: History): void {
  if (history !== h) return;
  history = null;
  skipHistorySnapshotUntilVerified = true;
  lastSavedHistoryCursor = "";
  blockHeaderCache.clear();
  walletAnswerCache.clear();
  rebuildAfter = deps.now() + REBUILD_BACKOFF_MS;
}

function historyFor(deps: MorphoPointsDeps): History {
  const key = `${deps.config.marketId}:${deps.config.fromBlock}:${deps.config.oracle.toLowerCase()}`;
  if (history && history.key === key) return history;
  if (deps.now() < rebuildAfter) {
    throw new MorphoPointsNotReadyError("points: rebuilding history after an integrity failure");
  }
  history = {
    key,
    verified: false,
    hydratedFromStore: false,
    events: [],
    scannedTo: 0n,
    epochs: [],
    epochsScannedTo: 0n,
    epochsVerifiedTo: 0n,
    owners: new Set(),
    balances: new Map(),
    snapshot: null,
  };
  return history;
}

function hex(n: bigint): Hex {
  return `0x${n.toString(16)}`;
}

function answerTooLarge(error: unknown): boolean {
  return isLogSizeLimitError(error);
}

function logMatchesTopics(log: RawLog, topics: (Hex | Hex[] | null)[]): boolean {
  for (let i = 0; i < topics.length; i += 1) {
    const expected = topics[i];
    if (expected === null || expected === undefined) continue;
    const actual = log.topics?.[i]?.toLowerCase();
    if (!actual) return false;
    if (Array.isArray(expected)) {
      if (!expected.some((candidate) => candidate.toLowerCase() === actual)) return false;
    } else if (expected.toLowerCase() !== actual) {
      return false;
    }
  }
  return true;
}

/**
 * Fallback for a single block whose `eth_getLogs` hit the provider's result cap or size refusal:
 * read the block's full receipts and filter locally so one crowded block cannot DoS the mirror.
 */
async function blockLogs(
  deps: MorphoPointsDeps,
  address: Address,
  topics: (Hex | Hex[] | null)[],
  block: bigint,
  atLeast: number,
): Promise<RawLog[]> {
  const receipts = (await deps.client.request({method: "eth_getBlockReceipts", params: [hex(block)]} as never)) as
    | {logs?: RawLog[]}[]
    | null;
  if (!Array.isArray(receipts)) {
    throw new MorphoPointsIntegrityError("points: the RPC's receipts answer is not a list");
  }
  const out: RawLog[] = [];
  const targetAddress = address.toLowerCase();
  for (const receipt of receipts) {
    if (!Array.isArray(receipt?.logs)) {
      throw new MorphoPointsIntegrityError("points: a receipt carries no log list");
    }
    for (const log of receipt.logs) {
      if (log.removed || BigInt(log.blockNumber) !== block) {
        throw new MorphoPointsIntegrityError("points: a receipt log is not from the requested block");
      }
      if (log.address?.toLowerCase() === targetAddress && logMatchesTopics(log, topics)) {
        out.push(log);
      }
    }
  }
  if (out.length < atLeast) {
    throw new MorphoPointsIntegrityError("points: a block's receipts hold fewer logs than its log answer");
  }
  return out;
}

/**
 * `eth_getLogs` over one range, refusing anything outside the filter. An answer of
 * LOG_RESULT_LIMIT entries or more, or a provider "too large" refusal, is halved (bounded by
 * MAX_SPLITS_PER_RANGE), down to a single block which falls back to `eth_getBlockReceipts`.
 */
async function getLogs(
  deps: MorphoPointsDeps,
  address: Address,
  topics: (Hex | Hex[] | null)[],
  from: bigint,
  to: bigint,
  budget: {splits: number} = {splits: MAX_SPLITS_PER_RANGE},
): Promise<RawLog[]> {
  const split = async (): Promise<RawLog[]> => {
    budget.splits -= 2;
    if (budget.splits < 0) {
      throw new MorphoPointsIntegrityError(
        "points: the RPC refused or capped too many log ranges to prove the answer complete",
      );
    }
    const middle = from + (to - from) / 2n;
    const first = await getLogs(deps, address, topics, from, middle, budget);
    const second = await getLogs(deps, address, topics, middle + 1n, to, budget);
    return [...first, ...second];
  };
  let logs: RawLog[];
  try {
    logs = (await deps.client.request({
      method: "eth_getLogs",
      params: [{address, topics, fromBlock: hex(from), toBlock: hex(to)}],
    } as never)) as RawLog[];
  } catch (error) {
    if (!answerTooLarge(error)) throw error;
    if (from === to) return blockLogs(deps, address, topics, from, 0);
    return split();
  }
  if (!Array.isArray(logs)) {
    throw new MorphoPointsIntegrityError("points: the RPC's log answer is not a list");
  }
  for (const log of logs) {
    const n = BigInt(log.blockNumber);
    if (log.removed || n < from || n > to || log.address?.toLowerCase() !== address.toLowerCase()) {
      throw new MorphoPointsIntegrityError("points: the RPC returned a log outside the requested filter");
    }
  }
  if (logs.length < LOG_RESULT_LIMIT) return logs;
  if (from === to) return blockLogs(deps, address, topics, from, logs.length);
  return split();
}

async function headers(
  deps: MorphoPointsDeps,
  numbers: bigint[],
  useCache = true,
): Promise<Map<bigint, {hash: Hex; timestamp: bigint}>> {
  const out = new Map<bigint, {hash: Hex; timestamp: bigint}>();
  const missing: bigint[] = [];
  for (const num of new Set(numbers)) {
    const cached = useCache ? blockHeaderCache.get(num) : undefined;
    if (cached) out.set(num, cached);
    else missing.push(num);
  }
  for (let i = 0; i < missing.length; i += HEADER_CONCURRENCY) {
    const slice = missing.slice(i, i + HEADER_CONCURRENCY);
    const blocks = await Promise.all(slice.map((blockNumber) => deps.client.getBlock({blockNumber})));
    blocks.forEach((block, j) => {
      if (block.hash === null) throw new MorphoPointsIntegrityError("points: a pending block in history");
      const entry = {hash: block.hash, timestamp: block.timestamp};
      out.set(slice[j], entry);
      if (useCache) {
        if (blockHeaderCache.size >= MAX_BLOCK_HEADER_CACHE) {
          const oldest = blockHeaderCache.keys().next().value;
          if (oldest !== undefined) blockHeaderCache.delete(oldest);
        }
        blockHeaderCache.set(slice[j], entry);
      }
    });
  }
  return out;
}

function headerFor(map: Map<bigint, {hash: Hex; timestamp: bigint}>, log: RawLog): bigint {
  const header = map.get(BigInt(log.blockNumber));
  if (!header || header.hash.toLowerCase() !== log.blockHash.toLowerCase()) {
    throw new MorphoPointsIntegrityError("points: a log's block is not the canonical block the RPC reports");
  }
  return header.timestamp;
}

async function verifyMarket(deps: MorphoPointsDeps, block: bigint): Promise<void> {
  const {client, config, contracts} = deps;
  if ((await client.getChainId()) !== EXPECTED_CHAIN.id) {
    throw new MorphoPointsIntegrityError("points: the archive RPC serves another chain");
  }
  const params = await client.readContract({
    address: MORPHO_BLUE,
    abi: MORPHO_COLLATERAL_ABI,
    functionName: "idToMarketParams",
    args: [config.marketId],
    blockNumber: block,
  });
  const [loanToken, collateralToken, oracle, irm, lltv] = params;
  if (
    loanToken.toLowerCase() !== contracts.usdc.toLowerCase() ||
    collateralToken.toLowerCase() !== contracts.susdfr.toLowerCase() ||
    irm.toLowerCase() !== ADAPTIVE_CURVE_IRM.toLowerCase() ||
    lltv !== MARKET_LLTV
  ) {
    throw new MorphoPointsIntegrityError("points: the configured market is not Forest Road's USDC/sUSDfr market");
  }
  // createMarket is permissionless, so a look-alike market can carry another oracle that answers
  // the four wiring views below. Only the deployed oracle, pinned by address, qualifies.
  if (oracle.toLowerCase() !== config.oracle.toLowerCase()) {
    throw new MorphoPointsIntegrityError("points: the market's oracle is not the pinned MORPHO_SUSDFR_ORACLE");
  }
  const wiring = await Promise.all(
    (["vault", "controller", "loanToken", "ONE_SHARE"] as const).map((functionName) =>
      client.readContract({address: oracle, abi: ORACLE_WIRING_ABI, functionName, blockNumber: block}),
    ),
  );
  const [vault, controller, oracleLoanToken, oneShare] = wiring as [Address, Address, Address, bigint];
  if (
    vault.toLowerCase() !== contracts.susdfr.toLowerCase() ||
    controller.toLowerCase() !== contracts.controller.toLowerCase() ||
    oracleLoanToken.toLowerCase() !== contracts.usdc.toLowerCase() ||
    oneShare !== ONE_SHARE
  ) {
    throw new MorphoPointsIntegrityError("points: the market's oracle is not Forest Road's exit-value oracle");
  }
  const [before, at] = await Promise.all(
    [config.fromBlock - 1n, config.fromBlock].map((blockNumber) =>
      client.readContract({
        address: MORPHO_BLUE,
        abi: MORPHO_COLLATERAL_ABI,
        functionName: "idToMarketParams",
        args: [config.marketId],
        blockNumber,
      }),
    ),
  );
  if (BigInt(before[0]) !== 0n || at[0].toLowerCase() !== contracts.usdc.toLowerCase()) {
    throw new MorphoPointsIntegrityError("points: MORPHO_SUSDFR_MARKET_FROM_BLOCK is not the market's creation block");
  }
}

async function checkLedgerWiring(deps: MorphoPointsDeps, block: bigint): Promise<void> {
  const {client, contracts} = deps;
  const [slot, hook] = await Promise.all([
    client.getStorageAt({address: contracts.points, slot: IMPLEMENTATION_SLOT, blockNumber: block}),
    client.readContract({
      address: contracts.susdfr,
      abi: VAULT_POINTS_ABI,
      functionName: "pointsModule",
      blockNumber: block,
    }),
  ]);
  const implementation = slot ? `0x${slot.slice(-40)}` : "";
  if (!isVerifiedPointsModuleImplementation(implementation)) {
    throw new MorphoPointsIntegrityError("points: the PointsModule implementation changed; re-verify the mirror");
  }
  if ((hook as Address).toLowerCase() !== contracts.points.toLowerCase()) {
    throw new MorphoPointsIntegrityError("points: sUSDfr no longer reports this PointsModule");
  }
}

/**
 * Extends the rate-epoch history to `toBlock`, committing each finalized chunk as it is read, so
 * a cold instance far past the deployment block converges over successive requests instead of
 * rescanning the same capped range forever (MORPHO-10).
 *
 * Committing is not trusting (MORPHO-32). The replay runs only on a history whose epoch count
 * matched `rateEpochCount` at the boundary it was scanned to, and that check runs whenever the
 * verified boundary trails the scanned one, including when this call scans nothing new. Without
 * it, a count read that failed after the last chunk, or a finalized head at or below what an
 * earlier capped request committed, would replay a history nobody counted, and a missing epoch
 * log would over-award every owner.
 */
const EPOCH_WAVE_CONCURRENCY = 4;

async function extendEpochs(deps: MorphoPointsDeps, h: History, toBlock: bigint, deadline: number): Promise<void> {
  let from = h.epochsScannedTo === 0n ? deps.protocolDeploymentBlock : h.epochsScannedTo + 1n;
  for (let chunks = 0; from <= toBlock; ) {
    const pastDeadline = deps.now() > deadline;
    if (chunks >= MAX_CHUNKS_PER_REQUEST || (chunks > 0 && pastDeadline)) {
      throw new MorphoPointsNotReadyError("points: catching up on rate history");
    }
    const remainingChunks = (toBlock - from) / BLOCK_CHUNK + 1n;
    const maxAllowed = MAX_CHUNKS_PER_REQUEST - chunks;
    const remainingMs = Math.max(0, deadline - deps.now());
    const budgetWave = Math.max(1, Math.floor(remainingMs / 1_000));
    const waveSize =
      !pastDeadline && remainingChunks > 4n
        ? Math.min(EPOCH_WAVE_CONCURRENCY, maxAllowed, budgetWave)
        : 1;
    const waveRanges: Array<{from: bigint; to: bigint}> = [];
    for (let i = 0; i < waveSize && from <= toBlock; i += 1) {
      const to = from + BLOCK_CHUNK - 1n < toBlock ? from + BLOCK_CHUNK - 1n : toBlock;
      waveRanges.push({from, to});
      from = to + 1n;
    }
    const waveLogs = await Promise.all(
      waveRanges.map((range) => getLogs(deps, deps.contracts.points, [RATE_EPOCH_TOPIC], range.from, range.to)),
    );
    for (let i = 0; i < waveLogs.length; i += 1) {
      const logs = waveLogs[i];
      const map = await headers(
        deps,
        logs.map((log) => BigInt(log.blockNumber)),
      );
      const added: RateEpoch[] = [];
      for (const log of logs) {
        const decoded = decodeEventLog({
          abi: POINTS_HISTORY_ABI,
          topics: log.topics as [Hex, ...Hex[]],
          data: log.data,
          strict: true,
        });
        if (decoded.args.index !== BigInt(h.epochs.length + added.length)) {
          throw new MorphoPointsIntegrityError("points: rate epochs are not contiguous");
        }
        added.push({start: headerFor(map, log), ratePerUnitDay: decoded.args.ratePerUnitDay});
      }
      for (const epoch of added) h.epochs.push(epoch);
      h.epochsScannedTo = waveRanges[i].to;
      chunks += 1;
    }
  }
  if (h.epochsVerifiedTo < h.epochsScannedTo) {
    const count = await deps.client.readContract({
      address: deps.contracts.points,
      abi: POINTS_ABI,
      functionName: "rateEpochCount",
      blockNumber: h.epochsScannedTo,
    });
    if (count !== BigInt(h.epochs.length)) {
      throw new MorphoPointsIntegrityError("points: rate epoch history does not match rateEpochCount");
    }
    h.epochsVerifiedTo = h.epochsScannedTo;
  }
}

/**
 * Extends the market's collateral history to `toBlock`, one chunk at a time. Before a chunk is
 * committed, the owners it could over-award are checked against Morpho Blue's `position()` at the
 * chunk's last block, so an omitted log changes a balance somewhere and fails closed, even when a
 * later omitted log nets it back to the same end balance. An omitted pair that nets to zero
 * inside one chunk (for example a withdrawal and an equal re-supply less than 9,000 blocks apart)
 * is not caught: that residual is accepted.
 *
 * Returns the block the last committed chunk was reconciled at, or null if it scanned nothing.
 */
async function extendCollateral(
  deps: MorphoPointsDeps,
  h: History,
  toBlock: bigint,
  deadline: number,
): Promise<bigint | null> {
  const {config} = deps;
  const collateralTopics = [
    MORPHO_COLLATERAL_TOPICS.SupplyCollateral,
    MORPHO_COLLATERAL_TOPICS.WithdrawCollateral,
    MORPHO_COLLATERAL_TOPICS.Liquidate,
  ] as Hex[];
  let from = h.scannedTo === 0n ? config.fromBlock : h.scannedTo + 1n;
  let reconciledAt: bigint | null = null;
  for (let chunks = 0; from <= toBlock; ++chunks) {
    if (chunks >= MAX_CHUNKS_PER_REQUEST || (chunks > 0 && deps.now() > deadline)) {
      throw new MorphoPointsNotReadyError("points: catching up on market history");
    }
    // Chunk n ends at the market's first block plus n * BLOCK_CHUNK - 1, whatever block this request
    // resumed from: a history extended from a head mid-chunk finishes that chunk first, so every
    // instance checks the owners held at zero at the same blocks as a cold build (Corrovera
    // M1001-m4-06).
    const chunk = (from - config.fromBlock) / BLOCK_CHUNK + 1n;
    const end = config.fromBlock + chunk * BLOCK_CHUNK - 1n;
    const to = end < toBlock ? end : toBlock;
    const logs = await getLogs(deps, MORPHO_BLUE, [collateralTopics, config.marketId], from, to);
    const map = await headers(
      deps,
      logs.map((log) => BigInt(log.blockNumber)),
    );
    const decoded = logs.map((log) =>
      decodeCollateralLog(
        {
          topics: log.topics,
          data: log.data,
          blockNumber: BigInt(log.blockNumber),
          logIndex: Number(BigInt(log.logIndex)),
        },
        config.marketId,
        headerFor(map, log),
      ),
    );
    decoded.sort((a, b) =>
      a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : a.blockNumber < b.blockNumber ? -1 : 1,
    );
    const last = h.events.at(-1);
    const first = decoded[0];
    if (
      last &&
      first &&
      (first.blockNumber < last.blockNumber || (first.blockNumber === last.blockNumber && first.logIndex <= last.logIndex))
    ) {
      throw new MorphoPointsIntegrityError("points: collateral history overlaps what is already committed");
    }
    const balances = new Map(h.balances);
    const owners = new Set(h.owners);
    const touched = new Set<string>();
    for (const event of decoded) {
      const owner = event.owner.toLowerCase();
      const before = balances.get(owner) ?? 0n;
      const after = event.kind === "supply" ? before + event.assets : before - event.assets;
      if (after < 0n) {
        throw new MorphoPointsIntegrityError("points: collateral removed that the replay never saw supplied");
      }
      balances.set(owner, after);
      owners.add(owner);
      touched.add(owner);
    }
    // Points accrue only on collateral the replay credits, so an omitted log can over-award an
    // owner only by leaving a replayed balance Morpho Blue does not hold, which is non-zero at
    // this boundary or a later one: checking every non-zero balance, plus every owner this chunk
    // touched, keeps the over-award check whole (MORPHO-31). An owner the replay holds at zero
    // can only be under-counted, and its own request still reads its position before any answer;
    // each is also checked once every 16 chunks, a sixteenth of them at each chunk's end, so an
    // omitted round trip spanning one of its check blocks fails closed instead of under-counting
    // (MORPHO-55, M1001-m4-07).
    const every = Number(ZERO_HELD_GRID_CHUNKS);
    const phase = Number(chunk % ZERO_HELD_GRID_CHUNKS);
    const due = [...owners].filter(
      (owner, i) => touched.has(owner) || (balances.get(owner) ?? 0n) !== 0n || i % every === phase,
    );
    await reconcileAt(deps, due, (owner) => balances.get(owner) ?? 0n, to);
    for (const event of decoded) h.events.push(event);
    h.owners = owners;
    h.balances = balances;
    h.scannedTo = to;
    reconciledAt = to;
    from = to + 1n;
  }
  return reconciledAt;
}

/** Checks each owner's collateral in Morpho Blue at `block` against what the history expects. */
async function reconcileAt(
  deps: MorphoPointsDeps,
  owners: readonly string[],
  expected: (owner: string) => bigint,
  block: bigint,
): Promise<void> {
  const batches: string[][] = [];
  for (let i = 0; i < owners.length; i += RECONCILE_BATCH) batches.push(owners.slice(i, i + RECONCILE_BATCH));
  for (let i = 0; i < batches.length; i += RECONCILE_CONCURRENCY) {
    await Promise.all(
      batches.slice(i, i + RECONCILE_CONCURRENCY).map(async (batch) => {
        const positions = (await deps.client.multicall({
          contracts: batch.map((owner) => ({
            address: MORPHO_BLUE,
            abi: MORPHO_COLLATERAL_ABI,
            functionName: "position" as const,
            args: [deps.config.marketId, owner as Address] as const,
          })),
          blockNumber: block,
          allowFailure: false,
          batchSize: RECONCILE_CALLDATA_BYTES,
        })) as (readonly [bigint, bigint, bigint])[];
        positions.forEach((position, j) => {
          if (position[2] !== expected(batch[j])) {
            throw new MorphoPointsIntegrityError("points: replayed collateral disagrees with Morpho Blue");
          }
        });
      }),
    );
  }
}

async function buildSnapshot(
  deps: MorphoPointsDeps,
  asOf: {number: bigint; timestamp: bigint},
  deadline: number,
): Promise<Snapshot> {
  const h = historyFor(deps);
  if (h.snapshot && h.snapshot.asOfBlock >= asOf.number) return h.snapshot;
  let hydratedThisBuild = false;
  try {
    if (
      h.scannedTo === 0n &&
      h.epochsScannedTo === 0n &&
      !h.hydratedFromStore &&
      !skipHistorySnapshotUntilVerified &&
      deps.snapshotStore
    ) {
      h.hydratedFromStore = true;
      const snap = await deps.snapshotStore.load(h.key);
      if (
        snap &&
        history === h &&
        snap.epochsScannedTo <= asOf.number &&
        snap.scannedTo <= asOf.number &&
        (snap.epochsScannedTo === 0n || snap.epochsScannedTo >= deps.protocolDeploymentBlock) &&
        (snap.scannedTo === 0n || snap.scannedTo >= deps.config.fromBlock)
      ) {
        // Verify internal event-to-balance consistency before hydrating from external storage.
        const derivedBalances = new Map<string, bigint>();
        let consistent = true;
        for (const event of snap.events) {
          const owner = event.owner.toLowerCase();
          const current = derivedBalances.get(owner) ?? 0n;
          const next = event.kind === "supply" ? current + event.assets : current - event.assets;
          if (next < 0n) {
            consistent = false;
            break;
          }
          derivedBalances.set(owner, next);
        }
        if (consistent && derivedBalances.size === snap.balances.length) {
          for (const [owner, bal] of snap.balances) {
            if (derivedBalances.get(owner) !== bal) {
              consistent = false;
              break;
            }
          }
        } else {
          consistent = false;
        }
        if (consistent) {
          for (const epoch of snap.epochs) h.epochs.push(epoch);
          h.epochsScannedTo = snap.epochsScannedTo;
          // Leave epochsVerifiedTo = 0n so extendEpochs ALWAYS verifies rateEpochCount on-chain.
          h.epochsVerifiedTo = 0n;
          for (const event of snap.events) h.events.push(event);
          for (const owner of snap.owners) h.owners.add(owner);
          for (const [owner, bal] of derivedBalances) h.balances.set(owner, bal);
          h.scannedTo = snap.scannedTo;
          lastSavedHistoryCursor = historyCursorKey(h);
          hydratedThisBuild = true;
        }
      }
    }
    if (!h.verified) {
      await verifyMarket(deps, asOf.number);
      h.verified = true;
    }
    await checkLedgerWiring(deps, asOf.number);
    await extendEpochs(deps, h, asOf.number, deadline);
    const reconciledAt = await extendCollateral(deps, h, asOf.number, deadline);
    const owners = replayCollateralPoints(h.events, h.epochs, asOf.timestamp);
    // The last chunk was just reconciled at this very block (MORPHO-31); a build that hydrated
    // from Blob or scanned no chunk up to `asOf.number` reconciles every known owner here.
    if (hydratedThisBuild || reconciledAt !== asOf.number) {
      await reconcileAt(deps, [...h.owners], (owner) => owners.get(owner)?.collateral ?? 0n, asOf.number);
    }
    skipHistorySnapshotUntilVerified = false;
    await persistHistorySnapshot(deps, h);
    h.snapshot = {
      asOfBlock: asOf.number,
      asOfTimestamp: asOf.timestamp,
      owners,
      rateEpochs: h.epochs.length,
      history: h,
    };
    return h.snapshot;
  } catch (error) {
    if (error instanceof MorphoPointsNotReadyError && history === h) {
      await persistHistorySnapshot(deps, h);
    } else if (error instanceof MorphoPointsIntegrityError) {
      dropHistory(deps, h);
    }
    throw error;
  }
}

/**
 * One cache extension at a time; concurrent requests for the same or an older block share it. A
 * build queued behind another keeps its own request's deadline, so once that has passed it does the
 * first chunk of each scan and then stops (Corrovera MORPHO-71, M1001-m4-07).
 */
function snapshotAt(
  deps: MorphoPointsDeps,
  asOf: {number: bigint; timestamp: bigint},
  deadline: number,
): Promise<Snapshot> {
  const current = history?.snapshot;
  if (current && current.asOfBlock >= asOf.number) return Promise.resolve(current);
  if (inflight && inflight.target >= asOf.number) return inflight.promise;
  const run = () => buildSnapshot(deps, asOf, deadline);
  const promise = queue.then(run, run);
  queue = promise.catch(() => undefined);
  const entry = {target: asOf.number, promise};
  inflight = entry;
  void promise
    .catch(() => undefined)
    .finally(() => {
      if (inflight === entry) inflight = null;
    });
  return promise;
}

function defaultDeps(): MorphoPointsDeps | null {
  const config = morphoPointsConfig();
  if (!config) return null;
  const {USDC, sUSDfr, MintRedeemController, PointsModule, ComplianceRegistry} = CONTRACTS;
  if (!USDC || !sUSDfr || !MintRedeemController || !PointsModule || !ComplianceRegistry) {
    throw new MorphoPointsIntegrityError("points: protocol addresses are not configured");
  }
  const client = createPublicClient({
    chain: EXPECTED_CHAIN,
    transport: createArchiveRpcTransport(archiveRpcUrl()),
  }) as PublicClient;
  return {
    client,
    config,
    contracts: {
      usdc: USDC,
      susdfr: sUSDfr,
      controller: MintRedeemController,
      points: PointsModule,
      compliance: ComplianceRegistry,
    },
    protocolDeploymentBlock: PROTOCOL_DEPLOYMENT_BLOCK,
    now: () => Date.now(),
    snapshotStore: blobMorphoHistoryStore(),
  };
}

type MorphoPointsAnswer = {
  ok: true;
  enabled: true;
  marketId: Hex;
  asOfBlock: string;
  asOfTimestamp: string;
  wallet: Address;
  collateral: string;
  rateEpochs: number;
};

export type MorphoPointsWire =
  | {ok: true; enabled: false}
  | (MorphoPointsAnswer & {points: string; excluded?: "protocol-exempt" | "jurisdiction-blocked"})
  | (MorphoPointsAnswer & {reconcileRequired: true; trackedShares: string; walletShares: string});

/**
 * One wallet's sUSDfr collateral in the Forest Road Morpho market and the points it has earned,
 * replayed from the market's finalized events and reconciled with Morpho Blue at the same block.
 * `arrivedAt` is when the request arrived (ms): apart from the first of each scan, no chunk of
 * history starts later than `REQUEST_BUDGET_MS` after then, however long it waited for another
 * build (Corrovera MORPHO-71). `REQUEST_BUDGET_MS` states the whole request's bound (M1001-m4-07).
 */
export async function loadMorphoCollateralPoints(
  wallet: Address,
  injected?: MorphoPointsDeps,
  arrivedAt?: number,
  options?: {useWalletCache?: boolean},
): Promise<MorphoPointsWire> {
  const deps = injected ?? defaultDeps();
  if (!deps) return {ok: true, enabled: false};
  const deadline = (arrivedAt ?? deps.now()) + REQUEST_BUDGET_MS;
  const useWalletCache = options?.useWalletCache ?? injected === undefined;
  const cacheKey = `${deps.config.marketId}:${deps.config.fromBlock}:${deps.config.oracle.toLowerCase()}:${wallet.toLowerCase()}`;
  if (useWalletCache) {
    const cached = walletAnswerCache.get(cacheKey);
    if (cached && deps.now() - cached.at < WALLET_CACHE_TTL_MS) return cached.answer;
    const pending = walletAnswerInFlight.get(cacheKey);
    if (pending) return pending;
  }

  let snapshotHistory: History | null = null;
  const compute = async (): Promise<MorphoPointsWire> => {
    const finalized = await deps.client.getBlock({blockTag: "finalized"});
    if (finalized.number === null) throw new MorphoPointsNotReadyError("points: no finalized block");
    if (finalized.number < deps.config.fromBlock) {
      throw new MorphoPointsNotReadyError("points: the market's creation block is not finalized yet");
    }
    const snapshot = await snapshotAt(deps, {number: finalized.number, timestamp: finalized.timestamp}, deadline);
    snapshotHistory = snapshot.history;
    const block = snapshot.asOfBlock;
    const owner = wallet.toLowerCase();
    const [position, exempt, blocked, tracked, walletShares] = await Promise.all([
      deps.client.readContract({
        address: MORPHO_BLUE,
        abi: MORPHO_COLLATERAL_ABI,
        functionName: "position",
        args: [deps.config.marketId, wallet],
        blockNumber: block,
      }),
      deps.client.readContract({
        address: deps.contracts.compliance,
        abi: OWNER_STATUS_ABI,
        functionName: "isProtocolExempt",
        args: [wallet],
        blockNumber: block,
      }),
      deps.client.readContract({
        address: deps.contracts.compliance,
        abi: OWNER_STATUS_ABI,
        functionName: "isJurisdictionBlocked",
        args: [wallet],
        blockNumber: block,
      }),
      deps.client.readContract({
        address: deps.contracts.points,
        abi: POINTS_ABI,
        functionName: "trackedBalances",
        args: [wallet],
        blockNumber: block,
      }),
      deps.client.readContract({
        address: deps.contracts.susdfr,
        abi: ERC20_ABI,
        functionName: "balanceOf",
        args: [wallet],
        blockNumber: block,
      }),
    ]);
    const mine = snapshot.owners.get(owner);
    const collateral = mine?.collateral ?? 0n;
    if (position[2] !== collateral) {
      dropHistory(deps, snapshot.history);
      throw new MorphoPointsIntegrityError("points: replayed collateral disagrees with Morpho Blue");
    }
    const base = {
      ok: true as const,
      enabled: true as const,
      marketId: deps.config.marketId,
      asOfBlock: block.toString(),
      asOfTimestamp: snapshot.asOfTimestamp.toString(),
      wallet,
      collateral: collateral.toString(),
      rateEpochs: snapshot.rateEpochs,
    };
    if (exempt) return {...base, points: "0", excluded: "protocol-exempt"};
    if (blocked) return {...base, points: "0", excluded: "jurisdiction-blocked"};
    if (mine !== undefined && tracked[0] > walletShares) {
      return {...base, reconcileRequired: true, trackedShares: tracked[0].toString(), walletShares: walletShares.toString()};
    }
    return {...base, points: (mine?.points ?? 0n).toString()};
  };

  if (!useWalletCache) return compute();
  const promise = compute()
    .then((answer) => {
      if (snapshotHistory !== null && history === snapshotHistory) {
        if (walletAnswerCache.size >= MAX_WALLET_CACHE) {
          const oldest = walletAnswerCache.keys().next().value;
          if (oldest !== undefined) walletAnswerCache.delete(oldest);
        }
        walletAnswerCache.set(cacheKey, {answer, at: deps.now()});
      }
      return answer;
    })
    .finally(() => {
      if (walletAnswerInFlight.get(cacheKey) === promise) walletAnswerInFlight.delete(cacheKey);
    });
  walletAnswerInFlight.set(cacheKey, promise);
  return promise;
}

/** Every credited owner's Morpho collateral points at one snapshot, for the points leaderboard. */
export type MorphoLeaderboard =
  | {enabled: false}
  | {
      enabled: true;
      asOfBlock: bigint;
      asOfTimestamp: bigint;
      /** Lowercase owners credited with more than zero points, as the per-wallet answer credits them. */
      points: Map<string, bigint>;
      /** Owners whose points the per-wallet answer withholds until PointsModule.reconcile(owner). */
      withheld: number;
    };

/** Reads one leaderboard owner needs, in this order, for the checks of `loadMorphoCollateralPoints`. */
const OWNER_READS = 5;

/**
 * Every owner's points in the Forest Road Morpho market at one finalized snapshot, for the points
 * leaderboard: the per-wallet answer's own checks, batched. Every owner the history has seen, even one
 * the replay holds at zero, must have exactly its replayed collateral in Morpho Blue at the snapshot's
 * block, or the history is dropped and nothing is served; a protocol-exempt or jurisdiction-blocked
 * owner earns nothing; and an owner whose ledger still tracks more sUSDfr shares than the wallet holds
 * is withheld, exactly as `loadMorphoCollateralPoints` withholds it. The same request budget applies.
 */
export async function loadMorphoCollateralLeaderboard(
  injected?: MorphoPointsDeps,
  arrivedAt?: number,
): Promise<MorphoLeaderboard> {
  const deps = injected ?? defaultDeps();
  if (!deps) return {enabled: false};
  const deadline = (arrivedAt ?? deps.now()) + REQUEST_BUDGET_MS;
  const finalized = await deps.client.getBlock({blockTag: "finalized"});
  if (finalized.number === null) throw new MorphoPointsNotReadyError("points: no finalized block");
  if (finalized.number < deps.config.fromBlock) {
    throw new MorphoPointsNotReadyError("points: the market's creation block is not finalized yet");
  }
  const snapshot = await snapshotAt(deps, {number: finalized.number, timestamp: finalized.timestamp}, deadline);
  const block = snapshot.asOfBlock;
  // Owners held at zero are checked too: a supply the provider left out would otherwise go uncounted
  // here while the per-wallet answer, reading that owner's position, fails closed.
  const owners = [...snapshot.owners.values()];
  const points = new Map<string, bigint>();
  let withheld = 0;
  const batches: OwnerPoints[][] = [];
  for (let i = 0; i < owners.length; i += RECONCILE_BATCH) {
    batches.push(owners.slice(i, i + RECONCILE_BATCH));
  }
  for (let i = 0; i < batches.length; i += RECONCILE_CONCURRENCY) {
    const wave = batches.slice(i, i + RECONCILE_CONCURRENCY);
    const waveResults = await Promise.all(
      wave.map(async (batch) => {
        const calls = batch.flatMap((entry) => {
          const owner = entry.owner as Address;
          return [
            {address: MORPHO_BLUE, abi: MORPHO_COLLATERAL_ABI, functionName: "position", args: [deps.config.marketId, owner]},
            {address: deps.contracts.compliance, abi: OWNER_STATUS_ABI, functionName: "isProtocolExempt", args: [owner]},
            {address: deps.contracts.compliance, abi: OWNER_STATUS_ABI, functionName: "isJurisdictionBlocked", args: [owner]},
            {address: deps.contracts.points, abi: POINTS_ABI, functionName: "trackedBalances", args: [owner]},
            {address: deps.contracts.susdfr, abi: ERC20_ABI, functionName: "balanceOf", args: [owner]},
          ];
        });
        const reads = (await deps.client.multicall({
          contracts: calls as never,
          blockNumber: block,
          allowFailure: false,
          batchSize: RECONCILE_CALLDATA_BYTES,
        })) as unknown[];
        if (reads.length !== batch.length * OWNER_READS) {
          throw new MorphoPointsIntegrityError("points: a leaderboard read returned the wrong number of answers");
        }
        return {batch, reads};
      }),
    );
    for (const {batch, reads} of waveResults) {
      batch.forEach((entry, j) => {
        const [position, exempt, blocked, tracked, walletShares] = reads.slice(j * OWNER_READS, (j + 1) * OWNER_READS) as [
          readonly [bigint, bigint, bigint],
          boolean,
          boolean,
          readonly [bigint, bigint],
          bigint,
        ];
        if (position[2] !== entry.collateral) {
          dropHistory(deps, snapshot.history);
          throw new MorphoPointsIntegrityError("points: replayed collateral disagrees with Morpho Blue");
        }
        if (exempt || blocked) return;
        if (tracked[0] > walletShares) {
          withheld += 1;
          return;
        }
        if (entry.points > 0n) points.set(entry.owner.toLowerCase(), entry.points);
      });
    }
  }
  return {enabled: true, asOfBlock: block, asOfTimestamp: snapshot.asOfTimestamp, points, withheld};
}
