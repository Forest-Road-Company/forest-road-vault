import {getAddress, isAddress} from "viem";
import {loadPendlePoints, PendlePointsUnavailableError} from "@/lib/pendlePoints.server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
/** One upstream request with an 8-second timeout, and nothing else. */
export const maxDuration = 15;

/** One wallet's points for sUSDfr and USDfr held through Pendle, as the points site computes them. */
export async function GET(request: Request) {
  const url = new URL(request.url);
  const params = url.searchParams;
  const wallet = params.get("wallet") ?? "";
  // As /api/points/morpho: only `wallet`, and only as a valid EIP-55 or all-lowercase address.
  const unknown = [...params.keys()].some((key) => key !== "wallet");
  if (unknown || params.getAll("wallet").length !== 1 || !isAddress(wallet, {strict: true})) {
    return Response.json(
      {ok: false, error: "Exactly one wallet address is required."},
      {status: 400, headers: {"cache-control": "no-store"}},
    );
  }
  // One CDN cache key per wallet: any other spelling is sent to the EIP-55 URL (as MORPHO-17).
  const canonical = getAddress(wallet);
  if (url.search !== `?wallet=${canonical}`) {
    const location = new URL(`/api/points/pendle?wallet=${canonical}`, url);
    return new Response(null, {
      status: 308,
      headers: {location: location.toString(), "cache-control": "public, max-age=86400, s-maxage=86400"},
    });
  }
  try {
    const result = await loadPendlePoints(canonical);
    return Response.json(result, {
      headers: {"cache-control": "public, s-maxage=60, stale-while-revalidate=300"},
    });
  } catch (error) {
    // Only this module's own static messages are logged; anything else is named, not quoted.
    const known = error instanceof PendlePointsUnavailableError;
    const detail = known ? `: ${(error as Error).message}` : "";
    const name = error instanceof Error ? error.name : "UnknownError";
    console.error(`points.pendle failed: ${name}${detail}`);
    return Response.json(
      {ok: false, error: "Pendle points are temporarily unavailable."},
      {status: 502, headers: {"cache-control": "no-store"}},
    );
  }
}
