import {beforeEach, describe, expect, it, vi} from "vitest";

const hoisted = vi.hoisted(() => ({serveTransparencyHistory: vi.fn()}));
vi.mock("@/lib/transparencyHistory.server", () => ({
  serveTransparencyHistory: hoisted.serveTransparencyHistory,
}));

import {GET, POST, maxDuration} from "./route";

const SAMPLE_ANSWER = {
  ok: true,
  asOfBlock: "26006832",
  revenue: {originationFees: "0", interestFees: "0", performanceFees: "0", managementFees: "0"},
  seniorIncome: "0",
  credit: {fundedPrincipal: "0", netLoss: "0", rateBps: null, byClass: []},
};

describe("/api/transparency/history", () => {
  beforeEach(() => {
    hoisted.serveTransparencyHistory.mockReset();
  });

  it("configures maxDuration, rejects query strings with 400 no-store, and rejects POST with 405", async () => {
    expect(maxDuration).toBe(60);

    const bad = await GET(new Request("https://forestroadvault.com/api/transparency/history?a=1"));
    expect(bad.status).toBe(400);
    expect(bad.headers.get("cache-control")).toBe("no-store");
    expect(hoisted.serveTransparencyHistory).not.toHaveBeenCalled();

    const post = await POST();
    expect(post.status).toBe(405);
    expect(post.headers.get("cache-control")).toBe("no-store");
  });

  it("returns split browser and CDN cache headers on fresh success, logs and short-caches stale answers, and returns 502 no-store on failure", async () => {
    hoisted.serveTransparencyHistory.mockResolvedValueOnce({
      answer: SAMPLE_ANSWER,
      stale: false,
    });
    const ok = await GET(new Request("https://forestroadvault.com/api/transparency/history"));
    expect(ok.status).toBe(200);
    expect(ok.headers.get("cache-control")).toBe("public, max-age=0, must-revalidate");
    expect(ok.headers.get("cdn-cache-control")).toBe(
      "public, s-maxage=60, stale-while-revalidate=300, stale-if-error=600",
    );
    expect(ok.headers.get("vercel-cdn-cache-control")).toBe(
      "public, s-maxage=60, stale-while-revalidate=300, stale-if-error=600",
    );

    const spy = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      hoisted.serveTransparencyHistory.mockResolvedValueOnce({
        answer: SAMPLE_ANSWER,
        stale: true,
        error: new Error("upstream failed"),
      });
      const stale = await GET(new Request("https://forestroadvault.com/api/transparency/history"));
      expect(stale.status).toBe(200);
      expect(stale.headers.get("cache-control")).toBe("public, max-age=0, must-revalidate");
      expect(stale.headers.get("cdn-cache-control")).toBe("public, s-maxage=60");
      expect(stale.headers.get("vercel-cdn-cache-control")).toBe("public, s-maxage=60");
      expect(spy).toHaveBeenCalledWith(expect.stringContaining("transparency.history failed, serving last whole answer: Error"));

      hoisted.serveTransparencyHistory.mockRejectedValueOnce(new Error("upstream failed"));
      const err = await GET(new Request("https://forestroadvault.com/api/transparency/history"));
      expect(err.status).toBe(502);
      expect(err.headers.get("cache-control")).toBe("no-store");
    } finally {
      spy.mockRestore();
    }
  });
});
