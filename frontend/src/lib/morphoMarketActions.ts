import {ceilDiv, marketPositionValues, ORACLE_SCALE, type MarketAction} from "./morphoMarket";
import type {MorphoMarketSnapshot} from "./morphoMarketReader";
import {maximumHorizonInterest} from "./morphoMarketProjection";
export {REPAY_INTEREST_SECONDS} from "./morphoMarketProjection";

export const MARKET_BUFFER_LTV_BPS = 8_000n;
const BPS = 10_000n;
const VIRTUAL_SHARES = 1_000_000n;

/** Exact forward IRM view on the pinned stored state, plus two raw USDC rounding units.
 * Other market transactions, a price change or a longer delay still require a fresh quote. */
export function repaymentQuote(s: MorphoMarketSnapshot) {
  if (!s.account || s.account.position.borrowShares === 0n) return {required: 0n, approval: 0n};
  const required = marketPositionValues(s.projectedMarket, s.account.position, s.price).borrowed + 2n;
  // The EOA gate uses required, NOT this moving approval ceiling (S1020M-m1-01).
  return {required, approval: ceilDiv(required * 1001n, 1000n)};
}

/** Exact share rounding for an estimated post-action position at the quoted block. */
export function postActionValues(action: MarketAction, amount: bigint, all: boolean, s: MorphoMarketSnapshot) {
  if (!s.account || amount < 0n) return null;
  const market = {...s.market};
  const position = {...s.account.position};
  if (action === "borrow") {
    const shares = ceilDiv(amount * (market.totalBorrowShares + VIRTUAL_SHARES), market.totalBorrowAssets + 1n);
    market.totalBorrowAssets += amount;
    market.totalBorrowShares += shares;
    position.borrowShares += shares;
  } else if (action === "withdrawCollateral") {
    if (amount > position.collateral) return null;
    position.collateral -= amount;
  } else if (action === "repay") {
    const shares = all ? position.borrowShares
      : amount * (market.totalBorrowShares + VIRTUAL_SHARES) / (market.totalBorrowAssets + 1n);
    if (shares > position.borrowShares) return null;
    const assets = all ? s.account.values.borrowed : amount;
    market.totalBorrowAssets -= assets;
    market.totalBorrowShares -= shares;
    position.borrowShares -= shares;
  }
  return marketPositionValues(market, position, s.price);
}

export function withinMarketBuffer(values: NonNullable<ReturnType<typeof postActionValues>>) {
  return values.borrowed * BPS <= values.collateralValue * MARKET_BUFFER_LTV_BPS;
}

/** Retain 80% LTV against forward debt without credit for oracle drift. */
export function safeCollateralMaximum(s: MorphoMarketSnapshot) {
  const a = s.account;
  if (!a) return 0n;
  if (a.position.borrowShares === 0n) return a.position.collateral;
  if (s.price === 0n) return 0n;
  const debt = max(a.values.borrowed, repaymentQuote(s).required);
  const valueNeeded = ceilDiv(debt * BPS, MARKET_BUFFER_LTV_BPS);
  const collateralNeeded = ceilDiv(valueNeeded * ORACLE_SCALE, s.price);
  return a.position.collateral > collateralNeeded ? a.position.collateral - collateralNeeded : 0n;
}

/** Include forward existing debt, new debt's ceiling-rate interest and share rounding. */
export function safeBorrowMaximum(s: MorphoMarketSnapshot) {
  const a = s.account;
  if (!a) return 0n;
  const forwardDebt = max(a.values.borrowed, repaymentQuote(s).required);
  const capacity = a.values.collateralValue * MARKET_BUFFER_LTV_BPS / BPS - forwardDebt;
  let low = 0n;
  let high = capacity < s.liquidity ? capacity : s.liquidity;
  if (high <= 0n) return 0n;
  while (low < high) {
    const middle = (low + high + 1n) / 2n;
    const values = postActionValues("borrow", middle, false, s)!;
    // Forward existing debt covers idle-market adaptation. The second buffer covers
    // interest on the whole post-borrow debt (including new assets) at the IRM ceiling.
    // Two extra raw units cover a share-rounding boundary between the two reads.
    const borrowed = values.borrowed + forwardDebt - a.values.borrowed + maximumHorizonInterest(values.borrowed, s.projectionSeconds) + 2n;
    if (withinMarketBuffer({...values, borrowed})) low = middle;
    else high = middle - 1n;
  }
  return low;
}

function max(a: bigint, b: bigint) {return a > b ? a : b;}
