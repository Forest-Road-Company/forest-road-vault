import {getAddress} from "viem";
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";

const load = vi.hoisted(() => vi.fn());

vi.mock("@/lib/morphoPoints.server", () => {
  class MorphoPointsIntegrityError extends Error {
    override name = "MorphoPointsIntegrityError";
  }
  class MorphoPointsNotReadyError extends Error {
    override name = "MorphoPointsNotReadyError";
  }
  return {loadMorphoCollateralPoints: load, MorphoPointsIntegrityError, MorphoPointsNotReadyError};
});

import {GET, maxDuration} from "./route";
import {MorphoPointsIntegrityError} from "@/lib/morphoPoints.server";

const WALLET = "0x000000000000000000000000000000000000a11c";
/** The EIP-55 test vector: its canonical spelling mixes case, so other spellings are distinct URLs. */
const MIXED = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed";
const call = (query: string) => GET(new Request(`https://forestroadvault.com/api/points/morpho${query}`));

let logged: string[] = [];
beforeEach(() => {
  load.mockReset();
  logged = [];
  vi.spyOn(console, "error").mockImplementation((...args: unknown[]) => {
    logged.push(args.map(String).join(" "));
  });
});
afterEach(() => vi.restoreAllMocks());

describe("GET /api/points/morpho", () => {
  it.each([
    ["no wallet", ""],
    ["a malformed wallet", "?wallet=nope"],
    ["an unknown parameter that would bypass the CDN", `?wallet=${WALLET}&cache=1`],
    ["two wallets", `?wallet=${WALLET}&wallet=${WALLET}`],
    ["a mixed-case wallet whose EIP-55 checksum is wrong (MORPHO-17)", "?wallet=0x5AaEB6053f3e94c9B9a09F33669435e7eF1bEaED"],
  ])("refuses %s with 400 and no-store", async (_, query) => {
    const response = await call(query);
    expect(response.status).toBe(400);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(load).not.toHaveBeenCalled();
  });

  it("serves a checksummed wallet with a short CDN cache", async () => {
    load.mockResolvedValue({ok: true, enabled: false});
    const response = await call(`?wallet=${WALLET}`);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ok: true, enabled: false});
    expect(response.headers.get("cache-control")).toContain("s-maxage=60");
    expect(load).toHaveBeenCalledWith(getAddress(WALLET), undefined, expect.any(Number));
    load.mockClear();
    expect((await call(`?wallet=${MIXED}`)).status).toBe(200);
    expect(load).toHaveBeenCalledWith(MIXED, undefined, expect.any(Number));
  });

  it("bounds the whole request, and measures the loader's budget from the request's arrival (MORPHO-71)", async () => {
    // The budget, two never-split collateral chunks and a few single reads (M1001-m4-07).
    expect(maxDuration).toBe(120);
    load.mockResolvedValue({ok: true, enabled: false});
    const before = Date.now();
    await call(`?wallet=${WALLET}`);
    const arrivedAt = load.mock.calls[0]?.[2] as number;
    expect(arrivedAt).toBeGreaterThanOrEqual(before);
    expect(arrivedAt).toBeLessThanOrEqual(Date.now());
  });

  // The handler's own comparison, called directly. Through Next.js only the lowercase spelling still
  // arrives un-normalized: Next decodes percent-encoding and drops separators first, so those two
  // spellings are answered with a 200 there (M1001B-n3-01); points-route-server-test.mts pins that
  // on the built server. These cases keep the handler right if Next ever stops normalizing.
  it.each([
    ["the all-lowercase spelling", `?wallet=${MIXED.toLowerCase()}`],
    ["a percent-encoded spelling", `?wallet=%30x${MIXED.slice(2)}`],
    ["a trailing separator", `?wallet=${MIXED}&`],
  ])("sends %s to the one canonical URL with a cacheable 308 (MORPHO-17)", async (_, query) => {
    const response = await call(query);
    expect(response.status).toBe(308);
    expect(response.headers.get("location")).toBe(`https://forestroadvault.com/api/points/morpho?wallet=${MIXED}`);
    expect(response.headers.get("cache-control")).toContain("s-maxage=86400");
    expect(load).not.toHaveBeenCalled();
  });

  it("never returns or logs an RPC error message, which can carry the endpoint URL", async () => {
    load.mockRejectedValue(new Error("request failed: https://eth-mainnet.example/v2/SECRET-KEY"));
    const response = await call(`?wallet=${WALLET}`);
    expect(response.status).toBe(502);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = await response.text();
    expect(body).not.toContain("SECRET");
    expect(logged.join("\n")).not.toContain("SECRET");
    expect(logged.join("\n")).toContain("points.morpho failed: Error");
  });

  it("logs the loader's own static integrity message", async () => {
    load.mockRejectedValue(new MorphoPointsIntegrityError("points: replayed collateral disagrees with Morpho Blue"));
    const response = await call(`?wallet=${WALLET}`);
    expect(response.status).toBe(502);
    expect(logged.join("\n")).toContain("disagrees with Morpho Blue");
  });
});
