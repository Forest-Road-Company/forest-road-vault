// @vitest-environment node
import {afterEach, describe, expect, it, vi} from "vitest";

// The default (mainnet) path, with placeholder protocol addresses: the Forest Road list is read
// before any RPC is configured, so these tests never reach a network.
const fake = vi.hoisted(() => (n: number) => `0x${n.toString(16).padStart(40, "0")}`);
vi.mock("@/config/contracts", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/config/contracts")>()),
  IS_MAINNET: true,
  CONTRACTS: {USDfr: fake(1), sUSDfr: fake(2), PointsModule: fake(3), CuratorModule: fake(4), ComplianceRegistry: fake(5)},
}));

import {
  FOREST_ROAD_WALLETS_ENV,
  forestRoadWallets,
  LeaderboardIntegrityError,
  loadPointsLeaderboard,
} from "./pointsLeaderboard.server";

/** Valid checksummed placeholders, none of them a Forest Road wallet. */
const A = "0x52908400098527886E0F7030069857D2E4169EE7";
const B = "0x8617E340B3D01FA5F11F306F4090FD50E238070D";
const B_LOWER = B.toLowerCase();

const read = (value: string | undefined) => () => forestRoadWallets({[FOREST_ROAD_WALLETS_ENV]: value});

describe("forestRoadWallets (server-only setting)", () => {
  it("reads checksummed and lowercase entries, trimmed, as checksummed addresses", () => {
    expect(read(` ${A} ,${B_LOWER}`)()).toEqual([A, B]);
  });

  it.each([
    ["unset", undefined],
    ["empty", ""],
    ["blank", "   "],
  ])("fails closed when the setting is %s", (_, value) => {
    expect(read(value)).toThrow(LeaderboardIntegrityError);
    expect(read(value)).toThrow(`leaderboard: ${FOREST_ROAD_WALLETS_ENV} is not set`);
  });

  it.each([
    ["a malformed entry", `${A},0x1234`, 2],
    ["an empty entry (a trailing comma)", `${A},`, 2],
    ["a wrong checksum", `${A},${B.replace("E340", "e340")}`, 2],
    ["text that is no address", "forest road", 1],
  ])("fails closed on %s, naming its position and never its value", (_, value, position) => {
    expect(read(value)).toThrow(`leaderboard: ${FOREST_ROAD_WALLETS_ENV} entry ${position} is not an address`);
    try {
      read(value)();
    } catch (error) {
      expect((error as Error).message).not.toContain("0x1234");
      expect((error as Error).message).not.toContain("forest road");
    }
  });

  it("fails closed when a wallet is listed twice, whatever its case", () => {
    expect(read(`${A},${B},${B_LOWER}`)).toThrow(`leaderboard: ${FOREST_ROAD_WALLETS_ENV} entry 3 is listed twice`);
  });
});

describe("the mainnet board without the setting", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("refuses to build, rather than rank Forest Road's wallets as participants", async () => {
    vi.stubEnv(FOREST_ROAD_WALLETS_ENV, "");
    await expect(loadPointsLeaderboard()).rejects.toBeInstanceOf(LeaderboardIntegrityError);
    await expect(loadPointsLeaderboard()).rejects.toThrow(`${FOREST_ROAD_WALLETS_ENV} is not set`);
  });

  it("with the setting, reads the list before any RPC is configured", async () => {
    vi.stubEnv(FOREST_ROAD_WALLETS_ENV, `${A},${B}`);
    vi.stubEnv("ETHEREUM_ARCHIVE_RPC_URL", "");
    // Past the list, the next step is the archive RPC, which a mainnet build requires.
    await expect(loadPointsLeaderboard()).rejects.toThrow("ETHEREUM_ARCHIVE_RPC_URL is required on mainnet");
  });
});
