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
