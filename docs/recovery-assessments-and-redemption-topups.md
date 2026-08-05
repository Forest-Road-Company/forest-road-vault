# Recovery assessments and redemption top-ups

> **Clean-v1 status (ADR-0030, 2026-07-24):** `AssessedImpairmentSource` is part of the
> clean deployment and wraps the revision-aware `DefaultManager`.
> `RecoveryTopUpDistributor` is optional source-only tooling: it is not deployed, wired,
> advertised, or promised for mainnet v1. The older Sepolia stack did deploy both tools;
> that historical test deployment is not the clean-v1 launch topology.

## What the queue price means

sUSDfr deposits mint at the realized vault NAV. Queue exits use a separate redemption NAV so an
investor cannot leave at an unimpaired price after a default is already known.

The default engine first calculates a zero-recovery case and applies protection in this order:

1. curator first-loss capital for the affected collateral class;
2. reachable sGROVE coverage; then
3. sUSDfr principal.

Only the third amount reduces the sUSDfr redemption NAV. Idle protocol reserves are not added to
the sUSDfr denominator: they also back unstaked USDfr, whose holders do not receive the credit
yield and are not the residual credit-loss tranche.

## Professional recovery assessment

Governance can publish a time-limited `assessedSeniorImpairment` through
`AssessedImpairmentSource`. The amount must be calculated from a signed professional recovery
memorandum:

1. estimate recoverable cash from collateral, remedies, guarantees, and the borrower;
2. subtract that recovery from the facility's outstanding principal;
3. apply the curator and sGROVE protection to the expected loss; and
4. submit only the residual loss expected to reach sUSDfr.

The contract rejects an assessed amount above the zero-recovery result. Every assessment includes
an evidence hash and expires within 30 days. Expiry automatically restores zero-recovery pricing.
This makes stale or missing judgment conservative.

Every assessment is also bound to the exact revisioned impairment snapshot standing when it is
published. A new declared default, past-due mark, recovery, realized loss, backstop change, or
change in curator/sGROVE capacity invalidates it immediately—even if equal-and-offsetting changes
leave the headline impairment amount unchanged. Pricing then uses the full live zero-recovery
result until governance publishes a new assessment backed by an updated memorandum.

The assessment can therefore change or become inactive before a queued request settles. The
frontend preview is an estimate at the current block, not a guaranteed settlement quote.

## Later top-ups

Mainnet v1 has no recovery-top-up contract. If actual recoveries are better than an assessment
used for an earlier fill, any later distribution requires a new governance/design decision,
funding source, legal review, deployment, and audit. The retained optional
`RecoveryTopUpDistributor` source illustrates a fully funded Merkle design, but no current user
has a contractual or on-chain entitlement to such a payment.

A future top-up, if separately approved and deployed:

- is discretionary and may never happen;
- is not included in `previewRedeem` or the amount shown at queue settlement;
- is not a claim against current sUSDfr holders;
- cannot be minted by the distributor;
- must be fully funded before the round is published; and
- cannot exceed the documented allocation in that round.

The operating team must publish the round's funding source, allocation file, evidence hash, and a
reconciliation from queue fill events to every payment. The cumulative amount allocated to a
request should never exceed its documented realized-NAV settlement discount, net of earlier
top-ups.

## Worked example

Suppose:

- defaulted outstanding is 6,000 USDfr;
- curator protection is 3,000 USDfr;
- reachable sGROVE protection is 1,500 USDfr; and
- sUSDfr vault assets are 21,100 USDfr.

At zero recovery, 1,500 USDfr reaches seniors and the redemption multiplier is approximately:

`(21,100 − 1,500) / 21,100 = 92.89%`

If a professional assessment instead supports 3,000 USDfr of recovery, expected gross loss is
3,000 USDfr. The curator layer covers it completely, so assessed senior impairment is zero and the
redemption haircut attributable to that default is zero.

That assessment is not a promise of recovery. If the final outcome is worse, the ordinary
curator → sGROVE → sUSDfr realized-loss cascade still applies.
