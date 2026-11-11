/**
 * The same-origin JSON-RPC proxy behind `/api/rpc` (owner decision, 6 November 2026).
 *
 * WHY IT EXISTS. Every NEXT_PUBLIC_ value is compiled into the browser bundle, so a provider URL
 * there publishes its key. A domain allowlist at the provider stops a browser on another site, but a
 * script can send any Origin header it likes and spend the account's compute units, and the
 * protocol's keepers draw on the same account. The browser now reads through this route, the
 * provider URL lives only in the server-only RPC_PROXY_UPSTREAM_URL, and the route admits only the
 * request shapes the site itself sends. Volume is limited per IP by a Vercel WAF rule in front of
 * the route, not here.
 *
 * WHAT IT REFUSES, in order:
 *   - a foreign Origin, or `Sec-Fetch-Site: cross-site` (403); a missing Origin is allowed;
 *   - a body that is not JSON (415), or over 256 KiB declared or actual (413);
 *   - anything but one JSON-RPC 2.0 request or a batch of 1 to 20, each with an id and a string
 *     method (400);
 *   - per entry, with a JSON-RPC error in a 200 answer so a batch fails only that entry: a method
 *     off the allowlist (-32601), or an eth_getLogs that names no contract address (-32602).
 *
 * WHAT IT NEVER SAYS. No answer and no log line carries the upstream URL, its key or a raw fetch
 * error: Node's fetch causes, and viem's error messages, embed the URL. Failures use fixed labels.
 * An upstream answer that echoes any part of the upstream URL is replaced by a fixed 502.
 *
 * WHAT PASSES THROUGH. The upstream's own answer to each forwarded entry, result or JSON-RPC error
 * (revert data included), under the client's id, uncached. That includes a 400 whose body answers
 * every entry, which is how Alchemy reports invalid params. Any other non-2xx, a timeout, a network
 * error or a malformed answer is the proxy's fixed failure (429, 502, 504), answered per entry.
 * An answer over 4,000,000 bytes (Vercel refuses a function body over 4.5 MB) loses its largest
 * entries, each to the named -32008 "too big" error, until the rest fits.
 *
 * THE UPSTREAM. Read per request from RPC_PROXY_UPSTREAM_URL and from nothing else: https only, no
 * credentials or fragment, and never a loopback or private address on mainnet or Sepolia. Before the
 * first forward, each instance checks that the upstream's eth_chainId is this build's chain. A
 * mismatch is remembered and refuses everything (503). A failed check is not remembered, in either
 * direction: the next request checks again.
 */

import {CHAIN_ID} from "@/config/contracts";
import {
  RPC_PROXY_CHAIN_PROBE_TIMEOUT_MS,
  RPC_PROXY_MAX_BATCH,
  RPC_PROXY_MAX_BODY_BYTES,
  RPC_PROXY_UPSTREAM_TIMEOUT_MS,
} from "@/lib/rpcProxyShared";

export {RPC_PROXY_CHAIN_PROBE_TIMEOUT_MS, RPC_PROXY_UPSTREAM_TIMEOUT_MS};
export const RPC_PROXY_UPSTREAM_ENV = "RPC_PROXY_UPSTREAM_URL";

/**
 * The largest answer body the route returns. A Vercel Function refuses to return a (non-streamed)
 * body over 4.5 MB and the browser would see an opaque platform 500, which viem retries three times.
 * Answers over this budget lose their largest entries instead, each replaced by the named
 * {@link RPC_PROXY_RESPONSE_TOO_BIG} error, until the rest fits.
 *
 * What can reach it: a recent mainnet block with full transactions (waitForTransactionReceipt reads
 * one per new block while a sent transaction is pending) measured 417 KB median and 827 KB at most
 * over 60 blocks on 6 November 2026; a block stuffed with calldata could in principle pass 4.5 MB.
 * An eth_getLogs that a script aims at a busy contract can (Alchemy returns up to 10,000 logs). The
 * site's own log reads are scoped to its contracts and are kilobytes.
 */
export const RPC_PROXY_MAX_RESPONSE_BYTES = 4_000_000;

/** The most the route reads of one upstream answer; past it every forwarded entry is too big. */
export const RPC_PROXY_MAX_UPSTREAM_BYTES = 16 * 1024 * 1024;

/**
 * The named per-entry error for an answer the proxy will not return because of its size. The code
 * and wording follow the "Response is too big" refusal some providers already give (-32008), which
 * viem does not retry, so a client is not sent the same oversized read three more times.
 */
export const RPC_PROXY_RESPONSE_TOO_BIG = {
  code: -32008,
  message: "Response is too big for the RPC proxy: narrow the request",
} as const;

/**
 * The JSON-RPC methods the site's browser code sends, and nothing else. Derived from the viem and
 * Wagmi actions the client components call, and checked against what those actions actually send by
 * `rpcProxy.census.test.ts`, which fails on a missing entry and on an unused one.
 *
 * Deliberately absent, because no browser path sends them through this transport:
 *   eth_getBlockByHash  no getBlock({blockHash}) anywhere in browser code.
 *   eth_getStorageAt    used only by server-side archive reads (points), never through the proxy.
 *   eth_getBalance, eth_getTransactionCount, eth_gasPrice, eth_maxPriorityFeePerGas,
 *   eth_feeHistory      viem fills nonce and fees only for local accounts; this site signs with
 *                       wallets (json-rpc accounts), whose eth_sendTransaction goes to the wallet,
 *                       and WalletConnect routes it to the wallet session, not to this RPC.
 *   net_version         nothing calls it.
 *   eth_newFilter, eth_getFilterChanges, eth_uninstallFilter
 *                       viem's contract-event watcher tries a filter first, and on refusal falls
 *                       back to eth_blockNumber plus eth_getLogs (pinned by the census test).
 * Everything else, signing, raw transactions, debug_, trace_, admin_ and provider extensions
 * (alchemy_*), subscriptions and filters, is -32601.
 */
export const RPC_PROXY_ALLOWED_METHODS: ReadonlySet<string> = new Set([
  // rpcAlignment's app-side probe; getChainId in morphoSafe.ts and morphoMarketReader.ts.
  "eth_chainId",
  // getBlockNumber, useBlockNumber, the receipt and event watchers' polling, rpcAlignment's tip
  // probe (also the wallet side when WalletConnect routes reads to this RPC).
  "eth_blockNumber",
  // getBlock and useBlock, rpcAlignment's header comparison, and waitForTransactionReceipt's
  // replacement check (the block with its transactions).
  "eth_getBlockByNumber",
  // readContract, multicall (useReadContract(s) through Multicall3), simulateContract, and call
  // (the Uniswap quoter, the Safe execution probe).
  "eth_call",
  // estimateContractGas in useWriteFlow, which sizes each transaction with headroom.
  "eth_estimateGas",
  // getCode: the Morpho surfaces' wallet and oracle checks, the Safe MultiSend probe.
  "eth_getCode",
  // getContractEvents (yield history), getLogs (Morpho treasury history) and the redemption-queue
  // event watcher's fallback. Always with a contract address; see the eth_getLogs rule below.
  "eth_getLogs",
  // getTransactionReceipt and waitForTransactionReceipt.
  "eth_getTransactionReceipt",
  // waitForTransactionReceipt reads the sent transaction to detect a replacement (speed-up/cancel).
  "eth_getTransactionByHash",
]);

const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const MAX_ID_LENGTH = 128;
const MAX_METHOD_LENGTH = 64;

type JsonRpcId = string | number;
type JsonRpcRequest = {jsonrpc: "2.0"; id: JsonRpcId; method: string; params?: unknown[]};
type JsonRpcError = {code: number; message: string; data?: unknown};
type JsonRpcResponse =
  | {jsonrpc: "2.0"; id: JsonRpcId | null; result: unknown}
  | {jsonrpc: "2.0"; id: JsonRpcId | null; error: JsonRpcError};

/** Every refusal and failure the route can give, with its fixed status and text. */
const FAILURES = {
  methodNotAllowed: {status: 405, code: -32600, message: "Only POST is accepted"},
  foreignOrigin: {status: 403, code: -32600, message: "Cross-origin requests are refused"},
  notJson: {status: 415, code: -32600, message: "Content-Type must be application/json"},
  tooLarge: {status: 413, code: -32600, message: "Request body too large"},
  parseError: {status: 400, code: -32700, message: "Parse error"},
  invalidRequest: {status: 400, code: -32600, message: "Invalid JSON-RPC request"},
  batchTooLarge: {status: 400, code: -32600, message: "Batch too large"},
  unconfigured: {status: 503, code: -32603, message: "RPC proxy is not configured"},
  wrongChain: {status: 503, code: -32603, message: "RPC proxy upstream serves another chain"},
  upstreamUnavailable: {status: 502, code: -32603, message: "Upstream RPC unavailable"},
  upstreamTimeout: {status: 504, code: -32603, message: "Upstream RPC timed out"},
  clientGone: {status: 499, code: -32603, message: "Request cancelled by the client"},
  upstreamRateLimited: {status: 429, code: -32005, message: "Upstream RPC rate limited"},
  upstreamInvalid: {status: 502, code: -32603, message: "Upstream RPC returned an invalid response"},
} as const;

type FailureName = keyof typeof FAILURES;

/**
 * The widest eth_getLogs block span the proxy forwards. The site's own reads are 9,000-block history
 * chunks, 1,000-block Morpho treasury chunks, and the redemption-queue watcher's catch-up from its
 * last poll, which a tab that slept for days can stretch; 100,000 blocks (about 14 days) covers all
 * of them. Tags are refused because "earliest" to "latest" has no bound at all.
 */
export const RPC_PROXY_MAX_LOG_BLOCK_SPAN = 100_000n;

const ENTRY_REFUSALS = {
  methodNotFound: {code: -32601, message: "Method not available through this proxy"},
  logsWithoutAddress: {
    code: -32602,
    message: "eth_getLogs through this proxy must name a contract address",
  },
  logsRange: {
    code: -32602,
    message:
      "eth_getLogs through this proxy needs numeric fromBlock and toBlock at most 100,000 blocks apart, or a blockHash",
  },
  callShape: {
    code: -32602,
    message: "eth_call and eth_estimateGas through this proxy take [transaction] or [transaction, block] with a contract address",
  },
} as const;

function respond(body: unknown, status: number, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {"content-type": "application/json", "cache-control": "no-store", ...extra},
  });
}

/**
 * A refusal or failure. Before the body is understood it is one error object with a null id. Once
 * the entries are known it answers each entry under its own id, and a batch with an array: viem's
 * batch scheduler indexes into the answer, so a lone error object for a batch would surface in the
 * browser as a TypeError instead of an HTTP error it can retry. Entries the policy refused keep
 * their own refusal.
 */
function failure(
  name: FailureName,
  known?: {entries: JsonRpcRequest[]; refusals: (JsonRpcError | null)[]; asBatch: boolean},
): Response {
  const {status, code, message} = FAILURES[name];
  const extra: Record<string, string> = name === "methodNotAllowed" ? {allow: "POST"} : {};
  if (!known) return respond({jsonrpc: "2.0", id: null, error: {code, message}}, status, extra);
  const answers = known.entries.map((entry, index) => ({
    jsonrpc: "2.0",
    id: entry.id,
    error: known.refusals[index] ?? {code, message},
  }));
  return respond(known.asBatch ? answers : answers[0], status, extra);
}

/** Logs a fixed label only. Never an error object, a URL, or upstream text. */
function logFailure(label: string): void {
  console.error(`rpc.proxy ${label}`);
}

/** 405 for every method but POST, with no CORS headers. */
export function rpcProxyMethodNotAllowed(): Response {
  return failure("methodNotAllowed");
}

// ── origin ───────────────────────────────────────────────────────────────────

/** The host this request was addressed to. On Vercel the edge sets x-forwarded-host. */
function ownHost(request: Request): string {
  const forwarded = request.headers.get("x-forwarded-host")?.split(",")[0]?.trim();
  const host = forwarded || request.headers.get("host")?.trim() || new URL(request.url).host;
  return host.toLowerCase();
}

/**
 * A browser on another site is refused; a request without an Origin is not, because a script can
 * forge or omit Origin anyway and the per-IP rate limit is what bounds it.
 */
export function rpcProxyOriginAllowed(request: Request): boolean {
  if (request.headers.get("sec-fetch-site")?.trim().toLowerCase() === "cross-site") return false;
  const origin = request.headers.get("origin");
  if (origin === null) return true;
  let originHost: string;
  try {
    const parsed = new URL(origin);
    if (parsed.protocol !== "https:" && parsed.protocol !== "http:") return false;
    originHost = parsed.host.toLowerCase();
  } catch {
    // Includes the opaque origin "null" (sandboxed frames, file: pages).
    return false;
  }
  return originHost === ownHost(request);
}

// ── body ─────────────────────────────────────────────────────────────────────

/**
 * Reads at most `limit` bytes of a request or upstream body; null when it is larger, in which case
 * reading stops there and the rest is cancelled. Throws on invalid UTF-8.
 */
async function readCapped(body: ReadableStream<Uint8Array> | null, limit: number): Promise<string | null> {
  if (!body) return "";
  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const {done, value} = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) {
      await reader.cancel().catch(() => undefined);
      return null;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder("utf-8", {fatal: true}).decode(bytes);
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** One request entry, canonicalized to the four JSON-RPC fields; null when malformed. */
function parseEntry(value: unknown): JsonRpcRequest | null {
  if (!isPlainObject(value)) return null;
  const {jsonrpc, id, method, params} = value;
  if (jsonrpc !== "2.0") return null;
  const validId =
    (typeof id === "string" && id.length <= MAX_ID_LENGTH) ||
    (typeof id === "number" && Number.isFinite(id));
  if (!validId) return null;
  if (typeof method !== "string" || method.length === 0 || method.length > MAX_METHOD_LENGTH) {
    return null;
  }
  if (params !== undefined && !Array.isArray(params)) return null;
  return params === undefined ? {jsonrpc, id, method} : {jsonrpc, id, method, params};
}

/** eth_getLogs must be scoped to one or more contract addresses, never a chain-wide scan. */
function logsFilterNamesAddress(params: unknown[] | undefined): boolean {
  const filter = params?.[0];
  if (!isPlainObject(filter)) return false;
  const {address} = filter;
  if (typeof address === "string") return ADDRESS.test(address);
  return (
    Array.isArray(address) &&
    address.length > 0 &&
    address.every((entry) => typeof entry === "string" && ADDRESS.test(entry))
  );
}

const QUANTITY = /^0x(0|[1-9a-fA-F][0-9a-fA-F]{0,15})$/;
const BLOCK_HASH = /^0x[0-9a-fA-F]{64}$/;
const BLOCK_TAG = /^(latest|earliest|pending|safe|finalized)$/;
const LOG_FILTER_KEYS = new Set(["address", "topics", "fromBlock", "toBlock", "blockHash"]);

/**
 * The block range of an eth_getLogs filter: one block by hash, or both numeric bounds, in order, no
 * more than {@link RPC_PROXY_MAX_LOG_BLOCK_SPAN} apart. Tags and missing bounds (which default to
 * "latest") are refused: the site always sends numbers, and a tag range has no bound to check.
 */
function logsRangeAllowed(filter: Record<string, unknown>): boolean {
  if (Object.keys(filter).some((key) => !LOG_FILTER_KEYS.has(key))) return false;
  const {fromBlock, toBlock, blockHash} = filter;
  if (blockHash !== undefined) {
    return typeof blockHash === "string" && BLOCK_HASH.test(blockHash) && fromBlock === undefined && toBlock === undefined;
  }
  if (typeof fromBlock !== "string" || typeof toBlock !== "string") return false;
  if (!QUANTITY.test(fromBlock) || !QUANTITY.test(toBlock)) return false;
  const from = BigInt(fromBlock);
  const to = BigInt(toBlock);
  return to >= from && to - from + 1n <= RPC_PROXY_MAX_LOG_BLOCK_SPAN;
}

/**
 * eth_call and eth_estimateGas exactly as the site sends them: a transaction object to a contract,
 * and at most a block number or tag. A third parameter (state or block overrides) is refused: it lets
 * a 200-byte request make the upstream build and return megabytes.
 */
function callShapeAllowed(params: unknown[] | undefined): boolean {
  if (!params || params.length < 1 || params.length > 2) return false;
  const [transaction, block] = params;
  if (!isPlainObject(transaction)) return false;
  if (typeof transaction.to !== "string" || !ADDRESS.test(transaction.to)) return false;
  if (params.length === 2) {
    return typeof block === "string" && (BLOCK_TAG.test(block) || QUANTITY.test(block));
  }
  return true;
}

/** Null when the entry may be forwarded, otherwise its JSON-RPC refusal. Exported for the census. */
export function rpcProxyEntryRefusal(entry: {method: string; params?: unknown[]}): JsonRpcError | null {
  if (!RPC_PROXY_ALLOWED_METHODS.has(entry.method)) return {...ENTRY_REFUSALS.methodNotFound};
  if (entry.method === "eth_getLogs") {
    if (!logsFilterNamesAddress(entry.params)) return {...ENTRY_REFUSALS.logsWithoutAddress};
    if (entry.params!.length !== 1 || !logsRangeAllowed(entry.params![0] as Record<string, unknown>)) {
      return {...ENTRY_REFUSALS.logsRange};
    }
  }
  if ((entry.method === "eth_call" || entry.method === "eth_estimateGas") && !callShapeAllowed(entry.params)) {
    return {...ENTRY_REFUSALS.callShape};
  }
  return null;
}

// ── upstream ─────────────────────────────────────────────────────────────────

const PUBLIC_CHAINS = new Set([1, 11155111]);

function isLoopbackOrPrivateHost(hostname: string): boolean {
  const host = hostname.toLowerCase().replace(/^\[|\]$/g, "");
  if (host === "localhost" || host.endsWith(".localhost")) return true;
  if (host.includes(":")) {
    // IPv6 literal, normalized by URL: loopback, unspecified, IPv4-mapped, unique-local, link-local.
    return (
      host === "::1" ||
      host === "::" ||
      host.startsWith("::ffff:") ||
      /^f[cd][0-9a-f]{2}:/.test(host) ||
      /^fe[89ab][0-9a-f]:/.test(host)
    );
  }
  const octets = host.split(".");
  if (octets.length !== 4 || !octets.every((part) => /^\d{1,3}$/.test(part))) return false;
  const [a, b] = octets.map(Number);
  return (
    a === 127 ||
    a === 0 ||
    a === 10 ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) ||
    (a === 100 && b >= 64 && b <= 127)
  );
}

/** The validated upstream URL, or null. Never logs or returns why in terms of its value. */
export function rpcProxyUpstream(
  raw: string | undefined,
  chainId: number,
): {url: string; secrets: string[]} | null {
  const value = raw?.trim();
  if (!value) return null;
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return null;
  }
  if (url.protocol !== "https:") return null;
  if (url.username || url.password || url.hash) return null;
  if (PUBLIC_CHAINS.has(chainId) && isLoopbackOrPrivateHost(url.hostname)) return null;
  return {url: url.toString(), secrets: urlSecrets(url)};
}

/**
 * Fragments of the upstream URL that must never appear in an answer: the whole URL, its host and
 * path, and every long path segment or query value (where providers put keys).
 */
function urlSecrets(url: URL): string[] {
  const secrets = new Set<string>([url.toString(), `${url.host}${url.pathname}`]);
  if (url.pathname.length > 1) secrets.add(url.pathname);
  for (const segment of url.pathname.split("/")) {
    if (segment.length >= 12) secrets.add(segment);
  }
  for (const value of url.searchParams.values()) {
    if (value.length >= 12) secrets.add(value);
  }
  return [...secrets];
}

type UpstreamAnswer =
  | {ok: true; body: unknown; text: string}
  | {ok: false; failure: "upstreamUnavailable" | "upstreamTimeout" | "upstreamRateLimited" | "upstreamInvalid" | "clientGone"}
  | {ok: false; failure: "tooBig"};

/**
 * One POST to the upstream. It is abandoned after `timeoutMs`, and also as soon as `clientSignal`
 * aborts (the browser went away), so a request nobody will read stops costing upstream work. Every
 * failure is reported by a fixed label, never by the error's text.
 */
async function postUpstream(
  upstream: string,
  payload: unknown,
  timeoutMs: number,
  clientSignal?: AbortSignal,
): Promise<UpstreamAnswer> {
  const timeout = AbortSignal.timeout(timeoutMs);
  let response: Response;
  try {
    response = await fetch(upstream, {
      method: "POST",
      headers: {"content-type": "application/json", accept: "application/json"},
      body: JSON.stringify(payload),
      // A redirect could carry the request, and the key in its URL, to another host.
      redirect: "error",
      cache: "no-store",
      signal: clientSignal ? AbortSignal.any([clientSignal, timeout]) : timeout,
    });
  } catch {
    if (clientSignal?.aborted) {
      logFailure("upstream_cancelled_client_gone");
      return {ok: false, failure: "clientGone"};
    }
    if (timeout.aborted) {
      logFailure("upstream_timeout");
      return {ok: false, failure: "upstreamTimeout"};
    }
    logFailure("upstream_network_error");
    return {ok: false, failure: "upstreamUnavailable"};
  }
  if (response.status === 429) {
    await response.body?.cancel().catch(() => undefined);
    logFailure("upstream_http_429");
    return {ok: false, failure: "upstreamRateLimited"};
  }
  // Alchemy answers a request it judges invalid (bad params, -32602) with HTTP 400 and a JSON-RPC
  // error per entry. That is the provider's answer to the caller, so it passes through, as a 200
  // with the per-entry errors, exactly as the browser saw it when it called the provider directly;
  // forward() still requires a well-formed answer for every entry, and anything else is a fixed
  // 502. Every other non-2xx status (401/403 key or capacity problems, 5xx) is the proxy's own
  // failure and never passes through.
  if (!response.ok && response.status !== 400) {
    await response.body?.cancel().catch(() => undefined);
    logFailure(`upstream_http_${response.status}`);
    return {ok: false, failure: "upstreamUnavailable"};
  }
  if (response.status === 400) logFailure("upstream_http_400_passed_through");
  let text: string | null;
  try {
    text = await readCapped(response.body, RPC_PROXY_MAX_UPSTREAM_BYTES);
  } catch {
    logFailure("upstream_body_error");
    return {ok: false, failure: "upstreamUnavailable"};
  }
  if (text === null) {
    logFailure("upstream_answer_over_read_cap");
    return {ok: false, failure: "tooBig"};
  }
  try {
    return {ok: true, body: JSON.parse(text) as unknown, text};
  } catch {
    logFailure("upstream_non_json");
    return {ok: false, failure: "upstreamUnavailable"};
  }
}

// ── the chain check ──────────────────────────────────────────────────────────

type ChainVerdict = "verified" | "mismatch" | "unavailable";

const settledChains = new Map<string, Exclude<ChainVerdict, "unavailable">>();
const pendingChains = new Map<string, Promise<ChainVerdict>>();

/** Clears the per-instance chain-check memory. Tests only. */
export function resetRpcProxyStateForTests(): void {
  settledChains.clear();
  pendingChains.clear();
}

async function probeChain(upstream: string, chainId: number, timeoutMs: number): Promise<ChainVerdict> {
  // Its own short timeout, and never tied to one client's request: concurrent requests share it.
  const answer = await postUpstream(upstream, {jsonrpc: "2.0", id: 1, method: "eth_chainId", params: []}, timeoutMs);
  if (!answer.ok) return "unavailable";
  const body = answer.body;
  if (!isPlainObject(body) || body.id !== 1 || typeof body.result !== "string" || !/^0x[0-9a-fA-F]{1,16}$/.test(body.result)) {
    logFailure("chain_check_invalid_answer");
    return "unavailable";
  }
  if (BigInt(body.result) !== BigInt(chainId)) {
    logFailure(`chain_mismatch expected=${chainId} reported=${BigInt(body.result).toString()}`);
    return "mismatch";
  }
  return "verified";
}

/**
 * Once per instance and upstream: a verified or mismatched chain is remembered; an unavailable
 * check is not, so a transient failure is retried by the next request. Concurrent first requests
 * share one probe.
 */
async function checkChain(upstream: string, chainId: number, timeoutMs: number): Promise<ChainVerdict> {
  const settled = settledChains.get(upstream);
  if (settled) return settled;
  let pending = pendingChains.get(upstream);
  if (!pending) {
    pending = probeChain(upstream, chainId, timeoutMs)
      .then((verdict) => {
        if (verdict !== "unavailable") settledChains.set(upstream, verdict);
        return verdict;
      })
      .finally(() => pendingChains.delete(upstream));
    pendingChains.set(upstream, pending);
  }
  return pending;
}

// ── forwarding ───────────────────────────────────────────────────────────────

/** An upstream answer entry for one of our ids, rebuilt with only the JSON-RPC fields. */
function upstreamEntry(value: unknown): {id: number; outcome: {result: unknown} | {error: JsonRpcError}} | null {
  if (!isPlainObject(value) || value.jsonrpc !== "2.0" || typeof value.id !== "number") return null;
  if ("error" in value && value.error !== undefined) {
    const error = value.error;
    if (!isPlainObject(error) || typeof error.code !== "number" || typeof error.message !== "string") {
      return null;
    }
    const rebuilt: JsonRpcError = {code: error.code, message: error.message};
    if ("data" in error) rebuilt.data = error.data;
    return {id: value.id, outcome: {error: rebuilt}};
  }
  if (!("result" in value)) return null;
  return {id: value.id, outcome: {result: value.result}};
}

/**
 * Forwards the admitted entries under the proxy's own ids (1..n), so a client's ids, duplicates
 * included, never decide how answers are matched, then restores the client's ids.
 */
async function forward(
  upstream: {url: string; secrets: string[]},
  entries: JsonRpcRequest[],
  asBatch: boolean,
  timeoutMs: number,
  clientSignal: AbortSignal,
): Promise<{ok: true; outcomes: Map<number, {result: unknown} | {error: JsonRpcError}>} | {ok: false; failure: FailureName}> {
  const outbound = entries.map((entry, index) => ({...entry, id: index + 1}));
  const answer = await postUpstream(upstream.url, asBatch ? outbound : outbound[0], timeoutMs, clientSignal);
  if (!answer.ok && answer.failure === "tooBig") {
    // Too large to read, so too large to return: every forwarded entry gets the named error.
    return {ok: true, outcomes: new Map(outbound.map(({id}) => [id, {error: {...RPC_PROXY_RESPONSE_TOO_BIG}}]))};
  }
  if (!answer.ok) return answer;
  if (upstream.secrets.some((secret) => answer.text.includes(secret))) {
    logFailure("upstream_echoed_its_url");
    return {ok: false, failure: "upstreamInvalid"};
  }
  const raw = asBatch ? answer.body : [answer.body];
  if (!Array.isArray(raw) || raw.length !== outbound.length) {
    logFailure("upstream_malformed");
    return {ok: false, failure: "upstreamInvalid"};
  }
  const outcomes = new Map<number, {result: unknown} | {error: JsonRpcError}>();
  for (const value of raw) {
    const parsed = upstreamEntry(value);
    if (!parsed || parsed.id < 1 || parsed.id > outbound.length || outcomes.has(parsed.id)) {
      logFailure("upstream_malformed");
      return {ok: false, failure: "upstreamInvalid"};
    }
    outcomes.set(parsed.id, parsed.outcome);
  }
  return {ok: true, outcomes};
}

// ── the handler ──────────────────────────────────────────────────────────────

export type RpcProxyOptions = {
  /** Defaults to process.env.RPC_PROXY_UPSTREAM_URL, read per request. */
  upstreamUrl?: string;
  /** Defaults to this build's NEXT_PUBLIC_CHAIN_ID. */
  chainId?: number;
  /** Defaults to RPC_PROXY_UPSTREAM_TIMEOUT_MS. */
  upstreamTimeoutMs?: number;
  /** Defaults to RPC_PROXY_CHAIN_PROBE_TIMEOUT_MS. */
  probeTimeoutMs?: number;
};

export async function handleRpcProxyRequest(request: Request, options: RpcProxyOptions = {}): Promise<Response> {
  if (request.method !== "POST") return failure("methodNotAllowed");
  if (!rpcProxyOriginAllowed(request)) return failure("foreignOrigin");

  const contentType = request.headers.get("content-type")?.split(";")[0]?.trim().toLowerCase();
  if (contentType !== "application/json") return failure("notJson");
  const declared = request.headers.get("content-length");
  if (declared !== null && Number(declared) > RPC_PROXY_MAX_BODY_BYTES) return failure("tooLarge");

  let text: string | null;
  try {
    text = await readCapped(request.body, RPC_PROXY_MAX_BODY_BYTES);
  } catch {
    return failure("parseError");
  }
  if (text === null) return failure("tooLarge");
  let parsed: unknown;
  try {
    parsed = JSON.parse(text) as unknown;
  } catch {
    return failure("parseError");
  }

  const asBatch = Array.isArray(parsed);
  const rawEntries = asBatch ? (parsed as unknown[]) : [parsed];
  if (asBatch && rawEntries.length === 0) return failure("invalidRequest");
  if (rawEntries.length > RPC_PROXY_MAX_BATCH) return failure("batchTooLarge");
  const entries: JsonRpcRequest[] = [];
  for (const raw of rawEntries) {
    const entry = parseEntry(raw);
    if (!entry) return failure("invalidRequest");
    entries.push(entry);
  }

  const refusals = entries.map(rpcProxyEntryRefusal);
  const admitted = entries.filter((_, index) => refusals[index] === null);
  let outcomes = new Map<number, {result: unknown} | {error: JsonRpcError}>();

  if (admitted.length > 0) {
    const known = {entries, refusals, asBatch};
    const chainId = options.chainId ?? CHAIN_ID;
    const upstream = rpcProxyUpstream(
      options.upstreamUrl ?? process.env[RPC_PROXY_UPSTREAM_ENV],
      chainId,
    );
    if (!upstream) {
      logFailure("upstream_unconfigured_or_invalid");
      return failure("unconfigured", known);
    }
    const verdict = await checkChain(upstream.url, chainId, options.probeTimeoutMs ?? RPC_PROXY_CHAIN_PROBE_TIMEOUT_MS);
    if (verdict === "mismatch") return failure("wrongChain", known);
    if (verdict === "unavailable") return failure("upstreamUnavailable", known);
    const forwarded = await forward(
      upstream,
      admitted,
      asBatch,
      options.upstreamTimeoutMs ?? RPC_PROXY_UPSTREAM_TIMEOUT_MS,
      request.signal,
    );
    if (!forwarded.ok) return failure(forwarded.failure, known);
    outcomes = forwarded.outcomes;
  }

  let forwardedIndex = 0;
  const answers: JsonRpcResponse[] = entries.map((entry, index) => {
    const refusal = refusals[index];
    if (refusal) return {jsonrpc: "2.0", id: entry.id, error: refusal};
    forwardedIndex += 1;
    const outcome = outcomes.get(forwardedIndex)!;
    return {jsonrpc: "2.0", id: entry.id, ...outcome};
  });
  const fitted = fitResponseBudget(answers);
  return respond(asBatch ? fitted : fitted[0], 200);
}

/**
 * Keeps the answer under {@link RPC_PROXY_MAX_RESPONSE_BYTES}: while it is over, the largest entry
 * is replaced by the named too-big error. Small entries in the same batch still answer.
 */
function fitResponseBudget(answers: JsonRpcResponse[]): JsonRpcResponse[] {
  const sizes = answers.map((answer) => Buffer.byteLength(JSON.stringify(answer)));
  // An array adds its brackets and one comma between entries.
  let total = sizes.reduce((sum, size) => sum + size, 0) + answers.length + 1;
  if (total <= RPC_PROXY_MAX_RESPONSE_BYTES) return answers;
  const fitted = [...answers];
  let replaced = 0;
  while (total > RPC_PROXY_MAX_RESPONSE_BYTES) {
    let largest = 0;
    for (let index = 1; index < sizes.length; index += 1) if (sizes[index] > sizes[largest]) largest = index;
    const tooBig: JsonRpcResponse = {jsonrpc: "2.0", id: fitted[largest].id, error: {...RPC_PROXY_RESPONSE_TOO_BIG}};
    const size = Buffer.byteLength(JSON.stringify(tooBig));
    if (size >= sizes[largest]) break; // nothing left to shrink; cannot happen with a 4 MB budget
    total -= sizes[largest] - size;
    sizes[largest] = size;
    fitted[largest] = tooBig;
    replaced += 1;
  }
  logFailure(`response_over_budget entries_replaced=${replaced}`);
  return fitted;
}
