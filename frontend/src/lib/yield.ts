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

export type ShareBasisEvent =
  | {kind: "deposit"; blockNumber: bigint; logIndex: number; assets: bigint; shares: bigint}
  | {kind: "transfer_in"; blockNumber: bigint; logIndex: number; shares: bigint}
  | {kind: "transfer_out"; blockNumber: bigint; logIndex: number; shares: bigint};

export type ShareBasisState = {
  trackedShares: bigint;
  trackedBasis: bigint;
  hasExternalShareTransfer: boolean;
};

export const INITIAL_SHARE_BASIS_STATE: ShareBasisState = {
  trackedShares: 0n,
  trackedBasis: 0n,
  hasExternalShareTransfer: false,
};

/**
 * Chronological share-lot tracker for direct-deposit basis.
 *
 * Processes deposits, external incoming transfers, and outgoing transfers (including burns and
 * redemption-queue lockups) in `(blockNumber, logIndex)` order:
 *  - Deposits add `(assets, shares)` to the running basis pool.
 *  - Outgoing transfers reduce the basis pool proportionally; whenever the tracked balance reaches
 *    zero, both basis and `hasExternalShareTransfer` reset cleanly so subsequent fresh direct
 *    deposits are not distorted by earlier exited positions.
 *  - Non-mint incoming transfers (or unmatched mints without a `Deposit`) mark
 *    `hasExternalShareTransfer = true` until the position fully exits to zero.
 */
export function applyShareBasisEvents(
  initial: ShareBasisState,
  events: readonly ShareBasisEvent[],
): ShareBasisState {
  const ordered = [...events].sort((a, b) =>
    a.blockNumber === b.blockNumber
      ? a.logIndex - b.logIndex
      : a.blockNumber < b.blockNumber
        ? -1
        : 1,
  );
  let trackedShares = initial.trackedShares;
  let trackedBasis = initial.trackedBasis;
  let hasExternalShareTransfer = initial.hasExternalShareTransfer;

  for (const event of ordered) {
    if (event.kind === "deposit") {
      if (event.shares <= 0n) continue;
      trackedShares += event.shares;
      trackedBasis += event.assets;
      continue;
    }
    if (event.kind === "transfer_in") {
      if (event.shares <= 0n) continue;
      trackedShares += event.shares;
      hasExternalShareTransfer = true;
      continue;
    }
    if (event.shares <= 0n) continue;
    if (trackedShares === 0n || event.shares >= trackedShares) {
      trackedShares = 0n;
      trackedBasis = 0n;
      hasExternalShareTransfer = false;
      continue;
    }
    const remainingShares = trackedShares - event.shares;
    trackedBasis = (trackedBasis * remainingShares) / trackedShares;
    trackedShares = remainingShares;
  }

  return {trackedShares, trackedBasis, hasExternalShareTransfer};
}

/**
 * Returns the remaining direct-deposit cost basis for `currentShares`, or `null` when an active
 * external share transfer or balance mismatch prevents an honest basis calculation.
 */
export function walletDirectDepositBasis(
  state: ShareBasisState,
  currentShares: bigint,
): bigint | null {
  if (currentShares === 0n) return 0n;
  if (state.hasExternalShareTransfer) return null;
  if (state.trackedShares !== currentShares) return null;
  return state.trackedBasis;
}

export function formatBps(bps: bigint): string {
  const sign = bps < 0n ? "-" : "";
  const value = bps < 0n ? -bps : bps;
  return `${sign}${value / 100n}.${(value % 100n).toString().padStart(2, "0")}%`;
}
