# ADR-0021 — sGROVE backstop implementation: the USDfr coverage-reserve model

**Status:** Accepted (2026-07-10, Phase H; coverage model confirmed by the user:
"(a) and we can always manually add funds"). Amends ADR-0014's cap semantics as noted
below; calibration remains an economic-review item.

> **AMENDED 2026-07-13 (post-campaign R4-EC1 + audit R5):** Rewards now **STREAM**
> Synthetix-style over a governance-tunable window (`rewardsDuration`, default 7d) via a
> `rewardPerToken`/`earned` accumulator — NOT the instant index-based pro-rata described
> below. A mid-stream `notifyRewards` cannot lower the drip rate (M-1 guard,
> `SGrove_RewardRateWouldDecrease`), defeating the deposit-before-harvest sandwich and
> supporting Pendle SY adapters (`rewardSchedule`/`earned` views). `notifyRewards` also
> fails loud (`SGrove_BadParams`) if `rewardsDuration` is 0 (R5-UP1 upgrade-path guard).
> **Known (R5-EC1, documented in `security-review.md`):** a reward slice streamed while
> `totalStaked == 0` is stranded with no governance sweep — a recommended follow-up.

## The problem

`ICascadeBackstop.coverShortfall` must deliver USDfr to the DefaultManager **within
the call** (the balance-delta-enforced contract from ADR-0017 §3), but sGROVE stakers
hold GROVE. No trustworthy on-chain GROVE→USDfr conversion exists at launch (no deep
market, no price oracle worth the manipulation surface it would create).

## Decision — option (a): a dedicated USDfr coverage reserve

The backstop's coverage capacity is a **USDfr reserve held by the SGrove contract**,
funded permissionlessly (`fundCoverage`): the governance-routed protocol fee share,
Forest Road's ADR-0014 seed (~$5M) and manual top-ups, or anyone. Coverage per event:
`covered = min(requested, reserve × perEventCapBps)` — ADR-0014's "≤ 50% of staked
sGROVE per event" cap is **re-based onto the reserve** (the cap's purpose — preserving
a residual backstop across successive events — carries over exactly; the original
GROVE-denominated base had no deliverable meaning without a conversion path).

**Honesty consequence (state everywhere — docs, risk page, dashboard):** the
backstop's real capacity is `coverageCapacity()` (reserve × cap), NOT the headline
staked-GROVE value. Staked GROVE is never converted, slashed, or seized in v1 —
stakers' risk is the reward stream (fees routed to coverage instead of rewards) and
governance's routing power, not principal. Whether GROVE principal should also be
at risk (requiring a conversion mechanic) is explicitly deferred to the economic
review; the interface accommodates it later without cascade changes.

Rejected alternatives: slash-and-auction GROVE (cannot deliver USDfr atomically;
auction design + price manipulation surface); governance-executed conversion (days of
delay against a same-transaction cascade); a synthetic GROVE price oracle (the
manipulation surface would be the protocol's weakest point).

## Mechanics (implemented)

- **Staking:** non-transferable positions; `stake` / `requestUnstake` (starts the
  ADR-0014 21-day cooldown; unbonding stake leaves the earning set immediately) /
  `claimUnstake` (ids stable, no double-claim). Unbonding GROVE stays custodied until
  release.
- **Rewards:** index-based pro-rata accumulator (`notifyRewards` — permissionless,
  routing is governance's decision per ADR-0019; `claimRewards`). Late stakers earn
  only post-join distributions; index flooring dust is bounded and never in stakers'
  favor.
- **Coverage:** `fundCoverage` permissionless; `coverShortfall` CREDIT_ROLE
  (DefaultManager), **never pausable** (the cascade cannot be suppressed —
  consistent with ADR-0017 §4); rewards and coverage buckets are strictly separate
  (custody invariant: contract USDfr == reserve + notified − claimed).
- **GROVE:** fixed genesis supply to the Forest Road treasury (ADR-0013 control,
  stated honestly), ERC20Votes + Permit, timestamp clock (governance parameters are
  second-denominated).
- **Governor/timelock:** standard audited OZ stack (Settings + CountingSimple +
  Votes + QuorumFraction + TimelockControl behind UUPS, upgrades via `onlyGovernance`);
  launch parameters in `Config` (1d delay, 7d period, 1M GROVE threshold, 4% quorum,
  2d timelock); the timelock is the module admin (exercised end-to-end in tests
  against a real parameter change). Forest Road's genesis supply is effective control.

## Slither triage

`timestamp` on the unbond-release comparison — 21-day-scale semantics; miner skew
immaterial. Standing triage family.
