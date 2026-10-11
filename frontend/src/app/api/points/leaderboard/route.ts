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
    return Response.json(served.answer, {
      headers: {"cache-control": "public, s-maxage=300, stale-while-revalidate=600"},
    });
  } catch (error) {
    console.error(`points.leaderboard failed: ${describe(error)}`);
    const catchingUp = error instanceof LeaderboardNotReadyError || error instanceof MorphoPointsNotReadyError;
    return Response.json(
      {
        ok: false,
        error: catchingUp
          ? "The leaderboard is catching up with the chain. Try again in a minute."
          : "The leaderboard is temporarily unavailable.",
      },
      {status: catchingUp ? 503 : 502, headers: {"cache-control": "no-store"}},
    );
  }
}
