# Full-system multi-pass audit

> **Historical snapshot — superseded.** This narrative predates ADR-0031 and the move to
> instant yield recognition. Statements below about receipts vesting smoothly describe the
> seven-day streaming window in force at the time; Forest Road set the launch window to zero
> on 30 July 2026, so realized interest now enters NAV as a step. Optional streaming remains
> available to governance. See the Round 14 report for the current behaviour.

## What this round was

The five rounds before this one each answered a narrower question: two five-pass source
reviews, a pre-mainnet campaign, a defensive review of the clean mainnet-v1 tree, and a
differential review of what the release branch changed. This one re-audited **everything** —
every production contract and all frontend functionality — after the Round 6 remediations had
landed.

The brief asked for findings confirmed by multiple passes. That was implemented as
**independent double discovery followed by adversarial verification**, not as one pass
reviewed twice:

1. The system was split into nine surfaces — six across the contracts (token layer, credit
   layer, loss cascade, reserve and queue, trust boundary, and governance/upgradeability/
   storage) and three across the frontend (write paths, read and display correctness,
   configuration and security posture).
2. **Each surface was reviewed twice, by reviewers with different briefs** — one on
   correctness and value safety, one adversarial and economic — and the second reviewer never
   saw the first one's work. Agreement between them is independent corroboration rather than
   confirmation bias.
3. The 71 raw candidates were merged **by mechanism, not by wording**, into 30. Where two
   reviewers disagreed on severity, the lower was carried.
4. Every one of the 30 then faced **two independent refuters** instructed to refute rather
   than confirm, and to default to rejection where the evidence was not airtight: one testing
   whether the code actually says what the finding claims, at the line claimed, without a
   guard the finder missed; the other testing whether the stated consequence follows, who must
   act to reach it, and whether a validator or an existing test already blocks it.
5. A completeness critic then challenged the severities and — more usefully — enumerated what
   the audit had failed to cover.

**All 30 mechanisms held. 22 of the 30 had their consequence corrected downward**, four filed
Mediums ending as Informational. The severities published here are post-correction.

## The result

No Critical and no High finding. Nothing found in this round breaks the backing invariant,
inverts or skips the loss cascade, bypasses the facility mint gate, defeats compliance,
over-distributes the redemption queue, or reaches an unauthorized mint.

**One contract-level defect is reachable through ordinary operation** — FRV-FS-01. The other
Medium is a disclosure defect at the point of an irreversible signature. Four of the top six
findings are frontend-to-contract reconciliation defects, which is the class the operating
rules assign to live-system QA — a pass this round could not perform.

Six rounds in, that a full re-audit yields one composed state-machine dead end and a cluster
of display-accuracy defects is itself a result about the contracts. It is not a statement that
the system is ready to launch.

## Post-audit remediation update — 28 July 2026

All two Medium and ten Low findings have since been remediated and verified. The original
audit narrative below is preserved as the evidence at baseline `33713ec`; these changes do
not retroactively turn the source-only review into an executed audit.

- **FRV-FS-01:** the waterfall now skips schedule advancement only for the exact terminal
  maturity-to-maturity case. ClaimBridge's strict later-date rule still binds every
  non-terminal receipt. Regressions cover interest-only and partial-principal receipts at the
  terminal due date, rejection of an unchanged pre-maturity date, and a deterministic
  thirteen-receipt facility lifetime through the maturity clamp.
- **FRV-FS-02:** the redeem card now reads the live configured cooldown, distinguishes it from
  the settlement heartbeat, warns that FIFO and liquidity can extend the wait, requires an
  explicit acknowledgement that queue entry is non-cancellable, and renders each position's
  first eligibility from its request timestamp plus the live cooldown. The request action is
  disabled until the on-chain cooldown has loaded.
- **FRV-FS-03:** an oversized healthy yield receipt can no longer close vault entry. The
  vesting stream is capped against the live staked base and any excess is recognized
  immediately as an upward-only NAV step, while ordinary receipts continue to vest smoothly.
- **FRV-FS-04:** professional assessments now separate risk-state identity from global
  backstop capacity. Permissionless additions cannot invalidate a live assessment; a capacity
  decrease, curator-pool change, or book/default revision still fails closed.
- **FRV-FS-05:** a pending queue does not consume its heartbeat for an aggregate fill below
  the governed economic minimum. The attempted dust fill rolls back; final drained tails remain
  claimable, and zero liquidity remains blocked even if governance disables the entry floor.
- **FRV-FS-06:** cancellation and different-call wallet replacements now report an error.
  Same-call repricing succeeds against the replacement hash that actually mined.
- **FRV-FS-07:** receivable collateral is calculated from live outstanding principal divided
  by LTV, preventing amortization or a write-down from inflating displayed coverage.
- **FRV-FS-08:** position value and gain now use the impairment-netted `previewRedeem` exit
  value and say so.
- **FRV-FS-09:** the receipt-bound verifier runs from Next's production-build phase as well as
  npm `prebuild`, and CI now executes the contract and frontend gates. No pre-deployment
  receipt was invented: mainnet builds remain blocked until the deployment ceremony produces
  the real approved manifest and receipt.
- **FRV-FS-10:** every build must select its chain explicitly; an unset
  `NEXT_PUBLIC_CHAIN_ID` fails closed.
- **FRV-FS-11:** writes are bound to both an account and a flow generation, so a result from
  the prior wallet cannot update the newly selected account's UI or trigger its success
  callback.
- **FRV-FS-12:** the denominator-unstable cumulative-income annualization was removed. The
  panel retains current expected yield, projected position income, realized history and the
  observation period.

Post-remediation verification completed with **865 contract tests passed, zero failures**;
182 environment-gated fork tests were skipped by the unconfigured run. The queue and credit
invariants each ran 256 campaigns of 128 calls per property without a handler revert.
Frontend logic, **332 contract↔UI synchronization checks**, lint, TypeScript and the production
build all passed; an explicit unset-chain probe failed closed as intended. Slither 0.11.5
analyzed 104 contracts with 101 detectors and returned 84 raw pattern matches; manual triage
added no new finding. Its High-labelled outputs were the role-gated exact USDC pull paths and
the non-reentrant loss cascade's explicit before/after balance check. The 18 Informational
findings retain their original dispositions. This remediation does not close any independent
external-audit, legal, economic or production-readiness gate.

## Independent agreement is not correctness

This is the most useful thing the round produced, and it is worth stating plainly because it
bears on how every finding on this site should be read.

The **most corroborated** finding of the round — four separate reviewers across two different
surfaces, all citing the same six locations, every citation accurate — claimed that the
protective margin-call and liquidation triggers wrongly require a fresh valuation, contrary to
the documented rule that protective action must never be blocked by a withheld mark.

All four were wrong, in the same way. None noticed that the ADR they were citing carries a
**supersession banner**, and that ADR-0030 deliberately reversed the rule: marked-to-market
calls, cures and liquidations now *do* require a fresh attested mark. The code implements the
current rule correctly. What is actually wrong is two stale comment blocks left behind by the
reversal — published here as FRV-FS-20, Informational.

Both refuters caught it independently, and the finding fell from Medium to Informational.

Four independent reviewers agreeing is strong evidence that a **mechanism** is real and weak
evidence that a **conclusion** is right. Corroboration alone would have published a Medium
against correct code. That is the argument for the verification stage, and it is why this page
records what verification *changed* rather than only what it confirmed.

## The two Mediums

**FRV-FS-01 — a servicing dead end.** The payment waterfall advances a facility's schedule on
every performing receipt that leaves principal outstanding. The credit register accepts only a
strictly later date, bounded above by maturity. Once those two coincide — which a bullet
facility can do from the day it is originated — the acceptable range is empty and the whole
distribution reverts.

Nothing is lost; the revert is atomic and happens before any money moves. What breaks is
servicing. A final short payment cannot be recorded. An unscheduled interest-only payment
cannot be recorded. That period's senior yield is never minted. And the facility then drifts
to its grace deadline, where the permissionless past-due flag can be applied by any address —
lowering the redemption NAV **while the borrower is in fact paying**. Both ways out are
governance- or attester-grade, and needed per payment.

The reason no test caught it is worth recording: the invariant campaign runs with reverts
treated as failures, and its handler applies the exact clamp that creates the trap. A green
run is therefore positive evidence that the fuzzer **never walks a single facility through its
own amortization schedule**.

**FRV-FS-02 — an undisclosed lock-up.** A queued redemption cannot settle for 21 days, and
the queue has no cancel or withdraw function of any kind: custody moves permanently when the
user signs. The redeem card states no exit horizon at all — its only time signal is the
sub-24-hour epoch countdown. The cooldown is not in the queue interface the app reads and
appears nowhere in the frontend; the request's own timestamp is decoded and then never shown.

This is the omission of a hard floor rather than an incorrect number, and it sits immediately
above an unrecoverable action on the app's broadest write surface. Two strings in the error
catalogue already promise a per-position countdown; they turn out to be unreachable at
runtime, which makes them evidence that the interface was believed to have one — not something
a user is ever shown.

Grading it Medium is a boundary call and is stated as one: earlier rounds reserve that grade
for frontend items with a functional consequence and use Low for display accuracy. It sits
with the former because the user acts irreversibly on the incomplete statement.

## Findings that touch previously accepted risks

Every reviewer was given the register of findings this protocol has already accepted, deferred
or left open, with the rule that a finding sharing an *impact class* with an accepted item may
only be raised if the *mechanism* genuinely differs — and must say how.

**No candidate had to be dropped as a restatement.** The closest calls were each checked and
kept:

- FRV-FS-03 against the accepted yield-guard residual. That acceptance concerns how much a
  depositor can capture once entry *reopens*; this is the opposite side of the same test — the
  guard *firing* during healthy operation, which undercuts the premise the calibration rests
  on.
- FRV-FS-13 against the accepted concentration-drift item. That one concerns exposure that
  **is** measured and drifts above its limit, mitigated by the rule that a breached dimension
  cannot be grown. Here the dimension is never measured at all, so that mitigation has nothing
  to attach to.
- FRV-FS-04 against the accepted curator-capital item. That is a privileged party posting
  withdrawable capital to *improve* a settlement; this is an unprivileged party spending a
  trivial, unrecoverable amount to *degrade* one, through a different module.

### One acceptance whose premise should be revisited

The marked-to-market class is carried at par as an explicit design decision, and that decision
is published on the Round 1 page with a stated rationale: the class is protected by the fast
margin-call, liquidation and loss-cascade remedy instead of by a continuously-marked backing
figure.

FRV-FS-20 establishes that ADR-0030 changed the conditions on that remedy — those triggers now
require a **fresh attested mark**. The code is right and the change was deliberate. But the
published acceptance rationale predates the reversal and does not disclose that the protection
it names is now conditional on continuous attester liveness: with a short maximum mark age, a
non-signing key, a guardian pause of the oracle, or an administrative revocation suspends the
remedy while the loan-to-value ratio deteriorates, and the fallback path needs a quorum through
the same entry point.

This is a documentation and governance item rather than a code defect, and it is the one place
where this round bears directly on a prior acceptance. It is recorded here so the acceptance
can be re-examined rather than inherited.

## What this audit did not cover

An audit that overstates its own coverage is worse than one that admits its limits.

**Nothing was executed.** This round was read-only by instruction: no test suite, no coverage
measurement, no invariant campaign, no symbolic checking, no static analysis, no build, no
live-chain reads. Every statement here that no test covers a finding is derived from reading
and searching the test tree, not from measuring it. **The test and coverage figures recorded
elsewhere in this repository were not re-verified by this round and are not restated here.**

**No live-system QA**, despite four of the six most significant findings being exactly the
frontend-to-contract reconciliation defects that a live pass is designed to catch. All four
were found by reading. That reading alone surfaced four is a reason to expect a live pass would
surface more; their absence from this page is not evidence they do not exist.

**Formal methods remain one file and one property.** The only symbolic artefact covers the loss
cascade, and it is a separate re-implementation bound to the contract by differential fuzzing
rather than the contract itself. The operating rules name two properties for formal treatment —
**the backing invariant has no symbolic proof at all.** No reviewer noticed this; the critic
did.

**There is no continuous integration.** The rule that a red suite blocks a merge is
unimplemented, so nothing mechanically prevents any finding — from this round or the five
before it — from regressing.

**The coverage methodology is self-documented as defective and was not re-measured.** The
repository's own notes record that the exclusion pattern used for coverage silently omitted one
production contract from every figure it has ever reported.

**The tests were never audited as a deliverable in their own right**, although the operating
rules treat them as one. Weak assertions, tautological tests, or handlers that cannot reach a
state would have been invisible to this round. Scale and multi-year state growth were not
examined at all.

## The blind spot, and what should happen next

The weakness this round revealed in itself is one of shape rather than effort: **defects that
require a single entity to be walked through many sequential operations across a module
boundary.**

FRV-FS-01 is exactly that shape, and **seventeen of the eighteen reviewers missed it** — each
of the two functions involved is correct in isolation, and the defect exists only in their
composition after a facility has amortized. At the audited baseline, the automated suite did
not reach it; the post-audit remediation adds a deterministic full-schedule regression.
Meanwhile every reviewer's list of properties they *could not* break is a point-in-time
property: reentrancy, rounding direction, replay, domain binding, storage layout, chain
binding, decimals, ordering, double-claim. All valuable; none sequential.

The recommendation carried into the next round is to **review by entity lifetime rather than by
module**, as executed integration tests rather than as reading: drive one facility and one
vault position through their full terms — many sequential partial repayments including an
interest-only and an unscheduled prepayment, a short final payment, past-due, cure, maturity;
and stake, accrue across several governance rate epochs, queue, cool down, settle partially
across epochs, claim. Add the missing symbolic proof of the backing invariant so the
long-sequence question is answered for all inputs rather than sampled.

## Status of these findings

At publication, **all thirty were open** and the evidence behind each was source-only. The
post-audit remediation above closes FRV-FS-01 through FRV-FS-12 with executed regression
evidence; the remaining 18 Informational findings retain their original dispositions.

Separately: several candidates were reduced or set aside precisely because they re-filed a
defect this protocol has already published under an earlier identifier. **Reducing a duplicate
filing says nothing about the underlying defect** — those items remain open under their
original identifiers, and at least one of them, the drift in the published access-control
matrix, is still present in the source.
