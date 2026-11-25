import {describe, expect, it, vi} from "vitest";
import {createArchiveFetch, isLogSizeLimitError, isRateLimitError} from "./archiveTransport.server";

describe("archiveTransport.server", () => {
  it("excludes HTTP 429 and -32005 rate-limit errors from log-size splitting", () => {
    // Viem's generic LimitExceededRpcError for -32005 rate limits
    const viemRateLimit = {
      code: -32005,
      shortMessage: "Request exceeds defined limit.",
      details: "Too Many Requests",
    };
    expect(isRateLimitError(viemRateLimit)).toBe(true);
    expect(isLogSizeLimitError(viemRateLimit)).toBe(false);

    // Alchemy CUPS capacity 429
    const alchemy429 = {
      status: 429,
      code: 429,
      shortMessage: "HTTP request failed.",
      details: "Your app has exceeded its compute units per second capacity.",
    };
    expect(isRateLimitError(alchemy429)).toBe(true);
    expect(isLogSizeLimitError(alchemy429)).toBe(false);

    // Generic -32005 with only viem's boilerplate shortMessage (no size details)
    expect(isLogSizeLimitError({code: -32005, shortMessage: "Request exceeds defined limit."})).toBe(false);

    // Genuine oversized eth_getLogs refusals still trigger range splitting
    expect(isLogSizeLimitError({cause: {code: -32008, shortMessage: "Response is too big"}})).toBe(true);
    expect(isLogSizeLimitError({code: -32005, shortMessage: "query returned more than 10000 results"})).toBe(true);
    expect(isLogSizeLimitError({code: -32602, details: "Log response size exceeded"})).toBe(true);
    expect(isLogSizeLimitError({code: -32602, shortMessage: "invalid argument 0: hex string"})).toBe(false);
  });

  it("retries HTTP 429 with Retry-After or jittered >1s CUPS backoff and stops cleanly on 200", async () => {
    const delays: number[] = [];
    const baseFetch = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(new Response("rate limited", {status: 429, headers: {"retry-after": "2"}}))
      .mockResolvedValueOnce(new Response("rate limited", {status: 429}))
      .mockResolvedValueOnce(new Response(JSON.stringify({jsonrpc: "2.0", id: 1, result: "0x1"}), {status: 200}));

    const archiveFetch = createArchiveFetch(baseFetch, {
      sleep: async (ms) => {
        delays.push(ms);
      },
      random: () => 0.5,
    });

    const response = await archiveFetch("https://archive.invalid", {method: "POST", body: "{}"});
    expect(response.status).toBe(200);
    expect(baseFetch).toHaveBeenCalledTimes(3);
    expect(delays).toEqual([2_000, 1_575]);
    // Enforces redirect: "error" and cache: "no-store" even when caller omits them.
    expect(baseFetch.mock.calls[0]?.[1]).toMatchObject({redirect: "error", cache: "no-store"});
  });

  it("caps cumulative rate-limit backoff and overrides caller redirect/cache options", async () => {
    const delays: number[] = [];
    const baseFetch = vi
      .fn<typeof fetch>()
      .mockResolvedValue(new Response("rate limited", {status: 429, headers: {"retry-after": "5"}}));

    const archiveFetch = createArchiveFetch(baseFetch, {
      sleep: async (ms) => {
        delays.push(ms);
      },
      random: () => 0,
    });

    const response = await archiveFetch("https://archive.invalid", {
      method: "POST",
      body: "{}",
      redirect: "follow",
      cache: "force-cache",
    });
    expect(response.status).toBe(429);
    // Retry-After: 5 is clamped to MAX_RETRY_DELAY_MS (4_000ms); two 4_000ms sleeps fit under 9_500ms,
    // and the third would exceed the cumulative cap so the loop exits after 3 total fetches.
    expect(delays).toEqual([4_000, 4_000]);
    expect(baseFetch).toHaveBeenCalledTimes(3);
    expect(baseFetch.mock.calls[0]?.[1]).toMatchObject({redirect: "error", cache: "no-store"});
  });
});
