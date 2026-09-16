# ADR-0036 — Queued governance is final; mainnet v1 has no proposal guardian

**Status:** Accepted — Forest Road decision, 2026-08-14 (recorded internally as **G1c**).

**Amends:** [ADR-0013](0013-governance-forest-road-controlled.md) (governance topology). Relates to
[ADR-0008](0008-uups-upgradeability.md) (upgrade authorisation through the timelock).

**Does NOT change any locked decision.** The three-layer loss cascade
([ADR-0004](0004-anchor-curator-first-loss.md), [ADR-0014](0014-sgrove-backstop-parameters.md),
[ADR-0021](0021-sgrove-backstop-implementation.md)), the collateral model, the yield model and the
economic parameters in `Config.sol` are untouched. This ADR governs only who may stop a governance
action after it has passed a vote.

> **Why this record exists.** The proposal-guardian mechanism was introduced on 2026-08-09
> (`f2a7cdd`) and removed on 2026-08-14 (`e7db1d2`) **without an ADR in either direction**. Every
> other record of this decision lives in files that CLAUDE.md §4.3.1 never publishes
> (`docs/MAINNET_LAUNCH_RUNBOOK.md`, `docs/remediation/`, `STATE.md`). An external auditor receives
> `ADR/` and `contracts/src` and would otherwise find a Governor with no veto path and no
> explanation. This ADR closes that gap.

---

## Decision

**Mainnet v1 ships no proposal guardian and no post-queue veto principal. Once a proposal passes a
vote and is queued in the Timelock, it will execute.** The only defence against a bad governance
action is preventing it from passing.

`FRGovernor` accordingly drops the `GovernorProposalGuardianUpgradeable` extension, the
`setProposalGuardian` setter, the `cancel` override, the `_validateCancel` override and the
`_isStandaloneGuardianRotation` helper. `initialize` loses its third parameter and becomes
`initialize(IVotes votesSource, TimelockControllerUpgradeable timelock)`.

`updateTimelock` is additionally disabled — it reverts unconditionally with
`Governor_TimelockMigrationDisabled`. OpenZeppelin's inherited endpoint moves only the Governor's
stored executor pointer; it migrates no module admin/upgrader roles and no proposer/canceller/
executor topology, so a partial migration through it would silently split authority. A real Timelock
migration must be a separately reviewed Governor upgrade plus an atomic role-transfer ceremony.

## Context

### What the guardian was for, and why it did not deliver it

The removed code carried its own justification: *"A reachable proposal guardian is mandatory because
the Governor is the Timelock's sole `CANCELLER_ROLE` holder and queued operations otherwise cannot
be vetoed."* The premise is correct — `Deploy.s.sol` grants `CANCELLER_ROLE` to the Governor and to
nothing else — but the conclusion did not hold in the configuration actually approved.

**In the approved principal set, `PROPOSAL_GUARDIAN` and `FR_TREASURY` are the same address**
(`0x0687a13c490B2573d4666fb3a7c21826a621215E`). That address already holds 100% of GROVE and
therefore decides every vote. The "independent veto" was the same key as the thing it was meant to
check. Against the only two threat models that can produce a hostile queued operation at launch —
treasury key compromise, or treasury malice — it protected nothing, because the same key that
queues the action also holds the veto.

### The mechanism was a net liability

In five days of existence it produced three findings, all in the bespoke cancellation logic:

- **H-2 (High)** — the guardian could veto the standalone proposal that rotated the guardian,
  entrenching a compromised veto key permanently.
- **P-41** — the hand-rolled assembly calldata parser mis-classified dirty-padded addresses, so an
  unexecutable call could be read as a valid rotation.
- **M-6** — under the shipped deployment path the deployer EOA became the permanent guardian.

Measured surface, baseline versus candidate:

| | `if` branches | inline assembly | bespoke sender checks | `revert` sites |
|---|---|---|---|---|
| with guardian | 6 | 1 | 1 | 3 |
| without | **0** | **0** | **0** | 1 (unconditional) |

A veto key is also a governance-DoS primitive in its own right: an attacker holding it can cancel
every proposal indefinitely, including the proposals that would remove it.

## Consequences — measured, and accepted

### 1. A queued operation cannot be stopped. ACCEPTED.

Verified on the candidate against the deployed configuration:

- `votingDelay` **86,400 s**, `votingPeriod` **604,800 s**, Timelock `getMinDelay` **172,800 s**.
- `EXECUTOR_ROLE` is held by `address(0)` — **execution is permissionless** once the delay elapses.
- Once a proposal reaches `Queued`, cancellation is unreachable by every address (confirmed by a
  20,000-run address fuzz). OpenZeppelin's base `_validateCancel` permits only the proposer, and
  only in `Pending` state.
- The operational `GUARDIAN_ROLE` pause does **not** brake a queued `grantRole` or upgrade — both
  execute while `USDfr` is paused.
- The fastest counter-governance response is a fresh proposal cycle completing **691,200 s (8 days)
  after** the original action is already executable.

A senior `sUSDfr` holder who reacts the instant a hostile operation is queued is still inside the
21-day redemption queue when it executes. This is a real reduction in defence-in-depth and is
accepted on the reasoning above: the veto it replaces was held by the same key as the attacker in
every scenario where it would have mattered.

### 2. Governance security now rests entirely on the vote. REQUIRED DISCLOSURE.

With no post-queue veto, the security of every privileged action reduces to the integrity of the
GROVE-weighted vote and the treasury key that holds it. This must be disclosed plainly rather than
implied — any public description of "timelock protection" that suggests a human circuit-breaker
exists after a vote passes is false for mainnet v1.

### 3. `updateTimelock` is permanently unavailable. ACCEPTED, with one footgun.

Disabling it does **not** create trapped state: the UUPS Governor-upgrade path remains reachable
through the Timelock, so a future migration is still possible via a reviewed upgrade.

**Footgun:** if that selector is ever scheduled, the resulting queued operation can neither execute
(it reverts) nor be cancelled (no cancellation path), so it occupies the Timelock permanently. The
operating procedure must never schedule `updateTimelock`.

### 4. Consequent changes

- `Deploy.s.sol`, `Handover.s.sol`, `Validate.s.sol` and `PrivilegeAudit.sol` no longer reference a
  guardian principal, and the guardian entry is removed from the blocking privilege scan.
- Ten guardian regression tests were removed tree-wide and two inverted; the governance suite now
  asserts the inverse property — that a queued proposal has no cancellation path.
- **Findings H-2, P-41 and P-31 are moot**: their remediations lived inside the deleted code and the
  mechanism they protected no longer exists. They are closed by removal, not by fix. Any register
  entry describing them as remediated by a guardian behaviour must be corrected, and
  `docs/remediation/CODEX_HIGH_MEDIUM_REMEDIATION_2026-08-08.md:92` ("A production proposal guardian
  must exist") is superseded by this ADR.

## Alternatives considered

- **Keep the guardian and fix H-2/P-41.** Rejected: it preserves a control that, as configured,
  cannot check the party it is aimed at, at the cost of a hand-rolled assembly calldata parser on
  the governance path.
- **Keep the guardian but assign it to an independent principal.** Not available at launch — no
  independent principal exists; `SAFE-CD-01` already records that four Safes share one four-owner
  quorum, so a nominally separate address would not be independent control.
- **Lengthen the timelock delay instead.** Does not create a veto; it only widens the window in
  which the un-vetoable action is visible. Considered a complement, not a substitute, and left to
  the Part 11 gate 5 review.
- **Add a direct Timelock canceller separate from the Governor.** Deferred. Per
  `docs/MAINNET_LAUNCH_RUNBOOK.md`, adding a proposal guardian, a direct canceller or a longer
  exit-notice guarantee is a governance-topology change requiring a new design decision, threat-model
  review, deployment authorisation and regression evidence.

## Status of the evidence behind this ADR

Stated honestly, because the code this ADR describes is newer than the campaign that tested it:

- The 1,085-mutation sweep and the fork exploitation rounds ran against the **guardian-bearing**
  tree (`fecf7d7d`). The candidate's `FRGovernor` has no mutation sites under any of the six sweep
  axes — zero conditionals, zero role gates, one unconditional revert — so re-running the sweep
  would measure nothing about it.
- The round-3 FRGovernor exploitation attack referenced elsewhere in the repo **does not exist in
  git** and cannot be re-run or adapted.
- The live Sepolia deployment still runs the **guardian-bearing** Governor, so no deployed-system
  governance QA has exercised this topology.
- Of the 19 production contracts, **18 are byte-identical** to the tree that was swept and attacked.
  `FRGovernor` is the sole exception, and it is the sole contract carrying no campaign evidence.

Closing that gap requires a testnet deployment of this Governor and a governance suite run against
it before the mainnet ceremony. It does not require re-running the mutation sweep.

## Sequencing

1. Deploy this Governor to a public testnet and run the governance suite against the live contract.
2. Correct the published audit register for H-2, P-41 and P-31.
3. Part 11 gate 5 (economic review) should consider whether the 2-day timelock delay remains
   appropriate now that it is the only window between a passed vote and an irreversible action.
