import {afterEach, describe, expect, it, vi} from "vitest";

const hoisted = vi.hoisted(() => ({isMainnet: false}));
vi.mock("@/config/contracts", () => ({
  get IS_MAINNET() {
    return hoisted.isMainnet;
  },
}));

import {GET, POST, maxDuration} from "./route";

const WALLET = "0x1111111111111111111111111111111111111111";

function validPayload(overrides: Record<string, unknown> = {}) {
  return {
    ok: true,
    enabled: true,
    asOfBlock: "26486000",
    asOfTimestamp: "1795536000",
    rankedWallets: 1,
    rankedPoints: "100",
    totalPoints: "100",
    forestRoadPoints: "0",
    truncated: false,
    rows: [{rank: 1, wallet: WALLET, points: "100", onchain: "60", pendle: "20", morpho: "20"}],
    venues: [
      {
        key: "morpho-blue",
        label: "Morpho Blue",
        address: "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb",
        points: "0",
        note: "Pooled venue",
      },
    ],
    ...overrides,
  };
}

describe("/api/points/live-leaderboard", () => {
  afterEach(() => {
    hoisted.isMainnet = false;
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it("returns 404 on mainnet and 405 on POST", async () => {
    expect(maxDuration).toBe(15);
    hoisted.isMainnet = true;
    const fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);

    const res = await GET(new Request("https://forestroadvault.com/api/points/live-leaderboard"));
    expect(res.status).toBe(404);
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(fetchSpy).not.toHaveBeenCalled();

    const post = await POST();
    expect(post.status).toBe(405);
    expect(post.headers.get("cache-control")).toBe("no-store");
  });

  it("rejects query parameters with 400 on non-mainnet", async () => {
    const res = await GET(new Request("https://staging.test/api/points/live-leaderboard?x=1"));
    expect(res.status).toBe(400);
    expect(res.headers.get("cache-control")).toBe("no-store");
  });

  it("validates payload, strips unknown fields, and forwards stale-if-error", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(JSON.stringify({...validPayload(), unexpectedExtraField: "drop-me"}), {
          status: 200,
          headers: {"content-type": "application/json"},
        }),
      ),
    );
    const res = await GET(new Request("https://staging.test/api/points/live-leaderboard"));
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toContain("stale-if-error=600");
    const json = (await res.json()) as Record<string, unknown>;
    expect(json.unexpectedExtraField).toBeUndefined();
    expect(json.rows).toHaveLength(1);
  });

  it.each([
    ["first rank not 1", validPayload({rows: [{rank: 2, wallet: WALLET, points: "100", onchain: "100", pendle: "0", morpho: "0"}]})],
    ["truncated rankedPoints less than row sum", validPayload({truncated: true, rankedPoints: "50"})],
    ["invalid venue address", validPayload({venues: [{key: "bad", label: "Bad", address: "not-an-address", points: "0", note: ""}]})],
  ])("rejects invalid upstream payload (%s) with 502", async (_label, payload) => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify(payload), {status: 200})));
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      const res = await GET(new Request("https://staging.test/api/points/live-leaderboard"));
      expect(res.status).toBe(502);
      expect(res.headers.get("cache-control")).toBe("no-store");
    } finally {
      errSpy.mockRestore();
    }
  });
});
