# Recovery assessments and redemption top-ups

> Clean mainnet v1 includes `AssessedImpairmentSource`, whose zero-recovery base is
> `DefaultManager`, but does not deploy or wire `RecoveryTopUpDistributor`. The assessment
> wrapper was first exercised on the Sepolia QA deployment. With no active governance
> assessment, queue pricing is exactly the conservative zero-recovery result.

## Why an exit can be marked down

sUSDfr deposits mint at realized NAV. Queue exits use a default-aware redemption NAV so an investor
cannot leave at an unimpaired price after a loss is already known.

The zero-recovery calculation applies protection in strict order: curator first-loss capital,
then reachable sGROVE coverage, then sUSDfr principal. Only the residual expected to reach sUSDfr
reduces the queue price. Idle protocol reserves are not part of the sUSDfr denominator because they
also back unstaked USDfr, which does not receive credit yield or bear the residual credit loss.

## Professional recovery marks

Governance may publish a time-limited professional assessment of the senior loss after estimated
recoveries and both junior layers. The assessment:

- can only reduce the zero-recovery impairment;
- is linked to a published recovery memorandum by an evidence hash;
- is bound to the exact revisioned default, past-due and curator first-loss state standing when
  it is published, and to the sGROVE backstop capacity available at that moment;
- lasts no more than 30 days; and
- automatically returns to zero-recovery pricing if it expires or that risk state changes.

A new default, past-due mark, recovery, realized loss or change in curator first-loss makes the
assessment inactive immediately. This still happens if offsetting changes leave the headline
impairment number unchanged. A fresh professional memorandum and governance assessment are
required before the discount can apply again.

Backstop capacity is treated directionally rather than as an exact match. A **fall** in sGROVE
backstop capacity invalidates the assessment, because less junior protection stands behind the
senior layer than the memorandum assumed. A **rise** does not, because more junior protection can
only make an already-published assessment more conservative than it needed to be. Anyone can add
backstop coverage without permission, so an exact-match rule let an outside party cancel a
depositor-favourable assessment at negligible cost.

An assessment can change or become inactive before a queue request settles. The amount shown in
the app is therefore the current on-chain preview, not a guaranteed future quote.

## A later payment is possible, not promised

If actual recovery is better than the assessment used for an earlier fill, governance may fund a
separate USDfr top-up distribution for affected request IDs. The distributor cannot mint USDfr or
withdraw assets from sUSDfr; each round must be fully funded before it is published.

No top-up or airdrop is guaranteed, automatic, or included in the redemption preview. A round may
never be created. If one is created, its allocation root, evidence, funding source, and
reconciliation to queue fills should be published so recipients can independently verify it.
