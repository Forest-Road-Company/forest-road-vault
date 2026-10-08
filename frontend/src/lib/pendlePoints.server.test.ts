import {afterEach, describe, expect, it, vi} from "vitest";

const chain = vi.hoisted(() => ({mainnet: true}));
vi.mock("@/config/contracts", () => ({
  get IS_MAINNET() {
    return chain.mainnet;
  },
}));

import {loadPendlePoints, parsePendlePoints, PENDLE_POINTS_URL, PendlePointsUnavailableError} from "./pendlePoints.server";

const WALLET = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed" as const;
const E18 = 10n ** 18n;

function answer(overrides: Record<string, unknown> = {}) {
  return {
    ok: true,
    enabled: true,
    wallet: WALLET.toLowerCase(),
    asOfBlock: "26148102",
    asOfTimestamp: 1_791_500_000,
    excluded: null,
    points: String(150n * E18),
    pointsPerDay: String(12n * E18),
    markets: [
      {key: "susdfr-2027jan", label: "sUSDfr 28 Jan 2027", yt: String(100n * E18), sy: "0", lp: String(40n * E18), points: String(140n * E18), pointsPerDay: String(10n * E18)},
      {key: "usdfr-2027jan", label: "USDfr 28 Jan 2027", yt: "0", sy: "0", lp: String(10n * E18), points: String(10n * E18), pointsPerDay: String(2n * E18)},
    ],
    ...overrides,
  };
}

const respond = (body: unknown, status = 200) =>
  vi.fn(async () => new Response(JSON.stringify(body), {status, headers: {"content-type": "application/json"}}));

afterEach(() => {
  chain.mainnet = true;
  vi.restoreAllMocks();
});

describe("parsePendlePoints", () => {
  it("accepts the points site's answer as it is", () => {
    const parsed = parsePendlePoints(answer(), WALLET);
    expect(parsed).toEqual({...answer(), wallet: undefined, ok: true} as never);
  });

  it("passes a disabled answer through", () => {
    expect(parsePendlePoints({ok: true, enabled: false}, WALLET)).toEqual({ok: true, enabled: false});
  });

  it.each([
    ["a failure", {ok: false}],
    ["another wallet's answer", answer({wallet: "0x0000000000000000000000000000000000000001"})],
    ["a block that is not a number", answer({asOfBlock: "latest"})],
    ["a fractional time", answer({asOfTimestamp: 1.5})],
    ["an unknown status", answer({excluded: "sanctioned"})],
    ["a negative point amount", answer({points: "-1"})],
    ["a decimal point amount", answer({points: "1.5"})],
    ["a point amount past uint256", answer({points: "1".repeat(79)})],
    ["markets that are not a list", answer({markets: {}})],
    ["too many markets", answer({markets: Array.from({length: 9}, () => answer().markets[0])})],
    ["a market with markup in its label", answer({markets: [{...answer().markets[0], label: "<img src=x>"}]})],
    ["markets that do not add up to the total", answer({points: String(500n * E18)})],
    ["a market whose parts do not add up", answer({markets: [{...answer().markets[0], yt: String(900n * E18)}, answer().markets[1]]})],
    ["points shown for an excluded wallet", answer({excluded: "jurisdiction-blocked"})],
  ])("refuses %s", (_, body) => {
    expect(() => parsePendlePoints(body, WALLET)).toThrow(PendlePointsUnavailableError);
  });

  it("accepts an excluded wallet at zero", () => {
    const zero = answer({excluded: "protocol-exempt", points: "0", pointsPerDay: "0", markets: []});
    expect(parsePendlePoints(zero, WALLET)).toMatchObject({enabled: true, excluded: "protocol-exempt", points: "0"});
  });
});

describe("loadPendlePoints", () => {
  it("asks the points site for the lowercase wallet and returns its validated answer", async () => {
    const fetcher = respond(answer());
    const result = await loadPendlePoints(WALLET, fetcher as unknown as typeof fetch);
    expect(fetcher).toHaveBeenCalledWith(`${PENDLE_POINTS_URL}?wallet=${WALLET.toLowerCase()}`, expect.objectContaining({cache: "no-store"}));
    expect(result).toMatchObject({enabled: true, points: String(150n * E18), asOfBlock: "26148102"});
  });

  it("answers disabled on a testnet build without a request", async () => {
    chain.mainnet = false;
    const fetcher = respond(answer());
    expect(await loadPendlePoints(WALLET, fetcher as unknown as typeof fetch)).toEqual({ok: true, enabled: false});
    expect(fetcher).not.toHaveBeenCalled();
  });

  it.each([
    ["an error status", respond({ok: false, error: "not_ready"}, 503)],
    ["a body that is not JSON", vi.fn(async () => new Response("<html>", {status: 200}))],
    ["no answer at all", vi.fn(async () => { throw new TypeError("fetch failed: https://points.example/secret"); })],
  ])("is unavailable on %s, with a message that names no upstream detail", async (_, fetcher) => {
    const error = await loadPendlePoints(WALLET, fetcher as unknown as typeof fetch).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(PendlePointsUnavailableError);
    expect(String((error as Error).message)).not.toContain("secret");
  });
});
