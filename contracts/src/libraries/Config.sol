// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title Config
/// @notice Single source of truth for token naming and protocol default parameters
///         (brief Part 12: names are final but kept in one module so a rebrand is a
///         single change).
library Config {
    // ── Token naming (final per brief Part 12) ──────────────────────────
    string internal constant USDFR_NAME = "Forest Road Dollar";
    string internal constant USDFR_SYMBOL = "USDfr";
    string internal constant SUSDFR_NAME = "Staked Forest Road Dollar";
    string internal constant SUSDFR_SYMBOL = "sUSDfr";
    string internal constant GROVE_NAME = "Forest Road Grove";
    string internal constant GROVE_SYMBOL = "GROVE";
    string internal constant SGROVE_NAME = "Staked Forest Road Grove";
    string internal constant SGROVE_SYMBOL = "sGROVE";

    // ── Collateral class IDs (ADR-0003 as amended: all FIVE live at genesis) ──
    uint256 internal constant CLASS_FILM_TAX_CREDITS = 1;
    uint256 internal constant CLASS_RENEWABLE_ENERGY = 2;
    uint256 internal constant CLASS_LIFE_SCIENCES = 3;
    uint256 internal constant CLASS_REAL_ESTATE = 4;
    /// @dev Marked-to-market, related-party class (ADR-0015) — distinct margin/
    ///      liquidation model, NOT the receivable model of classes 1-4.
    uint256 internal constant CLASS_DIGITAL_ASSETS = 5;
    uint256 internal constant NUM_CLASSES = 5;

    // ── Credit-layer defaults (ADR-0004 / ADR-0014; governance-adjustable) ──
    /// @dev USD amounts in 18 decimals (USDfr units).
    uint256 internal constant DEFAULT_FIRST_LOSS_PER_CLASS = 10_000_000e18;
    uint256 internal constant SGROVE_UNBONDING_PERIOD = 21 days;
    // Reward streaming window (ADR-0021 / audit R4-EC1): notified rewards drip linearly
    // over this period rather than distributing instantly, so rewards accrue in real time
    // (Pendle-compatible) and cannot be sandwiched by a deposit-before-harvest. Governance
    // tunable via setRewardsDuration, bounded by SGROVE_MAX_REWARDS_DURATION.
    uint64 internal constant SGROVE_REWARDS_DURATION = 7 days;
    uint64 internal constant SGROVE_MAX_REWARDS_DURATION = 365 days;

    // ── Governance defaults (ADR-0013/0021; FR-controlled at launch) ─────
    /// @dev Fixed at genesis, minted to the Forest Road treasury (ADR-0013).
    uint256 internal constant GROVE_INITIAL_SUPPLY = 1_000_000_000e18;
    uint48 internal constant GOV_VOTING_DELAY = 1 days;
    uint32 internal constant GOV_VOTING_PERIOD = 7 days;
    uint256 internal constant GOV_PROPOSAL_THRESHOLD = 1_000_000e18; // 0.1% of supply
    uint256 internal constant GOV_QUORUM_FRACTION = 4; // % of total votes
    uint256 internal constant TIMELOCK_MIN_DELAY = 2 days;
    /// @dev C-01 reserve-loss pre-arm floor. The live arm duration is derived from the
    ///      bound Governor and Timelock at arm time and may be longer; this immutable
    ///      floor prevents a broken or shortened timing dependency from failing open.
    uint256 internal constant RESERVE_LOSS_MIN_PREARM_DURATION = 11 days;
    uint256 internal constant RESERVE_LOSS_SCHEDULING_SLACK = 1 days;

    /// @dev Protocol fee on distributed interest (waterfall), in bps. Launch default
    ///      is deliberately modest; governance-adjustable; economic-review item.
    uint256 internal constant DEFAULT_PROTOCOL_FEE_BPS = 1_000; // 10% of interest

    /// @dev AUDIT FIX (SWEEP-2 S2-F1) — PERMANENT HARD CAP ON THE INTEREST PROTOCOL FEE.
    ///      DO NOT DELETE AND DO NOT RAISE WITHOUT FOREST ROAD DIRECTION.
    ///
    ///      Before this, `WaterfallEngine.setProtocolFee` was bounded only by `Config.BPS` — it was
    ///      the ONLY fee rate in the protocol with no permanent ceiling, while its three siblings
    ///      (`setOriginationFee` -> `MAX_ORIGINATION_FEE_BPS`, `sUSDfr.setPerformanceFee` ->
    ///      `MAX_PERFORMANCE_FEE_BPS`, `setManagementFee` -> `MAX_MANAGEMENT_FEE_BPS`) all carry
    ///      one and two of those are PUBLISHED to holders (`maxPerformanceFeeBps()`,
    ///      `maxManagementFeeBps()`) and described here as "permanent in v1". MEASURED: 10,000 bps
    ///      was accepted and took the ENTIRE senior yield leg (`toVault` 0, `toFee` the whole
    ///      interest receipt). Because `_routeInterest` takes this fee FIRST, off the same senior
    ///      income stream the vault's 20% performance cap protects, total capture of senior yield
    ///      was reachable AROUND a cap the protocol advertises as permanent — and the fee recipient
    ///      holds plain USDfr, so it is not a cascade layer.
    ///
    ///      The LEVEL mirrors `MAX_PERFORMANCE_FEE_BPS` (20%), i.e. 2x the launch default, which
    ///      is the house convention for "a permanent ceiling with real governance room under it".
    ///      The level is an economic-review item; the EXISTENCE of the ceiling is not.
    uint16 internal constant MAX_PROTOCOL_FEE_BPS = 2_000; // 20% of interest — permanent in v1

    /// @dev Protocol-level performance fee on sUSDfr NAV gains above the global,
    ///      post-fee high-water mark. Launches at 10% and may only be changed
    ///      prospectively by timelocked governance. The hard cap is permanent in v1.
    uint16 internal constant DEFAULT_PERFORMANCE_FEE_BPS = 1_000; // 10% of profit
    uint16 internal constant MAX_PERFORMANCE_FEE_BPS = 2_000; // 20% of profit

    /// @dev Effective-annual sUSDfr management fee on a 365-day basis. Launches disabled
    ///      and may only be enabled prospectively by timelocked governance. Fractional
    ///      periods use geometric retention; the hard cap is permanent in v1.
    uint16 internal constant DEFAULT_MANAGEMENT_FEE_BPS = 0;
    uint16 internal constant MAX_MANAGEMENT_FEE_BPS = 200; // 2% per 365-day year
    uint64 internal constant MANAGEMENT_FEE_YEAR = 365 days;

    /// @dev Origination fee charged at facility funding, in bps of principal (OID
    ///      mechanics: the borrower nets principal minus fee). Market range for the
    ///      book's verticals is ~1-2% (ADR-0019); per-class governance-adjustable,
    ///      capped at MAX_ORIGINATION_FEE_BPS; economic-review item.
    uint16 internal constant DEFAULT_ORIGINATION_FEE_BPS = 200; // 2% of principal (Forest Road direction)
    uint16 internal constant MAX_ORIGINATION_FEE_BPS = 1_000; // 10% hard cap

    /// @dev Margin-call cure window for marked-to-market classes (ADR-0015:
    ///      "hours-to-days"). Governance-adjustable per class; economic-review item.
    uint64 internal constant DEFAULT_MARGIN_CURE_WINDOW = 1 days;

    // ── Liquidity-layer defaults (ADR-0010/0022; governance-adjustable) ──
    /// @dev Settlement HEARTBEAT (ADR-0022): how often `closeEpoch` may run and refresh
    ///      the liquidity budget. Under the ADR-0022 cooldown model this is NOT the
    ///      holding period — `DEFAULT_REDEEM_COOLDOWN` is. The heartbeat must be SHORT
    ///      relative to the cooldown so the effective wait ≈ cooldown (no compounding).
    ///      Heartbeat/liquidity calibration is an economic-review item (ADR-0022 §X.5).
    uint64 internal constant DEFAULT_EPOCH_DURATION = 1 days;
    /// @dev Share of the treasury's idle canonical-USDC liquidity a settlement may
    ///      distribute to the queue PER
    ///      HEARTBEAT, leaving the remainder for direct USDfr redemptions. Rescaled from
    ///      the legacy 50%/30-day batch to preserve ~50%/30-day throughput at a 1-day
    ///      heartbeat (5000/30 ≈ 167). Economic-review item (ADR-0022 §X.5).
    uint16 internal constant DEFAULT_EPOCH_LIQUIDITY_BPS = 167; // ~1.67%/day ≈ 50%/30d

    /// @dev ADR-0022: forced per-request redemption cooldown. A queued redemption cannot
    ///      settle until `requestedAt + DEFAULT_REDEEM_COOLDOWN`. Matches
    ///      `SGROVE_UNBONDING_PERIOD` (21 days) — long enough that a senior cannot exit
    ///      ahead of a foreseeable loss (front-running / loss-dodge defense).
    uint64 internal constant DEFAULT_REDEEM_COOLDOWN = 21 days;

    /// @dev AUDIT FIX (SWEEP-2 CSG-F2) — the UPPER bound on `RedemptionQueue.setRedeemCooldown`.
    ///      The LOWER bound is `DEFAULT_REDEEM_COOLDOWN` itself and is not a separate constant on
    ///      purpose: the G2W relief ramp in `CollateralRegistry.conservativeSeniorMark` is written
    ///      against that exact constant, so the floor must BE it — a second constant is a second
    ///      thing to forget to move (SEAM-1). 180 days is the same order as
    ///      `SGrove.setUnbondingPeriod`'s `AUDIT FIX (L)` ceiling and exists for the same reason:
    ///      an unbounded setter can permanently freeze every queued senior exit by fat finger.
    uint64 internal constant MAX_REDEEM_COOLDOWN = 180 days;

    /// @dev C-1 anti-dust-wedge floor. Minimum REALIZED value (in USDfr, 18 decimals) a
    ///      redemption request must be worth to enter the queue — $1. `closeEpoch` never burns a
    ///      position worth zero at the conservative mark; it stops there, so a sub-wei "dust" head
    ///      could otherwise wedge the queue for the real positions behind it. Barring dust at entry
    ///      makes that wedge reachable only when the exchange rate has collapsed by >1e18x (a
    ///      >99.9999999999999999% senior loss), at which point every realistically-sized position
    ///      is ALSO worth under a wei and halting the queue is the correct behaviour, not griefing.
    ///      Measured at the REALIZED rate (`convertToAssets`), not the conservative one, so a
    ///      declared-but-unrealized impairment does not lock new exits out of the queue.
    ///      Governance-tunable via `RedemptionQueue.setMinRedemptionValue`.
    uint256 internal constant DEFAULT_MIN_REDEMPTION_VALUE = 1e18; // 1 USDfr ($1)

    // ── Optional senior-yield vesting (ADR-0023; governance-adjustable) ──
    /// @dev Realized senior yield may be vested linearly into `sUSDfr.totalAssets()`
    ///      instead of landing as an instant step. Only ALREADY-REALIZED yield can be
    ///      streamed — nothing forward-looking is ever pre-credited, so ADR-0002
    ///      variable-yield pass-through is untouched. Pendle accepts a valid stepwise SY
    ///      exchange rate; smoothing is an optional market-design control against
    ///      payment-timing games and abrupt asset-denominated price moves, not a Pendle
    ///      protocol prerequisite. Forest Road selected instant recognition for launch.
    ///      Governance may enable a non-zero window prospectively after economic review.
    uint64 internal constant DEFAULT_YIELD_VESTING_PERIOD = 0;
    /// @dev Hard ceiling on a newly opened stream. The vault also stores an absolute stream
    ///      deadline that non-zero governance re-tunes and rollovers may shorten but never
    ///      extend, so alternating settings cannot defer the same realized yield indefinitely.
    uint64 internal constant MAX_YIELD_VESTING_PERIOD = 30 days;

    /// @notice RAMP POSTURE (Forest Road direction, 2026-07-21): concentration limits are
    ///         seeded WIDE OPEN so idle deposit capital can be deployed into originations —
    ///         initially a facility to the digital-assets book — without a concentration
    ///         dimension blocking it before the book has any diversity to measure.
    /// @dev At `BPS` (100%) the admission test `exp > limitBps * base / BPS` reduces to
    ///      `exp > base`, and no single dimension can exceed the book, so NOTHING BINDS.
    ///      Two consequences the operator must hold in mind, both stated rather than implied:
    ///        1. Concentration TELEMETRY GOES DARK. `isOverConcentrated`, the drift events and
    ///           `concentrationHeadroom` all measure against the configured limit, so at 100%
    ///           they report "clean" unconditionally. There is no on-chain early warning while
    ///           this posture holds; monitoring must come from the `ExposureRecorded` stream.
    ///        2. RATCHETING DOWN LATER IS A CLIFF. Limits are ADMISSION control and a standing
    ///           breach is permitted (a decrease can never be blocked, or a risk limit could
    ///           veto a loss being realized). So whatever is concentrated when a real limit is
    ///           set will instantly read as breached and be frozen from further growth until
    ///           the book grows around it. Set the first real limits AT or slightly above the
    ///           actual composition at that time, then step down — do not jump straight to the
    ///           target.
    ///      `Validate.s.sol` prints an unmissable posture block whenever this is in force, so
    ///      an unlimited deployment can never produce output identical to a limited one.
    uint16 internal constant RAMP_CONCENTRATION_LIMIT_BPS = 10_000; // 100% = unbounded

    uint256 internal constant BPS = 10_000;

    /// @notice Forward weight, in bps, that an UNATTESTED permissionless past-due mark
    ///         (`DefaultManager.markPastDue`) carries in the conservative redemption NAV,
    ///         relative to an ATTESTED declared default. Used as the fallback whenever
    ///         `DefaultManager`'s governed slot reads zero (see `pastDueWeightBps()`).
    /// @dev OWNER DECISION (Forest Road, 2026-08-07): "An unattested, permissionless past-due
    ///      mark should NOT carry the same forward weight as an attested declared default."
    ///
    ///      DERIVED, NOT INVENTED. The protocol already governs an evidence ladder — but only on
    ///      the marked-to-market side, where the three rungs are per-class registry parameters:
    ///        - `maxLtvBps`         the rung the protocol is willing to be exposed at (healthy);
    ///        - `marginCallLtvBps`  the rung at which a PERMISSIONLESS, REVERSIBLE early warning
    ///                              fires (`marginCall`) — forward impairment weight ZERO, it only
    ///                              starts a cure clock;
    ///        - `liquidationLtvBps` the terminal rung, where `liquidate` records the FULL
    ///                              outstanding into the impairment pool and `realizeLoss` becomes
    ///                              reachable — forward impairment weight ONE.
    ///      `markPastDue` is the receivable-side analogue of the MARGIN-CALL rung: permissionless,
    ///      reversible, early, and strictly BEFORE the terminal attested rung (`declareDefault`).
    ///      Governance placed that early rung exactly half way along the governed deterioration
    ///      band. From the mainnet-v1 class-5 tuple in `script/Deploy.s.sol`
    ///      (maxLtv 5_000, marginCall 6_500, liquidation 8_000):
    ///
    ///          (marginCallLtvBps - maxLtvBps) / (liquidationLtvBps - maxLtvBps)
    ///            = (6_500 - 5_000) / (8_000 - 5_000) = 1_500 / 3_000 = 1/2 = 5_000 bps.
    ///
    ///      WHY NOT THE ADVANCE RATE ALONE. `maxLtvBps`/`ltvBps` cannot supply this weight, and the
    ///      reasoning is recorded here so it is not re-attempted: the advance rate is DEFINED as the
    ///      break-even recovery on the attested claim face (ClaimBridge documents the denominator as
    ///      `principal * BPS / ltvBps`). Senior loss is `max(0, principal - recovery)`, so at a
    ///      recovery equal to the advance rate the loss is identically ZERO — the advance rate
    ///      derives a weight of 0, which re-opens H-5 and D5-03. Worse, every variant that forces a
    ///      positive number out of it (haircut on face, re-advance against carried principal) is
    ///      MONOTONE THE WRONG WAY: it marks a more conservatively underwritten facility harder.
    ///
    ///      DO NOT set this to zero (re-opens H-5: a conflicted servicer can sit on a declaration
    ///      while seniors exit at par) or to `BPS` (restores the defect this constant fixes).
    ///      `CollateralRegistry.setPastDueWeight` enforces both bounds.
    uint256 internal constant DEFAULT_PAST_DUE_WEIGHT_BPS = 5_000; // 50%

    /// @notice sUSDfr entry guard (audit H-3 residual): the maximum ratio of the STRANDED,
    ///         realized-but-unvested yield stream (`sUSDfr.unvestedYield()`) to the DEPOSIT BASE
    ///         (`sUSDfr.totalAssets()`) that vault entry tolerates before `deposit`/`mint` close as
    ///         degenerate.
    /// @dev THE HAZARD (ADR-0023): the vault physically holds realized yield that vests linearly
    ///      into `totalAssets()` over a window and is EXCLUDED from `totalAssets()` until it does.
    ///      Deposits price on `totalAssets()` (OZ's un-overridden `_convertToShares`), so a
    ///      depositor entering while that stranded stream is large relative to the base buys shares
    ///      cheaply and then skims a pro-rata slice of the stream as it vests — extracting from the
    ///      incumbents who funded it. The hazard scales with `unvestedYield() / totalAssets()`, so
    ///      the guard keys on exactly that ratio.
    ///
    ///      CALIBRATION (economic-review item; audit finding #3 re-key from 10 to 3, then audit
    ///      R16-01). `sUSDfr._capStreamToBase` enforces a retention boundary against the ACTUAL
    ///      staked base on both sides of the vault: after every yield delivery AND before every
    ///      queue outflow, at most `1/(K+1)` of physical vault USDfr remains unvested and any
    ///      excess is recognized immediately. A healthy low-staking vault therefore cannot be
    ///      closed by receiving a payment that is large relative to deposits (FRV-FS-03), nor by
    ///      an ordinary settlement shrinking the base under a live stream (RC-03).
    ///      The guard remains meaningful after a senior write-down, which burns the recognized
    ///      base while leaving an already-live stream physically present.
    ///
    ///      WHY 3 AND NOT 10 (the audit residual). The OLD `K = 10` reopened entry the moment the
    ///      ratio fell to 10 — with the stranded stream still 10/11 (~91%) of the vault balance —
    ///      leaving a near-total skim band `(0, 10]` open. It did NOT "close the entire band": near
    ///      the top of that band a fresh depositor could still skim ~91% of the vault as the stream
    ///      vested. Dropping to `K = 3` collapses the open band to `(0, 3)`. `K = 3` bounds the
    ///      excluded stream at the closure point to 3/4 (~75%) of physical vault assets. It is a
    ///      DIMENSIONLESS ratio, not a wei level, so it holds identically at every vault scale.
    ///
    ///      CORRECTION (AUDIT R16-01, HIGH — the previous justification of the open band was
    ///      FALSE; do not restore it). This comment used to argue that the top of the `(0, K]` band
    ///      is "only reachable while the withheld stream is a MAJORITY of the vault, an
    ///      already-catastrophic near-total-write-down state, never a healthy one". That was wrong,
    ///      and `K` was never what bounded a routine deposit's skim. The FRV-FS-03 inflow leg
    ///      created exactly that ratio in a HEALTHY vault: the cap retained `K/(K+1)` of the
    ///      balance, the largest retention the guard tolerates, which parks the vault at precisely
    ///      `unvestedYield() == K * totalAssets()` — and `_isDegenerate`'s strict `>` left entry
    ///      OPEN on that point. Servicing payments are sized off book principal, not off live
    ///      sUSDfr supply, so any payment large relative to the staked base reached it. What bounds
    ///      the routine skim is the CAP's retention target, now `1/(K+1)`: healthy operation parks
    ///      at ratio `1/K`, a factor of `K^2` inside this guard, with a minority (25%) of the
    ///      vault's cash excluded, and the boundary itself is now CLOSED (`>=`). The band between
    ///      `1/K` and `K` is reachable only through a realized loss or a governance re-pricing of
    ///      the vesting window.
    ///
    ///      Kept a constant rather than a governance-tunable for
    ///      this pass: like `SUSDFR_MAX_SHARE_PRICE_COLLAPSE`, it is a defensive safety floor, not an
    ///      operating knob, and adding storage/setter surface to the namespaced vault struct for it
    ///      is unwarranted complexity here; a future pass may promote it to a governed parameter.
    ///      See `SUSDfr._isDegenerate` and `SUSDfr._capStreamToBase`.
    uint256 internal constant SUSDFR_MAX_STRANDED_YIELD_RATIO = 3;

    /// @dev AUDIT R15-01. Vault entry closes once the realized per-share rate has collapsed to
    ///      below `1 / SUSDFR_DEGENERATE_RATE_DIVISOR` of the stored high-water mark.
    ///
    ///      WHY A SECOND BAND IS NEEDED. `SUSDFR_MAX_STRANDED_YIELD_RATIO` above keys on
    ///      `unvestedYield()`, which is identically zero at the launch instant-recognition policy
    ///      (`DEFAULT_YIELD_VESTING_PERIOD == 0`). That band therefore cannot fire at launch,
    ///      leaving only the `totalAssets() == 0` POINT — and one wei of a permissionless USDfr
    ///      transfer steps off a point. `_isDegenerate`'s own rationale states the hazard is the
    ///      whole neighbourhood, not the point; this restores the neighbourhood at every vesting
    ///      setting.
    ///
    ///      WHY PAR IS THE REFERENCE. The stored high-water mark was tried first and rejected:
    ///      `_accrueFees`'s empty-supply branch ratchets it to `(assets + 1) * 1e18` whenever any
    ///      balance exists while `totalSupply() == 0`, so a pre-seed donation could inflate the
    ///      hurdle arbitrarily and then permanently close entry through this band. That is
    ///      harmless while the HWM only suppresses fees, and becomes a brick the moment entry
    ///      depends on it — the invariant suite caught exactly that. Par is derived from the
    ///      token's own decimals, is scale-free, and no actor can move it.
    ///
    ///      WHY 100. The band must separate a catastrophic collapse from a merely bad year, because
    ///      closing entry is a governance event: a vault below 1% of its high-water mark is the
    ///      near-total write-down the guard exists for, while a 50%-drawdown vault stays open to
    ///      new capital. ECONOMIC-REVIEW ITEM, on the same footing as `K = 3` above — the shape is
    ///      a safety floor, but the exact multiple is a judgement about when recapitalization must
    ///      route through governance rather than through an ordinary deposit.
    uint256 internal constant SUSDFR_DEGENERATE_RATE_DIVISOR = 100;
}
