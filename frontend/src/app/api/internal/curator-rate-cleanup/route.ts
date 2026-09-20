import {timingSafeEqual} from "node:crypto";
import {del, list} from "@vercel/blob";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const PREFIX = "curators-rate/";
const RETAIN_MS = 60 * 60_000;
const MAX_PAGES = 50;

function authorized(request: Request, secret: string): boolean {
  const received = Buffer.from(request.headers.get("authorization") ?? "");
  const expected = Buffer.from(`Bearer ${secret}`);
  return received.length === expected.length && timingSafeEqual(received, expected);
}

export async function GET(request: Request) {
  const secret = process.env.CRON_SECRET;
  if (!secret) {
    return Response.json({ok: false, error: "Cleanup is not configured."}, {status: 503});
  }
  if (!authorized(request, secret)) {
    return Response.json({ok: false, error: "Unauthorized."}, {status: 401});
  }

  const cutoff = Date.now() - RETAIN_MS;
  let cursor: string | undefined;
  let deleted = 0;
  let complete = false;
  try {
    for (let page = 0; page < MAX_PAGES; page += 1) {
      const result = await list({prefix: PREFIX, cursor, limit: 1_000});
      const expired = result.blobs
        .filter((blob) => new Date(blob.uploadedAt).getTime() < cutoff)
        .map((blob) => blob.url);
      if (expired.length > 0) {
        await del(expired);
        deleted += expired.length;
      }
      if (!result.hasMore) {
        complete = true;
        break;
      }
      cursor = result.cursor;
    }
  } catch (error) {
    const name = error instanceof Error ? error.name : "UnknownError";
    console.error(`curators.interest.cleanup failed: ${name}`);
    return Response.json({ok: false, error: "Cleanup failed."}, {status: 502});
  }

  return Response.json(
    {ok: true, deleted, complete},
    {headers: {"cache-control": "no-store"}},
  );
}
