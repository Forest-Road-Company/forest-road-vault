import {getAddress} from "viem";
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";

const load = vi.hoisted(() => vi.fn());

vi.mock("@/lib/pendlePoints.server", () => {
  class PendlePointsUnavailableError extends Error {
    override name = "PendlePointsUnavailableError";
  }
  return {loadPendlePoints: load, PendlePointsUnavailableError};
});

import {GET, maxDuration} from "./route";
import {PendlePointsUnavailableError} from "@/lib/pendlePoints.server";

const WALLET = "0x000000000000000000000000000000000000a11c";
/** The EIP-55 test vector: its canonical spelling mixes case, so other spellings are distinct URLs. */
const MIXED = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed";
const call = (query: string) => GET(new Request(`https://forestroadvault.com/api/points/pendle${query}`));

let logged: string[] = [];
beforeEach(() => {
  load.mockReset();
  logged = [];
  vi.spyOn(console, "error").mockImplementation((...args: unknown[]) => {
    logged.push(args.map(String).join(" "));
  });
});
afterEach(() => vi.restoreAllMocks());

describe("GET /api/points/pendle", () => {
  it.each([
    ["no wallet", ""],
    ["a malformed wallet", "?wallet=nope"],
    ["an unknown parameter that would bypass the CDN", `?wallet=${WALLET}&cache=1`],
    ["two wallets", `?wallet=${WALLET}&wallet=${WALLET}`],
    ["a mixed-case wallet whose EIP-55 checksum is wrong", "?wallet=0x5AaEB6053f3e94c9B9a09F33669435e7eF1bEaED"],
  ])("refuses %s with 400 and no-store", async (_, query) => {
    const response = await call(query);
    expect(response.status).toBe(400);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(load).not.toHaveBeenCalled();
  });

  it("serves a checksummed wallet with a short CDN cache, within a short time limit", async () => {
    expect(maxDuration).toBe(15);
    load.mockResolvedValue({ok: true, enabled: false});
    const response = await call(`?wallet=${WALLET}`);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ok: true, enabled: false});
    expect(response.headers.get("cache-control")).toContain("s-maxage=60");
    expect(load).toHaveBeenCalledWith(getAddress(WALLET));
    load.mockClear();
    expect((await call(`?wallet=${MIXED}`)).status).toBe(200);
    expect(load).toHaveBeenCalledWith(MIXED);
  });

  it.each([
    ["the all-lowercase spelling", `?wallet=${MIXED.toLowerCase()}`],
    ["a percent-encoded spelling", `?wallet=%30x${MIXED.slice(2)}`],
    ["a trailing separator", `?wallet=${MIXED}&`],
  ])("sends %s to the one canonical URL with a cacheable 308", async (_, query) => {
    const response = await call(query);
    expect(response.status).toBe(308);
    expect(response.headers.get("location")).toBe(`https://forestroadvault.com/api/points/pendle?wallet=${MIXED}`);
    expect(response.headers.get("cache-control")).toContain("s-maxage=86400");
    expect(load).not.toHaveBeenCalled();
  });

  it("never returns or logs an unexpected error's message", async () => {
    load.mockRejectedValue(new Error("request failed: https://points.example/SECRET"));
    const response = await call(`?wallet=${WALLET}`);
    expect(response.status).toBe(502);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.text()).not.toContain("SECRET");
    expect(logged.join("\n")).not.toContain("SECRET");
    expect(logged.join("\n")).toContain("points.pendle failed: Error");
  });

  it("logs the loader's own static message", async () => {
    load.mockRejectedValue(new PendlePointsUnavailableError("pendle points: the markets do not add up to the total"));
    const response = await call(`?wallet=${WALLET}`);
    expect(response.status).toBe(502);
    expect(logged.join("\n")).toContain("do not add up");
  });
});
