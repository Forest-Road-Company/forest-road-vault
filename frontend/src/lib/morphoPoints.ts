/**
 * Participation points for sUSDfr posted as collateral in the Forest Road Morpho Blue market.
 *
 * sUSDfr moved into Morpho Blue leaves its owner's wallet, so the on-chain PointsModule credits
 * the Morpho Blue contract instead of the owner. Forest Road credits the owner off-chain by
 * replaying the market's own collateral events through this exact mirror of the PointsModule
 * share formula (sUSDfr at the 1x base, forward-only rate epochs, the 365-day maturity ramp).
 *
 * Methodology (decision D5, 28 September 2026): each owner's Morpho collateral is its own
 * position, so its maturity ramp starts when the collateral is supplied, exactly as moving shares
 * to a fresh wallet does. Adding collateral blends the start time by amount; withdrawal and
 * liquidation reduce the balance without resetting what remains. The Morpho Blue contract's own
 * on-chain points are a pass-through and are excluded from any future allocation.
 *
 * Every operation below reproduces PointsModule's integer arithmetic step for step, including
 * the order of multiplications and floor divisions. The parity target is the ideal on-chain
 * ledger: a wallet that is not protocol-exempt, held the same shares over the same instants, and
 * whose every points hook succeeded. Two schedules measured from the deployed contract on a
 * mainnet fork pin it (contracts/deployments/fixtures/morpho-collateral-points-parity.json), and
 * a differential test compares it with a Solidity-literal model across random schedules.
 *
 * Exempt and jurisdiction-blocked owners are the server's concern: this module credits every
 * owner it is given, and `morphoPoints.server.ts` withholds the result for those two.
 */

/** A replay or history failure. Its message names no endpoint and is safe to log. */
export class MorphoPointsIntegrityError extends Error {
  override name = "MorphoPointsIntegrityError";
}

export const MATURITY_RAMP = 365n * 86_400n;
export const WAD = 10n ** 18n;
export const SHARE_UNIT = 10n ** 24n;
const DAY = 86_400n;

/** A PointsModule rate epoch. sUSDfr earns the base rate, so only the rate matters here. */
export type RateEpoch = {start: bigint; ratePerUnitDay: bigint};

/** One change to an owner's Morpho collateral, in chain order. */
export type CollateralEvent = {
  blockNumber: bigint;
  logIndex: number;
  timestamp: bigint;
  kind: "supply" | "withdraw" | "liquidate";
  owner: `0x${string}`;
  assets: bigint;
};

/** Mirrors PointsModule.Position for the share stream. */
export type Position = {
  balance: bigint;
  accrued: bigint;
  maturityStart: bigint;
  lastAccrual: bigint;
};

export const emptyPosition = (): Position => ({balance: 0n, accrued: 0n, maturityStart: 0n, lastAccrual: 0n});

/** F(x) = integral of m(t) from 0 to x, m(t) = 1 + min(t, RAMP) / RAMP, WAD-scaled. */
export function rampIntegral(x: bigint): bigint {
  if (x <= MATURITY_RAMP) return x * WAD + (x * x * WAD) / (2n * MATURITY_RAMP);
  return (3n * MATURITY_RAMP * WAD) / 2n + 2n * (x - MATURITY_RAMP) * WAD;
}

function epochPoints(balance: bigint, start: bigint, a: bigint, b: bigint, ratePerUnitDay: bigint): bigint {
  const dF = rampIntegral(b >= start ? b - start : 0n) - rampIntegral(a >= start ? a - start : 0n);
  // PointsModule: rate = ratePerUnitDay * BPS / BPS for shares, then bal * dF / WAD * rate / (1 day * unit).
  return (((balance * dF) / WAD) * ratePerUnitDay) / (DAY * SHARE_UNIT);
}

function validateEpochs(epochs: readonly RateEpoch[]): void {
  if (epochs.length === 0) throw new MorphoPointsIntegrityError("points: at least the genesis rate epoch is required");
  for (let i = 1; i < epochs.length; i++) {
    if (epochs[i].start < epochs[i - 1].start) throw new MorphoPointsIntegrityError("points: rate epochs out of order");
  }
}

/**
 * Points earned since the last checkpoint, as PointsModule._pending computes them at `now`.
 * Iterating from epoch 0 is equivalent to the contract's `lastEpochIdx` start: every epoch
 * before it ends at or before `lastAccrual`, so it contributes nothing.
 */
export function pending(p: Position, epochs: readonly RateEpoch[], now: bigint): bigint {
  if (p.balance === 0n || p.lastAccrual === 0n || now <= p.lastAccrual) return 0n;
  let total = 0n;
  for (let i = 0; i < epochs.length; i++) {
    const a = epochs[i].start > p.lastAccrual ? epochs[i].start : p.lastAccrual;
    let b = i + 1 < epochs.length ? epochs[i + 1].start : now;
    if (b > now) b = now;
    if (b > a) total += epochPoints(p.balance, p.maturityStart, a, b, epochs[i].ratePerUnitDay);
  }
  return total;
}

function accrue(p: Position, epochs: readonly RateEpoch[], now: bigint): void {
  p.accrued += pending(p, epochs, now);
  p.lastAccrual = now;
}

/** PointsModule._track: checkpoint, then blend the maturity start by amount. */
export function track(p: Position, amount: bigint, epochs: readonly RateEpoch[], now: bigint): void {
  accrue(p, epochs, now);
  p.maturityStart = p.balance === 0n ? now : (p.balance * p.maturityStart + amount * now) / (p.balance + amount);
  p.balance += amount;
}

/** PointsModule._untrack: checkpoint, then reduce the balance (clamped), keeping the start. */
export function untrack(p: Position, amount: bigint, epochs: readonly RateEpoch[], now: bigint): void {
  accrue(p, epochs, now);
  p.balance -= amount < p.balance ? amount : p.balance;
}

/** Accrued plus pending points, as `pointsOfWallet` reads them at `now`. */
export function pointsAt(p: Position, epochs: readonly RateEpoch[], now: bigint): bigint {
  return p.accrued + pending(p, epochs, now);
}

export type OwnerPoints = {owner: `0x${string}`; collateral: bigint; points: bigint};

/**
 * Replays a market's collateral events and returns each owner's live collateral and points at
 * `asOf`. Throws rather than guess on events out of chain order, dated after `asOf`, or removing
 * more collateral than the replay holds: Morpho Blue reverts such a withdrawal, so it can only
 * mean the history is missing an earlier event.
 */
export function replayCollateralPoints(
  events: readonly CollateralEvent[],
  epochs: readonly RateEpoch[],
  asOf: bigint,
): Map<string, OwnerPoints> {
  validateEpochs(epochs);
  const positions = new Map<string, {owner: `0x${string}`; p: Position}>();
  let previous: CollateralEvent | undefined;
  for (const event of events) {
    if (
      previous &&
      (event.blockNumber < previous.blockNumber ||
        (event.blockNumber === previous.blockNumber && event.logIndex <= previous.logIndex) ||
        event.timestamp < previous.timestamp)
    ) {
      throw new MorphoPointsIntegrityError("points: collateral events out of chain order");
    }
    if (event.timestamp > asOf) throw new MorphoPointsIntegrityError("points: collateral event after the as-of time");
    if (event.assets < 0n) throw new MorphoPointsIntegrityError("points: negative collateral amount");
    previous = event;
    const key = event.owner.toLowerCase();
    let entry = positions.get(key);
    if (!entry) {
      entry = {owner: event.owner, p: emptyPosition()};
      positions.set(key, entry);
    }
    if (event.assets === 0n) continue; // PointsModule returns early on a zero amount
    if (event.kind === "supply") {
      track(entry.p, event.assets, epochs, event.timestamp);
    } else {
      if (event.assets > entry.p.balance) {
        throw new MorphoPointsIntegrityError("points: collateral removed that the replay never saw supplied");
      }
      untrack(entry.p, event.assets, epochs, event.timestamp);
    }
  }
  const out = new Map<string, OwnerPoints>();
  for (const [key, {owner, p}] of positions) {
    out.set(key, {owner, collateral: p.balance, points: pointsAt(p, epochs, asOf)});
  }
  return out;
}
