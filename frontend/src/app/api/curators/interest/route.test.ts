import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";

const blob = vi.hoisted(() => ({del: vi.fn(), put: vi.fn()}));

vi.mock("@vercel/blob", () => ({
  put: blob.put,
  del: blob.del,
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
});

afterEach(() => {
  vi.useRealTimers();
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

  it("claims one source sub-window before storing a valid registration", async () => {
    const response = await POST(request({email: "curator@example.com", chain: "solana"}));
    expect(response.status).toBe(200);
    expect(blob.put).toHaveBeenCalledTimes(2);
    const paths = blob.put.mock.calls.map(([pathname]) => String(pathname));
    expect(paths[0]).toMatch(/^curators-rate\/source\/[0-9a-f]{64}\/\d+\.json$/);
    expect(paths[1]).toMatch(/^curators\/[0-9a-f]{64}\//);
    expect(paths.join("\n")).not.toContain("curator@example.com");
    expect(blob.put.mock.calls[0][2]).toEqual(expect.objectContaining({
      addRandomSuffix: false,
      allowOverwrite: false,
    }));
  });

  it("returns 429 after one constant-cost write when the current source sub-window is occupied", async () => {
    blob.put.mockRejectedValue(Object.assign(new Error("already exists"), {
      name: "BlobPreconditionFailedError",
    }));
    const response = await POST(request({email: "curator@example.com"}));
    expect(response.status).toBe(429);
    expect(Number(response.headers.get("retry-after"))).toBeGreaterThan(0);
    expect(Number(response.headers.get("retry-after"))).toBeLessThanOrEqual(38);
    expect(blob.put).toHaveBeenCalledTimes(1);
  });

  it("stores a corrected resubmission in a later sub-window instead of treating the email as a duplicate", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-09-20T12:00:00.000Z"));
    const claimedGates = new Set<string>();
    blob.put.mockImplementation(async (pathname: string) => {
      if (pathname.startsWith("curators-rate/")) {
        if (claimedGates.has(pathname)) {
          throw Object.assign(new Error("already exists"), {name: "BlobPreconditionFailedError"});
        }
        claimedGates.add(pathname);
      }
      return {url: "https://blob.invalid/test"};
    });
    const first = await POST(request({email: "curator@example.com", note: "old"}));
    expect(first.status).toBe(200);
    vi.advanceTimersByTime(38_000);
    const corrected = await POST(request({email: "curator@example.com", note: "corrected"}));
    expect(corrected.status).toBe(200);
    const records = blob.put.mock.calls.filter(([pathname]) => String(pathname).startsWith("curators/"));
    expect(records).toHaveLength(2);
    expect(String(records[1][1])).toContain('"note":"corrected"');
  });

  it("has no shared email gate that can delete a concurrent request's admission", async () => {
    const claimedGates = new Set<string>();
    blob.put.mockImplementation(async (pathname: string) => {
      if (pathname.startsWith("curators-rate/")) {
        if (claimedGates.has(pathname)) {
          throw Object.assign(new Error("already exists"), {name: "BlobPreconditionFailedError"});
        }
        claimedGates.add(pathname);
      }
      return {url: "https://blob.invalid/test"};
    });
    const first = await POST(request({email: "curator@example.com"}, {"x-vercel-forwarded-for": "192.0.2.10"}));
    const second = await POST(request({email: "curator@example.com"}, {"x-vercel-forwarded-for": "192.0.2.11"}));
    expect([first.status, second.status]).toEqual([200, 200]);
    expect(blob.put.mock.calls.filter(([pathname]) => String(pathname).startsWith("curators/"))).toHaveLength(2);
    expect(blob.del).not.toHaveBeenCalled();
  });

  it("releases only its own source gate when the durable record write fails", async () => {
    blob.put
      .mockResolvedValueOnce({url: "https://blob.invalid/source"})
      .mockRejectedValueOnce(Object.assign(new Error("socket failed"), {
        name: "BlobUnknownError",
      }));
    const log = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const response = await POST(request({email: "curator@example.com"}));
    expect(response.status).toBe(502);
    expect(blob.del).toHaveBeenCalledWith([String(blob.put.mock.calls[0][0])]);
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
