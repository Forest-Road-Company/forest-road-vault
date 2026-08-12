# Invariant Specification — Forest Road Vault

**Audience:** external auditors and reviewers. **Status:** the properties below are the
normative clean-mainnet-v1 safety specification. Their named Foundry suites must pass at
the configured heavy profile before release (`heavy`: 10k fuzz runs; invariant runs
≥ 512, depth ≥ 256). This document is
the protocol's **safety spec** — it maps each property in CLAUDE.md §1.3 to (a) the
mechanism that enforces it on-chain and (b) the named test(s) that prove it.

Run: `FOUNDRY_PROFILE=heavy forge test` (from `contracts/`). Release evidence and exact
counts are recorded in the dated pre-mainnet security report.

> Convention: an invariant is a property that must hold **across all reachable states**.
> If one cannot be made to hold, that is a genuine-problem STOP — we surface it rather
> than weaken the assertion (CLAUDE.md §1.3, §4.5).

---

## 1. Backing invariant (ADR-0012)

**Property.** `USDfr.totalSupply()` ≤ backing value, always, where backing =
internally accounted idle USDC at par + deployed facility principal. No reserve
instrument or direct token donation can increase backing.

**Enforcement.** Every supply-increasing path asserts backing *after* the mint:
`MintRedeemController.mint` (`_assertBacking`), `WaterfallEngine._routeInterest` /
`fund` (each `mintYield` is checked; the interest==0 principal leg calls
`backingInvariantHolds()` explicitly — audit R1 fix). Supply-decreasing paths (burn,
loss) can only *improve* the ratio. There is no mint entrypoint that skips the assertion.

**Tests and symbolic checks.** `invariant_backing_supplyNeverExceedsBacking`
(CreditInvariants, TokenLayerInvariants), `invariant_backing_holdsThroughQueueTraffic`
(RedemptionQueueInvariants), `invariant_supply_fullyAccounted`, and the five Halmos
properties in `test/symbolic/BackingSymbolic.t.sol`. Four symbolic properties execute
the real controller/reserve implementations through proxies; the user mint/redeem
equal-delta identity is a full-domain arithmetic lemma whose production binding remains
covered by unit, fork, and differential stateful tests. The scope and trust boundary are
spelled out in `docs/formal-methods-amenability.md`.

## 2. Value conservation in the waterfall

**Property.** Every distributed repayment is fully and correctly allocated —
`fee + toVault == interest` and the principal leg reduces deployed principal
exactly; nothing is created or destroyed; senior (`sUSDfr`) is never subordinated to
junior (curator).

**Enforcement.** `_routeInterest` splits by construction. `distribute` spends a
single-use `PaymentReceived` attestation committing to the exact payment id, facility,
USDC asset, payer, cash amount, interest, principal, and next due date. The reserve
manager pulls that exact USDC receipt and updates cash/principal accounting atomically;
the transaction reverts if the transfer or any accounting leg differs. The later
ADR-0031 performance/management fees do not alter this cash conservation equation:
they mint `sUSDfr` shares and leave every backing asset in the vault.

**Tests.** `invariant_waterfall_conservesValue`, `invariant_reserves_and_pools_reconcile`.

## 3. Loss-cascade ordering (three-layer)

**Property.** Losses absorb **curator first-loss → sGROVE backstop → sUSDfr depositor
principal**, in that order, never skipping or inverting a layer.

**Enforcement.** `DefaultManager.realizeLoss` consults the layers in fixed sequence:
`curator.absorbLoss` (layer 1) → `sGrove.coverShortfall` on the residual (layer 2, with a
strict `received == covered` equality check — audit R1 fix L) → depositor burn on what
remains (layer 3), then the write-down is paired atomically with the burns so the backing
assertion never observes an intermediate violation. ADR-0035 bounds layer two only by its live
USDfr reserve: one shortfall can exhaust it, after which senior principal absorbs every subsequent
loss until real USDfr replenishes the reserve. The cascade path is **never pausable**.

**Tests and symbolic checks.** `invariant_cascade_orderingHolds`,
`invariant_curator_subordinationRespected`, and
`test/symbolic/CascadeSymbolic.t.sol` (nine Halmos paths over the full arithmetic
domain, with the model-to-production binding supplied by differential stateful tests).

## 4. NFT mint gate

**Property.** A Loan NFT cannot mint unless **all** required attestation kinds for its
class are satisfied AND on-chain conditions hold; escrow release is contractually
conditioned on the NFT's existence.

**Enforcement.** `ClaimBridge.originate` iterates the class's `requiredMintAttestations`
bitmask and requires each kind satisfied for the new `tokenId`. High-value kinds
(CreditIssued, PaymentReceived, DefaultDeclared, Valuation, LossRealized,
PastDueCured, TermsAmended) require **m-of-n ≥ 2**
attester signatures (audit R3 SM-1/SM-2 hardening); the deployed receivable masks include
CreditIssued so a single attester cannot satisfy the gate.

**Tests.** `invariant_mintGate_neverBypassed`.

## 5. Redemption queue

**Property.** The queue never distributes more than available liquidity; FIFO ordering
holds; no double-claim.

**Enforcement.** Epoch FIFO by `requestId`; `head` advances only on a full fill;
settlement is bounded by a snapshotted budget (rounding always favors the pool);
`assetsClaimable` is zeroed before transfer (no double-claim); a guardian pause blocks
new requests and settlement but does not block claiming already-settled assets; dust requests that convert
to 0 assets are rejected (audit R3 N-1); a zero-distribution settlement with requests
queued reverts rather than consuming the epoch (audit R2 A1 — anti-DoS).

**Tests.** `invariant_queue_fifoHolds`, `invariant_queue_custodyReconciles`,
`invariant_exchangeRate_neverFallsFromQueueOps`.

## 6. Concentration limits

**Property.** Per-vertical / per-state / per-borrower limits are an **admission control**,
not a continuous cap (corrected by AUDIT FIX M-02 — the previous wording implied a standing
property the protocol cannot deliver). Precisely:

**The rule, in one sentence.** No exposure increase may leave the class, borrower or state
it touches holding more than its `limitBps` share of **`max(post-trade book,
concentrationFloor)`**.

1. **No admission into breach, and no deepening of one.** Both follow from the single rule
   above, at every book size and every floor setting. An origination can neither create a
   fresh breach on a mature book nor add anything to a dimension already standing above its
   limit.
2. **The bootstrap floor is a floor on the ASSUMED BOOK SIZE, not an exemption.** A young
   book (whose first facility is 100% of it) must not be self-blocking, so the limits
   measure against the floor while the real book is smaller. That still caps every
   dimension in ABSOLUTE terms at `limitBps * floor / BPS` — at the launch defaults,
   8.75m per 3500bps class, 3.75m per borrower and 6.25m per state against a 25m floor.
   The rule is continuous at the floor and monotone in the amount added, so
   `concentrationHeadroom` is its exact inverse. (Round-1 of AUDIT FIX M-02 keyed the
   exemption on the BUCKET instead, which left the enforcement inert at the shipped floor
   and let an origination create a fresh breach on a mature book. That is corrected.)
3. **No silent breach.** A dimension that crosses its limit is disclosed on-chain:
   `ConcentrationDrift`/`ConcentrationHealed` for classes and
   `BorrowerConcentrationDrift`/`Healed`, `StateConcentrationDrift`/`Healed` for the other
   two dimensions, plus `isOverConcentrated`, `overConcentratedClasses`,
   `overConcentratedBorrowers`, `overConcentratedStates`, `classConcentrationBps` and
   `concentrationHeadroom`. The breach views RECOMPUTE from the book on every read, so an
   implementation upgrade whose appended cache slots read zero cannot make a standing
   breach invisible; the permissionless `syncConcentrationBreaches` publishes the
   corresponding events without waiting for the next exposure change.
   Known limits of the event channel, stated plainly: the borrower/state key sets are not
   enumerable on-chain, so a drift caused by a party the transaction does not touch is
   evented only when someone calls `syncConcentrationBreaches` with that id (the key set
   itself is recoverable from `ExposureRecorded`). The breach views are floor-independent
   and therefore read "over limit" for an ordinary young book; the drift events carry
   `bookAboveFloor` so alerting can filter bootstrap from a genuine incident.

**Why not a continuous cap.** Exposure falls through repayment, default write-down and the
retirement of an unfunded facility (`ClaimBridge.cancelPending`). A shrinking book
mechanically raises the share held by whatever did not shrink, so the book **can stand**
above a limit. None of those decreases may ever be blocked: a concentration check able to
revert `realizeLoss` would let a risk limit veto a loss being realized, inverting the
three-layer loss cascade (§3). A redemption never touches the registry at all. Healing an
over-concentrated book is therefore a governance/origination action (grow the book
elsewhere), not something the contract can force.

**Enforcement.** `CollateralRegistry._checkConcentration` on every increase;
`recordExposureDecrease` keeps the ledger exact and reports (never blocks). The breach
sweep on the decrease path uses a 512-bit intermediate (`Math.mulDiv`) and does no
division, so it is arithmetically incapable of reverting — a concentration check must never
be able to block `realizeLoss`. `checkConcentration` rejects an absurd principal with
`Registry_PrincipalTooLarge` rather than an arithmetic panic, and `concentrationHeadroom`
never returns a value the admission path would panic on.

**Governance caveat (open).** `concentrationFloor` is a timelocked
`DEFAULT_ADMIN_ROLE` parameter bounded only against arithmetic overflow. Within that
bound, raising it raises every dimension's absolute allowance on a book below it — the same
class of power as raising `concentrationLimitBps` via `setClass`. What it can no longer do
is switch the relative limits off on a book above it. The launch value (25,000,000e18) is a
placeholder pending the pre-mainnet economic review (brief Part 11 gate 5).

**Tests.** `invariant_concentration_limitsHold`, `invariant_exposure_reconciles`,
`invariant_m02_breachBitmapMatchesTheBook`, `invariant_m02_overLimitDimensionCannotBeGrown`,
`invariant_m02_headroomIsAdmissible`, and `test/audit/Fix_M02-concentration-drift.t.sol`.

## 7. sUSDfr fee-net exchange-rate integrity

**Property.** Absent credit loss or a protocol fee becoming economically due, the
fee-net `sUSDfr` exchange rate does not decrease from yield accrual alone. Credit
losses enter **only** via the cascade. Due management/performance fees are reflected
deterministically in read previews and are minted only through explicit ADR-0031 events.

**Enforcement.** Launch yield arrives as USDfr minted into the vault and is recognized
immediately (rate up); optional governance-enabled vesting may delay that rise but cannot
create a fall. A cascade burn is paired with a recorded loss. ERC-4626 conversions simulate the management and
performance shares due at the current timestamp, so a quote immediately before a
checkpoint matches the post-checkpoint state; the later
`ManagementFeeAccrued` / `PerformanceFeeAccrued` mint leaves vault assets unchanged and
must not create a second price jump. With management enabled, the fee-net view may
decline predictably as time elapses before the event. The ERC-4626 exit is queue-only
(`maxWithdraw`/`maxRedeem` return 0 for everyone except the RedemptionQueue), and all
queue entry/settlement/exit paths checkpoint before pricing.

**Tests.** `invariant_exchangeRate_neverFallsWithoutLossOrFee`,
`invariant_exchangeRate_neverFallsFromQueueOps`, plus
`test/unit/SUSDfrFees.t.sol`.

> **Known limits of these tests — read before relying on them (ADR-0031, 2026-07-30).**
> Neither invariant currently enforces this property tightly, and the record should not
> imply otherwise.
> - `invariant_exchangeRate_neverFallsWithoutLossOrFee` grants a flat
>   `1 - performanceFeeBps` slack whenever a performance fee is due. That constant is
>   *tight* for a single checkpoint (the single-checkpoint fall is exactly
>   `feeAssets / (redemptionTotalAssets() + 1)`); what it absorbs is the compounding of
>   several checkpoints inside one ghost-floor epoch. Two attempts to narrow it to the
>   accepted regime were made and abandoned — both turned a green campaign red against a
>   baseline green at 256 runs / 32,768 calls.
> - `invariant_exchangeRate_neverFallsFromQueueOps` re-anchors its own floor to the
>   post-action rate as the last state-touching statement of every registered selector, so
>   at the launch configuration it reduces to a trivially true comparison. The real check
>   lives per-call inside the handler; the top-level assertion makes no cross-call statement.
> - Any correct in-code bound must anchor to a value captured BEFORE an impairment release.
>   On a full cure `performanceFeeImpairment()` reads zero at the moment the invariant
>   evaluates, so a gate keyed on it is defeated by the very transition that moved the rate.
>
> Until that work lands, the operative control for the accepted denomination residual is
> external monitoring — an alert on any release of `performanceFeeImpairment()` — not this
> test tier. See ADR-0031, "Accepted fee-share denomination tradeoff".

### Fee-accounting corollary (ADR-0031)

**Property.** The performance fee launches at 10% of performance-fee NAV profit
above a global post-fee high-water mark and may change prospectively up to a hard 20%
v1 cap. Investment losses never lower the hurdle. A deposit carries `H + assets`.
An exit carries
`max(H - assets, ceil(H × postEffectiveSupply / preEffectiveSupply))`: the first
term preserves a genuine drawdown and the second preserves each remaining share's
deferred-fee claim when redemption NAV exceeds performance-fee NAV. Junior-capacity
changes never mutate the hurdle and never increase the performance-fee base. The
management fee starts at zero, is prospective, and cannot
exceed 2% per 365-day year in v1. Both setters crystallize the old rate first.
Management is charged before performance. Neither fee removes backing assets, and the
same profit cannot be charged twice. On an unchanged fee base, management-fee retention
composes across time, so permissionless checkpoint frequency cannot materially change
the charge.

**Enforcement.** Fee shares mint to a protocol-exempt recipient. Every investor
entry/exit, repayment, direct default/loss/past-due transition, and fee/configuration
change closes the prior period; anyone may call `accrueFees`. The performance hurdle
uses `totalAssets() - performanceFeeImpairment()`, where the impairment includes live
declared/past-due risk before temporary curator or sGROVE capacity is netted. Live
impairment therefore suppresses fees and recovery below the old peak is fee-free.
Deposits add principal to the hurdle; exits apply the explicit max-law above;
curator/sGROVE/backstop writers use a two-call checkpoint-and-lock bracket but do not
derive a hurdle adjustment from the observed NAV. The ERC-20 share-update lock prevents the fail-open points
callback from checkpointing against transient supply, and the persistent yield-delivery
lock covers both Waterfall mints through `notifyYield`. Waterfall then calls
`accrueFees`, so the zero-period launch performance fee crystallizes before the
repayment transaction returns. Read-only conversions simulate pending shares without
changing state.

This is a **global**, not per-wallet, high-water mark. Entrants during a drawdown
share fee-free recovery to the protocol's prior peak. They can also share a later fee
on pre-entry gains that were deferred below the hurdle by a live performance
impairment—even when junior support made redemption impairment zero at entry. That
equalization consequence is part of the property, not a promise of personal
cost-basis accounting.

Forest Road also accepts a composition residual of this pooled rule: after the queue
cooldown, an incumbent can exit and redeposit during a junior-covered deferral and
reduce the protocol's later fee. This does not violate the invariant above—the exit
cannot lower the per-share HWM and the direction is protocol under-collection, not a
holder overcharge. It is a documented economic tradeoff, not an untested claim of
round-trip neutrality.

**Tests.** `test/unit/SUSDfrFees.t.sol`,
`test/integration/FeeStackFlow.t.sol`, and
`test/integration/RecoveryAssessmentFlow.t.sol`. The full-cure property directly
asserts that no performance shares mint regardless of intervening junior-capacity
writes. `invariant_feeHurdle_followsPreFlowReferenceLaw` independently derives the
post-flow hurdle from pre-flow state, assets, and supply and fuzzes both equal- and
dual-NAV queue states. The composed
`test_acceptedGlobalHwmRoundTripUndercollectsButCannotOverchargeHolders` pins the
accepted non-neutral round trip explicitly.

## 8. Access control

**Property.** No privileged action is reachable by an unauthorized role in any state.

**Enforcement.** OpenZeppelin `AccessControl` on every privileged function; a flat
role-admin graph (all roles admin'd by `DEFAULT_ADMIN_ROLE`, no self-granting loop);
UUPS `_authorizeUpgrade` is gated by `UPGRADER_ROLE` (the timelock) on all 17 role-based
modules; `FRGovernor` is separately gated by `onlyGovernance`. See
`docs/access-control-matrix.md`.

**Tests.** Exhaustive per-function unit tests (authorized + unauthorized caller for every
role-gated function; 100% branch), plus `Validate.s.sol` asserts the live role topology
(positive AND negative holdings).

## 9. USDC reserve accounting

**Property.** The internal idle-USDC ledger plus per-facility deployed principal
reconciles to every admitted value transition. Direct USDC donations never create
backing, accounting can rise only with a measured receipt or fee capitalization, and a
custody shortfall can only lower recognized backing.

**Enforcement.** Mainnet v1 has one immutable six-decimal USDC asset. There is no generic
asset registry, DSRA, or reserve-instrument path. `depositUSDC` and `recordPayment`
measure exact receipts; `releaseUSDC`, `recordDeployment`, principal return and write-off
move the durable ledgers atomically; `reconcileIdleUSDC` is one-way downward.

**Tests.** `invariant_reserves_reconcile`, `invariant_reserves_and_pools_reconcile`,
`invariant_exposure_reconciles`.

---

## Additional encoded invariants (beyond the §1.3 minimum)

| Invariant | Property |
|---|---|
| `invariant_sgrove_groveCustodyExact` | sGROVE holds exactly the active-staked GROVE (unbonding excluded). |
| `invariant_sgrove_usdfrCustodyExact` | sGROVE USDfr balance == coverage reserve + (rewards notified − claimed); coverage and reward pools never bleed into each other. |
| `invariant_sgrove_rewardsConserve` | Claimed + streamed-pending rewards never exceed what was notified (holds under the new streaming model — audit R4-EC1/M-1). |
| `invariant_sgrove_votingUnitsTrackStakeExactly` | sGROVE's checkpointed voting units equal `totalStaked()` exactly (ADR-0026). Catches a dropped or duplicated mint/burn of voting units, and an in-place upgrade of a pre-L-02 proxy whose Votes namespace is virgin while `staked` is populated. It does **not** catch the `stake` self-delegate-ordering double count — `_delegate` never touches `_totalCheckpoints`, so the total is unchanged; that is caught by `invariant_sgrove_votesEqualDelegatedStake` and the two supply bounds. |
| `invariant_sgrove_custodyStaysUndelegated` | `grove.delegates(address(sGrove)) == address(0)` (ADR-0026). The precondition the entire no-double-count argument rests on: a single `delegate` call would make every staked GROVE count twice, once through GROVE and once through sGROVE. |
| `invariant_votes_neverExceedGroveSupply` | The sum of aggregate voting power across every delegate is `<=` GROVE total supply (ADR-0026). Non-strict: **equality is the intended launch state** (the treasury self-delegates the whole genesis supply). It goes strict exactly to the extent of undelegated GROVE plus GROVE in the unbonding window, both of which sit in the denominator but are votable by nobody. |
| `invariant_sgrove_stakeIsBackedByCustody` | `sGrove.totalStaked() <= grove.balanceOf(address(sGrove))` (ADR-0026). |
| `invariant_sgrove_votesEqualDelegatedStake` | Zero-slack: the sum of `sGrove.getVotes` over every delegate equals the sum of `stakedOf` over accounts that have a delegate (ADR-0026). **This is the check that catches the `stake` self-delegate-ordering double count**, and units credited to the wrong account. |
| `invariant_sgrove_firstStakeAutoSelfDelegates` | A staker who never hand-delegated is self-delegated and votes exactly their active stake (ADR-0026). Pins that staking CREDITS the staker — deleting the auto-self-delegate leaves every other invariant green. |
| `invariant_votes_pastReadsNeverExceedPastSupply` | The Governor's actual read path (`getPastVotes` summed over delegates) never exceeds `getPastTotalSupply` at the same past timepoint (ADR-0026). |
| `invariant_votes_aggregatorComposesBothLegs` | The aggregator's present and past reads equal GROVE leg + sGROVE leg per account (ADR-0026) — catches a dropped leg, which the `<=` bounds cannot. |
| `invariant_governance_clocksAgree` | GROVE, sGROVE and the aggregator all report `clock() == block.timestamp` and `CLOCK_MODE() == "mode=timestamp"` (ADR-0026). Catches the silent block-number fallback. |
| `invariant_quorumDenominatorIsGroveOnly` | `aggregator.getPastTotalSupply(t) == grove.getPastTotalSupply(t) == GROVE_INITIAL_SUPPLY` (ADR-0026) — no reachable sequence moves the quorum denominator. |
| `invariant_oracle_ghostParity` | The real EIP-712 oracle's satisfied/consumed state matches an independent ghost model (differential check). |
| `invariant_tracking_reconcilesToParticipantBalances` | PointsModule tracked shares reconcile to the participants' sUSDfr balances. |
| `invariant_exemptModulesNeverAccrue` | Protocol-owned/exempt addresses never accrue points. |
| `invariant_points_monotonicPerWallet` | Points never decrease for a wallet absent an explicit event. |
| `invariant_noFreePoints_idleWallet` | A same-block track/untrack accrues exactly 0 (no flash-farming). |

> **Corrected 2026-07-21.** These four rows previously named
> `invariant_tracking_matchesVaultSupply`, `invariant_attribution_identityBalancesReconcile`,
> `invariant_points_monotonicPerIdentity` and `invariant_noFreePoints_idleIdentity` — none of which
> exist. They were the pre-**points-v2** names: the 2026-07-14 redesign made accrual **per-wallet**
> and dropped the identity/tier machinery entirely, so the "attribution is identity-keyed
> (ADR-0016 anti-Sybil)" row described a property the code no longer has. Sybil-resistance now
> rests on flat linear accrual plus the fresh-wallet ramp reset, not on identity keying.

---

## Formal / differential notes (CLAUDE.md §1.5)

- **Differential model:** the attestation oracle runs against an independent ghost model
  (`invariant_oracle_ghostParity`); reward accounting is cross-checked by
  `invariant_sgrove_rewardsConserve` against notified/claimed ghosts.
- **Symbolic:** Halmos proves five backing-transition properties (four against the real
  controller/reserve implementations through proxies, one full-domain user-flow lemma)
  and the modeled cascade arithmetic across nine paths. Exact scope and trust boundaries
  are documented in `formal-methods-amenability.md`; this supplements, rather than
  replaces, the integrated backing and cascade invariant campaigns.
- **Gas snapshots:** `forge snapshot` tracked; regressions flagged in review.

*This spec is a living document. Any new value-moving path must add its invariant here and
its encoding test before the module is considered done (CLAUDE.md §5).*
