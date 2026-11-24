import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";

const blob = vi.hoisted(() => ({del: vi.fn(), list: vi.fn()}));
vi.mock("@vercel/blob", () => ({del: blob.del, list: blob.list}));

import {GET} from "./route";

const SECRET = "fixture";
const request = (secret = SECRET) => new Request(
  "https://forestroadvault.com/api/internal/curator-rate-cleanup",
  {headers: {authorization: `Bearer ${secret}`}},
);

beforeEach(() => {
  process.env.CRON_SECRET = SECRET;
  process.env.BLOB_READ_WRITE_TOKEN = "test-blob-token";
  blob.del.mockReset().mockResolvedValue(undefined);
  blob.list.mockReset().mockResolvedValue({
    blobs: [],
    cursor: undefined,
    hasMore: false,
  });
});

afterEach(() => {
  delete process.env.CRON_SECRET;
  delete process.env.BLOB_READ_WRITE_TOKEN;
});

describe("curator admission-gate cleanup", () => {
  it("requires the Vercel cron bearer secret and sets no-store on failures", async () => {
    const unauthorized = await GET(request("wrong"));
    expect(unauthorized.status).toBe(401);
    expect(unauthorized.headers.get("cache-control")).toBe("no-store");
    expect(blob.list).not.toHaveBeenCalled();

    delete process.env.BLOB_READ_WRITE_TOKEN;
    const unconfigured = await GET(request());
    expect(unconfigured.status).toBe(503);
    expect(unconfigured.headers.get("cache-control")).toBe("no-store");
  });

  it("deletes only expired rate gates and follows pagination", async () => {
    const old = new Date(Date.now() - 2 * 60 * 60_000);
    const fresh = new Date();
    blob.list
      .mockResolvedValueOnce({
        blobs: [
          {url: "https://blob.invalid/old-a", uploadedAt: old},
          {url: "https://blob.invalid/fresh", uploadedAt: fresh},
        ],
        cursor: "next-page",
        hasMore: true,
      })
      .mockResolvedValueOnce({
        blobs: [{url: "https://blob.invalid/old-b", uploadedAt: old}],
        cursor: undefined,
        hasMore: false,
      });

    const response = await GET(request());
    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({ok: true, deleted: 2, complete: true});
    expect(blob.list).toHaveBeenNthCalledWith(1, {
      prefix: "curators-rate/",
      cursor: undefined,
      limit: 1_000,
      abortSignal: expect.any(AbortSignal),
    });
    expect(blob.list).toHaveBeenNthCalledWith(2, {
      prefix: "curators-rate/",
      cursor: "next-page",
      limit: 1_000,
      abortSignal: expect.any(AbortSignal),
    });
    expect(blob.del).toHaveBeenNthCalledWith(
      1,
      ["https://blob.invalid/old-a"],
      expect.objectContaining({abortSignal: expect.any(AbortSignal)}),
    );
    expect(blob.del).toHaveBeenNthCalledWith(
      2,
      ["https://blob.invalid/old-b"],
      expect.objectContaining({abortSignal: expect.any(AbortSignal)}),
    );
  });
});
