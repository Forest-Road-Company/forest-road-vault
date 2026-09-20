import {describe, expect, it} from "vitest";
import {accrue, couponView, monthStart, nextMonthStart, SLICE_DENOMINATOR} from "@/lib/curatorVaultMath";

const USDC = 1_000_000n;
const DAY = 86_400n;

describe("curator vault arithmetic mirror", () => {
  it("one Actual/360 year at 5% on 1,000,000 is exactly 50,000 (Rust fixture)", () => {
    const r = accrue(1_000_000n * USDC, [{startTs: 0n, bps: 500}], 0n, 360n * DAY, 0n);
    expect(r.whole).toBe(50_000n * USDC);
    expect(r.remainder).toBe(0n);
  });

  it("a rate change splits the slice at the epoch start (Rust fixture)", () => {
    const epochs = [{startTs: 0n, bps: 500}, {startTs: 180n * DAY, bps: 1_000}];
    expect(accrue(1_000_000n * USDC, epochs, 0n, 360n * DAY, 0n).whole).toBe(75_000n * USDC);
  });

  it("carrying the remainder makes accrual path-independent", () => {
    const epochs = [{startTs: 0n, bps: 1_250}];
    const principal = 123_456_789n;
    const one = accrue(principal, epochs, 17n, 9_999_999n, 0n);
    const a = accrue(principal, epochs, 17n, 4_321n, 0n);
    const b = accrue(principal, epochs, 4_321n, 9_999_999n, a.remainder);
    expect(a.whole + b.whole).toBe(one.whole);
    expect(b.remainder).toBe(one.remainder);
    expect(one.remainder < SLICE_DENOMINATOR).toBe(true);
  });

  it("month boundaries match the civil calendar", () => {
    const sep17 = BigInt(Math.floor(Date.UTC(2026, 8, 17, 10, 42, 12) / 1000));
    expect(monthStart(sep17)).toBe(BigInt(Date.UTC(2026, 8, 1) / 1000));
    expect(nextMonthStart(sep17)).toBe(BigInt(Date.UTC(2026, 9, 1) / 1000));
    const dec31 = BigInt(Math.floor(Date.UTC(2026, 11, 31, 23, 59, 59) / 1000));
    expect(nextMonthStart(dec31)).toBe(BigInt(Date.UTC(2027, 0, 1) / 1000));
  });

  it("a position opened mid-month has nothing claimable until the next boundary", () => {
    const opened = BigInt(Math.floor(Date.UTC(2026, 8, 18, 1) / 1000));
    const epochs = [{startTs: opened, bps: 1_250}];
    const p = {
      principal: 10_000n * USDC,
      couponOwed: 0n,
      couponPayable: 0n,
      couponRemainder: 0n,
      couponAccruedThrough: opened,
      couponPaidThrough: monthStart(opened),
    };
    const late = opened + 10n * DAY;
    const before = couponView(p, epochs, late);
    expect(before.claimable).toBe(0n);
    expect(before.pendingThisMonth).toBe(accrue(p.principal, epochs, opened, late, 0n).whole);
    const oct1 = BigInt(Date.UTC(2026, 9, 1) / 1000) + 10n;
    const after = couponView(p, epochs, oct1);
    expect(after.claimable).toBe(accrue(p.principal, epochs, opened, oct1 - 10n, 0n).whole);
  });

  it("does not make coupon checkpointed after the completed boundary payable early", () => {
    const oct1 = BigInt(Date.UTC(2026, 9, 1) / 1000);
    const oct10 = BigInt(Date.UTC(2026, 9, 10) / 1000);
    const oct15 = BigInt(Date.UTC(2026, 9, 15) / 1000);
    const p = {
      principal: 10_000n * USDC,
      couponOwed: 120n * USDC,
      couponPayable: 100n * USDC,
      couponRemainder: 0n,
      couponAccruedThrough: oct10,
      couponPaidThrough: BigInt(Date.UTC(2026, 8, 1) / 1000),
    };
    const view = couponView(p, [{startTs: oct1, bps: 1_250}], oct15);
    expect(view.claimable).toBe(100n * USDC);
    expect(view.pendingThisMonth).toBe(
      20n * USDC + accrue(p.principal, [{startTs: oct1, bps: 1_250}], oct10, oct15, 0n).whole,
    );
  });
});
