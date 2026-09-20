import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";

const blob = vi.hoisted(() => ({del: vi.fn(), list: vi.fn(), put: vi.fn()}));

vi.mock("@vercel/blob", () => ({
  put: blob.put,
  del: blob.del,
  list: blob.list,
  BlobPreconditionFailedError: class BlobPreconditionFailedError extends Error {},
}));

import {POST} from "./route";

function request(body: unknown, headers: Record<string, string> = {}) {
  return new Request("https://forestroadvault.com/api/curators/interest", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      origin: "https://forestroadvault.com",
      "x-vercel-forwarded-for": "192.0.2.10",
      ...headers,
    },
    body: JSON.stringify(body),
  });
}

beforeEach(() => {
  process.env.BLOB_READ_WRITE_TOKEN = "test-token";
  process.env.CURATOR_INTEREST_KEY_SECRET = "test-secret-with-enough-entropy";
  blob.put.mockReset().mockResolvedValue({url: "https://blob.invalid/test"});
  blob.del.mockReset().mockResolvedValue(undefined);
  blob.list.mockReset().mockResolvedValue({blobs: [], cursor: undefined, hasMore: false});
});

afterEach(() => {
  delete process.env.BLOB_READ_WRITE_TOKEN;
  delete process.env.CURATOR_INTEREST_KEY_SECRET;
});

describe("curator interest admission", () => {
  it.each([null, [], "email@example.com", 42])("rejects a non-object JSON body: %j", async (body) => {
    const response = await POST(request(body));
    expect(response.status).toBe(400);
    expect(blob.put).not.toHaveBeenCalled();
  });

  it("refuses cross-origin browser posts before allocating storage", async () => {
    const response = await POST(request({email: "curator@example.com"}, {origin: "https://attacker.invalid"}));
    expect(response.status).toBe(403);
    expect(blob.put).not.toHaveBeenCalled();
  });

  it("claims a source slot and email gate before storing a valid registration", async () => {
    const response = await POST(request({email: "curator@example.com", chain: "solana"}));
    expect(response.status).toBe(200);
    expect(blob.put).toHaveBeenCalledTimes(3);
    const paths = blob.put.mock.calls.map(([pathname]) => String(pathname));
    expect(paths[0]).toMatch(/^curators-rate\/source\/[0-9a-f]{64}\/.+\/0\.json$/);
    expect(paths[1]).toMatch(/^curators-rate\/email\/[0-9a-f]{64}\//);
    expect(paths[2]).toMatch(/^curators\/[0-9a-f]{64}\//);
    expect(paths.join("\n")).not.toContain("curator@example.com");
    expect(blob.put.mock.calls[0][2]).toEqual(expect.objectContaining({
      addRandomSuffix: false,
      allowOverwrite: false,
    }));
  });

  it("uses the next free source slot instead of rejecting a first-time colleague", async () => {
    blob.put.mockRejectedValueOnce(Object.assign(new Error("already exists"), {
      name: "BlobPreconditionFailedError",
    }));
    const response = await POST(request({email: "curator@example.com"}));
    expect(response.status).toBe(200);
    expect(String(blob.put.mock.calls[1][0])).toMatch(/\/1\.json$/);
  });

  it("returns 429 only after all sixteen application source slots are occupied", async () => {
    blob.put.mockRejectedValue(Object.assign(new Error("already exists"), {
      name: "BlobPreconditionFailedError",
    }));
    const response = await POST(request({email: "curator@example.com"}));
    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("600");
    expect(blob.put).toHaveBeenCalledTimes(16);
  });

  it("returns the same success for a durable duplicate without revealing recency", async () => {
    blob.put
      .mockResolvedValueOnce({url: "https://blob.invalid/source"})
      .mockRejectedValueOnce(Object.assign(new Error("already exists"), {
        name: "BlobPreconditionFailedError",
      }));
    blob.list.mockResolvedValueOnce({
      blobs: [{url: "https://blob.invalid/record"}],
      cursor: undefined,
      hasMore: false,
    });
    const response = await POST(request({email: "curator@example.com"}));
    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({ok: true});
    expect(blob.put).toHaveBeenCalledTimes(2);
    expect(blob.del).toHaveBeenCalledWith([String(blob.put.mock.calls[0][0])]);
  });

  it("never reports success for an orphaned email gate", async () => {
    blob.put
      .mockResolvedValueOnce({url: "https://blob.invalid/source"})
      .mockRejectedValueOnce(Object.assign(new Error("already exists"), {
        name: "BlobPreconditionFailedError",
      }));
    const log = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const response = await POST(request({email: "curator@example.com"}));
    expect(response.status).toBe(502);
    expect(blob.list).toHaveBeenCalledWith(expect.objectContaining({
      prefix: expect.stringMatching(/^curators\/[0-9a-f]{64}\/$/),
    }));
    expect(blob.del).toHaveBeenCalledTimes(2);
    log.mockRestore();
  });

  it("releases both gates when the durable record write fails", async () => {
    blob.put
      .mockResolvedValueOnce({url: "https://blob.invalid/source"})
      .mockResolvedValueOnce({url: "https://blob.invalid/email"})
      .mockRejectedValueOnce(Object.assign(new Error("socket failed"), {
        name: "BlobUnknownError",
      }));
    const log = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const response = await POST(request({email: "curator@example.com"}));
    expect(response.status).toBe(502);
    expect(blob.del).toHaveBeenCalledWith([
      String(blob.put.mock.calls[0][0]),
      String(blob.put.mock.calls[1][0]),
    ]);
    log.mockRestore();
  });

  it("visibly refuses a filled non-semantic trap without writing", async () => {
    const response = await POST(request({
      email: "curator@example.com",
      faxExtension: "filled-by-extension",
    }));
    expect(response.status).toBe(400);
    expect(blob.put).not.toHaveBeenCalled();
  });
});
