# Full-system audit, round nine

> **Historical snapshot, superseded.** This narrative predates ADR-0031 and the
> later impairment-source liveness remediation. Statements below about missing CI,
> coverage, formal, fork, or render evidence describe that earlier point in time and
> are not the current assurance status.

## What changed about how this round was run

The previous full audit ended with a specific criticism of itself: its weakness was not effort
but **shape**. The defects it missed were the ones that require a single entity to be walked
through many sequential operations across a module boundary, each function correct in
isolation, the fault living only in their composition. Seventeen of eighteen reviewers missed
one such defect entirely.

So this round kept the nine module surfaces, each still reviewed twice by independent agents
with opposing briefs, and added four lenses that follow **one entity through its whole life**
rather than reviewing by module: a single facility from origination through a dozen sequential
repayments to maturity and through the parallel default path; a single senior position from
deposit through several rate epochs and a loss to settlement and claim; junior capital across
repeated losses and recoveries; and a lens for scale and unbounded growth.

Every candidate then faced two adversarial refuters, and a critic was asked, among other
things, to judge whether those new lenses had actually done what they were added for.

## Whether that worked: two of four

Worth reporting honestly, because it decides how the next round should be run.

**The facility and senior-position lenses worked.** Each traced a real sequence, and each
produced findings no module review did: a post-maturity amendment freeze visible only if you
keep a facility alive past its maturity, and two defects in a recent fix that exist only across
successive operations. The facility lens also named its own limit, that no test in the tree
warps past maturity on a live facility, which is what a genuine lifetime review looks like.

**The junior-capital and scale lenses collapsed back into module review.** Their coverage
statements read as file lists and static surveys. The scale lens conceded the point directly:
it ran nothing, so every growth figure it gave was an arithmetic estimate rather than a
measurement. Both were competent second passes over ground already covered, wearing a label
they did not earn.

## The result

No Critical and no High finding. Nothing found here reaches a loss of funds, an unauthorized
mint, a backing break, a cascade inversion or a compliance bypass.

Eighty-four raw candidates consolidated to thirty. Two were then **dropped outright** by the
critic, and the reason matters more than the count:

- one would have recommended **undoing an earlier fix**. It described as an exploit the exact
  behaviour a named regression test asserts as that fix working, and its load-bearing claim, that no test composes those two calls adversarially, was simply false;
- the other named a root cause that is causally inert, so its proposed remedy would have
  changed nothing.

A third had its headline struck: relaxing the backing assertion, which it proposed, was already
considered and **rejected in an ADR** on the grounds that it inverts the loss cascade.

Twenty-seven findings remain: three Medium, twenty Low, four Informational. About half are
documentation drift, an ADR asserting a check that did not exist, an invariants document
describing a pause envelope the code changed, a matrix listing functions that are gone.

## The clearest new defect was in the previous round's own fix

Two rounds ago a guard was added to stop a settlement committing while it could never reach the
redemption floor. It did not stop the floor **moving underneath** a settlement that had already
legitimately committed. Because the liquidity budget is captured once and can only shrink,
raising the floor mid-settlement made the guard permanently unsatisfiable, the same dead end,
reached through a governance setter instead of a chunk boundary.

The reason it survived is the instructive part: **the regression test written for the original
fix sets the floor before settling**, and no stateful-fuzzing handler carries a governance
selector. The test bound the path its author was thinking about and missed the one beside it.

It is fixed: the floor is now captured alongside the budget, so a live settlement is judged
against the parameters it opened under, and it was reproduced against the unfixed code before
the fix was written.

## The finding five reviewers found independently

The previous round responded to a storage-layout risk by pinning one contract's fields to their
exact slots. Five reviewers in this round, each arriving from a different contract, pointed out
the same thing: that covered **one namespace of sixteen**, the upgradeability ADR asserted a
pipeline check that did not exist, and the verification command the contracts' own comments
prescribe reports nothing at all for this storage pattern, because these contracts declare no
ordinary state.

That is a fair criticism of closing an instance and calling it the class. It is now closed
properly: a check compares the field order and types of every namespaced and array-element
struct against a committed baseline and runs in the pipeline. Inserts, reorders, retypes and
deletions fail. Extending a namespaced root at its tail passes, because that is safe. Any
growth of an array-element struct fails, because those are laid out contiguously and growing
one shifts every later element on a live proxy. The ADR now describes the check that exists.

## One finding published as contested

The vault's entry guard closes only when the withheld yield stream is *strictly greater* than a
set multiple of vault assets, and a cap introduced two rounds ago sets the stream to exactly
that multiple. So a healthy vault now sits at the very top of an accepted trade-off band by
construction, rather than passing through it transiently.

Whether that matters is a calibration question for economic review, not a coding error, and the
reviewers split on it. It is published as contested rather than resolved, because presenting a
genuine disagreement as a settled finding would be the more misleading choice.

## What this round establishes, and what it does not

It establishes that nine rounds of increasingly specialised reading now return documentation
drift and remediation-completeness gaps rather than defects. That is a meaningful result about
the contracts, but it is also the signal that **source review has converged**.

It does not establish that the contracts behave correctly, because **nothing was executed
during the review**: every figure in every finding is hand-derived. The only measurements are
the suites run alongside it, which themselves run one stateful campaign against an unbounded
mock and skip the environment-gated fork tests in the pipeline. It does not establish frontend
behaviour, because there is still no render harness. And it does not touch the economic
calibration, the coverage cap level, the first-loss target, the vesting ratio whose acceptance
rationale one finding here shows a later change falsified, which remains a human decision.

The honest read is that the remaining risk has moved out of reading and into execution, the
deferred economic review, and the independent external audit. Another reading round is unlikely
to earn its keep.

This remains an internal review and closes none of the production-assurance gates.
