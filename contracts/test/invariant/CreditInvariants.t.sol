// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {CreditHandler} from "./handlers/CreditHandler.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @dev Stateful-fuzz invariants for the CREDIT LAYER over the full stack
///      (CLAUDE.md §1.3). The two centerpiece properties — waterfall value
///      conservation and loss-cascade ordering — are additionally asserted
///      per-call inside the handler against an independent differential model,
///      so every fuzzed distribution and loss event is checked exactly, not
///      just at invariant boundaries:
///      - BACKING:       supply <= backing through funding, repayment, default,
///                       recovery, and loss realization
///      - CONSERVATION:  every distributed unit lands in exactly one of
///                       fee / senior vault; principal returns exactly
///      - CASCADE:       losses drain curator -> backstop -> depositors, never
///                       skipping or inverting a layer (per-call + corollary)
///      - SUBORDINATION: curator capital never leaves while required (senior is
///                       never subordinated to junior)
///      - RATE INTEGRITY: the fee-net rate falls only at explicit depositor-loss
///                        events or when a bounded protocol fee becomes due
///      - RECONCILIATION: exposure == pending + outstanding; curator pools == module balance; the
///                       engines retain nothing
contract CreditInvariants is CreditLayerFixture {
    CreditHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new CreditHandler(
            [address(usdc), address(usdfr), address(compliance), address(reserves), address(controller), address(vault)],
            [
                address(registry),
                address(bridge),
                address(oracle),
                address(curator),
                address(waterfall),
                address(defaultManager)
            ],
            address(backstopMock),
            [servicer, anchorCurator, originator, custodian, feeRecipient, borrower],
            complianceAdmin
        );
        // AUDIT H-3: let the handler fuzz the timelocked yield-vesting re-tune (see
        // `CreditHandler.retuneYieldVesting`). The setter itself is NOT a fuzz selector.
        handler.setVaultAdmin(admin);
        targetContract(address(handler));
        // ghost-free helper views must not be fuzzed as actions
        bytes4[] memory selectors = new bytes4[](21);
        selectors[0] = CreditHandler.depositAndStake.selector;
        selectors[1] = CreditHandler.originate.selector;
        selectors[2] = CreditHandler.fund.selector;
        selectors[3] = CreditHandler.repay.selector;
        selectors[4] = CreditHandler.postFirstLoss.selector;
        selectors[5] = CreditHandler.withdrawFirstLoss.selector;
        selectors[6] = CreditHandler.fundBackstop.selector;
        selectors[7] = CreditHandler.declareDefault.selector;
        selectors[8] = CreditHandler.accelerate.selector;
        selectors[9] = CreditHandler.realizeLoss.selector;
        selectors[10] = CreditHandler.warp.selector;
        // PM-R-11 reach: the coverage reserve drained to EXACTLY zero while live defaults still
        // hold consumption. Random sequencing never gets there (see the handler's note), and
        // `invariant_pendingImpairmentNeverUnderMarks` cannot see the third under-marking
        // variant from any other state.
        selectors[11] = CreditHandler.fundBackstopSmall.selector;
        selectors[12] = CreditHandler.stressCoverageFloor.selector;
        // AUDIT H-3: timelocked governance setters were invisible to this suite — a re-tune
        // dropped the rate 471 bps through 32,768 clean calls. Model the class, not the instance.
        selectors[13] = CreditHandler.retuneYieldVesting.selector;
        // AUDIT H-5: the REVERSIBLE past-due impairment pool is a value-moving input to
        // `pendingSeniorImpairment` (the conservative-NAV / backing path, §1.3). `markPastDue`
        // warps past the ~1-year maturity + 21-day grace to reach the state; `clearPastDue`
        // (servicer) reverses it. Without these two, a regression in the past-due accounting would
        // pass the mandated impairment invariants unseen.
        selectors[14] = CreditHandler.markPastDue.selector;
        selectors[15] = CreditHandler.clearPastDue.selector;
        // ADR-0035 anti-vacuity: repeatedly assert that the mock's compatibility capacity is the
        // raw live balance, matching production, rather than leaving that identity unexercised.
        selectors[16] = CreditHandler.checkUncappedBackstopCapacity.selector;
        // ADR-0031: governance may vary the global performance fee prospectively.
        // Exercise the setter and its old-rate crystallization in the stateful campaign.
        selectors[17] = CreditHandler.retunePerformanceFee.selector;
        // ADR-0031: management fee is both stateful and time-dependent. Fuzz the
        // setter so the geometric-retention branch below is live and bounded.
        selectors[18] = CreditHandler.retuneManagementFee.selector;
        // AUDIT R16-01: `repay` bounds interest to a flat window, so whether a delivery is large
        // ENOUGH RELATIVE TO THE LIVE BASE to drive `_capStreamToBase` past its retention target
        // was left to luck — the campaign never systematically visited the parked state where the
        // R16-01 skim lives. This action sizes the payment off the vault's own cash and asserts
        // the parked ratio per call. Registering the selector is the whole point.
        selectors[19] = CreditHandler.deliverOversizedYield.selector;
        // OWNER DECISION 2026-08-07 (G2W): the unattested past-due weight RAMPS back to full over
        // one redemption cooldown, and `invariant_pendingImpairmentNeverUnderMarks` now models that
        // ramp. Random sequencing reaches the EXPIRED half of it in only ~11 of 256 default-profile
        // runs (measured), which is luck, not coverage -- exactly the shape of the two vacuous
        // invariants this repository has already been bitten by. This reach action drives the
        // expiry deterministically whenever a cohort is standing.
        selectors[20] = CreditHandler.expireReliefRamp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice INVARIANT (backing, ADR-0012): supply never exceeds backing — now
    ///         across the full credit lifecycle including losses.
    function invariant_backing_supplyNeverExceedsBacking() public view {
        assertLe(controller.totalUSDfr(), controller.backingValue(), "BACKING VIOLATED");
    }

    /// @notice INVARIANT (waterfall conservation): cumulative fee + senior yield + cumulative
    ///         withheld protocol fee exactly equals cumulative interest distributed.
    /// @dev AUDIT FIX (ADV-1) — STRENGTHENED FROM TWO LEGS TO THREE, NOT WEAKENED. This read
    ///      `ghostFees() + ghostVaultYield() == ghostInterestDistributed()`, the two-way identity
    ///      `interest == fee + toVault`. That identity was already stale under the R16-M5 headroom
    ///      clamp and is definitively false under ADV-1's senior-impairment fee withholding, whose
    ///      whole point is that some interest is RETAINED AS BACKING rather than minted. Folding
    ///      the withheld amount back into `ghostFees` would have kept the old shape green while
    ///      destroying the ability of `CreditHandler.repay`'s per-call `DIFF: fee split` assert to
    ///      reconcile against the fee recipient's REAL balance — the weakening this file must not
    ///      accept. Every unit of interest is still accounted for, to the wei, in exactly one of
    ///      three named legs.
    function invariant_waterfall_conservesValue() public view {
        assertEq(
            handler.ghostFees() + handler.ghostVaultYield() + handler.ghostFeeWithheldForImpairment(),
            handler.ghostInterestDistributed(),
            "WATERFALL CONSERVATION VIOLATED"
        );
    }

    /// @notice INVARIANT (cascade ordering): enforced exactly per loss event in the
    ///         handler (differential model). Between calls, the standing corollary:
    ///         any depositor loss ever realized implies the film curator pool and the
    ///         backstop were empty at that moment (asserted there); here we pin the
    ///         cumulative bookkeeping still reconciles.
    function invariant_cascade_orderingHolds() public view {
        // if depositors ever lost, the per-call asserts proved both junior layers
        // were dry first; the ghost survives as the audit trail
        handler.ghostDepositorLosses(); // reverts never; presence = per-call model ran
        assertTrue(handler.sharePriceCapped(), "CURATOR SHARE PRICE EXCEEDED 1");
    }

    /// @notice INVARIANT (fee-aware rate integrity): below the last evented floor,
    ///         a decrease is legal only while a bounded protocol fee is economically due.
    function invariant_exchangeRate_neverFallsWithoutLossOrFee() public view {
        uint256 rate = vault.currentExchangeRate();
        uint256 floor = handler.rateFloor();
        // The handler's fee-parameter checkpoints already permit one wei of share-price
        // rounding. Apply the same tolerance before classifying a decline as economically due.
        if (rate >= floor || floor - rate <= 1) return;

        bool managementDue =
            vault.managementFeeBps() != 0 && block.timestamp > vault.lastFeeAccrual() && vault.totalSupply() != 0;
        bool performanceDue = vault.performanceFeeBps() != 0 && vault.feeExchangeRate() > vault.highWaterMark();
        assertTrue(managementDue || performanceDue, "RATE FELL WITHOUT LOSS OR A DUE FEE");

        // Quantitative combined-fee bound. The previous version skipped ALL
        // bounds whenever `managementDue`, accepting even a fall to zero. Apply
        // the independently re-derived geometric management retention to the
        // last evented floor. A simultaneously pending performance fee may
        // dilute that retained rate too; without coupling this bound to the
        // implementation's HWM arithmetic, its worst case is the configured
        // percentage of the entire post-management marked NAV. That bound is
        // deliberately conservative but finite: even with a zero hurdle, the
        // rate must retain at least (1 - performanceFee) of its value.
        uint256 retainedFloor = floor;
        if (managementDue) {
            uint256 annualFeeWad = Math.mulDiv(vault.managementFeeBps(), 1e18, Config.BPS);
            uint256 elapsedYearsWad =
                Math.mulDiv(block.timestamp - vault.lastFeeAccrual(), 1e18, vault.managementFeeYear());
            uint256 retentionWad =
                uint256(FixedPointMathLib.powWad(int256(1e18 - annualFeeWad), int256(elapsedYearsWad)));
            retainedFloor = Math.mulDiv(floor, retentionWad, 1e18, Math.Rounding.Floor);
        }
        if (performanceDue) {
            retainedFloor =
                Math.mulDiv(retainedFloor, Config.BPS - vault.performanceFeeBps(), Config.BPS, Math.Rounding.Floor);
        }
        assertGe(rate + 5, retainedFloor, "FEE DILUTION EXCEEDED THE COMBINED PROTOCOL-FEE BOUND");
    }

    /// @notice INVARIANT (AUDIT H-3 remediation + residual — no inflation/skim mint into a
    ///         degenerate vault): entry is closed IFF shares are outstanding AND the deposit base
    ///         has collapsed to zero, the realized share price is below 1% of par, OR the base is
    ///         dwarfed by the stranded unvested-yield stream.
    /// @dev A genuine BICONDITIONAL. The independent reference model includes both the original
    ///      stranded-stream predicate and R15-01's launch-safe collapsed-price band, so it checks
    ///      BOTH directions — the guard closes every degenerate state (no inflation/skim mint)
    ///      AND never bricks a solvent one. The
    ///      degenerate state is REACHABLE and this suite reaches it: `realizeLoss` bounds the
    ///      layer-3 senior burn by `totalAssets()`, so `depositorLoss == totalAssets()` is a
    ///      permitted maximal write-down that strands the whole unvested stream. Pricing is
    ///      degenerate across the whole band where the stream dwarfs the base (not just at the zero
    ///      point), so `deposit`/`mint` must fail loudly (`SUSDfr_DegenerateSharePrice`) there.
    ///      Exits stay open by design: a degenerate vault must still settle its queue.
    function invariant_degenerateVaultIsClosedToNewCapital() public view {
        uint256 supply = vault.totalSupply();
        uint256 assets = vault.totalAssets();
        uint256 wholeShare = 10 ** vault.decimals();
        uint256 par = 10 ** usdfr.decimals();
        uint256 virtualShares = 10 ** (vault.decimals() - usdfr.decimals());
        uint256 realizedRate = Math.mulDiv(wholeShare, assets + 1, supply + virtualShares, Math.Rounding.Floor);
        bool belowLaunchFloor = realizedRate * Config.SUSDFR_DEGENERATE_RATE_DIVISOR < par;
        // Independent reference model of SUSDfr._isDegenerate. Keep every economic clause here:
        // omitting the R15-01 launch floor made this invariant misclassify a correctly closed vault.
        // AUDIT R16-01: the stranded-stream comparison is `>=`. Entry must be CLOSED on the exact
        // boundary `unvestedYield() == K * totalAssets()` — the point of maximum tolerated skim,
        // which the old strict `>` left open and which the old `_capStreamToBase` retention of
        // `K/(K+1)` of the balance parked healthy vaults on exactly. A `>` here would let a vault
        // sitting on the boundary be classified "solvent" and then fail the `SOLVENT VAULT CLOSED`
        // arm; it is the model, not the guard, that must follow.
        bool closed = supply != 0
            && (assets == 0 || belowLaunchFloor || vault.unvestedYield() >= Config.SUSDFR_MAX_STRANDED_YIELD_RATIO * assets);
        if (closed) {
            assertEq(vault.maxDeposit(address(this)), 0, "DEGENERATE VAULT STILL ACCEPTS DEPOSITS");
            assertEq(vault.maxMint(address(this)), 0, "DEGENERATE VAULT STILL ACCEPTS MINTS");
        } else if (!vault.paused()) {
            // and the guard must not brick a non-degenerate vault
            assertGt(vault.maxDeposit(address(this)), 0, "SOLVENT VAULT CLOSED TO DEPOSITS");
        }
    }

    /// @notice INVARIANT (ADR-0022 §Y.2 — conservative-redemption NAV): the price a holder
    ///         EXITS at never exceeds the price they could ENTER at, in any reachable state.
    /// @dev This is what makes the asymmetry safe. If it ever inverted, a round trip
    ///      (deposit then redeem in the same state) would extract value from the vault at the
    ///      expense of the remaining holders — a mint-from-nothing on the senior claim. Asserted
    ///      on the asset base AND on both share-conversion directions, because the two round in
    ///      opposite directions (`previewRedeem` floors, `previewWithdraw` ceils) and a rounding
    ///      slip in either would open exactly that round trip.
    function invariant_redemptionNavNeverAboveDepositNav() public view {
        assertLe(vault.redemptionTotalAssets(), vault.totalAssets(), "REDEMPTION NAV ABOVE DEPOSIT NAV");
        uint256 oneShare = 10 ** vault.decimals();
        assertLe(vault.previewRedeem(oneShare), vault.convertToAssets(oneShare), "EXIT PRICE ABOVE REALIZED PRICE");
        // burning-side: an impaired exit must cost at least as many shares per asset, never fewer
        if (vault.redemptionTotalAssets() != 0) {
            assertGe(vault.previewWithdraw(1e18), vault.convertToShares(1e18), "IMPAIRED EXIT COSTS FEWER SHARES");
        }
    }

    /// @notice INVARIANT (ADR-0022 §Y): the queue's budget cap, computed at the conservative
    ///         rate, can never authorise a fill worth more than the budget itself.
    /// @dev Guards the §1.3 queue property ("never distributes more than available liquidity")
    ///      against the rounding of the new conservative conversion, at the live vault state.
    function invariant_queueBudgetCapNeverOvershoots() public view {
        uint256 budget = queue.availableLiquidity();
        assertLe(vault.previewRedeem(vault.convertToSharesAtRedemption(budget)), budget, "BUDGET CAP OVERSHOOTS");
    }

    /// @notice INVARIANT (exposure reconciliation): the registry's book equals
    ///         originated-but-pending principal plus funded outstanding principal.
    function invariant_exposure_reconciles() public view {
        assertEq(
            registry.totalBookExposure(),
            handler.ghostPendingPrincipal() + reserves.deployedPrincipal(),
            "EXPOSURE DOES NOT RECONCILE"
        );
        assertEq(reserves.deployedPrincipal(), handler.sumDeployed(), "DEPLOYED != SUM OF FACILITIES");
    }

    /// @notice INVARIANT: the USDC treasury holds no USDfr; curator pools reconcile;
    ///         the engines retain nothing.
    function invariant_reserves_and_pools_reconcile() public view {
        assertEq(usdfr.balanceOf(address(reserves)), 0, "RESERVE RETAINED USDfr");
        assertEq(usdfr.balanceOf(address(curator)), handler.sumCuratorPools(), "CURATOR BALANCE != POOL SUM");
        assertEq(usdfr.balanceOf(address(waterfall)), 0, "WATERFALL RETAINED FUNDS");
        assertEq(usdfr.balanceOf(address(defaultManager)), 0, "DEFAULT MANAGER RETAINED FUNDS");
    }

    /// @notice INVARIANT (supply conservation): every USDfr lives in a tracked hand.
    function invariant_supply_fullyAccounted() public view {
        uint256 tracked = usdfr.balanceOf(address(vault)) + usdfr.balanceOf(address(reserves))
            + usdfr.balanceOf(address(curator)) + usdfr.balanceOf(address(backstopMock)) + usdfr.balanceOf(feeRecipient)
            + handler.sumActorBalances();
        assertEq(usdfr.totalSupply(), tracked, "SUPPLY LEAKED TO UNTRACKED ADDRESS");
    }

    /// @notice INVARIANT (subordination): live exposure is protected — pools may only
    ///         be below requirement through LOSS ABSORPTION, never through withdrawal
    ///         (withdrawals assert per-call in the handler).
    function invariant_curator_subordinationRespected() public view {
        // structural half: headroom math is consistent for both fuzzed classes
        for (uint256 c = 1; c <= 2; ++c) {
            uint256 pool = curator.poolBalance(c);
            uint256 required = curator.requiredFirstLoss(c);
            uint256 free = curator.headroom(c);
            assertEq(free, pool > required ? pool - required : 0, "HEADROOM MATH BROKEN");
        }
    }

    /// @notice Anti-vacuity: the handler must actually be exercising the system.
    /// @dev `ghostFloorDrains` is the PM-R-11 reach telemetry — how many times the campaign
    ///      actually reached the drained-then-refilled coverage state, not merely how many times
    ///      `stressCoverageFloor` was called. Read here so the number is visible in traces rather
    ///      than assumed; see the MEASURED REACH block below for what it measured.
    function invariant_reachTelemetry() public view {
        handler.callCount();
        handler.ghostFloorDrains();
        // AUDIT FIX (H-5) past-due reach telemetry (see the MEASURED REACH block on
        // `invariant_pendingImpairmentNeverUnderMarks`): marks / clears / conversions, the
        // performing-repayment cures (re-audit MEDIUM: full auto-releases + partial re-anchors), and
        // how many facilities are flagged right now. Read here so the numbers surface in traces.
        handler.ghostPastDueMarks();
        handler.ghostPastDueClears();
        handler.ghostPastDueConversions();
        handler.ghostPastDueAutoReleases();
        handler.ghostPastDueReanchors();
        handler.pastDueFlaggedCount();
        // OWNER DECISION 2026-08-07 (G2W) relief-ramp reach: how many observations this run fell
        // INSIDE the ramp versus PAST its expiry. Surfaced here so the split is visible in traces
        // rather than assumed; asserted non-vacuous in `afterInvariant`.
        handler.ghostRampObservedInside();
        handler.ghostRampObservedExpired();
    }

    function afterInvariant() public view {
        assertGt(handler.callCount(), 0, "VACUOUS: credit handler executed no successful action");
        // OWNER DECISION 2026-08-07 (G2W) — PER-RUN ANTI-VACUITY FOR THE RELIEF RAMP.
        // `invariant_pendingImpairmentNeverUnderMarks` now models the RAMPED weight. A model that
        // is never evaluated with a live unattested cohort constrains nothing, and this repository
        // has already shipped two invariants that passed only because their handler never reached
        // the region. So: any run that marked a facility past due must have taken at least one
        // observation with that cohort standing. Deliberately NOT "must observe both halves" —
        // crossing the 21-day expiry needs a warp that a 128-call run is not guaranteed to draw,
        // and a per-run assertion that can fail by luck is worse than no assertion. The CAMPAIGN-
        // level split (both halves non-zero across 256 runs) is measured out-of-band and recorded
        // in the MEASURED REACH block below; re-measure it if the handler's action mix changes.
        if (handler.ghostPastDueMarks() > 0) {
            assertGt(
                handler.ghostRampObservedInside() + handler.ghostRampObservedExpired(),
                0,
                "VACUOUS: marks happened but the relief ramp was never observed with a standing cohort"
            );
        }
    }

    /// @notice INVARIANT (ADR-0022 / PM-R-11): the conservative redemption NAV NEVER under-marks
    ///         senior impairment. Recomputed from first principles, independently of
    ///         `pendingSeniorImpairment`'s own arithmetic.
    /// @dev This exists because the impairment path produced THREE distinct under-marking bugs in
    ///      three consecutive audit rounds — netting a live global capacity against a per-EVENT
    ///      snapshot; then a capacity that a permissionless top-up could re-inflate; then a zero
    ///      floor read as "unset". Each was closed by a targeted regression test, which only ever
    ///      pins the variant already found. This asserts the PROPERTY, so a fourth variant fails
    ///      here rather than shipping. Under-marking is the dangerous direction: it lets a queued
    ///      senior exit above the true floor, pushing loss onto the seniors who stay, which
    ///      inverts the §1.3 cascade ordering the whole ADR-0022 mechanism exists to preserve.
    ///
    ///      MEASURED REACH, stated honestly rather than assumed. Mutation-tested against all three
    ///      known variants at the DEFAULT profile (256 runs x 32,768 calls), each mutation applied
    ///      to a scratch copy of `src/DefaultManager.sol`, each campaign repeated on independent
    ///      seeds. Every seed killed every variant, in the run range noted:
    ///        - variant 1, netting a live global capacity with no deduction  -> CAUGHT (runs 2-6)
    ///        - variant 2, no capacity floor so a top-up re-inflates it      -> CAUGHT (runs 1-6)
    ///        - variant 3, zero floor read as "unset" after a drain+refill   -> CAUGHT (runs 20-56)
    ///      Variant 3 was NOT caught until `CreditHandler.stressCoverageFloor` was added. Random
    ///      action sequencing never reaches a coverage reserve drawn to exactly zero WHILE live
    ///      defaults still hold consumption: that needs every live default snapshotted against the
    ///      standing reserve, the reserve then spent to the last wei with one default holding room
    ///      back, a refill, and that default drawing again. The reach action drives exactly that
    ///      order through the real contracts, under the same per-call cascade differential model as
    ///      every other loss in this suite. Measured reach on the clean build: 26 of 256 default-
    ///      profile runs reach the state (`handler.ghostFloorDrains()`), which is what makes the
    ///      variant-3 kill reproducible rather than lucky.
    ///
    ///      Variant 3 also stays pinned deterministically by
    ///      `test/audit/ExternalFinding2_NavVsEventCap.t.sol::test_pmr11_drainToZeroThenRefillDoesNotReSeedTheFloor`
    ///      -- belt and braces, since a regression test pins the known variant while this pins the
    ///      property. What remains uncovered is honest to state: the reach action needs two
    ///      at-risk defaults that can still take a loss, an empty class first-loss pool, and a
    ///      reserve the book can actually spend back to zero, so states outside that envelope are
    ///      still only covered by the ordinary fuzzed path.
    ///
    ///      AUDIT FIX (H-5) — PAST-DUE POOL, added to BOTH this floor and the over-marks ceiling.
    ///      The reversible past-due pool is a value-moving input to `pendingSeniorImpairment`, and it
    ///      was previously unexercised by this handler. `markPastDue`/`clearPastDue` now drive it;
    ///      `markPastDue` warps past the ~1-year maturity + 21-day grace (no ordinary action jumps
    ///      that far), so it also advances the suite into the post-maturity regime. Measured at the
    ///      default profile: the two actions are invoked ~1,700 / ~1,700 times per campaign with ZERO
    ///      reverts, and per-run reach routinely flags 1-4 facilities with servicer clears and
    ///      declareDefault CONVERSIONS both observed.
    ///
    ///      RE-AUDIT MEDIUM (2026-07-22). `WaterfallEngine.distribute` now calls
    ///      `onPerformingRepayment` on both performing branches, so the handler's `repay` action
    ///      (~1,750 calls/campaign, ZERO reverts) can now cure a past-due facility: a full repayment
    ///      auto-releases the mark, a partial paydown re-anchors it DOWN. `_syncPastDueGhostOnRepay`
    ///      mirrors that into the ghost set (like `_syncPastDueGhostOnDeclare` mirrors the conversion),
    ///      so the ghost never goes stale and BOTH the floor (live `deployedTo`) and the ceiling
    ///      (re-anchored snapshot) keep matching the contract's honest term.
    ///
    ///      Mutation-tested, each on a scratch copy of the mutated src file, caches cleared, then
    ///      restored byte-identical (verified by sha256):
    ///        - drop the `pastDuePrincipal` fold in `pendingSeniorImpairment` -> THIS invariant RED
    ///          (runs 10, calls 1,280): contract marks 0 where the honest floor is the past-due
    ///          principal.
    ///        - make `_releasePastDue` a no-op (a converted/cleared facility double-counts across the
    ///          past-due and declared pools) -> `invariant_pendingImpairmentNeverOverMarks` RED
    ///          (runs 4, calls 512).
    ///        - neuter `onPerformingRepayment` (a performing repayment no longer re-anchors/releases
    ///          the past-due mark, so a bystander-marked facility that then cures keeps the stale
    ///          over-mark) -> `invariant_pendingImpairmentNeverOverMarks` RED (runs 137, calls 17,536;
    ///          shrunk to originate -> originate -> fund -> markPastDue -> repay).
    ///      Both terms are recomputed INDEPENDENTLY of `DefaultManager.pastDuePrincipal`: the floor
    ///      sums CURRENT `reserves.deployedTo` over the handler's own ghost flagged set (== the
    ///      contract's re-anchored term, always a valid LOWER bound -> a valid floor), while the
    ///      ceiling sums the handler's own snapshot, re-anchored DOWN in lockstep on each performing
    ///      repay (an upper bound tracking the contract's honest term -> a valid ceiling). The one
    ///      ADR-0035 gives every wired event the same live-reserve room. The model still bounds
    ///      each row by its own principal, then clamps the cohort once by the reserve actually
    ///      held so multiple events cannot double-count capital.
    ///      OWNER DECISION 2026-08-07 (G2W) — THE HONEST FLOOR FOR THE UNATTESTED COHORT MOVED,
    ///      THE INVARIANT'S STATEMENT DID NOT. This invariant says "the reported impairment is
    ///      never below the honest conservative floor". What changed is the definition of the
    ///      honest floor for the PAST-DUE cohort, and it changed because Forest Road decided that
    ///      an unattested, permissionless mark must not carry the same forward weight as an
    ///      attested declared default. The floor is therefore recomputed here in the same two
    ///      steps the contract uses, from INDEPENDENT inputs:
    ///        - the past-due cohort's own post-junior residual, from the handler's ghost set and
    ///          live `reserves.deployedTo` (never from `DefaultManager.pastDuePrincipal`);
    ///        - clamped to the senior absorption capacity `realizeLoss` could actually reach today
    ///          (`sUSDfr.totalAssets()`, read from the VAULT, less the attested cohort's prior
    ///          claim — the attested cohort can call `realizeLoss` this block, the past-due cohort
    ///          structurally cannot);
    ///        - then multiplied by the governed weight, rounding DOWN where the contract rounds UP,
    ///          so the recomputed value stays a strict LOWER bound and cannot false-fail.
    ///
    ///      THE ATTESTED HALF IS UNTOUCHED — it is neither clamped nor weighted nor ramped, here or
    ///      in the contract, so a genuine near-total senior loss on the attested path still has to
    ///      clear the full, unmodified floor.
    ///
    ///      MEASURED RAMP REACH, DEFAULT PROFILE (256 runs x depth 128), clean build, counted by
    ///      writing `afterInvariant` telemetry to a file and aggregating ACROSS runs — an in-memory
    ///      counter cannot do this, because invariant state reverts between runs and would only
    ///      ever show the last one:
    ///        - 85 of 256 runs marked at least one facility past due;
    ///        - all 85 of those took at least one observation INSIDE the relief ramp;
    ///        - 39 of 256 runs took at least one observation PAST its expiry (93 observations).
    ///      Without `CreditHandler.expireReliefRamp` the expired half was reached in only 11 of 256
    ///      runs (20 observations) — reachable by luck, not by coverage. That is why the reach
    ///      action exists; re-measure both numbers if the action mix changes.
    ///
    ///      THE BOUND IS PROVED, NOT ASSUMED. Write `D` for the attested senior residual, `P` for
    ///      the past-due one, `V` for vault assets and `w` for the weight. The model's junior
    ///      credit is deliberately the MOST generous honest figure, so `D_model <= D_contract` and
    ///      `P_model <= P_contract`. Then
    ///      `D_model + w*min(P_model, V - D_model) <= D_contract + w*min(P_contract, V - D_contract)`
    ///      in every case: if `V <= D_contract` the model is at most `(1-w)D_model + wV <= D_contract`;
    ///      if neither side clamps it is termwise; if the contract clamps the model is at most
    ///      `(1-w)D_model + wV <= (1-w)D_contract + wV`; and if only the model clamps then
    ///      `P_contract >= P_model > V - D_model` makes the contract strictly larger. So the
    ///      assertion remains one-sided in the safe direction.
    function invariant_pendingImpairmentNeverUnderMarks() public view {
        // Layer 1, exactly as the contract does it: per-class curator first-loss.
        uint256 residual;
        for (uint256 classId = 1; classId <= 5; ++classId) {
            // AUDIT FIX (H-5): `pendingSeniorImpairment` folds the REVERSIBLE past-due pool into `d`
            // alongside the declared pool BEFORE the curator netting, so the floor must too - else it
            // is understated and the invariant is vacuously satisfied against a broken fold. The
            // past-due term is recomputed INDEPENDENTLY of `DefaultManager.pastDuePrincipal`: the
            // handler iterates its OWN ghost set of flagged ids and sums CURRENT `reserves.deployedTo`.
            // Since the re-audit MEDIUM fix, the contract re-anchors `pastDuePrincipal` DOWN to exactly
            // `deployedTo` on every performing repayment (`onPerformingRepayment`), so this sum EQUALS
            // the contract's honest past-due term while flagged - and it is a valid LOWER bound in
            // every case (`deployedTo` never rises after a mark), so the recomputed floor can never
            // exceed the contract's `d` and false-fail.
            uint256 d = defaultManager.declaredDefaultedPrincipal(classId) + handler.pastDuePrincipalByClass(classId);
            if (d == 0) continue;
            uint256 pool = curator.poolBalance(classId);
            if (d > pool) residual += d - pool;
        }
        if (residual == 0) return;

        // Layer 2, the TRUE reachable coverage: per-event room, summed over the live declared
        // defaults, then bounded by what the backstop actually holds. This is deliberately the
        // MOST GENEROUS honest figure for the junior layer, which makes the resulting floor the
        // LOWEST honest floor — so asserting the contract is at or above it is the strict test.
        uint256 room;
        // OWNER DECISION 2026-08-07 (G2W): an INDEPENDENT UPPER bound on the contract's past-due
        // senior residual, from the handler's own snapshot ghost (the same ghost the over-marks
        // ceiling uses, re-anchored DOWN in lockstep on every performing repay). It must be an
        // UPPER bound, not a lower one: the model attributes as much of the recomputed floor as
        // possible to the DISCOUNTED cohort, which is what makes the resulting floor the LOWEST
        // honest floor and therefore the strict test. Accumulated for EVERY flagged facility
        // regardless of live `deployedTo`, so a mark the contract still holds against a
        // written-down facility cannot fall out of the bound.
        uint256 pastDueCeiling;
        uint256 held = usdfr.balanceOf(address(backstopMock));
        uint256 n = handler.facilitiesLength();
        for (uint256 i = 0; i < n; ++i) {
            uint256 id = handler.facilities(i);
            if (handler.isPastDueFacility(id)) pastDueCeiling += handler.pastDueSnapshotOf(id);
            uint256 candidateRoom;
            uint256 eventPrincipal;
            if (handler.isDefaultedFacility(id)) {
                eventPrincipal = defaultManager.defaultedContribution(id);
                if (eventPrincipal == 0) continue;
                candidateRoom = handler.backstopRoomFor(id);
            } else if (handler.isPastDueFacility(id) && reserves.deployedTo(id) != 0) {
                // A past-due facility has not drawn, but if it proceeds to default it reaches the
                // same shared reserve as every declared event.
                eventPrincipal = reserves.deployedTo(id);
                candidateRoom = backstopMock.coverageCapacity();
            } else {
                continue;
            }
            // F1: a room is deliverable only against THIS event's remaining principal.  The
            // shared reserve is clamped after summing these per-event deliverables; using the
            // pooled principal here would recreate the exact over-credit the SGrove acceptance
            // test exposes.
            if (candidateRoom > eventPrincipal) candidateRoom = eventPrincipal;
            // Saturating rather than breaking: `room` still stops at what the backstop actually
            // holds, but the loop must run to completion so `pastDueCeiling` is total.
            if (room < held) room = candidateRoom >= held - room ? held : room + candidateRoom;
        }

        uint256 trueFloor = residual > room ? residual - room : 0;

        // ── OWNER DECISION 2026-08-07 (G2W) ───────────────────────────────
        // Split the recomputed floor into the ATTESTED cohort (full weight, never clamped, never
        // weighted) and the UNATTESTED past-due cohort. Attribute the MAXIMUM defensible amount to
        // the discounted cohort: with `w < 1` the reported figure falls as the past-due share
        // rises, so this yields the lowest honest floor and keeps the assertion strict.
        uint256 pastDueSenior = pastDueCeiling < trueFloor ? pastDueCeiling : trueFloor;
        if (pastDueSenior != 0) {
            uint256 declaredSenior = trueFloor - pastDueSenior;
            // The EXECUTABLE bound, recomputed from the VAULT rather than from DefaultManager:
            // `realizeLoss` reverts once the senior slice exceeds `totalAssets()`, and the
            // attested cohort — which can call it this block — has first claim on that capacity.
            uint256 executable = vault.totalAssets();
            executable = executable > declaredSenior ? executable - declaredSenior : 0;
            if (pastDueSenior > executable) pastDueSenior = executable;
            // Governed weight, RAMPED. Reading the parameter is reading GOVERNANCE state, and the
            // anchor is read from the handler's mirror of the contract's GROSS emptiness test --
            // neither is the impairment arithmetic this invariant is checking, so the model stays
            // independent of the thing under test. The ramp itself is recomputed here from `Config`
            // constants and is NOT read from `registry.pastDueRampWeightBps`: routing it through
            // the contract's own view would move the floor in lockstep with any mutation of the
            // ramp and the mutation would survive.
            //
            // WHY THE RAMP HAD TO BE MODELLED AT ALL. Before this, the model used the FLOOR weight
            // `pastDueWeightBps()`, which is a valid lower bound at every elapsed -- and therefore
            // passed without ever constraining the ramp. An invariant that cannot fail in the
            // region it claims to cover is worth nothing; with `w(t)` modelled, any mutation that
            // makes the contract's weight LOWER than the honest ramp (dropping the interpolation,
            // shortening the elapsed, interpolating towards the floor instead of towards `BPS`)
            // now drives the contract below this floor and reddens here.
            //
            // STILL ONE-SIDED. It rounds DOWN where the contract rounds UP, so the recomputed value
            // remains a strict LOWER bound and cannot false-fail on rounding.
            uint256 w = registry.pastDueWeightBps();
            uint256 elapsed = block.timestamp - handler.ghostReliefAnchor();
            if (elapsed >= Config.DEFAULT_REDEEM_COOLDOWN) {
                w = Config.BPS;
            } else {
                w += ((Config.BPS - w) * elapsed) / Config.DEFAULT_REDEEM_COOLDOWN;
            }
            trueFloor = declaredSenior + (pastDueSenior * w) / Config.BPS;
        }

        assertGe(
            defaultManager.pendingSeniorImpairment(),
            trueFloor,
            "NAV UNDER-MARKS SENIOR IMPAIRMENT (exits above the conservative floor)"
        );
    }

    /// @notice INVARIANT (ADR-0022 §Y.2, mirror image): the reported impairment never exceeds the
    ///         principal that is still genuinely AT RISK across the declared defaults.
    /// @dev AUDIT FIX (H-2). `invariant_pendingImpairmentNeverUnderMarks` is one-sided
    ///      (`assertGe`) AND draws its per-facility term from the contract's own
    ///      `defaultedContribution`, so a bug that inflates that contribution is invisible to it
    ///      twice over. That is precisely what H-2 was: `defaultedContribution` was snapshotted at
    ///      declare and reduced only by a realized loss or a clean resolve, while a partial cash
    ///      RECOVERY on a defaulted facility reduced `deployedTo` silently. Recover, then write off
    ///      the remainder, and the facility sat at `deployedTo == 0` with a contribution equal to
    ///      the recovered cash, in a state from which `Resolved` was unreachable — a permanent
    ///      haircut on every senior exit, and a permanently pinned `liveDefaultCoverageConsumed`
    ///      that under-netted the backstop for every later default.
    ///
    ///      THE MODEL IS INDEPENDENT OF THE CONTRACT. The ceiling for a defaulted facility is
    ///      exactly `reserves.deployedTo(id)` — the largest loss it can still realize, since
    ///      `realizeLoss` reverts above it — read from a different contract and never from
    ///      `defaultedContribution`. Junior netting (curator, then sGROVE) can only lower the
    ///      reported figure, so the sum of ceilings is a valid upper bound with or without it.
    ///
    ///      NO SLACK TERM. The wave-1 fix carried a `ghostUnsyncedRecovery` addend here to
    ///      tolerate a recovery the manager had not been told about; that addend was a standing
    ///      licence for exactly the residual over-mark H-2 is about, and it made this invariant
    ///      structurally incapable of catching a regression in that window. The remediation
    ///      closed the window at source (`WaterfallEngine.distribute` -> `onDefaultRecovery`), so
    ///      the ceiling is now the register-specified one and the ghost is gone.
    ///
    ///      OVER-MARKING IS NOT SAFE. An over-mark that nothing on-chain can clear is not
    ///      conservatism: measured pre-remediation, four ordinary partial workouts drove
    ///      `redemptionTotalAssets()` to zero against a solvent vault, destroying a redeemer's
    ///      exit entirely. It is a stuck haircut on principal that came back in cash, taken from
    ///      holders who did nothing wrong (register item L-1).
    function invariant_pendingImpairmentNeverOverMarks() public view {
        uint256 ceiling;
        uint256 n = handler.facilitiesLength();
        for (uint256 i = 0; i < n; ++i) {
            uint256 id = handler.facilities(i);
            if (handler.isDefaultedFacility(id)) {
                // declared pool: the largest loss a defaulted facility can still realize
                ceiling += reserves.deployedTo(id);
            } else if (handler.isPastDueFacility(id)) {
                // AUDIT FIX (H-5): a past-due facility is Active, so it is NOT in the defaulted set,
                // yet `pendingSeniorImpairment` folds its at-risk principal into the mark. Add it, or
                // the ceiling false-fails the moment the handler marks anything.
                //
                // RE-AUDIT MEDIUM (2026-07-22): `WaterfallEngine.distribute` now calls
                // `onPerformingRepayment` on both performing branches, which re-anchors the contract's
                // `pastDueContribution` DOWN to live `deployedTo` on a partial paydown and clears it on
                // a full repayment. The handler mirrors that re-anchor into `_pastDueSnapshot` via
                // `_syncPastDueGhostOnRepay` (INDEPENDENTLY: it reads ReserveManager and its own ghost,
                // never `DefaultManager.pastDueContribution`), so `pastDueSnapshotOf(id)` tracks the
                // contract's honest contribution term-for-term while the facility stays flagged - a
                // tight, valid UPPER bound. Because the ghost models the INTENDED cure, a mutation that
                // neuters `onPerformingRepayment` leaves the contract marking the stale (higher)
                // snapshot while this ceiling re-anchors DOWN, so the assert below goes RED - which is
                // exactly how this invariant pins the fix. A facility CONVERTED to a declared default
                // has already left this ghost set (mirrors `_releasePastDue`), so the two pools never
                // double-count in the sum.
                ceiling += handler.pastDueSnapshotOf(id);
            }
        }
        assertLe(
            defaultManager.pendingSeniorImpairment(),
            ceiling,
            "NAV OVER-MARKS SENIOR IMPAIRMENT (impairment stranded above live at-risk principal)"
        );
    }
}
