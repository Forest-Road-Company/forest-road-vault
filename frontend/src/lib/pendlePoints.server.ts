import type {Address} from "viem";
import {IS_MAINNET} from "@/config/contracts";

/**
 * Participation points for sUSDfr and USDfr held through Pendle.
 *
 * Tokens deposited into a Pendle market leave their owner's wallet, so the on-chain PointsModule
 * credits the market's SY contract instead. Forest Road credits the owners off-chain (direction of
 * 8 October 2026): the points site replays the markets' own events, crediting YT holders and LPs,
 * and its weekly race counts the result. This module reads that same answer, so the app and the race
 * always show the same numbers, and checks its shape before anything is displayed.
 *
 * The points site applies decision D16 as the Morpho mirror does: a protocol-exempt or
 * jurisdiction-blocked address, read at the served block, earns nothing for its whole history.
 */

/** The points site's read-only answer for one wallet (forestvault-whitelist, src/app/api/pendle-points). */
export const PENDLE_POINTS_URL = "https://points.forestroadvault.com/api/pendle-points";
const TIMEOUT_MS = 8_000;
const MAX_MARKETS = 8;
const MAX_WALLET_RESPONSE_BYTES = 256 * 1024;
const MAX_LEADERBOARD_RESPONSE_BYTES = 4 * 1024 * 1024;
const WALLET_CACHE_TTL_MS = 60_000;
const MAX_WALLET_CACHE = 500;
/** Raw points, 1e18 to a point: a uint256 at most. */
const RAW = /^(0|[1-9]\d{0,77})$/;

const walletCache = new Map<string, {answer: PendlePointsAnswer; at: number}>();
const walletInFlight = new Map<string, Promise<PendlePointsAnswer>>();

/** Clears the per-instance wallet cache. Tests only. */
export function resetPendlePointsCache(): void {
  walletCache.clear();
  walletInFlight.clear();
}

/** Upper bound on unix timestamps accepted from upstream (year 2100) so Date#toISOString never throws RangeError. */
const MAX_UNIX_TIMESTAMP_SECONDS = 4_102_444_800;

async function readCappedJson(response: Response, limit: number): Promise<unknown> {
  const declared = response.headers.get("content-length");
  if (declared !== null) {
    const length = Number(declared);
    if (!Number.isFinite(length) || length < 0 || length > limit) {
      await response.body?.cancel().catch(() => undefined);
      fail("the answer is too large");
    }
  }
  const body = response.body;
  if (!body) fail("the answer is empty");
  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const {done, value} = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > limit) {
        fail("the answer is too large");
      }
      chunks.push(value);
    }
  } catch (error) {
    if (error instanceof PendlePointsUnavailableError) throw error;
    fail("the points site did not finish answering");
  } finally {
    await reader.cancel().catch(() => undefined);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return JSON.parse(new TextDecoder("utf-8", {fatal: true}).decode(bytes)) as unknown;
  } catch {
    fail("the answer is not JSON");
  }
}

/** The points site was unreachable or answered something this module will not show. Safe to log. */
export class PendlePointsUnavailableError extends Error {
  override name = "PendlePointsUnavailableError";
}

export type PendleMarketPoints = {
  key: string;
  label: string;
  yt: string;
  sy: string;
  lp: string;
  points: string;
  pointsPerDay: string;
};

export type PendlePointsAnswer =
  | {ok: true; enabled: false}
  | {
      ok: true;
      enabled: true;
      asOfBlock: string;
      asOfTimestamp: number;
      excluded: null | "protocol-exempt" | "jurisdiction-blocked";
      points: string;
      pointsPerDay: string;
      markets: PendleMarketPoints[];
    };

function fail(message: string): never {
  throw new PendlePointsUnavailableError(`pendle points: ${message}`);
}

function raw(value: unknown, field: string): string {
  if (typeof value !== "string" || !RAW.test(value)) fail(`${field} is not a raw point amount`);
  return value;
}

/** Validates the points site's answer for `wallet`; anything unexpected is refused, never shown. */
export function parsePendlePoints(body: unknown, wallet: Address): PendlePointsAnswer {
  if (typeof body !== "object" || body === null) fail("the answer is not an object");
  const b = body as Record<string, unknown>;
  if (b.ok !== true) fail("the points site reported a failure");
  if (b.enabled === false) return {ok: true, enabled: false};
  if (b.enabled !== true) fail("enabled is not a boolean");
  if (typeof b.wallet !== "string" || b.wallet !== wallet.toLowerCase()) fail("the answer is for another wallet");
  if (typeof b.asOfBlock !== "string" || !/^[1-9]\d{0,19}$/.test(b.asOfBlock)) fail("asOfBlock is not a block number");
  if (
    typeof b.asOfTimestamp !== "number" ||
    !Number.isSafeInteger(b.asOfTimestamp) ||
    b.asOfTimestamp <= 0 ||
    b.asOfTimestamp > MAX_UNIX_TIMESTAMP_SECONDS
  ) {
    fail("asOfTimestamp is not a time");
  }
  const excluded = b.excluded;
  if (excluded !== null && excluded !== "protocol-exempt" && excluded !== "jurisdiction-blocked") {
    fail("excluded is not a known status");
  }
  const points = raw(b.points, "points");
  const pointsPerDay = raw(b.pointsPerDay, "pointsPerDay");
  if (!Array.isArray(b.markets) || b.markets.length > MAX_MARKETS) fail("markets is not a short list");
  const markets = b.markets.map((entry: unknown, index: number): PendleMarketPoints => {
    if (typeof entry !== "object" || entry === null) fail(`market ${index} is not an object`);
    const m = entry as Record<string, unknown>;
    if (typeof m.key !== "string" || !/^[a-z0-9-]{1,40}$/.test(m.key)) fail(`market ${index} has no key`);
    if (typeof m.label !== "string" || !/^[A-Za-z0-9 .:/-]{1,60}$/.test(m.label)) fail(`market ${index} has no label`);
    return {
      key: m.key,
      label: m.label,
      yt: raw(m.yt, `market ${index} yt`),
      sy: raw(m.sy, `market ${index} sy`),
      lp: raw(m.lp, `market ${index} lp`),
      points: raw(m.points, `market ${index} points`),
      pointsPerDay: raw(m.pointsPerDay, `market ${index} pointsPerDay`),
    };
  });
  // Each figure is rounded to a millionth of a point on its own, so the parts may miss the whole by
  // up to that much per figure; anything further means the answer does not add up.
  const slack = BigInt(markets.length * 4 + 1) * 10n ** 12n;
  const sum = markets.reduce((total, m) => total + BigInt(m.points), 0n);
  const delta = sum > BigInt(points) ? sum - BigInt(points) : BigInt(points) - sum;
  if (delta > slack) fail("the markets do not add up to the total");
  for (const m of markets) {
    const parts = BigInt(m.yt) + BigInt(m.sy) + BigInt(m.lp);
    const gap = parts > BigInt(m.points) ? parts - BigInt(m.points) : BigInt(m.points) - parts;
    if (gap > 4n * 10n ** 12n) fail(`market ${m.key} does not add up`);
  }
  if (excluded !== null && points !== "0") fail("an excluded wallet is shown points");
  return {
    ok: true,
    enabled: true,
    asOfBlock: b.asOfBlock,
    asOfTimestamp: b.asOfTimestamp,
    excluded,
    points,
    pointsPerDay,
    markets,
  };
}

async function fetchPendlePointsUncached(wallet: Address, fetcher: typeof fetch): Promise<PendlePointsAnswer> {
  let response: Response;
  try {
    response = await fetcher(`${PENDLE_POINTS_URL}?wallet=${wallet.toLowerCase()}`, {
      headers: {accept: "application/json"},
      signal: AbortSignal.timeout(TIMEOUT_MS),
      redirect: "error",
      cache: "no-store",
    });
  } catch {
    fail("the points site did not answer");
  }
  if (!response.ok) {
    await response.body?.cancel().catch(() => undefined);
    fail(`the points site answered ${response.status}`);
  }
  const body = await readCappedJson(response, MAX_WALLET_RESPONSE_BYTES);
  return parsePendlePoints(body, wallet);
}

/**
 * One wallet's Pendle points from the points site. Ethereum only: on a testnet build the Pendle
 * markets do not exist, so it answers disabled without a request. Production calls coalesce in
 * flight and reuse validated answers for 60s so Next.js-stripped query variants cannot amplify
 * upstream traffic.
 */
export async function loadPendlePoints(
  wallet: Address,
  fetcher: typeof fetch = fetch,
  options?: {useCache?: boolean; now?: () => number},
): Promise<PendlePointsAnswer> {
  if (!IS_MAINNET) return {ok: true, enabled: false};
  const useCache = options?.useCache ?? fetcher === fetch;
  if (!useCache) return fetchPendlePointsUncached(wallet, fetcher);

  const now = options?.now ?? Date.now;
  const key = wallet.toLowerCase();
  const cached = walletCache.get(key);
  if (cached && now() - cached.at < WALLET_CACHE_TTL_MS) return cached.answer;
  const existing = walletInFlight.get(key);
  if (existing) return existing;

  const pending = fetchPendlePointsUncached(wallet, fetcher)
    .then((answer) => {
      if (walletCache.size >= MAX_WALLET_CACHE) {
        const oldest = walletCache.keys().next().value;
        if (oldest !== undefined) walletCache.delete(oldest);
      }
      walletCache.set(key, {answer, at: now()});
      return answer;
    })
    .finally(() => {
      if (walletInFlight.get(key) === pending) walletInFlight.delete(key);
    });
  walletInFlight.set(key, pending);
  return pending;
}

/** Every wallet's Pendle points, for the leaderboard (forestvault-whitelist, src/app/api/pendle-points/all). */
export const PENDLE_LEADERBOARD_URL = "https://points.forestroadvault.com/api/pendle-points/all";
/** The points site refuses to list more wallets than this, and so does this module. */
export const PENDLE_LEADERBOARD_MAX_WALLETS = 5_000;
/** Its answer replays every market once per stored block and reads each listed wallet's status. */
const LEADERBOARD_TIMEOUT_MS = 20_000;

export type PendleLeaderboardAnswer =
  | {ok: true; enabled: false}
  | {
      ok: true;
      enabled: true;
      asOfBlock: bigint;
      asOfTimestamp: number;
      /** Lowercase wallets with more than zero raw points; exempt and blocked wallets are never listed. */
      points: Map<string, bigint>;
    };

/** Validates the points site's every-wallet answer; anything unexpected is refused, never ranked. */
export function parsePendleLeaderboard(body: unknown): PendleLeaderboardAnswer {
  if (typeof body !== "object" || body === null) fail("the answer is not an object");
  const b = body as Record<string, unknown>;
  if (b.ok !== true) fail("the points site reported a failure");
  if (b.enabled === false) return {ok: true, enabled: false};
  if (b.enabled !== true) fail("enabled is not a boolean");
  if (typeof b.asOfBlock !== "string" || !/^[1-9]\d{0,19}$/.test(b.asOfBlock)) fail("asOfBlock is not a block number");
  if (
    typeof b.asOfTimestamp !== "number" ||
    !Number.isSafeInteger(b.asOfTimestamp) ||
    b.asOfTimestamp <= 0 ||
    b.asOfTimestamp > MAX_UNIX_TIMESTAMP_SECONDS
  ) {
    fail("asOfTimestamp is not a time");
  }
  if (!Array.isArray(b.wallets) || b.wallets.length > PENDLE_LEADERBOARD_MAX_WALLETS) fail("wallets is not a bounded list");
  const points = new Map<string, bigint>();
  const seen = new Set<string>();
  b.wallets.forEach((entry: unknown, index: number) => {
    if (typeof entry !== "object" || entry === null) fail(`wallet ${index} is not an object`);
    const row = entry as Record<string, unknown>;
    if (typeof row.wallet !== "string" || !/^0x[0-9a-f]{40}$/.test(row.wallet)) fail(`wallet ${index} is not a lowercase address`);
    const value = BigInt(raw(row.points, `wallet ${index} points`));
    if (seen.has(row.wallet)) fail(`wallet ${index} is listed twice`);
    seen.add(row.wallet);
    // The points site lists every wallet whose points are above zero and rounds each to a millionth of a
    // point, so a dust holder arrives as "0". It ranks nowhere; refusing it would take the board down.
    if (value > 0n) points.set(row.wallet, value);
  });
  return {ok: true, enabled: true, asOfBlock: BigInt(b.asOfBlock), asOfTimestamp: b.asOfTimestamp, points};
}

/**
 * Every wallet's Pendle points from the points site, for the leaderboard. Ethereum only: on a testnet
 * build the Pendle markets do not exist, so it answers disabled without a request.
 */
export async function loadPendleLeaderboard(
  fetcher: typeof fetch = fetch,
  signal?: AbortSignal,
): Promise<PendleLeaderboardAnswer> {
  if (!IS_MAINNET) return {ok: true, enabled: false};
  const timeout = AbortSignal.timeout(LEADERBOARD_TIMEOUT_MS);
  const combinedSignal = signal ? AbortSignal.any([signal, timeout]) : timeout;
  let response: Response;
  try {
    response = await fetcher(PENDLE_LEADERBOARD_URL, {
      headers: {accept: "application/json"},
      signal: combinedSignal,
      redirect: "error",
      cache: "no-store",
    });
  } catch {
    fail("the points site did not answer");
  }
  if (!response.ok) {
    await response.body?.cancel().catch(() => undefined);
    fail(`the points site answered ${response.status}`);
  }
  const body = await readCappedJson(response, MAX_LEADERBOARD_RESPONSE_BYTES);
  return parsePendleLeaderboard(body);
}
