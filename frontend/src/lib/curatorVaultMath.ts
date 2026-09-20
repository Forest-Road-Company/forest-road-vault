/**
 * Mirror of the program's arithmetic (`solana/curator-vault/.../src/math.rs`), in BigInt.
 *
 * The page uses it to show what the program will pay, so it must floor and carry exactly as
 * the program does. Rates are basis points, Actual/360, continuous accrual settled at UTC month
 * starts. Tested against the same fixtures as the Rust module.
 */

export const YEAR_SECONDS = 360n * 86_400n;
export const BPS = 10_000n;
export const SLICE_DENOMINATOR = BPS * YEAR_SECONDS;

export type RateEpoch = { startTs: bigint; bps: number };

/** Whole units accrued over [from, to) plus the carried remainder, exactly as the program. */
export function accrue(
  principal: bigint,
  epochs: RateEpoch[],
  from: bigint,
  to: bigint,
  carried: bigint,
): { whole: bigint; remainder: bigint } {
  if (to <= from || principal === 0n || epochs.length === 0) return { whole: 0n, remainder: carried };
  let numerator = carried;
  epochs.forEach((epoch, i) => {
    const sliceStart = epoch.startTs > from ? epoch.startTs : from;
    const next = epochs[i + 1];
    const sliceEnd = next ? (next.startTs < to ? next.startTs : to) : to;
    if (sliceEnd <= sliceStart) return;
    numerator += principal * BigInt(epoch.bps) * (sliceEnd - sliceStart);
  });
  return { whole: numerator / SLICE_DENOMINATOR, remainder: numerator % SLICE_DENOMINATOR };
}

/** 00:00:00 UTC on the first day of the month containing `ts` (seconds). */
export function monthStart(ts: bigint): bigint {
  const d = new Date(Number(ts) * 1000);
  return BigInt(Math.floor(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), 1) / 1000));
}

/** The first month boundary strictly after `ts` (seconds). */
export function nextMonthStart(ts: bigint): bigint {
  const d = new Date(Number(ts) * 1000);
  return BigInt(Math.floor(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 1) / 1000));
}

export type PositionLike = {
  principal: bigint;
  couponOwed: bigint;
  couponPayable: bigint;
  couponRemainder: bigint;
  couponAccruedThrough: bigint;
  couponPaidThrough: bigint;
};

/**
 * What `pay_coupon` would transfer now, and what has accrued since the last boundary and is
 * not yet payable. Mirrors `handle_pay_coupon`: payable once per month for accrual through the
 * most recent boundary plus anything settled by principal changes since.
 */
export function couponView(p: PositionLike, epochs: RateEpoch[], now: bigint) {
  const boundary = monthStart(now);
  const payableNow = boundary > p.couponPaidThrough;
  let owed = p.couponOwed;
  let payable = p.couponPayable;
  let remainder = p.couponRemainder;
  let accruedThrough = p.couponAccruedThrough;
  if (payableNow && accruedThrough !== 0n && accruedThrough <= boundary) {
    const r = accrue(p.principal, epochs, accruedThrough, boundary, remainder);
    owed += r.whole;
    remainder = r.remainder;
    accruedThrough = boundary;
    payable = owed;
  }
  const pendingStored = owed >= payable ? owed - payable : 0n;
  const sinceCheckpoint = accrue(p.principal, epochs, accruedThrough, now, remainder).whole;
  return {
    claimable: payableNow ? payable : 0n,
    pendingThisMonth: pendingStored + sinceCheckpoint,
    nextBoundary: nextMonthStart(now),
    boundary,
  };
}

export function currentRateBps(epochs: RateEpoch[], now: bigint): number {
  let bps = 0;
  for (const e of epochs) if (e.startTs <= now) bps = e.bps;
  return bps;
}

export function formatUnits(value: bigint, decimals: number, places = 2): string {
  const base = 10n ** BigInt(decimals);
  const whole = value / base;
  const frac = value % base;
  const fracStr = frac.toString().padStart(decimals, "0").slice(0, places);
  return `${whole.toLocaleString("en-US")}${places > 0 ? "." + fracStr : ""}`;
}
