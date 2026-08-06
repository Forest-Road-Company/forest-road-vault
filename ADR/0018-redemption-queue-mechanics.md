# ADR-0018 — RedemptionQueue settlement mechanics (Phase F implementation decisions)

**Status:** Accepted (made during implementation, 2026-07-09). Within the ADR-0010
envelope; parameter defaults flagged to the pre-mainnet economic review.

> **UPDATED BY ADR-0022 AND ADR-0030.** The live design uses a one-day settlement
> heartbeat, a 21-day per-request cooldown, and a 1.67% liquidity slice per heartbeat.
> Clean v1 is USDC-only and has no reserve-instrument subtraction.

ADR-0010 fixed the shape (epoch FIFO, the QEV analog). Four mechanics needed resolving:

## 1. The liquidity budget: a slice of accounted USDC liquidity

A settlement may distribute at most `epochLiquidityBps` of the treasury's accounted
idle USDC liquidity. Rationale: the vault can always redeem shares for USDfr
balance-wise; the real constraint is the USDfr → stable layer. Throttling vault exits
to actual stable liquidity keeps the USDfr issued to exiting stakers honorable, and the
un-distributed share stays available for direct `MintRedeemController.redeem` calls by
USDfr holders. The budget is **snapshotted once per settlement** and is a hard ceiling
(share conversions round down against it — never overshot, proven by per-settlement
asserts in the invariant handler). Both parameters are governance-set launch defaults
for the economic review.

## 2. Chunked, permissionless settlement

`closeEpoch(maxRequests)` is callable by anyone once the epoch ends — no privileged
keeper, no unbounded loop. The first call snapshots the budget; subsequent calls
continue filling head-first until the queue, the budget, or the chunk is exhausted.
The epoch advances only when settlement completes (queue drained or budget spent);
a `maxRequests` stop keeps the settlement open for the next chunk. The head request
may fill **partially** (strict FIFO: nobody behind it receives anything meaningful
before it is whole); its owner can claim partial fills immediately while the remainder
keeps its head-of-queue position.

## 3. No cancellation

A queued request cannot be withdrawn. Cancellation enables queue-jump gaming (request
early to hold an option on the epoch's liquidity, cancel if you don't need it) and
complicates FIFO accounting; v1 makes exit intent binding. Revisit with market-clearing
QEV evolution if Forest Road wants it.

## 4. Points interplay (ADR-0016)

Queued shares sit at the queue's address, which is not identity-bound in the
PointsModule — the requester's participation accrual **stops at request time** by
construction (exit intent ends participation), and the queue accrues nothing (unbound
wallets are untracked). Chosen over continuing accrual until claim: points measure
participation, and a queued exit is no longer participating capital. Asserted in
`test_points_queuedSharesAccrueNothing`.

## Slither triage (queue-specific)

`unused-return` on `reserveInstrument()` (only the value is needed, the timestamp is
deliberately unused here); `calls-loop` in `closeEpoch` (bounded chunk loop over the
trusted protocol vault); `timestamp` (epoch boundaries are day-scale by design).
