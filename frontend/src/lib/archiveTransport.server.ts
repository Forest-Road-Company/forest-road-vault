import {http, type HttpTransport} from "viem";

const ARCHIVE_TIMEOUT_MS = 15_000;
const MAX_RATE_LIMIT_RETRIES = 3;
const BASE_BACKOFF_MS = 700;
const MAX_BACKOFF_MS = 3_500;
const MAX_RETRY_AFTER_MS = 4_000;
/** Cap total backoff sleep per request well below ARCHIVE_TIMEOUT_MS so retries never trigger layered viem timeouts. */
const MAX_CUMULATIVE_BACKOFF_MS = 9_500;

/** JSON-RPC error codes providers use for oversized `eth_getLogs` answers. */
const TOO_LARGE_CODES = new Set([-32005, -32008, -32602]);

/** Messages that signal upstream rate limiting or throughput exhaustion, never an oversized log window. */
const RATE_LIMIT_RE =
  /rate\s*limit|too many requests|compute units|cu\/s|throughput|quota|capacity|throttl/i;

/** Messages that signal an `eth_getLogs` range or response-size limit (safe to split). */
const LOG_SIZE_RE =
  /too big|too large|too many results|more than \d+|query returned more than|log response size|block range|response size|exceeds max results|max results/i;

/** Viem's generic `LimitExceededRpcError.shortMessage` for every `-32005` error (rate limit or size). */
const VIEM_GENERIC_LIMIT_SHORT_MESSAGE = "request exceeds defined limit.";

function parseRetryAfterMs(header: string | null): number | null {
  if (!header) return null;
  const trimmed = header.trim();
  const seconds = Number(trimmed);
  if (Number.isFinite(seconds) && seconds > 0) {
    return Math.min(MAX_RETRY_AFTER_MS, Math.max(1_000, Math.ceil(seconds * 1_000)));
  }
  const dateMs = Date.parse(trimmed);
  if (Number.isFinite(dateMs)) {
    const delta = dateMs - Date.now();
    if (delta > 0) return Math.min(MAX_RETRY_AFTER_MS, Math.max(1_000, delta));
  }
  return null;
}

function sleepWithSignal(ms: number, signal?: AbortSignal | null): Promise<void> {
  if (signal?.aborted) return Promise.reject(signal.reason ?? new Error("Aborted"));
  return new Promise((resolve, reject) => {
    const onAbort = () => {
      clearTimeout(timer);
      reject(signal?.reason ?? new Error("Aborted"));
    };
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    signal?.addEventListener("abort", onAbort, {once: true});
  });
}

/**
 * Returns true if any error in the cause chain is an HTTP 429 or upstream rate/throughput limit.
 * Must be checked BEFORE log-range splitting so rate limits never trigger recursive halving.
 */
export function isRateLimitError(error: unknown): boolean {
  for (
    let e: unknown = error, depth = 0;
    e !== null && e !== undefined && typeof e === "object" && depth < 5;
    e = (e as {cause?: unknown}).cause, depth += 1
  ) {
    const node = e as {
      status?: unknown;
      code?: unknown;
      shortMessage?: unknown;
      details?: unknown;
      message?: unknown;
    };
    if (node.status === 429 || node.code === 429) return true;
    const text = [node.details, node.shortMessage, node.message]
      .filter((part): part is string => typeof part === "string")
      .join(" ");
    if (RATE_LIMIT_RE.test(text)) return true;
  }
  return false;
}

/**
 * Whether an `eth_getLogs` failure is a provider's "this log answer is too large" refusal
 * (e.g. -32008 "Response is too big", -32005 "query returned more than 10000 results",
 * -32602 "Log response size exceeded").
 *
 * Explicitly excludes HTTP 429 / throughput rate-limit errors (including viem's generic
 * `-32005` `LimitExceededRpcError` boilerplate `"Request exceeds defined limit."`) so rate
 * limits are retried with backoff rather than amplified by recursive range halving.
 */
export function isLogSizeLimitError(error: unknown): boolean {
  if (isRateLimitError(error)) return false;
  for (
    let e: unknown = error, depth = 0;
    e !== null && e !== undefined && typeof e === "object" && depth < 5;
    e = (e as {cause?: unknown}).cause, depth += 1
  ) {
    const {code, shortMessage, details} = e as {
      code?: unknown;
      shortMessage?: unknown;
      details?: unknown;
    };
    if (typeof code !== "number" || !TOO_LARGE_CODES.has(code)) continue;
    const shortStr = typeof shortMessage === "string" ? shortMessage.trim() : "";
    const effectiveShort =
      shortStr.toLowerCase() === VIEM_GENERIC_LIMIT_SHORT_MESSAGE ? "" : shortStr;
    const detailsStr = typeof details === "string" ? details : "";
    const text = `${effectiveShort} ${detailsStr}`.trim();
    if (text && LOG_SIZE_RE.test(text)) return true;
  }
  return false;
}

/**
 * Server-side archive RPC fetch wrapper with jittered >1s CUPS-bucket backoff on HTTP 429/503,
 * honoring `Retry-After` and caller abort signals.
 */
export function createArchiveFetch(
  baseFetch: typeof fetch = fetch,
  options?: {
    maxRetries?: number;
    sleep?: (ms: number, signal?: AbortSignal | null) => Promise<void>;
    random?: () => number;
  },
): typeof fetch {
  const maxRetries = options?.maxRetries ?? MAX_RATE_LIMIT_RETRIES;
  const sleep = options?.sleep ?? sleepWithSignal;
  const random = options?.random ?? Math.random;

  return async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const safeInit: RequestInit = {...init, redirect: "error", cache: "no-store"};
    let sleptMs = 0;
    for (let attempt = 0; ; attempt += 1) {
      const response = await baseFetch(input, safeInit);
      if ((response.status !== 429 && response.status !== 503) || attempt >= maxRetries) {
        return response;
      }
      const retryAfterMs = parseRetryAfterMs(response.headers.get("retry-after"));
      const jitter = Math.floor(random() * 350);
      const delayMs =
        retryAfterMs ?? Math.min(MAX_BACKOFF_MS, BASE_BACKOFF_MS * (1 << attempt)) + jitter;
      if (sleptMs + delayMs > MAX_CUMULATIVE_BACKOFF_MS) {
        return response;
      }
      await response.body?.cancel().catch(() => undefined);
      sleptMs += delayMs;
      await sleep(delayMs, safeInit.signal);
    }
  };
}

/**
 * Hardened viem HTTP transport for server-side archive indexers:
 * - `batch: false` avoids viem's batch-429 lone-error-object crash that bypasses `Retry-After`
 *   and prevents multi-call `eth_getLogs` burst coalescing. (Contract `multicall()` still packs
 *   contract reads into a single `Multicall3` `eth_call`.)
 * - `fetchFn` forces `redirect: "error"` and `cache: "no-store"`, and retries HTTP 429/503 across
 *   >1s upstream CUPS buckets with jitter + `Retry-After` inside a bounded cumulative sleep cap.
 * - `retryCount: 1` avoids layered retry amplification on top of `createArchiveFetch`.
 */
export function createArchiveRpcTransport(url: string): HttpTransport {
  return http(url, {
    timeout: ARCHIVE_TIMEOUT_MS,
    retryCount: 1,
    retryDelay: 750,
    batch: false,
    fetchFn: createArchiveFetch(),
  });
}
