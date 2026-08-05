const BPS = 10_000n;

export function indicativeAnnualIncome(positionAssets: bigint, annualizedBps: bigint): bigint {
  return (positionAssets * annualizedBps) / BPS;
}

export function remainingDirectDepositBasis(
  depositedAssets: bigint,
  depositedShares: bigint,
  currentShares: bigint,
): bigint | null {
  if (currentShares === 0n) return 0n;
  if (depositedShares === 0n || currentShares > depositedShares) return null;
  return (depositedAssets * currentShares) / depositedShares;
}

export function formatBps(bps: bigint): string {
  const sign = bps < 0n ? "-" : "";
  const value = bps < 0n ? -bps : bps;
  return `${sign}${value / 100n}.${(value % 100n).toString().padStart(2, "0")}%`;
}
