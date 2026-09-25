export type OutstandingLoan = {
  outstandingPrincipal: bigint;
  interestRateBps: bigint;
  state: number;
};

export type BookYieldMetrics = {
  outstandingPrincipal: bigint;
  grossAnnualInterest: bigint;
  weightedAverageBps: bigint | null;
  performingPrincipal: bigint;
  performingGrossAnnualInterest: bigint;
  performingWeightedAverageBps: bigint | null;
  nonPerformingPrincipal: bigint;
};

export type FundedPrincipal = {
  classId: number;
  principal: bigint;
};

export type RealizedPrincipalLoss = {
  classId: number;
  loss: bigint;
};

export type HistoricalNetDefaultSlice = {
  fundedPrincipal: bigint;
  netLoss: bigint;
  rateBps: bigint | null;
};

export type HistoricalNetDefaultMetrics = HistoricalNetDefaultSlice & {
  byClass: ReadonlyMap<number, HistoricalNetDefaultSlice>;
};

export type CollateralPosition = {
  classId: number;
  originalPrincipal: bigint;
  ltvBps: bigint;
  outstandingPrincipal: bigint;
  valuation: bigint;
  valuationAsOf: bigint;
};

export type CollateralValueMetrics = {
  referenceValue: bigint;
  receivableReferenceValue: bigint;
  markedToMarketValue: bigint;
  outstandingPrincipal: bigint;
  coverageBps: bigint | null;
  complete: boolean;
  /** The oldest mark included past its class freshness window, or null when every included mark is fresh. */
  staleMarkAsOf: bigint | null;
};

/** A chain timestamp as `YYYY-MM-DD HH:MM UTC`, the site's display form. */
export function formatUtcMinute(seconds: bigint): string {
  return `${new Date(Number(seconds) * 1_000).toISOString().replace("T", " ").slice(0, 16)} UTC`;
}

const ACTIVE = 1;
const AMORTIZING = 2;
const BPS = 10_000n;
export const DIGITAL_ASSETS_CLASS_ID = 5;

type NamedFacilityEconomics = {
  interestRateBps?: number | bigint;
  state?: number | bigint;
};

type NamedFacilityCollateral = {
  classId?: number | bigint;
  principal?: number | bigint;
  ltvBps?: number | bigint;
};

type NamedClassParams = {
  maxMarkAge?: number | bigint;
};

/** viem normally returns fully named Solidity tuples as objects. A positional
 * fallback keeps the reader compatible with clients that expose tuple arrays. */
export function decodeFacilityEconomics(
  result: unknown,
): {interestRateBps: bigint; state: number} | null {
  if (!result || typeof result !== "object") return null;
  const named = result as NamedFacilityEconomics;
  const positional = result as readonly unknown[];
  const interestRateBps =
    named.interestRateBps ?? (Array.isArray(result) ? positional[5] : undefined);
  const state = named.state ?? (Array.isArray(result) ? positional[17] : undefined);
  if (
    (typeof interestRateBps !== "number" && typeof interestRateBps !== "bigint") ||
    (typeof state !== "number" && typeof state !== "bigint")
  ) {
    return null;
  }
  return {interestRateBps: BigInt(interestRateBps), state: Number(state)};
}

/** Decode the facility terms that define its collateral reference value. */
export function decodeFacilityCollateral(
  result: unknown,
): {classId: number; originalPrincipal: bigint; ltvBps: bigint} | null {
  if (!result || typeof result !== "object") return null;
  const named = result as NamedFacilityCollateral;
  const positional = result as readonly unknown[];
  const classId = named.classId ?? (Array.isArray(result) ? positional[0] : undefined);
  const principal =
    named.principal ?? (Array.isArray(result) ? positional[3] : undefined);
  const ltvBps = named.ltvBps ?? (Array.isArray(result) ? positional[4] : undefined);
  if (
    (typeof classId !== "number" && typeof classId !== "bigint") ||
    (typeof principal !== "number" && typeof principal !== "bigint") ||
    (typeof ltvBps !== "number" && typeof ltvBps !== "bigint")
  ) {
    return null;
  }
  return {
    classId: Number(classId),
    originalPrincipal: BigInt(principal),
    ltvBps: BigInt(ltvBps),
  };
}

/** Decode the ninth `ClassParams` field used to assess MTM mark freshness. */
export function decodeClassMaxMarkAge(result: unknown): bigint | null {
  if (!result || typeof result !== "object") return null;
  const named = result as NamedClassParams;
  const positional = result as readonly unknown[];
  const maxMarkAge =
    named.maxMarkAge ?? (Array.isArray(result) ? positional[8] : undefined);
  return typeof maxMarkAge === "number" || typeof maxMarkAge === "bigint"
    ? BigInt(maxMarkAge)
    : null;
}

/** Principal-weighted contractual rates. The performing rate excludes defaulted,
 * accelerated, repaid, resolved, cancelled, and still-pending facilities. */
export function calculateBookYield(loans: readonly OutstandingLoan[]): BookYieldMetrics {
  let outstandingPrincipal = 0n;
  let weightedRate = 0n;
  let performingPrincipal = 0n;
  let performingWeightedRate = 0n;

  for (const loan of loans) {
    if (loan.outstandingPrincipal <= 0n) continue;
    outstandingPrincipal += loan.outstandingPrincipal;
    weightedRate += loan.outstandingPrincipal * loan.interestRateBps;
    if (loan.state === ACTIVE || loan.state === AMORTIZING) {
      performingPrincipal += loan.outstandingPrincipal;
      performingWeightedRate += loan.outstandingPrincipal * loan.interestRateBps;
    }
  }

  return {
    outstandingPrincipal,
    grossAnnualInterest: weightedRate / BPS,
    weightedAverageBps:
      outstandingPrincipal === 0n ? null : weightedRate / outstandingPrincipal,
    performingPrincipal,
    performingGrossAnnualInterest: performingWeightedRate / BPS,
    performingWeightedAverageBps:
      performingPrincipal === 0n ? null : performingWeightedRate / performingPrincipal,
    nonPerformingPrincipal: outstandingPrincipal - performingPrincipal,
  };
}

/**
 * Indicative annual income available to sUSDfr at the current book shape:
 * contractual performing interest less the Waterfall interest fee. This is
 * deliberately BEFORE ADR-0031's global-HWM performance fee and time-based
 * management fee: those depend on protocol NAV/HWM/history and cannot be inferred
 * from facility coupons alone. ADR-0028 retired automatic DSRA funding, so no
 * senior income is withheld for a reserve.
 */
export function calculateProjectedSeniorIncome(
  loans: readonly OutstandingLoan[],
  protocolFeeBps: bigint,
): bigint {
  let projected = 0n;
  for (const loan of loans) {
    if (
      loan.outstandingPrincipal <= 0n ||
      (loan.state !== ACTIVE && loan.state !== AMORTIZING)
    ) {
      continue;
    }
    const gross = (loan.outstandingPrincipal * loan.interestRateBps) / BPS;
    const afterFee = (gross * (BPS - protocolFeeBps)) / BPS;
    projected += afterFee;
  }
  return projected;
}

/**
 * Gross collateral/reference value for currently outstanding facilities.
 *
 * Receivable classes do not have a continuously updated on-chain mark, so their
 * live reference value is the underwriting denominator implied by remaining
 * principal/LTV. Scaling the reference value down with amortization and write-downs
 * prevents displayed coverage from rising merely because the denominator fell.
 * Digital-assets collateral instead uses its latest m-of-n attested mark. A mark
 * past the class freshness window still stands until the next one arrives (owner
 * direction, 2026-09-24): it is included, and `staleMarkAsOf` carries its date so
 * the display says it is stale rather than presenting it as current. Only an
 * outstanding MTM facility with NO usable mark (never attested, zero, or dated in
 * the future) makes `complete` false, and then the aggregate must not be shown.
 * This is a display rule only: the protocol's margin path still requires a fresh mark.
 */
export function calculateCollateralValueMetrics(
  positions: readonly CollateralPosition[],
  now: bigint,
  markedToMarketMaxAge: bigint,
): CollateralValueMetrics {
  let receivableReferenceValue = 0n;
  let markedToMarketValue = 0n;
  let outstandingPrincipal = 0n;
  let complete = true;
  let staleMarkAsOf: bigint | null = null;

  for (const position of positions) {
    if (position.outstandingPrincipal <= 0n) continue;
    outstandingPrincipal += position.outstandingPrincipal;

    if (position.classId === DIGITAL_ASSETS_CLASS_ID) {
      const markIsUsable =
        position.valuation > 0n &&
        position.valuationAsOf > 0n &&
        position.valuationAsOf <= now;
      if (!markIsUsable) {
        complete = false;
        continue;
      }
      if (
        now - position.valuationAsOf > markedToMarketMaxAge &&
        (staleMarkAsOf === null || position.valuationAsOf < staleMarkAsOf)
      ) {
        staleMarkAsOf = position.valuationAsOf;
      }
      markedToMarketValue += position.valuation;
      continue;
    }

    if (position.outstandingPrincipal < 0n || position.ltvBps <= 0n) {
      complete = false;
      continue;
    }
    receivableReferenceValue +=
      (position.outstandingPrincipal * BPS) / position.ltvBps;
  }

  const referenceValue = receivableReferenceValue + markedToMarketValue;
  return {
    referenceValue,
    receivableReferenceValue,
    markedToMarketValue,
    outstandingPrincipal,
    coverageBps:
      complete && outstandingPrincipal > 0n
        ? (referenceValue * BPS) / outstandingPrincipal
        : null,
    complete,
    staleMarkAsOf,
  };
}

/**
 * Historical realized credit loss, net of principal recovered before write-off.
 *
 * `WaterfallEngine.Funded` supplies the denominator: principal that actually
 * left reserves and became credit exposure. `DefaultManager.LossRealized.loss`
 * supplies the numerator: principal ultimately written off after any recovery
 * cash was first processed through the waterfall. A fully cured default
 * therefore contributes zero; an unresolved default is not presented as a
 * historical loss before its outcome is known.
 */
export function calculateHistoricalNetDefaultMetrics(
  funded: readonly FundedPrincipal[],
  losses: readonly RealizedPrincipalLoss[],
  classIds: readonly number[],
): HistoricalNetDefaultMetrics {
  const fundedByClass = new Map<number, bigint>();
  const lossByClass = new Map<number, bigint>();
  let fundedPrincipal = 0n;
  let netLoss = 0n;

  for (const item of funded) {
    if (item.principal < 0n) throw new Error("funded principal cannot be negative");
    fundedPrincipal += item.principal;
    fundedByClass.set(
      item.classId,
      (fundedByClass.get(item.classId) ?? 0n) + item.principal,
    );
  }
  for (const item of losses) {
    if (item.loss < 0n) throw new Error("realized loss cannot be negative");
    netLoss += item.loss;
    lossByClass.set(
      item.classId,
      (lossByClass.get(item.classId) ?? 0n) + item.loss,
    );
  }

  const allClassIds = new Set([
    ...classIds,
    ...fundedByClass.keys(),
    ...lossByClass.keys(),
  ]);
  const byClass = new Map<number, HistoricalNetDefaultSlice>();
  for (const classId of allClassIds) {
    const classFunded = fundedByClass.get(classId) ?? 0n;
    const classLoss = lossByClass.get(classId) ?? 0n;
    byClass.set(classId, {
      fundedPrincipal: classFunded,
      netLoss: classLoss,
      rateBps: classFunded === 0n ? null : (classLoss * BPS) / classFunded,
    });
  }

  return {
    fundedPrincipal,
    netLoss,
    rateBps: fundedPrincipal === 0n ? null : (netLoss * BPS) / fundedPrincipal,
    byClass,
  };
}
