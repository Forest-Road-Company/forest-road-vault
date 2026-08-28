# Internal adversarial audit of the whole protocol

## What this round was

Every previous round on this register reviewed a change. This one reviewed the **protocol**, under a
formal engagement protocol written before any code was read, with a single instruction: break it.

The protocol had five phases and each had to finish before the next began. Reconcile what is
actually deployed against the source. Derive a threat model from the code rather than from the
documentation. Sweep a mandatory vulnerability-class table where every class owes either a finding
or a written reason it does not apply. Attack it on two pinned forks. Then report.

Three rules mattered more than the rest. **Source was frozen through discovery**: nothing was
fixed while anything was still being looked at, because repairing as you go contaminates everything
you look at afterwards and destroys the record of what the code was when the bug was found. **Every
finding above Informational owes a test that actually runs**, and a finding without one is labelled
a hypothesis rather than dressed up as a result. And **a dismissal owes a test too**: if you believe
a function is safe from reentrancy, you write the test that tries it, because a clean report is the
easiest place in the world to hide an untested assumption.

## The core mechanics held

This is the most important result and it is a measured one, not a courtesy.

The three-layer loss cascade was attacked directly and did not break. Ordering, conservation and
subordination headroom all held across 163,840 stateful calls with independently tracked ghost
capacities, and, for the first time, with the per-event backstop cap exercised at a value that
actually **binds**. A previous round had found that this cap had no callers anywhere in the test
suite, so the layer-2 rule had never been tested at a value where it constrains anything. It has
now been.

The redemption queue's solvency, its strict first-in-first-out ordering, its no-double-claim
property and its liveness all held across another 163,840 calls, including under chunked
settlements, forty-five-day keeper absences, and liquidity drained to zero and refilled.

The attestation layer held under a deliberate assault: zero-address recovery, signature
malleability, compact and legacy signature encodings, bundle-ordering attacks, replay across kinds
and facilities and payloads and chains, and the valuation anti-rollback watermark. This layer
matters more here than in most protocols, because the system integrates **no on-chain price oracle
at all**: there is no AMM, no price feed, no TWAP. The entire price-manipulation family of attacks
has no surface, and the equivalent risk is relocated wholly into attestation.

Reentrancy was closed across all six sub-classes, and closed by building a hostile module and
installing it, not by reasoning about the call graph. Every `unchecked` block, every downcast and
every assembly site was proven safe for all reachable inputs. Rounding direction was enumerated
across every division in four contracts.

And flash-loan atomicity was tested by **actually borrowing**, at a pinned block, from a real
lending pool with real depth, never by simulating a balance. Seven of the nine state-dependent
surfaces resisted, including governance voting power and the backing invariant's computed side.

## Where it broke: two clusters, not a scatter

The failures are not distributed. They sit in two places, and saying so is more useful than a
severity ranking.

**Economic controls derived from spot-read balances.** The queue's per-epoch liquidity budget is
read from a live balance at the instant settlement opens, and a live balance can be moved inside a
single transaction with borrowed capital. That budget is the protocol's only throttle on senior
exits. Separately, the guard protecting the settlement heartbeat is an *absolute constant* rather
than a proportion of the epoch's actual capacity, so it does not need to be overwhelmed, only
stepped over, and stepping over it costs about a dollar. Both of these attack the only exit the
senior claim has.

**The role-admin topology.** Searching the production source for a role-admin override returns
nothing, which means the default administrator role administers *every* role. Under the deployment
posture that deliberately retains operator control on testnet, that one fact produces three separate
symptoms that had been filed as three findings: the timelock can be bypassed in a single grant, the
mint authority can be reconstituted, and two of the safety specification's own invariants turn out
to describe a configuration snapshot rather than a property. They should be remediated as one thing.

## An audit that corrected itself four times

The most useful thing this round produced was not a finding. It was four corrections to conclusions
this same audit had already published in its earlier phases.

The sharpest: an earlier phase found that a reserve write-down freezes minting and redemption, rated
it High, and recorded that repayments would gradually heal the shortfall. Working it through on a
funded facility showed that reasoning is **arithmetically wrong**: the repayment path is exactly
neutral on the gap, not narrowing, so while the system is under water the credit book cannot be
serviced at all. That makes the mechanism worse than reported.

The same work then found the *opposite* error in the same finding. It had claimed no on-chain
recovery exists short of a contract upgrade. Two governance cures do exist, each demonstrated
restoring minting, redemption and servicing. The finding came **down** from High to Medium and was
reframed from an unrecoverable brick to an incident-response gap, a real gap, because the cure
requires a role grant the deployment script never makes and nobody has rehearsed.

Its recommended fix was also **struck**, because the decision record shows that exact change was
already considered and rejected for a good reason: it would invert the loss cascade, letting exits
race while the protocol is impaired and subordinating the holders who stay.

An audit that cannot correct itself is worth less than one that can, so all four corrections are in
the report rather than quietly patched.

## The coverage result, stated against itself

The production source measures **100% of lines, statements, branches and functions** under the
repository's own test suite. That was measured, and then independently re-measured.

Every defect in this report lives in code that is fully covered.

That is the point, and it is why the number is published next to the findings rather than instead of
them. Coverage is a floor. It tells you a line executed; it tells you nothing about whether the
assertion around it would have noticed if the line were wrong.

## A note on what is disclosed here

Every finding is listed with its severity and its disposition, including the ones that remain open.
For findings that are remediated, accepted, or informational: the mechanism is described in full.

For the small number of **open findings that are exploitable against a live deployment**, this page
states what is wrong, what the impact is, and what the fix is, but not the reproduction recipe.
The complete mechanical detail, the parameters and the executable proofs are held in the internal
audit record and are available to reviewers on request. That is ordinary responsible-disclosure
practice, and it is flagged here rather than done silently, because this register's stated policy is
to publish in full and this is a deliberate exception to it with a stated expiry: remediation.

## Post-audit remediation

On 3 August 2026, the four Low assurance-chain findings D13-01 through D13-04 were remediated.
Static analysis is now bound to a runner-owned configuration and complete source identity; storage
layout discovery covers the full reachable type graph and has hostile key-type regressions; the
broadcasting QA path is bound to the connected chain's canonical manifest; and frontend fee-ABI
selection rejects known incompatible pairings and requires an explicit version for unknown test
deployments. These controls are executable in CI rather than relying on the audit's temporary
evidence scripts.

Those remediations do not change the disposition of any open protocol or economic finding and do
not satisfy the independent external-audit gate.

## Standing

This was an internal adversarial audit. It is **not** the independent external security audit that
the production-assurance gates require. That gate remains outstanding: this work does not satisfy
it, and nothing here authorizes a mainnet promotion.

The deployment it examined is a testnet deployment carrying no third-party capital, with a mock
stablecoin, retained operator privileges and concentration limits left fully open, so nothing green
in this round is evidence about a production configuration either.
