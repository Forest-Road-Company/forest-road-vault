import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";

const serve = vi.hoisted(() => vi.fn());

vi.mock("@/lib/pointsLeaderboard.server", () => {
  class LeaderboardIntegrityError extends Error {
    override name = "LeaderboardIntegrityError";
  }
  class LeaderboardNotReadyError extends Error {
    override name = "LeaderboardNotReadyError";
  }
  return {servePointsLeaderboard: serve, LeaderboardIntegrityError, LeaderboardNotReadyError};
});
vi.mock("@/lib/morphoPoints.server", () => {
  class MorphoPointsIntegrityError extends Error {
    override name = "MorphoPointsIntegrityError";
  }
  class MorphoPointsNotReadyError extends Error {
    override name = "MorphoPointsNotReadyError";
  }
  return {MorphoPointsIntegrityError, MorphoPointsNotReadyError};
});
vi.mock("@/lib/pendlePoints.server", () => {
  class PendlePointsUnavailableError extends Error {
    override name = "PendlePointsUnavailableError";
  }
  return {PendlePointsUnavailableError};
});

import {GET, maxDuration} from "./route";
import {LeaderboardIntegrityError, LeaderboardNotReadyError} from "@/lib/pointsLeaderboard.server";
import {MorphoPointsNotReadyError} from "@/lib/morphoPoints.server";
import {PendlePointsUnavailableError} from "@/lib/pendlePoints.server";

const call = (query = "") => GET(new Request(`https://forestroadvault.com/api/points/leaderboard${query}`));

let logged: string[] = [];
beforeEach(() => {
  serve.mockReset();
  logged = [];
  vi.spyOn(console, "error").mockImplementation((...args: unknown[]) => {
    logged.push(args.map(String).join(" "));
  });
});
afterEach(() => vi.restoreAllMocks());

describe("GET /api/points/leaderboard", () => {
  it.each([
    ["a parameter that would make another CDN key", "?wallet=0x000000000000000000000000000000000000a11c"],
    ["a bare cache-buster", "?x"],
  ])("refuses %s with 400 and no-store", async (_, query) => {
    const response = await call(query);
    expect(response.status).toBe(400);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(serve).not.toHaveBeenCalled();
  });

  it("serves the board with a five-minute CDN cache, measuring the budget from the request's arrival", async () => {
    expect(maxDuration).toBe(120);
    serve.mockResolvedValue({answer: {ok: true, enabled: false}, stale: false});
    const before = Date.now();
    const response = await call();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ok: true, enabled: false});
    expect(response.headers.get("cache-control")).toBe("public, s-maxage=300, stale-while-revalidate=600");
    const arrivedAt = serve.mock.calls[0]?.[0] as number;
    expect(arrivedAt).toBeGreaterThanOrEqual(before);
    expect(arrivedAt).toBeLessThanOrEqual(Date.now());
    expect(logged).toEqual([]);
  });

  it("serves the last whole answer briefly while the loader fails, and still logs the failure", async () => {
    const answer = {ok: true, enabled: true, asOfBlock: "26170379"};
    serve.mockResolvedValue({
      answer,
      stale: true,
      error: new LeaderboardIntegrityError("leaderboard: the discovered wallets do not account for the PointsModule's totals"),
    });
    const response = await call();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(answer);
    expect(response.headers.get("cache-control")).toBe("public, s-maxage=60");
    expect(logged.join("\n")).toContain("serving the last whole answer: LeaderboardIntegrityError: leaderboard: the discovered wallets");
  });

  it.each([
    ["the leaderboard is still indexing", new LeaderboardNotReadyError("leaderboard: still indexing participants")],
    ["the Morpho snapshot is catching up", new MorphoPointsNotReadyError("points: rebuilding history after an integrity failure")],
  ])("answers 503, uncached, while %s", async (_, error) => {
    serve.mockRejectedValue(error);
    const response = await call();
    expect(response.status).toBe(503);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(((await response.json()) as {error: string}).error).toMatch(/catching up/);
  });

  it.each([
    ["an integrity failure", new LeaderboardIntegrityError("leaderboard: the discovered wallets do not account for the PointsModule's totals"), /do not account/],
    ["the points site being down", new PendlePointsUnavailableError("pendle points: the points site did not answer"), /did not answer/],
  ])("answers 502, uncached, on %s, and logs the loader's own static message", async (_, error, message) => {
    serve.mockRejectedValue(error);
    const response = await call();
    expect(response.status).toBe(502);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(logged.join("\n")).toMatch(message);
  });

  it("never returns or logs an RPC error message, which can carry the endpoint URL", async () => {
    serve.mockRejectedValue(new Error("request failed: https://eth-mainnet.example/v2/SECRET-KEY"));
    const response = await call();
    expect(response.status).toBe(502);
    expect(await response.text()).not.toContain("SECRET");
    expect(logged.join("\n")).not.toContain("SECRET");
    expect(logged.join("\n")).toContain("points.leaderboard failed: Error");
  });
});
