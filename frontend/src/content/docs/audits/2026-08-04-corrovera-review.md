# External review by Corrovera Security

## What this is

Corrovera Security reviewed the whole protocol, 37 Solidity files, 10,502 lines of
`contracts/src`: at commit `d2ef15a5`, and the reviewed source is byte-identical to the current
`contracts/src` tree at `b5245398`. This is the first review of this protocol conducted by a party
other than Forest Road.

It is an **AI-assisted security review**, which is the tier Corrovera delivered and the tier we
commissioned. We are publishing what it did and did not cover, in their words rather than ours,
because the distinction matters to anyone deciding what this page is worth.

**What ran:** Corrovera's deterministic Solidity analysis; Slither over the full compiled project;
our own Foundry suite; whole-protocol review by five independent model lineages under two
specialist lenses, with our 36-entry findings register supplied as an exclusion list so that
nothing already known could be re-reported as new; adversarial cross-examination of the surviving
candidate by four further lineages instructed to refute it; and manual source validation of every
load-bearing claim by the reviewing engineer.

**What did not run**, and what Corrovera says it costs:

| Absent | Consequence |
|---|---|
| Model qualification benchmark | No lineage has measured competence at this task |
| Generated fork reproduction | **No finding reaches `confirmed`** |
| Coverage-guided fuzzing | No state-space exploration beyond our own suite |
| Symbolic execution / formal verification | No property proven |
| Deterministic consensus pipeline | Adjudication by one engineer |

Their summary of what a clean section means is worth quoting directly: *"A clean result in any
section is evidence that these methods at this depth found nothing there. It is not evidence of
security."*

## What they found

Two new Medium findings and one challenge to an existing risk acceptance. All three fall outside
the 36 entries we supplied, which is the result that matters: the exclusion list was designed to
make a rediscovery impossible to pass off as a discovery.

One lineage produced three candidates; the other four produced none. The strongest was put to the
remaining four for refutation. Three returned verdicts and **all three said it survives**, each
rating it High. The reviewing engineer rated it down to Medium on reachability grounds after we
raised the redemption cooldown, a calibration the refuting reviewers were not asked to challenge,
and the report says so.

### F-01: a curator can inflate the exit price it redeems at

Our impairment calculation nets a class's at-risk principal against a **live, un-snapshotted** read
of the curator's first-loss pool, and that figure flows into the price at which queued redemptions
settle. Separately, and deliberately: a past-due mark does not freeze curator withdrawals, that
omission is what removed a griefing surface in an earlier redesign.

Each decision is sound alone. Together they let an approved curator who also holds senior tokens
raise the pool balance, settle their own queued exit against the improved price, and withdraw the
capital again, with the impairment snapping back afterwards. Both the trigger and the settlement
are permissionless, so the actor controls the timing of both.

**Scope is the important part.** This is near-unreachable while Forest Road is the sole curator:
our first-loss capital is consumed before any senior loss, so the round trip would extract from
seniors while our own junior capital stays exposed, and the franchise is worth more than any single
exit. It becomes live from the moment a third-party curator is approved: they have no franchise
at stake, and nothing in code stops a curator holding senior tokens.

It is best read as a **precondition on a planned capability** rather than present exposure. The
acceptance reopens before any third-party curator is approved; remediation or a fresh, explicit
owner decision is required at that boundary.

### F-02, ordinary forbearance suppresses the senior mark

The permissionless past-due mark is anchored on a servicer-controlled payment date. While that date
is rolled forward, the delinquency never reaches the senior impairment figure, and seniors exiting
in that window are priced against a facility that is not performing.

Corrovera withdrew their own first framing of this as misconduct, and the correction makes it
worse rather than better: rolling a payment date for a borrower with a temporary liquidity problem
is ordinary credit practice, and the mechanism needs no bad intent. **Likelihood rises, because
forbearance is routine, and it is less likely to be noticed precisely because nobody is behaving
badly.**

Two things bound it. It only bites where a class's loss exceeds its first-loss capacity, inside
that capacity the curator absorbs it and no senior is mispriced, which is the cascade working as
designed. And both deferral routes require an attestation, so attestation discipline is the
control. That control is the one our own register already flags as concentrated, and the report is
explicit that the two findings compound.

They also record, as an observation rather than an allegation, that management and performance fees
are not neutral to the forbearance decision.

### F-03, a challenge to an existing acceptance

Nine of ten independent opinions judged our `D7-01` acceptance sound. One dissented with a specific,
testable mechanism: that acceptance was written about a private, atomic trigger, and a later
redesign introduced a **permissionless, public** trigger that raises the same figure. That does not
overturn the acceptance; it records that a redesign may have widened the surface the acceptance was
scoped against. We are treating it as a revisit trigger.

## What they confirmed and dismissed

Our open `C-01` was confirmed still open: the deliberately-red invariant marker fails as designed
over 256 runs and 32,768 calls, and inverts when the finding is fixed.

Of 134 static-analysis results touching in-scope source, all 38 Mediums were individually
adjudicated and dismissed with reasons: the flagged token transfers are role-gated and
balance-delta verified, all thirteen reentrancy sites carry guards: the divide-before-multiply is
deliberate decimal dust retention, and the unused-return flags read a field the code does not need.
One candidate from an outside lineage was **self-refuted by the reporting model** during its own
verification.

Our suite ran 947 passed, 2 failed, 204 skipped, one failure the intentional `C-01` marker, the
other environmental.

## Forest Road's decision, 4 August 2026

Forest Road analysed both Medium findings and **accepted them as low practical risk**. Forest Road
also confirmed that one external audit is the applicable launch requirement, so this received
Corrovera engagement satisfies that gate. Publishing the reasoning matters more than publishing the
conclusion: the policy decision does not expand the engagement's scope or method, and it does not
turn accepted findings into fixed ones.

**Accepted is not fixed.** Neither mechanism was refuted and neither was remediated in code.
Corrovera's Medium ratings stand as they wrote them: we have not restated them as Low on our own
register, because a client's risk tolerance is not a re-rating of an auditor's finding.

Each acceptance rests on a stated condition, and each carries revisit triggers recorded against the
finding. F-01's rests on actor scope: the only approved curator is the party whose own junior
capital the round trip would leave exposed, so **it must be revisited before any third-party curator
is approved**: the precise event that makes it live. F-02's rests on the loss sitting inside
first-loss capacity and on attestation discipline, and the interaction with our existing
concentrated-attestation entry is the part to watch, since the acceptance of each assumes the other
holds.

**What a reader should weigh against that.** No finding in this review reached `confirmed`, because
fork reproduction was not part of the engagement. No property was formally proven. No fuzzing ran
beyond our own suite. Adjudication was by one engineer. Those are the report's own disclosures, not
our characterisation of it, and they are reproduced in full above so that anyone can judge the
acceptances and evidence tier for themselves.

What the review did do is more useful than a clean report would have been: it put five independent
reviewers on the whole protocol with our known findings excluded, and they came back with two real
structural observations we had not made ourselves, one of which gates a capability we were
planning to enable, and now gates it explicitly.

The exact Forest Road rationale, conditions and revisit triggers are archived separately in
`audit-reports/CORROVERA_OWNER_DISPOSITIONS_2026-08-04.md`; the vendor report remains the source
review record.
