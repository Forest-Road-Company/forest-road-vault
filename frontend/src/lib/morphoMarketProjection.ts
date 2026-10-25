import {ceilDiv, WAD} from "./morphoMarket";

export const REPAY_INTEREST_SECONDS = 300n;
export const MARKET_READ_TIMEOUT_MS = 15_000;
export const MARKET_FUTURE_SKEW_SECONDS = 30n;
// One Ethereum slot beyond expiry; not an on-chain deadline or an inclusion guarantee.
export const MARKET_EXECUTION_MARGIN_SECONDS = 12n;
export type MarketQuoteTiming = {issuedAt: number; expiresAt: number};

/** Quotes expire exclusively: the exact expiry instant already requires a fresh read. */
export function isMarketQuoteCurrent(quote: MarketQuoteTiming, now = Date.now()) {
  return Number.isSafeInteger(quote.issuedAt) && Number.isSafeInteger(quote.expiresAt)
    && Number.isSafeInteger(now) && quote.issuedAt >= 0
    && quote.expiresAt - quote.issuedAt === Number(REPAY_INTEREST_SECONDS) * 1_000
    && now >= quote.issuedAt && now < quote.expiresAt;
}

export function assertMarketQuoteCurrent(quote: MarketQuoteTiming, now = Date.now()) {
  if (!isMarketQuoteCurrent(quote, now)) throw new Error("Quote expired or its clock could not be verified. Refresh and review again before signing.");
}
// The pinned AdaptiveCurveIrm caps rateAtTarget at 200% APR and its curve at 4x.
// Round UP, unlike the contract's integer division. This is a bound, not a forecast.
// morpho-org/morpho-blue-irm: src/adaptive-curve-irm/libraries/ConstantsLib.sol.
export const MAX_MARKET_RATE = ceilDiv(8n * WAD, 31_536_000n);

/** Upper bound for NEW debt over the actual block-to-projection horizon, including rounding. */
export function maximumHorizonInterest(assets: bigint, projectionSeconds: bigint) {
  const first = MAX_MARKET_RATE * projectionSeconds;
  const second = first * first / (2n * WAD);
  const third = second * first / (3n * WAD);
  return ceilDiv(assets * (first + second + third), WAD);
}
