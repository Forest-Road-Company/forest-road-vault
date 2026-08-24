# ADR 0034 — Sub-par exit pricing must follow the loss cascade at all times

**Status:** Accepted (Forest Road direction 2026-08-07). Amends the exit-pricing half of
[ADR-0022](0022-redemption-cooldown-and-conservative-nav.md) and constrains the sub-par redemption
mechanism introduced by audit round R16. Does not reopen the locked three-layer cascade
([ADR-0004](0004-anchor-curator-first-loss.md), [ADR-0014](0014-sgrove-backstop-parameters.md)) — it
requires that the cascade be honoured on a path that currently bypasses it. The disclosure
consequences below are **counsel-review** and must clear before mainnet.

## Context

Audit round R16 replaced the senior-exit **freeze** with **sub-par redemption**: rather than refusing
`MintRedeemController.redeem` while the protocol is short, the controller now settles the exit at a
coverage ratio below par. The freeze was a real defect — it deadlocked exits precisely when holders
most needed them, and it disabled its own cure — so replacing it is correct in direction.

Four independent adversarial reviews of R16 established that the replacement, as implemented, prices
the exit off the **gross** book mark:

- `MintRedeemController._quoteRedeem` derives its price from `backingValue()`, i.e.
  `ReserveManager.totalBackingValue()`, which nets **nothing** against junior capital.
- The senior `sUSDfr` path prices off `DefaultManager.pendingSeniorImpairment()`, which **does** net
  against curator first-loss per class and then the global sGROVE backstop (the ADR-0022
  conservative-redemption NAV).

So two redemption paths in the same tree price off two different bases, and the direct path is the
un-netted one. A holder redeeming while curator first-loss capital is still intact therefore absorbs
a loss that the junior tranche was contracted to take first. A reviewer characterised the composite
effect as "the locked three-layer cascade run backwards": the exiting holder takes the haircut, and
when the conservative mark is later released the recovered value does not return to them — it
reappears as `mintableHeadroom()` and is paid to the `sUSDfr` vault as yield.

The tree also asserts two contradictory positions. `DefaultManager.realizeLoss` refuses to allocate a
loss beyond absorption capacity, on the stated ground that doing so "would impair unstaked USDfr
holders, who sit outside the §1.3 cascade entirely" — while the sub-par exit path impairs exactly
those holders, silently, at the gross mark.

## Decision

### X — All capital is at risk, and losses are borne in cascade order at all times

Forest Road's direction, verbatim: *"whilst we have a junior tranche that takes first loss, all
capital is at risk and there is a risk of the senior being impaired"*, and *"in cascade order at all
times"*.

This resolves two questions that had been conflated:

1. **Is the senior impairable?** Yes. The protocol does not represent senior capital as protected
   from loss. Sub-par exit is therefore the correct mechanism, not a defect to be reverted.
2. **In what order?** Strictly the §1.3 cascade — curator first-loss, then the sGROVE backstop, then
   senior — **on every path, at all times**, including the direct redemption path. "All capital is at
   risk" and "junior takes first loss" are not in tension; the second is the ordering constraint on
   the first.

Unstaked USDfr holders are consequently **in** the risk-bearing set, positioned **last**. The
`realizeLoss` rationale quoted above is superseded: it is no longer correct that they "sit outside
the §1.3 cascade entirely". They sit at the end of it.

### Y — The direct exit prices off the post-cascade residual

`MintRedeemController.redeem` and `previewRedeem` must derive the sub-par price from the
junior-netted residual — the quantity the protocol already computes as
`DefaultManager.pendingSeniorImpairment()` and already uses for the senior path — rather than from
gross `totalBackingValue()`.

This preserves sub-par exit (all capital at risk) while restoring cascade order (juniors absorb
first). It requires no new valuation machinery: it reuses an existing, already-audited number, and it
makes the two redemption paths consistent, which removes a class of "which basis?" defects. Three of
the four R16 reviews independently found a second instance of that same class in
`mintableHeadroom()`.

An equivalent alternative — atomic reservation of junior absorption at the moment of exit — is
acceptable if it proves cheaper in bytecode, provided the ordering property below holds.

### Z — Ordering is an invariant, not a code comment

"At all times" is an invariant claim and is to be encoded as one, per CLAUDE.md §1.3, as a stateful
fuzz property rather than a unit assertion. The existing campaigns cannot currently catch a violation:
the only handler that models a custody shortfall has eight actions and **none of them mints yield or
distributes**, so the custody × credit-layer seam is unexercised across the whole suite.

Required, at minimum:

- a handler action that drives the protocol under-backed and then redeems, and
- an invariant asserting no redemption sequence allows a senior or USDfr holder to absorb loss while
  unexhausted junior capital remains — equivalently, that no exit leaves a remaining holder worse off
  than a simultaneous exit would have.

### W — Slippage protection is required independently

R16 turned `redeem` into a variable-price operation while retaining the fixed-price
`redeem(uint256)` signature, with no minimum-out and no deadline. A review measured settlement
**44% below the quoted price** when a non-timelocked `recordPrincipalWritedown` landed between quote
and settlement. `redeem` must take a minimum-out and a deadline. This is required whichever pricing
basis is chosen and is not contingent on X–Z.

**How W is implemented, and where it deliberately diverges (added 2026-08-20, raised by Cantina
Managed).** The requirement above is stated flatly. The implementation satisfies it for the
canonical form and knowingly does not for two legacy ones, so the shape is recorded here rather
than left for a reader to discover.

`MintRedeemController` exposes three external forms, which are **not** equivalent:

| Form | Minimum-out | Deadline | Status |
|---|---|---|---|
| `redeem(uint256)` | par floor, supplied internally | none | safe without one, by arithmetic |
| `redeem(uint256,uint256)` | caller-named | none | **residual timing exposure** |
| `redeem(uint256,uint256,uint256)` | caller-named | enforced | **canonical** |

`redeem(uint256)` passes `usdfrAmount / SCALE` as the floor. Since `usdcOut` can never exceed
`usdfrIn / SCALE`, that floor equals the maximum achievable payout, so the form settles at **exactly
par or reverts**. It needs no deadline: a transaction held in the mempool sells no option, because
any downward move in the ratio reverts it rather than settling it worse. This is the same property
that makes the form safe against silent impairment — a haircut requires the caller to name the price
they will accept.

`redeem(uint256,uint256,uint256)` enforces the deadline with `Controller_DeadlinePassed`, falsified
by `test_Y_G08_theDeadlineRefusesAnExpiredRedemption`. It is the form integrators should use.

`redeem(uint256,uint256)` is the genuine divergence from W and is recorded as such. A caller-named
floor without a deadline bounds price but not time, which is the free option W exists to close: a
redeemer who sets `minUsdcOut` at a healthy mark and is not included for some time hands a searcher
the ability to withhold the transaction until the ratio decays to that floor and then include it.
Every path that moves the ratio down is untimelocked and publicly visible before it lands —
`recordPrincipalWritedown`, `reconcileIdleUSDC`, and a timelock's own
`recognizePrincipalImpairment`, whose ready transactions anyone may execute.

**Why the legacy forms were not simply given deadlines.** Attaching a new expiry semantic to an
unchanged signature is the mistake R16 made and R17 was written to correct: every caller compiled
against the old signature keeps compiling and begins behaving differently. A silent semantic change
on a live signature was judged worse than a documented migration path. That reasoning is sound for
`redeem(uint256)`, where the par floor closes the gap by arithmetic. It is **weaker** for
`redeem(uint256,uint256)`, where nothing closes it.

**Residual exposure and disposition.** The application uses `redeem(uint256)` exclusively
(`frontend/src/lib/abi.ts` declares only that signature), so the exposed form is reachable only by a
direct integrator who names a floor and omits a deadline, and the loss is bounded by the distance
between the price at broadcast and the floor that integrator chose. Opt-in and self-bounded, but
real. Removing the two-argument signature is an ABI break and therefore an upgrade decision, not one
for mainnet v1. Until then the exposure is disclosed here, and integrators are directed to the
three-argument form.

**What `previewRedeem` publishes, and one pause surface it misses (added 2026-08-24, raised by
Cantina Managed).** Two properties of the published quote are stated in the source but were not
visible from this ADR, and an integrator should not have to open the contract to find them.

First, **the quote is a lower bound, not an estimate.** `previewRedeem` passes `drawn = 0` into
`_quoteRedeem`, so below par it publishes the undrawn price while `redeem` settles at the
junior-drawn price, which is equal or better and never worse. Passing the published number straight
back as `minUsdcOut` therefore cannot revert on slippage, and that direction is what makes the gap
safe. The draw is not simulated because sizing it needs live junior capacity from the five curator
pools and the shared sGROVE reserve, neither of which is reachable from the controller, and
publishing it from `DefaultManager` measured 218 bytes in a contract with 183 remaining. Anyone
tempted to "fix" the undrawn quote should note that moving it in the other direction would make the
published number unsafe to use as a floor.

Second, **the view consults the controller pause and the USDfr pause but not the `ReserveManager`
pause**, while `ReserveManager.releaseUSDC` carries `whenNotPaused`. With the reserve paused the
view publishes a full quote that no redemption can settle. Nothing is at risk: the redemption
reverts inside `releaseUSDC` before any state is written, so no USDfr is burned, no USDC moves, no
holder is impaired and nothing is extractable by acting on the stale number. The defect is a
published figure that will not execute, during a state that is itself an incident response. Until
the controller is next opened, an integrator should read `ReserveManager.paused()` alongside the
quote. An earlier internal sweep closed the other two pause surfaces on this view, which is why the
tests around it are named `test_S3_F3_previewRedeemQuotesAFullPriceWhileRedemptionIsPaused` and
`test_S3_F3b_previewRedeemQuotesAFullPriceWhileTheTokenPauseClosesTheBurn`; the reserve is the third
sibling of that family and was missed.

Separately, `_quoteRedeem` computes `usdfrIn + drawn` before any size check, so a max-sized
`usdfrAmount` on the under-backed branch panics with `Panic(0x11)` instead of returning a controller
error. No funds are at risk, since no caller can hold or burn such an amount, and the addition does
not exist on the whole-backed branch because `_exitDrawTarget` returns zero there. The intended
remedy is a `usdfrIn <= supply` bound rather than a balance read: the controller already holds the
supply as a local, no holder can exceed total supply, and `drawn` is clamped to the standing deficit,
so the bound makes the overflow unrepresentable rather than merely unlikely.

All three of these are accepted as known limitations of mainnet v1 and are queued for the next
controller upgrade alongside the ADR-0033 §5 interlock consumption. Reproductions are committed at
`contracts/test/audit/PoC_CantinaI3_PreviewVsReservePause.t.sol` and
`contracts/test/audit/PoC_CantinaI1_OversizedRedeemPanics.t.sol`.

### Y-bis — the junior draw is ATOMIC with the exit (Forest Road, 2026-08-08)

Y as first written said "price off the post-cascade residual" and treated the atomic reservation of
junior absorption as an alternative mechanism. **Implementation scoping established they are not
alternatives.** The residual price is LARGER than gross-marked backing, and the difference is not in
`ReserveManager`'s USDC — it sits in the curator pool and the sGROVE backstop. Quoting the residual
rate without moving that capital returns a number `releaseUSDC` cannot settle: either a fresh deadlock
in the exact state Y exists to cure, or the quote/settlement divergence an adversarial review already
measured at 44% below quote.

**DECISION: draw.** Junior capital is drawn at the moment of the senior exit, in the same transaction,
to fund the cascade-ordered price. Cascade order is thereby enforced AT SETTLEMENT rather than assumed.

**The cost, accepted explicitly rather than discovered later.** The mark that triggers the draw is a
CONSERVATIVE, REVERSIBLE estimate (`recognizePrincipalImpairment`), not an adjudicated loss. So a draw
crystallises junior capital against a loss that may not materialise. If the mark later reverses, the
junior has borne a loss that did not happen and the beneficiary was a holder who has already exited and
cannot be clawed back. Forest Road accepted this on 2026-08-08 in preference to the alternative, which
is that a senior absorbs a loss the junior contracted to take first — a violation of the §1.3 cascade
this ADR exists to enforce.

Two options were considered and rejected in reaching it. **Clamping** the residual rate to available
liquidity is cheap and moves no value, but degrades to the gross rate precisely when junior capital
matters most, so it does not deliver decision X in the states that matter. **Paying the gross price
plus a claim on the reversal** avoids crystallising anything early and is the only shape where nobody
pays for an estimate, but requires per-exit residual-claim machinery that does not exist.

**Implementation requirements (none optional):**
- The draw is ATOMIC with the redemption. A quote that cannot be funded must not be issued.
- The draw respects cascade ORDER within the junior layers: curator first-loss per class, then the
  global sGROVE backstop — never inverted, never skipping.
- The draw must not exceed what the cascade would have absorbed anyway; it brings absorption FORWARD in
  time, it does not enlarge it.
- Decision Z's stateful invariant must cover the drawn path: no exit may leave a remaining holder worse
  off than a simultaneous exit would have, and no exit may absorb loss while unexhausted junior capital
  remains.
- `withdrawFirstLoss`'s existing locks (`Curator_ClassDefaultFrozen`, and the subordination requirement
  that locks capital protecting live exposure) already prevent junior capital escaping ahead of a
  crystallisation. They are load-bearing for this decision and must not be relaxed.

### Y-ter — X governs REALIZATION order; Y-bis governs EXIT pricing (clarification, 2026-08-19)

Raised in external review (Cantina): X states the cascade applies *"on every path, at all times,
including the direct redemption path"* and places unstaked USDfr holders **last** — behind senior.
Y-bis's implementation requirements name only layers 1 and 2, and `drawForSeniorExit` stops at the
sGROVE backstop. Which is normative on the direct path?

**Y-bis is normative on the direct path.** The two decisions govern different operations, and the
original wording did not say so:

- **X governs the order in which a realized loss is BORNE.** `DefaultManager.realizeLoss` implements
  it in full, burning curator first-loss, then the sGROVE backstop, then sUSDfr vault principal, and
  pairs the burns with the principal write-down. Unstaked USDfr holders sit at the end of that order,
  exactly as X states.
- **Y-bis governs the price an exit SETTLES AT, and the draw that funds it.** The draw is a *junior*
  draw. sUSDfr is not junior capital, so it is not drawn from.

Three reasons this is the right scoping rather than an omission:

1. **Funding an unstaked exit from the vault would invert the tranche economics.** sUSDfr holders
   take yield-compensated risk and sit ahead of unstaked holders in the loss order. Paying an
   unstaked exit out of staked principal moves value the wrong way along that ordering.
2. **Layer-3 absorption carries a write-down that the exit path cannot perform.** `realizeLoss` burns
   vault principal *and* records the paired principal write-down. A draw has no facility to write
   down, so drawing from layer 3 would reduce senior principal without recording why.
3. **Requirement 3 already bounds it.** The draw "brings absorption FORWARD in time, it does not
   enlarge it." Layer-3 absorption only becomes something to bring forward once a loss is realized —
   and at that point `realizeLoss` performs it directly.

**What this leaves, stated honestly.** The deficit that makes an exit sub-par comes from
`recognizePrincipalImpairment` (`DEFAULT_ADMIN_ROLE`, timelock, 2-day delay), which is deliberately
*reversible*. `realizeLoss` is permanent and separately gated (`SERVICER_ROLE`). Between a
provisional mark and a realized loss there is a window in which an unstaked holder who exits absorbs
their share while the vault is untouched. That is a **sequencing property, not an ordering
inversion** — sUSDfr absorbs on the realization trigger rather than the exit trigger — and during a
genuinely provisional mark it is the correct outcome: the book is worth less, and "all capital is at
risk" means the exiting holder bears that.

**Operational consequence (belongs in the runbook, not in code).** When queuing
`recognizePrincipalImpairment`, state explicitly whether the loss is *provisional* (mark only) or
*determined* (mark plus `realizeLoss` immediately following execution). The 2-day timelock delay is
sufficient to stage the Safe batch for the determined case.

**Revisit trigger.** This scoping is recorded as a decision, not a permanent constraint. It should be
re-examined before KYC mint/redeem is opened to external participants. The change would be contained
if made: the draw source is resolved dynamically via `ReserveManager.lossAbsorber()` behind an
authorised-source check, so a three-layer absorber can replace the current one without new storage or
redeployment. Decision Z's stateful invariant must be extended to cover the new branch in the same
change — an uncovered path makes the invariant vacuous for it.

## Alternatives considered

- **Retain the freeze.** Rejected: it deadlocks exits in exactly the state they matter, and disables
  the cure for that state. This is the defect R16 was written to fix.
- **Keep gross-mark pricing.** Rejected: it inverts the locked cascade and contradicts the decision
  above. It also contradicts `realizeLoss`, so the tree would continue to assert two positions.
- **Queue the direct redemption** so it settles at the post-cascade mark once absorption is known.
  Not chosen: it reintroduces a wait for holders the cooldown does not otherwise bind, and ADR-0022
  already governs the queued path.

## Consequences

- Sub-par exits remain available in all states; they no longer subordinate junior capital.
- Recovered value on a released mark must not accrue to the `sUSDfr` vault ahead of holders who
  absorbed the corresponding haircut; the R16 follow-up work nets the crystallised haircut out of
  `mintableHeadroom()` for this reason.
- **Counsel-review, blocking:** offering materials and the dashboard must state plainly that all
  capital is at risk, senior included. The dashboard must call `previewRedeem` rather than assume
  par. Neither surface was changed by the audit work.
- **ADR-0022 amendment:** its exit-pricing sub-decision is narrowed by X–Z above; its cooldown
  sub-decision is unaffected.
- The `realizeLoss` guard comment and any dependent NatSpec must be corrected to state the position
  in X, so the tree asserts one thing.
