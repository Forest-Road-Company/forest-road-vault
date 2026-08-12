# ADR 0023 — Optional senior-yield vesting

**Status:** Accepted as an optional control on 2026-07-20; launch default amended
to **zero vesting** by Forest Road on 2026-07-30. Complements
[ADR-0022](0022-redemption-cooldown-and-conservative-nav.md) and does not reopen
[ADR-0002](0002-variable-yield-passthrough.md).

## Context

`WaterfallEngine` delivers realized senior interest to `sUSDfr` in a lump. A
non-zero vesting period can withhold that already-realized receipt from
`totalAssets()` and release it linearly. This can smooth asset-denominated exchange-rate
moves and reduce payment-timing games in a liquid secondary market.

Earlier versions of this repository incorrectly described smoothing as a Pendle
prerequisite and claimed an immediate exchange-rate step would break a Pendle TWAP.
That is not a protocol requirement. Pendle can integrate a valid, monotone,
stepwise ERC-4626/SY exchange rate. Smoothing may still be useful market design,
especially for YT timing and oracle-lag management, but it is optional and must be
justified against its added accounting and loss-path complexity.

The direct sUSDfr exit path also has a 21-day queue cooldown. That makes a simple
deposit-before-payment/direct-exit trade carry time and credit risk; it does not
eliminate every possible secondary-market timing strategy, but it materially changes
the launch tradeoff.

## Decision

1. **Launch with instant recognition.**
   `Config.DEFAULT_YIELD_VESTING_PERIOD` is zero. A realized interest payment enters
   `totalAssets()` immediately.
2. **Checkpoint fees in the repayment transaction.**
   `WaterfallEngine` opens the vault delivery lock, mints the senior receipt, calls
   `notifyYield`, and then calls `accrueFees`. At the zero-period launch setting, the
   10% global-HWM performance fee therefore crystallizes atomically with the interest
   payment. A second checkpoint against unchanged state cannot charge it again.
3. **Retain optional streaming.**
   Timelocked governance may set a prospective non-zero period up to
   `MAX_YIELD_VESTING_PERIOD` after economic review. In that mode,
   `unvestedYield()` decays linearly and `totalAssets()` excludes the remainder.
4. **Keep delivery atomic in both modes.**
   `beginYieldNotification` blocks fee checkpoints across the underlying mint and
   `notifyYield` closes the lock. This prevents a callback from charging against the
   transient balance before the chosen recognition policy is applied.
5. **Preserve continuity and a fixed terminal bound when governance changes a live schedule.**
   `setYieldVestingPeriod` crystallizes the old schedule before changing its future
   pace. The active stream carries an absolute deadline: a non-zero re-tune or rollover
   may shorten that deadline but never extend it. Setting the period to zero releases
   the remaining realized yield upward and checkpoints the resulting performance in
   that governance transaction. Rewriting the same value remains a no-op.
6. **Preserve the cascade bound for the optional mode.**
   A layer-3 senior burn is bounded by credited `totalAssets()`, not the raw balance,
   so it cannot burn value still withheld in a live stream. Deposits remain closed in
   the fully wiped `totalSupply() > 0 && totalAssets() == 0` state.

## Why this remains realized-yield accounting

Only yield backed by arrived stablecoin and minted through the normal repayment path
can be streamed. No expected or forecast income is pre-credited. A non-zero period
delays recognition of value already held; zero recognizes that value immediately.
Neither mode turns forecast yield into depositor NAV.

## Governance and operating requirements

- Launch validation requires the period to equal the approved default: zero.
- Enabling a non-zero period is a prospective economic-policy change. Governance must
  publish the reason, window, affected market integrations, and rollback conditions.
- Operators must monitor `YieldStreamStarted`, `YieldVestingPeriodSet`,
  `YieldInstantlyRecognized`, and the fee-accrual events when optional streaming is on.
- Direct donations bypass `notifyYield` and enter NAV immediately. They are not a
  substitute for the authenticated interest-payment path.
- Pendle launch readiness is evaluated independently from this parameter. Zero vesting
  is not represented as a Pendle exception or waiver.

## Alternatives considered

- **Mandatory seven-day streaming.** Rejected for launch. It adds state and timing
  complexity without being required by Pendle.
- **Expected-yield per-second accrual.** Rejected because it would recognize income
  before realization and conflict with ADR-0002.
- **Remove the streaming code entirely.** Rejected. Keeping a tested, capped,
  governance-controlled option avoids an upgrade if market evidence later supports it.
- **Per-investor time weighting.** Rejected for fungible transferable shares; it would
  require lots, equalization credits, or new share classes.

## Verification

- `test/audit/YieldVestingStream.t.sol` first asserts the zero launch default, then
  explicitly enables a seven-day test window and covers linear release, rollover,
  continuity, zero-period release, cascade bounds, and fuzzed schedule changes.
- `test/audit/Fix_H3-vesting-period-crystallization.t.sol` explicitly enables the
  optional window and pins the historical re-pricing, stranded-stream, wipe, and
  queue-settlement remediations.
- `test/integration/FeeStackFlow.t.sol` proves a 20% gross facility return takes the
  10% interest deduction first, recognizes the remaining yield immediately, mints the
  10% performance fee in the same repayment transaction, and cannot double-charge it.
- Fork lifecycle coverage asserts the zero-period launch path; a separate fork test
  explicitly enables the optional path so its production wiring remains exercised.
