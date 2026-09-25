# Corrovera review of the accrual and open-finding diffs

## Result

The diff sequence covered the continuous-accrual follow-up, recovery-assessment ratchet, ceremony
checks, custody-exit corrections, impairment-source recovery and legacy PIK default handling.
Material candidates passed through independent refutation and focused execution probes.

The confirmed live-path defects were corrected. The assessment no longer dies merely because its
past-due cohort earns another second of interest; the cold impairment-source read no longer crosses
an undersized fixed probe; armed custody review cannot be changed by permissionless dust funding;
and completed legacy PIK is recorded before default rather than forfeited.

## Legacy-only acceptances

The review showed that a 16-coupon legacy default cap was not a safe gas bound once the old proxy
was fully bound to the accrual system. It also showed that the old multi-transaction preparation
could expose curator withdrawal between public evidence and the later freeze.

Forest Road accepted both only because Ethereum V2 was deployed fresh with continuous accrual
active before any facility funding. The legacy upgrade route remains uncleared: any future use
must size the actual state, batch before default, and pause the queue and CuratorModule before
publishing default evidence.

## Scope

This was a review of five diffs and their tests. It does not convert unchanged code outside those
diffs into reviewed code, and BSC findings do not describe the deployment status of Ethereum V2.
