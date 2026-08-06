# ADR 0022 — Forced redemption cooldown + conservative-redemption NAV

**Status:** Accepted (user-confirmed 2026-07-20). Supersedes the front-running posture of
[ADR-0010](0010-epoch-fifo-redemption-queue.md) / [ADR-0018](0018-redemption-queue-mechanics.md);
those remain in force for everything they cover *except* the holding-period and exit-pricing
questions resolved here. Two sub-decisions (settlement-heartbeat/liquidity calibration, and the
marking of a declared-but-unquantified default) are flagged **economic-review** and
**counsel-review** respectively and must clear before mainnet.

## Context

A pre-mainnet red-team established (PoC on a Sepolia fork) that the epoch redemption queue does
**not** impose a per-request holding period. `RedemptionQueue.closeEpoch` settles requests FIFO
without reading `epochRequested`, so the "30-day epoch" is a global batch *clock*, not a minimum
hold. Two consequences, both proven:

- **JIT yield-sniping** — deposit into sUSDfr, `requestRedeem`, close the (already-lapsed) epoch,
  and `claim`, atomically, capturing a pro-rata slice of a yield distribution for ~zero holding
  time (`WaterfallEngine.mintYield` delivers senior yield as an instant lump into the vault, so it
  accrues to whoever holds shares at that instant, with no time-weighting).
- **Loss-dodging** — a senior can exit at pre-loss NAV in the window between `declareDefault`
  (which freezes *curators* via `freezeOnDefault`, but not senior redemptions) and `realizeLoss`
  (which burns the vault balance). The queue has no default-awareness.

The `sGROVE` backstop already solves the analogous problem with a **21-day per-position unbonding**
([ADR-0014](0014-sgrove-backstop-parameters.md)) — "long enough that stakers cannot front-run a
known loss event." sUSDfr has no equivalent. Benchmark: **usd.ai** uses a 30-day epoch with **no**
forced cooldown and prevents JIT via an **asymmetric NAV** — deposits price at optimistic NAV
(prorating expected upcoming repayments), redemptions at conservative NAV; deposit price ≥
redemption price always.

## Decision

Adopt **both** a time-based hold and a price-based exit floor — belt and suspenders — but *not*
usd.ai's optimistic-deposit half.

### X — Forced per-request cooldown, decoupled from the settlement cadence

1. Every redemption request stamps `requestedAt = block.timestamp`. A request is **eligible** for
   settlement only once `block.timestamp >= requestedAt + redeemCooldown`.
2. `redeemCooldown` defaults to **21 days** (`Config.DEFAULT_REDEEM_COOLDOWN`), matching
   `SGROVE_UNBONDING_PERIOD` for protocol-wide consistency and for the same stated reason (exceeds
   the realistic gap between a loss becoming foreseeable and `realizeLoss` landing on-chain).
   Governance-settable (timelocked) via `setRedeemCooldown`.
3. **FIFO-monotonic gate.** Because `requestedAt` is non-decreasing along the queue and the
   cooldown is applied uniformly, eligibility time is also non-decreasing. So `closeEpoch` fills
   FIFO from the head and **stops at the first request still in cooldown** — nothing behind it can
   be eligible either. This preserves strict FIFO with no reordering and an O(maxRequests) bound.
   - *Caveat (documented):* a governance change to `redeemCooldown` applies uniformly to in-flight
     requests (eligibility is recomputed with the current value). Timelocked and rare; a shortening
     only helps queued users, a lengthening is bounded by the timelock delay. Monotonicity holds
     because the same current value is applied to all.
4. **Decoupling (the anti-compounding requirement).** A forced cooldown *layered on* the 30-day
   epoch would compound: a request made at day 10 with a 21-day cooldown becomes eligible at day 31
   but, if other activity advances the epoch at day 30, waits for the *next* boundary at day 60 →
   ~50 days, with a discontinuity. To make the effective wait ≈ the cooldown, the settlement
   **heartbeat** (the `epochDuration` that governs how often `closeEpoch` may run and refresh the
   liquidity budget) must be **short relative to the cooldown**. The cooldown becomes the hold; the
   heartbeat becomes only a settlement/liquidity-refresh tick.
   - A settlement that distributes nothing solely because the head is still in cooldown must **not**
     burn the heartbeat (mirrors the existing A1 empty-settlement guard): it reverts
     `Queue_AllInCooldown` and leaves `epochEndsAt` untouched, so the request settles the moment its
     cooldown elapses rather than at the next boundary.
5. **Calibration is an economic-review item.** Changing the liquidity throttle from a 30-day batch
   (`DEFAULT_EPOCH_LIQUIDITY_BPS = 5000`, i.e. 50% of idle per 30 days) to a short-heartbeat smooth
   rate changes the drain profile under a run, and the heartbeat may want to align with the
   monthly cadence at which facility repayments actually arrive. The *mechanism* is decided here;
   the exact `epochDuration` / `epochLiquidityBps` operating point is deferred to economic review
   (consistent with the existing R2-M-01 "hard reservation is an economic-review item" note). The
   committed defaults are conservative and governance-tunable.

### Y — Conservative-redemption NAV only (no optimistic-deposit pricing)

1. Redemptions price on a **conservative NAV** that marks down **declared-but-unrealized losses**
   (outstanding principal on facilities in `Defaulted`/`Accelerated` state) so a senior cannot exit
   at pre-loss NAV during the `declareDefault → realizeLoss` window. This closes finding A1 from
   the pricing side and complements X (which closes it from the time side).
2. **Deposits are unchanged** — they price at today's realized NAV. We deliberately do **not** adopt
   usd.ai's optimistic-deposit NAV (prorating *expected upcoming* yield), because pre-crediting a
   forward return conflicts with **[ADR-0002] variable-yield pass-through (Locked)** and carries
   securities-characterization weight (brief Part 0.5). The yield-sniping defense is instead carried
   entirely by X's holding period. **Invariant owed:** redemption NAV ≤ deposit/realized NAV always.
3. Side effect: sourcing the redemption valuation from accounted state rather than raw
   `usdfr.balanceOf(vault)` makes the exit price robust to the (economically-nil but Pendle-relevant)
   donation rate-spike.
4. **Counsel/economic-review flag:** how to mark a declared default whose loss is not yet quantified
   (conservative choice: treat the full outstanding deployed principal of the defaulted facility as
   impaired until `realizeLoss` settles the true number) is a valuation decision with disclosure
   implications. The mechanism is built to a conservative default; the exact mark is review-gated.

## Alternatives considered

- **Just enforce `epochRequested < closedEpoch`** (make the existing epoch the hold). Simplest, but
  ties the hold length to the 30-day epoch and still compounds with any future cooldown; rejected in
  favor of an explicit, independently-tunable cooldown.
- **usd.ai-style optimistic+conservative NAV, no cooldown.** Best UX (1–29 day wait) and proven, but
  the optimistic-deposit half conflicts with ADR-0002 and the securities posture; and it leaves the
  loss-dodge only partially closed if the conservative mark lags. Rejected as the *sole* mechanism;
  its conservative half is adopted as Y.
- **Cooldown only, no NAV floor.** Closes both attacks if the cooldown exceeds every foreseeable
  loss-realization window, but relies entirely on that assumption; the conservative-redemption NAV is
  cheap defense-in-depth. Adopted together.

## Implementation record

**X — SHIPPED.** `RedemptionQueue` stamps `requestedAt`, gates settlement on
`requestedAt + redeemCooldown` with the FIFO-monotonic head check, and reverts
`Queue_AllInCooldown` without burning the heartbeat. `Config`: cooldown 21d, epoch 30d→1d,
liquidity bps 5000→167.

**Y — SHIPPED (engine + consumption).**
- *Engine* (`DefaultManager`): per-class `declaredDefaultedPrincipal` and per-facility
  `defaultedContribution`, incremented at `declareDefault`/`liquidate`, decremented at
  `realizeLoss`, cleared at a clean resolve. `pendingSeniorImpairment()` nets the pool against
  junior capacity in strict cascade order (curator pool per class, then the sGROVE backstop).
  Purely additive: the cascade split math is untouched and the halmos symbolic proof still
  passes at 9 paths.

  > **CORRECTION (PM-R-11, 2026-07-21).** This bullet used to describe the sGROVE leg as netting
  > "sGROVE per-event capacity — the smaller, conservative figure". That was **false** once
  > PM-R-07 made the sGROVE cap cumulative PER EVENT and snapshotted at each event's first draw.
  > `coverageCapacity()` reports what a *fresh* event could draw; an event that has already drawn
  > can only reach `snapshot - drawn`. After a partial `realizeLoss` the two diverge and the NAV
  > netted MORE coverage than the loss could actually reach — so it **under-marked** impairment,
  > `redemptionTotalAssets()` read high, and a queued senior could exit above the conservative
  > floor, pushing the difference onto the seniors who stayed. Externally reported and reproduced
  > at 150,000 USDfr on a 1M reserve. `DefaultManager` now tracks the coverage consumed by
  > still-live declared defaults and deducts it, **and caps the netting at the capacity standing at
  > that draw** (`liveDefaultCapacityFloor`). The cap is load-bearing: the first version of this fix
  > deducted consumption from a LIVE `coverageCapacity()`, and a later audit round showed that a
  > permissionless `fundCoverage` top-up or a `setPerEventCap` raise re-opened the same under-mark
  > at up to 10x the magnitude. With both halves the direction is restored (it may over-mark, never
  > under-mark) — the arithmetic proof is in the `pendingSeniorImpairment` NatSpec. Regression suite:
  > `test/audit/ExternalFinding2_NavVsEventCap.t.sol`. See `STATE.md` and
  > `audit-reports/EXTERNAL_AGENT_FINDINGS_2026-07-21.md`.
- *Resolve hook*: `WaterfallEngine.distribute` calls `onDefaultResolved(tokenId)` on the sole
  `Defaulted/Accelerated → Resolved` transition, wired through a `setDefaultManager` admin setter
  (not an init arg — the manager is constructed after the engine everywhere). Without it a fully
  recovered facility would depress the NAV forever; `test_withoutResolveHook_theMarkWouldPersistForever`
  pins that.
- *Consumption* (`sUSDfr`): `redemptionTotalAssets()` = `totalAssets() − pendingSeniorImpairment`,
  clamped at zero, sourced through the narrow `IImpairmentSource` interface via a
  `setImpairmentSource` admin setter (zero = realized NAV = pre-ADR-0022 behaviour). Only
  `previewRedeem`, `previewWithdraw` and `maxWithdraw` are overridden; `totalAssets`,
  `convertToAssets/Shares`, `previewDeposit/Mint` and `currentExchangeRate` remain realized, so
  the §1.3 monotonicity subject does not move on a mere declaration. Read is deliberately NOT
  `try/catch` — swallowing it would silently restore the optimistic exit price. A non-zero
  replacement must pass ABI reads for both `pendingSeniorImpairment()` and ADR-0031's
  `performanceFeeImpairment()` and report the latter greater than or equal to the former.
  If either installed-source view later becomes unreadable or violates that ordering, the
  normal setter intentionally fails; timelocked governance can use the evented
  `clearUnreadableImpairmentSource` path only after a fixed-budget probe demonstrably fails.
  A separate minimum recovery-gas reserve prevents caller-supplied under-gassing from
  manufacturing that failure. The path clears to zero and ratchets the lifted NAV into the
  fee HWM without charging performance; it cannot bypass a source readable through both views
  or install a replacement. Consequently, any fee embedded in that operational NAV lift is
  permanently waived; incident monitoring must quantify it before production resumes.
- *Performance-fee consumption* (`sUSDfr`, ADR-0031):
  `performanceFeeTotalAssets = totalAssets() − performanceFeeImpairment()`, clamped at zero.
  `DefaultManager.performanceFeeImpairment()` is the same live declared/past-due exposure
  before curator or sGROVE capacity is netted. This separate view does not change exit pricing;
  it prevents temporary junior capital from being characterized as senior investment profit.
- *Queue alignment*: the settlement budget converts at the conservative rate via
  `convertToSharesAtRedemption` (floor-rounded), so the budget is fully usable during an
  impairment yet still cannot be overshot. The entry gate keeps the REALIZED rate deliberately —
  at the conservative rate a total impairment would value every request at zero and lock users
  out of the queue.
- *C-1 anti-dust-wedge floor (2026-07-22, owner-approved)*: `closeEpoch` never burns a position
  worth zero at the conservative mark — it STOPS there (loud `Queue_HeadNotRedeemable`), keeping
  strict FIFO with no reordering. A sub-wei "dust" head could otherwise block the real positions
  behind it. Rather than deferring/requeuing such a head (which carried its own edge cases), the
  entry gate now bars requests worth less than `minRedemptionValue` (default **$1**, realized;
  governance-tunable, capped at $100). This makes a sub-wei head reachable only after the exchange
  rate has collapsed by >1e18x — a near-total senior loss where every realistically-sized position
  is also sub-wei and halting the queue is the correct behaviour, not griefing. Pinned by
  `test/audit/Fix_C01-queue-zero-value-fill.t.sol` and the `invariant_queue_entryFloorAndStrictFifo`
  invariant.
- *Invariants encoded*: `invariant_redemptionNavNeverAboveDepositNav` (the §Y.2 obligation, on the
  asset base and both conversion directions) and `invariant_queueBudgetCapNeverOvershoots`, in
  `CreditInvariants` — 11 credit invariants now pass at 32,768 calls each with zero handler
  reverts. Unit + fuzz coverage in `test/audit/OptionYConservativeNAV.t.sol` (15 tests).

**Still open on this ADR:** the economic-review calibration (§X.5) and the counsel-review mark
methodology (§Y.4) both remain unsigned-off, and are Part 11 gate inputs.

## Consequences

- New governance parameter `redeemCooldown`; new revert `Queue_AllInCooldown`; `Request` gains
  `requestedAt` (rides the fresh mainnet deploy — the array-element layout is otherwise frozen).
- Effective redemption wait ≈ cooldown (~21 days) + up to one short heartbeat, with no compounding
  cliff.
- Redemptions become default-aware via the conservative NAV; the loss cascade's senior-last ordering
  (§1.3) is now protected on the exit path, not just in `DefaultManager`.
- Economic review must sign off the heartbeat/liquidity calibration and the declared-default mark
  before mainnet (Part 11 gate inputs).
