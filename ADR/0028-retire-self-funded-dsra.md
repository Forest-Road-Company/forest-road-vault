# ADR 0028 — Retire the self-funded DSRA

> **SUPERSEDED FOR CLEAN MAINNET V1 BY ADR-0030 (2026-07-24):** mainnet has no
> legacy balances to unwind, so all DSRA storage, events and call paths are removed
> rather than retained dormant. This ADR remains the history of the Sepolia transition.

**Status:** Accepted (Forest Road direction, 2026-07-24). Supersedes the automatic
DSRA-funding and borrower-refund policy in ADR-0017. Legacy custody functions remain only
for upgrade-safe unwind of balances created before this decision.

## Context

The original interest waterfall sent gross interest through:

`protocol fee → facility DSRA top-up → sUSDfr`

The DSRA was not funded by separate borrower capital. It was minted from the same
post-fee interest that otherwise belonged to sUSDfr holders. A later DSRA draw returned
that already-realized income to the vault, while an unused residual could be refunded to
the borrower after close.

This did not add loss-bearing capital. It made senior holders forgo income now for
potential income later, introduced servicer discretion and custody complexity, and could
return unused senior economics to the borrower. Curator capital and sGROVE already cover
credit-loss severity; sUSDfr is explicitly variable-yield and does not promise a fixed
periodic coupon. ADR-0023 retains optional realized-income smoothing, but launch uses
instant recognition and Pendle does not require a stream.

## Decision

1. New interest distributions route:

   `gross interest → protocol fee → sUSDfr`

   `WaterfallEngine.Distributed.dsraTopUp` remains in the event for ABI and historical
   compatibility but is always zero.
2. `WaterfallEngine.dsraTarget()` always returns zero. All five launch class tuples set
   `dsraMonths = 0`, and deployment validation fails if any genesis tuple differs.
3. `ReserveManager`'s DSRA storage and the existing `serviceFromDSRA` /
   `refundDSRA` selectors remain in place so an upgrade cannot strand pre-existing
   escrow or break storage/ABI compatibility. They are legacy unwind paths, not an active
   product feature. `WaterfallEngine.refundDSRA` now requires the destination to be the
   sUSDfr vault and notifies the configured yield-recognition path.
4. During migration, operations route every live-facility balance to sUSDfr with
   `serviceFromDSRA`. Any residual on an already closed facility must use the vault-bound
   `refundDSRA`; legacy escrow can never be returned to a borrower after the upgrade.
5. The frontend's projected senior income is contractual performing interest less the
   protocol fee only; it no longer subtracts an unfunded DSRA target.

## Consequences

- Senior holders receive every post-fee unit of realized interest.
- No new USDfr is escrowed as DSRA and no new servicing dependency is created.
- Existing DSRA accounting remains test-covered until every deployed legacy balance is
  zero.
- A future independently borrower-funded reserve would require a new ADR, explicit legal
  ownership of the residual, a distinct funding path, and fresh economic/security review.
- Upgrade order for an existing deployment: set every class's `dsraMonths` to zero,
  upgrade `WaterfallEngine`, drain all legacy balances to senior, verify every
  `dsraOf == 0` and `dsraTarget == 0`, then process a test payment and prove
  `interest == fee + toVault`.
