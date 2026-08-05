# First audit of the marked-to-market executor

## Why this round exists at all

While assembling a package for the external auditors, we found something uncomfortable: a production
contract had entered the protocol *after* our sixteenth review round and had never been reviewed by
any of them.

`MtmAtomicExecutor` is 95 lines. It is deployed in the production path, inherited by the mainnet
deployment script, and wired to the two most sensitive modules in the system — the attestation oracle
and the default manager. It had twelve unit tests and nothing else. No finding, no proof-of-concept,
no invariant family referenced it.

That is a process failure worth stating plainly: **nothing in our review process detects a production
contract added between rounds.** We found this one by accident, while writing a document about where
our own method is blind. We have recorded the general lesson alongside the specific fix.

## What the contract does

Digital-asset positions are marked to market, and a new mark can immediately require a margin call, a
cure, or a liquidation. Publishing a signed valuation *before* its protective action lands opens a
window: everyone can see the position is about to be liquidated, and the protection has not happened
yet.

The executor closes that window by making both halves one transaction. It takes a threshold-signed
mark, records it, and applies the strongest action the resulting on-chain state permits — or reverts
both. Crucially, **the caller does not choose the action.** It attempts liquidation first and may
only fall back to a lesser action when the default manager returns one exact, fully-specified
"threshold not breached" result. Anything else aborts the whole operation.

The contract holds no role, has no owner, cannot be upgraded, and cannot make arbitrary calls. A
keeper key therefore carries no protocol authority: the attester signatures authorise the mark, and
the on-chain rules authorise the action.

## What we found

Six independent reviewers attacked it from different angles — the revert parser, liveness, protocol
integration, MEV and ordering, deployment, and the off-chain keeper. Between them they raised **44
candidate findings**. Each of the most severe was then handed to a separate reviewer whose only job
was to destroy it.

**Two survived. Both are Low.**

That ratio is the honest headline. Most of the 44 described real mechanisms whose *consequences* were
already covered by findings we had published in earlier rounds, or whose impact simply did not hold
up when someone attacked it properly.

### The parser cannot tell you who is speaking

The contract decides whether to liquidate by inspecting the *shape* of the error the default manager
returns. Custom errors in Solidity carry no proof of origin — and the liquidation path continues past
its own threshold check into four further contracts, whose errors pass straight back through.

A contract on that path can therefore imitate the default manager's own "not breached" verdict, and
the executor will believe it: a materially breached position is downgraded to a margin call while the
transaction **reports success**. Our keeper checks the receipt only for internal consistency — the
action the executor declares must match the event the default manager actually emitted — and a
downgraded action satisfies that perfectly well, so it sees green too.

This is exactly the outcome the design was written to make impossible, and the code comments and the
decision record both claim more than the code delivers. **We are correcting those claims regardless
of whether we change the code**, because a reader who trusts them will trust the wrong thing.

It is Low rather than High because reaching it requires a privileged configuration change that the
production deployment does not permit — the mainnet script drops the relevant administrative role
entirely — and because post-deployment validation independently checks the wiring that would enable
it. Anyone able to set it up could block the liquidation outright anyway, which is strictly more
power than the downgrade.

### The keeper shows its hand before it plays

Before submitting, the off-chain keeper simulates the transaction against a read-only node. That
simulation contains the complete signed bundle — and because recording a mark is permissionless, that
bundle is effectively a bearer credential. Whoever operates that node can use it, alone, and split
apart the atomicity the executor exists to provide.

Our own launch runbook says: *never publish an action-triggering valuation, its signatures, or its
executable calldata before that atomic transaction is included.* Nobody had reconciled the
simulation step against that sentence, and no trust requirement for that endpoint is written down
anywhere.

It is Low because the endpoint can be — and should be — one the operator controls, and because the
obvious way to exploit it does not work: exits run through a queue with a three-week cooldown that
prices at settlement, so there is no way to sprint out ahead of the loss.

## What held up

Worth reporting, because a clean result on a new contract is a result.

We enumerated **every one of the 172 custom errors** in the production source to look for one that
could be mistaken for the fallback trigger. Eighteen have exactly the right length. **None collides.**
The assembly is correct, the length check is strict, and malformed, empty and panic-shaped failures
all abort rather than downgrade.

The central design claim — that a caller cannot choose a weaker action — **holds**, including against
the sharpest attack we could think of: submitting a mark early to force a margin call where waiting
would have forced a liquidation. That does not exist.

And the keeper **fails closed** when its private submission path is unavailable. It does not quietly
fall back to a public one. That was the specific thing we most suspected, and we were wrong.

## What we got wrong ourselves

Two of the three hypotheses we seeded into this audit were refuted by it. We believed valuations fed
the protocol's solvency calculation — they do not, which removed the impact from several findings we
had been inclined to accept. And our description of a liveness gap during the cure window overstated
it: marks are taken at most daily, which bounds the exposure to a single missed cycle rather than a
continuous blind period. That correction came from Forest Road, against our own analysis.

Seeding an auditor's hypotheses into an audit is efficient, and it is also how those hypotheses
become the audit's conclusions. We mitigated it by instructing every reviewer to refute the seeds as
readily as confirm them. Six reviewers still converged on the same liveness gap — and every verifier
still refused to raise it, because its consequence was already published under an earlier finding.

## Risk acceptance — 4 August 2026

Forest Road formally accepted `MTM-01` at **Low / PROVEN**. Accepted is used strictly: the mechanism
remains live, no code fix exists, and nothing has refuted the reproduction. The decision retains the
incremental risk because reaching it requires the timelock-level authority needed to replace
`sUSDfr.impairmentSource`; mainnet handover removes the deployer and operations EOA from
`DEFAULT_ADMIN`, deployment validation pins the exact reviewed source, and an authority capable of
installing the forging module could already block liquidation outright.

The acceptance is conditional. It must be revisited if the mainnet role posture changes, the
impairment source or its access control/upgradeability changes, another attacker-influenceable
external call is added after the threshold check, the exact wiring assertion is weakened or fails,
or new evidence establishes non-governance reachability or materially greater impact. The decision
record now describes the provenance limit explicitly rather than claiming that shape validation can
authenticate a deliberate downstream forgery.

Acceptance removes this Low finding as a release blocker. It does not mark the mechanism fixed and
does not waive the independent-review, external-audit or production-operations gates.

## Remediation follow-up — 4 August 2026

`MTM-02` is fixed. The review confirmed that the disclosure was broader than the first report:
standalone attestation simulation, atomic-executor simulation and gas estimation each carried the
same signatures. The keeper now derives the EIP-712 digest and authorises the quorum locally using
only signature-free oracle state reads, performs no valuation-carrying or signature-bearing
`eth_call`/`eth_estimateGas`, and uses a required fixed execution-gas limit. The approved
confidential relay is the first external endpoint permitted to receive the signed raw transaction.
It also avoids pre-inclusion `digestUsed` queries: peer recovery filters already-public executor
events by facility and compares their digests locally, so a low-entropy mark cannot be attacked via
an RPC-visible hash commitment.

A remediation-parity review also aligned local acceptance exactly with the oracle: only canonical
65-byte, low-s, v=27/28 signatures pass. Compact, high-s and raw-recovery-bit encodings are rejected
before relay submission. The release-bound gas fixtures pass 14/14 and measure a 1,057,100 worst
case at 64 signatures; the approved 2,000,000 limit is 1.89x that value and lower configured values
are rejected. Installation against the eventual deployed threshold remains open.

A second remediation-lens fixture measured **73,566–140,588 gas** across five deterministic revert
classes that blind relay submission could otherwise burn after public simulation was removed. The
worker now takes a block-consistent signature-free state snapshot and mirrors the executor's three
action branches locally. Paused, stale, non-live and no-action bundles fail closed before release;
the fork's healthy/no-action case makes zero relay calls and leaves the digest unused.

The compiled lifecycle passed again on the pinned mainnet fork. Both RPC proxies actively reject
digest-commitment and valuation-carrying digest/attest/execute calls, and the receipt records
`rpc-commitment-leak=0`, `rpc-valuation-leak=0` plus `rpc-bearer-leak=0` while all canonical
actions, race, replacement, reorg and fail-closed cases still pass. Both selected live Flashbots
configurations later passed bounded funded deterministic-revert suppression and selected
Alchemy/Ankr no-public-observer tests without inclusion, nonce movement or spend. The public status
API nevertheless exposed limited FAILED-transaction metadata contrary to current provider docs;
internal raw-payload logging/retention and downstream access cannot be proven externally. Forest
Road formally accepted that selected hosted-relay residual as `MTM-RELAY-01` on 5 August 2026,
subject to the exact non-fast, Flashbots-only-builder, hash-only configuration, separate relay-auth
keys, preservation of zero ordinary-RPC bearer leakage and four documented revisit triggers. The
acceptance does not claim provider internals or universal/reorg no-rebroadcast are proven. This is
a provider/operator disposition, not an open code defect or an acceptance of `MTM-02`.

One thing the fix cost, recorded because the register should show both sides. Removing the pre-flight
simulation also removed the `expectedAction` cross-check: the keeper used to compare the action in
the receipt against the action its simulation had predicted. Receipt verification is still thorough —
the action the executor declares must match the event the default manager actually emitted, and the
remedy-log count must agree — but it now checks the receipt against itself, and its return value is
discarded at both call sites. The new pre-submission precheck predicts the branch locally, yet that
prediction is never compared with what executed. This does not weaken `MTM-01` detection, which the
old check never caught either: under that finding the simulation was downgraded identically, so the
two agreed. What is no longer detected is divergence between the predicted and the executed action.
Comparing the precheck's prediction against the verifier's return value would close it cheaply.

A follow-up review of the remediation's own test evidence found the leak detector had no positive
control: the three nested selector sets are built from hand-written signature strings, so a drift
from the contract ABI would silently disarm the guard while every assertion still passed. The guard
is now self-proving — each selector is re-derived by parsing the contract source rather than
compared against a second copy of the same hand-written string, and each counter is
proven capable of firing.

## Status

`MTM-01` is accepted, risk retained, at Low/PROVEN; it is not fixed or refuted. `MTM-02` is fixed in
repository and fork-verified. The distinct hosted-relay operational residual is accepted as
`MTM-RELAY-01`; it does not change `MTM-02`'s fixed disposition. Reproduction detail for the live
accepted contract finding remains withheld.

This remains an internal review. Forest Road's separate one-external-audit requirement is satisfied
by the Corrovera whole-contract review; this page does not expand that engagement's scope or method.
