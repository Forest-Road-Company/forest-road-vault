import {MorphoPointsIntegrityError, MorphoPointsNotReadyError} from "@/lib/morphoPoints.server";
import {PendlePointsUnavailableError} from "@/lib/pendlePoints.server";
import {
  LeaderboardIntegrityError,
  LeaderboardNotReadyError,
  servePointsLeaderboard,
} from "@/lib/pointsLeaderboard.server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
/**
 * As /api/points/morpho: the participant discovery and the Morpho snapshot each start no chunk more
 * than 20 seconds after the request arrived, apart from the first of each scan, and the rest is a few
 * batched reads and one 20-second upstream request made alongside them.
 */
export const maxDuration = 120;

/** RPC and fetch errors can carry an endpoint URL, so only the loaders' own static messages are logged. */
function describe(error: unknown): string {
  const known =
    error instanceof LeaderboardIntegrityError ||
    error instanceof LeaderboardNotReadyError ||
    error instanceof MorphoPointsIntegrityError ||
    error instanceof MorphoPointsNotReadyError ||
    error instanceof PendlePointsUnavailableError;
  const detail = known ? `: ${(error as Error).message}` : "";
  return `${error instanceof Error ? error.name : "UnknownError"}${detail}`;
}

/**
 * How the CDN holds a whole answer: fresh for five minutes, then served while a newer one is read
 * (stale-while-revalidate) or in place of an error (stale-if-error) for at most ten minutes more.
 * Every cached answer therefore stays within fifteen minutes of being served, the same bound the
 * server applies to its own last whole answer (ANSWER_STALE_IF_ERROR_MS): a failing loader, an
 * integrity failure included, is never hidden for longer than that.
 */
const FRESH_CACHE = "public, s-maxage=300, stale-while-revalidate=600, stale-if-error=600";
/** How soon the page should ask again after a 503: the instance keeps its discovery progress. */
const CATCHING_UP_RETRY_SECONDS = 10;

/** The public points leaderboard. It takes no parameters, so the CDN holds one answer. */
export async function GET(request: Request) {
  const arrivedAt = Date.now();
  if (new URL(request.url).search !== "") {
    return Response.json(
      {ok: false, error: "The leaderboard takes no parameters."},
      {status: 400, headers: {"cache-control": "no-store"}},
    );
  }
  try {
    const served = await servePointsLeaderboard(arrivedAt);
    if (served.stale) {
      console.error(`points.leaderboard failed, serving the last whole answer: ${describe(served.error)}`);
      return Response.json(served.answer, {headers: {"cache-control": "public, s-maxage=60"}});
    }
    return Response.json(served.answer, {headers: {"cache-control": FRESH_CACHE}});
  } catch (error) {
    console.error(`points.leaderboard failed: ${describe(error)}`);
    const catchingUp = error instanceof LeaderboardNotReadyError || error instanceof MorphoPointsNotReadyError;
    return Response.json(
      {
        ok: false,
        error: catchingUp
          ? "The leaderboard is catching up with the chain. Try again in a few seconds."
          : "The leaderboard is temporarily unavailable.",
      },
      {
        status: catchingUp ? 503 : 502,
        headers: catchingUp
          ? {"cache-control": "no-store", "retry-after": String(CATCHING_UP_RETRY_SECONDS)}
          : {"cache-control": "no-store"},
      },
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
