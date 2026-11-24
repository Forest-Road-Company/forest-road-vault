import {createPublicClient, http} from "viem";
import {
  BRIDGE_HISTORY_ABI,
  DEFAULT_HISTORY_ABI,
  VAULT_HISTORY_ABI,
  WATERFALL_HISTORY_ABI,
} from "@/lib/abi";
import {
  CONTRACTS,
  IS_MAINNET,
  PROTOCOL_DEPLOYMENT_BLOCK,
  RPC_PROXY_MODE,
  RPC_URL,
} from "@/config/contracts";
import {EXPECTED_CHAIN} from "@/lib/chain";
import {DEFAULT_BLOCK_CHUNK, readBlockRangeChunked} from "@/lib/logs";
import {VERTICALS} from "@/lib/verticals";
import {
  serializeTransparencyHistory,
  summarizeTransparencyHistory,
  type TransparencyHistoryWire,
} from "@/lib/transparencyHistory";

const CACHE_TTL_MS = 60_000;
const ARCHIVE_HISTORY_CONCURRENCY = 6;
const MAX_SPLITS_PER_CHUNK = 12;

function isLoopbackOrPrivateHost(hostname: string): boolean {
  const host = hostname.toLowerCase().replace(/^\[|\]$/g, "");
  if (
    host === "localhost" ||
    host === "::1" ||
    host === "0.0.0.0" ||
    host.endsWith(".localhost") ||
    host.endsWith(".local") ||
    host.endsWith(".internal")
  ) {
    return true;
  }
  const v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (v4) {
    const [a, b] = [Number(v4[1]), Number(v4[2])];
    if (a === 10 || a === 127 || a === 0) return true;
    if (a === 169 && b === 254) return true;
    if (a === 192 && b === 168) return true;
    if (a === 172 && b >= 16 && b <= 31) return true;
    if (a === 100 && b >= 64 && b <= 127) return true;
  }
  if (host.startsWith("fc") || host.startsWith("fd") || host.startsWith("fe80:")) return true;
  return false;
}

/**
 * The archive RPC for server-side history reads; required on mainnet (public HTTPS only),
 * HTTPS or loopback HTTP on testnet/local fork.
 *
 * A testnet build without it falls back to the browser RPC, but never to the proxy path: in proxy
 * mode NEXT_PUBLIC_RPC_URL is `/api/rpc`, which is not a URL a server can read from. That case
 * fails loudly by name rather than as an unparseable URL, and does not borrow the proxy's upstream.
 */
export function archiveRpcUrl(): string {
  const configured = process.env.ETHEREUM_ARCHIVE_RPC_URL?.trim();
  if (!configured && !IS_MAINNET && RPC_PROXY_MODE) {
    throw new Error("ETHEREUM_ARCHIVE_RPC_URL is required when the browser RPC is the same-origin proxy");
  }
  const value = configured || (IS_MAINNET ? "" : RPC_URL);
  if (!value) throw new Error("ETHEREUM_ARCHIVE_RPC_URL is required on mainnet");
  const url = new URL(value);
  if (IS_MAINNET) {
    if (url.protocol !== "https:") throw new Error("archive RPC must use HTTPS on mainnet");
    if (isLoopbackOrPrivateHost(url.hostname)) {
      throw new Error("archive RPC must not target loopback or private hosts on mainnet");
    }
  } else if (url.protocol !== "https:" && !(url.hostname === "127.0.0.1" || url.hostname === "localhost")) {
    throw new Error("archive RPC must use HTTPS or loopback HTTP");
  }
  if (url.username || url.password) throw new Error("archive RPC must not contain URL credentials");
  if (url.hash) throw new Error("archive RPC must not contain a URL fragment");
  return url.toString();
}

export interface TransparencyEventsBatch {
  originated: Array<{tokenId?: bigint; classId?: bigint}>;
  funded: Array<{tokenId?: bigint; principal?: bigint}>;
  losses: Array<{classId?: bigint; loss?: bigint}>;
  originationFees: Array<{fee?: bigint}>;
  distributions: Array<{fee?: bigint; toVault?: bigint}>;
  performanceFees: Array<{feeAssets?: bigint}>;
  managementFees: Array<{feeAssets?: bigint}>;
}

export interface TransparencyHistoryDeps {
  now: () => number;
  getChainId: () => Promise<number>;
  getLatestAndFinalizedBlocks: () => Promise<{latest: bigint; finalized: bigint}>;
  readRange: (fromBlock: bigint, toBlock: bigint) => Promise<TransparencyEventsBatch>;
}

interface FinalizedCursor {
  finalizedBlock: bigint;
  events: TransparencyEventsBatch;
}

const VAULT_FEE_EVENTS_ABI = VAULT_HISTORY_ABI.filter(
  (entry) => entry.name === "PerformanceFeeAccrued" || entry.name === "ManagementFeeAccrued",
);

function emptyBatch(): TransparencyEventsBatch {
  return {
    originated: [],
    funded: [],
    losses: [],
    originationFees: [],
    distributions: [],
    performanceFees: [],
    managementFees: [],
  };
}

function mergeBatches(a: TransparencyEventsBatch, b: TransparencyEventsBatch): TransparencyEventsBatch {
  return {
    originated: [...a.originated, ...b.originated],
    funded: [...a.funded, ...b.funded],
    losses: [...a.losses, ...b.losses],
    originationFees: [...a.originationFees, ...b.originationFees],
    distributions: [...a.distributions, ...b.distributions],
    performanceFees: [...a.performanceFees, ...b.performanceFees],
    managementFees: [...a.managementFees, ...b.managementFees],
  };
}

function isLogLimitError(error: unknown): boolean {
  const message = error instanceof Error ? error.message.toLowerCase() : String(error).toLowerCase();
  const code =
    typeof error === "object" && error !== null && "code" in error
      ? Number((error as {code?: unknown}).code)
      : NaN;
  return (
    code === -32005 ||
    code === -32008 ||
    message.includes("more than") ||
    message.includes("too large") ||
    message.includes("exceed") ||
    message.includes("block range") ||
    message.includes("log response size")
  );
}

async function readRangeAdaptive<T>(
  fromBlock: bigint,
  toBlock: bigint,
  fetchEvents: (from: bigint, to: bigint) => Promise<readonly T[]>,
  splits = 0,
): Promise<T[]> {
  try {
    return [...(await fetchEvents(fromBlock, toBlock))];
  } catch (error) {
    if (!isLogLimitError(error) || fromBlock >= toBlock || splits >= MAX_SPLITS_PER_CHUNK) {
      throw error;
    }
    const mid = fromBlock + (toBlock - fromBlock) / 2n;
    const [left, right] = await Promise.all([
      readRangeAdaptive(fromBlock, mid, fetchEvents, splits + 1),
      readRangeAdaptive(mid + 1n, toBlock, fetchEvents, splits + 1),
    ]);
    return [...left, ...right];
  }
}

function defaultDeps(): TransparencyHistoryDeps {
  const client = createPublicClient({
    chain: EXPECTED_CHAIN,
    transport: http(archiveRpcUrl(), {timeout: 15_000, retryCount: 2, batch: true}),
  });

  return {
    now: () => Date.now(),
    getChainId: () => client.getChainId(),
    getLatestAndFinalizedBlocks: async () => {
      const [latest, finalizedBlock] = await Promise.all([
        client.getBlockNumber(),
        client.getBlock({blockTag: "finalized"}).catch(() => null),
      ]);
      // Fall back to a conservative 64-block finality margin if the RPC omits the finalized tag (e.g. local anvil).
      const fallbackFinalized = latest > 64n ? latest - 64n : 0n;
      const finalized = finalizedBlock?.number !== undefined && finalizedBlock.number <= latest
        ? finalizedBlock.number
        : fallbackFinalized;
      return {latest, finalized};
    },
    readRange: async (fromBlock, toBlock) => {
      const [originated, losses, waterfallLogs, vaultFeeLogs] = await Promise.all([
        readBlockRangeChunked(
          fromBlock,
          toBlock,
          (chunkFrom, chunkTo) =>
            readRangeAdaptive(chunkFrom, chunkTo, async (from, to) => {
              const logs = await client.getContractEvents({
                address: CONTRACTS.ClaimBridge!,
                abi: BRIDGE_HISTORY_ABI,
                eventName: "Originated",
                fromBlock: from,
                toBlock: to,
              });
              return logs.filter((log) => !log.removed).map((log) => log.args);
            }),
          DEFAULT_BLOCK_CHUNK,
          ARCHIVE_HISTORY_CONCURRENCY,
        ),
        readBlockRangeChunked(
          fromBlock,
          toBlock,
          (chunkFrom, chunkTo) =>
            readRangeAdaptive(chunkFrom, chunkTo, async (from, to) => {
              const logs = await client.getContractEvents({
                address: CONTRACTS.DefaultManager!,
                abi: DEFAULT_HISTORY_ABI,
                eventName: "LossRealized",
                fromBlock: from,
                toBlock: to,
              });
              return logs.filter((log) => !log.removed).map((log) => log.args);
            }),
          DEFAULT_BLOCK_CHUNK,
          ARCHIVE_HISTORY_CONCURRENCY,
        ),
        // Merge all three WaterfallEngine event streams into one contract sweep per chunk.
        readBlockRangeChunked(
          fromBlock,
          toBlock,
          (chunkFrom, chunkTo) =>
            readRangeAdaptive(chunkFrom, chunkTo, async (from, to) => {
              const logs = await client.getContractEvents({
                address: CONTRACTS.WaterfallEngine!,
                abi: WATERFALL_HISTORY_ABI,
                fromBlock: from,
                toBlock: to,
              });
              return logs.filter((log) => !log.removed);
            }),
          DEFAULT_BLOCK_CHUNK,
          ARCHIVE_HISTORY_CONCURRENCY,
        ),
        // Merge both sUSDfr fee-accrual event streams into one contract sweep per chunk.
        readBlockRangeChunked(
          fromBlock,
          toBlock,
          (chunkFrom, chunkTo) =>
            readRangeAdaptive(chunkFrom, chunkTo, async (from, to) => {
              const logs = await client.getContractEvents({
                address: CONTRACTS.sUSDfr!,
                abi: VAULT_FEE_EVENTS_ABI,
                fromBlock: from,
                toBlock: to,
              });
              return logs.filter((log) => !log.removed);
            }),
          DEFAULT_BLOCK_CHUNK,
          ARCHIVE_HISTORY_CONCURRENCY,
        ),
      ]);

      const funded: TransparencyEventsBatch["funded"] = [];
      const originationFees: TransparencyEventsBatch["originationFees"] = [];
      const distributions: TransparencyEventsBatch["distributions"] = [];
      for (const log of waterfallLogs) {
        if (log.eventName === "Funded") funded.push(log.args);
        else if (log.eventName === "OriginationFeeCharged") originationFees.push(log.args);
        else if (log.eventName === "Distributed") distributions.push(log.args);
      }

      const performanceFees: TransparencyEventsBatch["performanceFees"] = [];
      const managementFees: TransparencyEventsBatch["managementFees"] = [];
      for (const log of vaultFeeLogs) {
        if (log.eventName === "PerformanceFeeAccrued") performanceFees.push(log.args);
        else if (log.eventName === "ManagementFeeAccrued") managementFees.push(log.args);
      }

      return {
        originated,
        funded,
        losses,
        originationFees,
        distributions,
        performanceFees,
        managementFees,
      };
    },
  };
}

let verifiedChain = false;
let finalizedCursor: FinalizedCursor | null = null;
let cachedAnswer: {value: TransparencyHistoryWire; expiresAt: number} | null = null;
let answerInFlight: Promise<TransparencyHistoryWire> | null = null;

/** Test helper: clears module-level caches between isolated test cases. */
export function resetTransparencyHistoryCacheForTests(): void {
  verifiedChain = false;
  finalizedCursor = null;
  cachedAnswer = null;
  answerInFlight = null;
}

async function computeTransparencyHistory(deps: TransparencyHistoryDeps): Promise<TransparencyHistoryWire> {
  if (!verifiedChain) {
    const chainId = await deps.getChainId();
    if (chainId !== EXPECTED_CHAIN.id) {
      throw new Error(`archive RPC chain mismatch: expected ${EXPECTED_CHAIN.id}, got ${chainId}`);
    }
    verifiedChain = true;
  }

  const {latest: asOfBlock, finalized} = await deps.getLatestAndFinalizedBlocks();
  if (asOfBlock < PROTOCOL_DEPLOYMENT_BLOCK) throw new Error("archive RPC is behind deployment");

  let cursor = finalizedCursor;
  if (finalized >= PROTOCOL_DEPLOYMENT_BLOCK) {
    if (!cursor) {
      const events = await deps.readRange(PROTOCOL_DEPLOYMENT_BLOCK, finalized);
      cursor = {finalizedBlock: finalized, events};
      finalizedCursor = cursor;
    } else if (finalized > cursor.finalizedBlock) {
      const delta = await deps.readRange(cursor.finalizedBlock + 1n, finalized);
      cursor = {finalizedBlock: finalized, events: mergeBatches(cursor.events, delta)};
      finalizedCursor = cursor;
    }
  }

  const baseEvents = cursor ? cursor.events : emptyBatch();
  const tailFrom = cursor ? cursor.finalizedBlock + 1n : PROTOCOL_DEPLOYMENT_BLOCK;
  const allEvents =
    tailFrom <= asOfBlock
      ? mergeBatches(baseEvents, await deps.readRange(tailFrom, asOfBlock))
      : baseEvents;

  return serializeTransparencyHistory(
    summarizeTransparencyHistory({
      asOfBlock,
      classIds: VERTICALS.map((_, index) => index + 1),
      originated: allEvents.originated,
      funded: allEvents.funded,
      losses: allEvents.losses,
      originationFees: allEvents.originationFees,
      distributions: allEvents.distributions,
      performanceFees: allEvents.performanceFees,
      managementFees: allEvents.managementFees,
    }),
  );
}

/**
 * Reads all cumulative history at one archive-RPC block and returns JSON-safe totals.
 * Caches finalized logs incrementally, coalesces concurrent cold requests, and reuses answers for 60s.
 */
export async function loadTransparencyHistory(
  depsOverride?: TransparencyHistoryDeps,
): Promise<TransparencyHistoryWire> {
  const deps = depsOverride ?? defaultDeps();
  const now = deps.now();
  if (cachedAnswer && now < cachedAnswer.expiresAt) return cachedAnswer.value;
  if (answerInFlight) return answerInFlight;

  const work = computeTransparencyHistory(deps)
    .then((value) => {
      cachedAnswer = {value, expiresAt: deps.now() + CACHE_TTL_MS};
      return value;
    })
    .finally(() => {
      if (answerInFlight === work) answerInFlight = null;
    });
  answerInFlight = work;
  return work;
}
