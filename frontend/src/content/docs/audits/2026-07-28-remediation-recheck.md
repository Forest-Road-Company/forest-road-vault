# Remediation re-check

## Why a round just for the fixes

Every prior round reviewed the protocol. This one reviewed **the previous round's
remediation**, on a principle worth stating plainly: a fix is itself a change, and a change
can introduce defects. A remediation pass that is never re-audited is a pass whose new code
has had less scrutiny than the code it replaced.

It found exactly what that principle predicts. Of the twelve Medium and Low fixes from
Round 7: one had introduced a new Medium defect, a liveness regression capable of
permanently freezing the only exit from the senior vault. It is fixed, but it existed because
a correct-looking fix to a Low-severity nuisance had a consequence nobody traced.

## How it was run

The twelve remediations were grouped into eight change clusters spanning the contracts, the
frontend, the build gate and the test suite. Each cluster was reviewed **twice, by
independent reviewers with opposite briefs** and no sight of each other's work:

- one asked *does this fix actually close the finding it claims to?*
- the other asked *what did this fix break or newly expose?*

Every candidate then faced two adversarial refuters, one checking the mechanism against the
code, one checking whether the stated consequence really follows, and finally a critic whose
job was to challenge the severities and, more usefully, to say what the re-check had failed
to cover.

The critic's sharpest objection was that the headline finding rested on reading alone. That
was correct, and it changed the outcome: the two most serious findings were subsequently
**reproduced by executable proof-of-concept** before any fix was written. One of the two
turned out to need a specific ordering to be reachable at all, which reading had not
established.

## The regression

The Round 7 fix stopped a dust-sized fill from consuming the redemption queue's epoch
heartbeat, a sensible Low-severity correction. The consequence it did not trace:

The amount distributed accumulates across the chunks of a single settlement, while the
liquidity budget is captured once at the start and can thereafter only shrink. So a chunk
that stopped because it hit its per-call request limit could **commit** a settlement whose
maximum possible total was already below the minimum the new guard demanded. From that point
no later chunk could satisfy the guard, and because the guard's abandon path reverts, it
also undid its own release of the settlement lock.

The result was an absorbing state. A proof-of-concept confirmed each step: once latched,
refilling the treasury and waiting a month still failed, because the budget is never
re-captured while a settlement is open. Only a governance change to the floor recovered it.

No funds were ever at risk, the reverting path moves nothing, and assets already settled
into a position stayed claimable throughout, but the sole senior exit could stall
indefinitely, and it surfaced as an ordinary "no liquidity" error while liquidity was in fact
ample.

**The fix tests reachability rather than the floor itself:** a settlement is refused
*before* it commits if the most it could ever distribute is already under the floor, so the
transaction rolls back and the next call begins fresh against live liquidity. A settlement
that has distributed little but still holds enough budget to clear the floor later is
ordinary, and still proceeds.

That distinction was not obvious. The first attempt applied the floor check on every exit, the intuitive fix, and **the stateful invariant suite rejected it** for denying settlement
to a request that was perfectly payable. Reading the code would not have caught that.

## What the other findings were

Three further residuals, all now fixed: the yield cap introduced in Round 7 left the vault
sitting exactly on the entry guard's boundary with no margin, so an ordinary settlement could
close senior entry, the original defect returning through a different door; a panel footnote
still explained itself using the valuation method the same round had replaced; and resetting
a card could abandon an in-flight transaction, letting an on-chain failure go unreported
while the interface sat idle.

One further candidate was withdrawn rather than fixed: both reviewers agreed it was not a
regression and that its substance was an already-published open finding.

## The three structural gaps

The critic declined to sign the round off on the findings alone, and named three things that
were not defects but were the conditions for future ones. All three are now closed:

**Storage layout was guarded by review alone.** The previous round grew an upgradeable
contract's stored state from five fields to seven with no automated check anywhere. Because
this protocol uses namespaced storage, the standard layout inspection reports nothing at all,
so the gap was invisible rather than merely absent. A test now pins every field to its exact
slot and fails on any insertion or reordering, the failure mode that silently reinterprets
live state on an upgrade, and the only change in that batch whose worst case is severe.

**Frontend fixes were pinned by searching their own source text.** An assertion that a file
contains a particular string can be satisfied by a later edit that keeps the string and
restores the defect, reviewers independently sketched such edits. The redemption hold's
arithmetic now lives in a small shared module pinned by tests that check computed values
against the contract's own rule, including the boundary second and the requirement that a
not-yet-loaded value never silently defaults to zero. Component rendering itself is still
untested, which would need a browser test harness this project does not have; that is stated
rather than glossed.

**The pipeline was narrower than the engineering rules require.** It now enforces formatting,
treats lint warnings as failures, checks dependency advisories, runs static analysis that
fails on high-severity findings and always publishes its report, and runs the heavy
stateful-fuzzing profile in its own job, a profile the configuration already claimed was
used and was not.

## What is still not covered

Stated because a pipeline that looks complete is worse than one that admits its edges:

- there is **no static-analysis baseline** to compare against, so a new low or medium finding
  does not fail the build. Failing on the whole detector set would go permanently red against
  the existing triaged findings and simply be ignored;
- **coverage is not measured in the pipeline**; it remains a manual pre-release step;
- the **environment-gated fork suites do not run there**: including the loss-cascade and
  deployment-validation tests, which are among the most valuable in the suite;
- there is still **no frontend render harness**, so component behaviour is reasoned about
  rather than exercised.

## Verification

Every fix in this round was checked to **fail against the unfixed code** before being
accepted, a test that passes either way pins nothing. Two were proven by proof-of-concept
first.

The full contract suite, the stateful invariants at the heavy profile, the contract-to-
interface synchronization checks, formatting, linting, type-checking and a production build
all pass. Environment-gated fork tests were not run here and are not claimed.

This remains an internal review. It does not close any independent audit, legal, economic or
production-readiness gate.
