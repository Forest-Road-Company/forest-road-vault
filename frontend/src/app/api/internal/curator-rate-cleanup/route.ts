import {createHash, timingSafeEqual} from "node:crypto";
import {del, list} from "@vercel/blob";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

const PREFIX = "curators-rate/";
const RETAIN_MS = 60 * 60_000;
const MAX_PAGES = 50;
const CLEANUP_BUDGET_MS = 45_000;
const NO_STORE = {"cache-control": "no-store"} as const;

function sha256(value: string): Buffer {
  return createHash("sha256").update(value).digest();
}

function authorized(request: Request, secret: string): boolean {
  const received = request.headers.get("authorization") ?? "";
  return timingSafeEqual(sha256(received), sha256(`Bearer ${secret}`));
}

export async function GET(request: Request) {
  const secret = process.env.CRON_SECRET?.trim();
  if (!secret || !process.env.BLOB_READ_WRITE_TOKEN?.trim()) {
    return Response.json(
      {ok: false, error: "Cleanup is not configured."},
      {status: 503, headers: NO_STORE},
    );
  }
  if (!authorized(request, secret)) {
    return Response.json(
      {ok: false, error: "Unauthorized."},
      {status: 401, headers: NO_STORE},
    );
  }

  const startedAt = Date.now();
  const cutoff = startedAt - RETAIN_MS;
  let cursor: string | undefined;
  let deleted = 0;
  let complete = false;
  try {
    for (let page = 0; page < MAX_PAGES; page += 1) {
      if (page > 0 && Date.now() - startedAt >= CLEANUP_BUDGET_MS) break;
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
    return Response.json(
      {ok: false, error: "Cleanup failed."},
      {status: 502, headers: NO_STORE},
    );
  }

  if (!complete) {
    console.warn("curators.interest.cleanup incomplete: stopped at page or time budget");
  }

  return Response.json(
    {ok: true, deleted, complete},
    {headers: NO_STORE},
  );
}
