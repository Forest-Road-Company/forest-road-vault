import {IS_MAINNET} from "@/config/contracts";
import {methodNotAllowed} from "@/lib/httpMethod.server";
import {loadLiveLeaderboard} from "@/lib/liveLeaderboard.server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 15;

const BROWSER_CACHE = "public, max-age=0, must-revalidate";
const FRESH_CDN_CACHE = "public, s-maxage=300, stale-while-revalidate=600, stale-if-error=600";

export async function GET(request: Request) {
  // Staging-only proxy: production serves /api/points/leaderboard directly from Ethereum state.
  if (IS_MAINNET) {
    return Response.json({ok: false, error: "Not found."}, {status: 404, headers: {"cache-control": "no-store"}});
  }
  if (new URL(request.url).search !== "") {
    return Response.json({ok: false, error: "The leaderboard takes no parameters."}, {status: 400, headers: {"cache-control": "no-store"}});
  }
  try {
    const validated = await loadLiveLeaderboard();
    return Response.json(validated, {
      headers: {
        "cache-control": BROWSER_CACHE,
        "cdn-cache-control": FRESH_CDN_CACHE,
        "vercel-cdn-cache-control": FRESH_CDN_CACHE,
      },
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

/** Refuse mutation-shaped and unmapped requests explicitly with no-store. */
const refuse = () => methodNotAllowed("GET");
export {refuse as POST, refuse as PUT, refuse as PATCH, refuse as DELETE, refuse as OPTIONS};
