import {afterEach, describe, expect, it, vi} from "vitest";

// From the 11 October 2026 reviews of the leaderboard: the refusals of parsePendleLeaderboard and
// loadPendleLeaderboard that pendlePoints.server.test.ts does not pin (each kills a mutant that
// survives that file), and the dust row the points site can serve.

const chain = vi.hoisted(() => ({mainnet: true}));
vi.mock("@/config/contracts", () => ({
  get IS_MAINNET() {
    return chain.mainnet;
  },
}));

import {
  loadPendleLeaderboard,
  parsePendleLeaderboard,
  PENDLE_LEADERBOARD_MAX_WALLETS,
  PENDLE_LEADERBOARD_URL,
  PendlePointsUnavailableError,
} from "./pendlePoints.server";

const E18 = 10n ** 18n;
const A = "0x000000000000000000000000000000000000000a";
const PRODUCTION_URL = "https://points.forestroadvault.com/api/pendle-points/all";

function board(overrides: Record<string, unknown> = {}) {
  return {
    ok: true,
    enabled: true,
    asOfBlock: "26170000",
    asOfTimestamp: 1_791_700_000,
    wallets: [{wallet: A, points: String(500n * E18)}],
    ...overrides,
  };
}

const respond = (body: unknown, status = 200) =>
  vi.fn(async (_input: RequestInfo | URL, _init?: RequestInit) =>
    new Response(JSON.stringify(body), {status, headers: {"content-type": "application/json"}}),
  );

afterEach(() => {
  chain.mainnet = true;
  vi.restoreAllMocks();
});

describe("parsePendleLeaderboard: the remaining refusals", () => {
  it.each([
    ["no body at all", null],
    ["a failure flag on an otherwise complete answer", board({ok: false})],
    ["a failure flag on a disabled answer", {ok: false, enabled: false}],
    ["block zero", board({asOfBlock: "0"})],
    ["a block number past twenty digits", board({asOfBlock: "1".repeat(21)})],
    ["a block with a leading zero", board({asOfBlock: "026170000"})],
    ["a time of zero", board({asOfTimestamp: 0})],
    ["a negative time", board({asOfTimestamp: -1})],
    ["a time given as text", board({asOfTimestamp: "1791700000"})],
    ["a wallet entry that is not an object", board({wallets: [null]})],
    ["points given as a number", board({wallets: [{wallet: A, points: 5}]})],
  ])("refuses %s", (_, body) => {
    expect(() => parsePendleLeaderboard(body)).toThrow(PendlePointsUnavailableError);
  });

  it("accepts exactly as many wallets as the bound", () => {
    const wallets = Array.from({length: PENDLE_LEADERBOARD_MAX_WALLETS}, (_, i) => ({
      wallet: `0x${(i + 1).toString(16).padStart(40, "0")}`,
      points: "1",
    }));
    const parsed = parsePendleLeaderboard(board({wallets}));
    expect(parsed.enabled && parsed.points.size).toBe(PENDLE_LEADERBOARD_MAX_WALLETS);
  });

  it("keeps the bound the points site enforces (forestvault-whitelist PENDLE_LEADERBOARD_MAX_WALLETS)", () => {
    expect(PENDLE_LEADERBOARD_MAX_WALLETS).toBe(5_000);
  });
});

describe("loadPendleLeaderboard: the endpoint and status", () => {
  it("asks exactly the production endpoint, with no query string (the points site refuses one)", async () => {
    expect(PENDLE_LEADERBOARD_URL).toBe(PRODUCTION_URL);
    const fetcher = respond(board());
    await loadPendleLeaderboard(fetcher as unknown as typeof fetch);
    expect(fetcher).toHaveBeenCalledWith(PRODUCTION_URL, expect.anything());
  });

  it("is unavailable on an error status even when the body is a complete answer", async () => {
    const error = await loadPendleLeaderboard(respond(board(), 503) as unknown as typeof fetch).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(PendlePointsUnavailableError);
    expect(String((error as Error).message)).toContain("503");
  });
});

describe("parsePendleLeaderboard: a dust row", () => {
  it("skips a wallet the points site rounds to \"0\" instead of refusing the whole answer", () => {
    const B = "0x000000000000000000000000000000000000000b";
    const parsed = parsePendleLeaderboard(board({wallets: [{wallet: A, points: String(5n * E18)}, {wallet: B, points: "0"}]}));
    expect(parsed.enabled && [...parsed.points]).toEqual([[A, 5n * E18]]);
  });

  it("still refuses a wallet listed twice when one of the rows is dust", () => {
    expect(() => parsePendleLeaderboard(board({wallets: [{wallet: A, points: "0"}, {wallet: A, points: "2"}]}))).toThrow(
      PendlePointsUnavailableError,
    );
  });
});
