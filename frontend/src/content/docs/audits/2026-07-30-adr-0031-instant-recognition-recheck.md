# Protocol fee stack, instant-recognition re-check

## What made this round different

The four preceding rounds all reviewed remediations. This one reviewed two deliberate changes of
behaviour: realized senior yield now enters the exchange rate immediately instead of vesting over
a window, and the protocol performance fee now crystallizes inside every interest repayment rather
than lazily at the next checkpoint.

Both are implemented correctly. The audit found no High finding, and, for the first time in this
sequence: the substantive items are about the governance record rather than the arithmetic.

That is a meaningful change of posture, and it is worth being precise about what it does and does
not mean.

## The two changes

**Instant recognition.** With the vesting window set to zero: the yield-notification call becomes
a pure lock release: the assets are already in the vault balance from the mint that preceded it,
the delivery lock still spans the whole window, and no deposit or fee checkpoint can price against
the transient state in between. This is also a strict improvement on the previous code, which would
have written a meaningless vesting record at a zero period. The enable-disable-re-enable cycle was
traced specifically for the stream-resurrection defect an earlier round found and fixed: it remains
safe, because the setter reads the outstanding stream against the *old* window before writing the
new one, so a stream that has already been recognized cannot be revived.

**Per-repayment crystallization.** Every interest leg now closes the fee period at both ends of the
delivery. The added checkpoint runs only after the lock has been released, so it cannot deadlock
against itself, and the conversion views pre-simulate the fee shares that are about to be minted,
so crystallization still creates no second price jump. On balance this is an improvement: the fee
is recognized when it is earned rather than whenever someone next touches the vault.

## What instant recognition re-opens

The vesting decision originally rested on two reasons. One of them has been retracted honestly and
correctly; the other has been overridden without being answered.

The retracted reason was that a stepwise exchange rate is a prerequisite for the intended
integration's rate oracle. That claim was overstated: a monotone stepwise rate is consumable, and
the correction is stated plainly in the architecture decision record, the threat model, the launch
runbook and the public documentation rather than being quietly dropped. Getting a prior
justification wrong and then saying so in the places a reader will actually look is the right
behaviour, and it should not be reversed.

The second reason was a red-team finding: whoever holds shares at the instant a payment lands
captures a full pro-rata slice of it. That finding was deleted rather than dispositioned, and the
mitigation now relied upon, the redemption cooldown, is the one the same record previously judged
insufficient, in terms: it makes the trade unprofitable but does not remove the mechanic. The
cooldown binds only the direct queue exit. Vault shares are freely transferable with no holding
period, so the liquid secondary market that the motivating integration creates restores an
immediate round trip on the captured step.

In fairness, vesting never fully removed that mechanic either, an entrant arriving just after a
payment still received the stream pro rata as it vested. What vesting bought was mandatory time and
credit exposure. So the honest description is that the protection has been reduced rather than
removed. That description appears nowhere, and it should.

Nobody is over-charged by this, no safety-list invariant breaks, and the transfer is between holder
cohorts rather than out of the protocol. It is an economic-design choice, and it is Forest Road's
to make. The finding is that the choice is not written down where a reviewer would find it.

## The gate timing

One consequence is concrete enough to act on before external review.

The pre-mainnet economic-review gate is recorded as complete, re-verified against the previous
seven-day vesting default. The parameter changed to zero the following day. The project's own list
of dispositions requiring re-confirmation against that gate already carries a related item about
the vesting ratio, but was not extended to cover the change itself. The superseded record stated
that the vesting window was an economic-review item that had to clear before mainnet; the
replacement moves that burden onto *enabling* vesting instead, which inverts a gate condition after
the gate closed.

These gates are human-owned and are not an auditor's to close or re-open. The finding is simply
that a gate signed against one parameter value is now being carried against a different one.

## The accounting item

One finding concerns the arithmetic, and it is the only one that could change contract behaviour.

Profit is measured against one valuation base, but the fee shares that settle it are sized against
a second, higher one, while the shares, once minted, dilute a third. The consequence is that a
purely positive repayment can lower the reported exchange rate.

**Corrected after this report was first filed.** A proof of concept was written for exactly this
finding, and it reproduced the defect while falsifying two of the claims made about it. The fall is
not independent of payment size, and the worst case is not the fee rate. Writing the realized base
plus one as *a* and the conservative base plus one as *r*, the rate falls only when *both* the
conservative base sits under roughly a tenth of realized assets *and* the payment is below
`(f·a − r)/(1 − f)`. A deeply marked vault therefore falls on small legs and rises on large ones.

The magnitude is correspondingly smaller than first stated. At a conservative base of 5% of
realized assets, the worst case over all payment sizes is a 0.92% fall. Reaching 8% requires a
vault marked down by 99.9%, which is already a governance event on its own terms. The `1 − f`
figure is an asymptote as the base tends to zero, not a practical bound.

What survives is the defect itself, now executable rather than argued: a repayment that adds value
and loses nothing can still reduce the reported rate, and the existing rate-integrity property
cannot detect it because its tolerance is exactly that asymptote. The reproduction pins the
vault-level arithmetic given a source reporting those values; it does not prove the credit layer
can reach that depth, which remains argued rather than executed.

The remedy is still not obvious, because neither base is correct in both of the branches the state
can resolve into. Which base the fee-share *mint* is denominated in, as distinct from the base
profit is *measured* on, is a financial-mechanic decision rather than a patch.

The existing rate-integrity property cannot detect this. Its tolerance is exactly the asymptote of
the mechanism, so no run count will falsify it.

## Assurance

Three smaller items, all in the direction of accuracy rather than risk.

The depositor-facing warning added by the previous round is keyed on the wrong quantity: it fires on
the remaining fee-free runway, whereas the fee that eventually crystallizes is largest precisely
when that runway is exhausted. The predicate is therefore inverse to the exposure it advertises,
and it falls silent at the point of maximum deferral, which per-repayment crystallization now makes
the ordinary steady state. The interface also cannot read the relevant valuation at all; it is
absent from the published contract surface the front end consumes.

The new interface-support check on the loss backstop reclassifies the *incumbent* backstop as
unreadable, because that contract was compiled before the check existed and does not declare the
identifier. An ordinary rotation away from a perfectly healthy backstop therefore takes the ordering
path documented as reserved for a broken one. The same pre-check also orphaned an existing branch:
the only fixture that exercised a malformed capacity response now short-circuits before reaching it,
so that branch is no longer tested.

## Verification

The reported figures were reproduced rather than accepted. The contract suite passes at the stated
count with no failures, the vault runtime and its remaining size headroom match exactly, and the
new continuous-integration size gate is real, it enumerates every production implementation and
fails closed. The interface identifier was recomputed independently to confirm that adding the
inherited support interface did not change its value, since a mismatch there would have silently
rejected the genuine backstop.

The fork tier could not be exercised in this environment for want of an archive endpoint, so the
claim that it runs without skips is consistent with a separate run but is not independently checked
here.

## Status

Five findings, none High: two Medium, the fee-share denomination question and the incomplete
record for instant recognition, and three Low. All are open.

The two items worth settling before external review are the gate re-confirmation, which is a
signature rather than an engineering task, and a proof of concept for the accounting finding. The
second should come before any decision about changing it: if it holds, the governing record's
current statement that the accepted trade-off runs only against the protocol and never against
remaining holders does not survive one of the two branches, and that sentence would need to change
whether or not the code does.
