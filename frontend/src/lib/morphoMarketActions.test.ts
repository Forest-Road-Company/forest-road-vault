import {describe, expect, it} from "vitest";
import {postActionValues, repaymentQuote, safeBorrowMaximum, safeCollateralMaximum, withinMarketBuffer} from "./morphoMarketActions";
import {accrueMarket, marketPositionValues} from "./morphoMarket";
import {maximumHorizonInterest, MAX_MARKET_RATE} from "./morphoMarketProjection";
import type {MorphoMarketSnapshot} from "./morphoMarketReader";

function snapshot(): MorphoMarketSnapshot {
  const market = {totalSupplyAssets: 1_000_000n, totalSupplyShares: 1_000_000_000_000n, totalBorrowAssets: 500_000n,
    totalBorrowShares: 500_000_000_000n, lastUpdate: 1_792_500_000n, fee: 0n};
  return {block: 26_234_000n, blockHash: `0x${"aa".repeat(32)}`, timestamp: 1_792_500_000n, readAt: 0,
    issuedAt: 0, expiresAt: 300_000, projectedThrough: 1_792_500_300n, projectionSeconds: 300n,
    market, projectedMarket: {...market},
    price: 10n ** 18n, rate: 0n, supplyRate: 0n, liquidity: 500_000n,
    account: {wallet: "0x1111111111111111111111111111111111111111", position: {supplyShares: 0n, borrowShares: 500_000_000_000n, collateral: 10n ** 24n},
      usdc: 500_150n, collateral: 0n, usdcAllowance: 0n, collateralAllowance: 0n, safeNonce: null,
      values: {supplied: 0n, borrowed: 500_000n, collateralValue: 1_000_000n, liquidationDebt: 860_000n,
        liquidity: 500_000n, borrowAvailable: 360_000n, ltvBps: 5000n}}};
}

describe("repay-all allowance and balance horizon", () => {
  it("separates what Morpho needs from the larger one-time approval", () => {
    const s = snapshot();s.projectedMarket.totalBorrowAssets = 500_150n;
    expect(repaymentQuote(s)).toEqual({required: 500_152n, approval: 500_653n});
    s.account!.usdc = 500_152n;
    expect(s.account!.usdc).toBeLessThan(repaymentQuote(s).approval);
  });
  it("accepts the original approval after one more raw unit of debt accrues", () => {
    const s = snapshot();s.projectedMarket.totalBorrowAssets = 500_150n;
    const first = repaymentQuote(s);
    s.market.totalBorrowAssets += 1n;s.market.totalSupplyAssets += 1n;s.account!.values.borrowed += 1n;
    s.projectedMarket.totalBorrowAssets += 1n;
    const next = repaymentQuote(s);
    expect(next.required).toBe(500_153n);expect(next.approval).toBeGreaterThan(first.approval);
    expect(first.approval).toBeGreaterThanOrEqual(next.required);
  });
  it("handles zero rates, zero debt and no connected account", () => {
    const s = snapshot();expect(repaymentQuote(s)).toEqual({required: 500_002n, approval: 500_503n});
    s.account!.position.borrowShares = 0n;expect(repaymentQuote(s)).toEqual({required: 0n, approval: 0n});
    s.account = null;expect(repaymentQuote(s)).toEqual({required: 0n, approval: 0n});
  });
  it("uses the forward stored-state projection rather than today's trailing-average rate", () => {
    const s = snapshot();s.rate = 0n;
    s.projectedMarket.totalBorrowAssets = 552_469n;
    expect(repaymentQuote(s).required).toBe(552_471n);
    expect(repaymentQuote(s).approval).toBe(553_024n);
  });
  it("rounds new debt's ceiling-rate interest up even below one raw USDC unit", () => {
    expect(MAX_MARKET_RATE).toBe(253_678_335_871n);
    expect(MAX_MARKET_RATE).toBeGreaterThanOrEqual((2n * 10n ** 18n / 31_536_000n) * 4n);
    expect(maximumHorizonInterest(0n, 300n)).toBe(0n);
    expect(maximumHorizonInterest(1n, 300n)).toBe(1n);
    expect(maximumHorizonInterest(1_000_000n, 300n)).toBe(77n);
    expect(maximumHorizonInterest(1_000_000n, 447n)).toBe(114n);
  });
});

describe("post-action LTV and executable buffered maxima", () => {
  it("computes typed borrowing with Morpho's upward share rounding", () => {
    const s = snapshot();expect(postActionValues("borrow", 300_000n, false, s)).toMatchObject({borrowed: 800_000n, ltvBps: 8000n});
    expect(withinMarketBuffer(postActionValues("borrow", 300_000n, false, s)!)).toBe(true);
    expect(withinMarketBuffer(postActionValues("borrow", 300_001n, false, s)!)).toBe(false);
  });
  it("finds the largest buffered borrow and respects liquidity", () => {
    const s = snapshot();expect(safeBorrowMaximum(s)).toBe(299_935n);
    s.liquidity = 123_456n;expect(safeBorrowMaximum(s)).toBe(123_456n);
    s.account!.values.borrowed = 800_001n;expect(safeBorrowMaximum(s)).toBe(0n);
    s.account = null;expect(safeBorrowMaximum(s)).toBe(0n);
  });
  it("backs off the asset maximum when upward share rounding crosses the buffer", () => {
    const s=snapshot();s.market.totalSupplyAssets=3_000_000n;s.market.totalBorrowAssets=2_000_000n;
    s.market.totalBorrowShares=1n;s.account!.position.borrowShares=1n;s.account!.values.borrowed=2n;s.liquidity=1_000_000n;
    s.projectedMarket = {...s.market};
    const maximum = safeBorrowMaximum(s);
    expect(maximum).toBeLessThan(799_997n);
    expect(postActionValues("borrow",maximum,false,s)!.borrowed).toBeLessThanOrEqual(800_000n);
    const numerator = (1n + (maximum * 1_000_001n + 2_000_000n) / 2_000_001n) * (2_000_001n + maximum);
    const denominator = 1_000_001n + (maximum * 1_000_001n + 2_000_000n) / 2_000_001n;
    expect(postActionValues("borrow",maximum,false,s)!.borrowed).toBe((numerator + denominator - 1n) / denominator);
  });
  it("retains exactly the collateral needed for the 80% buffer", () => {
    const s = snapshot(), amount = 374_997_000_000_000_000_000_000n;
    expect(safeCollateralMaximum(s)).toBe(amount);
    expect(postActionValues("withdrawCollateral", amount, false, s)).toMatchObject({borrowed: 500_000n, collateralValue: 625_003n, ltvBps: 8000n});
    expect((s.account!.position.collateral - amount) * s.price / 10n ** 36n * 8000n / 10_000n).toBeGreaterThanOrEqual(500_002n);
    expect((s.account!.position.collateral - amount - 1n) * s.price / 10n ** 36n * 8000n / 10_000n).toBeLessThan(500_002n);
  });
  it("rounds the retained collateral up at an uneven oracle price", () => {
    const s = snapshot();s.price = 1_000_000_000_000_000_001n;
    const needed = (625_003n * 10n ** 36n + s.price - 1n) / s.price;
    expect(625_003n * 10n ** 36n % s.price).not.toBe(0n);
    expect(safeCollateralMaximum(s)).toBe(s.account!.position.collateral - needed);
    expect(needed * s.price / 10n ** 36n).toBe(625_003n);
    expect((needed - 1n) * s.price / 10n ** 36n).toBe(625_002n);
  });
  it("keeps both maxima executable through a five-minute interest-only fresh read", () => {
    const s = snapshot();s.rate = 4_180_000_000n;
    s.projectedMarket = accrueMarket(s.market, 8_000_000_000n, s.timestamp + 300n);
    const borrow = safeBorrowMaximum(s), collateral = safeCollateralMaximum(s);
    const later = {...s, market: s.projectedMarket, account: {...s.account!,
      values: marketPositionValues(s.projectedMarket, s.account!.position, s.price)}};
    expect(borrow).toBeGreaterThan(0n);expect(collateral).toBeGreaterThan(0n);
    expect(withinMarketBuffer(postActionValues("borrow", borrow, false, later)!)).toBe(true);
    expect(withinMarketBuffer(postActionValues("withdrawCollateral", collateral, false, later)!)).toBe(true);
  });
  it("leaves new-debt interest headroom when a wallet has no existing debt", () => {
    const s = snapshot();s.account!.position.borrowShares = 0n;s.account!.values.borrowed = 0n;
    s.liquidity = 1_000_000n;
    const amount = safeBorrowMaximum(s), values = postActionValues("borrow", amount, false, s)!;
    expect(amount).toBeGreaterThan(0n);expect(amount).toBeLessThan(800_000n);
    expect(values.borrowed + maximumHorizonInterest(values.borrowed, s.projectionSeconds) + 2n).toBeLessThanOrEqual(800_000n);
  });
  it("keeps Max valid in 2,000 independently rounded future states, including changed share prices", () => {
    let seed = 99102026n;
    const random = (max: bigint) => {seed = (seed * 1664525n + 1013904223n) % (1n << 32n);return seed % max;};
    for (let i = 0; i < 2000; i++) {
      const s = snapshot();
      const assets = 1n + random(1_000_000_000n), shares = assets * 1_000_000n + random(999_999n);
      s.market.totalBorrowAssets = assets;s.market.totalBorrowShares = shares;
      s.market.totalSupplyAssets = assets + 2_000_000_000n;s.liquidity = 2_000_000_000n;
      s.account!.position.borrowShares = random(shares + 1n);
      s.account!.position.collateral = 2_000n * 10n ** 24n;
      s.price = 10n ** 18n + random(100_000_000_000_000_000n);
      s.account!.values = marketPositionValues(s.market, s.account!.position, s.price);
      // Independent upper-rate Taylor expansion, no production projection helper.
      s.projectionSeconds = 300n + random(163n);
      const x = 253_678_335_871n * s.projectionSeconds;
      const growth = x + x * x / (2n * 10n ** 18n) + (x * x / (2n * 10n ** 18n)) * x / (3n * 10n ** 18n);
      const interest = assets * growth / 10n ** 18n;
      s.projectedMarket = {...s.market, totalBorrowAssets: assets + interest, totalSupplyAssets: s.market.totalSupplyAssets + interest, lastUpdate: s.timestamp + s.projectionSeconds};
      const borrow = safeBorrowMaximum(s), withdrawal = safeCollateralMaximum(s);
      const retainedValue = (s.account!.position.collateral - withdrawal) * s.price / 10n ** 36n;
      const numerator = s.account!.position.borrowShares * (assets + interest + 1n);
      const futureDebt = (numerator + shares + 999_999n) / (shares + 1_000_000n);
      if (withdrawal > 0n) expect(futureDebt * 10_000n).toBeLessThanOrEqual(retainedValue * 8000n);
      if (borrow > 0n) {
        const minted = (borrow * (shares + 1_000_000n) + assets + interest) / (assets + interest + 1n);
        const n = (s.account!.position.borrowShares + minted) * (assets + interest + borrow + 1n), d = shares + minted + 1_000_000n;
        const actualDebt = (n + d - 1n) / d;
        expect(actualDebt * 10_000n).toBeLessThanOrEqual(s.account!.values.collateralValue * 8000n);
        const currentMinted = (borrow * (shares + 1_000_000n) + assets) / (assets + 1n);
        const futurePool = assets + borrow + (assets + borrow) * growth / 10n ** 18n;
        const poolShares = shares + currentMinted + 1_000_000n;
        const ownedNumerator = (s.account!.position.borrowShares + currentMinted) * (futurePool + 1n);
        const debtIfBorrowedNow = (ownedNumerator + poolShares - 1n) / poolShares;
        expect(debtIfBorrowedNow * 10_000n).toBeLessThanOrEqual(s.account!.values.collateralValue * 8000n);
      }
    }
  });
  it("allows all collateral only without debt, even at zero price", () => {
    const s = snapshot();s.price = 0n;expect(safeCollateralMaximum(s)).toBe(0n);
    s.account!.position.borrowShares = 0n;expect(safeCollateralMaximum(s)).toBe(10n ** 24n);
    s.account = null;expect(safeCollateralMaximum(s)).toBe(0n);
  });
  it("offers no collateral withdrawal when the existing debt is above the page buffer", () => {
    const s = snapshot();s.account!.values.borrowed = 900_000n;expect(safeCollateralMaximum(s)).toBe(0n);
  });
  it("quotes partial and share-based full repayments", () => {
    const s = snapshot();expect(postActionValues("repay", 100_000n, false, s)).toMatchObject({borrowed: 400_000n, ltvBps: 4000n});
    expect(postActionValues("repay", 0n, true, s)).toMatchObject({borrowed: 0n, ltvBps: 0n});
    expect(postActionValues("repay", 600_000n, false, s)).toBeNull();
  });
  it("rejects impossible previews without mutating the snapshot", () => {
    const s = snapshot();expect(postActionValues("withdrawCollateral", 10n ** 24n + 1n, false, s)).toBeNull();
    expect(postActionValues("borrow", -1n, false, s)).toBeNull();
    expect(s.market.totalBorrowAssets).toBe(500_000n);expect(s.account!.position.collateral).toBe(10n ** 24n);
    s.account = null;expect(postActionValues("borrow", 1n, false, s)).toBeNull();
  });
  it("agrees with an independent rational reference over 2,000 borrow states", () => {
    let seed = 10202026n;
    const random = (max: bigint) => {seed = (seed * 1664525n + 1013904223n) % (1n << 32n);return seed % max;};
    for (let i = 0; i < 2000; i++) {
      const s = snapshot(), assets = 1n + random(1_000_000_000n), shares = assets * 1_000_000n + random(10_000_000n);
      const owned = random(shares + 1n), amount = 1n + random(1_000_000n);
      s.market.totalBorrowAssets = assets;s.market.totalBorrowShares = shares;s.account!.position.borrowShares = owned;
      const added = (amount * (shares + 1_000_000n) - 1n) / (assets + 1n) + 1n;
      const numerator = (owned + added) * (assets + amount + 1n);
      const debt = (numerator - 1n) / (shares + added + 1_000_000n) + 1n;
      expect(postActionValues("borrow", amount, false, s)!.borrowed).toBe(debt);
    }
  });
});
