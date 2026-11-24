import {IS_MAINNET} from "@/config/contracts";
import {LEADERBOARD_MAX_ROWS} from "@/config/pointsLeaderboard";

const UPSTREAM = "https://points.forestroadvault.com/api/points-leaderboard";
const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const UINT = /^(0|[1-9][0-9]*)$/;
const UPSTREAM_TIMEOUT_MS = 10_000;
const MAX_BODY_BYTES = 1_048_576;

type Row = {rank: number; wallet: string; points: string; onchain: string; pendle: string; morpho: string};
type Venue = {key: string; label: string; address: string; points: string; note: string};
type PendleMeta = {enabled: false} | {enabled: true; asOfBlock: string; asOfTimestamp: number};
type MorphoMeta = {enabled: boolean; withheld: number};
type ValidatedBoard = {
  ok: true;
  enabled: true;
  asOfBlock: string;
  asOfTimestamp: string;
  pendle: PendleMeta;
  morpho: MorphoMeta;
  ranked: number;
  rankedPoints: string;
  truncated: boolean;
  rows: Row[];
  forestRoad: {wallets: number; points: string};
  venues: Venue[];
  notRanked: {jurisdictionBlocked: number; belowOnePoint: number};
};

function isSafeNonNegativeInt(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function validBoard(value: unknown): ValidatedBoard | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const board = value as Record<string, unknown>;
  if (board.ok !== true || board.enabled !== true || !Array.isArray(board.rows) || board.rows.length > LEADERBOARD_MAX_ROWS) {
    return null;
  }
  if (
    typeof board.asOfBlock !== "string" ||
    !UINT.test(board.asOfBlock) ||
    typeof board.asOfTimestamp !== "string" ||
    !UINT.test(board.asOfTimestamp) ||
    !isSafeNonNegativeInt(board.ranked) ||
    board.ranked < board.rows.length ||
    typeof board.rankedPoints !== "string" ||
    !UINT.test(board.rankedPoints) ||
    typeof board.truncated !== "boolean"
  ) {
    return null;
  }

  // Validate nested `pendle`, `morpho`, `forestRoad`, `notRanked`, and `venues` objects required
  // unconditionally by PointsLeaderboard.tsx.
  if (!board.pendle || typeof board.pendle !== "object" || Array.isArray(board.pendle)) return null;
  const rawPendle = board.pendle as Record<string, unknown>;
  let pendle: PendleMeta;
  if (rawPendle.enabled === false) {
    pendle = {enabled: false};
  } else if (
    rawPendle.enabled === true &&
    typeof rawPendle.asOfBlock === "string" &&
    UINT.test(rawPendle.asOfBlock) &&
    isSafeNonNegativeInt(rawPendle.asOfTimestamp)
  ) {
    pendle = {enabled: true, asOfBlock: rawPendle.asOfBlock, asOfTimestamp: rawPendle.asOfTimestamp};
  } else {
    return null;
  }

  if (!board.morpho || typeof board.morpho !== "object" || Array.isArray(board.morpho)) return null;
  const rawMorpho = board.morpho as Record<string, unknown>;
  if (typeof rawMorpho.enabled !== "boolean" || !isSafeNonNegativeInt(rawMorpho.withheld)) return null;
  const morpho: MorphoMeta = {enabled: rawMorpho.enabled, withheld: rawMorpho.withheld};

  if (!board.forestRoad || typeof board.forestRoad !== "object" || Array.isArray(board.forestRoad)) return null;
  const rawFr = board.forestRoad as Record<string, unknown>;
  if (!isSafeNonNegativeInt(rawFr.wallets) || typeof rawFr.points !== "string" || !UINT.test(rawFr.points)) return null;
  const forestRoad = {wallets: rawFr.wallets, points: rawFr.points};

  if (!board.notRanked || typeof board.notRanked !== "object" || Array.isArray(board.notRanked)) return null;
  const rawNotRanked = board.notRanked as Record<string, unknown>;
  if (!isSafeNonNegativeInt(rawNotRanked.jurisdictionBlocked) || !isSafeNonNegativeInt(rawNotRanked.belowOnePoint)) {
    return null;
  }
  const notRanked = {
    jurisdictionBlocked: rawNotRanked.jurisdictionBlocked,
    belowOnePoint: rawNotRanked.belowOnePoint,
  };

  if (!Array.isArray(board.venues) || board.venues.length > 50) return null;

  const wallets = new Set<string>();
  const rows: Row[] = [];
  let total = 0n;
  let previous: Row | undefined;
  for (let index = 0; index < board.rows.length; index += 1) {
    const raw = board.rows[index];
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
    const row = raw as Partial<Row>;
    if (!Number.isSafeInteger(row.rank) || (row.rank ?? 0) < 1 || typeof row.wallet !== "string" || !ADDRESS.test(row.wallet)) return null;
    if (![row.points, row.onchain, row.pendle, row.morpho].every((part) => typeof part === "string" && UINT.test(part))) return null;
    const wallet = row.wallet.toLowerCase();
    if (wallets.has(wallet)) return null;
    wallets.add(wallet);
    const points = BigInt(row.points!);
    if (points !== BigInt(row.onchain!) + BigInt(row.pendle!) + BigInt(row.morpho!)) return null;
    if (index === 0) {
      if (row.rank !== 1) return null;
    } else if (previous) {
      const previousPoints = BigInt(previous.points);
      if (points > previousPoints) return null;
      const expectedRank = points === previousPoints ? previous.rank : index + 1;
      if (row.rank !== expectedRank) return null;
    }
    total += points;
    const cleanRow: Row = {
      rank: row.rank!,
      wallet: row.wallet,
      points: row.points!,
      onchain: row.onchain!,
      pendle: row.pendle!,
      morpho: row.morpho!,
    };
    rows.push(cleanRow);
    previous = cleanRow;
  }

  const rankedPoints = BigInt(board.rankedPoints);
  if (board.truncated ? rankedPoints < total : rankedPoints !== total) return null;

  const venues: Venue[] = [];
  for (const rawVenue of board.venues) {
    if (!rawVenue || typeof rawVenue !== "object" || Array.isArray(rawVenue)) return null;
    const venue = rawVenue as Partial<Venue>;
    if (
      typeof venue.key !== "string" ||
      venue.key.length === 0 ||
      venue.key.length > 80 ||
      typeof venue.label !== "string" ||
      venue.label.length === 0 ||
      venue.label.length > 160 ||
      typeof venue.address !== "string" ||
      !ADDRESS.test(venue.address) ||
      typeof venue.points !== "string" ||
      !UINT.test(venue.points) ||
      typeof venue.note !== "string" ||
      venue.note.length > 400
    ) {
      return null;
    }
    venues.push({
      key: venue.key,
      label: venue.label,
      address: venue.address,
      points: venue.points,
      note: venue.note,
    });
  }

  return {
    ok: true,
    enabled: true,
    asOfBlock: board.asOfBlock,
    asOfTimestamp: board.asOfTimestamp,
    pendle,
    morpho,
    ranked: board.ranked,
    rankedPoints: board.rankedPoints,
    truncated: board.truncated,
    rows,
    forestRoad,
    venues,
    notRanked,
  };
}

async function readCappedText(response: Response, limit: number): Promise<string> {
  const length = Number(response.headers.get("content-length") ?? "0");
  if (Number.isFinite(length) && length > limit) throw new Error("upstream leaderboard response too large");
  if (!response.body) return "";
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let total = 0;
  let text = "";
  try {
    for (;;) {
      const {done, value} = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > limit) throw new Error("upstream leaderboard response too large");
      text += decoder.decode(value, {stream: true});
    }
    text += decoder.decode();
    return text;
  } finally {
    await reader.cancel().catch(() => {});
  }
}

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 15;

export async function GET(request: Request) {
  // Staging-only proxy: production serves /api/points/leaderboard directly from Ethereum state.
  if (IS_MAINNET) {
    return Response.json({ok: false, error: "Not found."}, {status: 404, headers: {"cache-control": "no-store"}});
  }
  if (new URL(request.url).search !== "") {
    return Response.json({ok: false, error: "The leaderboard takes no parameters."}, {status: 400, headers: {"cache-control": "no-store"}});
  }
  try {
    const upstream = await fetch(UPSTREAM, {
      headers: {accept: "application/json"},
      redirect: "error",
      cache: "no-store",
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
    if (!upstream.ok) throw new Error(`upstream leaderboard status ${upstream.status}`);
    const body: unknown = JSON.parse(await readCappedText(upstream, MAX_BODY_BYTES));
    const validated = validBoard(body);
    if (!validated) throw new Error("upstream leaderboard failed validation");
    return Response.json(validated, {
      headers: {"cache-control": "public, max-age=0, must-revalidate, s-maxage=300, stale-while-revalidate=600, stale-if-error=600"},
    });
  } catch (error) {
    const name = error instanceof Error ? error.name : "UnknownError";
    console.error(`points.live-leaderboard failed: ${name}`);
    return Response.json(
      {ok: false, error: "The live Ethereum leaderboard is temporarily unavailable."},
      {status: 502, headers: {"cache-control": "no-store"}},
    );
  }
}

/** Refuse mutation-shaped requests explicitly and prevent an intermediary from caching the 405. */
export async function POST() {
  return Response.json(
    {ok: false, error: "Method not allowed."},
    {status: 405, headers: {allow: "GET", "cache-control": "no-store"}},
  );
}
