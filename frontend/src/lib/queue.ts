/**
 * Redemption-queue eligibility arithmetic.
 *
 * Extracted from RedeemCard so the FRV-FS-02 disclosure fix is pinned by VALUE tests
 * rather than by a substring grep over the component. The re-check's standing criticism
 * of the frontend remediations was that they were guarded only by `source.includes(...)`
 * assertions, which a future edit can step over while keeping the matched literals.
 *
 * The rule mirrors `RedemptionQueue.eligibleToSettleAt` and the settlement gate exactly:
 * a request may first settle at `requestedAt + redeemCooldown`, and settlement is blocked
 * while `block.timestamp < eligibleAt`. It is deliberately NOT the epoch heartbeat, which
 * is a separate and much shorter clock.
 */

/** First timestamp (unix seconds) at which a request may settle. */
export function eligibleAtSeconds(requestedAt: bigint, redeemCooldown: bigint): bigint {
  return requestedAt + redeemCooldown;
}

/**
 * Seconds still to wait before a request is first eligible, floored at zero.
 * `null` when the live cooldown has not loaded, callers must not substitute a default,
 * because understating the hold is the defect FRV-FS-02 was raised for.
 */
export function secondsUntilEligible(
  requestedAt: bigint,
  redeemCooldown: bigint | undefined,
  nowSeconds: number | null,
): number | null {
  if (redeemCooldown === undefined || nowSeconds === null) return null;
  const remaining = Number(eligibleAtSeconds(requestedAt, redeemCooldown)) - nowSeconds;
  return remaining > 0 ? remaining : 0;
}

/** True once the request has served its full hold. */
export function isEligible(
  requestedAt: bigint,
  redeemCooldown: bigint | undefined,
  nowSeconds: number | null,
): boolean {
  const remaining = secondsUntilEligible(requestedAt, redeemCooldown, nowSeconds);
  return remaining === 0;
}
