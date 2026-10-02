import {readFileSync} from "node:fs";
import {resolve} from "node:path";
import {describe, expect, it} from "vitest";
import {
  MATURITY_RAMP,
  MorphoPointsIntegrityError,
  WAD,
  emptyPosition,
  pointsAt,
  rampIntegral,
  replayCollateralPoints,
  track,
  untrack,
  type CollateralEvent,
  type RateEpoch,
} from "@/lib/morphoPoints";
import {decodeCollateralLog, MORPHO_COLLATERAL_TOPICS, morphoPointsConfig} from "@/lib/morphoPoints.server";

const DAY = 86_400n;
const SHARE = 10n ** 24n;
const OWNER = "0x00000000000000000000000000000000000000b0" as const;
const OTHER = "0x00000000000000000000000000000000000000c0" as const;

type Schedule = {morphoMirrored: boolean; at: number[]; kind: number[]; value: string[]};
type Fixture = {
  t0: number;
  genesisEpochStart: number;
  genesisRate: string;
  wholeShares: Schedule;
  oddAmounts: Schedule;
};

/**
 * The schedules `contracts/test/fork/MorphoCollateralPointsParityFork.t.sol` runs on a pinned
 * mainnet fork, with the deployed PointsModule's measured points. Both suites read this one file.
 */
const FIXTURE = JSON.parse(
  readFileSync(resolve(process.cwd(), "../contracts/deployments/fixtures/morpho-collateral-points-parity.json"), "utf8"),
) as Fixture;
const T0 = BigInt(FIXTURE.t0);

/** Replays a fixture schedule as Morpho events and returns every read beside its measured value. */
function replaySchedule(schedule: Schedule): {index: number; expected: bigint; actual: bigint}[] {
  const epochs: RateEpoch[] = [{start: BigInt(FIXTURE.genesisEpochStart), ratePerUnitDay: BigInt(FIXTURE.genesisRate)}];
  const events: CollateralEvent[] = [];
  const reads: {index: number; expected: bigint; actual: bigint}[] = [];
  let rate = BigInt(FIXTURE.genesisRate);
  schedule.at.forEach((at, i) => {
    const timestamp = T0 + BigInt(at);
    const value = BigInt(schedule.value[i]);
    const event = (kind: CollateralEvent["kind"]) =>
      events.push({blockNumber: BigInt(i + 1), logIndex: 0, timestamp, kind, owner: OWNER, assets: value});
    switch (schedule.kind[i]) {
      case 0:
        event("supply");
        break;
      case 1:
        event("withdraw");
        break;
      case 2:
        event("liquidate");
        break;
      case 3:
        rate = value;
        epochs.push({start: timestamp, ratePerUnitDay: value});
        break;
      case 4:
        // A multiplier-only epoch: the share rate is unchanged, but the boundary splits the floor.
        epochs.push({start: timestamp, ratePerUnitDay: rate});
        break;
      case 5:
        reads.push({
          index: i,
          expected: value,
          actual: replayCollateralPoints(events, epochs, timestamp).get(OWNER)?.points ?? 0n,
        });
        break;
      default:
        throw new Error(`unknown fixture action ${schedule.kind[i]}`);
    }
  });
  return reads;
}

describe("Morpho collateral points: parity with the deployed PointsModule", () => {
  it("reproduces the whole-shares schedule, measured through a real Morpho market", () => {
    const reads = replaySchedule(FIXTURE.wholeShares);
    expect(reads.map((r) => r.expected)).toEqual([807_612_633_181_126_331_811_261n, 815_831_811_263_318_112_633_178n]);
    for (const read of reads) expect(read.actual).toBe(read.expected);
  });

  it("reproduces the odd-amounts schedule that exercises every floor", () => {
    const reads = replaySchedule(FIXTURE.oddAmounts);
    expect(reads).toHaveLength(3);
    for (const read of reads) {
      expect(read.expected).not.toBe(0n);
      expect(read.actual).toBe(read.expected);
    }
  });

  it("goes red if the rate change is ignored", () => {
    const withoutRate = {...FIXTURE.wholeShares, kind: FIXTURE.wholeShares.kind.map((k) => (k === 3 ? 4 : k))};
    const reads = replaySchedule(withoutRate);
    expect(reads[0].actual).not.toBe(reads[0].expected);
  });

  it("goes red if a liquidation is not replayed", () => {
    const i = FIXTURE.wholeShares.kind.indexOf(2);
    const withoutSeizure = {...FIXTURE.wholeShares, value: FIXTURE.wholeShares.value.map((v, j) => (j === i ? "0" : v))};
    // A seizure the replay never saw leaves more collateral accruing, so the reads move.
    const reads = replaySchedule(withoutSeizure);
    for (const read of reads) expect(read.actual).not.toBe(read.expected);
  });
});

describe("the PointsModule share formula", () => {
  it("integrates the 1x to 2x ramp exactly", () => {
    expect(rampIntegral(0n)).toBe(0n);
    expect(rampIntegral(MATURITY_RAMP)).toBe((3n * MATURITY_RAMP * WAD) / 2n);
    expect(rampIntegral(MATURITY_RAMP + DAY)).toBe((3n * MATURITY_RAMP * WAD) / 2n + 2n * DAY * WAD);
    expect(rampIntegral(DAY)).toBe(DAY * WAD + (DAY * DAY * WAD) / (2n * MATURITY_RAMP));
  });

  it("pays one point per whole sUSDfr per day at the start of the ramp", () => {
    const epochs = [{start: 0n, ratePerUnitDay: WAD}];
    const p = emptyPosition();
    track(p, SHARE, epochs, 1_000n);
    // One day at 1x..(1 + 1/365)x: 1 + 1/730 points, in 18-decimal fixed point.
    expect(pointsAt(p, epochs, 1_000n + DAY)).toBe(WAD + WAD / 730n);
  });

  it("blends the maturity start by amount, with the contract's floor division", () => {
    const epochs = [{start: 0n, ratePerUnitDay: WAD}];
    const p = emptyPosition();
    track(p, 3n * SHARE, epochs, 1_000n);
    track(p, SHARE, epochs, 1_003n);
    expect(p.maturityStart).toBe((3n * SHARE * 1_000n + SHARE * 1_003n) / (4n * SHARE));
  });

  it("keeps the maturity start on a partial withdrawal, and clamps an over-withdrawal", () => {
    const epochs = [{start: 0n, ratePerUnitDay: WAD}];
    const p = emptyPosition();
    track(p, 5n * SHARE, epochs, 1_000n);
    untrack(p, 2n * SHARE, epochs, 1_000n + DAY);
    expect(p.maturityStart).toBe(1_000n);
    untrack(p, 99n * SHARE, epochs, 1_000n + 2n * DAY);
    expect(p.balance).toBe(0n);
  });

  it("restarts the ramp when a position is re-opened from zero", () => {
    const epochs = [{start: 0n, ratePerUnitDay: WAD}];
    const p = emptyPosition();
    track(p, SHARE, epochs, 1_000n);
    untrack(p, SHARE, epochs, 1_000n + 400n * DAY);
    track(p, SHARE, epochs, 1_000n + 500n * DAY);
    expect(p.maturityStart).toBe(1_000n + 500n * DAY);
  });

  it("keeps PointsModule's intermediate WAD floor, which only shows at the maximum rate", () => {
    // MAX_RATE_PER_UNIT_DAY is 1e27. Found by search: without the floor after `/ WAD` this reads
    // one unit higher.
    const epochs = [{start: 0n, ratePerUnitDay: 10n ** 27n}];
    const p = emptyPosition();
    track(p, 17_523_649_916_728_235_635n, epochs, 1n);
    expect(pointsAt(p, epochs, 1n + 7_268_698n)).toBe(1_644_135_179_430_361_793_657_522n);
  });

  it("earns nothing between two changes in the same second", () => {
    const epochs = [{start: 0n, ratePerUnitDay: WAD}];
    const once = emptyPosition();
    track(once, 2n * SHARE, epochs, 5_000n);
    const twice = emptyPosition();
    track(twice, SHARE, epochs, 5_000n);
    track(twice, SHARE, epochs, 5_000n);
    expect(pointsAt(twice, epochs, 5_000n + 30n * DAY)).toBe(pointsAt(once, epochs, 5_000n + 30n * DAY));
  });
});

describe("the collateral replay", () => {
  let nextBlock = 1n;
  function event(day: bigint, kind: CollateralEvent["kind"], assets: bigint, owner: `0x${string}` = OWNER): CollateralEvent {
    return {blockNumber: nextBlock++, logIndex: 0, timestamp: T0 + day * DAY, kind, owner, assets};
  }
  const epochs: RateEpoch[] = [{start: T0 - DAY, ratePerUnitDay: 1_250_000_000_000_000_003n}];

  it("keeps owners independent", () => {
    nextBlock = 1n;
    const mixed = [
      event(0n, "supply", 100n * SHARE, OWNER),
      event(1n, "supply", 40n * SHARE, OTHER),
      event(5n, "withdraw", 30n * SHARE, OWNER),
      event(9n, "liquidate", 10n * SHARE, OTHER),
    ];
    const asOf = T0 + 40n * DAY;
    const together = replayCollateralPoints(mixed, epochs, asOf);
    const alone = replayCollateralPoints(mixed.filter((e) => e.owner === OWNER), epochs, asOf);
    expect(together.get(OWNER)).toEqual(alone.get(OWNER));
    expect(together.get(OTHER)?.collateral).toBe(30n * SHARE);
  });

  it("matches owners case-insensitively", () => {
    nextBlock = 1n;
    const upper = "0x00000000000000000000000000000000000000AB" as const;
    const lower = "0x00000000000000000000000000000000000000ab" as const;
    const result = replayCollateralPoints(
      [event(0n, "supply", 10n * SHARE, upper), event(1n, "withdraw", 4n * SHARE, lower)],
      epochs,
      T0 + 2n * DAY,
    );
    expect(result.size).toBe(1);
    expect(result.get(lower)?.collateral).toBe(6n * SHARE);
  });

  it("ignores a zero-amount event, where a checkpoint would have changed the floors", () => {
    // Odd amount, odd instants: splitting the interval at the zero event rounds differently, so
    // an implementation that checkpointed on zero amounts (as the points hook does not) goes red.
    const amount = 1_234_567_891_234_567_891_234_567_891n;
    const supplyAt = T0 + 17n;
    const zeroAt = T0 + 3n * DAY + 7n;
    const asOf = T0 + 45n * DAY + 11n;
    const base = [{blockNumber: 1n, logIndex: 0, timestamp: supplyAt, kind: "supply" as const, owner: OWNER, assets: amount}];
    const withZero = [...base, {blockNumber: 2n, logIndex: 0, timestamp: zeroAt, kind: "supply" as const, owner: OWNER, assets: 0n}];
    const expected = replayCollateralPoints(base, epochs, asOf).get(OWNER)?.points;
    expect(replayCollateralPoints(withZero, epochs, asOf).get(OWNER)?.points).toBe(expected);

    const checkpointed = emptyPosition();
    track(checkpointed, amount, epochs, supplyAt);
    untrack(checkpointed, 0n, epochs, zeroAt); // accrues without moving the balance
    expect(pointsAt(checkpointed, epochs, asOf)).not.toBe(expected);
  });

  it("refuses to remove collateral it never saw supplied, instead of clamping", () => {
    nextBlock = 1n;
    const missing = [event(0n, "supply", 10n * SHARE), event(1n, "withdraw", 11n * SHARE)];
    expect(() => replayCollateralPoints(missing, epochs, T0 + 2n * DAY)).toThrow(/never saw supplied/);
    nextBlock = 1n;
    const seized = [event(0n, "supply", 10n * SHARE), event(1n, "liquidate", 10n * SHARE + 1n)];
    expect(() => replayCollateralPoints(seized, epochs, T0 + 2n * DAY)).toThrow(MorphoPointsIntegrityError);
  });

  it("refuses events out of chain order, after the as-of time, or without a genesis epoch", () => {
    nextBlock = 1n;
    const a = event(0n, "supply", SHARE);
    const b = event(1n, "supply", SHARE);
    expect(() => replayCollateralPoints([b, a], epochs, T0 + 2n * DAY)).toThrow(/out of chain order/);
    expect(() => replayCollateralPoints([a, {...b, blockNumber: a.blockNumber}], epochs, T0 + 2n * DAY)).toThrow(
      /out of chain order/,
    );
    expect(() => replayCollateralPoints([a, b], epochs, T0)).toThrow(/after the as-of time/);
    expect(() => replayCollateralPoints([a], [], T0 + DAY)).toThrow(/genesis rate epoch/);
    expect(() =>
      replayCollateralPoints([a], [{start: T0, ratePerUnitDay: WAD}, {start: T0 - 1n, ratePerUnitDay: WAD}], T0 + DAY),
    ).toThrow(/out of order/);
  });
});

describe("Morpho Blue log decoding, against real mainnet logs", () => {
  it("credits onBehalf, not the bundler that called SupplyCollateral (block 26,073,018)", () => {
    const id = "0xe7e9694b754c4d4f7e21faf7223f6fa71abaeb10296a4c43a54a7977149687d2";
    const decoded = decodeCollateralLog(
      {
        topics: [
          MORPHO_COLLATERAL_TOPICS.SupplyCollateral,
          id,
          "0x00000000000000000000000038b0c12ab81976e9417d4ebfe2a34db6df22e6ad",
          "0x000000000000000000000000f3489e562dd6bfd6a604a75efaf5b4316cec4825",
        ],
        data: "0x00000000000000000000000000000000000000000000000016345785d8a00000",
        blockNumber: 26_073_018n,
        logIndex: 724,
      },
      id,
      1n,
    );
    expect(decoded.kind).toBe("supply");
    expect(decoded.owner.toLowerCase()).toBe("0xf3489e562dd6bfd6a604a75efaf5b4316cec4825");
    expect(decoded.assets).toBe(0x16345785d8a00000n);
  });

  it("credits onBehalf, not the caller or receiver, of a WithdrawCollateral (block 26,073,151)", () => {
    const id = "0xbc32188b61522b84140ca39b8c9ecf94fdf97acb64a6c1a5a987f025f927f9a7";
    const decoded = decodeCollateralLog(
      {
        topics: [
          MORPHO_COLLATERAL_TOPICS.WithdrawCollateral,
          id,
          "0x000000000000000000000000f39661e33e13373d8be2b871429343c7b6eb0fa1",
          "0x0000000000000000000000002de3ecaba30c3ae5f12d19a70064f73538a113ea",
        ],
        data: ("0x0000000000000000000000002de3ecaba30c3ae5f12d19a70064f73538a113ea" +
          "00000000000000000000000000000000000000000000000000000002e90e3529") as `0x${string}`,
        blockNumber: 26_073_151n,
        logIndex: 636,
      },
      id,
      1n,
    );
    expect(decoded.kind).toBe("withdraw");
    expect(decoded.owner.toLowerCase()).toBe("0xf39661e33e13373d8be2b871429343c7b6eb0fa1");
    expect(decoded.assets).toBe(0x2e90e3529n);
  });

  it("credits the borrower, not the liquidator, with the seized collateral (block 26,073,408)", () => {
    const id = "0xde2bb82278de27e7851625e2d7c25280adc6d499c000cc6904eb0ab29124a481";
    const decoded = decodeCollateralLog(
      {
        topics: [
          MORPHO_COLLATERAL_TOPICS.Liquidate,
          id,
          "0x000000000000000000000000fe1dcc4db359b161f9042e99c3b481a50f73dec1",
          "0x0000000000000000000000008dc49b98b2f6cb7b76ff92faa165742fb9aae4f8",
        ],
        data: ("0x0000000000000000000000000000000000000000000000000000000000163d76" +
          "0000000000000000000000000000000000000000000000000000014ada0cb413" +
          "000000000000000000000000000000000000000000005380453ec11c71bbbdda" +
          "0000000000000000000000000000000000000000000000000000000000000000" +
          "0000000000000000000000000000000000000000000000000000000000000000") as `0x${string}`,
        blockNumber: 26_073_408n,
        logIndex: 469,
      },
      id,
      1n,
    );
    expect(decoded.kind).toBe("liquidate");
    expect(decoded.owner.toLowerCase()).toBe("0x8dc49b98b2f6cb7b76ff92faa165742fb9aae4f8");
    expect(decoded.assets).toBe(0x5380453ec11c71bbbddan);
  });

  it("refuses a log from another market", () => {
    expect(() =>
      decodeCollateralLog(
        {
          topics: [
            MORPHO_COLLATERAL_TOPICS.SupplyCollateral,
            "0xe7e9694b754c4d4f7e21faf7223f6fa71abaeb10296a4c43a54a7977149687d2",
            "0x00000000000000000000000038b0c12ab81976e9417d4ebfe2a34db6df22e6ad",
            "0x000000000000000000000000f3489e562dd6bfd6a604a75efaf5b4316cec4825",
          ],
          data: "0x00000000000000000000000000000000000000000000000016345785d8a00000",
          blockNumber: 1n,
          logIndex: 0,
        },
        "0x1111111111111111111111111111111111111111111111111111111111111111",
        1n,
      ),
    ).toThrow(/another market/);
  });
});

describe("market configuration", () => {
  const id = "0x" + "ab".repeat(32);
  const oracle = "0xB53977a70D755a56d3Ce26926Acb4c33f7861c61";
  const complete = {MORPHO_SUSDFR_MARKET_ID: id, MORPHO_SUSDFR_MARKET_FROM_BLOCK: "26100000", MORPHO_SUSDFR_ORACLE: oracle};

  it("is off when no value is set, and off away from mainnet whatever is set", () => {
    expect(morphoPointsConfig({}, true)).toBeNull();
    expect(morphoPointsConfig(complete, false)).toBeNull();
    expect(morphoPointsConfig({MORPHO_SUSDFR_MARKET_ID: "junk"}, false)).toBeNull();
  });

  it("reads a complete mainnet configuration, with the oracle it pins", () => {
    expect(
      morphoPointsConfig(
        {...complete, MORPHO_SUSDFR_MARKET_ID: id.toUpperCase().replace("0X", "0x"), MORPHO_SUSDFR_ORACLE: oracle.toLowerCase()},
        true,
      ),
    ).toEqual({marketId: id, fromBlock: 26_100_000n, oracle});
  });

  it("refuses a partial or malformed mainnet configuration rather than guess", () => {
    expect(() => morphoPointsConfig({MORPHO_SUSDFR_MARKET_ID: id}, true)).toThrow(/set together/);
    expect(() => morphoPointsConfig({MORPHO_SUSDFR_MARKET_FROM_BLOCK: "1"}, true)).toThrow(/set together/);
    expect(() => morphoPointsConfig({MORPHO_SUSDFR_ORACLE: oracle}, true)).toThrow(/set together/);
    expect(() => morphoPointsConfig({...complete, MORPHO_SUSDFR_MARKET_ID: "0x1234"}, true)).toThrow(/bytes32/);
    expect(() => morphoPointsConfig({...complete, MORPHO_SUSDFR_MARKET_FROM_BLOCK: "0"}, true)).toThrow(
      MorphoPointsIntegrityError,
    );
  });

  it("fails closed on a market id without the oracle pin, or an oracle that is not an address (MORPHO-16)", () => {
    expect(() =>
      morphoPointsConfig({MORPHO_SUSDFR_MARKET_ID: id, MORPHO_SUSDFR_MARKET_FROM_BLOCK: "26100000"}, true),
    ).toThrow(/MORPHO_SUSDFR_ORACLE must be set together/);
    expect(() => morphoPointsConfig({...complete, MORPHO_SUSDFR_ORACLE: "0x1234"}, true)).toThrow(/not an address/);
    // Mixed case with a broken EIP-55 checksum is refused rather than corrected.
    expect(() => morphoPointsConfig({...complete, MORPHO_SUSDFR_ORACLE: oracle.replace("B5", "b5")}, true)).toThrow(
      /not an address/,
    );
  });
});
