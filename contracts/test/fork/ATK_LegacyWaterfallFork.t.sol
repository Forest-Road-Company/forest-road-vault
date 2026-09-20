// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {WaterfallEngine} from "../../src/WaterfallEngine.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {WaterfallAccrualLib} from "../../src/libraries/WaterfallAccrualLib.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title ATK_LegacyWaterfallFork: the servicing path the live mainnet deployment actually runs
/// @notice Every other fork suite binds and enables the continuous accrual engine in `setUp`. The
///         mainnet deployment (`edf525c`) never did: the reserve is unconfigured, no consumer is
///         bound, and `WaterfallEngine` takes the LEGACY branch of `distribute`, `capitalizePik`
///         and `planPik` on every call. This fixture reproduces that state by overriding the
///         deploy script's accrual wiring hook to do nothing, then attacks the legacy planner
///         (`WaterfallAccrualLib.planLegacyPik` / `pendingLegacyPik`), the legacy receipt
///         settlement (`_settleReceipt` after the continuous early return, `_routeInterest`, the
///         ADV-1 withholding) and the permissionless PIK crank, as `carol` wherever the surface is
///         permissionless and as the named role where it is not.
///
/// @dev Findings already recorded in `STATE.md` ("Round four" and "THE PIK LIVENESS FAMILY") are
///      not re-asserted here. Where a test walks through one of them to reach a branch (for
///      example the terminal-period clock desync), the assertion is the branch, not the finding.
contract ATK_LegacyWaterfallForkTest is ForkLifecycleFixture {
    uint256 internal constant P = 1_000_000e18;
    uint16 internal constant RATE = 1400;
    uint64 internal constant INTERVAL = 30 days;
    uint64 internal constant GRACE = 21 days; // Config.DEFAULT_REDEEM_COOLDOWN, the class default
    uint256 internal constant GRID = 1e12;
    uint256 internal constant CLASS = Config.CLASS_FILM_TAX_CREDITS;

    /// @dev Closed-form legacy coupons on 1,000,000e18 at 1400 bps, Actual/360, 30-day periods,
    ///      floored to the USDC grid, compounding on the grown balance. Pinned as literals so a
    ///      planner mutation cannot move the expectation with it.
    uint256 internal constant C1 = 11_666_666_666_000_000_000_000;
    uint256 internal constant C2 = 11_802_777_777_000_000_000_000;
    uint256 internal constant C3 = 11_940_476_851_000_000_000_000;
    uint256 internal constant SIX_PERIOD_BALANCE = 1_072_073_705_115_000_000_000_000;
    /// @dev First coupon of a facility funded one day AFTER origination: 29 days, not 30, because the
    ///      first period accrues from funding (Forest Road, 2026-09-10) while the schedule anchor stays.
    uint256 internal constant C1_29D = 11_277_777_777_000_000_000_000;

    /// @dev THE LEGACY FIXTURE. Nothing bound, nothing enabled: the mainnet shape.
    function _wireContinuousAccrual(D memory) internal override {}

    function setUp() public override {
        super.setUp();
        if (!forkReady) return;
        IContinuousAccrual.Snapshot memory s = reserves.accrualSnapshot();
        require(!s.enabled, "legacy fixture: continuous accrual must be disabled");
        require(waterfall.accrualReserve() == address(0), "legacy fixture: the waterfall must report the legacy route");
        require(reserves.accrualModules().token == address(0), "legacy fixture: the reserve must be unconfigured");
        _mintFromUSDC(alice, 4_000_000e6);
        _stake(alice, 1_000_000e18);
    }

    // ── helpers ──────────────────────────────────────────────────────────

    function _terms(uint256 principal, uint64 interval, uint64 maturity, bool pik, bytes32 salt)
        internal
        view
        returns (ClaimBridge.OriginationTerms memory t)
    {
        t = _forkTermsFor(
            CLASS,
            keccak256(abi.encode("legacy-borrower", salt)),
            keccak256("US-GA"),
            principal,
            7500,
            RATE,
            maturity,
            salt
        );
        t.pik = pik;
        t.paymentInterval = interval;
        t.nextPaymentDue = uint64(block.timestamp) + interval;
    }

    function _originate(ClaimBridge.OriginationTerms memory t) internal returns (uint256 id) {
        id = bridge.totalOriginated() + 1;
        bytes32 h = bridge.creditTermsHash(t);
        _attest(id, IAttestationOracle.AttestationKind.AssignmentExecuted, h);
        _attest(id, IAttestationOracle.AttestationKind.UCCFiled, h);
        _attest(id, IAttestationOracle.AttestationKind.CreditIssued, h);
        vm.prank(ops);
        require(bridge.originate(ops, t) == id, "legacy fixture: tokenId drift");
    }

    function _fund(uint256 id, uint256 principal) internal {
        vm.prank(ops);
        waterfall.fund(id, principal / GRID);
    }

    function _pik(uint256 principal, uint64 maturityIn, bytes32 salt) internal returns (uint256 id) {
        id = _originate(_terms(principal, INTERVAL, uint64(block.timestamp) + maturityIn, true, salt));
        _fund(id, principal);
    }

    function _cash(uint256 principal, bytes32 salt) internal returns (uint256 id) {
        id = _originate(_terms(principal, INTERVAL, uint64(block.timestamp + 365 days), false, salt));
        _fund(id, principal);
    }

    /// @dev Attest a receipt with ARBITRARY legs (the fixture's `_repay` derives its own), funding
    ///      the borrower so the cash can land if the engine accepts it.
    function _attestReceipt(uint256 id, uint256 interest, uint256 principal, uint64 nextDue, bytes32 salt)
        internal
        returns (IWaterfallEngine.Payment memory p)
    {
        uint256 stable = (interest + principal) / GRID;
        deal(USDC, borrower, IERC20(USDC).balanceOf(borrower) + stable);
        vm.prank(borrower);
        IERC20(USDC).approve(address(reserves), stable);
        p = IWaterfallEngine.Payment({
            tokenId: id,
            paymentId: keccak256(abi.encode("legacy-receipt", id, interest, principal, salt)),
            payer: borrower,
            interest: interest,
            principal: principal,
            nextPaymentDue: nextDue
        });
        _attest(
            id,
            IAttestationOracle.AttestationKind.PaymentReceived,
            keccak256(abi.encode(p.paymentId, id, USDC, borrower, stable, interest, principal, nextDue))
        );
    }

    function _distribute(IWaterfallEngine.Payment memory p) internal {
        vm.prank(ops);
        waterfall.distribute(p);
    }

    function _nextDueAfter(uint256 id) internal view returns (uint64) {
        ClaimBridge.Facility memory f = bridge.facility(id);
        return f.nextPaymentDue + f.paymentInterval;
    }

    function _state(uint256 id) internal view returns (uint8) {
        return uint8(bridge.facility(id).state);
    }

    function _surplus() internal view returns (uint256) {
        return reserves.totalBackingValue() - usdfr.totalSupply();
    }

    /// @dev Every permissionless PIK entry point, driven by carol with the same hostile id.
    function _expectAllPikEntriesRevert(uint256 id, bytes memory err) internal {
        vm.prank(carol);
        vm.expectRevert(err);
        waterfall.capitalizePik(id);
        vm.prank(carol);
        vm.expectRevert(err);
        waterfall.planPik(id);
        vm.prank(carol);
        vm.expectRevert(err);
        waterfall.pikCrankIsDue(id);
        vm.prank(carol);
        vm.expectRevert(err);
        waterfall.pikCrankBlockedByProtocol(id);
    }

    function _expectCrankRefused(uint256 id, bytes memory err) internal {
        vm.prank(carol);
        vm.expectRevert(err);
        waterfall.capitalizePik(id);
        vm.prank(carol);
        vm.expectRevert(err);
        waterfall.planPik(id);
    }

    // ═════════════════════════════════════════════════════════════════════
    // 1. ADV-1 on the path that is live: the protocol fee is withheld ahead of the senior residual
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Facility A is in declared default with its whole face standing as an unabsorbed
    ///         senior residual (no curator first-loss, no sGROVE coverage). Facility B pays cash
    ///         interest. On the legacy route `_routeInterest` -> `_withholdFeeForSeniorImpairment`
    ///         withholds `min(feeGross, residual)` from the OUT-OF-CASCADE fee recipient, leaves
    ///         the vault leg untouched, and retains the withheld cash as backing. Both arms of the
    ///         ceiling are measured: a fee below the residual is withheld whole; a fee above it is
    ///         cut to exactly the residual. The residual itself never falls, so a second receipt
    ///         withholds again (the disclosed over-withholding), measured here as a cumulative
    ///         6,000e18 retained against a 5,000e18 residual.
    function test_atk_legacy_adv1WithholdsTheFeeAheadOfTheSeniorResidual() public onFork {
        uint256 a = _cash(5_000e18, "A");
        uint256 b = _cash(P, "B");
        _declareDefault(a, keccak256("legacy-default-A"));

        assertEq(curator.poolBalance(CLASS), 0, "premise: no curator first-loss in the fixture");
        assertEq(sGrove.coverageCapacity(), 0, "premise: no sGROVE coverage in the fixture");
        uint256 residual = defaultManager.pendingSeniorImpairment();
        assertEq(residual, 5_000e18, "legacy route: ConservativeImpairmentMath marks the declared face at full weight");
        assertEq(controller.recognizedDeficit(), 0, "a DECLARED default is invisible to the R16-M5 headroom clamp");

        uint256 feeBefore = usdfr.balanceOf(ops); // ops is the fee recipient
        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        uint256 surplusBefore = _surplus();

        // receipt 1: 10,000e18 interest. feeGross 1,000e18 < residual 5,000e18: withheld whole.
        IWaterfallEngine.Payment memory p = _attestReceipt(b, 10_000e18, 0, _nextDueAfter(b), "r1");
        vm.expectEmit(address(waterfall));
        emit IWaterfallEngine.ProtocolFeeWithheldForSeniorImpairment(1_000e18, 5_000e18);
        vm.expectEmit(address(waterfall));
        emit IWaterfallEngine.Distributed(b, p.paymentId, borrower, 10_000e18, 0, 0, 9_000e18);
        _distribute(p);
        assertEq(usdfr.balanceOf(ops) - feeBefore, 0, "fee recipient is paid NOTHING while the residual stands");
        assertEq(usdfr.balanceOf(address(vault)) - vaultBefore, 9_000e18, "the vault leg is bit-for-bit untouched");
        assertEq(_surplus() - surplusBefore, 1_000e18, "the withheld fee is retained as backing, not redirected");
        assertEq(defaultManager.pendingSeniorImpairment(), 5_000e18, "withholding does not reduce the residual");

        // receipt 2: 100,000e18 interest. feeGross 10,000e18 > residual 5,000e18: cut to the residual.
        p = _attestReceipt(b, 100_000e18, 0, _nextDueAfter(b), "r2");
        vm.expectEmit(address(waterfall));
        emit IWaterfallEngine.ProtocolFeeWithheldForSeniorImpairment(5_000e18, 5_000e18);
        vm.expectEmit(address(waterfall));
        emit IWaterfallEngine.Distributed(b, p.paymentId, borrower, 100_000e18, 0, 5_000e18, 90_000e18);
        _distribute(p);
        assertEq(usdfr.balanceOf(ops) - feeBefore, 5_000e18, "the residual is a CEILING on the fee, not a cliff");
        assertEq(
            usdfr.balanceOf(address(vault)) - vaultBefore, 99_000e18, "9,000 + 90,000: senior income never withheld"
        );
        assertEq(_surplus() - surplusBefore, 6_000e18, "two receipts withhold 6,000e18 against a 5,000e18 residual");
        assertEq(defaultManager.pendingSeniorImpairment(), 5_000e18);

        // The continuous engine retired this ceiling (results doc section 5); here it is what runs.
        emit log_named_uint("legacy ADV-1: senior residual (e18)", residual / 1e18);
        emit log_named_uint("legacy ADV-1: fee withheld, receipt 1 (e18)", 1_000);
        emit log_named_uint("legacy ADV-1: fee withheld, receipt 2 (e18)", 5_000);
        emit log_named_uint("legacy ADV-1: fee paid, receipt 2 (e18)", 5_000);
    }

    // ═════════════════════════════════════════════════════════════════════
    // 2. Receipt legs on the legacy path are bounded by the book, not by any planner
    // ═════════════════════════════════════════════════════════════════════

    /// @notice `Waterfall_PrincipalExceedsOutstanding` is dead in continuous mode (the engine's
    ///         `AccrualLoans_PaymentAboveDebt` fires first) and live here. The interest leg of a
    ///         cash-pay facility has NO planner bound on the legacy route: an attested leg 85x
    ///         the contractual coupon is minted in full, so the attestation is the only ceiling.
    ///         A PIK facility refuses any cash interest at all. Carol reaches neither servicing
    ///         entry point.
    function test_atk_legacy_receiptLegsAreBoundedByTheBookNotAPlanner() public onFork {
        uint256 c = _cash(P, "C");
        uint256 d = _pik(P, 365 days, "D");

        // carol: no SERVICER_ROLE, no fund, no distribute
        IWaterfallEngine.Payment memory p;
        p.tokenId = c;
        p.principal = GRID;
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.SERVICER_ROLE)
        );
        waterfall.distribute(p);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.SERVICER_ROLE)
        );
        waterfall.fund(c, 1);

        // principal one grid unit above the book: the waterfall's own check fires with the book's number
        uint256 snap = vm.snapshotState();
        p = _attestReceipt(c, 0, P + GRID, 0, "over");
        vm.expectRevert(
            abi.encodeWithSelector(IWaterfallEngine.Waterfall_PrincipalExceedsOutstanding.selector, c, P + GRID, P)
        );
        _distribute(p);
        assertEq(reserves.deployedTo(c), P, "a refused receipt moves nothing");
        vm.revertToState(snap);

        // interest 1,000,000e18 (85.7 contractual coupons) plus 400,000e18 principal: accepted in full
        uint256 feeBefore = usdfr.balanceOf(ops);
        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        uint256 surplusBefore = _surplus();
        p = _attestReceipt(c, 1_000_000e18, 400_000e18, _nextDueAfter(c), "huge");
        vm.expectEmit(address(waterfall));
        emit IWaterfallEngine.Distributed(c, p.paymentId, borrower, 1_000_000e18, 400_000e18, 100_000e18, 900_000e18);
        _distribute(p);
        assertEq(usdfr.balanceOf(ops) - feeBefore, 100_000e18, "10% fee on the whole attested leg");
        assertEq(usdfr.balanceOf(address(vault)) - vaultBefore, 900_000e18, "90% to the senior vault");
        assertEq(_surplus(), surplusBefore, "interest == fee + toVault + 0 withheld: exact conservation");
        assertEq(reserves.deployedTo(c), 600_000e18);
        assertEq(_state(c), uint8(ClaimBridge.LoanState.Amortizing));

        // the bound follows the book down
        snap = vm.snapshotState();
        p = _attestReceipt(c, 0, 600_000e18 + GRID, 0, "over2");
        vm.expectRevert(
            abi.encodeWithSelector(
                IWaterfallEngine.Waterfall_PrincipalExceedsOutstanding.selector, c, 600_000e18 + GRID, 600_000e18
            )
        );
        _distribute(p);
        vm.revertToState(snap);

        // a PIK facility takes no cash interest, not even one grid unit
        snap = vm.snapshotState();
        p = _attestReceipt(d, GRID, 0, _nextDueAfter(d), "pik-cash");
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikCashInterestNotPermitted.selector, d));
        _distribute(p);
        vm.revertToState(snap);

        // both legs zero: refused before the attestation is even read
        p.tokenId = c;
        p.interest = 0;
        p.principal = 0;
        vm.expectRevert(IWaterfallEngine.Waterfall_ZeroAmount.selector);
        _distribute(p);

        // exact payoff closes; anything after is not distributable
        _distribute(_attestReceipt(c, 0, 600_000e18, 0, "close"));
        assertEq(_state(c), uint8(ClaimBridge.LoanState.Repaid));
        assertEq(reserves.deployedTo(c), 0);
        p = _attestReceipt(c, 0, GRID, 0, "after-close");
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_NotDistributable.selector, c));
        _distribute(p);
    }

    // ═════════════════════════════════════════════════════════════════════
    // 3. Hostile crank and planner arguments, as carol
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Every refusal of `planLegacyPik` that a live legacy facility can reach, driven
    ///         through all four permissionless entry points with the exact error, plus the two
    ///         planner branches (zero interval, non-receivable class) that origination makes
    ///         unreachable. The matured facility walks the terminal-period desync to reach
    ///         `Waterfall_PikPastMaturity`, the past-due mark to reach `Waterfall_PikPastDue`
    ///         ahead of it, and the balloon payoff to reach `pendingLegacyPik`'s `dueAt > maturity`
    ///         arm.
    function test_atk_legacy_hostileCrankArgumentsAsCarol() public onFork {
        uint256 c = _cash(P, "C");
        uint256 e = _originate(_terms(P, INTERVAL, uint64(block.timestamp + 365 days), true, "E")); // Pending PIK
        uint256 f = _pik(P, 365 days, "F");
        uint64 t0 = uint64(block.timestamp);
        uint256 g = _pik(P, 45 days, "G"); // matures 15 days into its second period
        uint256 unknown = bridge.totalOriginated() + 1;

        // unknown ids: the bridge's error bubbles through every entry point, the two views included
        _expectAllPikEntriesRevert(unknown, abi.encodeWithSelector(ClaimBridge.Bridge_UnknownToken.selector, unknown));
        _expectAllPikEntriesRevert(0, abi.encodeWithSelector(ClaimBridge.Bridge_UnknownToken.selector, 0));

        // a cash-pay facility
        _expectCrankRefused(c, abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikNotDesignated.selector, c));
        assertFalse(waterfall.pikCrankIsDue(c));
        assertFalse(waterfall.pikCrankBlockedByProtocol(c));

        // a PIK facility that was never funded
        _expectCrankRefused(
            e,
            abi.encodeWithSelector(
                IWaterfallEngine.Waterfall_PikNotPerforming.selector, e, uint8(ClaimBridge.LoanState.Pending)
            )
        );
        assertFalse(waterfall.pikCrankIsDue(e));
        assertFalse(waterfall.pikCrankBlockedByProtocol(e));

        // fund E one day after origination: the schedule anchor stays at t0, the accrual starts at t0 + 1d
        vm.warp(t0 + 1 days);
        _fund(e, P);
        (uint64 anchor,) = waterfall.pikCursorOf(e);
        assertEq(anchor, t0, "cursor anchored at nextPaymentDue - interval, not at the funding block");

        // a funded PIK facility one second before its first boundary
        vm.warp(t0 + INTERVAL - 1);
        _expectCrankRefused(
            f, abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikIntervalNotElapsed.selector, f, t0 + INTERVAL)
        );
        assertFalse(waterfall.pikCrankIsDue(f));
        assertFalse(waterfall.pikCrankBlockedByProtocol(f));
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_NotPastDue.selector, f, t0 + INTERVAL, t0 + INTERVAL + GRACE
            )
        );
        defaultManager.markPastDue(f);

        // the two planner refusals origination makes unreachable
        ClaimBridge.OriginationTerms memory bad = _terms(P, INTERVAL, uint64(block.timestamp + 365 days), true, "Z");
        bad.paymentInterval = 0;
        vm.prank(ops);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.originate(ops, bad);
        bad = _terms(P, INTERVAL, uint64(block.timestamp + 365 days), true, "M");
        bad.classId = Config.CLASS_DIGITAL_ASSETS;
        vm.prank(ops);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.originate(ops, bad);

        _maturedFacilityAsCarol(g, e, t0);
    }

    function _maturedFacilityAsCarol(uint256 g, uint256 e, uint64 t0) internal {
        uint64 maturity = t0 + 45 days;
        assertEq(bridge.facility(g).maturity, maturity);

        // the only crankable coupon: dueAt 30d <= maturity; next boundary 60d > maturity so the
        // schedule cannot advance and stays at 30d
        vm.warp(t0 + INTERVAL);
        // E, funded a day late: `max(lastAt, fundedAt)` selects fundedAt, so the first coupon is 29 days
        vm.prank(carol);
        vm.expectEmit(address(waterfall));
        emit IWaterfallEngine.PikInterestCapitalized(e, CLASS, C1_29D, P + C1_29D, t0 + INTERVAL, RATE);
        assertEq(waterfall.capitalizePik(e), C1_29D, "first period accrues from funding: 29/360, not 30/360");
        vm.prank(carol);
        assertEq(waterfall.capitalizePik(g), C1);
        assertEq(bridge.facility(g).nextPaymentDue, t0 + INTERVAL, "terminal period: schedule frozen at 30d");
        (uint64 lastAt,) = waterfall.pikCursorOf(g);
        assertEq(lastAt, t0 + INTERVAL);

        // past maturity: the crank is refused, the desync is reported protocol-side, the mark is
        // held back until one class window after MATURITY (72d = max(51d+21d, 45d+21d))
        vm.warp(t0 + 61 days);
        _expectCrankRefused(g, abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikPastMaturity.selector, g, maturity));
        assertFalse(waterfall.pikCrankIsDue(g));
        assertTrue(waterfall.pikCrankBlockedByProtocol(g));
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_PikCrankBlocked.selector, g));
        defaultManager.markPastDue(g);

        vm.warp(t0 + 72 days + 1);
        vm.prank(carol);
        vm.expectEmit(address(defaultManager));
        emit IDefaultManager.PastDueMarked(g, CLASS, t0 + INTERVAL, P + C1);
        defaultManager.markPastDue(g);
        assertEq(defaultManager.pastDueContribution(g), P + C1);

        // the past-due gate precedes the maturity gate in the planner
        _expectCrankRefused(g, abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikPastDue.selector, g));
        assertFalse(waterfall.pikCrankIsDue(g));

        // the balloon: `pendingLegacyPik` sees dueAt 60d > maturity 45d and demands no coupon, the
        // performing payoff closes to Repaid and clears the mark
        _distribute(_attestReceipt(g, 0, P + C1, 0, "balloon"));
        assertEq(_state(g), uint8(ClaimBridge.LoanState.Repaid));
        assertEq(reserves.deployedTo(g), 0);
        assertEq(defaultManager.pastDueContribution(g), 0, "onPerformingRepayment cleared the mark");
        assertEq(defaultManager.pendingSeniorImpairment(), 0);
        _expectCrankRefused(
            g,
            abi.encodeWithSelector(
                IWaterfallEngine.Waterfall_PikNotPerforming.selector, g, uint8(ClaimBridge.LoanState.Repaid)
            )
        );
    }

    // ═════════════════════════════════════════════════════════════════════
    // 4. A PIK note through two capitalisations, with receipts on the boundary second and either side
    // ═════════════════════════════════════════════════════════════════════

    /// @notice `planLegacyPik` (`block.timestamp < dueAt` refuses) and `pendingLegacyPik`
    ///         (`dueAt > block.timestamp` returns zero) agree to the second: at `dueAt - 1` no
    ///         coupon is owed and a full payoff closes the note; at `dueAt` the payoff is refused
    ///         with `Waterfall_PikSettlementRequired(dueAt)` until the coupon is capitalised; at
    ///         `dueAt + 1` the same. The measured consequence on the legacy path: a payoff one
    ///         second before a boundary forfeits the whole period, because a PIK facility can take
    ///         no cash interest and the planner recognises no partial period.
    function test_atk_legacy_pikCouponBoundarySeconds() public onFork {
        uint256 id = _pik(P, 365 days, "P");
        uint64 t0 = uint64(block.timestamp);
        uint64 due1 = t0 + INTERVAL;

        // dueAt - 1: no coupon, and a payoff closes with ZERO interest ever recognised
        vm.warp(due1 - 1);
        _expectCrankRefused(
            id, abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikIntervalNotElapsed.selector, id, due1)
        );
        uint256 snap = vm.snapshotState();
        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        _distribute(_attestReceipt(id, 0, P, 0, "payoff-1s-early"));
        assertEq(_state(id), uint8(ClaimBridge.LoanState.Repaid));
        assertEq(reserves.deployedTo(id), 0);
        assertEq(usdfr.balanceOf(address(vault)), vaultBefore, "29d 23:59:59 at 1400 bps: nothing owed, nothing paid");
        assertEq(waterfall.pikCapitalisedTotalOf(id), 0);
        vm.revertToState(snap);

        // dueAt: the payoff is refused until the coupon is capitalised; the crank runs on the second
        vm.warp(due1);
        snap = vm.snapshotState();
        IWaterfallEngine.Payment memory p = _attestReceipt(id, 0, P, 0, "payoff-on-boundary");
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikSettlementRequired.selector, id, due1));
        _distribute(p);
        vm.revertToState(snap);
        vm.prank(carol);
        vm.expectEmit(address(waterfall));
        emit IWaterfallEngine.PikInterestCapitalized(id, CLASS, C1, P + C1, due1, RATE);
        assertEq(waterfall.capitalizePik(id), C1);
        assertEq(reserves.deployedTo(id), P + C1);
        assertEq(bridge.facility(id).nextPaymentDue, due1 + INTERVAL);

        // second boundary, one second late
        uint64 due2 = due1 + INTERVAL;
        vm.warp(due2 + 1);
        vm.prank(carol);
        assertEq(waterfall.capitalizePik(id), C2);
        assertEq(reserves.deployedTo(id), P + C1 + C2);

        _thirdBoundary(id, due2 + INTERVAL);
    }

    function _thirdBoundary(uint256 id, uint64 due3) internal {
        uint256 owed = P + C1 + C2;

        vm.warp(due3 - 1);
        uint256 snap = vm.snapshotState();
        _distribute(_attestReceipt(id, 0, owed, 0, "payoff-3-early"));
        assertEq(_state(id), uint8(ClaimBridge.LoanState.Repaid), "two coupons paid, the third forfeited by one second");
        assertEq(waterfall.pikCapitalisedTotalOf(id), C1 + C2);
        vm.revertToState(snap);

        vm.warp(due3);
        snap = vm.snapshotState();
        IWaterfallEngine.Payment memory p = _attestReceipt(id, 0, owed, 0, "payoff-3-on");
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikSettlementRequired.selector, id, due3));
        _distribute(p);
        vm.revertToState(snap);

        vm.warp(due3 + 1);
        snap = vm.snapshotState();
        p = _attestReceipt(id, 0, owed, 0, "payoff-3-late");
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikSettlementRequired.selector, id, due3));
        _distribute(p);
        vm.revertToState(snap);

        uint256 feeBefore = usdfr.balanceOf(ops);
        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        vm.prank(carol);
        assertEq(waterfall.capitalizePik(id), C3);
        assertEq(usdfr.balanceOf(ops) - feeBefore, C3 / 10, "PIK: 10% of the coupon to the fee recipient");
        assertEq(usdfr.balanceOf(address(vault)) - vaultBefore, C3 - C3 / 10, "PIK: 90% of the coupon to the vault");
        _distribute(_attestReceipt(id, 0, owed + C3, 0, "payoff-3-settled"));
        assertEq(_state(id), uint8(ClaimBridge.LoanState.Repaid));
        assertEq(reserves.deployedTo(id), 0);
        assertEq(waterfall.pikCapitalisedTotalOf(id), C1 + C2 + C3);
        emit log_named_uint("legacy PIK: interest forfeited by a payoff at dueAt-1 (e12 units)", C3 / GRID);
    }

    // ═════════════════════════════════════════════════════════════════════
    // 5. A stale cursor: 200 days with no crank
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Facility Q is never cranked for 200 days; facility R is cranked on every boundary.
    ///         The stale planner reports the FIRST elapsed period on its frozen terms (the
    ///         `caughtUp == false` arm), never drifts and never reverts. Carol cannot mark Q past
    ///         due at day 200: the permissionless mark settles a period instead, six times, and
    ///         after the sixth Q and R hold the same balance to the wei.
    function test_atk_legacy_staleCursorCatchesUpWithoutDriftAndCannotBeMarked() public onFork {
        uint256 q = _pik(P, 365 days, "Q");
        uint256 r = _pik(P, 365 days, "R");
        uint64 t0 = uint64(block.timestamp);
        for (uint256 i = 1; i <= 6; ++i) {
            vm.warp(t0 + i * INTERVAL);
            vm.prank(carol);
            waterfall.capitalizePik(r);
        }
        vm.warp(t0 + 200 days);
        assertEq(reserves.deployedTo(r), SIX_PERIOD_BALANCE, "prompt arm: six compounding coupons");

        WaterfallEngine.PikPlan memory plan = waterfall.planPik(q);
        assertEq(plan.dueAt, t0 + INTERVAL, "stale planner: the first elapsed period, not the latest");
        assertEq(plan.amount, C1);
        assertEq(plan.nextBasis, P + C1, "not caught up: basis grows by the coupon, terms stay frozen");
        assertEq(plan.nextRateBps, RATE);
        assertEq(plan.nextInterval, INTERVAL);
        assertTrue(waterfall.pikCrankIsDue(q));
        assertFalse(waterfall.pikCrankBlockedByProtocol(q));

        // periods 1..5 are past their grace window at day 200: each mark attempt settles one instead
        for (uint256 i = 1; i <= 5; ++i) {
            vm.expectEmit(address(defaultManager));
            emit IDefaultManager.PikPeriodSettledInsteadOfMark(q, CLASS, uint64(t0 + i * INTERVAL));
            vm.prank(carol);
            defaultManager.markPastDue(q);
            assertEq(
                bridge.facility(q).nextPaymentDue, t0 + (i + 1) * INTERVAL, "each mark attempt advances one period"
            );
            assertEq(defaultManager.pastDueContribution(q), 0, "never marked");
        }
        // period 6 (due day 180) is elapsed but inside its grace window until day 201: the mark is
        // refused on the grace test, the crank is due, and carol can crank it herself
        uint64 due6 = t0 + 6 * INTERVAL;
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_NotPastDue.selector, q, due6, due6 + GRACE)
        );
        defaultManager.markPastDue(q);
        assertTrue(waterfall.pikCrankIsDue(q));
        vm.prank(carol);
        waterfall.capitalizePik(q);
        assertEq(reserves.deployedTo(q), SIX_PERIOD_BALANCE, "late arm: identical to the wei, no drift");
        assertEq(reserves.deployedTo(q), reserves.deployedTo(r));
        assertEq(waterfall.pikCapitalisedTotalOf(q), waterfall.pikCapitalisedTotalOf(r));

        uint64 due7 = t0 + 7 * INTERVAL;
        _expectCrankRefused(
            q, abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikIntervalNotElapsed.selector, q, due7)
        );
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_NotPastDue.selector, q, due7, due7 + GRACE)
        );
        defaultManager.markPastDue(q);
        assertFalse(waterfall.pikCrankIsDue(q));
        assertFalse(waterfall.pikCrankBlockedByProtocol(q));
    }

    // ═════════════════════════════════════════════════════════════════════
    // 6. `WaterfallAccrualLib.validate`, driven directly, and the bound-but-disabled legacy state
    // ═════════════════════════════════════════════════════════════════════

    /// @notice The migration's first step on mainnet is `WaterfallEngine.setAccrualReserve`, which
    ///         runs `validate`. Driven through every refusal a legacy deployment can reach: the
    ///         wrong reserve, an unconfigured reserve (seven zero module words), a configured
    ///         reserve whose token is not yet bound, then success, then `AlreadyBound`. The
    ///         resulting BOUND-BUT-DISABLED state is exactly what mainnet will sit in between
    ///         binding and the attested opening: the legacy crank and planner still run (through
    ///         `capitalizePik`'s idle check on the bound reserve), and `planPik` does not report
    ///         the facility as engine-managed.
    function test_atk_legacy_validateLadderAndBoundButDisabledLegacyRoute() public onFork {
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0))
        );
        waterfall.setAccrualReserve(address(reserves));

        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(WaterfallAccrualLib.WaterfallAccrual_InvalidReserve.selector, address(bridge))
        );
        waterfall.setAccrualReserve(address(bridge));

        // unconfigured reserve: accrualModules() is seven zero words, address(0) has no code
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(WaterfallAccrualLib.WaterfallAccrual_InvalidReserve.selector, address(reserves))
        );
        waterfall.setAccrualReserve(address(reserves));

        vm.prank(ops);
        reserves.configureContinuousAccrual(
            IContinuousAccrual.Modules({
                token: address(usdfr),
                controller: address(controller),
                vault: address(vault),
                waterfall: address(waterfall),
                bridge: address(bridge),
                registry: address(registry),
                defaultManager: address(defaultManager)
            })
        );

        // configured, but the token does not yet point back at the reserve
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(WaterfallAccrualLib.WaterfallAccrual_InvalidReserve.selector, address(reserves))
        );
        waterfall.setAccrualReserve(address(reserves));

        vm.prank(ops);
        usdfr.setAccrualReserve(address(reserves));

        vm.prank(ops);
        vm.expectEmit(address(waterfall));
        emit WaterfallEngine.AccrualReserveSet(address(reserves));
        waterfall.setAccrualReserve(address(reserves));
        assertEq(waterfall.accrualReserve(), address(reserves));
        assertFalse(reserves.accrualSnapshot().enabled, "bound, NOT enabled");

        vm.prank(ops);
        vm.expectRevert(WaterfallEngine.Waterfall_AccrualAlreadyBound.selector);
        waterfall.setAccrualReserve(address(reserves));

        // the legacy route still runs on the bound-but-disabled deployment
        uint256 s = _pik(P, 365 days, "S");
        uint64 due1 = uint64(block.timestamp) + INTERVAL;
        vm.warp(due1);
        WaterfallEngine.PikPlan memory plan = waterfall.planPik(s);
        assertEq(plan.amount, C1);
        assertTrue(waterfall.pikCrankIsDue(s));
        vm.prank(carol);
        assertEq(waterfall.capitalizePik(s), C1);
        assertEq(reserves.deployedTo(s), P + C1);

        uint256 c = _cash(P, "C");
        IWaterfallEngine.Payment memory p = _attestReceipt(c, 10_000e18, 0, _nextDueAfter(c), "bound-cash");
        vm.expectEmit(address(waterfall));
        emit IWaterfallEngine.Distributed(c, p.paymentId, borrower, 10_000e18, 0, 1_000e18, 9_000e18);
        _distribute(p);
    }
}
