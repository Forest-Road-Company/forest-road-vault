# ADR-0016 — Participation points: on-chain activity only, time-weighted, per wallet

**Status:** Resolved (Forest Road direction, 2026-07-14; frontend completion
2026-07-24). Parameters are governance-tunable. The program remains an explicit
pre-mainnet securities-counsel review item.

## Decision

`PointsModule` is a non-transferable, fully on-chain participation ledger. It measures
actual capital participation in the protocol. It is not a token, a claim on a token,
yield, or a promise of future value.

Points come exclusively from real on-chain balances and elapsed block time:

- sUSDfr shares held by a wallet: 1× the base rate;
- USDfr held by a wallet: governance-set multiple, initially 3×, in lieu of the
  variable vault income received by sUSDfr;
- curator first-loss capital posted by a wallet, tracked per collateral class:
  governance-set multiple, initially 5×.

There are no manual awards, discretionary credits, administrative backdating, imported
off-chain balances, transaction-count bonuses, referral points, or volume rewards.
`reconcile(wallet)` may only repair the ledger to the wallet's actual live token and
curator balances after a fail-open hook miss. It cannot set accrued points, choose a
historical start date, or grant a balance the wallet does not hold on-chain.

## Accrual formula

Each position accrues:

```text
points = (balance / unit)
       × integral(maturity multiplier over elapsed time)
       × rate active during each rate epoch
       × source multiplier
```

The units are one whole sUSDfr share (24 decimals) or one whole USDfr/curator USDfr
(18 decimals). The maturity multiplier rises linearly from 1× to 2× over 365 days and
then remains capped at 2×.

The module evaluates pending points lazily in its views. A user does not need to send a
checkpoint transaction for elapsed time to appear in `pointsOfWallet` or
`pointsBreakdown`.

### Position maturity

- Opening a zero-balance position starts its maturity clock at the current block
  timestamp.
- Adding capital blends the existing and new timestamps by balance weight, so a small
  seasoned balance cannot age a large new deposit.
- Removing capital leaves the surviving balance's maturity start unchanged.
- Moving seasoned capital to a fresh wallet starts a new maturity clock for the
  receiving position.

## Per-wallet, flat-linear accounting

The v1 identity-keyed, concave-tier design was abandoned on 2026-07-14. Points v2 is
permissionless and per wallet: no KYC or identity binding is required to accrue.

The balance function is flat and linear. Splitting equally aged capital across wallets
cannot increase the base accrual. Moving an existing position to fresh wallets can only
reduce forward accrual because each receiving position restarts at the bottom of the
maturity ramp. The system does not claim to prove that several wallets belong to one
person; it makes wallet splitting economically non-accretive instead.

## Forward-only governance changes

`setRate`, `setUSDfrMultiplier`, and `setCuratorMultiplier` append rate epochs.
Previously elapsed time is integrated under the parameters then in force; a new setting
cannot retroactively reprice an uncheckpointed wallet.

Rates and multipliers are bounded in-contract. Governance can change future accrual
economics but cannot edit a wallet's accrued total.

## Hooks, liveness, and reconciliation

USDfr, sUSDfr, and CuratorModule report balance changes to PointsModule. Token hooks are
fail-open: a points-module failure must never block a transfer, deposit, redemption, or
loss cascade.

Because fail-open accounting can miss a transition, `reconcile(wallet)` is permissionless.
It:

1. accrues the wallet to the current point under its existing tracked position;
2. reads the wallet's live USDfr and sUSDfr balances;
3. reads its live posted curator capital in each class;
4. moves tracked balances to those exact live values.

This is a repair path, not a grant path. Newly discovered capital starts or blends its
maturity at reconciliation time; reconciliation never invents historical activity.

## Curator losses

Curator points represent live first-loss capital, not the amount originally posted.
When a class absorbs a loss, every affected curator position freezes at the loss
timestamp. The class survival ratio writes cached capital down pro rata. Accrual resumes
only after `reconcile(wallet)` confirms the curator's live post-loss position.

This prevents destroyed capital, or replacement capital posted after a loss, from
continuing with an unjustified mature points clock.

## Frontend and indexing

The `/points` dashboard reads `pointsOfWallet`, `pointsBreakdown`, tracked balances,
live rate parameters, and per-class curator state directly from PointsModule. It shows
the connected wallet's complete existing on-chain history; opening the page neither
starts nor modifies accrual.

A global leaderboard is not a contract view because PointsModule does not enumerate
wallets. Publishing one requires an event indexer that discovers participants and
reconciles every displayed total to the canonical contract view. No manually maintained
leaderboard is permitted.

## Binding framing

Every surface must state:

- points measure participation;
- points are not transferable;
- points are not a token, security, yield, or claim on one;
- there is no conversion rate, distribution date, or promised allocation;
- any proposed future utility is discretionary and subject to counsel review.

## Alternatives considered

- Identity-keyed concave tiers: rejected in the v2 redesign because the tiers rewarded
  identity splitting and made KYC uniqueness economically load-bearing.
- Manual/off-chain awards: rejected because they are not independently reproducible from
  protocol activity.
- Transaction or volume rewards: rejected because they reward churn and wash activity.
- Transferable points token: rejected because transferability would create a separate
  asset and materially change the legal and security surface.
- Mandatory hooks: rejected because points accounting must never compromise core asset
  liveness.

## Consequences

- The PointsModule contract remains the sole source of truth.
- Historical wallet totals already accrued on-chain are preserved and surfaced as-is.
- No deployment migration is needed merely to launch the connected frontend.
- A future binding token allocation would be a separate tokenomics, legal, governance,
  and security decision; this ADR does not authorize one.
