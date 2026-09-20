// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ATK_AssessedImpairmentForkBase} from "./ATK_AssessedImpairmentFork.t.sol";
import {AssessedImpairmentSource} from "../../src/AssessedImpairmentSource.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAccrualLifecycle} from "../../src/interfaces/IAccrualLifecycle.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {IRevisionedImpairmentSource} from "../../src/interfaces/IRevisionedImpairmentSource.sol";
import {Config} from "../../src/libraries/Config.sol";
import {PreviousAssessmentSource} from "../helpers/PreviousAssessmentSource.sol";

/// @title ATK_AssessmentRatchetFork, round four: attacks on the 4407d60 assessment ratchet
///        against the FULL protocol on the pinned mainnet fork with REAL USDC.
///
/// @notice Commit 4407d60 keeps an ADR-0027 recovery assessment alive while an undeclared
///         past-due cohort accrues: the wrapper snapshots (riskHash, pastDueExposure, capacity)
///         at publication and, while the identity is unchanged and neither capacity nor exposure
///         has fallen, returns `min(base, A0 + (E - E0))` for redemption and `F0 + (E - E0)` for
///         the performance-fee base. The refuters of round three warned that a surviving
///         assessment with a FLAT mark would let the delinquent facility's full-face accrual flow
///         into the senior exit price (+2,449,991,833,353,381,274,969 over a week under mutation
///         MA). This file attacks the ratchet that replaces the flat mark.
///
///         Invariants under attack (CLAUDE.md 1.3):
///           I1. Exit pricing must never be paid above the cascade-ordered conservative NAV, and
///               yield alone (the clock) must not raise a senior exit quote while an assessment
///               stands against a delinquent cohort.
///           I2. sUSDfr fee-net rate integrity: reserved income is not performance-bearing.
///           I3. Access control: no permissionless act voids a governance assessment without an
///               economic event.
///
///         Attacks (each ends in an unambiguous assertion; blocked attacks assert the exact
///         numbers, a successful one would assert the leaked money):
///           R1. THE LEAK. alice's queued-exit quote and the conservative NAV at +1 s, +1 day,
///               +7 days and +29 days with no state change, against the base quote at the same
///               instants; then the real queue settlement at +29 days.
///           R2. SELF-NEUTRALISATION. The instant `A0 + increase` reaches the base, for a small
///               and a large assessed loss, on the fixture book; whether the TTL comes first.
///           R3. EXPOSURE SEMANTICS. Whether a class-B cohort's accrual raises a class-A
///               assessment's mark, and what that costs the lever.
///           R4. THE DOWN DIRECTION. Cure, partial loss, coupon, PIK, and carol's whole
///               permissionless surface: which invalidate, which do not, none by carol alone.
///           R5. FEE ACCOUNTING. The fee mark moves by exactly the senior increase, `accrueFees`
///               crystallises nothing on it, and the cap on the two paths is consistent.
///           R6. THE UPGRADE SEAM. A pre-field memorandum, the actual previous implementation,
///               a wrong-length base, and a live base that loses the tuple.
contract ATK_AssessmentRatchetForkTest is ATK_AssessedImpairmentForkBase {
    uint256 internal constant RENEWABLES = Config.CLASS_RENEWABLE_ENERGY; // 2
    bytes32 internal constant ASSESSMENT_SLOT = 0x22d1327051d3790a2a295641453e9e7c93d6a209be7b99c1b2a8eee179860200;
    uint256 internal constant FLAG_OFFSET = 11; // accrualStateSnapshotted, per Fix_RC06 layout pin
    uint256 internal constant TTL = 30 days;

    /// @dev The marked book: A declared, B marked past due, alice queued or holding.
    struct Book {
        uint256 idA;
        uint256 idB;
        uint256 sharesA;
        uint256 t0; // the publication instant
        uint256 base0; // conservative base at publication
        uint256 e0; // pastDueExposure at publication
        uint256 fee0; // wrapper performance-fee mark at publication
        uint256 assessed; // A0
    }

    /// @dev One instant's complete reading.
    struct Probe {
        uint256 exposure;
        uint256 increase;
        uint256 mark;
        uint256 fee;
        uint256 base;
        uint256 baseFee;
        uint256 totalAssets;
        uint256 redemptionAssets;
        uint256 quote;
        uint256 baseQuote;
        uint256 rate;
        uint256 feeRate;
        bool active;
        bytes32 riskHash;
        uint256 capacity;
    }

    // ─────────────────────────────────────────────────────────────────────
    // R1 (I1): the leak the refuters warned about
    // ─────────────────────────────────────────────────────────────────────

    /// @notice With A declared and B marked (the only accruing loan), a 100,000e18 assessment is
    ///         published in the mark block. At +1 s, +1 day, +7 days and +29 days with no
    ///         state-changing call, alice's exit quote and the conservative NAV never rise; the
    ///         mark rises by the cohort's GROSS accrual while the NAV rises by the NET (90%), so
    ///         the quote falls by the protocol-fee share of the delinquent income. The assessment
    ///         still prices above the base at every instant and the queue pays no more at +29 days
    ///         than the publication quote.
    /// @dev Attacks I1. Mutation M1 (drop `+ increase` from `pendingSeniorImpairment`) reopens the
    ///      refuters' leak: the quote rises on the clock alone.
    function test_atk_ratchet_theClockNeverRaisesTheAssessedExitQuote() public onFork {
        Book memory b = _markedBook(FILM, 100_000e18);
        Probe memory p0 = _probe(b);
        assertTrue(p0.active, "published in the mark block");
        assertEq(p0.mark, 100_000e18, "assessed at publication");
        assertGt(p0.quote, p0.baseQuote, "the assessment lifts the exit above the base");
        emit log_named_uint("R1 base at publication", p0.base);
        emit log_named_uint("R1 assessed quote at publication (alice)", p0.quote);
        emit log_named_uint("R1 base quote at publication (alice)", p0.baseQuote);
        // alice queues her whole stake at the assessed quote; the real settlement comes at +29 d.
        vm.startPrank(alice);
        vault.approve(address(queue), b.sharesA);
        uint256 req = queue.requestRedeem(b.sharesA);
        vm.stopPrank();

        uint256[4] memory offsets = [uint256(1), 1 days, 7 days, 29 days];
        Probe memory prev = p0;
        for (uint256 i = 0; i < 4; ++i) {
            vm.warp(b.t0 + offsets[i]);
            vm.roll(block.number + 1);
            _freshen();
            Probe memory p = _probe(b);
            _assertNoLeakAt(b, p0, prev, p, offsets[i]);
            prev = p;
        }
        _settleAtTwentyNineDays(b, p0, prev, req);
    }

    function _assertNoLeakAt(Book memory b, Probe memory p0, Probe memory prev, Probe memory p, uint256 offset)
        internal
    {
        emit log_named_uint("R1 offset (s)", offset);
        emit log_named_uint("R1 cohort increase since publication", p.increase);
        emit log_named_uint("R1 wrapper mark", p.mark);
        emit log_named_uint("R1 conservative base", p.base);
        emit log_named_uint("R1 assessed quote (alice)", p.quote);
        emit log_named_uint("R1 base quote (alice)", p.baseQuote);
        // I1 first: the redemption asset base and alice's quote never rise on the clock alone.
        assertLe(p.quote, prev.quote, "LEAK: alice's exit quote rose on the clock");
        assertLe(p.redemptionAssets, prev.redemptionAssets, "LEAK: the conservative asset base rose on the clock");
        assertLe(p.quote, p0.quote, "LEAK: alice's exit quote is above the publication quote");
        assertTrue(p.active, "the clock alone does not void the assessment");
        assertGt(p.increase, prev.increase, "the marked cohort accrued");
        assertEq(p.riskHash, p0.riskHash, "the risk identity is clock-stable");
        assertEq(p.capacity, p0.capacity, "capacity is clock-stable");
        assertLt(p.mark, p.base, "the assessment still has effect (below the base)");
        assertEq(p.mark, b.assessed + p.increase, "the mark is the assessment plus the GROSS cohort increase");
        assertEq(p.fee, b.fee0 + p.increase, "the fee mark carries the same increase");
        // The NAV grew by the NET accrual (the 10% protocol interest fee is not the vault's).
        uint256 navGrowth = p.totalAssets - p0.totalAssets;
        assertLt(navGrowth, p.increase, "the vault receives less than the gross cohort accrual");
        assertApproxEqAbs(navGrowth, p.increase * 9 / 10, 2, "the vault's share is 90% of the gross cohort accrual");
        assertEq(p0.redemptionAssets - p.redemptionAssets, p.increase - navGrowth, "the base fell by the fee share");
        assertGt(p.quote, p.baseQuote, "still above the base quote at this instant");
        assertGt(p.rate, prev.rate, "the realized exchange rate (1.3 subject) keeps tracking value");
        assertLe(p.feeRate, prev.feeRate, "the fee-net rate does not rise on reserved income");
    }

    /// @dev The request is 29 days old (cooldown 21 days, heartbeat 1 day): settle it for real.
    function _settleAtTwentyNineDays(Book memory b, Probe memory p0, Probe memory p29, uint256 req) internal {
        queue.setEpochLiquidityBps(10_000); // ops: the whole idle reserve may settle (as A3)
        _warpToSettleable();
        assertEq(block.timestamp, b.t0 + 29 days, "settleable at +29 days without further warp");
        uint256 quoteNow = vault.previewRedeem(b.sharesA);
        assertEq(quoteNow, p29.quote, "the settlement quote is the +29 d quote");
        queue.closeEpoch(10);
        (, uint256 rem, uint256 claimable,,) = queue.request(req);
        assertEq(rem, 0, "filled in full");
        assertEq(claimable, quoteNow, "paid exactly the quote in force at settlement");
        assertLe(claimable, p0.quote, "paid no more than the publication quote: the leak is closed");
        assertGt(claimable, p29.baseQuote, "paid more than the base: the assessment still priced");
        emit log_named_uint("R1 alice paid at +29 d", claimable);
        emit log_named_uint("R1 publication quote minus paid", p0.quote - claimable);
        emit log_named_uint("R1 paid minus base quote at +29 d", claimable - p29.baseQuote);
    }

    // ─────────────────────────────────────────────────────────────────────
    // R2: self-neutralisation on the fixture book
    // ─────────────────────────────────────────────────────────────────────

    /// @notice On the fixture book (A declared, B marked in the same class, past-due residual
    ///         positive) the ratchet NEVER neutralises: during the 21-day relief ramp the base
    ///         rises faster than the assessed mark (the gap widens), after the ramp both rise by
    ///         the same gross accrual (the gap is constant to the wei), so the 30-day TTL comes
    ///         first for both a small (100,000e18) and a large (base minus 1,000e18) assessed loss.
    /// @dev Mutation M2 (`assessmentState` returns the recorded exposure without the accrued
    ///      cohort) makes the post-ramp gap grow instead of holding, which this test rejects.
    function test_atk_ratchet_neutralisationNeverPrecedesTheTtlOnTheFixtureBook() public onFork {
        Book memory b = _markedBook(FILM, 100_000e18);
        uint256 before = vm.snapshotState();
        _gapNeverClosesBeforeTtl(b, "small loss");
        assertTrue(vm.revertToState(before), "revert to the mark block");
        vm.warp(b.t0);
        // Republish the large loss in the same block (identity unchanged, no accrual yet).
        _republish(b, b.base0 - 1_000e18);
        _gapNeverClosesBeforeTtl(b, "large loss");
    }

    function _gapNeverClosesBeforeTtl(Book memory b, string memory label) internal {
        uint256[7] memory offsets = [uint256(1), 1 days, 7 days, 21 days - 1, 22 days, 29 days, 30 days];
        uint256 gap0 = b.base0 - b.assessed;
        uint256 gapAt22;
        uint256 rampEnd = defaultManager.pastDueReliefAnchor() + Config.DEFAULT_REDEEM_COOLDOWN;
        assertEq(rampEnd, b.t0 + 21 days, "the relief anchor is the mark block: the ramp ends at +21 d");
        emit log_string(label);
        emit log_named_uint("R2 gap at publication (base - assessed)", gap0);
        for (uint256 i = 0; i < 7; ++i) {
            vm.warp(b.t0 + offsets[i]);
            _freshen();
            Probe memory p = _probe(b);
            assertTrue(p.active, "alive inside the TTL");
            assertEq(p.mark, b.assessed + p.increase, "uncapped: the assessment plus the gross increase");
            uint256 gap = p.base - p.mark;
            emit log_named_uint("R2 offset (s)", offsets[i]);
            emit log_named_uint("R2 gap (base - mark)", gap);
            assertGt(gap, 0, "NEUTRALISED before the TTL");
            // The ramp weight moves one basis point every 362.88 s; inside the first step the
            // ratchet leads by the unweighted half of one second's accrual, then the ramp wins.
            if (offsets[i] == 1) {
                assertLt(gap, gap0, "one second: the ratchet leads the still-flat ramp weight");
                assertLt(gap0 - gap, 1e16, "by under 1e16 wei (half of one second's accrual)");
            }
            if (offsets[i] >= 1 days && offsets[i] < 21 days) assertGt(gap, gap0, "the ramp outruns the ratchet");
            if (offsets[i] == 22 days) gapAt22 = gap;
            if (offsets[i] > 22 days) assertEq(gap, gapAt22, "after the ramp the gap is constant to the wei");
        }
        vm.warp(b.t0 + TTL + 1);
        assertFalse(_active(), "the TTL, not neutralisation, ends the assessment");
        assertEq(_assessed().pendingSeniorImpairment(), defaultManager.pendingSeniorImpairment(), "base after expiry");
    }

    // ─────────────────────────────────────────────────────────────────────
    // R3: exposure semantics
    // ─────────────────────────────────────────────────────────────────────

    /// @notice `impairmentAssessmentState().exposure` is the WHOLE book's marked cohort, every
    ///         class. B (Renewables, 1,000,000e18) is marked while a 2,000,000e18 Renewables
    ///         curator pool absorbs it entirely at the base: the mark does not move the base but
    ///         still kills the FILM assessment (identity). After republication B's accrual raises
    ///         the assessed mark at 100% while the base charges seniors 0% of it; that is
    ///         over-reservation, and it neutralises a large assessed loss (base minus 1,000e18)
    ///         in about 2.6 days, well inside the TTL.
    /// @dev Mutation M3 (`pastDueExposure` counting FILM only) hides B's accrual from the ratchet.
    function test_atk_ratchet_exposureIsTheWholeBookSoAnotherClassesAccrualRaisesTheMark() public onFork {
        Book memory b = _markedBook(RENEWABLES, 100_000e18);
        assertEq(b.base0, 350_000e18, "B's marked cohort is absorbed by its own class pool: the base is A's alone");
        Probe memory p0 = _probe(b);
        (bytes32 risk, uint256 exposure, uint256 capacity) = defaultManager.impairmentAssessmentState();
        assertEq(exposure, defaultManager.pastDueExposure(), "the tuple's exposure is the global cohort");
        assertEq(
            exposure, reserves.deployedTo(b.idB) + reserves.accruedPastDue(RENEWABLES), "recorded B face plus unposted"
        );
        assertEq(reserves.accruedPastDue(FILM), 0, "nothing marked in FILM");
        assertEq(risk, p0.riskHash);
        assertEq(capacity, 500_000e18, "the shared reserve");

        uint256 s = vm.snapshotState();
        vm.warp(b.t0 + 7 days);
        _freshen();
        Probe memory p7 = _probe(b);
        assertTrue(p7.active, "alive");
        assertEq(p7.base, 350_000e18, "the base is FLAT: the Renewables pool absorbs B's accrual");
        assertEq(p7.mark, 100_000e18 + p7.increase, "the FILM assessment carries B's Renewables accrual at 100%");
        assertEq(p7.increase, reserves.accruedPastDue(RENEWABLES), "the increase is exactly B's unposted accrual");
        assertGt(p7.increase, 2_700e18, "about 388.9e18 per day for a week");
        emit log_named_uint("R3 B's accrual in a week (reserved at 100% by the assessment)", p7.increase);
        emit log_named_uint("R3 base charge to seniors for the same accrual", p7.base - p0.base);
        emit log_named_uint("R3 assessed quote at publication", p0.quote);
        emit log_named_uint("R3 assessed quote a week later", p7.quote);
        emit log_named_uint("R3 base quote at publication", p0.baseQuote);
        emit log_named_uint("R3 base quote a week later", p7.baseQuote);
        assertLt(p7.quote, p0.quote, "the assessed quote fell by the fee share");
        assertGt(p7.baseQuote, p0.baseQuote, "the base quote ROSE: at the base B's income reaches seniors");
        assertGt(p7.quote, p7.baseQuote, "still above the base");
        assertTrue(vm.revertToState(s), "back to the mark block");
        vm.warp(b.t0);
        _aLargeLossNeutralisesInsideTheTtl(b);
    }

    /// @dev Republish at base minus 1,000e18. The gap closes at 1,000e18 / rate: measured.
    function _aLargeLossNeutralisesInsideTheTtl(Book memory b) internal {
        // Same block as the mark: identity and exposure unchanged, so republication is a clean read.
        _republish(b, b.base0 - 1_000e18);
        vm.warp(b.t0 + 1);
        uint256 ratePerSecond = defaultManager.pastDueExposure() - b.e0;
        assertGt(ratePerSecond, 0, "B accrues every second");
        uint256 tStar = (1_000e18 + ratePerSecond - 1) / ratePerSecond;
        emit log_named_uint("R3 cohort rate (wei/s)", ratePerSecond);
        emit log_named_uint("R3 neutralisation instant (s after publication)", tStar);
        assertLt(tStar, TTL, "neutralisation precedes the TTL in this configuration");
        assertGt(tStar, 2 days, "about 2.57 days at 1,000,000e18 and 14%");
        vm.warp(b.t0 + tStar - 1 hours);
        _freshen();
        Probe memory pBefore = _probe(b);
        assertTrue(pBefore.active);
        assertLt(pBefore.mark, pBefore.base, "an hour before: still below the base");
        vm.warp(b.t0 + tStar + 1 hours);
        _freshen();
        Probe memory pAfter = _probe(b);
        assertTrue(pAfter.active, "identity unchanged: still 'active'");
        assertEq(pAfter.mark, pAfter.base, "but capped at the base: the assessment has no senior effect");
        assertEq(pAfter.quote, pAfter.baseQuote, "alice is quoted the base");
        assertEq(pAfter.fee, b.fee0 + pAfter.increase, "the fee mark keeps ratcheting, uncapped");
        emit log_named_uint("R3 mark an hour after neutralisation", pAfter.mark);
        emit log_named_uint("R3 uncapped A0 + increase", b.assessed + pAfter.increase);
    }

    // ─────────────────────────────────────────────────────────────────────
    // R4 (I3): the down direction and carol's whole surface
    // ─────────────────────────────────────────────────────────────────────

    /// @notice On the FILM book plus a matured, marked PIK note P: every permissionless call
    ///         carol can make in the publication block (checkpoint, post, service, materialize,
    ///         accrueFees, a second mark, a mark on A, a mark on P) leaves identity, exposure,
    ///         capacity and both marks untouched. A cure (servicer), a partial realized loss on A,
    ///         and a coupon on B each invalidate: cure and coupon lower exposure AND advance the
    ///         revision, the partial loss leaves exposure alone and moves the pool. A cure and
    ///         re-mark in one block restores the identical exposure and pools and is still
    ///         refused (revision). P, marked after maturity, cannot capitalise: its exposure is
    ///         constant and only B's accrual feeds the ratchet.
    /// @dev Mutation M4 (drop `impairmentRevision` from the identity) lets the same-face cure and
    ///      re-mark revive the memorandum.
    function test_atk_ratchet_onlyEconomicEventsInvalidateAndNoneOfThemIsCarols() public onFork {
        Book memory b = _markedBookWithMaturedPik(100_000e18);
        Probe memory p0 = _probe(b);
        uint256 s = vm.snapshotState();
        _carolsSurfaceChangesNothing(b, p0);
        _back(s, b);
        _cureAndRemarkAtTheSameFace(b, p0);
        _back(s, b);
        _partialLossOnAInvalidatesWithoutTouchingExposure(b, p0);
        _back(s, b);
        _couponOnBInvalidatesAndLowersExposure(b, p0);
        _back(s, b);
        _theMaturedPikCannotCapitalise(b, p0);
    }

    function _carolsSurfaceChangesNothing(Book memory b, Probe memory p0) internal {
        vm.startPrank(carol);
        reserves.checkpointAccrual(32);
        reserves.postAccruedLoan(b.idB);
        assertEq(reserves.serviceAccruedLoan(b.idB), 0, "a cash note has nothing to capitalise");
        (uint256 senior,) = reserves.materializeAccrued(1);
        assertGt(senior, 0, "carol delivered the vault's accrued senior claim");
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_AlreadyPastDue.selector, b.idB));
        defaultManager.markPastDue(b.idB);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotDefaultable.selector, b.idA));
        defaultManager.markPastDue(b.idA);
        vm.stopPrank();
        vm.prank(carol);
        vault.accrueFees();
        Probe memory p = _probe(b);
        assertEq(p.riskHash, p0.riskHash, "identity untouched by carol");
        assertEq(p.exposure, p0.exposure, "exposure untouched by carol (posting is neutral)");
        assertEq(p.capacity, p0.capacity, "capacity untouched by carol");
        assertTrue(p.active, "carol cannot void a governance assessment");
        assertEq(p.mark, p0.mark, "mark untouched");
        assertEq(p.fee, p0.fee, "fee mark untouched");
    }

    function _cureAndRemarkAtTheSameFace(Book memory b, Probe memory p0) internal {
        uint256 revision = defaultManager.impairmentRevision();
        bytes32 evidence = keccak256("r4-cure-b");
        _attest(b.idB, IAttestationOracle.AttestationKind.PastDueCured, keccak256(abi.encode(b.idB, evidence)));
        vm.prank(ops);
        defaultManager.clearPastDue(b.idB, evidence);
        Probe memory cured = _probe(b);
        assertLt(cured.exposure, p0.exposure, "the cure lowered exposure by B's whole contribution");
        assertEq(p0.exposure - cured.exposure, reserves.deployedTo(b.idB), "exactly B's recorded face");
        assertEq(defaultManager.impairmentRevision(), revision + 1, "and advanced the revision");
        assertFalse(cured.active, "cure invalidates (economic event, servicer + attestation)");
        assertEq(cured.mark, cured.base, "base prices");
        emit log_named_uint("R4 exposure before cure", p0.exposure);
        emit log_named_uint("R4 exposure after cure", cured.exposure);
        // carol re-marks in the same block: exposure, pools and capacity return to the wei.
        vm.prank(carol);
        defaultManager.markPastDue(b.idB);
        Probe memory remarked = _probe(b);
        assertEq(remarked.exposure, p0.exposure, "same exposure as published");
        assertEq(remarked.capacity, p0.capacity, "same capacity");
        assertEq(remarked.base, p0.base, "same base");
        assertTrue(remarked.riskHash != p0.riskHash, "a different risk episode (revision)");
        assertFalse(remarked.active, "the old memorandum does not revive");
        assertEq(remarked.mark, remarked.base, "base prices until fresh evidence");
    }

    function _partialLossOnAInvalidatesWithoutTouchingExposure(Book memory b, Probe memory p0) internal {
        _realizeLoss(b.idA, 50_000e18, bytes32(0));
        Probe memory p = _probe(b);
        assertEq(p.exposure, p0.exposure, "a loss on the declared A leaves the marked cohort alone");
        assertEq(curator.poolBalance(FILM), 100_000e18, "layer one absorbed the 50,000e18");
        assertTrue(p.riskHash != p0.riskHash, "identity moved (revision, pool, declared principal)");
        assertFalse(p.active, "invalidated");
        assertEq(p.mark, p.base, "base prices");
    }

    function _couponOnBInvalidatesAndLowersExposure(Book memory b, Probe memory p0) internal {
        uint256 revision = defaultManager.impairmentRevision();
        _repay(b.idB, 10_000e18, 0);
        Probe memory p = _probe(b);
        assertLt(p.exposure, p0.exposure, "the coupon lowered the marked exposure");
        uint256 drop = p0.exposure - p.exposure;
        assertGe(drop, 10_000e18, "by at least the interest received");
        assertLt(drop - 10_000e18, 1e12, "plus less than one asset-grid unit of recognised rounding");
        emit log_named_uint("R4 exposure drop on a 10,000e18 coupon", drop);
        assertGt(defaultManager.impairmentRevision(), revision, "and advanced the revision");
        assertFalse(p.active, "a repayment invalidates (attested economic event)");
        assertEq(p.mark, p.base, "base prices");
    }

    function _theMaturedPikCannotCapitalise(Book memory b, Probe memory p0) internal {
        uint256 pik = b.idB + 1;
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(pik);
        assertTrue(d.pik && d.known && !d.active, "P is a matured PIK note");
        assertEq(d.nextCapitalization, 0, "no further capitalisation");
        assertGt(defaultManager.pastDueContribution(pik), 100_000e18, "P is marked at its capitalised face");
        vm.warp(b.t0 + 7 days);
        _freshen();
        Probe memory p = _probe(b);
        assertTrue(p.active, "alive a week later");
        assertEq(reserves.unpostedAccruedLoan(pik), 0, "P accrued nothing after maturity");
        assertEq(p.increase, reserves.accruedPastDue(FILM), "the increase is the FILM cohort's unposted growth");
        assertEq(p.increase, reserves.unpostedAccruedLoan(b.idB), "which is B's alone");
        vm.prank(carol);
        assertEq(reserves.serviceAccruedLoan(pik), 0, "carol cannot capitalise P");
        assertEq(_probe(b).mark, p0.mark + p.increase, "ratchet carries B's accrual only");
        emit log_named_uint("R4 B's accrual over the week", p.increase);
    }

    // ─────────────────────────────────────────────────────────────────────
    // R5 (I2): fee accounting
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The recovery itself is performance-bearing (ADR-0031: shares mint at publication).
    ///         Thereafter the fee mark moves by exactly the senior increase at +1 s, +1 d, +7 d and
    ///         +29 d, and `accrueFees` crystallises zero shares at each instant: reserved income
    ///         is never charged a performance fee. At the cap (bob's permissionless top-up drives
    ///         the base below `A0 + increase`), the senior path returns the base and the fee path
    ///         keeps `F0 + increase`: the junior credit stays fee-neutral and ordering holds.
    /// @dev Mutation M5 (drop `+ increase` from `performanceFeeImpairment`) mints performance
    ///      shares on the reserved income.
    function test_atk_ratchet_theReservedIncomeIsNeverChargedAPerformanceFee() public onFork {
        Book memory b = _markedBook(FILM, 100_000e18);
        (uint256 mgmt0, uint256 perf0) = vault.accrueFees();
        assertEq(mgmt0, 0, "no management fee configured");
        // The mark pinned the high-water mark at the pre-mark fee NAV (markPastDue calls
        // accrueFees first), so the assessed fee NAV sits below it: no shares at publication.
        assertEq(perf0, 0, "the recovery sits below the HWM pinned at the mark");
        uint256 hwm = vault.highWaterMark();
        Probe memory p0 = _probe(b);
        assertLt(p0.feeRate, hwm, "fee-net rate below the pinned HWM");
        emit log_named_uint("R5 high-water mark (per share)", hwm);
        emit log_named_uint("R5 fee-net rate at publication", p0.feeRate);
        uint256[4] memory offsets = [uint256(1), 1 days, 7 days, 29 days];
        for (uint256 i = 0; i < 4; ++i) {
            vm.warp(b.t0 + offsets[i]);
            _freshen();
            Probe memory p = _probe(b);
            assertEq(p.fee - p0.fee, p.mark - p0.mark, "fee and senior marks move by the same increase");
            assertEq(p.fee - p0.fee, p.increase, "which is the gross cohort increase");
            (uint256 mgmt, uint256 perf) = vault.accrueFees();
            assertEq(mgmt, 0, "no management fee");
            assertEq(perf, 0, "NO performance fee on reserved delinquent income");
            assertEq(vault.highWaterMark(), hwm, "the high-water mark is untouched");
            assertLe(vault.feeExchangeRate(), p0.feeRate, "the fee-net rate did not rise");
            emit log_named_uint("R5 offset (s)", offsets[i]);
            emit log_named_uint("R5 fee mark", p.fee);
            emit log_named_uint("R5 senior mark", p.mark);
        }
        _theCapIsConsistentAcrossBothPaths(b);
    }

    /// @dev At +29 d bob funds coverage so the base drops below A0 + increase.
    function _theCapIsConsistentAcrossBothPaths(Book memory b) internal {
        Probe memory p = _probe(b);
        uint256 baseFeeBefore = defaultManager.performanceFeeImpairment();
        _mintFromUSDC(bob, 2_000_000e6);
        _fundCoverage(bob, 1_320_000e18);
        Probe memory c = _probe(b);
        assertTrue(c.active, "a capacity increase is tolerated (FRV-FS-04)");
        assertLt(c.base, b.assessed + c.increase, "the top-up drove the base below A0 + increase");
        assertEq(c.mark, c.base, "senior path: capped at the base");
        assertEq(c.fee, p.fee, "fee path: F0 + increase, the top-up cannot offset the reserve");
        assertEq(c.fee, b.fee0 + c.increase, "to the wei");
        assertGe(c.fee, c.mark, "ordering: the vault's fee mark is at least the senior mark");
        assertEq(defaultManager.performanceFeeImpairment(), baseFeeBefore, "the base fee mark ignores the top-up");
        assertEq(c.baseFee - c.fee, b.base0 - b.assessed, "the fee path keeps the assessed recovery R below the base");
        assertEq(c.feeRate, p.feeRate, "the fee-net rate is unchanged by the top-up");
        assertGt(c.quote, p.quote, "the senior exit improved with the top-up");
        emit log_named_uint("R5 base after top-up", c.base);
        emit log_named_uint("R5 uncapped A0 + increase", b.assessed + c.increase);
        emit log_named_uint("R5 fee mark after top-up", c.fee);
        emit log_named_uint("R5 base fee mark after top-up", c.baseFee);
    }

    // ─────────────────────────────────────────────────────────────────────
    // R6: the upgrade seam
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A pre-field memorandum (presence flag cleared by `vm.store`) fails closed to the
    ///         base even though its exact hash still matches. The ACTUAL previous implementation,
    ///         installed on the proxy, reproduces the round-three Medium on this fork (dead at
    ///         +1 s); upgrading back to 4407d60 leaves that memorandum conservative until
    ///         republication. A base whose tuple has the wrong length is refused at wiring and,
    ///         if the LIVE base loses the tuple with a memorandum standing, both views and the
    ///         vault's quote revert until governance clears (liveness of an unsequenced rollback).
    /// @dev Mutations M6 (drop the presence-flag check) and M7 (`!= 96` to `< 96`).
    function test_atk_ratchet_theUpgradeSeamFailsClosedOnTheFork() public onFork {
        Book memory b = _markedBook(FILM, 100_000e18);
        _aPreFieldMemorandumFailsClosed(b);
        _theActualPreviousImplementationRoundTrips(b);
        _aWrongLengthBaseIsRefused();
        _aLiveBaseLosingTheTupleBricksPricingUntilCleared(b);
    }

    function _aPreFieldMemorandumFailsClosed(Book memory b) internal {
        AssessedImpairmentSource a = _assessed();
        bytes32 flagSlot = bytes32(uint256(ASSESSMENT_SLOT) + FLAG_OFFSET);
        assertEq(uint256(vm.load(address(a), flagSlot)), 1, "slot 11: accrualStateSnapshotted set");
        Probe memory p = _probe(b);
        assertTrue(p.active && p.mark == 100_000e18, "assessed");
        vm.store(address(a), flagSlot, bytes32(0));
        (bytes32 snap, bytes32 live, bool matches) = a.assessmentState();
        assertEq(snap, live, "the exact hash still matches at this instant");
        assertFalse(matches, "but a pre-field memorandum does not match");
        assertFalse(_active(), "inactive");
        assertEq(a.pendingSeniorImpairment(), p.base, "senior view: base");
        assertEq(a.performanceFeeImpairment(), p.baseFee, "fee view: base gross");
        assertEq(vault.previewRedeem(b.sharesA), p.baseQuote, "alice quoted the base");
        vm.store(address(a), flagSlot, bytes32(uint256(1)));
        assertTrue(_active(), "restored");
    }

    function _theActualPreviousImplementationRoundTrips(Book memory b) internal {
        AssessedImpairmentSource a = _assessed();
        bytes32 flagSlot = bytes32(uint256(ASSESSMENT_SLOT) + FLAG_OFFSET);
        address previous = address(new PreviousAssessmentSource());
        vm.prank(timelock);
        a.upgradeToAndCall(previous, "");
        assertEq(_implementation(), previous, "the previous implementation is live (a rollback)");
        assertTrue(_active(), "old code reads the 4407d60 memorandum through its exact hash");
        uint256 s = vm.snapshotState();
        vm.warp(b.t0 + 1);
        assertFalse(_active(), "ROUND THREE F2 REPRODUCED under the previous implementation: dead at +1 s");
        _back(s, b);
        // ROLLBACK HAZARD (observation): the old code neither writes nor clears slots 9-11, so a
        // memorandum it publishes over a 4407d60 memorandum inherits the stale accrual snapshot
        // and is honoured after the forward upgrade whenever the identity still matches.
        vm.prank(timelock);
        PreviousAssessmentSource(address(a)).setAssessment(90_000e18, uint64(b.t0 + TTL), EVIDENCE);
        assertEq(uint256(vm.load(address(a), flagSlot)), 1, "the stale presence flag survives the old code");
        address fresh = address(new AssessedImpairmentSource());
        vm.prank(timelock);
        a.upgradeToAndCall(fresh, "");
        assertTrue(_active(), "ROLLBACK HAZARD: the old-code memorandum is honoured on the stale snapshot");
        assertEq(a.pendingSeniorImpairment(), 90_000e18, "priced at the old-code amount (stale E0 is this block's)");
        // The documented sequence: a proxy that never carried the flag. Clear (zeroes 9-11),
        // roll back, publish under the old code, upgrade forward: conservative until republished.
        vm.prank(timelock);
        a.clearAssessment();
        assertEq(uint256(vm.load(address(a), flagSlot)), 0, "cleared");
        vm.prank(timelock);
        a.upgradeToAndCall(previous, "");
        vm.prank(timelock);
        PreviousAssessmentSource(address(a)).setAssessment(100_000e18, uint64(b.t0 + TTL), EVIDENCE);
        assertTrue(_active(), "published by the previous implementation");
        assertEq(uint256(vm.load(address(a), flagSlot)), 0, "the old code wrote no presence flag");
        vm.prank(timelock);
        a.upgradeToAndCall(fresh, "");
        assertEq(_implementation(), fresh, "4407d60 is live again");
        assertFalse(_active(), "the old memorandum falls back conservatively");
        assertEq(a.pendingSeniorImpairment(), defaultManager.pendingSeniorImpairment(), "base");
        assertEq(a.performanceFeeImpairment(), defaultManager.performanceFeeImpairment(), "base gross");
        _publish(100_000e18, uint64(TTL));
        assertTrue(_active(), "republished under 4407d60");
        assertEq(uint256(vm.load(address(a), flagSlot)), 1, "presence flag written");
        s = vm.snapshotState();
        vm.warp(b.t0 + 1);
        assertTrue(_active(), "and now the clock does not kill it");
        assertGt(a.pendingSeniorImpairment(), 100_000e18, "the ratchet carries the second's accrual");
        _back(s, b);
    }

    function _aWrongLengthBaseIsRefused() internal {
        AssessedImpairmentSource a = _assessed();
        address short_ = address(new FixedReplyBase(64));
        address long_ = address(new FixedReplyBase(128));
        address dead = address(new RevertingBase());
        vm.startPrank(timelock);
        vm.expectRevert(abi.encodeWithSelector(AssessedImpairmentSource.Assessment_BaseNotRevisioned.selector, short_));
        a.setBaseSource(short_);
        vm.expectRevert(abi.encodeWithSelector(AssessedImpairmentSource.Assessment_BaseNotRevisioned.selector, long_));
        a.setBaseSource(long_);
        vm.expectRevert(abi.encodeWithSelector(AssessedImpairmentSource.Assessment_BaseNotRevisioned.selector, dead));
        a.setBaseSource(dead);
        vm.stopPrank();
        assertEq(a.baseSource(), address(defaultManager), "wiring untouched");
        assertTrue(_active(), "memorandum untouched");
    }

    function _aLiveBaseLosingTheTupleBricksPricingUntilCleared(Book memory b) internal {
        AssessedImpairmentSource a = _assessed();
        bytes memory call = abi.encodeCall(IRevisionedImpairmentSource.impairmentAssessmentState, ());
        bytes memory err = abi.encodeWithSelector(
            AssessedImpairmentSource.Assessment_BaseNotRevisioned.selector, address(defaultManager)
        );
        (bytes32 risk, uint256 exposure, uint256 capacity) = defaultManager.impairmentAssessmentState();
        // A 128-byte reply carrying the real tuple plus one word: refused, never partially decoded.
        vm.mockCall(address(defaultManager), call, abi.encode(risk, exposure, capacity, uint256(1)));
        vm.expectRevert(err);
        a.pendingSeniorImpairment();
        vm.expectRevert(err);
        a.performanceFeeImpairment();
        vm.expectRevert(err);
        vault.previewRedeem(b.sharesA);
        vm.expectRevert(err);
        vault.redemptionTotalAssets();
        vm.clearMockedCalls();
        // The base reverting outright (an unsequenced rollback with a memorandum standing).
        vm.mockCallRevert(address(defaultManager), call, "");
        vm.expectRevert(err);
        a.pendingSeniorImpairment();
        vm.expectRevert(err);
        vault.previewRedeem(b.sharesA);
        vm.expectRevert(err);
        a.currentAssessment();
        address fresh = address(new AssessedImpairmentSource());
        vm.prank(timelock);
        vm.expectRevert(err);
        a.upgradeToAndCall(fresh, "");
        // Governance can still clear; the wrapper then short-circuits before the tuple read.
        vm.prank(timelock);
        a.clearAssessment();
        assertEq(a.pendingSeniorImpairment(), defaultManager.pendingSeniorImpairment(), "liveness restored: base");
        assertEq(vault.previewRedeem(b.sharesA), _quoteAt(b.sharesA, defaultManager.pendingSeniorImpairment()), "quote");
        vm.prank(timelock);
        vm.expectRevert(err);
        a.setAssessment(100_000e18, uint64(block.timestamp + TTL), EVIDENCE);
        vm.clearMockedCalls();
    }

    // ─────────────────────────────────────────────────────────────────────
    // Scenes and readings
    // ─────────────────────────────────────────────────────────────────────

    /// @dev alice stakes 3,000,000e18; 150,000e18 FILM first-loss and 500,000e18 shared reserve;
    ///      A (FILM, 1,000,000e18) declared at t=0; B (1,000,000e18, 14%) in `classB` performs
    ///      until day 60 when carol marks it (a Renewables B gets a 2,000,000e18 Renewables pool);
    ///      the timelock publishes `assessed` in the mark block.
    function _markedBook(uint256 classB, uint256 assessed) internal returns (Book memory b) {
        _grantTimelockAdmin();
        _mintFromUSDC(alice, 5_000_000e6);
        b.sharesA = _stake(alice, 3_000_000e18);
        _mintFromUSDC(ops, 3_000_000e6);
        _postFirstLoss(FILM, 150_000e18);
        if (classB != FILM) _postFirstLoss(classB, 2_000_000e18);
        _fundCoverage(ops, 500_000e18);
        b.idA = _originateAndFund(1_000_000e18);
        b.idB = classB == FILM
            ? _originateAndFund(1_000_000e18)
            : _originateAndFundIn(classB, keccak256("RATCHET_BORROWER_B"), 1_000_000e18);
        _declareDefault(b.idA, keccak256("ratchet-declared-a"));
        assertEq(defaultManager.pendingSeniorImpairment(), 350_000e18, "declared face less both junior layers");
        _warp(60 days);
        _freshen();
        vm.prank(carol);
        defaultManager.markPastDue(b.idB);
        _finishBook(b, assessed);
    }

    /// @dev As `_markedBook(FILM, ..)` plus P: a 100,000e18 FILM PIK note with a single 30-day
    ///      period, matured at day 30 and marked by carol at day 60 alongside B.
    function _markedBookWithMaturedPik(uint256 assessed) internal returns (Book memory b) {
        _grantTimelockAdmin();
        _mintFromUSDC(alice, 5_000_000e6);
        b.sharesA = _stake(alice, 3_000_000e18);
        _mintFromUSDC(ops, 3_000_000e6);
        _postFirstLoss(FILM, 150_000e18);
        _fundCoverage(ops, 500_000e18);
        b.idA = _originateAndFund(1_000_000e18);
        b.idB = _originateAndFund(1_000_000e18);
        uint256 pik = _originateAndFundPik(100_000e18, 30 days);
        assertEq(pik, b.idB + 1, "P follows B");
        _declareDefault(b.idA, keccak256("ratchet-declared-a"));
        _warp(60 days);
        _freshen();
        vm.startPrank(carol);
        defaultManager.markPastDue(b.idB);
        defaultManager.markPastDue(pik);
        vm.stopPrank();
        _finishBook(b, assessed);
    }

    function _finishBook(Book memory b, uint256 assessed) internal {
        b.t0 = block.timestamp;
        b.base0 = defaultManager.pendingSeniorImpairment();
        b.e0 = defaultManager.pastDueExposure();
        b.assessed = assessed;
        assertLt(assessed, b.base0, "publishable");
        _publish(assessed, uint64(TTL));
        b.fee0 = _assessed().performanceFeeImpairment();
        assertEq(b.fee0, assessed + (defaultManager.performanceFeeImpairment() - b.base0), "fee mark at publication");
    }

    /// @dev Revert to `s` and pin the clock at the publication block.
    function _back(uint256 s, Book memory b) internal {
        assertTrue(vm.revertToState(s), "revert");
        vm.warp(b.t0);
    }

    /// @dev Republishes in the current block and refreshes the book's publication readings.
    function _republish(Book memory b, uint256 assessed) internal {
        _publish(assessed, uint64(TTL));
        b.t0 = block.timestamp;
        b.base0 = defaultManager.pendingSeniorImpairment();
        b.e0 = defaultManager.pastDueExposure();
        b.assessed = assessed;
        b.fee0 = _assessed().performanceFeeImpairment();
        assertEq(b.fee0, assessed + (defaultManager.performanceFeeImpairment() - b.base0), "fee mark at republication");
    }

    /// @dev Reads the tuple, both wrapper views, the base, the NAVs, alice's quote and the base
    ///      quote (the same instant with the assessment cleared, on a discarded snapshot).
    function _probe(Book memory b) internal returns (Probe memory p) {
        AssessedImpairmentSource a = _assessed();
        (p.riskHash, p.exposure, p.capacity) = defaultManager.impairmentAssessmentState();
        p.increase = p.exposure > b.e0 ? p.exposure - b.e0 : 0; // saturating: a fall is read as zero
        p.mark = a.pendingSeniorImpairment();
        p.fee = a.performanceFeeImpairment();
        p.base = defaultManager.pendingSeniorImpairment();
        p.baseFee = defaultManager.performanceFeeImpairment();
        p.totalAssets = vault.totalAssets();
        p.redemptionAssets = vault.redemptionTotalAssets();
        p.quote = vault.previewRedeem(b.sharesA);
        p.rate = vault.currentExchangeRate();
        p.feeRate = vault.feeExchangeRate();
        p.active = _active();
        uint256 s = vm.snapshotState();
        vm.prank(timelock);
        a.clearAssessment();
        p.baseQuote = vault.previewRedeem(b.sharesA);
        assertTrue(vm.revertToState(s), "probe: revert");
    }

    /// @dev Originate in a receivable class with its own borrower at 14%, then fund.
    function _originateAndFundIn(uint256 classId, bytes32 borrowerId, uint256 principal)
        internal
        returns (uint256 tokenId)
    {
        tokenId = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + 365 days);
        bytes32 ref = keccak256(abi.encode("ratchet-ref", tokenId));
        ClaimBridge.OriginationTerms memory terms =
            _forkTermsFor(classId, borrowerId, bytes32(0), principal, 7500, 1400, maturity, ref);
        _attestAndOriginate(tokenId, terms);
        vm.prank(ops);
        waterfall.fund(tokenId, principal / 1e12);
    }

    /// @dev A FILM PIK note with one signed period: capitalises and matures at `term`.
    function _originateAndFundPik(uint256 principal, uint256 term) internal returns (uint256 tokenId) {
        tokenId = bridge.totalOriginated() + 1;
        ClaimBridge.OriginationTerms memory t = _forkTermsFor(
            FILM,
            keccak256("RATCHET_PIK_BORROWER"),
            keccak256("US-GA"),
            principal,
            7500,
            1400,
            uint64(block.timestamp + term),
            keccak256(abi.encode("ratchet-pik", tokenId))
        );
        t.pik = true;
        t.paymentInterval = uint64(term);
        t.nextPaymentDue = uint64(block.timestamp + term);
        _attestAndOriginate(tokenId, t);
        vm.prank(ops);
        waterfall.fund(tokenId, principal / 1e12);
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(tokenId);
        assertTrue(d.pik && d.active, "registered as an accruing PIK note");
    }

    function _attestAndOriginate(uint256 tokenId, ClaimBridge.OriginationTerms memory terms) internal {
        bytes32 termsHash = bridge.creditTermsHash(terms);
        _attest(tokenId, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash);
        _attest(tokenId, IAttestationOracle.AttestationKind.UCCFiled, termsHash);
        _attest(tokenId, IAttestationOracle.AttestationKind.CreditIssued, termsHash);
        vm.prank(ops);
        uint256 id = bridge.originate(ops, terms);
        require(id == tokenId, "ATK_ratchet: tokenId drift");
    }
}

/// @dev A base that answers every call with `length` bytes of zeros.
contract FixedReplyBase {
    uint256 private immutable LENGTH;

    constructor(uint256 length) {
        LENGTH = length;
    }

    fallback() external {
        uint256 length = LENGTH;
        assembly {
            return(0, length)
        }
    }
}

/// @dev A base that reverts on every call.
contract RevertingBase {
    fallback() external {
        revert("dead base");
    }
}
