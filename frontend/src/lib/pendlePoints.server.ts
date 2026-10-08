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
/** Raw points, 1e18 to a point: a uint256 at most. */
const RAW = /^(0|[1-9]\d{0,77})$/;

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
  if (typeof b.asOfTimestamp !== "number" || !Number.isSafeInteger(b.asOfTimestamp) || b.asOfTimestamp <= 0) {
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

/**
 * One wallet's Pendle points from the points site. Ethereum only: on a testnet build the Pendle
 * markets do not exist, so it answers disabled without a request.
 */
export async function loadPendlePoints(wallet: Address, fetcher: typeof fetch = fetch): Promise<PendlePointsAnswer> {
  if (!IS_MAINNET) return {ok: true, enabled: false};
  let response: Response;
  try {
    response = await fetcher(`${PENDLE_POINTS_URL}?wallet=${wallet.toLowerCase()}`, {
      headers: {accept: "application/json"},
      signal: AbortSignal.timeout(TIMEOUT_MS),
      cache: "no-store",
    });
  } catch {
    fail("the points site did not answer");
  }
  if (!response.ok) fail(`the points site answered ${response.status}`);
  let body: unknown;
  try {
    body = await response.json();
  } catch {
    fail("the answer is not JSON");
  }
  return parsePendlePoints(body, wallet);
}
