# ADR 0027 — Assessed recovery marks and discretionary redemption top-ups

**Status:** Accepted in principle by Forest Road (2026-07-23); deployed and smoke-tested on
Sepolia (2026-07-24). Mainnet deployment, recovery-valuation policy, funding policy, and legal
disclosure remain pre-mainnet review items. ADR-0029 separately defers the top-up distributor from
mainnet v1. This ADR refines ADR-0022's zero-recovery marking methodology; it does not change the
forced redemption cooldown or the three-layer loss cascade.

## Context

ADR-0022 initially treats every declared default as having zero recovery until cash is recovered or
a loss is realized. That is safe against loss-dodging, but it can be commercially over-conservative
for a long workout. On the exercised Sepolia fork, a 6,000 USDfr default was protected by 3,000
USDfr of curator first-loss and 1,500 USDfr of sGROVE capacity. The remaining 1,500 USDfr senior
mark was spread across approximately 21,100 USDfr of sUSDfr assets, producing an approximately
7.1% queue discount. The protocol's approximately 60,210 USDfr total backing was not the
denominator: idle reserves also back unstaked USDfr, which does not participate in credit yield or
the residual credit loss.

A professionally supported recovery estimate must be applied to the facility's gross expected
loss **before** the curator → sGROVE → sUSDfr waterfall. Multiplying the existing zero-recovery
senior impairment by a recovery percentage is wrong around junior-capital thresholds. For example,
if the expected loss on the 6,000 USDfr facility is 3,000 USDfr, the 3,000 USDfr curator layer
covers it and the correct senior impairment is zero—not 750 USDfr.

Some redeemers may nevertheless settle at a discount which later proves larger than the realized
loss. Forest Road wants the ability, but not an obligation, to make a separately funded
post-recovery payment to those redeemers.

## Decision

### 1. Time-limited governed assessment

`AssessedImpairmentSource` wraps both impairment views exposed by `DefaultManager`.
Governance may publish an absolute `assessedSeniorImpairment` denominated in 18-decimal USDfr,
calculated after professionally estimated recoveries and both junior layers.

- The assessment may only reduce the zero-recovery result.
- The assessment is bound to `DefaultManager.impairmentStateHash()` at publication. The hash
  includes a monotonic impairment revision plus all live declared-default, past-due and curator
  inputs, and the backstop wiring. Any new default or past-due mark, recovery, loss realization,
  backstop wiring change, or curator first-loss change makes the assessment inactive immediately.
- **Amended (FRV-FS-04):** reachable sGROVE capacity is NOT part of that hash. It is snapshotted
  alongside the assessment and compared directionally: a capacity DECREASE invalidates, a capacity
  INCREASE does not. `SGrove.fundCoverage` is permissionless, so folding capacity into an
  exact-match hash let any outside party void a depositor-favourable assessment with a dust
  donation. An increase is safe to tolerate because more junior protection can only make an
  already-published assessment more conservative than it needed to be.
- While the state hash matches, the live result is
  `min(assessedSeniorImpairment, currentZeroRecoveryImpairment)`. On any mismatch the live result is
  the full current zero-recovery impairment until governance publishes fresh evidence.
- **Amended by ADR-0031 round-2:** performance-fee accounting uses a separate impairment. On
  publication the wrapper snapshots
  `assessedSeniorImpairment + (basePerformanceFeeImpairment - currentZeroRecoveryImpairment)`.
  The second term is the junior-capital credit standing at publication. It prevents contributed
  curator/sGROVE capital from becoming fee profit while still allowing a supported recovery
  assessment to increase performance-fee NAV. An invalid, expired, cleared, or pre-upgrade
  assessment falls back to the base source's gross performance impairment.
- The monotonic revision is necessary even though the live amounts are hashed: equal-and-offsetting
  transitions can leave the aggregate impairment unchanged while changing the loans and protection
  to which the professional work applied.
- Each assessment commits to a non-zero hash of the signed recovery memorandum and supporting data.
- Each assessment expires after at most 30 days. If it is not refreshed, redemption pricing
  automatically returns to the zero-recovery result.
- Setting, clearing, and changing the base source are `DEFAULT_ADMIN_ROLE` actions intended for the
  governance timelock. A servicer or frontend cannot change the mark.
- `sUSDfr` consumes the wrapper through the narrow two-view `IImpairmentSource`; neither
  `DefaultManager`'s realized accounting nor the loss cascade is modified.

The submitted absolute senior amount is intentional. The professional workpaper should show:

`gross outstanding − assessed recovery = expected gross loss`

`expected gross loss − available curator protection − reachable sGROVE protection = assessed senior impairment`

with every subtraction floored at zero and each capacity reconciled to the same valuation timestamp.

### 2. Separately funded discretionary top-ups

`RecoveryTopUpDistributor` supports fully funded Merkle rounds. Each allocation leaf is bound to
the chain, distributor, round, RedemptionQueue request ID, recipient, and amount. Anyone may relay a
valid proof, but USDfr is transferred only to the recorded recipient. A bitmap prevents replay.
Unclaimed funds return to the round's recorded refund recipient only after the claim deadline.

The distributor:

- cannot mint USDfr;
- cannot withdraw from sUSDfr;
- cannot use queue claim balances;
- requires the full round amount to be transferred in before publication; and
- records both an allocation root and evidence hash.

This separation prevents a top-up from silently creating unbacked USDfr or shifting value from
current sUSDfr holders. Governance must identify and disclose the funding source for each round.

An allocation is discretionary, not an on-chain entitlement. Operationally, each request's
cumulative top-up should be capped at the difference between its realized-NAV value at each fill
and the USDfr actually paid, less previous top-ups. The published evidence package must reconcile
the root to `RedemptionRequested`, `RequestFilled`, `Claimed`, and prior top-up events.

## Required disclosure

Before staking and before requesting redemption, the frontend must disclose:

1. entry is priced at realized NAV while a queued exit uses the current assessed redemption NAV;
2. the assessment can change before the request settles and expires to the zero-recovery mark if
   it is not refreshed;
3. actual recovery may be higher or lower than the assessment; and
4. governance may later fund a top-up, but no top-up or airdrop is promised, automatic, or included
   in the displayed redemption value.

## Deployment and operating requirements

- Both contracts were deployed and exercised on Sepolia at block 11,339,762; do not treat that
  retained-admin testnet posture as a production template.
- Explorer source publication remains pending explicit authorization; on-chain bytecode parity was
  independently checked against the compiled source for both implementations.
- Upgrade/deploy the revision-aware `DefaultManager` first. `AssessedImpairmentSource.initialize`
  and `setBaseSource` reject an old amount-only source and require both redemption and
  performance-fee impairment views.
- Wire `sUSDfr.impairmentSource` to `AssessedImpairmentSource` and its revision-aware `baseSource`
  to `DefaultManager`. Changing the base source clears any existing assessment.
- Make the top-up distributor protocol-exempt in `ComplianceRegistry`; recipient transfers remain
  subject to USDfr's account-level compliance rules.
- Put assessment and round administration behind the timelock.
- Publish the recovery memorandum/evidence object before executing an assessment proposal.
- Publish the Merkle allocation file, proof generator, funding source, and reconciliation before
  creating a top-up round.

## Consequences

- A default no longer forces seniors to price the entire unresolved exposure at zero recovery when
  a current, governance-approved professional assessment supports a lower loss.
- Stale professional judgment fails safe to zero recovery on time expiry or immediately when the
  assessed risk snapshot changes.
- Temporary junior-capital changes may improve redemption pricing but cannot be booked as
  performance-fee profit. The assessment's fee-credit snapshot is append-only upgrade state;
  pre-field live assessments fail conservatively until governance republishes them.
- Former redeemers can receive later recovery upside without making that upside a guaranteed debt
  of the vault.
- Governance gains a material valuation power. Timelock delay, evidence publication, monitoring,
  and valuation-policy sign-off are therefore mainnet gates.
