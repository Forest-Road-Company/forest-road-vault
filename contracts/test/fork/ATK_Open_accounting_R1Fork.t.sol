// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IAccrualLifecycle} from "../../src/interfaces/IAccrualLifecycle.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {AccrualBook} from "../../src/libraries/AccrualBook.sol";
import {AccrualSegments} from "../../src/libraries/AccrualSegments.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @title OPEN_accounting_R1: accounting and conservation under interleaved permissionless and
///        operator events, against the FULL protocol on a pinned mainnet fork.
///
/// @notice Every view of the same wei must agree at every instant: the reserve's deployed face
///         (recorded plus unposted), the book's recognised gross (issued plus unissued), USDfr
///         effective supply against backing, the registry's effective exposure, and the default
///         manager's past-due and declared risk carriers (recorded plus the reserve's cohort
///         clock). `_reconcile` asserts all of them after every step. The three candidates:
///
///           C1. Two facilities in one class, both marked past due, with carol posting and
///               materialising each leg at odd offsets, a coupon on a marked facility (rounding
///               close plus re-anchor), a stale window across two boundaries at different times
///               processed one at a time, a cure, a coupon on the other marked facility after its
///               technical boundary, a declaration, a partial loss, a recovery carrying interest,
///               a terminal write-off with retirement, and a balloon repayment with retirement.
///           C2. A signed amendment on a past-due-marked facility: the cohort clock must change
///               slope with the facility, the close must post the old curve and credit its
///               correction, and the cure must remove exactly the new slope.
///           C3. A governance impairment mark carried across a rounding close (mark consumed by
///               the write-down while the cascade burns the loss), a large principal recovery
///               (mark clamped to the remaining face), and a terminal write-off.
contract OPEN_accounting_R1 is ForkLifecycleFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    uint256 internal constant SCALE = 1e12;
    uint256 internal constant YEAR = 360 days;
    uint16 internal constant RATE_BPS = 1400;
    uint256 internal constant P1 = 1_000_001e18;
    uint256 internal constant P2 = 700_003e18;

    bytes32 internal constant LOSS_BURNED = keccak256("LossBurned(address,uint256)");
    bytes32 internal constant YIELD_MINTED = keccak256("YieldMinted(address,uint256)");
    bytes32 internal constant ACCRUED_MINTED =
        keccak256("AccruedInterestMinted(uint256,address,address,uint256,uint256)");
    bytes32 internal constant ALIGNED = keccak256("AccrualLoanAligned(uint256,uint64,uint64,uint256,uint256,bool)");

    event AccrualRoundingAllocated(
        uint256 indexed facilityId,
        uint64 indexed closureNonce,
        uint256 amount,
        uint256 prepaid,
        uint256 curator,
        uint256 backstop,
        uint256 senior,
        uint256 unabsorbed,
        uint256 markConsumed
    );
    event AccrualLoanAligned(
        uint256 indexed facilityId,
        uint64 indexed closureNonce,
        uint64 at,
        uint256 positiveCorrection,
        uint256 roundingLoss,
        bool stopped
    );

    /// @dev Running supply ledger rebuilt from events, so physical supply is reconstructed
    ///      independently of the book: supply == supply0 + user mints + origination fee mints +
    ///      accrual deliveries - cascade burns.
    struct Ledger {
        uint256 supply0;
        uint256 userMinted;
        uint256 yieldMinted;
        uint256 accrualSenior;
        uint256 accrualFee;
        uint256 burned;
        uint256 corrections;
        uint256 roundingLosses;
        uint256 closures;
    }

    struct Model {
        AccrualSegments.Terms terms;
        uint64 start;
        uint64 end;
        uint256 segmentAmount;
        uint256 rate;
        uint256 remainder;
    }

    struct Sums {
        uint256 deployed;
        uint256 unposted;
        uint256 marked;
        uint256 declared;
    }

    Ledger internal L;
    uint256[] internal ids;

    // ─────────────────────────────────────────────────────────────────────
    // C1. Two facilities, one class, everything interleaved
    // ─────────────────────────────────────────────────────────────────────

    function test_open_twoFacilityCohortAndFaceReconcileAcrossInterleavedLifecycle() public onFork {
        _begin();
        _mintTracked(alice, 5_000_000e6);
        _stake(alice, 3_000_000e18);
        _postFirstLossTracked(50_000e18);
        _fundCoverageTracked(20_000e18);

        uint64 t0 = uint64(block.timestamp);
        uint256 f2 = _fundFacility(P2, keccak256("R1-B2"), 365 days);
        _warp(1 days);
        uint256 f1 = _fundFacility(P1, keccak256("R1-B1"), 700 days);
        Model memory m2 = _model(f2, P2, RATE_BPS, t0);
        _reconcile("funded");

        // Both facilities markable: F2 after t0+51d, F1 after t0+52d.
        _warp(51 days + 1 hours);
        vm.prank(carol);
        defaultManager.markPastDue(f1);
        vm.prank(carol);
        defaultManager.markPastDue(f2);
        _reconcile("both marked");
        _assertMarked(f1);
        _assertMarked(f2);

        // carol posts one and materialises each leg at odd offsets while the cohort grows.
        _warp(_odd(1));
        _assertMarked(f1);
        vm.prank(carol);
        reserves.postAccruedLoan(f1);
        _reconcile("posted f1 while marked");
        _assertMarked(f1);
        vm.prank(carol);
        reserves.materializeAccrued(1);
        _reconcile("materialised senior");
        _warp(_odd(2));
        vm.prank(carol);
        reserves.materializeAccrued(2);
        vm.prank(carol);
        vault.accrueFees();
        _reconcile("materialised fee and crystallised vault fees");
        _assertMarked(f1);
        _assertMarked(f2);

        // A coupon on the marked F2 at an offset whose close over-recognises: the rounding loss
        // must be charged to the class curator inside the receipt, the marked contribution must
        // shrink by the loss (onRounding) and then re-anchor to the face (onPerformingRepayment).
        {
            (uint256 off, uint256 loss) = _firstLossOffsetFrom(m2, block.timestamp - m2.start, 1);
            _warp(off);
            IWaterfallEngine.Payment memory p = _prep(f2, reserves.accruedDebt(f2).interest, 0, "f2-coupon");
            vm.expectEmit(true, true, true, true, address(reserves));
            emit AccrualRoundingAllocated(f2, 1, loss, 0, loss, 0, 0, 0, 0);
            _settle(p);
            emit log_named_uint("C1 rounding loss at the marked F2 coupon", loss);
        }
        _reconcile("coupon on marked f2");
        _assertMarked(f2);
        assertEq(reserves.deployedTo(f2), P2, "f2 face is exactly principal after the exact coupon");
        assertEq(defaultManager.pastDueContribution(f2), P2, "f2 contribution re-anchored to principal");

        // Stale window: F2 matures at t0+365d and F1 hits its technical boundary at t0+366d.
        _warpTo(t0 + 366 days + 3 hours);
        {
            IContinuousAccrual.Snapshot memory s = reserves.accrualSnapshot();
            assertFalse(s.fresh, "two boundaries pending");
            assertEq(s.accruedThrough, t0 + 365 days, "frontier is the earliest boundary");
            uint256 depF1 = reserves.deployedTo(f1);
            uint256 eff = controller.totalUSDfr();
            uint256 backing = reserves.totalBackingValue();
            uint256 cohort = defaultManager.pastDuePrincipal(FILM);
            _warp(1 hours);
            assertEq(reserves.deployedTo(f1), depF1, "stale: face frozen at the frontier");
            assertEq(controller.totalUSDfr(), eff, "stale: effective supply frozen");
            assertEq(reserves.totalBackingValue(), backing, "stale: backing frozen");
            assertEq(defaultManager.pastDuePrincipal(FILM), cohort, "stale: cohort frozen");
            vm.prank(carol);
            vm.expectRevert(
                abi.encodeWithSelector(
                    AccrualBook.AccrualBook_BoundaryPending.selector, uint64(t0 + 365 days), uint64(block.timestamp)
                )
            );
            reserves.materializeAccrued(1);
        }
        _reconcile("stale window");
        _assertMarked(f1);
        _assertMarked(f2);

        // One boundary at a time. Between the two the frontier is F1's boundary, still stale.
        {
            vm.prank(carol);
            (uint256 processed, bool fresh) = reserves.checkpointAccrual(1);
            assertEq(processed, 1, "first batch processed F2's maturity");
            assertFalse(fresh, "F1's boundary still pending");
            IContinuousAccrual.Snapshot memory s = reserves.accrualSnapshot();
            assertEq(s.accruedThrough, t0 + 366 days, "frontier moved to F1's technical boundary");
            assertFalse(reserves.accruedDebt(f2).active, "F2 deactivated at maturity");
        }
        _reconcile("mid-batch");
        _assertMarked(f1);
        _assertMarked(f2);
        {
            vm.prank(carol);
            (uint256 processed, bool fresh) = reserves.checkpointAccrual(1);
            assertEq(processed, 1, "second batch processed F1's technical boundary");
            assertTrue(fresh, "fresh after the catch-up");
            assertTrue(reserves.accrualSnapshot().fresh, "snapshot fresh");
            IAccrualLifecycle.Debt memory d2 = reserves.accruedDebt(f2);
            assertEq(reserves.deployedTo(f2), d2.principal + d2.interest, "matured F2 face is exact");
        }
        _reconcile("fresh after catch-up");
        _assertMarked(f1);
        _assertMarked(f2);

        // Cure F2, then a coupon on F1 on its second technical segment while still marked.
        _clearPastDue(f2, keccak256("R1-cure-f2"));
        _reconcile("f2 cured");
        assertEq(defaultManager.pastDueContribution(f2), 0, "f2 left the cohort");
        _assertMarked(f1);
        {
            uint256 interest = reserves.accruedDebt(f1).interest;
            _pay(f1, interest, 0, "f1-coupon");
            assertEq(reserves.deployedTo(f1), P1, "f1 face is exactly principal after the exact coupon");
        }
        _reconcile("coupon on marked f1 after its technical boundary");
        _assertMarked(f1);

        // Declare F1, partial loss, recovery with an interest leg, terminal write-off.
        _warp(_odd(3));
        _assertMarked(f1);
        _declareDefault(f1, keccak256("R1-default-f1"));
        _reconcile("f1 declared");
        assertEq(defaultManager.pastDueExposure(), 0, "cohort empty after the declaration");
        assertEq(defaultManager.defaultedContribution(f1), reserves.deployedTo(f1), "declared mark equals the face");
        assertFalse(reserves.accruedDebt(f1).active, "f1 stopped");

        _realizeLoss(f1, 300_000e18, bytes32(0));
        _reconcile("f1 partial loss");
        assertEq(defaultManager.defaultedContribution(f1), reserves.deployedTo(f1), "mark tracks the face after a loss");

        _warp(_odd(4));
        {
            IAccrualLifecycle.Debt memory d1 = reserves.accruedDebt(f1);
            assertEq(reserves.deployedTo(f1), d1.principal + d1.interest, "stopped face is exact");
            _pay(f1, d1.interest, 200_000e18, "f1-recovery");
        }
        _reconcile("f1 recovery with interest leg");
        assertEq(defaultManager.defaultedContribution(f1), reserves.deployedTo(f1), "mark re-anchored after recovery");
        assertEq(reserves.accruedDebt(f1).interest, 0, "recovered interest discharged the stopped claim");

        _realizeLoss(f1, reserves.deployedTo(f1), bytes32(0));
        _reconcile("f1 written off");
        assertEq(reserves.deployedTo(f1), 0, "f1 face zero");
        assertEq(uint8(bridge.facility(f1).state), uint8(ClaimBridge.LoanState.Resolved), "f1 resolved");
        assertEq(defaultManager.declaredDefaultedPrincipal(FILM), 0, "declared pool empty");

        // F2 balloon: full principal plus the interest recognised through maturity.
        _warp(_odd(5));
        {
            IAccrualLifecycle.Debt memory d2 = reserves.accruedDebt(f2);
            assertEq(reserves.deployedTo(f2), d2.principal + d2.interest, "balloon face is exact");
            _pay(f2, d2.interest, d2.principal, "f2-balloon");
        }
        _reconcile("f2 repaid");
        assertEq(uint8(bridge.facility(f2).state), uint8(ClaimBridge.LoanState.Repaid), "f2 repaid");
        assertEq(reserves.deployedPrincipal(), 0, "book empty");
        assertEq(reserves.accrualSnapshot().unposted, 0, "nothing unposted on an empty book");

        vm.prank(carol);
        reserves.materializeAccrued(3);
        _reconcile("final delivery");
        assertEq(reserves.accrualSnapshot().unissued, 0, "everything recognised is physical");
        assertEq(controller.totalUSDfr(), usdfr.totalSupply(), "effective supply equals physical supply");
        assertEq(
            reserves.totalBackingValue(), reserves.normalizeUSDC(reserves.idleUSDC()), "backing is idle cash alone"
        );
        emit log_named_uint("C1 closures", L.closures);
        emit log_named_uint("C1 positive corrections total", L.corrections);
        emit log_named_uint("C1 rounding losses total", L.roundingLosses);
        emit log_named_uint("C1 gross recognised", reserves.accrualSnapshot().gross);
        emit log_named_uint("C1 senior delivered", L.accrualSenior);
        emit log_named_uint("C1 fee delivered", L.accrualFee);
        emit log_named_uint("C1 burned by cascades", L.burned);
    }

    // ─────────────────────────────────────────────────────────────────────
    // C2. Amendment on a past-due-marked facility
    // ─────────────────────────────────────────────────────────────────────

    function test_open_amendmentOnMarkedFacilityMovesTheCohortSlopeExactly() public onFork {
        _begin();
        _mintTracked(alice, 5_000_000e6);
        _stake(alice, 3_000_000e18);
        _postFirstLossTracked(50_000e18);

        uint64 t0 = uint64(block.timestamp);
        uint256 f = _fundFacility(P1, keccak256("R1-B3"), 365 days);
        Model memory m = _model(f, P1, RATE_BPS, t0);
        _reconcile("funded");

        _warp(51 days + 1 hours);
        vm.prank(carol);
        defaultManager.markPastDue(f);
        _reconcile("marked");
        _assertMarked(f);

        // Amend at an offset whose close credits a positive correction.
        uint256 amendAt;
        uint256 canonical;
        {
            uint256 off = _firstCorrectionOffset(m, block.timestamp - m.start);
            _warp(off);
            amendAt = block.timestamp;
            uint256 elapsed = amendAt - m.start;
            uint256 full = Math.mulDiv(m.segmentAmount, elapsed, m.end - m.start);
            canonical = AccrualSegments.cumulative(m.terms, uint64(amendAt));
            assertGt(canonical, full, "precondition: the close credits a correction");
            ClaimBridge.Facility memory fac = bridge.facility(f);
            ClaimBridge.Amendment memory a = ClaimBridge.Amendment({
                interestRateBps: 900,
                maturity: fac.maturity,
                paymentInterval: fac.paymentInterval,
                nextPaymentDue: uint64(block.timestamp + 30 days),
                rateType: fac.rateType,
                dayCountConvention: fac.dayCountConvention,
                renewable: fac.renewable,
                paymentScheduleHash: fac.paymentScheduleHash,
                rateIndexRef: fac.rateIndexRef,
                renewalTermsHash: fac.renewalTermsHash
            });
            bytes32 amendmentId = keccak256("R1-amend-1");
            _attest(f, IAttestationOracle.AttestationKind.TermsAmended, keccak256(abi.encode(amendmentId, f, a)));
            vm.expectEmit(true, true, true, true, address(reserves));
            emit AccrualLoanAligned(f, 1, uint64(amendAt), canonical - full, 0, false);
            vm.prank(ops);
            bridge.amendTerms(f, amendmentId, a);
            emit log_named_uint("C2 positive correction at the amendment close", canonical - full);
        }
        _reconcile("amended while marked");
        _assertMarked(f);
        assertEq(reserves.deployedTo(f), P1 + canonical, "the amendment posted the old curve's canonical interest");
        assertEq(reserves.unpostedAccruedLoan(f), 0, "nothing unposted at the amendment instant");
        assertEq(reserves.accruedPastDue(FILM), 0, "cohort clock settled at the amendment instant");

        // The cohort clock must now run at the NEW integer slope, and nothing else.
        uint256 rate2;
        {
            IAccrualLifecycle.Debt memory d = reserves.accruedDebt(f);
            assertEq(d.interest, canonical, "contractual interest carried into the new epoch");
            AccrualSegments.Terms memory t = AccrualSegments.Terms({
                basis: P1,
                yearSeconds: YEAR,
                scale: SCALE,
                cap: d.balanceCeiling - (P1 + canonical),
                periodStart: uint64(amendAt),
                periodEnd: d.maturity,
                maturity: d.maturity,
                rateBps: 900
            });
            AccrualSegments.Segment memory seg = AccrualSegments.plan(t, uint64(amendAt));
            rate2 = seg.amount / (seg.end - seg.start);
            assertLt(rate2, m.rate, "the amended slope is lower");
            assertGt(rate2, 0, "the amended slope is positive");
        }
        uint256 recorded = defaultManager.pastDuePrincipal(FILM);
        _warp(1 hours);
        assertEq(reserves.unpostedAccruedLoan(f), rate2 * 3600, "facility streams at the new slope");
        assertEq(reserves.accruedPastDue(FILM), rate2 * 3600, "cohort streams at the new slope");
        assertEq(defaultManager.pastDuePrincipal(FILM), recorded + rate2 * 3600, "class risk grows at the new slope");
        _reconcile("one hour on the amended curve");
        _assertMarked(f);

        // A coupon on the amended curve, then the cure removes exactly the new slope.
        _warp(_odd(6));
        uint256 rate3;
        {
            uint256 interest = reserves.accruedDebt(f).interest;
            _pay(f, interest, 0, "amended-coupon");
            assertEq(reserves.deployedTo(f), P1, "face is principal after the exact coupon");
            // An interest-only coupon keeps the amended curve and widens its cap by the amount
            // paid; the successor segment starts now, so its integer slope is re-planned.
            IAccrualLifecycle.Debt memory d = reserves.accruedDebt(f);
            AccrualSegments.Terms memory t = AccrualSegments.Terms({
                basis: P1,
                yearSeconds: YEAR,
                scale: SCALE,
                cap: d.balanceCeiling - (P1 + canonical) + interest,
                periodStart: uint64(amendAt),
                periodEnd: d.maturity,
                maturity: d.maturity,
                rateBps: 900
            });
            AccrualSegments.Segment memory seg = AccrualSegments.plan(t, uint64(block.timestamp));
            rate3 = seg.amount / (seg.end - seg.start);
            assertGt(rate3, 0, "re-planned slope is positive");
        }
        _reconcile("coupon on the amended curve");
        _assertMarked(f);
        _warp(_odd(7));
        _clearPastDue(f, keccak256("R1-cure-f3"));
        _reconcile("cured");
        assertEq(defaultManager.pastDueContribution(f), 0, "left the cohort");
        assertEq(reserves.accruedPastDue(FILM), 0, "cohort clock empty");
        _warp(1 hours);
        assertEq(reserves.accruedPastDue(FILM), 0, "cohort clock has no slope left");
        assertEq(reserves.unpostedAccruedLoan(f), rate3 * 3600, "facility still streams at its re-planned slope");
        _reconcile("one hour after the cure");
    }

    // ─────────────────────────────────────────────────────────────────────
    // C3. Governance impairment mark across rounding, recovery and write-off
    // ─────────────────────────────────────────────────────────────────────

    function test_open_impairmentMarkIsConsumedOnceAcrossRoundingRecoveryAndWriteOff() public onFork {
        _begin();
        _mintTracked(alice, 5_000_000e6);
        _stake(alice, 3_000_000e18);
        _postFirstLossTracked(50_000e18);

        uint64 t0 = uint64(block.timestamp);
        uint256 f = _fundFacility(P1, keccak256("R1-B4"), 365 days);
        Model memory m = _model(f, P1, RATE_BPS, t0);
        _reconcile("funded");

        uint256 mark = 100_000e18;
        _warp(20 days);
        reserves.recognizePrincipalImpairment(f, mark, keccak256("R1-mark"));
        _reconcile("marked by governance");
        assertEq(reserves.principalImpairmentOf(f), mark, "mark recorded");

        // Rounding close under the mark: the cascade burns the loss from the curator and the
        // write-down consumes the same wei of the mark, so backing is unchanged by the close.
        {
            (uint256 off, uint256 loss) = _firstLossOffsetFrom(m, block.timestamp - m.start, 1);
            _warp(off);
            IWaterfallEngine.Payment memory p = _prep(f, reserves.accruedDebt(f).interest, 0, "marked-coupon");
            uint256 backing0 = reserves.totalBackingValue();
            // The close first credits the sub-slope remainder the live view holds back
            // (AccrualBook.reconcile); everything after that is backing-neutral under the mark.
            uint256 extra = Math.mulDiv(m.remainder, block.timestamp - m.start, m.end - m.start);
            vm.expectEmit(true, true, true, true, address(reserves));
            emit AccrualRoundingAllocated(f, 1, loss, 0, loss, 0, 0, 0, loss);
            _settle(p);
            assertEq(
                reserves.totalBackingValue(),
                backing0 + extra,
                "the close moves only the reconciled remainder; the loss is absorbed by the mark"
            );
            assertEq(reserves.principalImpairmentOf(f), mark - loss, "the mark absorbed the rounding write-down");
            emit log_named_uint("C3 rounding loss consumed against the mark", loss);
            emit log_named_uint("C3 remainder credited at the close", extra);
        }
        _reconcile("rounding close under a mark");

        // A large principal recovery clamps the mark to the remaining face.
        _warp(_odd(8));
        {
            IAccrualLifecycle.Debt memory d = reserves.accruedDebt(f);
            _pay(f, d.interest, 950_000e18, "big-recovery");
            assertEq(reserves.deployedTo(f), P1 - 950_000e18, "face after the recovery");
            assertEq(reserves.principalImpairmentOf(f), P1 - 950_000e18, "mark clamped to the remaining face");
            assertEq(reserves.totalPrincipalImpairment(), P1 - 950_000e18, "total mark clamped");
        }
        _reconcile("mark clamped by recovery");

        // Declare and write off the remainder: the mark must be consumed to zero, once.
        _warp(_odd(9));
        _declareDefault(f, keccak256("R1-default-f4"));
        _reconcile("declared under a clamped mark");
        {
            vm.prank(carol);
            reserves.materializeAccrued(3);
            uint256 face = reserves.deployedTo(f);
            uint256 supply0 = usdfr.totalSupply();
            _realizeLoss(f, face, bytes32(0));
            assertEq(reserves.principalImpairmentOf(f), 0, "mark consumed by the write-off");
            assertEq(reserves.totalPrincipalImpairment(), 0, "no mark left");
            assertEq(reserves.deployedTo(f), 0, "face zero");
            assertEq(supply0 - usdfr.totalSupply(), face, "the cascade burned the whole face");
            assertEq(uint8(bridge.facility(f).state), uint8(ClaimBridge.LoanState.Resolved), "resolved");
        }
        _reconcile("written off");
        assertEq(reserves.deployedPrincipal(), 0, "book empty");
    }

    // ─────────────────────────────────────────────────────────────────────
    // The reconciliation: every view of the same wei, after every step
    // ─────────────────────────────────────────────────────────────────────

    function _reconcile(string memory tag) internal {
        _drain();
        Sums memory v;
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            uint256 dep = reserves.deployedTo(id);
            v.deployed += dep;
            v.unposted += reserves.unpostedAccruedLoan(id);
            v.marked += defaultManager.pastDueContribution(id);
            v.declared += defaultManager.defaultedContribution(id);
            IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
            uint256 face = d.principal + d.interest;
            assertLt(dep, face + SCALE, string.concat("streamed face below canonical + grid: ", tag));
            assertLt(
                face, dep + SCALE + 731 days, string.concat("canonical face below streamed + grid + elapsed: ", tag)
            );
            assertLe(reserves.principalImpairmentOf(id), dep, string.concat("mark never exceeds its face: ", tag));
        }
        IContinuousAccrual.Snapshot memory s = reserves.accrualSnapshot();
        uint256 backing = reserves.totalBackingValue();
        assertEq(reserves.deployedPrincipal(), v.deployed, string.concat("deployedPrincipal == sum deployedTo: ", tag));
        assertEq(s.unposted, v.unposted, string.concat("book unposted == sum facility unposted: ", tag));
        assertEq(
            backing,
            reserves.normalizeUSDC(reserves.idleUSDC()) + v.deployed - reserves.totalPrincipalImpairment(),
            string.concat("backing == idle + faces - marks: ", tag)
        );
        assertEq(s.unissued, s.seniorUnissued + s.feeUnissued, string.concat("unissued legs add: ", tag));
        assertEq(
            controller.totalUSDfr(),
            usdfr.totalSupply() + s.unissued,
            string.concat("effective == physical + unissued: ", tag)
        );
        assertEq(
            L.accrualSenior + L.accrualFee + s.unissued,
            s.gross,
            string.concat("recognised == issued + unissued: ", tag)
        );
        assertEq(
            usdfr.totalSupply(),
            L.supply0 + L.userMinted + L.yieldMinted + L.accrualSenior + L.accrualFee - L.burned,
            string.concat("supply reconstructs from mints and burns: ", tag)
        );
        assertEq(reserves.roundingLossUnabsorbed(), 0, string.concat("no unabsorbed rounding: ", tag));
        {
            // A governance mark lowers backing without burning supply, by design: the deficit view
            // must then equal exactly the excess, and the un-marked book must still cover supply.
            uint256 eff = controller.totalUSDfr();
            assertEq(
                controller.recognizedDeficit(),
                eff > backing ? eff - backing : 0,
                string.concat("deficit == excess: ", tag)
            );
            assertLe(
                eff,
                backing + reserves.totalPrincipalImpairment(),
                string.concat("effective supply within un-marked backing: ", tag)
            );
        }
        assertEq(registry.classExposure(FILM), v.deployed, string.concat("registry class exposure == faces: ", tag));
        assertEq(registry.totalBookExposure(), v.deployed, string.concat("registry book exposure == faces: ", tag));
        assertEq(
            defaultManager.pastDuePrincipal(FILM), v.marked, string.concat("class cohort == sum contributions: ", tag)
        );
        assertEq(defaultManager.pastDueExposure(), v.marked, string.concat("global cohort == sum contributions: ", tag));
        assertEq(
            defaultManager.declaredDefaultedPrincipal(FILM),
            v.declared,
            string.concat("declared pool == sum declared contributions: ", tag)
        );
    }

    /// @dev A marked facility's recorded-plus-cohort contribution equals its face, always.
    function _assertMarked(uint256 id) internal view {
        assertEq(defaultManager.pastDueContribution(id), reserves.deployedTo(id), "marked contribution == face");
    }

    // ── helpers ───────────────────────────────────────────────────────────

    function _begin() internal {
        L.supply0 = usdfr.totalSupply();
        vm.recordLogs();
    }

    function _drain() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory g = logs[i];
            if (g.topics.length == 0) continue;
            if (g.emitter == address(controller) && g.topics[0] == LOSS_BURNED) {
                L.burned += abi.decode(g.data, (uint256));
            } else if (g.emitter == address(controller) && g.topics[0] == YIELD_MINTED) {
                L.yieldMinted += abi.decode(g.data, (uint256));
            } else if (g.emitter == address(usdfr) && g.topics[0] == ACCRUED_MINTED) {
                (uint256 senior, uint256 fee) = abi.decode(g.data, (uint256, uint256));
                L.accrualSenior += senior;
                L.accrualFee += fee;
            } else if (g.emitter == address(reserves) && g.topics[0] == ALIGNED) {
                (, uint256 correction, uint256 loss,) = abi.decode(g.data, (uint64, uint256, uint256, bool));
                L.corrections += correction;
                L.roundingLosses += loss;
                ++L.closures;
            }
        }
    }

    function _mintTracked(address who, uint256 usdcAmount) internal {
        L.userMinted += _mintFromUSDC(who, usdcAmount);
    }

    function _postFirstLossTracked(uint256 usdfrAmount) internal {
        _mintTracked(ops, usdfrAmount / SCALE);
        vm.startPrank(ops);
        usdfr.approve(address(curator), usdfrAmount);
        curator.postFirstLoss(FILM, usdfrAmount);
        vm.stopPrank();
    }

    function _fundCoverageTracked(uint256 usdfrAmount) internal {
        _mintTracked(ops, usdfrAmount / SCALE);
        vm.startPrank(ops);
        usdfr.approve(address(sGrove), usdfrAmount);
        sGrove.fundCoverage(usdfrAmount);
        vm.stopPrank();
    }

    function _fundFacility(uint256 principal, bytes32 borrowerId, uint256 term) internal returns (uint256 tokenId) {
        tokenId = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + term);
        bytes32 stateId = keccak256("US-GA");
        bytes32 ref = keccak256(abi.encode("R1-ucc", tokenId));
        _attestFilmGate(tokenId, borrowerId, stateId, principal, 7500, maturity, ref);
        vm.prank(ops);
        uint256 id = bridge.originate(ops, _forkTerms(borrowerId, stateId, principal, 7500, maturity, ref));
        require(id == tokenId, "R1: tokenId drift");
        vm.prank(ops);
        waterfall.fund(tokenId, principal / SCALE);
        ids.push(tokenId);
        assertEq(reserves.deployedTo(tokenId), principal, "funded at exactly the principal");
    }

    function _pay(uint256 id, uint256 interest, uint256 principal, string memory tag) internal {
        _settle(_prep(id, interest, principal, tag));
    }

    /// @dev Attests a receipt and funds the borrower; makes no call after the attestation so a
    ///      caller can arm `vm.expectEmit` immediately before `_settle`.
    function _prep(uint256 id, uint256 interest, uint256 principal, string memory tag)
        internal
        returns (IWaterfallEngine.Payment memory p)
    {
        uint256 stable = (interest + principal) / SCALE;
        require((interest + principal) % SCALE == 0, "R1: off-grid payment in test");
        deal(USDC, borrower, IERC20(USDC).balanceOf(borrower) + stable);
        vm.prank(borrower);
        IERC20(USDC).approve(address(reserves), stable);
        ClaimBridge.Facility memory f = bridge.facility(id);
        uint64 nextDue = f.nextPaymentDue + f.paymentInterval;
        if (nextDue > f.maturity) nextDue = f.maturity;
        bytes32 paymentId = keccak256(abi.encode(tag, id, interest, principal));
        _attest(
            id,
            IAttestationOracle.AttestationKind.PaymentReceived,
            keccak256(abi.encode(paymentId, id, USDC, borrower, stable, interest, principal, nextDue))
        );
        p = IWaterfallEngine.Payment({
            tokenId: id,
            paymentId: paymentId,
            payer: borrower,
            interest: interest,
            principal: principal,
            nextPaymentDue: nextDue
        });
    }

    function _settle(IWaterfallEngine.Payment memory p) internal {
        uint256 stable = (p.interest + p.principal) / SCALE;
        uint256 borrowerUSDC = IERC20(USDC).balanceOf(borrower);
        vm.prank(ops);
        waterfall.distribute(p);
        assertEq(borrowerUSDC - IERC20(USDC).balanceOf(borrower), stable, "exactly the attested USDC was pulled");
    }

    function _clearPastDue(uint256 id, bytes32 evidence) internal {
        _attest(id, IAttestationOracle.AttestationKind.PastDueCured, keccak256(abi.encode(id, evidence)));
        vm.prank(ops);
        defaultManager.clearPastDue(id, evidence);
    }

    function _model(uint256 id, uint256 principal, uint16 rate, uint64 periodStart)
        internal
        view
        returns (Model memory m)
    {
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
        m.terms = AccrualSegments.Terms({
            basis: principal,
            yearSeconds: YEAR,
            scale: SCALE,
            cap: d.balanceCeiling - principal,
            periodStart: periodStart,
            periodEnd: d.maturity,
            maturity: d.maturity,
            rateBps: rate
        });
        AccrualSegments.Segment memory seg = AccrualSegments.plan(m.terms, periodStart);
        require(seg.end > seg.start && seg.amount != 0, "R1: model segment is empty");
        m.start = seg.start;
        m.end = seg.end;
        m.segmentAmount = seg.amount;
        m.rate = seg.amount / (seg.end - seg.start);
        m.remainder = seg.amount % (seg.end - seg.start);
    }

    function _firstLossOffsetFrom(Model memory m, uint256 elapsed, uint256 first)
        internal
        pure
        returns (uint256 off, uint256 loss)
    {
        off = first | 1;
        for (uint256 i; i < 64; ++i) {
            uint256 full = Math.mulDiv(m.segmentAmount, elapsed + off, m.end - m.start);
            uint256 canonical = AccrualSegments.cumulative(m.terms, uint64(m.start + elapsed + off));
            if (full > canonical && full - canonical >= 1000) return (off, full - canonical);
            off += 2;
        }
        revert("R1: no offset with a rounding loss found");
    }

    function _firstCorrectionOffset(Model memory m, uint256 elapsed) internal pure returns (uint256 off) {
        off = 1;
        for (uint256 i; i < 4096; ++i) {
            uint256 full = Math.mulDiv(m.segmentAmount, elapsed + off, m.end - m.start);
            uint256 canonical = AccrualSegments.cumulative(m.terms, uint64(m.start + elapsed + off));
            if (canonical > full) return off;
            off += 2;
        }
        revert("R1: no offset with a positive correction found");
    }

    function _odd(uint256 i) internal pure returns (uint256) {
        return (uint256(keccak256(abi.encode("open-accounting-r1", i))) % 5 days) | 1;
    }

    function _warpTo(uint256 ts) internal {
        require(ts > block.timestamp, "R1: warpTo backwards");
        _warp(ts - block.timestamp);
    }
}
