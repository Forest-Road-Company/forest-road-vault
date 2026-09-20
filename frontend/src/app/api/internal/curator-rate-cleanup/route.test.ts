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
  blob.del.mockReset().mockResolvedValue(undefined);
  blob.list.mockReset().mockResolvedValue({
    blobs: [],
    cursor: undefined,
    hasMore: false,
  });
});

afterEach(() => {
  delete process.env.CRON_SECRET;
});

describe("curator admission-gate cleanup", () => {
  it("requires the Vercel cron bearer secret", async () => {
    expect((await GET(request("wrong"))).status).toBe(401);
    expect(blob.list).not.toHaveBeenCalled();
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
    });
    expect(blob.list).toHaveBeenNthCalledWith(2, {
      prefix: "curators-rate/",
      cursor: "next-page",
      limit: 1_000,
    });
    expect(blob.del).toHaveBeenNthCalledWith(1, ["https://blob.invalid/old-a"]);
    expect(blob.del).toHaveBeenNthCalledWith(2, ["https://blob.invalid/old-b"]);
  });
});
