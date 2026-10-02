import {getAddress, isAddress} from "viem";
import {
  loadMorphoCollateralPoints,
  MorphoPointsIntegrityError,
  MorphoPointsNotReadyError,
} from "@/lib/morphoPoints.server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
/**
 * The loader starts no chunk of history later than 20 seconds after the request arrived
 * (`REQUEST_BUDGET_MS`), except the first of each scan, and never splits one. So a request can take
 * 20 seconds, plus what a build it waited behind ran past its own deadline (at most one chunk of
 * each scan), plus its own first chunk of each scan, plus a few single reads; `REQUEST_BUDGET_MS`
 * states the bound in full (Corrovera MORPHO-71, M1001-m4-07). A collateral chunk reads one
 * position for each owner it touched or holds non-zero and for a sixteenth of those held at zero.
 * 120 seconds leaves about 40 seconds of position reads for each of the two collateral chunks: some
 * 13 waves of four 200-owner multicalls at a slow 3 seconds a wave, about 10,000 positions a chunk.
 */
export const maxDuration = 120;

/** One wallet's sUSDfr collateral in the Forest Road Morpho market and the points it has earned. */
export async function GET(request: Request) {
  const arrivedAt = Date.now();
  const url = new URL(request.url);
  const params = url.searchParams;
  const wallet = params.get("wallet") ?? "";
  // Only `wallet` is accepted, and only as a valid EIP-55 or all-lowercase address: a mixed-case
  // spelling with a bad checksum is refused rather than silently corrected to another address.
  const unknown = [...params.keys()].some((key) => key !== "wallet");
  if (unknown || params.getAll("wallet").length !== 1 || !isAddress(wallet, {strict: true})) {
    return Response.json(
      {ok: false, error: "Exactly one wallet address is required."},
      {status: 400, headers: {"cache-control": "no-store"}},
    );
  }
  // A lowercase spelling of the wallet is its own CDN cache key, so it is sent to the one EIP-55 URL
  // (MORPHO-17). The redirect covers case only (Corrovera M1001B-n3-01): before this handler runs,
  // Next.js re-serializes the query (RouteModule.prepare's normalizeCdnUrl, as of 16.3.8 and the
  // same in 16.2.11). It decodes percent-encoding, drops empty separators and strips its own keys
  // (nxtP*, nxtI*, nextInternalLocale), so `?wallet=%30x...`, `?&wallet=...` and
  // `?wallet=...&nxtPa=1` arrive here as the canonical query and are answered under their own URLs,
  // each its own cache key. Neither this handler nor a proxy sees the raw spelling. Those keys cost
  // no more than distinct wallets do, and the control on both is the per-IP rate limit on this
  // path. frontend/points-route-server-test.mts pins this through the built server, so a Next.js
  // upgrade that changes the normalization fails there.
  const canonical = getAddress(wallet);
  if (url.search !== `?wallet=${canonical}`) {
    const location = new URL(`/api/points/morpho?wallet=${canonical}`, url);
    return new Response(null, {
      status: 308,
      headers: {location: location.toString(), "cache-control": "public, max-age=86400, s-maxage=86400"},
    });
  }
  try {
    const result = await loadMorphoCollateralPoints(canonical, undefined, arrivedAt);
    return Response.json(result, {
      headers: {"cache-control": "public, s-maxage=60, stale-while-revalidate=300"},
    });
  } catch (error) {
    // RPC client errors can carry the endpoint URL, so only the loader's own static messages log.
    const known = error instanceof MorphoPointsIntegrityError || error instanceof MorphoPointsNotReadyError;
    const detail = known ? `: ${(error as Error).message}` : "";
    const name = error instanceof Error ? error.name : "UnknownError";
    console.error(`points.morpho failed: ${name}${detail}`);
    return Response.json(
      {ok: false, error: "Morpho collateral points are temporarily unavailable."},
      {status: 502, headers: {"cache-control": "no-store"}},
    );
  }
}
