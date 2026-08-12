# ADR 0033 — Persistent reserve-loss interlock and ordered custody cascade

**Status:** Implemented locally on 2026-08-07; not release-cleared. ADR-0035 supersedes only the
per-event-cap element; the authenticated incident and ordered custody cascade remain current.

Forest Road accepted the `CURATOR-INSOLVENCY-LOCK` policy for a genuine residual insolvency after
the ordered cascade is exhausted. This decision does not close the repository's independent G1c,
G2, G3, G4, Timelock-migration, deployment, or operational blockers.

## Context

An unaccounted reduction in canonical USDC custody creates two distinct problems:

1. users and curators must not exit at the old par value while the loss is unresolved; and
2. once governance adjudicates the loss, backing and supply must be reduced through the protocol's
   locked curator → sGROVE → senior waterfall.

The former expiry-based C-01 pre-arm did not satisfy those requirements. Changes to live Governor
timing could make an arm permanently unresolvable, degraded timing dependencies created one-way
latches, and a view-only timestamp boundary could silently release the freeze without a
transaction or event. Tests incorrectly described those outcomes as safety properties. That
design is superseded in full by this ADR.

The replacement also closes two related accounting requirements:

- one custody incident must retain one durable arm-derived identity across every governance-
  recognized tranche; under ADR-0035 that identity is observability, not a coverage allowance; and
- USDC recovered after a write-down must be creditable as backing without minting USDfr, including
  when it returns after the incident was finalized.

## Decision

### 1. Objective observation is reversible

`ReserveManager` continuously derives a native-unit custody shortfall as:

`max(idleUSDCUnits - canonicalUSDC.balanceOf(ReserveManager), 0)`.

This is an objective balance fact, not a caller-supplied assertion. Every accounted outflow lowers
`idleUSDCUnits` before transferring USDC, while deposits and payments require exact receipt before
raising it. A permissionless call to `reconcileIdleUSDC()` therefore only emits the recorded,
live, and shortfall values; it does not change backing, open an incident, or move junior or senior
capital. `observeIdleUSDC()` exposes the same values without emitting.

The objective predicate immediately locks the protected exits. Returning the missing USDC clears
that observational predicate automatically. Equality does not lock, a surplus does not become
backing, and one native unit means one micro-USDC, not one whole USDC.

The legacy arbitrary-amount `writeDownIdleUSDC(uint256)` selector remains only as an always-
reverting ABI tombstone. Operator tooling and proposals must use the arm-bound functions below.

### 2. A Guardian arm is persistent and singular

`armReserveLossFreeze(evidenceHash)` is Guardian-only. It:

- allocates a monotonically increasing internal `armId`;
- derives the sole permitted custody `incidentId` from that arm;
- locks curator withdrawals and new senior queue settlement immediately; and
- emits both identifiers and the evidence commitment before any amount-bearing proposal is
  published.

An active arm has no timestamp expiry and no dependency on mutable Governor or Timelock timing.
The Guardian cannot replace, extend, renew, or release it. Disabling Guardian arms prevents future
arms but never clears an existing arm. This removes silent expiry, timing drift, degraded-timing
deadlock, and repeated re-arm behavior from the state machine rather than attempting to special-
case them.

The accepted cost is explicit: a Guardian can freeze both protected exits until governance acts.
Recovery is action-bounded, not time-bounded; governance liveness has no hard upper bound. Public
disclosure of an adjudication amount is safe against withdrawal front-running because both exits
are already locked before proposal publication.

### 3. Incident identity is structurally bound to the arm

Facility events occupy `[0, 2^255)`. A valid arm is nonzero and below `2^255`, and its custody event
is:

`incidentId = type(uint256).max - armId`.

The library checks the input range and asserts that the result is in the upper namespace. Call
sites assert the same post-condition. `ClaimBridge` separately prevents facility IDs entering that
upper namespace.

`ratifyAndOpen` does not accept an incident nonce. Every tranche under one arm must reuse the
derived ID and the Guardian's armed evidence commitment. A mismatched evidence hash reverts before
recognition, making both incident substitution and sGROVE cap multiplication unrepresentable. A
used custody ID cannot be reopened, and a new cap requires a new arm after the prior arm reaches a
terminal state.

### 4. Governance transitions are mutually exclusive at execution

All transitions re-read canonical state when they execute. An open Timelock executor therefore
cannot choose an economic outcome by racing two ready operations.

| State at execution | Valid transition | Result |
| --- | --- | --- |
| Shortfall = 0; no incident, recognized loss, deficit, or direct insolvency | `cancelAndDisable` | Consumes the unused arm and disables future Guardian arms |
| `0 < shortfall <= approvedMaxLoss` | `ratifyAndOpen` | Writes down and absorbs exactly the live shortfall under the arm-derived incident |
| `shortfall > approvedMaxLoss` | None | Reverts without accounting changes; the same arm and locks remain |
| Shortfall = 0; the arm-derived incident or a deficit remains | `finalizeAndDisable` after its recovery conditions hold | Resolves the deficit if directly cured, closes the incident, consumes the arm, and disables future arms |

`ratifyAndOpen(expectedArmId, evidenceHash, approvedMaxLoss)` requires `RESERVE_ADMIN_ROLE`. It:

1. rejects a stale or absent arm;
2. requires the proposal's evidence hash to equal the Guardian's armed commitment;
3. derives the current shortfall from the canonical token balance;
4. rejects a cured shortfall and rejects an amount above the voted ceiling;
5. opens or reuses only the arm-derived incident;
6. writes down exactly the current shortfall; and
7. executes the ordered cascade atomically.

A shortfall that shrinks before execution charges only the smaller live amount. A growing
shortfall that outruns the approved ceiling remains frozen and requires a replacement proposal
against the same arm and incident. This `GROWING-SHORTFALL-LIVELOCK` is safe for accounting but has
no automatic liveness guarantee; operations must contain the drain before proposing and use an
explicit, justified deterioration buffer.

`cancelAndDisable` performs the opposite execution-time check. Any live shortfall, incident,
recognized loss, deficit, or direct insolvency makes it revert. A cancellation queued while funds
are healthy therefore cannot release the interlock if a loss appears before execution.

`finalizeAndDisable` is the fourth-state terminal transition. It requires:

- the matching arm-derived incident;
- no live shortfall;
- no unabsorbed recognized loss;
- no physically returned recovery that is eligible but still uncredited; and
- direct `totalUSDfr() <= backingValue()` solvency.

It then clears a cured recorded deficit, closes the incident, consumes the arm, and disables
future Guardian arms in one transaction. It never briefly releases the interlock between those
steps.

### 5. Both junior and senior exits share one interlock

`reserveLossExitsLocked()` is true if any of the following is true:

- a persistent arm exists;
- an adjudicated custody incident exists;
- a recognized supply reduction remains unabsorbed;
- a reserve deficit remains latched;
- the objective native-unit shortfall is positive; or
- the controller is absent, unreadable, or directly insolvent.

`CuratorModule.withdrawFirstLoss` reads this predicate through a typed call and fails closed.
`RedemptionQueue.closeEpoch` reads the same predicate before creating new fills. Already-filled
claims remain claimable; the interlock prevents new senior settlement rather than confiscating an
existing claim.

This shared lock prevents either cohort escaping while the other remains exposed. It is an interim
measure: any future sub-par senior settlement must price from a post-cascade residual senior rate,
not charge seniors before curator and sGROVE capital are applied.

### 6. Adjudicated losses use the locked waterfall

For each ratified live shortfall:

1. existing backing surplus absorbs the portion that does not require a supply burn;
2. all five curator pools absorb pro rata by their pre-call balances, skipping zero allocations
   and placing integer dust deterministically in the lowest numbered pools with headroom;
3. sGROVE absorbs from the whole live reserve; one tranche may exhaust layer two, after which
   senior principal absorbs subsequent loss until replenishment;
4. every USDfr received from the junior layers is burned;
5. vested senior-vault assets absorb only the residual; and
6. any remaining deficit is recorded and emitted instead of rolling the backing write-down back.

Each burn is checked as an exact non-worsening reduction in the live `supply - backing` deficit.
Mint and redemption retain the absolute backing invariant. Later custody losses do not
short-circuit merely because a prior deficit is latched; newly available junior and senior capital
is still consulted.

Custody coverage uses only sGROVE's incident ledger. It must not write facility-default
consumption or F-18-01 attribution fields. Reduced remaining sGROVE capacity may legitimately
affect future impairment; fabricated facility consumption may not.

### 7. Returned custody capital is creditable without issuance

Each ratified tranche increases an arm-specific recovery ceiling in native USDC units by exactly
the written-down amount. `creditRecoveredIdleUSDC(armId, evidenceHash)` requires
`RESERVE_ADMIN_ROLE` and may credit only:

`min(liveUSDC - recordedUSDC, remainingRecoveryCeiling)`.

The function raises `idleUSDCUnits` without minting USDfr and decrements the immutable remaining
ceiling. Ordinary donations beyond that ceiling remain unrecognized. The ceiling survives incident
finalization, so late recovery cannot become permanently stranded merely because governance
already closed the arm.

Crediting recovered capital does not remint claims that the cascade already burned. It restores
backing for the surviving protocol and makes the returned asset visible to accounting. If recovery
arrives before finalization, finalization requires it to be credited first; if it arrives later,
the same capped function remains available.

### 8. Residual insolvency policy

Forest Road accepts that a genuine residual `totalUSDfr() > backingValue()` after surplus,
curator capital, permitted sGROVE coverage, and senior assets are exhausted keeps both protected
exits locked until measured recovery or recapitalization restores direct solvency.

This may lock third-party curator capital indefinitely if governance never acts. There is no
implemented generic wind-down path, so documentation must not present wind-down as an existing
escape. A future wind-down requires its own reviewed one-way accounting and pro-rata settlement
state machine.

## Access and deployment consequences

- Guardian may create one persistent arm but cannot release or renew it.
- `RESERVE_ADMIN_ROLE` may ratify bounded live losses and credit capped physical recovery.
- `DEFAULT_ADMIN_ROLE` may cancel a clean arm, finalize a resolved incident, and enable or disable
  future Guardian arms.
- ReserveManager must remain wired to the controller, CuratorModule, sGROVE, senior vault,
  Governor, and Timelock; the latter two remain wiring qualifications but are not runtime clocks
  for an active arm.
- CuratorModule and RedemptionQueue must be wired to the same ReserveManager.
- The controller, cascade-module, and CuratorModule reserve-manager bindings cannot be changed
  while a persistent arm, objective shortfall, incident, unabsorbed loss, recorded deficit, or
  direct insolvency is active. An implementation upgrade keeps the stable proxy address and does
  not require repointing.
- The old expiry/timing storage fields remain reserved forever; the persistent arm fields are
  appended after them.
- The arbitrary write-down selector is disabled and must not appear in new proposals or operator
  runbooks.

## Operational response

For a suspected or observed custody loss:

1. arm the interlock before publishing an amount-bearing proposal;
2. pause affected value paths and contain any continuing drain;
3. snapshot the canonical shortfall and choose a documented maximum with a deterioration buffer;
4. monitor the shortfall through execution;
5. ratify only while the live amount is positive and within the approved maximum;
6. reuse the same arm for every tranche;
7. credit any returned USDC against that arm's recovery ceiling; and
8. finalize only after the incident is terminal and direct solvency is restored.

If the live loss exceeds the voted ceiling, neither cancellation nor ratification is valid. Leave
the same arm locked and repropose; do not create a new arm to obtain another sGROVE cap.

## Rejected alternatives

- **Automatic or view-only expiry:** can release without a transaction and silently depends on
  mutable governance timing.
- **Live-derived timing hashes and degraded arms:** created the deadlock classes this replacement
  removes.
- **Guardian renewal or cancellation:** permits indefinite repeated DoS or lets the key that armed
  protection remove it.
- **Observation-only locking:** leaves suspected but not yet visible losses exposed during public
  governance disclosure.
- **Adjudication-only locking:** leaves objectively missing custody available for par exits during
  the governance delay.
- **A caller-selected incident nonce:** permits accidental or deliberate multiplication of the
  sGROVE cap.
- **One permanent protocol event ID:** shares one lifetime cap across unrelated incidents.
- **Odd/even IDs:** sequential facility IDs already occupy both parities.
- **Senior-first absorption:** reverses the locked loss waterfall.
- **Revert on an unabsorbable loss:** preserves phantom backing and minting against missing USDC.
- **Automatic remint on recovery:** recreates claims without a distribution rule and can overstate
  liabilities.
- **Treating every surplus as recovery:** turns arbitrary donations into backing without an
  adjudicated ceiling.

## Verification and acceptance

The implementation must retain all of the following evidence before release review:

- explicit replacement tests state that timing deadlock and timestamp-only release were previously
  asserted as safe and are now rejected;
- native-unit equality, one-unit shortfall, one-unit returned capital, and donation-surplus
  boundaries;
- cured, reduced, exact, over-ceiling, repeated-tranche, and fourth-state execution cases;
- pre- and post-finalization recovery credits without minting;
- arm-derived upper-namespace IDs and same-ID sGROVE cap reuse;
- curator and queue interlock coverage;
- ordered curator → sGROVE → senior allocation, later-loss handling, residual-deficit latching,
  value conservation, and F-18-01 isolation;
- append-only field layout plus derived ERC-7201 namespace-slot checks; and
- a complete guard → deletion mutation → catching tier → expected failure table for the new state
  machine.

Current repository evidence on 2026-08-07:

- ReserveManager focused units: **27 passed / 0 failed / 0 skipped**;
- affected CuratorModule, DefaultManager, and RedemptionQueue units: **151 passed / 0 failed /
  0 skipped** before the two final ReserveManager recovery additions, for **178 focused tests** in
  the current combined source;
- production-cascade invariants: **11 passed / 0 failed / 0 skipped**, each invariant at 256 runs ×
  128 calls with zero handler reverts;
- source storage gate: **26 structs and 16 ERC-7201 namespace slots passed**;
- compiled storage gate: **26 structs passed**;
- optimized sizes: ReserveManager **21,885 bytes** with **2,691 bytes** EIP-170 margin;
  CuratorModule **12,146 bytes**; RedemptionQueue **12,536 bytes**; and DefaultManager
  **22,654 bytes**; and
- full 272-file optimized compilation succeeds with warnings permitted; the repository-wide strict
  warnings mode remains noisy because of pre-existing lint findings and ignored audit-mount path
  diagnostics.

These receipts validate the implementation but do not make the replacement deployment a GO. The
repository recommendation remains **NO_GO** until every independent mandatory blocker and the
complete release campaign are reconciled.
