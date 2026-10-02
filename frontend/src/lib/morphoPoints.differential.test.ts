import {describe, expect, it} from "vitest";
import {replayCollateralPoints, type CollateralEvent, type RateEpoch} from "@/lib/morphoPoints";

/**
 * Differential test: a Solidity-literal model of PointsModule's share stream against the replay.
 *
 * The model follows the contract's own control flow, which the replay deliberately does not: it
 * iterates epochs from `lastEpochIdx`, casts timestamps to uint64, checks every uint256 operation,
 * and appends rate epochs in chain order interleaved with the transfers. The replay iterates from
 * epoch 0 over the final epoch list. Random schedules cover what the two fork-pinned schedules
 * cannot reach cheaply: one floor per epoch, same-block epochs on both sides of an event,
 * multiplier-only and zero-rate epochs, dust and zero amounts, zero-seized liquidations and gaps
 * longer than the ramp. Written for the 28 September 2026 review of the Morpho points build.
 */

const WAD = 10n ** 18n;
const SHARE_UNIT = 10n ** 24n;
const BPS = 10_000n;
const RAMP = 365n * 86_400n;
const U256 = (1n << 256n) - 1n;
const U64 = (1n << 64n) - 1n;

function chk(x: bigint): bigint {
  if (x < 0n || x > U256) throw new Error("uint256 overflow/underflow");
  return x;
}

function rampIntegral(x: bigint): bigint {
  if (x <= RAMP) return chk(chk(x * WAD) + chk(chk(x * x) * WAD) / chk(2n * RAMP));
  return chk(chk(3n * RAMP * WAD) / 2n + chk(chk(2n * (x - RAMP)) * WAD));
}

type SolEpoch = {start: bigint; ratePerUnitDay: bigint};
type SolPosition = {balance: bigint; accrued: bigint; maturityStart: bigint; lastAccrual: bigint; lastEpochIdx: number};

/** PointsModule's share stream, transcribed statement by statement. */
class SolidityModel {
  epochs: SolEpoch[] = [];
  positions = new Map<string, SolPosition>();
  now = 0n;

  position(owner: string): SolPosition {
    let p = this.positions.get(owner);
    if (!p) {
      p = {balance: 0n, accrued: 0n, maturityStart: 0n, lastAccrual: 0n, lastEpochIdx: 0};
      this.positions.set(owner, p);
    }
    return p;
  }

  appendEpoch(rate: bigint): void {
    this.epochs.push({start: this.now & U64, ratePerUnitDay: rate});
  }

  private epochPoints(balance: bigint, start: bigint, a: bigint, b: bigint, e: SolEpoch): bigint {
    const dF = chk(rampIntegral(b >= start ? b - start : 0n) - rampIntegral(a >= start ? a - start : 0n));
    const rate = chk(e.ratePerUnitDay * BPS) / BPS; // _multForKind(shares) is BPS
    return chk(chk(chk(balance * dF) / WAD) * rate) / chk(86_400n * SHARE_UNIT);
  }

  pending(p: SolPosition): bigint {
    if (p.balance === 0n || p.lastAccrual === 0n || this.now <= p.lastAccrual) return 0n;
    const upper = this.now;
    let total = 0n;
    for (let i = p.lastEpochIdx; i < this.epochs.length; i++) {
      const a = this.epochs[i].start > p.lastAccrual ? this.epochs[i].start : p.lastAccrual;
      let b = i + 1 < this.epochs.length ? this.epochs[i + 1].start : upper;
      if (b > upper) b = upper;
      if (b > a) total = chk(total + this.epochPoints(p.balance, p.maturityStart, a, b, this.epochs[i]));
    }
    return total;
  }

  private accrue(p: SolPosition): void {
    const pending = this.pending(p);
    p.lastAccrual = this.now & U64;
    p.lastEpochIdx = this.epochs.length - 1;
    if (pending !== 0n) p.accrued = chk(p.accrued + pending);
  }

  receive(owner: string, amount: bigint): void {
    if (amount === 0n) return;
    const p = this.position(owner);
    this.accrue(p);
    const now = this.now & U64;
    p.maturityStart =
      p.balance === 0n ? now : (chk(chk(p.balance * p.maturityStart) + chk(amount * now)) / chk(p.balance + amount)) & U64;
    p.balance = chk(p.balance + amount);
  }

  send(owner: string, amount: bigint): void {
    if (amount === 0n) return;
    const p = this.position(owner);
    this.accrue(p);
    p.balance -= amount < p.balance ? amount : p.balance;
  }

  pointsOf(owner: string): bigint {
    const p = this.position(owner);
    return p.accrued + this.pending(p);
  }
}

/** Deterministic xorshift64* so a failure reproduces exactly. */
function prng(seed: bigint) {
  let s = seed & U64;
  const next = () => {
    s ^= s >> 12n;
    s ^= (s << 25n) & U64;
    s ^= s >> 27n;
    s &= U64;
    return (s * 0x2545f4914f6cdd1dn) & U64;
  };
  const below = (n: bigint) => (n <= 0n ? 0n : next() % n);
  return {below, pick: <T,>(xs: readonly T[]): T => xs[Number(below(BigInt(xs.length)))]};
}

const OWNERS = [
  "0x00000000000000000000000000000000000000a1",
  "0x00000000000000000000000000000000000000a2",
  "0x00000000000000000000000000000000000000a3",
] as const;

function runSchedules(iterations: number, seed: bigint): {cases: number; mismatches: string[]} {
  const {below, pick} = prng(seed);
  const amount = (): bigint => {
    switch (Number(below(6n))) {
      case 0:
        return (1n + below(5_000n)) * SHARE_UNIT;
      case 1:
        return 1n + below(10n ** 30n);
      case 2:
        return 1n + below(1_000_000n);
      case 3:
        return below(10n ** 27n) + below(7n);
      case 4:
        return 0n;
      default:
        return 1n + below(10n ** 24n);
    }
  };
  const rate = (previous: bigint): bigint => {
    switch (Number(below(5n))) {
      case 0:
        return previous; // a multiplier-only epoch: shares keep the rate, the boundary remains
      case 1:
        return 0n;
      case 2:
        return 1n + below(10n ** 27n);
      case 3:
        return (1n + below(5n)) * WAD;
      default:
        return below(3n * WAD) + 1n;
    }
  };

  let cases = 0;
  const mismatches: string[] = [];
  for (let iteration = 0; iteration < iterations; iteration++) {
    const model = new SolidityModel();
    const events: CollateralEvent[] = [];
    const epochs: RateEpoch[] = [];
    const held = new Map<string, bigint>();
    let ts = 1_700_000_000n + below(1_000_000n);
    let block = 1_000n;
    model.now = ts;
    model.appendEpoch(WAD);
    epochs.push({start: ts, ratePerUnitDay: WAD});
    let lastRate = WAD;
    const blocks = 1 + Number(below(25n));
    for (let b = 0; b < blocks; b++) {
      const gapKind = Number(below(5n));
      const gap =
        gapKind === 0
          ? 12n
          : gapKind === 1
            ? below(90n * 86_400n) + 1n
            : gapKind === 2
              ? RAMP + below(400n * 86_400n)
              : gapKind === 3
                ? 1n
                : below(3_000n) + 1n;
      ts += gap;
      block += 1n + below(3n);
      model.now = ts;
      const transactions = 1 + Number(below(4n));
      let logIndex = 0;
      for (let t = 0; t < transactions; t++) {
        if (below(5n) === 0n) {
          lastRate = rate(lastRate);
          model.appendEpoch(lastRate);
          epochs.push({start: ts, ratePerUnitDay: lastRate});
          logIndex++;
          continue;
        }
        const owner = pick(OWNERS);
        const balance = held.get(owner) ?? 0n;
        const choice = Number(below(3n));
        let kind: CollateralEvent["kind"] =
          choice === 0 || balance === 0n ? "supply" : choice === 1 ? "withdraw" : "liquidate";
        let assets = amount();
        if (kind === "supply" && assets === 0n && below(2n) === 0n) assets = 1n;
        if (kind !== "supply") assets = balance === 0n ? 0n : below(2n) === 0n ? balance : below(balance + 1n);
        if (kind === "withdraw" && assets === 0n) assets = balance; // Morpho refuses a zero withdrawal
        if (kind === "supply" && assets === 0n) kind = "liquidate"; // only a liquidation seizes zero
        held.set(owner, kind === "supply" ? balance + assets : balance - assets);
        if (kind === "supply") model.receive(owner, assets);
        else model.send(owner, assets);
        events.push({blockNumber: block, logIndex: logIndex++, timestamp: ts, kind, owner, assets});
      }
    }
    const tail = below(3n) === 0n ? 0n : below(3n) === 0n ? RAMP + below(100n * 86_400n) : below(200n * 86_400n);
    const asOf = ts + tail;
    model.now = asOf;
    const replayed = replayCollateralPoints(events, epochs, asOf);
    for (const owner of OWNERS) {
      cases++;
      const want = model.pointsOf(owner);
      const got = replayed.get(owner)?.points ?? 0n;
      const wantBalance = model.position(owner).balance;
      const gotBalance = replayed.get(owner)?.collateral ?? 0n;
      if (want !== got || wantBalance !== gotBalance) {
        mismatches.push(`iteration ${iteration} ${owner}: model ${want}/${wantBalance}, replay ${got}/${gotBalance}`);
      }
    }
  }
  return {cases, mismatches};
}

describe("Morpho collateral points: differential against a Solidity-literal PointsModule", () => {
  it("agrees exactly on 2,000 random schedules (6,000 owner cases)", () => {
    const {cases, mismatches} = runSchedules(2_000, 0x9e3779b97f4a7c15n);
    expect(cases).toBe(6_000);
    expect(mismatches.slice(0, 5)).toEqual([]);
  });

  it("agrees under a second seed", () => {
    const {mismatches} = runSchedules(500, 0x2545f4914f6cdd1dn);
    expect(mismatches.slice(0, 5)).toEqual([]);
  });
});
