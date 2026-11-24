# Corrovera delta audit of the LMV protocol repair candidate (58e651f1)

## Result

Corrovera Security issued **NO-GO** on candidate commit `58e651f1` and blocked release promotion
until five confirmed delta issues were corrected:

- **`CORR-DELTA-01` (High):** Extracting `drawForSeniorExit` into `DefaultLossLib` increased
  `DefaultManager` link references from 3 to 4 while `tools/library-link-binding.test.mjs` still
  pinned 3, breaking hosted CI `deployment-ceremony` alongside `tools/origination/ci-scope.test.mjs`
  and a runner disconnect on `invariants (shard 1)` in Run #752.
- **`CORR-DELTA-02` (High):** `CuratorModule._callPoints` swallowed observer failures regardless
  of caller-supplied gas, allowing a curator calling `withdrawFirstLoss` with a tight gas budget to
  complete withdrawal while skipping `PointsModule.onCuratorStakeChange` and leaving phantom 5x
  curator points accruing until reconciliation. Reproduced offline and on Ethereum fork block
  `26,398,000`.
- **`CORR-DELTA-03` (Medium):** `RedemptionQueue._canReachSettlementFloor` walked queued heads
  without checking `redeemCooldown`, allowing a sub-floor eligible head followed by a cooling
  request to latch `isSettling() == true` into a stale-budget `Queue_NoLiquidity` trap. Reproduced
  offline and on Ethereum fork block `26,398,000`.
- **`CORR-DELTA-04` (Low):** Targeted mutation `M3` deleting the zero-value later-head guard in
  `_canReachSettlementFloor` survived the unit test suite.
- **`CORR-DELTA-05` (Low):** `CuratorModule.claimClosedRound` emitted `_notifyPoints` even when
  bounded 32-hop `_settleStaleRound` had not yet reached `pool.round`, which could emit a zero
  balance update and reset curator points maturity if prior loss hooks had failed open or the
  points module had been swapped.

## Remediation and carried-forward dispositions

All five items (`CORR-DELTA-01` through `CORR-DELTA-05`) were fixed in commit `ee9b228a` and
verified **CLOSED** (with `Mutant M3` killed) in Corrovera's 24 November 2026 re-audit.

Four pre-existing Low and Informational items identified in touched files (`CORR-DELTA-06` through
`CORR-DELTA-09`) were explicitly accepted or deferred by the owner on 23 November 2026 rather than
silently dropped: ADR-0022/A1 `stopReason == 2` heartbeat behavior (`CORR-DELTA-06`), Timelock
recovery via UUPS if `ReserveManager.custodyLossUnabsorbed()` reverted (`CORR-DELTA-07`),
admin-only `setEpochDuration` upper bound (`CORR-DELTA-08`, also tracked as `CORR-REAUDIT-02`),
and zero-residual `CommitmentLedger` delegatecall (`CORR-DELTA-09`).

## Scope and limits

This engagement audited the `74ac92a7 -> 58e651f1` protocol repair delta and observed hosted CI
Run #752. It did not re-audit unchanged files outside the delta closure, and `58e651f1` was never
deployed to mainnet proxies.
