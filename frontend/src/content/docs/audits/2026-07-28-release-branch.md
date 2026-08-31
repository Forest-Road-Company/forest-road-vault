# Release-branch differential review

## What this round was

Every prior round reviewed a tree. This one reviewed a *change*: the complete set of
differences between the pre-mainnet release branch and the mainline it will merge into, 252 files across the contracts, the deployment and validation scripts, and the frontend.
A differential review asks a narrower and sharper question than a full audit: not "is this
system sound", but "what did this change break, weaken, or leave inconsistent".

Eleven candidate issues were raised by the first pass. Each was then handed to an
independent reviewer whose brief was to *refute* it, to open the cited file, re-derive the
claimed consequence, and default to rejecting the finding where the evidence was not
airtight. That second stage changed the result substantially, and it is worth being
explicit about how:

- **One was refuted outright.** A claim that a permissionless reserve-reconciliation
  function could be used to manufacture a backing deficit does not hold. The function is
  monotone-downward by construction and cannot reduce the ledger below actual custody, its
  stated trigger was factually wrong, and the claimed inescapable deadlock has at least
  three exits. It is recorded here as refuted rather than quietly dropped.
- **One was a duplicate.** A finding that pausing the reserve manager blocks the otherwise
  never-pausable loss-recognition path is a restatement of FRV-DSA-005, which the owner
  formally accepted on 27 July and which is already published on the previous round's page
  with a passing regression test. Its distinguishing claim, that earlier cascade layers
  execute and leave partial state, is false: the revert is atomic. The correct
  characterization is a liveness stall, not state corruption.
- **Most of the rest had their consequences corrected downward.** Several described a
  latent hazard in the language of a live one. Where that happened: the finding is
  published at the severity the evidence supports, with the unreachability stated first
  rather than buried.

What survived at review time was one live Medium, one Low on the attestation trust
boundary, two further Lows, and five Informational items. The remediation pass completed
later on 28 July closed the Medium, the attestation Low, and four frontend/documentation
items. The live concentration-limit disclosure remains open, as do the explicitly
identified upgrade-documentation and read-efficiency follow-ups.

## Remediation update, 28 July 2026

The following findings are now remediated in source:

- **FRV-BR-01:** the funding gate now rejects a pending facility once
  `nextPaymentDue <= block.timestamp`. The boundary is covered directly and the stateful
  credit handler was extended so invariant fuzzing exercises the same production
  precondition.
- **FRV-BR-02:** `AttestationOracle.attest` now rejects a zero threshold at the point of
  use, so an omitted initializer entry fails closed even with an empty signature array.
- **FRV-BR-04:** the yield-history reader performs one deployment-to-tip bootstrap and
  then advances an in-memory cursor over unseen block ranges instead of replaying the full
  history every minute.
- **FRV-BR-06:** the positional `ClassParams` fallback now reads `maxMarkAge` from index
  eight, with named- and positional-tuple regression coverage.
- **FRV-BR-07:** the queue pause documentation now states that settled claims remain
  available, and the orphaned one-argument curator-loss documentation was removed.
- **FRV-BR-09:** unresolved wallet, wallet-client, and RPC states now produce explicit,
  actionable error status instead of silently leaving the write flow idle.
- **FRV-BR-08 (partial):** `requestRedeem` now calculates the realized share value once.
  The concentration bookkeeping and overlapping frontend facility reads remain quality
  follow-ups and are not represented as fixed.

The earlier **FRV-DSA-005** liveness finding, independently re-raised during this round, is
also now remediated: the role-gated principal write-down needed by the loss cascade remains
available while `ReserveManager` is paused, while user and custody operations stay paused.

Verification after the remediation included the complete default Foundry suite, the heavy
10,000-case fuzz profile and 512-by-256 stateful invariant profile, instrumented coverage,
frontend logic/synchronization tests, lint, and a production Next.js build. Every newly
added or altered executable contract branch in this pass reached 100% statement, line,
branch, and function coverage; the documentation-only PointsModule edit retains its
pre-existing coverage gaps. Slither returned the same 82-result detector baseline and no
new detector class.

## The one that matters

**FRV-BR-01** was the only finding in this round that was reachable on a deployed system at
review time, and it was the priority remediation.

The protocol added a permissionless past-due mechanism in this release: anyone may flag a
receivable facility whose payment date has passed by more than its grace window, which
applies a conservative impairment mark and lowers the redemption NAV until it is cured.
That is a deliberate depositor protection, it stops a receivable being carried at par
between a missed payment and a servicer acknowledging it.

The reviewed gap was that the funding gate had not been extended to the new anchor.
Origination refuses a payment date already in the past. Funding re-validates maturity, class activity,
attestations, the terms binding and mark freshness, but not the payment date. So a
facility that sits pending long enough between origination and funding activates with a
payment date already behind it, and can be flagged immediately by any address, on a
facility where no payment was ever contractually possible.

Two things bound it. The enabling delay is operator-created: origination is a privileged
action, so an outside party can amplify a slow deal but cannot manufacture one. And the
mark is an accounting flag only: it does not set the defaulted state, does not freeze
curator capital, does not enable loss realization, and does not enter the loss cascade. No
funds leave the protocol. The harm is that seniors exiting through the queue while the mark
stands settle below the NAV the book actually supports.

The implemented fix refuses to fund a facility whose payment date has already passed, so
the funding checks are a true superset of the origination checks. The
alternative of silently rolling the payment date forward on activation should be rejected: it would let an operator rewrite an attested economic term outside the amendment quorum.

## On the attestation boundary

**FRV-BR-02** is graded Low because it is not reachable, and it is worth explaining why it
is published at all.

The reviewed attestation oracle seeded each attestation kind's signature threshold in a
loop with a hardcoded bound. Every kind currently defined is seeded, governance cannot set a threshold
to zero, and an out-of-range kind is rejected before it reaches any logic, so there is no
kind today that can be attested without signatures. But the check that enforces the quorum
compares a signature count against the threshold, and a threshold of zero satisfies it
vacuously with an empty signature list and no attester check. The failure direction is
open, not closed.

That matters because this release *did* restructure the attestation enum, deleting two
kinds and appending three. That change was safe only because it shipped as a fresh
deployment rather than an in-place upgrade. Had it been upgraded in place: one kind would
have carried a zero threshold and two others would have silently inherited a lower quorum
from the kinds they displaced. Nothing in the code enforces the coupling; the deployment
choice happened to be the right one. The facility mint gate already solves the identical
problem structurally, with a named count constant, precisely so a future kind cannot slip
past it. The remediation adds the load-bearing protection at the point of use:
`attest` now rejects a zero threshold outright before inspecting the signature bundle.

## Disclosure accuracy

**FRV-BR-03** is not a contract defect. The concentration-limit ramp, every dimension open
to 100% during testnet ramp-up, is deliberate, owner-accepted with disclosure, and refused
by the production validator, so it cannot reach a mainnet deployment. The suggestion that
it renders the concentration invariant vacuous was checked and refuted: the invariant suite
sets its own binding limits and fails the run if no dimension ever rejects an origination.

What is new is narrower and worth fixing: the public site tells readers a position is capped
by concentration limits enforced on-chain, no page renders the configured limit, and on the
network the site points at: that limit does not bind. The remedy is to surface the live
configured value alongside the claim.

## Method

Ten independent review lenses were run over the branch diff, access control and
upgradeability, accounting and value conservation, the loss cascade, the attestation and
oracle boundary, lifecycle and state machine, deployment and validation tooling, storage
and upgrade safety, frontend correctness, frontend security posture, and documentation
versus code, followed by a sweep for anything the lenses did not cover.

Every candidate was then independently re-verified with an explicit instruction to refute:
open the cited line, quote what is actually there, trace who can reach it in what state
with what role, check whether an earlier guard or a deploy-time validator already blocks it,
check whether a test already covers it, and establish whether the stated *consequence*
follows rather than only the stated premise. A true premise with an overstated consequence
was recorded as partially confirmed and downgraded, not published as written. A final
calibration pass then compared every severity against how comparable issues were graded in
this protocol's earlier rounds, since a reader compares them.

## Limitations

This was a differential review of source, not a full-system audit and not a review of
deployed bytecode, key custody, multisig configuration, attester operations, or legal
enforceability. It reviewed the branch at its head commit; two contracts are recorded
elsewhere as having source ahead of what is currently deployed on the testnet, so a reader
checking a finding against a live contract should confirm which version they are reading.
No code was changed during the review itself; the remediation described above was a
separate subsequent pass. Findings that assert a negative, that no
unauthorized-mint or permissionless theft path was found, are bounded by the lenses run
and are not a proof of absence.

An independent external audit remains a required production gate and is not satisfied by
this or any other internal round.
