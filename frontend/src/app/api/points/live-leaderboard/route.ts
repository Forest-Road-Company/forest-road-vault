import {IS_MAINNET} from "@/config/contracts";
import {LEADERBOARD_MAX_ROWS} from "@/config/pointsLeaderboard";

const UPSTREAM = "https://points.forestroadvault.com/api/points-leaderboard";
const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const UINT = /^(0|[1-9][0-9]*)$/;
const UPSTREAM_TIMEOUT_MS = 10_000;
const MAX_BODY_BYTES = 1_048_576;

type Row = {rank: number; wallet: string; points: string; onchain: string; pendle: string; morpho: string};
type Venue = {key: string; label: string; address: string; points: string; note: string};
type ValidatedBoard = {
  ok: true;
  enabled: true;
  asOfBlock?: string;
  asOfTimestamp?: string;
  rankedWallets?: number;
  rankedPoints: string;
  totalPoints?: string;
  forestRoadPoints?: string;
  truncated: boolean;
  rows: Row[];
  venues?: Venue[];
};

function validBoard(value: unknown): ValidatedBoard | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const board = value as Record<string, unknown>;
  if (board.ok !== true || board.enabled !== true || !Array.isArray(board.rows) || board.rows.length > LEADERBOARD_MAX_ROWS) {
    return null;
  }
  if (typeof board.rankedPoints !== "string" || !UINT.test(board.rankedPoints) || typeof board.truncated !== "boolean") {
    return null;
  }
  if (board.asOfBlock !== undefined && (typeof board.asOfBlock !== "string" || !UINT.test(board.asOfBlock))) return null;
  if (board.asOfTimestamp !== undefined && (typeof board.asOfTimestamp !== "string" || !UINT.test(board.asOfTimestamp))) return null;
  if (board.totalPoints !== undefined && (typeof board.totalPoints !== "string" || !UINT.test(board.totalPoints))) return null;
  if (board.forestRoadPoints !== undefined && (typeof board.forestRoadPoints !== "string" || !UINT.test(board.forestRoadPoints))) return null;
  if (board.rankedWallets !== undefined && (!Number.isSafeInteger(board.rankedWallets) || (board.rankedWallets as number) < board.rows.length)) {
    return null;
  }

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

  let venues: Venue[] | undefined;
  if (board.venues !== undefined) {
    if (!Array.isArray(board.venues) || board.venues.length > 50) return null;
    venues = [];
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
  }

  return {
    ok: true,
    enabled: true,
    ...(board.asOfBlock !== undefined ? {asOfBlock: board.asOfBlock} : {}),
    ...(board.asOfTimestamp !== undefined ? {asOfTimestamp: board.asOfTimestamp} : {}),
    ...(board.rankedWallets !== undefined ? {rankedWallets: board.rankedWallets as number} : {}),
    rankedPoints: board.rankedPoints,
    ...(board.totalPoints !== undefined ? {totalPoints: board.totalPoints} : {}),
    ...(board.forestRoadPoints !== undefined ? {forestRoadPoints: board.forestRoadPoints} : {}),
    truncated: board.truncated,
    rows,
    ...(venues !== undefined ? {venues} : {}),
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
      headers: {"cache-control": "public, s-maxage=300, stale-while-revalidate=600, stale-if-error=600"},
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
    {status: 405, headers: {"cache-control": "no-store"}},
  );
}
