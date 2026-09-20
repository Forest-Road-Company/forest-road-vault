// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IAccrualLifecycle} from "../../src/interfaces/IAccrualLifecycle.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {AccrualBook} from "../../src/libraries/AccrualBook.sol";
import {ReserveAccrualCreditLib} from "../../src/libraries/ReserveAccrualCreditLib.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @title OPEN_time_R2: round-two time and boundary attacks on the continuous-accrual engine,
///        executed against the full protocol on the pinned mainnet fork.
///
/// @notice Every prior fork suite drives a 365-day term, so the interior technical boundary that
///         AccrualSegments inserts every 365 days inside a LONGER contractual period, the successor
///         segment a late keeper opens at a HISTORICAL instant, and a PIK note whose signed interval
///         is longer than one technical segment were never executed on a fork. Those are the three
///         places a boundary can be recognised twice, skipped, or crossed late.
///
///         Invariants under attack (CLAUDE.md 1.3): I1 backing, I2 value conservation across
///         keeper cadence, I7 sUSDfr rate integrity (a stale frontier never quotes above fresh).
///
///         T1. A 730-day cash note. Four hundred days of neglect, then one permissionless catch-up
///             that processes the day-365 boundary late and opens its successor at the historical
///             instant, must land on the same wei as a weekly keeper and a keeper hitting the
///             boundary second and its neighbours. Then the cap binds at 730 days exactly.
///         T2. The annual coupon lands ON the boundary second (refused, nothing consumed), the same
///             receipt is admitted the same second after a checkpoint at exactly the contractual
///             coupon, or twelve seconds later with the closure discrepancy pinned to the segment
///             model; a declaration inside the second segment aligns to the closed form.
///         T3. A PIK note with a 400-day signed interval and a 730-day term: the technical boundary
///             at day 365 must capitalise nothing, the signed date at day 400 capitalises exactly
///             the telescoped 400-day coupon, maturity invents no compounding, and a single late
///             checkpoint at day 500 equals the step-by-step state. The stale bridge due date left
///             behind by the last capitalisation must not make the note markable before maturity.
contract OPEN_time_R2Test is ForkLifecycleFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    uint256 internal constant P = 1_000_000e18;
    uint256 internal constant RATE = 1400;
    uint256 internal constant YEAR = 360 days; // Actual/360
    uint256 internal constant TERM = 730 days;
    uint256 internal constant COUPON = 365 days; // annual coupon: the payment date IS the boundary
    uint256 internal constant TECH = 365 days; // AccrualSegments.MAX_SEGMENT_SECONDS
    uint256 internal constant SCALE = 1e12;

    uint256 internal constant PIK_P = 100_000e18;
    uint256 internal constant PIK_INTERVAL = 400 days; // longer than one technical segment
    uint256 internal constant PIK_TERM = 730 days; // one signed capitalisation, then a 330-day stub

    struct Reading {
        uint256 gross;
        uint256 unposted;
        uint256 principal;
        uint256 interest;
        uint256 face;
        uint256 recorded;
        uint256 backing;
        uint256 supply;
        uint256 assets;
        uint256 price;
        uint64 accruedThrough;
        bool fresh;
        bool active;
        bool scheduled;
    }

    // ---------------------------------------------------------------------
    // T1: interior technical boundary, crossed late, on time, and on the second (I2, I7)
    // ---------------------------------------------------------------------

    function test_atk_interiorTechnicalBoundary_lateCatchUpTelescopes() public onFork {
        (uint256 id, uint256 t0) = _fund730();
        uint256 base = vm.snapshotState();

        // (i) four hundred days of neglect. The frontier is pinned at the interior boundary and
        // every priced action refuses naming it; the stale quote carries no remainder.
        _warpTo(t0 + 400 days);
        _t1StaleAtInteriorBoundary(id, t0);
        (uint256 processed, bool fresh) = _checkpointAsCarol();
        assertEq(processed, 1, "one late boundary: the day-365 technical endpoint");
        assertTrue(fresh, "fresh after the catch-up");
        Reading memory late = _read(id);
        emit log_named_uint("T1 seg1 endpoint (canonical 365d)", _seg1());
        emit log_named_uint("T1 slope1 wei/s", _slope1());
        emit log_named_uint("T1 seg2 amount (canonical 730d-1 minus seg1)", _seg2());
        emit log_named_uint("T1 slope2 wei/s", _slope2());
        emit log_named_uint("T1 gross after late catch-up at day 400", late.gross);
        emit log_named_uint("T1 canonical interest at day 400", late.interest);
        emit log_named_uint("T1 backing at day 400", late.backing);
        emit log_named_uint("T1 supply at day 400", late.supply);
        emit log_named_uint("T1 price at day 400", late.price);
        assertEq(
            late.gross, _seg1() + _slope2() * 35 days, "successor opened at the historical boundary, not the clock"
        );
        assertEq(late.interest, _canon(400 days), "canonical interest at day 400");
        assertTrue(late.scheduled, "the successor segment is live");
        assertEq(late.supply, late.backing, "I1: supply and backing move together");

        // (ii) weekly keeper to the same instant.
        assertTrue(vm.revertToState(base), "revert");
        for (uint256 i = 1; i <= 57; ++i) {
            _warpTo(t0 + i * 7 days);
            _checkpointAsCarol();
        }
        _warpTo(t0 + 400 days);
        _checkpointAsCarol();
        Reading memory weekly = _read(id);

        // (iii) the boundary second and its neighbours.
        assertTrue(vm.revertToState(base), "revert");
        uint256[6] memory offsets = [TECH - 1, TECH, TECH + 1, TECH + 12, 399 days + 86_399, 400 days];
        for (uint256 i; i < offsets.length; ++i) {
            _warpTo(t0 + offsets[i]);
            (uint256 p,) = _checkpointAsCarol();
            assertEq(p, offsets[i] == TECH ? 1 : 0, "only the boundary second processes a boundary");
        }
        Reading memory jagged = _read(id);
        _assertSame(late, weekly, "late vs weekly");
        _assertSame(late, jagged, "late vs jagged");

        // (iv) on to maturity: the penultimate second, the cap, and nothing afterwards.
        _t1Maturity(id, t0);
    }

    function _t1StaleAtInteriorBoundary(uint256 id, uint256 t0) internal {
        uint64 boundary = uint64(t0 + TECH);
        IContinuousAccrual.Snapshot memory s = reserves.accrualSnapshot();
        assertFalse(s.fresh, "stale across the interior boundary");
        assertEq(s.accruedThrough, boundary, "frontier pinned at the interior boundary");
        assertEq(s.gross, _slope1() * TECH, "stale gross is the integer slope through the boundary, no remainder");
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
        assertEq(d.accruedThrough, boundary, "canonical debt capped at the same frontier");
        assertEq(d.interest, _seg1(), "canonical interest through the boundary");
        uint256 stalePrice = vault.convertToAssets(10 ** vault.decimals());
        emit log_named_uint("T1 stale gross at day 400 (frontier day 365)", s.gross);
        emit log_named_uint("T1 stale price", stalePrice);
        bytes memory pending =
            abi.encodeWithSelector(AccrualBook.AccrualBook_BoundaryPending.selector, boundary, uint64(block.timestamp));
        vm.startPrank(alice);
        usdfr.approve(address(vault), 1_000e18);
        vm.expectRevert(pending);
        vault.deposit(1_000e18, alice);
        IERC20(USDC).approve(address(controller), 1_000e6);
        vm.expectRevert(pending);
        controller.mint(1_000e6);
        vm.stopPrank();
        vm.prank(carol);
        vm.expectRevert(pending);
        reserves.materializeAccrued(3);
        // I7: after the catch-up the price is at least the stale one. Checked by the caller via
        // _read; recorded here so the comparison uses the pre-catch-up value.
        _t1StalePrice = stalePrice;
    }

    uint256 internal _t1StalePrice;

    function _t1Maturity(uint256 id, uint256 t0) internal {
        Reading memory afterCatchUp = _read(id);
        assertGe(afterCatchUp.price, _t1StalePrice, "I7: the stale frontier never quoted above fresh");

        _warpTo(t0 + TERM - 1);
        (uint256 p,) = _checkpointAsCarol();
        assertEq(p, 1, "the penultimate-second technical boundary");
        assertEq(reserves.accrualSnapshot().gross, _canon(TERM - 1), "endpoint at maturity minus one, exact");

        _warpTo(t0 + TERM);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccrualBoundaryProcessed(id, uint64(t0 + TERM), 0, 0, true);
        (p,) = _checkpointAsCarol();
        assertEq(p, 1, "the maturity boundary");
        Reading memory m = _read(id);
        emit log_named_uint("T1 cap (730d grid interest)", _cap());
        emit log_named_uint("T1 gross at maturity", m.gross);
        emit log_named_uint("T1 price at maturity", m.price);
        assertEq(m.gross, _cap(), "gross binds to the 730-day cap to the wei");
        assertEq(m.interest, _cap(), "canonical interest binds to the cap");
        assertEq(m.principal + m.interest, reserves.accruedDebt(id).balanceCeiling, "the ceiling binds exactly");
        assertFalse(m.active, "stopped at maturity");
        assertFalse(m.scheduled, "no segment survives maturity");
        assertEq(m.supply, m.backing, "I1 at maturity");

        _warpTo(t0 + TERM + 30 days);
        (p,) = _checkpointAsCarol();
        assertEq(p, 0, "nothing after maturity");
        assertEq(reserves.accrualSnapshot().gross, _cap(), "no recognition after maturity");
    }

    // ---------------------------------------------------------------------
    // T2: the coupon lands on the boundary second, and twelve seconds past it (I2, I1)
    // ---------------------------------------------------------------------

    function test_atk_receiptOnTheInteriorBoundarySecondAndTwelveSecondsPast() public onFork {
        (uint256 id, uint256 t0) = _fund730();
        _warpTo(t0 + TECH);
        uint64 b = uint64(block.timestamp);
        IWaterfallEngine.Payment memory coupon = _prepInterestPayment(id, _seg1(), uint64(t0 + TERM));

        // ATTACK: settle the annual coupon on the boundary second before the keeper.
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_BoundaryPending.selector, b, b));
        waterfall.distribute(coupon);
        assertEq(reserves.deployedTo(id), P + _slope1() * TECH, "the refusal consumed nothing");
        assertEq(reserves.accruedDebt(id).interest, _seg1(), "canonical unchanged by the refusal");

        (uint256 p,) = _checkpointAsCarol();
        assertEq(p, 1, "boundary processed on its second");
        uint256 mid = vm.snapshotState();

        _t2SameSecond(id, t0, b, coupon);
        assertTrue(vm.revertToState(mid), "revert to the processed boundary");
        _t2TwelveSecondsLater(id, t0, b, coupon);
    }

    /// @dev Same second, after the keeper: admitted at exactly the coupon, zero discrepancy, and the
    ///      note continues on the SAME curve (anchor preserved, cap expanded, so the cap is no longer
    ///      reachable and the next boundary is maturity itself, not maturity minus one).
    function _t2SameSecond(uint256 id, uint256 t0, uint64 b, IWaterfallEngine.Payment memory coupon) internal {
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccrualLoanAligned(id, 1, b, 0, 0, false);
        vm.prank(ops);
        waterfall.distribute(coupon);
        Reading memory a = _read(id);
        assertEq(a.interest, 0, "the coupon discharged exactly the contractual year");
        assertEq(a.face, P, "face back to principal");
        assertEq(a.recorded, P, "recorded face back to principal");
        assertEq(a.unposted, 0, "nothing unposted after the receipt");
        assertTrue(a.scheduled && a.active, "continues accruing");
        assertEq(a.supply, a.backing, "I1 after the receipt");

        _warpTo(t0 + TERM - 1);
        assertTrue(reserves.accrualSnapshot().fresh, "no penultimate-second boundary once the cap is unreachable");
        assertEq(reserves.accruedDebt(id).interest, _canon(TERM - 1) - _seg1(), "same curve, second year");
        _warpTo(t0 + TERM);
        assertFalse(reserves.accrualSnapshot().fresh, "maturity is the boundary");
        (uint256 p,) = _checkpointAsCarol();
        assertEq(p, 1, "maturity processed");
        Reading memory m = _read(id);
        assertEq(m.interest, _cap() - _seg1(), "second-year interest is the cap minus the coupon");
        assertEq(m.face, P + _cap() - _seg1(), "face at maturity");
        assertFalse(m.active, "stopped at maturity");
        assertEq(m.supply, m.backing, "I1 at maturity");
    }

    /// @dev Twelve seconds later: the coupon is still admitted, the residual is exactly the twelve
    ///      grid-floored seconds, and the closure discrepancy is pinned to the segment model.
    function _t2TwelveSecondsLater(uint256 id, uint256 t0, uint64 b, IWaterfallEngine.Payment memory coupon) internal {
        _warp(12);
        (uint256 corr, uint256 loss) = _discrepancy(_seg2(), TERM - 1 - TECH, 12, _canon(TECH + 12) - _seg1());
        emit log_named_uint("T2 12s canonical residual", _canon(TECH + 12) - _seg1());
        emit log_named_uint("T2 12s recognized (interpolation)", Math.mulDiv(_seg2(), 12, TERM - 1 - TECH));
        emit log_named_uint("T2 12s positive correction", corr);
        emit log_named_uint("T2 12s rounding loss", loss);
        assertTrue(corr <= SCALE && loss < SCALE, "model: discrepancy inside one reserve unit");
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccrualLoanAligned(id, 1, b + 12, corr, loss, false);
        vm.prank(ops);
        waterfall.distribute(coupon);
        Reading memory r = _read(id);
        assertEq(r.interest, _canon(TECH + 12) - _seg1(), "residual is twelve seconds of grid interest");
        assertEq(r.face, P + r.interest, "face is principal plus the residual");
        assertEq(r.recorded, r.face, "everything posted at the receipt");
        assertEq(r.supply, r.backing, "I1 after the late-landing receipt");

        // Declaration inside the second segment, at day 500, aligns to the closed form.
        _warpTo(t0 + 500 days);
        uint256 dur = TERM - TECH - 12;
        uint256 amount = _cap() - _canon(TECH + 12);
        (corr, loss) = _discrepancy(amount, dur, 500 days - TECH - 12, _canon(500 days) - _canon(TECH + 12));
        emit log_named_uint("T2 declare canonical since receipt", _canon(500 days) - _canon(TECH + 12));
        emit log_named_uint("T2 declare recognized", Math.mulDiv(amount, 500 days - TECH - 12, dur));
        emit log_named_uint("T2 declare positive correction", corr);
        emit log_named_uint("T2 declare rounding loss", loss);
        bytes32 evidence = keccak256("open-time-r2-declare");
        _attest(id, IAttestationOracle.AttestationKind.DefaultDeclared, keccak256(abi.encode(id, evidence)));
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccrualLoanAligned(id, 2, uint64(t0 + 500 days), corr, loss, true);
        vm.prank(ops);
        defaultManager.declareDefault(id, evidence);
        Reading memory d = _read(id);
        emit log_named_uint("T2 declared face", d.face);
        emit log_named_uint("T2 declared interest", d.interest);
        emit log_named_uint("T2 backing after declaration", d.backing);
        emit log_named_uint("T2 supply after declaration", d.supply);
        assertEq(d.interest, _canon(500 days) - _seg1(), "unpaid interest at declaration: canonical minus the coupon");
        assertEq(d.face, P + d.interest, "posted face at declaration");
        assertEq(d.unposted, 0, "nothing unposted after declaration");
        assertFalse(d.active, "stopped at declaration");
        assertEq(d.supply, d.backing, "I1 after declaration");
    }

    // ---------------------------------------------------------------------
    // T3: a PIK signed interval longer than one technical segment (I2, I1)
    // ---------------------------------------------------------------------

    function test_atk_pikSignedIntervalLongerThanATechnicalSegment() public onFork {
        (uint256 id, uint256 t0) = _fundPik400();
        uint256 base = vm.snapshotState();
        uint256 c1 = _pcum(PIK_P, PIK_INTERVAL);

        // Step by step: technical boundary (no capitalisation), signed date (exact coupon), stub.
        _warpTo(t0 + TECH);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccrualBoundaryProcessed(id, uint64(t0 + TECH), 0, 0, false);
        (uint256 p,) = _checkpointAsCarol();
        assertEq(p, 1, "technical boundary at day 365");
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
        assertEq(d.principal, PIK_P, "a technical boundary never capitalises");
        assertEq(d.interest, _pcum(PIK_P, TECH), "canonical interest at day 365");
        assertEq(d.nextCapitalization, t0 + PIK_INTERVAL, "signed date untouched");

        _warpTo(t0 + PIK_INTERVAL);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccrualBoundaryProcessed(id, uint64(t0 + PIK_INTERVAL), c1, 0, false);
        (p,) = _checkpointAsCarol();
        assertEq(p, 1, "signed capitalisation at day 400");
        d = reserves.accruedDebt(id);
        assertEq(d.principal, PIK_P + c1, "capitalised exactly the telescoped 400-day coupon");
        assertEq(d.interest, 0, "no interest survives the capitalisation");
        assertEq(d.nextCapitalization, 0, "no further signed date fits before maturity");
        assertTrue(d.active, "the stub keeps accruing");
        assertEq(bridge.facility(id).nextPaymentDue, t0 + PIK_INTERVAL, "the bridge keeps the last signed date");
        _t3NotMarkableOnTheStaleBridgeDate(id, t0);

        _warpTo(t0 + PIK_TERM);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccrualBoundaryProcessed(id, uint64(t0 + PIK_TERM), 0, 0, true);
        (p,) = _checkpointAsCarol();
        assertEq(p, 1, "maturity");
        Reading memory stepwise = _read(id);
        emit log_named_uint("T3 ceiling", reserves.accruedDebt(id).balanceCeiling);
        emit log_named_uint("T3 coupon c1 (400d)", c1);
        emit log_named_uint("T3 principal at maturity", stepwise.principal);
        emit log_named_uint("T3 stub interest at maturity", stepwise.interest);
        emit log_named_uint("T3 gross at maturity", stepwise.gross);
        assertEq(stepwise.principal, PIK_P + c1, "maturity invents no compounding");
        assertEq(
            stepwise.interest, _pcum(PIK_P + c1, PIK_TERM - PIK_INTERVAL), "stub interest on the capitalised basis"
        );
        assertLe(stepwise.principal + stepwise.interest, reserves.accruedDebt(id).balanceCeiling, "under the ceiling");
        assertEq(stepwise.gross, c1 + stepwise.interest, "book gross equals the two canonical legs");
        assertFalse(stepwise.active, "stopped at maturity");
        assertEq(stepwise.supply, stepwise.backing, "I1 at maturity");

        // One late checkpoint at day 500 crosses both boundaries and equals the step-by-step state.
        assertTrue(vm.revertToState(base), "revert");
        _warpTo(t0 + 500 days);
        bool fresh;
        (p, fresh) = _checkpointAsCarol();
        assertEq(p, 2, "both boundaries in one call");
        assertTrue(fresh, "fresh after the catch-up");
        Reading memory lateAt500 = _read(id);
        assertTrue(vm.revertToState(base), "revert");
        _warpTo(t0 + TECH);
        _checkpointAsCarol();
        _warpTo(t0 + PIK_INTERVAL);
        _checkpointAsCarol();
        _warpTo(t0 + 500 days);
        _checkpointAsCarol();
        Reading memory stepAt500 = _read(id);
        _assertSame(lateAt500, stepAt500, "pik late vs stepwise at day 500");
        assertEq(stepAt500.principal, PIK_P + c1, "capitalised basis at day 500");
        assertEq(stepAt500.interest, _pcum(PIK_P + c1, 100 days), "stub canonical at day 500");
        _warpTo(t0 + PIK_TERM);
        _checkpointAsCarol();
        _assertSame(_read(id), stepwise, "pik late vs stepwise at maturity");
    }

    /// @dev The bridge's nextPaymentDue stays at the last signed date once no further
    ///      capitalisation fits. That stale date must not open a past-due mark: the manager
    ///      substitutes legal maturity as the balloon deadline.
    function _t3NotMarkableOnTheStaleBridgeDate(uint256 id, uint256 t0) internal {
        uint64 grace = defaultManager.graceWindow(FILM);
        uint256 s = vm.snapshotState();
        _warpTo(t0 + PIK_INTERVAL + grace + 1);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_NotPastDue.selector,
                id,
                uint64(t0 + PIK_TERM),
                uint64(t0 + PIK_TERM) + grace
            )
        );
        defaultManager.markPastDue(id);
        assertTrue(vm.revertToState(s), "revert");
    }

    // ---------------------------------------------------------------------
    // fixtures and closed forms
    // ---------------------------------------------------------------------

    /// @dev 1,000,000 at 14% Actual/360, annual coupon, 730-day term.
    function _fund730() internal returns (uint256 id, uint256 t0) {
        _mintFromUSDC(alice, 3_000_000e6);
        _stake(alice, 2_000_000e18);
        t0 = block.timestamp;
        ClaimBridge.OriginationTerms memory t = _forkTermsFor(
            FILM,
            keccak256("R2_BORROWER"),
            keccak256("US-GA"),
            P,
            7500,
            uint16(RATE),
            uint64(t0 + TERM),
            keccak256("r2-730")
        );
        t.paymentInterval = uint64(COUPON);
        t.nextPaymentDue = uint64(t0 + COUPON);
        id = _originateCustom(t);
        vm.prank(ops);
        waterfall.fund(id, P / SCALE);
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
        assertEq(d.principal, P, "registered");
        assertEq(d.balanceCeiling, P + _cap(), "cash ceiling is principal plus the 730-day grid interest");
        assertTrue(d.active, "accruing");
    }

    /// @dev 100,000 PIK at 14% Actual/360, one 400-day signed period, 730-day term.
    function _fundPik400() internal returns (uint256 id, uint256 t0) {
        _mintFromUSDC(alice, 1_000_000e6);
        _stake(alice, 600_000e18);
        t0 = block.timestamp;
        ClaimBridge.OriginationTerms memory t = _forkTermsFor(
            FILM,
            keccak256("R2_PIK_BORROWER"),
            keccak256("US-GA"),
            PIK_P,
            7500,
            uint16(RATE),
            uint64(t0 + PIK_TERM),
            keccak256("r2-pik-400")
        );
        t.pik = true;
        t.paymentInterval = uint64(PIK_INTERVAL);
        t.nextPaymentDue = uint64(t0 + PIK_INTERVAL);
        id = _originateCustom(t);
        vm.prank(ops);
        waterfall.fund(id, PIK_P / SCALE);
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
        assertEq(d.principal, PIK_P, "registered");
        assertEq(d.balanceCeiling, _pikCeiling400(), "the AccrualCeiling.pik reservation, derived by hand");
        assertEq(d.nextCapitalization, t0 + PIK_INTERVAL, "first signed date");
        assertTrue(d.pik && d.active, "accruing PIK");
    }

    function _originateCustom(ClaimBridge.OriginationTerms memory t) internal returns (uint256 id) {
        id = bridge.totalOriginated() + 1;
        bytes32 termsHash = bridge.creditTermsHash(t);
        _attest(id, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash);
        _attest(id, IAttestationOracle.AttestationKind.UCCFiled, termsHash);
        _attest(id, IAttestationOracle.AttestationKind.CreditIssued, termsHash);
        vm.prank(ops);
        uint256 minted = bridge.originate(ops, t);
        assertEq(minted, id, "facility id");
    }

    /// @dev The contractual grid cap of the 730-day cash note.
    function _cap() internal pure returns (uint256) {
        return Math.mulDiv(P * RATE, TERM, YEAR * 10_000 * SCALE) * SCALE;
    }

    /// @dev Canonical grid-floored cumulative interest on the frozen basis after `elapsed` seconds.
    function _canon(uint256 elapsed) internal pure returns (uint256) {
        uint256 exact = Math.mulDiv(P, RATE * elapsed, 10_000 * YEAR);
        uint256 cap = _cap();
        if (exact > cap) exact = cap;
        return exact / SCALE * SCALE;
    }

    /// @dev First technical segment [t0, t0 + 365d]: its endpoint and integer slope.
    function _seg1() internal pure returns (uint256) {
        return _canon(TECH);
    }

    function _slope1() internal pure returns (uint256) {
        return _seg1() / TECH;
    }

    /// @dev Second technical segment [t0 + 365d, maturity - 1] on the untouched curve.
    function _seg2() internal pure returns (uint256) {
        return _canon(TERM - 1) - _seg1();
    }

    function _slope2() internal pure returns (uint256) {
        return _seg2() / (TERM - 1 - TECH);
    }

    /// @dev AccrualLoans._close: recognised is the linear interpolation of the segment endpoint
    ///      (integer slope plus the interpolated remainder); canonical is the grid curve. Returns
    ///      the positive correction or the rounding loss, exactly one of which is nonzero or both zero.
    function _discrepancy(uint256 amount, uint256 duration, uint256 elapsed, uint256 canonical)
        internal
        pure
        returns (uint256 corr, uint256 loss)
    {
        uint256 recognized = Math.mulDiv(amount, elapsed, duration);
        if (canonical > recognized) corr = canonical - recognized;
        else loss = recognized - canonical;
    }

    /// @dev Grid-floored cumulative interest on `basis` after `elapsed` seconds (PIK period curve,
    ///      cap never binding on these terms).
    function _pcum(uint256 basis, uint256 elapsed) internal pure returns (uint256) {
        return Math.mulDiv(basis, RATE * elapsed, 10_000 * YEAR) / SCALE * SCALE;
    }

    /// @dev AccrualCeiling.pik for the 400-day note: the first coupon rounded up to the grid, no
    ///      compounding successor (330 days remain, fewer than one interval), then the stub rounded up.
    function _pikCeiling400() internal pure returns (uint256 ceiling) {
        uint256 denominator = 10_000 * YEAR;
        ceiling = PIK_P + Math.mulDiv(PIK_P, RATE * PIK_INTERVAL, denominator * SCALE, Math.Rounding.Ceil) * SCALE;
        uint256 stub = PIK_TERM - PIK_INTERVAL;
        ceiling += Math.mulDiv(ceiling, RATE * stub, denominator, Math.Rounding.Ceil);
    }

    function _warpTo(uint256 ts) internal {
        require(ts > block.timestamp, "R2: warp must move forward");
        _warp(ts - block.timestamp);
    }

    function _checkpointAsCarol() internal returns (uint256 processed, bool fresh) {
        vm.prank(carol);
        return reserves.checkpointAccrual(32);
    }

    function _read(uint256 id) internal view returns (Reading memory r) {
        IContinuousAccrual.Snapshot memory s = reserves.accrualSnapshot();
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
        r.gross = s.gross;
        r.unposted = s.unposted;
        r.accruedThrough = s.accruedThrough;
        r.fresh = s.fresh;
        r.principal = d.principal;
        r.interest = d.interest;
        r.active = d.active;
        r.face = reserves.deployedTo(id);
        r.recorded = r.face - reserves.unpostedAccruedLoan(id);
        r.backing = reserves.totalBackingValue();
        r.supply = controller.totalUSDfr();
        r.assets = vault.totalAssets();
        r.price = vault.convertToAssets(10 ** vault.decimals());
        r.scheduled = reserves.accrualLoanScheduled(id);
    }

    function _assertSame(Reading memory a, Reading memory b, string memory ctx) internal pure {
        assertEq(a.gross, b.gross, string.concat(ctx, ": gross"));
        assertEq(a.unposted, b.unposted, string.concat(ctx, ": unposted"));
        assertEq(a.principal, b.principal, string.concat(ctx, ": principal"));
        assertEq(a.interest, b.interest, string.concat(ctx, ": interest"));
        assertEq(a.face, b.face, string.concat(ctx, ": face"));
        assertEq(a.recorded, b.recorded, string.concat(ctx, ": recorded"));
        assertEq(a.backing, b.backing, string.concat(ctx, ": backing"));
        assertEq(a.supply, b.supply, string.concat(ctx, ": supply"));
        assertEq(a.assets, b.assets, string.concat(ctx, ": assets"));
        assertEq(a.price, b.price, string.concat(ctx, ": price"));
        assertEq(uint256(a.accruedThrough), uint256(b.accruedThrough), string.concat(ctx, ": frontier"));
        assertEq(a.fresh, b.fresh, string.concat(ctx, ": fresh"));
        assertEq(a.active, b.active, string.concat(ctx, ": active"));
        assertEq(a.scheduled, b.scheduled, string.concat(ctx, ": scheduled"));
    }

    /// @dev An attested interest-only receipt, not yet distributed, with the next due date given.
    function _prepInterestPayment(uint256 tokenId, uint256 interest, uint64 nextDue)
        internal
        returns (IWaterfallEngine.Payment memory p)
    {
        uint256 stableAmount = interest / SCALE;
        deal(USDC, borrower, IERC20(USDC).balanceOf(borrower) + stableAmount);
        vm.prank(borrower);
        IERC20(USDC).approve(address(reserves), stableAmount);
        bytes32 paymentId = keccak256(abi.encode("open-time-r2-coupon", tokenId, interest));
        _attest(
            tokenId,
            IAttestationOracle.AttestationKind.PaymentReceived,
            keccak256(abi.encode(paymentId, tokenId, USDC, borrower, stableAmount, interest, uint256(0), nextDue))
        );
        p = IWaterfallEngine.Payment({
            tokenId: tokenId,
            paymentId: paymentId,
            payer: borrower,
            interest: interest,
            principal: 0,
            nextPaymentDue: nextDue
        });
    }
}
