# Corrovera re-audit of the LMV protocol remediation candidate (ee9b228a)

## Result

Corrovera Security issued **PASS** on the `ee9b228a` delta remediation. Every blocking and
non-blocking finding raised in the 23 November delta review (`CORR-DELTA-01` through
`CORR-DELTA-05`) and the previously surviving mutation (`Mutant M3`) were independently verified
**CLOSED**, with ten of ten compiled delta mutations killed and zero new or regressed Solidity
defects introduced.

At the audit sealing snapshot (08:20 UTC, 24 November 2026), overall release readiness was
**CONDITIONAL-GO** pending two explicit gates:

1. **Hosted CI completion (`CORR-REAUDIT-04`, High operational gate):** At snapshot time, exact-commit
   `Security gates` Run #753 (`45341869384`) had 52/65 jobs passing, 12 still running, and one
   transient `RUN-ERROR` (`139/140` killed, `0` survivors) on untouched `queue-keeper`. Once the
   remaining jobs succeeded, a targeted failed-job rerun (Attempt 2) completed at 11:45 UTC on
   24 November with **66/66 jobs PASS (`0` failed, `0` skipped)** alongside green
   `Persisted counterexample gate` Run #664, closing `CORR-REAUDIT-04`.
2. **Owner disposition on pre-existing touched-file items (`CORR-REAUDIT-01` Medium;
   `CORR-REAUDIT-02`, `CORR-REAUDIT-03`, `CORR-DELTA-06`, `CORR-DELTA-07` Low):** None of these
   was introduced or worsened by `ee9b228a`. Under owner Option A (24 November 2026), Forest Road
   froze `ee9b228a` to preserve the Corrovera delta `PASS`, retained operational batch sizing on
   `queue-keeper` (`MAX_REQUESTS` up to 25 requests per call rather than 1), and tracked bounded
   open-settlement budget-refresh recovery (`CORR-REAUDIT-01`) alongside the Low hardening items
   for the next scheduled `RedemptionQueue` / `CuratorModule` upgrade.

## Deployment and governance status (Phase 1)

On 24 November 2026, all 38 newly compiled Stage 2 contracts and libraries from `ee9b228a` were
finalized on Ethereum mainnet (block `26,486,122`) and verified **`exact_match`** (`38/38`) on
Sourcify, alongside four reused audited components and the 15 Stage 1 preliminary release-monitor
components deployed on 20 November. The Stage 1 governance proposal
(`0xd14e120817bfd084d717dd230118014889c4909d51eb01ec3694a4255c102ce1`, submission tx
`0x83a86e829acec35568c6a1040f57dc4ebcb0dbe99f49d524232fc4044948f698`) was submitted on 24 November
(voting 25–27 November, earliest execution 29 November).

Live protocol proxies remain on their pre-LMV implementations until Stage 2 governance executes.
This review therefore clears the staged `ee9b228a` protocol delta; it does not claim that Stage 2
is already active on Ethereum mainnet or close the separate off-chain liquidation-bot rollout item
(`FRV-NEW-02`).

## Scope and limits

This re-audit covered the `58e651f1 -> ee9b228a` delta (`CuratorModule.sol`, `RedemptionQueue.sol`,
tests and tooling pins) and verified `DefaultManager.sol` and `DefaultLossLib.sol` byte-identical
to `58e651f1`. Two open-weight panel stages ended incomplete due to upstream HTTP 502 errors and
were compensated by full frontier panel coverage, single-model open-weight review, and Foundry
PoC/mutation adjudication. Local Slither `0.11.6` differed in version from the `0.11.5` baseline
with zero added findings (pinned Slither `0.11.5` passed exit 0 in local and hosted CI gates).
