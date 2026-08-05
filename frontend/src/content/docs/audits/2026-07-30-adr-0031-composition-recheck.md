# Protocol fee stack, composition re-check

> **Owner disposition and follow-up (30 July 2026).** This page preserves the
> external review as delivered. Forest Road accepted the protocol-revenue
> under-collection in the global-HWM exit/redeposit round trip and declined an
> exit equalization charge. The remaining findings were remediated: the legacy
> seed uses realized assets; the backstop regression is non-vacuous and incoming
> backstops must advertise the complete interface; upgrade authorization probes
> installed downstream implementations and the runbook requires one ordered
> atomic batch; a composition regression now exercises the accepted round trip;
> the UI ignores one-wei rounding dust; and CI has an explicit EIP-170 size gate.
> These follow-up changes remain a new source delta and do not turn this
> historical review into an audit of the resulting tree.

## The shape of this round

Three consecutive rounds of this fee work each produced a High finding, and each one had the same
root cause: a fee hurdle denominated in one asset base, adjusted by a quantity measured in a
different one. Every remediation closed the specific defect and moved the class somewhere else —
first out of the high-water-mark ratchet, then out of the junior-capacity bracket, then out of the
exit path.

This round is the first that does not continue that sequence. There is no High finding, no
invariant on the protocol's safety list is broken, and the residual that remains has the opposite
sign from all three predecessors: it costs the protocol its own revenue rather than costing
holders theirs.

It is also the round that explains why the sequence happened, which turns out to be more useful
than any individual finding.

## What the exit fix actually achieved

The previous round found that an exit priced on the junior-supported redemption NAV carried the
performance hurdle out at the wrong price, so a leaver shed deferred fee exposure onto the holders
who stayed. The fix carries the hurdle out at the greater of two quantities: the assets actually
paid, or the leaver's pro-rata share of the hurdle.

The pro-rata leg is the load-bearing half, and it works for a reason worth stating precisely.
Converting the pro-rata carry back into a per-share rate leaves that rate exactly unchanged, and
the maximum is never below the pro-rata term. So the stored per-share high-water mark is
**monotonically non-decreasing across every exit, in every reachable state**.

That is a real guarantee, and it is the one the previous three rounds never had. A surviving
holder can no longer be charged more than a textbook per-share high-water-mark fee. The failure
direction that produced every earlier High — a hurdle pushed below holders' own cost basis, so a
fee lands on something that was never profit — is now structurally impossible rather than merely
absent.

The backstop-rotation fix is also clean. Exactly one checkpoint opens on every path and is always
followed by the single close, the no-op early exit skips both, and a broken outgoing backstop no
longer blocks its own replacement — which is what the previous round asked for.

## Why four rounds were needed

The interesting result is not any of the findings. It is that three properties, each one forced by
a previous round's remediation, cannot all hold at once.

- **Entry must be basis-additive.** A deposit adds exactly the principal delivered to the hurdle.
  Anything else taxes an entrant on a gain earned before they arrived. Rounds one and two forced
  this.
- **Exit must remove the departing shares' basis.** Under a pooled model that is the leaver's
  pro-rata share. Anything smaller dumps their deferred liability on the holders who stay. Round
  three forced this.
- **A value-neutral round trip must not move the hurdle.** Anything else lets anyone erase deferred
  fee for free. This round forced it.

With a single scalar hurdle these are jointly unsatisfiable. Entry contributes the full principal;
exit removes only the pro-rata share; and whenever the entrant came in above the pooled average
basis the difference is stripped permanently. Round three chose the first and third properties and
sacrificed the second. Round four chose the first and second and sacrificed the third.

Neither is wrong so much as incomplete, and the choice between them has never been framed as a
choice. That is the substantive recommendation of this round: the trade-off is a financial-mechanic
decision, not an implementation detail, and it belongs with Forest Road and the economic review
rather than with whoever writes the next patch.

## The residual

The surviving instance is a round trip that restores the vault exactly. An incumbent redeems a
fraction of their position through the queue and re-deposits the proceeds; assets, share supply and
all three valuation bases return to their starting values, but the hurdle is permanently higher, so
the deferred performance fee the protocol had accrued is destroyed.

It needs no fresh capital, and the damage scales with the fraction round-tripped rather than with
capital committed: redeeming and re-depositing most of a position destroys most of the deferred
fee. Chunking the exit across settlements does not reduce it. The only frictions are time — the
redemption cooldown and the per-epoch liquidity throttle — and there is no minimum holding period
between deposit and queue admission.

The direction matters for how urgently this needs answering. No holder is over-charged and no
exchange-rate guarantee is broken; the protocol simply loses fees it had earned. That makes it a
revenue and fairness question rather than a custody one, which is why it is recorded as Medium and
referred upward rather than patched in place.

A second, smaller base mismatch survives in the upgrade path: seeding a legacy proxy's hurdle
anchors on the redemption base, which removes the junior-covered portion of the old mismatch but
leaves the senior-marked portion. The anchor that is neutral in both terminal states — a cure and a
realized loss — is the realized asset base. It is a one-token change, and both existing regressions
for that branch happen to run with the residual pinned to zero, which is why it was not visible.

## Assurance

Two things this round did not find, which is itself informative. The queue campaign can now
construct the divergent-NAV state the previous round said it structurally could not, and the
management-and-performance sequencing now has a test that runs both fees against genuinely
different bases with independently computed expectations. Both were previous-round findings and
both are properly closed.

What the assurance tier still cannot do is falsify the flow law itself. The invariant added for it
re-derives the production expression with the same rounding, and checks one operation at a time
against state captured immediately before that operation — so a defect that only appears in the
composition of two operations is invisible to it by construction. That is exactly the defect this
round found, and no test in the repository composes an entry with an exit of the same shares.

The regression added for the backstop change is vacuous in a more ordinary way: its fixture never
reaches a state in which the outgoing backstop is read at all, so it passes identically against the
code the fix replaced.

Separately, the whole fork tier — every one of its tests — did not execute in this review
environment for want of an archive endpoint, including the suite that was modified by this very
change. The rest of the suite is deterministic and green across repeated runs.

## Operational constraints

Two items are not defects but will shape what can be done next.

The vault implementation now sits about 1.5% below the contract size limit. The fee work has
consumed roughly two thirds of the headroom that existed a few checkpoints ago, and the build
pipeline has no explicit size gate — the only thing between a routine change and an undeployable
implementation is a compiler warning being promoted to an error.

And this change introduced a new cross-contract dependency: the vault now calls a second valuation
method that did not exist before, through two layers of upgradeable proxies. The candidate is
validated when a source is installed, but not when an implementation behind an already-installed
address is upgraded. Upgrading the vault ahead of the sources would freeze every value path in the
vault, including queue settlement. That ordering needs to be an executable constraint or, at
minimum, a stated atomicity requirement in the launch runbook.

## Status at delivery

Seven findings, none High: two Medium on the remaining base mismatches, two Medium on assurance and
upgrade ordering, three Low. All were open when delivered. The owner disposition above records the
subsequent accepted policy and remediations without retroactively expanding this review's scope.
