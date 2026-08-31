# Protocol fee stack, remediation re-check

## Why this round exists

The preceding round found four defects in the protocol fee stack and six gaps in the tests
covering it. All ten were remediated in a single pass that touched seven production
contracts, three initializer signatures, a new role, and the deployment and validation
scripts.

A remediation of that size is a change, and a change can introduce defects. This round
reviewed the fixes rather than the protocol, with two questions per lens: does this fix
actually close the finding it claims to, and what did it newly expose?

The answer to the first question is yes for three of the four. The answer to the second is
that the fourth fix reintroduced the same defect class the round opened with, on a different
axis, and that the invariant which should have caught it cannot, by construction.

## How it was run

Ten lenses over the remediation diff, weighted toward the new machinery rather than the
original findings: the persistent bracket lock and whether it can strand; the asset-hurdle
arithmetic and whether it actually fixes what it claims; the consequences of a high-water
mark that is no longer monotone; completeness of bracket coverage across every writer of
every input to the conservative NAV; the new role and its grants; deadlocks across the now
four locking mechanisms; storage layout and deployment wiring; ERC-4626 and queue conformance;
and an independent check of the stated verification evidence.

Two adversarial refuters per candidate, as before. Twenty-five candidates, sixteen survivors,
consolidated to four code defects.

## What the fixes got right

Three of the four are properly closed, and the mechanisms are worth stating because they are
the parts that should not be disturbed by whatever fixes the remaining findings.

The high-water mark is now maintained as an **asset** hurdle across share flows. A helper
converts the stored per-share mark into exactly the hurdle the fee calculation consumes, and
deposit and withdrawal each capture that hurdle before the flow and carry it by precisely the
principal that moved. Both directions are correct, because real assets genuinely enter and
leave with the shares minted and burned, so the cushion between the hurdle and the marked NAV
is preserved. Both original scenarios were replayed and now charge nothing.

The fee-recipient rotation now writes its new state before crystallizing, so a recipient
whose mint has been blocked can be rotated away from, and the initializer enforces the
exemption invariant that was previously only a deployment convention. The accepted residual, a fee pending at the moment of rotation mints to the incoming recipient, is deliberate, is
what buys un-brickability, and is documented as such.

The yield-delivery window is now closed by a genuine vault-side lock, acquired under the same
condition that later releases it, so the two are structurally paired with no branch that can
reach one without the other. The false documentation is gone.

The checkpoint half of the junior-capacity fix is also correct and carefully wired. All five
bracket pairs are straight-line and atomic; the new role is granted to exactly three module
contracts and the deployment validation asserts that both positively and negatively, which is
better practice than most of the repository.

## Where it went wrong

The junior-capacity fix did not stop at checkpointing. It also re-anchors the asset hurdle by
the marked-NAV movement it observes across its own window, **in both directions**: and that
made the high-water mark, which every other part of the design treats as monotone, something
that can now fall.

The inference is the defect. The bracket derives its adjustment from a free-running re-read of
the conservative NAV rather than from the capital that actually moved, and that is wrong in
three distinct ways.

**It attributes movements it did not cause.** The risk fingerprint that keeps a governance
valuation assessment alive folds the curator pool balance for every class. So a bracketed
capacity write is itself the event that invalidates a live assessment: the window opens with
the assessment alive and closes with it dead, and the entire assessed discount is written off
the hurdle. One wei posted to a completely healthy, unrelated class is enough: that path has
no headroom check, no default freeze and no minimum. When the assessment is republished, as
it must be within its time-to-live: the gap is booked as profit. On a fifty-million vault
carrying a one-million assessment this charges roughly four hundred thousand units of fee
against a vault whose realized assets never moved.

**It makes a transient quantity permanent.** Junior capacity only affects the conservative NAV
while there is declared or past-due exposure to net against. Every path that clears that
exposure is deliberately unbracketed, it checkpoints first and then releases. So the hurdle
is reduced permanently for a mark that later disappears, and nothing restores it. The decisive
evidence is path dependence: performing the identical economic transition in the opposite
order leaves the hurdle untouched and charges nothing. Same capital, same end state, different
fee.

**The mirror direction leaks the other way.** A capacity top-up during a live impairment
credits the hurdle permanently; once the exposure clears, that credit stops affecting the NAV
with no offsetting debit and no recovery lever, because every writer of the high-water mark
either raises it or re-anchors it and there is no governance setter. This one harms the
protocol rather than holders, which is the safe direction, but it is unbounded and it
accumulates across every workout in the deployment's life.

A fourth, separate finding: the bracket added to the backstop setter causes it to read
**through the backstop it exists to replace**, and the pre-change body was purely internal, so the change removed a one-call self-repair path. The bracket does not validate the incoming
address either, because the netting short-circuits before reaching it in a healthy book, so a
mistyped address commits silently with a successful event. This is in deliberate contrast to
the vault's own source setter, which probes.

## The invariant cannot see any of it

This is the part that should shape what happens next.

The one invariant covering fee-net rate integrity is blind twice over.

Its handler re-bases its own floor whenever fee shares were minted, and it does so
immediately after the two bracketed capacity writes these findings abuse. A fee-share mint
produced by a supposedly fee-*neutral* operation therefore silently resets the floor it would
otherwise violate.

And the assertion decides whether a fee was legitimate by comparing against the vault's own
high-water mark: it interrogates the very variable these findings corrupt. It is satisfied by
construction in every scenario above.

There is also a structural gap: the credit-layer fixture wires the vault directly to the
default manager, bypassing the assessed impairment source that the deployment installs and
the validation script asserts as mandatory. Every assessment test in the tree runs against a
zero-NAV vault, which is the only reason the arithmetic in the first finding is never
exercised.

The missing property is simple and does not depend on the high-water mark at all: *a full
cure of any impairment mints zero performance shares, regardless of intervening
junior-capacity writes.*

## Verification evidence

The claimed evidence was checked independently rather than taken at face value.

Two claims reproduced exactly: the contract suite reports 914 passing and 0 failing, and the
vault's runtime bytecode is 23,664 bytes, leaving the stated 912 bytes of headroom under the
size limit.

One claim could not be reproduced here: the fork suites require an archive endpoint that was
not configured in the review environment, so all 183 of them skipped. They report a passing
result while running nothing, which reads green in a scroll-back. That matters for this
change specifically, because the governance fork suite is the only place the new machinery
meets the production wiring.

The size margin is not a cosmetic note. Every remediation the findings above call for lands in
the vault: a separately tracked capacity credit applied at read time, a release path for it, a
valuation-regime snapshot across the bracket window, and a clamp. Those will not fit in 912
bytes. Something will have to come out of that contract first.

## Suggested direction

The minimal safe change is to make the bracket a one-way ratchet, drop the decrease branch
entirely. A junior-capacity withdrawal then deepens the fee-free drawdown exactly like any
other unbracketed movement, which is the conservative answer, and the original finding stays
closed because the posting leg still cannot be booked as profit.

The structurally complete change is to stop mutating the high-water mark for junior-capacity
effects at all: hold the credit in a separate asset-denominated field applied at read time,
released when the exposure it was granted against reaches zero. That also removes the first
finding, because the hurdle would no longer depend on a free-running NAV re-read.

## Status at publication

The four findings in this round are **open**. The round was run read-only and wrote no
proof-of-concept tests, so the direction, permanence and first-order magnitude of each follow
deterministically from the source, but the wei-level figures have not been executed. The
cheapest reproduction is a two-line reordering of an existing regression test: move the second
first-loss posting to before the past-due mark, and its assertion that a cure mints no fee
should fail.

## Subsequent remediation status before the next review

The working tree now contains a second remediation, but this historical audit verdict remains
open until the external reviewer confirms the delta.

The new design removes both directions of bracket-driven HWM mutation. Redemption pricing
continues to net live curator and sGROVE protection. Performance fees use a separate impairment
view that measures gross live declared/past-due exposure before that temporary capital is
netted. A live professional assessment snapshots the junior-capital credit standing at
publication, so supported recovery can affect performance while a later capacity write cannot
be misclassified as yield. The begin/end calls now checkpoint, lock, and assert unchanged share
supply only; they never infer accounting from a free-running NAV re-read.

`DefaultManager.setBackstop` preserves intentional zero as “no backstop,” rejects code-less,
reverting, and malformed nonzero candidates, then installs the validated replacement before
checkpointing so a broken old backstop cannot block repair. The effects-first management-fee
valuation residual is documented as a timelocked incident trade-off; performance-fee NAV is
independent of backstop capacity.

The invariant fixture now uses the production assessed wrapper. Fee-neutral handlers assert
directly that the fee recipient receives no shares during the capacity write, and the new
nonzero-NAV regressions cover assessment invalidation/republication, both capacity orderings,
a complete cure, malformed and semantically inconsistent impairment views, large exits whose
physical payout exceeds the remaining fee hurdle, and broken-backstop replacement.

Current local engineering evidence is **929 passing, 0 failing, and 183 RPC-dependent
skipped** in the optimized and coverage profiles; **181/181** mainnet-fork and **3/3**
deployed-Sepolia checks; **59/59** heavy invariant properties; **2,802/2,804** production
lines, **437/442** branches, and **491/491** source-defined functions; **98** Slither results
across **92** reviewed fingerprints; and zero-counterexample backing and cascade symbolic
checks. The changed `sUSDfr` runtime is **24,029 bytes**, leaving **547 bytes** under EIP-170.
Frontend logic, **393/393** contract-sync checks, **8/8** render tests, lint, TypeScript,
dependency audit, and an explicit-Sepolia production build also pass.

This evidence does not close the audit verdict. Independent review of this second remediation
delta remains pending, and the prior deployment/artifact receipts no longer identify the
current source.

## Later independent re-check

The 30 July dual-NAV re-check independently confirmed all four code findings in this
report closed. It also found a separate exit-leg mismatch between the redemption price
and the performance-NAV-denominated hurdle. That finding and its subsequent
working-tree remediation are recorded in the
[dual-NAV remediation re-check](/docs/audit/2026-07-30-adr-0031-dual-nav-recheck).
