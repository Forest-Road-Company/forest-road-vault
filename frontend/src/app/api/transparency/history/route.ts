import {loadTransparencyHistory} from "@/lib/transparencyHistory.server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  try {
    const history = await loadTransparencyHistory();
    return Response.json(history, {
      headers: {
        "cache-control": "public, s-maxage=60, stale-while-revalidate=300",
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
