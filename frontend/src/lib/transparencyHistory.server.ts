import {BlobPreconditionFailedError, del as delBlob, get as getBlob, put as putBlob} from "@vercel/blob";
import {createPublicClient} from "viem";
import {
  BRIDGE_HISTORY_ABI,
  DEFAULT_HISTORY_ABI,
  VAULT_HISTORY_ABI,
  WATERFALL_HISTORY_ABI,
} from "@/lib/abi";
import {createArchiveRpcTransport, isLogSizeLimitError} from "@/lib/archiveTransport.server";
import {
  CONTRACTS,
  IS_LOCAL_FORK,
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
const STALE_IF_ERROR_MS = 600_000;
const ARCHIVE_HISTORY_CONCURRENCY = 3;
const MAX_SPLITS_PER_CHUNK = 64;
const LOG_RESULT_LIMIT = 1_000;
const SNAPSHOT_BLOB_PATH = `transparency-history/chain-${EXPECTED_CHAIN.id}-finalized-v1.json`;
const SNAPSHOT_IO_TIMEOUT_MS = 4_000;
const SNAPSHOT_MAX_BYTES = 4 * 1024 * 1024;
const SNAPSHOT_MAX_EVENTS = 100_000;
const UINT_STRING = /^(0|[1-9][0-9]*)$/;

function isLoopbackOrPrivateHost(hostname: string): boolean {
  const host = hostname.toLowerCase().replace(/^\[|\]$/g, "").replace(/\.+$/, "");
  if (
    host === "localhost" ||
    host === "::1" ||
    host === "::" ||
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
  if (
    host.includes(":") &&
    (host.startsWith("::ffff:") || /^f[cd][0-9a-f]{2}:/.test(host) || /^fe[89ab][0-9a-f]:/.test(host))
  ) {
    return true;
  }
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

export interface TransparencyHistorySnapshotStore {
  load: (expectedKey: string) => Promise<FinalizedCursor | null>;
  save: (key: string, cursor: FinalizedCursor) => Promise<void>;
  clear?: () => Promise<void>;
}

export interface TransparencyHistoryDeps {
  now: () => number;
  getChainId: () => Promise<number>;
  getLatestAndFinalizedBlocks: () => Promise<{latest: bigint; finalized: bigint}>;
  readRange: (fromBlock: bigint, toBlock: bigint) => Promise<TransparencyEventsBatch>;
  snapshotKey?: string;
  snapshotStore?: TransparencyHistorySnapshotStore;
}

interface FinalizedCursor {
  finalizedBlock: bigint;
  events: TransparencyEventsBatch;
}

async function readBoundedStreamText(stream: ReadableStream<Uint8Array>, maxBytes: number): Promise<string | null> {
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

function parseRequiredBigInt(value: unknown): bigint | null {
  if (typeof value !== "string" || !UINT_STRING.test(value)) return null;
  return BigInt(value);
}

function parseOptionalBigInt(value: unknown): bigint | undefined | null {
  if (value === undefined) return undefined;
  if (typeof value !== "string" || !UINT_STRING.test(value)) return null;
  return BigInt(value);
}

function serializeBatch(events: TransparencyEventsBatch) {
  return {
    originated: events.originated.map((e) => ({
      ...(e.tokenId !== undefined ? {tokenId: e.tokenId.toString()} : {}),
      ...(e.classId !== undefined ? {classId: e.classId.toString()} : {}),
    })),
    funded: events.funded.map((e) => ({
      ...(e.tokenId !== undefined ? {tokenId: e.tokenId.toString()} : {}),
      ...(e.principal !== undefined ? {principal: e.principal.toString()} : {}),
    })),
    losses: events.losses.map((e) => ({
      ...(e.classId !== undefined ? {classId: e.classId.toString()} : {}),
      ...(e.loss !== undefined ? {loss: e.loss.toString()} : {}),
    })),
    originationFees: events.originationFees.map((e) => ({
      ...(e.fee !== undefined ? {fee: e.fee.toString()} : {}),
    })),
    distributions: events.distributions.map((e) => ({
      ...(e.fee !== undefined ? {fee: e.fee.toString()} : {}),
      ...(e.toVault !== undefined ? {toVault: e.toVault.toString()} : {}),
    })),
    performanceFees: events.performanceFees.map((e) => ({
      ...(e.feeAssets !== undefined ? {feeAssets: e.feeAssets.toString()} : {}),
    })),
    managementFees: events.managementFees.map((e) => ({
      ...(e.feeAssets !== undefined ? {feeAssets: e.feeAssets.toString()} : {}),
    })),
  };
}

function parseBatch(raw: unknown): TransparencyEventsBatch | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const obj = raw as Record<string, unknown>;
  const list = (key: string): Record<string, unknown>[] | null => {
    const arr = obj[key];
    if (!Array.isArray(arr) || arr.length > SNAPSHOT_MAX_EVENTS) return null;
    for (const item of arr) {
      if (!item || typeof item !== "object" || Array.isArray(item)) return null;
    }
    return arr as Record<string, unknown>[];
  };
  const originatedRaw = list("originated");
  const fundedRaw = list("funded");
  const lossesRaw = list("losses");
  const originationFeesRaw = list("originationFees");
  const distributionsRaw = list("distributions");
  const performanceFeesRaw = list("performanceFees");
  const managementFeesRaw = list("managementFees");
  if (
    !originatedRaw ||
    !fundedRaw ||
    !lossesRaw ||
    !originationFeesRaw ||
    !distributionsRaw ||
    !performanceFeesRaw ||
    !managementFeesRaw
  ) {
    return null;
  }
  const originated: TransparencyEventsBatch["originated"] = [];
  for (const item of originatedRaw) {
    const tokenId = parseRequiredBigInt(item.tokenId);
    const classId = parseRequiredBigInt(item.classId);
    if (tokenId === null || classId === null) return null;
    originated.push({tokenId, classId});
  }
  const funded: TransparencyEventsBatch["funded"] = [];
  for (const item of fundedRaw) {
    const tokenId = parseRequiredBigInt(item.tokenId);
    const principal = parseRequiredBigInt(item.principal);
    if (tokenId === null || principal === null) return null;
    funded.push({tokenId, principal});
  }
  const losses: TransparencyEventsBatch["losses"] = [];
  for (const item of lossesRaw) {
    const classId = parseRequiredBigInt(item.classId);
    const loss = parseRequiredBigInt(item.loss);
    if (classId === null || loss === null) return null;
    losses.push({classId, loss});
  }
  const originationFees: TransparencyEventsBatch["originationFees"] = [];
  for (const item of originationFeesRaw) {
    const fee = parseRequiredBigInt(item.fee);
    if (fee === null) return null;
    originationFees.push({fee});
  }
  const distributions: TransparencyEventsBatch["distributions"] = [];
  for (const item of distributionsRaw) {
    const fee = parseRequiredBigInt(item.fee);
    const toVault = parseOptionalBigInt(item.toVault);
    if (fee === null || toVault === null) return null;
    distributions.push({fee, toVault});
  }
  const performanceFees: TransparencyEventsBatch["performanceFees"] = [];
  for (const item of performanceFeesRaw) {
    const feeAssets = parseRequiredBigInt(item.feeAssets);
    if (feeAssets === null) return null;
    performanceFees.push({feeAssets});
  }
  const managementFees: TransparencyEventsBatch["managementFees"] = [];
  for (const item of managementFeesRaw) {
    const feeAssets = parseRequiredBigInt(item.feeAssets);
    if (feeAssets === null) return null;
    managementFees.push({feeAssets});
  }
  return {originated, funded, losses, originationFees, distributions, performanceFees, managementFees};
}

function isBlobConflict(error: unknown): boolean {
  if (error instanceof BlobPreconditionFailedError) return true;
  return error instanceof Error && /already exists|precondition/i.test(error.message);
}

function blobSnapshotStore(): TransparencyHistorySnapshotStore | undefined {
  if (!process.env.BLOB_READ_WRITE_TOKEN || IS_LOCAL_FORK) return undefined;
  return {
    async load(expectedKey: string): Promise<FinalizedCursor | null> {
      try {
        const result = await getBlob(SNAPSHOT_BLOB_PATH, {
          access: "private",
          useCache: false,
          abortSignal: AbortSignal.timeout(SNAPSHOT_IO_TIMEOUT_MS),
        });
        if (!result) {
          observedBlobEtag = null;
          return null;
        }
        if (result.statusCode !== 200 || !result.stream) return null;
        observedBlobEtag = result.blob.etag;
        const text = await readBoundedStreamText(result.stream, SNAPSHOT_MAX_BYTES);
        if (text === null) return null;
        const parsed = JSON.parse(text) as Record<string, unknown>;
        if (
          parsed.version !== 1 ||
          parsed.key !== expectedKey ||
          typeof parsed.finalizedBlock !== "string" ||
          !/^[1-9][0-9]*$/.test(parsed.finalizedBlock)
        ) {
          return null;
        }
        const events = parseBatch(parsed.events);
        if (!events) return null;
        return {finalizedBlock: BigInt(parsed.finalizedBlock), events};
      } catch (error) {
        const name = error instanceof Error ? error.name : "UnknownError";
        console.error(`transparency.snapshot load failed: ${name}`);
        return null;
      }
    },
    async save(key: string, cursor: FinalizedCursor): Promise<void> {
      const payload = JSON.stringify({
        version: 1,
        key,
        finalizedBlock: cursor.finalizedBlock.toString(),
        events: serializeBatch(cursor.events),
      });
      if (Buffer.byteLength(payload, "utf8") > SNAPSHOT_MAX_BYTES) {
        console.error("transparency.snapshot save skipped: payload exceeds size cap");
        return;
      }
      try {
        const saved = await putBlob(
          SNAPSHOT_BLOB_PATH,
          payload,
          observedBlobEtag !== null
            ? {
                access: "private",
                contentType: "application/json",
                addRandomSuffix: false,
                allowOverwrite: true,
                ifMatch: observedBlobEtag,
                abortSignal: AbortSignal.timeout(SNAPSHOT_IO_TIMEOUT_MS),
              }
            : {
                access: "private",
                contentType: "application/json",
                addRandomSuffix: false,
                allowOverwrite: false,
                abortSignal: AbortSignal.timeout(SNAPSHOT_IO_TIMEOUT_MS),
              },
        );
        observedBlobEtag = saved.etag;
      } catch (error) {
        if (isBlobConflict(error)) return;
        throw error;
      }
    },
    async clear(): Promise<void> {
      try {
        const etag = observedBlobEtag;
        observedBlobEtag = null;
        await delBlob(
          SNAPSHOT_BLOB_PATH,
          etag
            ? {ifMatch: etag, abortSignal: AbortSignal.timeout(SNAPSHOT_IO_TIMEOUT_MS)}
            : {abortSignal: AbortSignal.timeout(SNAPSHOT_IO_TIMEOUT_MS)},
        );
      } catch (error) {
        if (isBlobConflict(error)) return;
        const name = error instanceof Error ? error.name : "UnknownError";
        console.error(`transparency.snapshot clear failed: ${name}`);
      }
    },
  };
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

async function readRangeAdaptive<T>(
  fromBlock: bigint,
  toBlock: bigint,
  fetchEvents: (from: bigint, to: bigint) => Promise<readonly T[]>,
  budget: {remaining: number} = {remaining: MAX_SPLITS_PER_CHUNK},
): Promise<T[]> {
  const split = async (): Promise<T[]> => {
    if (fromBlock >= toBlock || budget.remaining <= 0) {
      throw new Error("transparency history: log range hit result cap or split limit");
    }
    budget.remaining -= 1;
    const mid = fromBlock + (toBlock - fromBlock) / 2n;
    const left = await readRangeAdaptive(fromBlock, mid, fetchEvents, budget);
    const right = await readRangeAdaptive(mid + 1n, toBlock, fetchEvents, budget);
    return [...left, ...right];
  };
  let events: T[];
  try {
    events = [...(await fetchEvents(fromBlock, toBlock))];
  } catch (error) {
    if (!isLogSizeLimitError(error) || fromBlock >= toBlock || budget.remaining <= 0) {
      throw error;
    }
    return split();
  }
  if (events.length >= LOG_RESULT_LIMIT) {
    if (fromBlock < toBlock) return split();
    throw new Error("transparency history: single block reached log result limit");
  }
  return events;
}

const COMBINED_HISTORY_ABI = [
  ...BRIDGE_HISTORY_ABI,
  ...DEFAULT_HISTORY_ABI,
  ...WATERFALL_HISTORY_ABI,
  ...VAULT_FEE_EVENTS_ABI,
] as const;

function defaultDeps(): TransparencyHistoryDeps {
  const client = createPublicClient({
    chain: EXPECTED_CHAIN,
    transport: createArchiveRpcTransport(archiveRpcUrl()),
  });

  const snapshotKey = [
    EXPECTED_CHAIN.id.toString(),
    CONTRACTS.ClaimBridge!,
    CONTRACTS.DefaultManager!,
    CONTRACTS.WaterfallEngine!,
    CONTRACTS.sUSDfr!,
    PROTOCOL_DEPLOYMENT_BLOCK.toString(),
  ]
    .join(":")
    .toLowerCase();

  return {
    now: () => Date.now(),
    snapshotKey,
    snapshotStore: blobSnapshotStore(),
    getChainId: () => client.getChainId(),
    getLatestAndFinalizedBlocks: async () => {
      const [latest, finalizedBlock] = await Promise.all([
        client.getBlockNumber(),
        client.getBlock({blockTag: "finalized"}).catch(() => null),
      ]);
      // Fall back to a conservative 64-block finality margin if the RPC omits the finalized tag (e.g. local anvil).
      const fallbackFinalized = latest > 64n ? latest - 64n : 0n;
      const finalized = finalizedBlock?.number != null && finalizedBlock.number <= latest
        ? finalizedBlock.number
        : fallbackFinalized;
      return {latest, finalized};
    },
    readRange: async (fromBlock, toBlock) => {
      const bridgeAddress = CONTRACTS.ClaimBridge!.toLowerCase();
      const defaultAddress = CONTRACTS.DefaultManager!.toLowerCase();
      const waterfallAddress = CONTRACTS.WaterfallEngine!.toLowerCase();
      const vaultAddress = CONTRACTS.sUSDfr!.toLowerCase();
      const addresses = [
        CONTRACTS.ClaimBridge!,
        CONTRACTS.DefaultManager!,
        CONTRACTS.WaterfallEngine!,
        CONTRACTS.sUSDfr!,
      ];

      // Read all 4 protocol contracts in one multi-address eth_getLogs call per chunk (4x fewer
      // RPC calls and 8x lower burst concurrency than 4 parallel streams x 6 workers).
      const logs = await readBlockRangeChunked(
        fromBlock,
        toBlock,
        (chunkFrom, chunkTo) =>
          readRangeAdaptive(chunkFrom, chunkTo, async (from, to) => {
            const batch = await client.getContractEvents({
              address: addresses,
              abi: COMBINED_HISTORY_ABI,
              fromBlock: from,
              toBlock: to,
            });
            const cleaned = [];
            for (const log of batch) {
              if (log.removed) continue;
              if (log.blockNumber === null || log.blockNumber < from || log.blockNumber > to) {
                throw new Error("transparency history: RPC returned a log outside the requested range");
              }
              cleaned.push(log);
            }
            return cleaned;
          }),
        DEFAULT_BLOCK_CHUNK,
        ARCHIVE_HISTORY_CONCURRENCY,
      );

      const originated: TransparencyEventsBatch["originated"] = [];
      const losses: TransparencyEventsBatch["losses"] = [];
      const funded: TransparencyEventsBatch["funded"] = [];
      const originationFees: TransparencyEventsBatch["originationFees"] = [];
      const distributions: TransparencyEventsBatch["distributions"] = [];
      const performanceFees: TransparencyEventsBatch["performanceFees"] = [];
      const managementFees: TransparencyEventsBatch["managementFees"] = [];

      for (const log of logs) {
        const addr = log.address.toLowerCase();
        if (log.eventName === "Originated" && addr === bridgeAddress) {
          originated.push(log.args);
        } else if (log.eventName === "LossRealized" && addr === defaultAddress) {
          losses.push(log.args);
        } else if (log.eventName === "Funded" && addr === waterfallAddress) {
          funded.push(log.args);
        } else if (log.eventName === "OriginationFeeCharged" && addr === waterfallAddress) {
          originationFees.push(log.args);
        } else if (log.eventName === "Distributed" && addr === waterfallAddress) {
          distributions.push(log.args);
        } else if (log.eventName === "PerformanceFeeAccrued" && addr === vaultAddress) {
          performanceFees.push(log.args);
        } else if (log.eventName === "ManagementFeeAccrued" && addr === vaultAddress) {
          managementFees.push(log.args);
        }
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
let hydratedFromStore = false;
let skipSnapshotUntilVerified = false;
let lastSavedFinalizedBlock = 0n;
let observedBlobEtag: string | null = null;
let cachedAnswer: {value: TransparencyHistoryWire; expiresAt: number; staleUntil: number} | null = null;
let answerInFlight: Promise<TransparencyHistoryWire> | null = null;

/** Test helper: clears module-level caches between isolated test cases. */
export function resetTransparencyHistoryCacheForTests(): void {
  verifiedChain = false;
  finalizedCursor = null;
  hydratedFromStore = false;
  skipSnapshotUntilVerified = false;
  lastSavedFinalizedBlock = 0n;
  observedBlobEtag = null;
  cachedAnswer = null;
  answerInFlight = null;
}

async function persistTransparencySnapshot(deps: TransparencyHistoryDeps, cursor: FinalizedCursor): Promise<void> {
  if (!deps.snapshotStore || !deps.snapshotKey || cursor.finalizedBlock <= lastSavedFinalizedBlock) return;
  try {
    await deps.snapshotStore.save(deps.snapshotKey, cursor);
    if (cursor.finalizedBlock > lastSavedFinalizedBlock) {
      lastSavedFinalizedBlock = cursor.finalizedBlock;
    }
  } catch (error) {
    const name = error instanceof Error ? error.name : "UnknownError";
    console.error(`transparency.snapshot save failed: ${name}`);
  }
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
  if (
    !cursor &&
    !hydratedFromStore &&
    !skipSnapshotUntilVerified &&
    deps.snapshotStore &&
    deps.snapshotKey &&
    finalized >= PROTOCOL_DEPLOYMENT_BLOCK
  ) {
    hydratedFromStore = true;
    const snap = await deps.snapshotStore.load(deps.snapshotKey);
    if (snap && snap.finalizedBlock >= PROTOCOL_DEPLOYMENT_BLOCK) {
      if (snap.finalizedBlock > lastSavedFinalizedBlock) {
        lastSavedFinalizedBlock = snap.finalizedBlock;
      }
      if (snap.finalizedBlock <= finalized) {
        cursor = snap;
      }
    }
  }

  if (finalized >= PROTOCOL_DEPLOYMENT_BLOCK) {
    if (!cursor) {
      const events = await deps.readRange(PROTOCOL_DEPLOYMENT_BLOCK, finalized);
      cursor = {finalizedBlock: finalized, events};
    } else if (finalized > cursor.finalizedBlock) {
      const delta = await deps.readRange(cursor.finalizedBlock + 1n, finalized);
      cursor = {finalizedBlock: finalized, events: mergeBatches(cursor.events, delta)};
    }
  }

  // If a lagging RPC replica reports `asOfBlock < cursor.finalizedBlock`, keep the monotonic
  // finalized block number so cached finalized events are never stamped with an older block.
  const effectiveAsOfBlock =
    cursor && asOfBlock < cursor.finalizedBlock ? cursor.finalizedBlock : asOfBlock;
  const baseEvents = cursor ? cursor.events : emptyBatch();
  const tailFrom = cursor ? cursor.finalizedBlock + 1n : PROTOCOL_DEPLOYMENT_BLOCK;
  const allEvents =
    tailFrom <= effectiveAsOfBlock
      ? mergeBatches(baseEvents, await deps.readRange(tailFrom, effectiveAsOfBlock))
      : baseEvents;

  let wire: TransparencyHistoryWire;
  try {
    wire = serializeTransparencyHistory(
      summarizeTransparencyHistory({
        asOfBlock: effectiveAsOfBlock,
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
  } catch (error) {
    // Never retain or persist a malformed cursor or snapshot that fails summarization.
    finalizedCursor = null;
    hydratedFromStore = false;
    skipSnapshotUntilVerified = true;
    lastSavedFinalizedBlock = 0n;
    await deps.snapshotStore?.clear?.().catch(() => undefined);
    throw error;
  }

  if (cursor) {
    finalizedCursor = cursor;
    skipSnapshotUntilVerified = false;
    await persistTransparencySnapshot(deps, cursor);
  }
  return wire;
}

export type ServedTransparencyHistory =
  | {answer: TransparencyHistoryWire; stale: false}
  | {answer: TransparencyHistoryWire; stale: true; error: unknown};

/**
 * Route-facing loader: caches finalized logs incrementally (plus optional private Blob snapshot),
 * coalesces concurrent cold requests, reuses answers for 60s, and surfaces stale fallback errors
 * explicitly so the HTTP route logs failures and shortens CDN TTL instead of re-stamping fresh TTL.
 */
export async function serveTransparencyHistory(
  depsOverride?: TransparencyHistoryDeps,
): Promise<ServedTransparencyHistory> {
  const now = depsOverride ? depsOverride.now() : Date.now();
  if (cachedAnswer && now < cachedAnswer.expiresAt) return {answer: cachedAnswer.value, stale: false};
  const staleFallback = cachedAnswer && now < cachedAnswer.staleUntil ? cachedAnswer.value : null;

  if (!answerInFlight) {
    const deps = depsOverride ?? defaultDeps();
    const pending = computeTransparencyHistory(deps).then((value) => {
      const finishedAt = deps.now();
      cachedAnswer = {
        value,
        expiresAt: finishedAt + CACHE_TTL_MS,
        staleUntil: finishedAt + STALE_IF_ERROR_MS,
      };
      return value;
    });
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
    return {answer, stale: false};
  } catch (error) {
    if (staleFallback) return {answer: staleFallback, stale: true, error};
    throw error;
  }
}

/** Reads all cumulative history at one archive-RPC block and returns JSON-safe totals. */
export async function loadTransparencyHistory(
  depsOverride?: TransparencyHistoryDeps,
): Promise<TransparencyHistoryWire> {
  const served = await serveTransparencyHistory(depsOverride);
  return served.answer;
}
