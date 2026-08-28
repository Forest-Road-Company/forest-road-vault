This is the first review conducted against a **live Ethereum mainnet deployment** rather than
against source or a testnet. It supersedes the same-day deployment audit, which examined bytecode,
roles, parameters and disclosure but declared two gaps explicitly: no fork reproduction, so no
finding could reach *confirmed*, and no independent adversarial cross-examination. This engagement
closes both.

It remains an **AI-assisted audit, not a maximum-assurance audit**, and must not be represented as
one.

## What changed relative to the deployment audit

A harness binds to the live mainnet addresses and drives the deployed contracts from genesis through
mint → deposit → originate → fund → default → settlement. **Every code finding below is a passing
test against production bytecode**, not a source argument.

Four independent reviewers read all 23 contracts in full under four distinct adversarial lenses, economic sequencing, cross-contract invariants, accounting and state machines, and authority and
voting. Every surviving candidate was then re-examined by a skeptic instructed to refute it. One
finding was refuted outright: one was de-escalated from Medium to Low, and one previously accepted
High-severity register entry was corrected downward.

## What is still absent, and what that costs

No coverage-guided fuzzing. No symbolic execution or formal proof. No model qualification benchmark.
No live-fire governance rehearsal beyond the fork. A clean result is evidence that these methods at
this depth found nothing; it is not proof of security.

## The honest headline

The deployed code is unusually hardened, sixteen prior review rounds, a large in-house fork and
attack corpus, and a Slither surface that reduces entirely to the project's own triaged baseline.

**The engineering findings are not fund-theft-by-anyone.** The three Mediums are two
privileged-operator liveness traps and one launch-sequencing gap. The sharpest exposure remains who
holds the keys and what has been disclosed, unchanged from the deployment audit. No user funds are
at risk at the current seed state.

## The finding that most affects an integrator

**DV-03** is the one to read first if you are considering routing capital here. The protocol
advertises a three-layer loss cascade, curator first-loss, then the sGROVE backstop, then senior
principal. Origination and funding consult **neither** junior layer, and both are **empty on chain
today**. A declared default therefore drives the full principal onto the senior NAV with nothing in
front of it.

The recommendation is to make first-loss and backstop funding a hard capped-launch acceptance gate,
before the first origination and before any user deposit path opens.

## The finding that most affects a rate oracle

**DV-01** produces an *upward* discontinuity in the exit price. A good-faith operator action, taken
on the protocol's own diagnostic, can drop a real senior impairment mark out of exit pricing
entirely and irreversibly ratchet the high-water mark. In the reproduction a genuine $2.3M mark
vanishes and the exit price jumps to par.

Any consumer that records a high-water exchange rate should understand this before integrating.

## Carried forward from the deployment audit, still valid

Four Safes sharing one 2-of-4 owner set. Queued governance being unstoppable and undisclosed, now
fork-proven. A degenerate 2-of-2 attester quorum with unfunded keys. Three unmanifested contracts in
the trusted base. A red entrypoint-guard test on the working tree.
