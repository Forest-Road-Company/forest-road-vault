# ADR 0026 — Staked GROVE retains voting rights

**Status:** Accepted (Forest Road direction, 2026-07-20). Closes finding **L-02**. **Amends
ADR-0013** (governance: Forest-Road-controlled at launch) and extends ADR-0021 (sGROVE backstop
implementation). ADR-0024 is reserved by the unlanded sGROVE patch; 0025 is taken.

## Context

ADR-0013 says the full "`GROVE`/`sGROVE` governance machinery is built and wired". Only the GROVE
half was. `SGrove` is **not a token** — it holds `mapping(address staker => uint256) staked` with no
checkpoints of any kind. `FRGovernor` reads `getPastVotes(account, timepoint)`, so historical
per-staker stake was simply not queryable, and the practical consequence was worse than a missing
feature:

**Staking GROVE into the backstop silently disenfranchised the staker.** The GROVE moved into the
`SGrove` contract, so it stopped counting toward their delegate's balance votes, and nothing gave it
back. The protocol was therefore asking its most committed holders — the ones putting capital behind
cascade layer 2, locked for a 21-day unbond — to give up their governance voice to do it. That is a
direct incentive against funding the backstop the loss cascade depends on.

## Decision

**Staked GROVE keeps voting rights, per-staker. Unbonding GROVE does not vote. A staker is
self-delegated automatically on their first stake.**

Three pieces, no `FRGovernor` surgery (it already accepts any `IVotes`):

1. **`SGrove` inherits OZ `VotesUpgradeable`.** Voting units are the staker's **active** stake:
   `_getVotingUnits(a)` returns `staked[a]`. `stake` mints units, `requestUnstake` burns them.
   `clock()`/`CLOCK_MODE()` are overridden to the **timestamp** clock, matching GROVE.
2. **`SGrove` leaves its custodied GROVE undelegated.** This — and only this — is what prevents
   double counting. The staked GROVE contributes to nobody's balance votes and reappears exactly
   once, as the staker's sGROVE votes.
3. **A new `GroveVotesAggregator`** is the Governor's `IVotes` source:
   `getPastVotes(a, t) = grove.getPastVotes(a, t) + sGrove.getPastVotes(a, t)`.

### Unbonding does not vote

`requestUnstake` burns the voting units immediately, not at `claimUnstake`. Unbonding capital is no
longer backing the cascade, so it should not be steering the protocol either. The consequence,
stated plainly because it is not obvious to a user: **`requestUnstake` is irreversible and forfeits
that voting power for the full 21 days** — there is no `cancelUnstake`, so a staker cannot re-stake
to recover their voice. The UI must warn before the click.

### Auto-self-delegate on first stake

Voting units count for nothing until delegated (OZ's opt-in model), and a staker who had to discover
a second, separate `delegate` call would silently have no votes — the same class of failure the L-04
"governance dead on arrival" check exists to catch. So `stake` self-delegates when
`delegates(staker) == address(0)`.

That predicate conflates *never delegated* with *deliberately un-delegated*: a user who calls
`sGrove.delegate(address(0))` and later stakes again is silently re-self-delegated. Accepted.
Honouring the opt-out needs a `hasEverDelegated` flag and a storage tail-extension, for an outcome
the user can restore with one call. OZ's own `ERC20Votes` carries the same ambiguity.

**The call order in `stake` is load-bearing.** `_delegate` moves `_getVotingUnits(account)` — the
*current* stake — to the new delegate. Self-delegating **before** the balance increment moves the
old balance (zero on a first stake) and lets `_transferVotingUnits` book the increment once.
Self-delegating **after** the increment would move the new balance and then book `amount` a second
time — a silent double count. Both orders compile.

Be precise about which check catches it, because an earlier draft named the wrong one.
`totalVotingUnits() == totalStaked()` does **not** catch this: `_delegate` only moves votes between
delegates and never touches `_totalCheckpoints`, so the total is unchanged under the mutation. What
catches it is `invariant_sgrove_votesEqualDelegatedStake` (a zero-slack per-delegate equality),
backed by `invariant_votes_neverExceedGroveSupply` / `invariant_votes_pastReadsNeverExceedPastSupply`
(the double count breaches the supply bound) and the unit test pinning the
`delegate(0)`-then-re-stake path at 150 votes rather than 200. `totalVotingUnits() == totalStaked()`
earns its place against a different bug class: a dropped or duplicated mint/burn of voting units,
and a pre-L-02 in-place upgrade whose Votes namespace is empty.

### Quorum is sourced from GROVE alone — the easiest thing to get wrong

`getPastTotalSupply(t) = grove.getPastTotalSupply(t)`, **not** the sum.

GROVE's total supply already contains the staked GROVE — it is *held* by the `SGrove` contract, not
burned. Summing the two supplies would inflate the quorum denominator and silently raise the quorum
bar for everyone. Worse, it would be **actively exploitable**: a whale could stake immediately before
a proposal snapshot purely to raise the denominator and block a proposal it opposed, then unbond.
Sourcing quorum from GROVE alone eliminates that class entirely and makes the denominator a constant
— `GroveToken` mints once at genesis, has no other mint path, does not inherit `ERC20Burnable`, and
OZ `ERC20` reverts on transfer to `address(0)`.

The resulting property is `Σ votes ≤ getPastTotalSupply(t)`. **Equality is reachable, and is in fact
the intended launch state**: the treasury self-delegates the entire fixed genesis supply, so with
nothing undelegated and nothing mid-unbond the bound is tight. It becomes strict exactly to the
extent of undelegated GROVE plus GROVE sitting in the unbonding window — both of which are in the
denominator but votable by nobody. (An earlier draft said "strictly — never equality", which was
wrong in the ordinary case. The code has always used a non-strict `assertLe`.)

### The clock guard checks the value, not just the string

`GovernorVotes.clock()` and `CLOCK_MODE()` each wrap the token call in `try/catch` and **fall back
to block numbers** on failure — silently. Both vote sources checkpoint in timestamps, so that
fallback leaves every voter reading ~0 votes, or every proposal stuck `Pending` forever, with no
revert anywhere and every other deploy check green. It is the single most dangerous silent failure in
this design.

The aggregator's constructor therefore refuses to deploy unless both sources agree. An initial
version compared only the `CLOCK_MODE()` **string**, and a reviewer showed that is not enough: a
source can declare `"mode=timestamp"` while `clock()` returns `block.number`, and the string check
waves it straight through into the failure it exists to prevent. The guard now also compares the live
`clock()` value (`Aggregator_ClockValueMismatch`). Both halves are needed — the string is what
off-chain tooling and `Validate.s.sol` read; the value is what the checkpoint keys are actually made
of. `Validate.s.sol` re-asserts the mode strings on the live system, since both sources stay
upgradeable after deployment.

### The aggregator is immutable, and that buys less than it looks like

Every other module in this repo is a UUPS proxy administered by the timelock. `GroveVotesAggregator`
is a plain contract with no roles, no state and no privileged functions. `GovernorVotes` fixes its
token at `initialize` with no setter, so re-pointing the vote source is **not a parameter change** —
it requires a full `FRGovernor` UUPS upgrade through the timelock, with the same blast radius as any
other module upgrade. It is not *impossible*: `FRGovernor._authorizeUpgrade` is `onlyGovernance`, so
a passed proposal could ship an implementation that writes `GovernorVotesStorageLocation`. (An
earlier draft said "can never be re-pointed", which overstated it — and contradicted this ADR's own
Rejected-alternatives section two paragraphs later.) What freezing the aggregator buys is that the
**composition rule** cannot be changed without that full governance upgrade.

Be precise about what it does **not** buy: both underlying vote sources remain UUPS-upgradeable with
`UPGRADER_ROLE` on the timelock, and an upgraded `SGrove` could write arbitrarily into its ERC-7201
Votes namespace, including rewriting history. **Immutability freezes the composition, not the
inputs.**

It is deliberately absent from `PrivilegeAudit.moduleSet` and `HandoverOps._modules`, for the same
documented reason `FRGovernor` is: a `hasRole` scan reverts on a non-AccessControl target. The module
count stays **15**.

### Neither leg is wrapped in `try/catch` — a contested call, recorded

A reviewer proposed degrading the sGROVE leg to zero on revert, on the grounds that a broken `SGrove`
proxy would make `propose` and `castVote` revert forever, and — because `state`/`queue`/`execute` run
off the GROVE-only quorum path and still work — governance could never propose the fix. On the
production posture that is unrecoverable.

**Rejected, for three reasons.**

1. A swallowed revert silently drops every staker's votes. That is precisely the class CLAUDE.md
   prime directive 4 forbids.
2. It creates a *new* attack that fail-loud does not have: a relayer submitting someone's
   `castVoteBySig` with a tight gas limit could force the swallow for that voter alone (EIP-150's
   63/64 rule), consuming their signature at a reduced weight. Closing that needs an explicit gas
   floor and a magic constant.
3. **The pre-L-02 design already accepts exactly this risk for GROVE.** The Governor has always
   called `grove.getPastVotes` unwrapped, and `GroveToken` is equally UUPS-upgradeable. L-02 does not
   introduce a new class of risk; it doubles an accepted surface. Treating the two vote sources
   asymmetrically would be the anomaly.

**Flagged for the pre-mainnet audit as a deliberate, contested choice.** A reviewer who raises it is
not wrong, and should get this section rather than a patch. Reverting to the fail-closed leg is a
five-line change, isolated to `GroveVotesAggregator.getPastVotes`.

## Rejected alternatives

- **Make `sGROVE` a transferable ERC20Votes receipt token.** Rejected: ADR-0021 fixed positions as
  **non-transferable** so the 21-day unbond cannot be arbitraged away by selling the position, and a
  liquid receipt reintroduces exactly the front-run-a-known-loss-event risk the unbond exists to
  prevent.
- **Have `SGrove` delegate its custodied GROVE.** Rejected: it can only delegate the whole custody
  block to one address; per-staker attribution is the entire requirement.
- **Aggregate inside `FRGovernor`.** Rejected: it puts protocol-specific logic into an audited OZ
  governance contract, and the vote source would then only be replaceable by a governor upgrade.
- **`aggregator.delegates(a)` returning GROVE's answer.** Rejected: an account can have *different*
  delegates on the two sources, so any single return value is a silent partial truth. It reverts
  `Aggregator_DelegateOnSource`; `groveDelegates` / `sGroveDelegates` are the honest reads.

## Consequences

- **Fresh proxies only, for two independent reasons.** The Governor's token is immutable at
  `initialize`, so the aggregator cannot be retro-fitted. Separately and more dangerously, **`SGrove`
  itself is fresh-proxy-only**: on an in-place upgrade the `openzeppelin.storage.Votes` namespace is
  virgin while `staked` is populated, so a legacy staker's `requestUnstake` hits
  `_subtract(0, amount)` — checked arithmetic — and reverts `Panic(0x11)`. Stated precisely, because
  an earlier draft overstated it and a reviewer disproved the overstatement: their **active** stake
  becomes unwithdrawable, since only `requestUnstake` can create the unbond record `claimUnstake`
  needs. Anything **already unbonding** at upgrade time is still rescuable — `claimUnstake` touches
  no voting units and succeeds normally. No reinitializer can repair the trapped slice: the staker
  set is not enumerable. The safe precondition is therefore not "totalStaked reconciles" but the much
  narrower **every `staked[x] == 0` at upgrade time**. A second, independent failure of the same path:
  `__EIP712_init` only runs inside the already-spent `initialize`, so the upgraded proxy carries an
  **empty EIP-712 domain** and `delegateBySig` would sign against `keccak256("")`.
  `test/audit/L02_FreshProxyOnly.t.sol` makes all of this executable rather than merely documented.
  This reinforces the PM-R-10 fresh-redeploy requirement; it does not create a new one.
  Note that `clock()`/`CLOCK_MODE()` are `view`/`pure` overrides in the implementation, so they
  **survive** an in-place upgrade unchanged — the clock assertions would report green on a bricked
  proxy. `totalVotingUnits() == totalStaked()` is the only check that catches it.
- **The deployed Sepolia stack cannot be upgraded into L-02.** `Validate.s.sol` now fails loudly and
  legibly on a manifest with no `.votesAggregator` key.
- **A guardian pause now freezes the electorate.** `stake` and `requestUnstake` are `whenNotPaused`,
  so pausing `SGrove` no longer merely freezes staking — it freezes the *composition* of the sGROVE
  electorate, and a pause timed just before a proposal snapshot locks in the current distribution.
  `delegate`/`delegateBySig` are inherited and deliberately **not** pausable (delegation moves no
  value, and a pausable `delegate` would be a stronger censorship lever), and all vote **reads** are
  unaffected, so the Governor itself never stalls. Recorded in `docs/threat-model.md` and the
  Permissionless section of `docs/access-control-matrix.md`.
- **The retained-admin posture's blast radius widens, and the owner should see it stated.** sGROVE
  now reports historical voting power. `DEFAULT_ADMIN_ROLE` administers `UPGRADER_ROLE`, so a holder
  can self-grant `UPGRADER` on `SGrove` and ship an implementation that writes **retroactive votes at
  any past timepoint** — defeating any future proposal to remove that key. Combined with the treasury
  holding the genesis supply, the key becomes structurally unremovable by governance. This does not
  reopen the owner's deliberate `KEEP_OPS_ADMIN` decision; it reports a change in what that decision
  costs. `Validate.s.sol` prints it in the RETAINED PRIVILEGE block.
- **`SGrove` gains new permissionless external mutators**: `delegate(address)` and
  `delegateBySig(...)`, inherited from `VotesUpgradeable`. Added to the access-control matrix.
- **`SGrove.initialize` must call `__EIP712_init` explicitly.** `__Votes_init()` and
  `__Votes_init_unchained()` are **empty** in OZ 5.4.0 — they do not seed the domain, and
  `GroveToken` only gets one via `__ERC20Permit_init`. Omitting it fails *silently*:
  `eip712Domain()`'s uninitialized guard passes on a never-initialized contract, so `delegateBySig`
  would sign against `keccak256("")` for name and version. Not a replay risk (chainid and
  `verifyingContract` still bind) but a real signing-UX break.
- **The L-04 governance-liveness checks now read through the aggregator.** Post-L-02, treasury GROVE
  staked into `SGrove` leaves the GROVE electorate and reappears in the sGROVE one. Reading
  `grove.getVotes` alone would report a fully-staked treasury as having zero votes and revert
  `GovernanceDeadOnArrival` on a perfectly healthy system — blocking the one-command handover for the
  full 21-day unbond with no faster recovery. Both `Validate.s.sol` and `Handover.s.sol` were fixed,
  consulting each source's own delegate since the two delegations are independent.
- **Storage is safe with no tail extension at all.** `VotesUpgradeable` drags in three new ERC-7201
  namespaces (Votes, EIP712, Nonces), all disjoint from `SGroveStorage` and from AccessControl,
  Pausable, ReentrancyGuard and Initializable. `SGrove` has an empty root storage layout, so there is
  no legacy-slot surface to collide with, and `SGROVE_STORAGE_LOCATION` is a `bytes32 constant` that
  inheritance order cannot move — the `base + 10` slot-pinning test in `SGrove.t.sol` is unaffected.
- **Voting power appears on stake and vanishes on exit.** A user who never delegated GROVE, stakes
  (and is auto-self-delegated), then claims their unstake 21 days later ends with GROVE in their
  wallet and `grove.delegates(user) == address(0)` — zero votes. Not a bug, but it inverts intuition:
  the UI must show "your voting power" as `grove.getVotes(x) + sGrove.getVotes(x)` and prompt for a
  GROVE delegation after a full exit.
- **Governance weight does not track economic exposure.** `coverShortfall` draws only from the USDfr
  coverage reserve and never touches `staked` (ADR-0021: GROVE is never converted, slashed or
  seized), so a staker whose coverage has been fully drained retains 100% of their voting weight.
  Consistent with ADR-0021, and stated here so it is not rediscovered as a finding.
- **Staking is not a vote-buying vector.** `castVote` reads `getPastVotes` at a strictly past
  snapshot and `propose` reads `getVotes(proposer, clock() - 1)` — one *second* ago under a timestamp
  clock, which no same-transaction flash loan reaches. Accumulating stake before a snapshot is
  possible, but it is inherent to OZ Governor, identical for plain GROVE, and *dominated* by simply
  holding GROVE: the sGROVE route costs an additional 21-day exit lock for the same weight.

## Verification

Recorded in `STATE.md` with measured numbers — test totals, per-module coverage, the invariant run
counts, and the Slither triage. No number appears here that was not actually run.
