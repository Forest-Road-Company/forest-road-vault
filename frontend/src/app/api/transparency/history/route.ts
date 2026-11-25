import {serveTransparencyHistory} from "@/lib/transparencyHistory.server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

const BROWSER_CACHE = "public, max-age=0, must-revalidate";
const FRESH_CDN_CACHE = "public, s-maxage=60, stale-while-revalidate=300, stale-if-error=600";
const STALE_CDN_CACHE = "public, s-maxage=60";

export async function GET(request: Request) {
  if (new URL(request.url).search !== "") {
    return Response.json(
      {ok: false, error: "Transparency history takes no parameters."},
      {status: 400, headers: {"cache-control": "no-store"}},
    );
  }
  try {
    const served = await serveTransparencyHistory();
    if (served.stale) {
      const name = served.error instanceof Error ? served.error.name : "UnknownError";
      console.error(`transparency.history failed, serving last whole answer: ${name}`);
      return Response.json(served.answer, {
        headers: {
          "cache-control": BROWSER_CACHE,
          "cdn-cache-control": STALE_CDN_CACHE,
          "vercel-cdn-cache-control": STALE_CDN_CACHE,
        },
      });
    }
    return Response.json(served.answer, {
      headers: {
        "cache-control": BROWSER_CACHE,
        "cdn-cache-control": FRESH_CDN_CACHE,
        "vercel-cdn-cache-control": FRESH_CDN_CACHE,
      },
    });
  } catch (error) {
    const name = error instanceof Error ? error.name : "UnknownError";
    console.error(`transparency.history failed: ${name}`);
    return Response.json(
      {ok: false, error: "Historical contract data is temporarily unavailable."},
      {status: 502, headers: {"cache-control": "no-store"}},
    );
  }
}

export async function POST() {
  return Response.json(
    {ok: false, error: "Method not allowed."},
    {status: 405, headers: {allow: "GET", "cache-control": "no-store"}},
  );
}
