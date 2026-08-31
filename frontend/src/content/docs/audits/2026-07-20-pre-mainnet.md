# Pre-mainnet campaign

## What this round was

This was the largest and most adversarial campaign run against the protocol, and the one
that found the most serious defects. It ran in four connected stages over six days:

1. **A manual pre-mainnet review** of contracts, frontend, deployment configuration,
   invariants and fork validation, producing the readiness register.
2. **An adversarial red-team fleet**: per-contract, specialist and protocol-wide reviewers
   attacking independently on isolated local forks. Every submitted finding was put to a
   panel of independent refuters before it was accepted; of fifty-six submissions, thirty-six
   were refuted and roughly nine distinct findings survived deduplication. The severities
   published here are the panel-adjudicated values, not the values as filed.
3. **A twenty-four-lens full-codebase register** in which each lens attacked independently
   and was forbidden to run the test suite, followed by a reproduction phase that turned
   forty-three findings into executable proofs. Every entry was labelled as reproduced or
   reasoning-only.
4. **Two go/no-go re-audits** of the resulting fix diff, each run with the explicit posture
   that another incomplete fix should be assumed until disproven, and each requiring the
   original defect to be re-run and shown dead rather than argued dead.

## What it found

The headline result was a **Critical**: under a fully-marked unrealized impairment, queue
settlement could burn an entire queued position and pay out exactly zero. It was reproduced
seven times.

Its history is the most instructive thing in this whole audit record. The same mechanism had
already been filed a week earlier, in Round 2, as an *Informational* item, a queued request
could become sub-wei dust and burn for nothing, and closed on the reasoning that an amount
below one wei was immaterial. Its recommendation was never implemented. When the conservative
redemption NAV was introduced days later, that change destroyed the premise: the clamp could
price a whole position at zero, not at a sub-wei residual, and the burn proceeded anyway.

An Informational finding was accepted on an argument about magnitude rather than a bound in
the code, and a later change falsified the argument while the code stayed as it was. That is
the failure mode this campaign exists to catch, and it is why findings on this site record
the *premise* of an acceptance rather than only its outcome.

Five further High findings concerned backing inflation through treasury-directed funding, a
permanently stranded impairment pool after partial recovery, a dilution mint opened by
re-pricing the yield vesting period, a mint gate that proved attestations existed without
proving they attested to the facility's terms, and the absence of any on-chain force to mark
a receivable down between a missed payment and a servicer default. All five are recorded
closed, each by re-running the original reproduction rather than by inspection.

The campaign also recorded that a first round of parallel fixes was rejected in its entirety, every one reviewed as incomplete, nothing applied, with upgrade-safety blindness and
knowingly-red test suites named as the two systemic causes.

## What it did not close

Two findings were deferred rather than fixed, and both remain live commitments:

- **Absorbed junior capital has no on-chain claim on later recoveries.** Accepted in
  principle, handled off-chain while Forest Road is itself the curator, and identified as a
  required build before a junior tranche or any third-party curator exists. The architecture
  document was corrected because it had described an on-chain leg the code does not
  implement.
- **The realized-loss magnitude is chosen by the servicer rather than bound to an
  attestation.** Confirmed real, pre-existing, and folded into the documented attestation and
  servicer trust model. Constraining it is a counsel decision rather than a code decision.

One further item is open by design and is the single most important caveat on any testnet
result reported anywhere on this site: **the testnet deployment is deliberately
testnet-shaped.** It retains bootstrap administrative privileges, uses a mock stablecoin
with no value, and runs with concentration limits open for ramp testing. The production
validator refuses every one of those postures. A green result on that stack is evidence
about the code, not evidence about a production configuration.

## Method note on the numbers

Severities here are adjudicated, and several moved during adjudication, two findings filed
High were reduced to Medium, one filed High was reduced to Low, and one was raised. Findings
that were reproduced with an executable proof are distinguished throughout the internal
reports from those established by reasoning alone; roughly a third of the full-codebase
register was reasoning-only and is marked as such there.

Fourteen further reported claims were refuted outright and recorded as refuted, so that a
later round would not re-derive them and count them again.

## Why these reports are not published in full

The underlying reports for this campaign are held internally rather than published, and the
reason is specific rather than reflexive. Several of them contain step-by-step, measured
exploitation recipes for defects whose fix status is stated in a different document; the
operational posture of the live testnet stack in enough detail to target it; and local
filesystem and endpoint detail from the reviewers' own environments. Publishing an
exploitation recipe alongside an incomplete statement of what is fixed would be worse than
publishing nothing.

What is published is the finding, its adjudicated severity, and its current disposition, which is the part a reader needs in order to judge the protocol.

## Limitations

The full-codebase register explicitly recorded what it did not cover: nothing was executed
by the lenses themselves, coverage was not measured in that round: the handover script was
unread, and economic calibration, most of the frontend, individual test files, manifest
drift, observability, servicer-outage liveness, and gas, static-analysis and storage-layout
diffs were all out of scope. Two of its findings concerned false greens in the test and
invariant layers, both reproduced by mutation, a reminder that a passing suite is evidence
only to the extent its assertions bind.

An independent external audit remains a required production gate.
