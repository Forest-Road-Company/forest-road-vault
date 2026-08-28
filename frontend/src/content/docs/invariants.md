# Invariant Specification — Forest Road Vault

**Audience:** external auditors and reviewers. **Status:** the invariants below are encoded
as stateful fuzzing (Foundry) with handlers and hold at the configured run counts
(`heavy` profile: 10k fuzz runs; invariants runs ≥ 512, depth ≥ 256); the backing and
cascade sections additionally have Halmos transition/arithmetic proofs. This document is
the protocol's **safety spec**. It maps each property in CLAUDE.md §1.3 to (a) the
mechanism that enforces it on-chain and (b) the named test(s) that prove it.

Run: `FOUNDRY_PROFILE=heavy forge test` (from `contracts/`). The clean mainnet-v1
candidate is also rehearsed against canonical Ethereum-mainnet USDC on a fork.

> Convention: an invariant is a property that must hold **across all reachable states**.
> If one cannot be made to hold, that is a genuine-problem STOP. We surface it rather
> than weaken the assertion (CLAUDE.md §1.3, §4.5).

---

## 1. Backing invariant (ADR-0012)

**Property.** `USDfr.totalSupply()` ≤ backing value, always, where backing =
accounted canonical USDC at par + outstanding deployed principal. Mainnet v1 has no
generic asset registry or reserve-instrument mark.

**Enforcement.** User mints atomically pull canonical USDC before minting USDfr.
Origination fees are capitalized only when principal is deployed. Repayments atomically
pull the attested payer's USDC before reducing principal or routing interest. Every
supply-increasing path asserts backing after the mint; write-downs are atomically paired
with the loss-cascade burns. Direct USDC donations never become recognized backing through
reconciliation: the reconciliation function is intentionally one-way downward and only
acknowledges a custody shortfall.

**Tests and symbolic checks.** `invariant_backing_supplyNeverExceedsBacking`
(CreditInvariants, TokenLayerInvariants), `invariant_backing_holdsThroughQueueTraffic`
(RedemptionQueueInvariants), `invariant_supply_fullyAccounted`, and the five Halmos
properties in `test/symbolic/BackingSymbolic.t.sol`. Four execute the real
controller/reserve implementations through proxies; the user mint/redeem equal-delta
identity is a full-domain arithmetic lemma bound to production by unit, fork and
differential stateful tests.

## 2. Value conservation in the waterfall

**Property.** Every distributed repayment is fully and correctly allocated:
`fee + toVault == interest` and the principal leg reduces deployed principal
exactly; nothing is created or destroyed; senior (`sUSDfr`) is never subordinated to
junior (curator).

**Enforcement.** `_routeInterest` splits by construction into protocol fee and sUSDfr
yield. `distribute` consumes a single-use `PaymentReceived` attestation committing to
the exact facility, payment id, payer, interest, principal and next due date, then pulls
the exact USDC amount. Mainnet v1 has no DSRA. Later performance/management fees mint
`sUSDfr` shares and therefore do not alter this cash-conservation equation.

**Tests.** `invariant_waterfall_conservesValue`, `invariant_reserves_and_pools_reconcile`.

## 3. Loss-cascade ordering (three-layer)

**Property.** Losses absorb **curator first-loss → sGROVE backstop → sUSDfr depositor
principal**, in that order, never skipping or inverting a layer.

**Enforcement.** `DefaultManager.realizeLoss` consults the layers in fixed sequence:
`curator.absorbLoss` (layer 1) → `sGrove.coverShortfall` on the residual (layer 2, with a
strict `received == covered` equality check; audit R1 fix L) → depositor burn on what
remains (layer 3), then the write-down is paired atomically with the burns so the backing
assertion never observes an intermediate violation. The cascade path is **never pausable**.

**Tests and symbolic checks.** `invariant_cascade_orderingHolds`,
`invariant_curator_subordinationRespected`, and the nine-path Halmos arithmetic proof in
`test/symbolic/CascadeSymbolic.t.sol`.

## 4. NFT mint gate

**Property.** A Loan NFT cannot mint unless **all** required attestation kinds for its
class are satisfied AND on-chain conditions hold; escrow release is contractually
conditioned on the NFT's existence.

**Enforcement.** `ClaimBridge.originate` iterates the class's
`requiredMintAttestations` bitmask and requires each kind satisfied for the new
`tokenId`. Credit terms, valuations, payments, defaults, cures, amendments and realized
losses are payload-bound; high-value facts require **m-of-n ≥ 2** signatures. Funding
uses the signed recipient and exact principal. Receivable masks include `CreditIssued`,
so documentary facts without matching signed terms cannot mint.

**Tests.** `invariant_mintGate_neverBypassed`.

## 5. Redemption queue

**Property.** The queue never distributes more than available liquidity; FIFO ordering
holds; no double-claim.

**Enforcement.** Epoch FIFO by `requestId`; `head` advances only on a full fill;
settlement is bounded by a snapshotted budget (rounding always favors the pool);
`assetsClaimable` is zeroed before transfer (no double-claim); dust requests that convert
to 0 assets are rejected (audit R3 N-1); a zero-distribution settlement with requests
queued reverts rather than consuming the epoch (audit R2 A1; anti-DoS).

**Tests.** `invariant_queue_fifoHolds`, `invariant_queue_custodyReconciles`,
`invariant_exchangeRate_neverFallsFromQueueOps`.

## 6. Concentration limits

**Property.** Per-vertical / per-state / per-borrower exposure limits are never exceeded
by an origination.

**Enforcement.** `CollateralRegistry` checks the limits atomically at origination and
records the exposure increase; `recordExposureDecrease` on write-down keeps the ledger
exact.

**Tests.** `invariant_concentration_limitsHold`, `invariant_exposure_reconciles`.

## 7. sUSDfr fee-net exchange-rate integrity

**Property.** Absent credit loss or a protocol fee becoming economically due, the
fee-net `sUSDfr` exchange rate does not decrease from yield accrual alone. Credit
losses enter **only** via the cascade; due fees are reflected deterministically in
contract previews and crystallized through explicit events.

**Enforcement.** Yield arrives as USDfr minted into the vault (rate up). A cascade
burn is paired with a recorded loss. ERC-4626 conversions simulate fee shares due now,
so a pre-transaction quote matches the checkpointed state; the later fee event/mint
leaves assets unchanged and does not create a second price jump. With management
enabled, the fee-net view can decline predictably with elapsed time before
crystallization. Every queue entry/settlement/exit path checkpoints before pricing.

**Tests.** `invariant_exchangeRate_neverFallsWithoutLossOrFee`,
`invariant_exchangeRate_neverFallsFromQueueOps`, plus
`test/unit/SUSDfrFees.t.sol`.

### Fee-accounting corollary (ADR-0031)

The performance fee launches at 10% of performance-fee NAV profit above a
**global** post-fee high-water mark and may change prospectively up to a hard 20% v1
cap. Investment losses never lower the hurdle. A deposit carries `H + assets`; an exit
carries the greater of the old hurdle less assets paid and the old hurdle's remaining
effective-supply fraction. This protects stayers in a drawdown and prevents a leaver
priced on junior-supported redemption NAV from shedding deferred fee exposure.
Junior-capacity changes never mutate the hurdle: they may improve
the redemption mark but are removed from performance-fee NAV because contributed
loss protection is not investment profit. The management fee starts at
0%, is prospective, and is capped
at 2% per 365-day year in v1. Both setters crystallize the old rate first. Management
is charged first; neither fee removes backing assets; recovery below an old peak is fee-free;
the same profit cannot be charged twice; and management retention on an unchanged fee
base is materially checkpoint-frequency neutral.

This is not personal cost-basis accounting. A depositor entering in a drawdown shares
the protocol's fee-free recovery to its old peak and can share a later fee on
pre-entry gains that were deferred by performance impairment, even when current
queued-exit impairment is zero.

**Tests.** `test/unit/SUSDfrFees.t.sol`,
`test/integration/FeeStackFlow.t.sol`, and
`test/integration/RecoveryAssessmentFlow.t.sol`. A full-cure property asserts that no
performance shares mint regardless of intervening junior-capacity writes. The queue
campaign fuzzes independent redemption/performance NAVs and checks the post-flow
hurdle against a pre-flow reference law.

## 8. Access control

**Property.** No privileged action is reachable by an unauthorized role in any state.

**Enforcement.** OpenZeppelin `AccessControl` on every privileged function; a flat
role-admin graph (all roles admin'd by `DEFAULT_ADMIN_ROLE`, no self-granting loop);
UUPS `_authorizeUpgrade` is gated by `UPGRADER_ROLE` (the timelock) on role-based
modules; `FRGovernor` is separately gated by `onlyGovernance`. See
`docs/access-control-matrix.md`.

**Tests.** Exhaustive per-function unit tests (authorized + unauthorized caller for every
role-gated function; 100% branch), plus `Validate.s.sol` asserts the live role topology
(positive AND negative holdings).

## 9. USDC reserve accounting

**Property.** Accounted idle USDC plus deployed principal reconciles exactly to the
protocol's backing ledger. Unsolicited transfers cannot increase backing, and a custody
shortfall cannot be reversed by a later donation.

**Enforcement.** `ReserveManager` is canonical-USDC-specific. Deposit, redemption,
deployment and repayment paths move USDC and accounting atomically. Reconciliation is
one-way downward; principal write-downs are durable and facility-bounded.

**Why reconciliation is permissionless.** A caller cannot remove funds or invent a loss.
The function simply compares the live canonical-USDC balance with the already-recorded idle
ledger and retains the lower number. Leaving it open means no administrator can conceal a
real custody shortfall from depositors: anyone can force the backing ledger to tell the
conservative truth. If that reveals under-backing, minting, redemption and servicing fail
closed instead of letting early exits race the deficit.

Sending USDC directly to the contract cannot undo a write-down or silently improve reported
backing. The production recovery is an exact recapitalization through the role-gated deposit
path, executed inside one timelock batch that grants and revokes the timelock's temporary
deposit authority. User operations stay paused until live custody, the idle ledger, supply,
backing and role revocation have all been independently verified.

**Tests.** `invariant_reserves_reconcile`, `invariant_idleReserve_independentRecompute`,
`invariant_supply_fullyAccounted`, and `ReserveManagerTest`.

---

## Additional encoded invariants (beyond the §1.3 minimum)

| Invariant | Property |
|---|---|
| `invariant_sgrove_groveCustodyExact` | sGROVE holds exactly the active-staked GROVE (unbonding excluded). |
| `invariant_sgrove_usdfrCustodyExact` | sGROVE USDfr balance == coverage reserve + (rewards notified − claimed); coverage and reward pools never bleed into each other. |
| `invariant_sgrove_rewardsConserve` | Claimed + streamed-pending rewards never exceed what was notified (holds under the new streaming model; audit R4-EC1/M-1). |
| `invariant_oracle_ghostParity` | The real EIP-712 oracle's satisfied/consumed state matches an independent ghost model (differential check). |
| `invariant_tracking_reconcilesToParticipantBalances` | PointsModule tracked totals (shares / USDfr / curator) reconcile to the sum of live per-wallet positions. |
| `invariant_exemptModulesNeverAccrue` | Protocol-exempt addresses (vault, controller, treasury…) never accrue points. No sink earns. |
| `invariant_points_monotonicPerWallet` | Points never decrease for a wallet from accrual alone (per-wallet, not identity-keyed; points-v2 anti-Sybil is the maturity-ramp reset). |
| `invariant_noFreePoints_idleWallet` | A same-block track/untrack accrues exactly 0 (no flash-farming). |

---

## Formal / differential notes (CLAUDE.md §1.5)

- **Differential model:** the attestation oracle runs against an independent ghost model
  (`invariant_oracle_ghostParity`); reward accounting is cross-checked by
  `invariant_sgrove_rewardsConserve` against notified/claimed ghosts.
- **Symbolic:** Halmos proves five backing-transition properties (four against the real
  controller/reserve implementations, one full-domain user-flow lemma) and the modeled
  cascade arithmetic across nine paths. Exact scope and trust boundaries are documented
  in `docs/formal-methods-amenability.md`; this supplements, rather than replaces, the
  integrated backing and cascade campaigns.
- **Gas snapshots:** `forge snapshot` tracked; regressions flagged in review.

*This spec is a living document. Any new value-moving path must add its invariant here and
its encoding test before the module is considered done (CLAUDE.md §5).*
