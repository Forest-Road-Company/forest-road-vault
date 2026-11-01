const UPSTREAM = "https://points.forestroadvault.com/api/points-leaderboard";
const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const UINT = /^(0|[1-9][0-9]*)$/;

type Row = { rank: number; wallet: string; points: string; onchain: string; pendle: string; morpho: string };

function validBoard(value: unknown): value is { ok: true; enabled: true; rows: Row[]; rankedPoints: string; truncated: boolean } {
  if (!value || typeof value !== "object") return false;
  const board = value as Record<string, unknown>;
  if (board.ok !== true || board.enabled !== true || !Array.isArray(board.rows) || board.rows.length > 500) return false;
  if (typeof board.rankedPoints !== "string" || !UINT.test(board.rankedPoints) || typeof board.truncated !== "boolean") return false;
  const wallets = new Set<string>();
  let total = 0n;
  let previous: Row | undefined;
  for (let index = 0; index < board.rows.length; index += 1) {
    const row = board.rows[index] as Partial<Row>;
    if (!Number.isSafeInteger(row.rank) || (row.rank ?? 0) < 1 || typeof row.wallet !== "string" || !ADDRESS.test(row.wallet)) return false;
    if (![row.points, row.onchain, row.pendle, row.morpho].every((part) => typeof part === "string" && UINT.test(part))) return false;
    const wallet = row.wallet.toLowerCase();
    if (wallets.has(wallet)) return false;
    wallets.add(wallet);
    const points = BigInt(row.points!);
    if (points !== BigInt(row.onchain!) + BigInt(row.pendle!) + BigInt(row.morpho!)) return false;
    if (previous) {
      const previousPoints = BigInt(previous.points);
      if (points > previousPoints) return false;
      const expectedRank = points === previousPoints ? previous.rank : index + 1;
      if (row.rank !== expectedRank) return false;
    }
    total += points;
    previous = row as Row;
  }
  return board.truncated || total === BigInt(board.rankedPoints);
}

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  if (new URL(request.url).search !== "") {
    return Response.json({ ok: false, error: "The leaderboard takes no parameters." }, { status: 400, headers: { "cache-control": "no-store" } });
  }
  try {
    const upstream = await fetch(UPSTREAM, { headers: { accept: "application/json" }, next: { revalidate: 300 } });
    const body: unknown = await upstream.json();
    if (!upstream.ok || !validBoard(body)) throw new Error("upstream leaderboard failed validation");
    return Response.json(body, { headers: { "cache-control": "public, s-maxage=300, stale-while-revalidate=600" } });
  } catch {
    return Response.json({ ok: false, error: "The live Ethereum leaderboard is temporarily unavailable." }, { status: 502, headers: { "cache-control": "no-store" } });
  }
}

/** Refuse mutation-shaped requests explicitly and prevent an intermediary from caching the 405. */
export async function POST() {
  return Response.json(
    { ok: false, error: "Method not allowed." },
    { status: 405, headers: { "cache-control": "no-store" } },
  );
}
