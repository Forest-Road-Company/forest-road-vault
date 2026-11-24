import {beforeEach, describe, expect, it, vi} from "vitest";

const hoisted = vi.hoisted(() => ({loadTransparencyHistory: vi.fn()}));
vi.mock("@/lib/transparencyHistory.server", () => ({
  loadTransparencyHistory: hoisted.loadTransparencyHistory,
}));

import {GET, POST, maxDuration} from "./route";

describe("/api/transparency/history", () => {
  beforeEach(() => {
    hoisted.loadTransparencyHistory.mockReset();
  });

  it("configures maxDuration, rejects query strings with 400 no-store, and rejects POST with 405", async () => {
    expect(maxDuration).toBe(60);

    const bad = await GET(new Request("https://forestroadvault.com/api/transparency/history?a=1"));
    expect(bad.status).toBe(400);
    expect(bad.headers.get("cache-control")).toBe("no-store");
    expect(hoisted.loadTransparencyHistory).not.toHaveBeenCalled();

    const post = await POST();
    expect(post.status).toBe(405);
    expect(post.headers.get("cache-control")).toBe("no-store");
  });

  it("returns cache headers with stale-if-error on success and 502 no-store on failure", async () => {
    hoisted.loadTransparencyHistory.mockResolvedValueOnce({
      ok: true,
      asOfBlock: "26006832",
      revenue: {originationFees: "0", interestFees: "0", performanceFees: "0", managementFees: "0"},
      seniorIncome: "0",
      credit: {fundedPrincipal: "0", netLoss: "0", rateBps: null, byClass: []},
    });
    const ok = await GET(new Request("https://forestroadvault.com/api/transparency/history"));
    expect(ok.status).toBe(200);
    expect(ok.headers.get("cache-control")).toContain("stale-if-error=600");

    hoisted.loadTransparencyHistory.mockRejectedValueOnce(new Error("upstream failed"));
    const spy = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      const err = await GET(new Request("https://forestroadvault.com/api/transparency/history"));
      expect(err.status).toBe(502);
      expect(err.headers.get("cache-control")).toBe("no-store");
    } finally {
      spy.mockRestore();
    }
  });
});
