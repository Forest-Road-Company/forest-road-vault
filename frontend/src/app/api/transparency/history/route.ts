import {loadTransparencyHistory} from "@/lib/transparencyHistory.server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

export async function GET(request: Request) {
  if (new URL(request.url).search !== "") {
    return Response.json(
      {ok: false, error: "Transparency history takes no parameters."},
      {status: 400, headers: {"cache-control": "no-store"}},
    );
  }
  try {
    const history = await loadTransparencyHistory();
    return Response.json(history, {
      headers: {
        "cache-control": "public, s-maxage=60, stale-while-revalidate=300, stale-if-error=600",
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
    {status: 405, headers: {"cache-control": "no-store"}},
  );
}
