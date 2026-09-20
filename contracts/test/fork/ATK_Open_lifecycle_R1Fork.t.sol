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
import {AccrualLoans} from "../../src/libraries/AccrualLoans.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @title OPEN_lifecycle_R1: lifecycle ordering and liveness on the pinned mainnet fork.
/// @notice Round 1 of the lifecycle angle. Three candidates, deepest first:
///   C1. A PIK note paid off mid-period by an amount that lands one grid unit short (the
///       realistic attester timing miss) is NOT closed: the frozen period basis survives the
///       principal reaching zero, so the engine keeps recognising interest on the ORIGINAL
///       basis until the next signed date, capitalises it as new principal, and the note can
///       only be closed by hitting the exact second or by a signed amendment that truncates
///       the term. Measured to the wei.
///   C2. The cash-pay control: the same one-unit-short payoff leaves a static dust interest
///       balance (basis zero), which a second exact receipt closes; retirement releases the slot.
///       An over-attested payoff is refused by name and the standing fact blocks a replacement
///       until the clock catches up, then the same fact lands.
///   C3. A cash note that matures unpaid: interest after maturity with the terminal due gate,
///       past-due after maturity, default after maturity, full loss through the cascade,
///       Resolved, retire; every risk carrier returns to zero and the retired tombstone refuses
///       every later mark.
contract OPEN_lifecycle_R1 is ForkLifecycleFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    uint256 internal constant P = 1_000_000e18;
    uint256 internal constant RATE_BPS = 1400;
    uint256 internal constant YEAR = 360 days;
    uint256 internal constant SCALE = 1e12;
    uint256 internal constant PIK_INTERVAL = 90 days;
    uint256 internal constant PIK_TERM = 360 days;

    // ---------------------------------------------------------------------
    // C1: PIK payoff shortfall keeps accruing on the frozen basis with zero principal
    // ---------------------------------------------------------------------

    function test_lifecycle_pikPayoffShortfallKeepsAccruingOnFrozenBasis() public onFork {
        _mintFromUSDC(alice, 3_000_000e6);
        _stake(alice, 2_000_000e18);
        uint256 t0 = block.timestamp;
        uint256 id = _fundPik(t0);

        // Day 45 of the first 90-day period. Canonical interest is exactly 17,500.
        _warpTo(t0 + 45 days);
        vm.prank(carol);
        reserves.checkpointAccrual(32);
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
        assertEq(d.principal, P, "principal at day 45");
        assertEq(d.interest, 17_500e18, "canonical PIK interest at day 45 is exactly 17,500");
        assertTrue(reserves.accrualSnapshot().fresh, "book fresh at day 45");

        _c1OverAttestedIsRefusedAndBlocksReplacement(id, P + 17_500e18 + SCALE);
        uint256 vaultBefore = vault.totalAssets();
        uint256 grossBefore = reserves.accrualSnapshot().gross;

        // The realistic miss: one grid unit short of the debt at the execution second.
        _distributePik(id, P + 17_500e18 - SCALE, "c1-short");
        d = reserves.accruedDebt(id);
        assertEq(d.principal, 0, "principal fully discharged");
        assertEq(d.interest, SCALE, "one grid unit of interest remains");
        assertEq(reserves.deployedTo(id), SCALE, "native face is the dust");
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Amortizing), "not closed");
        assertTrue(d.active, "the note is still accruing");
        assertTrue(reserves.accrualLoanScheduled(id), "a positive segment was re-opened on zero principal");

        _c1FrozenBasisAccruesThroughTheSignedDate(id, t0, vaultBefore, grossBefore);
        _c1SecondPayoffMissesAgain(id);
        _c1TruncatingAmendmentIsTheOnlyClose(id);
    }

    /// @dev An attester who estimates one grid unit above the debt at execution is refused by
    ///      name; the fact stands and no replacement PaymentReceived can be signed until it is
    ///      consumed or revoked.
    function _c1OverAttestedIsRefusedAndBlocksReplacement(uint256 id, uint256 overLeg) internal {
        uint256 s = vm.snapshotState();
        IWaterfallEngine.Payment memory over = _prepPik(id, overLeg, "c1-over");
        vm.prank(ops);
        vm.expectRevert(AccrualLoans.AccrualLoans_PaymentAboveDebt.selector);
        waterfall.distribute(over);
        // A corrected fact cannot be signed while the refused one stands.
        bytes32 standing = keccak256(
            abi.encode(over.paymentId, id, USDC, borrower, overLeg / SCALE, uint256(0), overLeg, over.nextPaymentDue)
        );
        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) =
            _signedBundle(id, IAttestationOracle.AttestationKind.PaymentReceived, keccak256("c1-replacement"));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_UnconsumedFact.selector,
                id,
                IAttestationOracle.AttestationKind.PaymentReceived,
                standing
            )
        );
        oracle.attest(a, sigs);
        // One second later the debt has grown past the attested figure and the SAME fact lands,
        // closing the note only because the standing figure happens to be at or below the debt.
        _warp(1);
        uint256 debt = reserves.accruedDebt(id).principal + reserves.accruedDebt(id).interest;
        assertGt(debt, overLeg, "one second of accrual on 1,000,000 exceeds one grid unit");
        vm.prank(ops);
        waterfall.distribute(over);
        assertEq(reserves.deployedTo(id), debt - overLeg, "residual after the late landing");
        emit log_named_uint("C1 residual after the over-attested fact lands one second late", debt - overLeg);
        assertTrue(vm.revertToState(s), "revert");
    }

    /// @dev From day 45 to the signed date at day 90 the engine recognises interest on the
    ///      original 1,000,000 basis although principal is zero, then capitalises it.
    function _c1FrozenBasisAccruesThroughTheSignedDate(uint256 id, uint256 t0, uint256 vaultBefore, uint256 grossBefore)
        internal
    {
        _warpTo(t0 + 90 days - 1);
        vm.prank(carol);
        reserves.checkpointAccrual(32);
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
        emit log_named_uint("C1 interest recognised on zero principal one second before the signed date", d.interest);
        assertGt(d.interest, 17_000e18, "tens of thousands recognised on a facility with no principal");
        assertEq(d.principal, 0, "principal is still zero");

        _warpTo(t0 + 90 days);
        vm.prank(carol);
        (uint256 processed,) = reserves.checkpointAccrual(32);
        assertEq(processed, 1, "the signed date is processed");
        d = reserves.accruedDebt(id);
        assertEq(d.principal, 17_500e18 + SCALE, "the period's frozen-basis interest is capitalised as principal");
        assertEq(d.interest, 0, "capitalised");
        assertEq(d.nextCapitalization, t0 + 180 days, "the next signed date is scheduled");
        assertEq(reserves.deployedTo(id), 17_500e18 + SCALE, "native face equals the phantom principal");
        assertEq(bridge.facility(id).nextPaymentDue, t0 + 180 days, "bridge due date advanced");
        // The book's gross also carries the sub-unit positive correction credited when the short
        // payoff closed the day-45 segment (measured: 544,000 wei), so compare within one grid unit.
        emit log_named_uint(
            "C1 book gross recognised since the short payoff", reserves.accrualSnapshot().gross - grossBefore
        );
        assertApproxEqAbs(
            reserves.accrualSnapshot().gross - grossBefore, 17_500e18, SCALE, "gross rose by the full period coupon"
        );
        assertTrue(d.active && reserves.accrualLoanScheduled(id), "still accruing on the new basis");

        // The senior claim on that income is real and physical once materialised.
        uint256 physicalBefore = usdfr.balanceOf(address(vault));
        vm.prank(carol);
        (uint256 senior, uint256 fee) = reserves.materializeAccrued(3);
        emit log_named_uint("C1 senior USDfr minted against the zero-principal coupon (plus earlier claims)", senior);
        emit log_named_uint("C1 fee USDfr minted", fee);
        assertEq(usdfr.balanceOf(address(vault)) - physicalBefore, senior, "senior leg delivered to the vault");
        emit log_named_uint(
            "C1 senior vault assets gained since day 45 (mostly the zero-principal coupon)",
            vault.totalAssets() - vaultBefore
        );
        assertGt(
            vault.totalAssets(), vaultBefore + 15_000e18, "senior assets carry the senior share of the phantom coupon"
        );
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "backing holds: the receivable backs the mint");
    }

    /// @dev A second payoff attested at the execution second but landing one second later
    ///      misses again; the note continues to accrue on 17,500.000001 of capitalised interest.
    function _c1SecondPayoffMissesAgain(uint256 id) internal {
        _warp(10 days);
        vm.prank(carol);
        reserves.checkpointAccrual(32);
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
        uint256 debtNow = d.principal + d.interest;
        IWaterfallEngine.Payment memory p = _prepPik(id, debtNow, "c1-second");
        _warp(1);
        vm.prank(ops);
        waterfall.distribute(p);
        d = reserves.accruedDebt(id);
        uint256 residual = reserves.deployedTo(id);
        emit log_named_uint("C1 residual after the second exact-figure payoff lands one second late", residual);
        assertGt(residual, 0, "not closed");
        assertEq(d.principal, 0, "principal zero again");
        assertTrue(d.active && reserves.accrualLoanScheduled(id), "still accruing on the frozen basis of 17,500");
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Amortizing), "not Repaid");
    }

    /// @dev The only operator path that freezes the debt before maturity: a signed amendment that
    ///      truncates maturity to the next second. After it the note deactivates and an exact
    ///      payoff closes it. Requires a TermsAmended quorum signature.
    function _c1TruncatingAmendmentIsTheOnlyClose(uint256 id) internal {
        ClaimBridge.Facility memory f = bridge.facility(id);
        ClaimBridge.Amendment memory a = ClaimBridge.Amendment({
            interestRateBps: f.interestRateBps,
            maturity: uint64(block.timestamp + 1),
            paymentInterval: 1 days,
            nextPaymentDue: uint64(block.timestamp + 1),
            rateType: f.rateType,
            dayCountConvention: f.dayCountConvention,
            renewable: false,
            paymentScheduleHash: keccak256("c1-truncate"),
            rateIndexRef: bytes32(0),
            renewalTermsHash: bytes32(0)
        });
        bytes32 amendmentId = keccak256("c1-truncation");
        _attest(id, IAttestationOracle.AttestationKind.TermsAmended, keccak256(abi.encode(amendmentId, id, a)));
        vm.prank(ops);
        bridge.amendTerms(id, amendmentId, a);
        _warp(1);
        vm.prank(carol);
        (uint256 processed,) = reserves.checkpointAccrual(32);
        assertEq(processed, 1, "the truncated maturity is processed");
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
        assertFalse(d.active, "frozen at the truncated maturity");
        assertFalse(reserves.accrualLoanScheduled(id), "no segment");
        uint256 debt = d.principal + d.interest;
        emit log_named_uint("C1 frozen debt after the truncating amendment", debt);
        IWaterfallEngine.Payment memory p = _prepPik(id, debt, "c1-final");
        _warp(3 days); // the frozen figure survives any landing delay
        vm.prank(ops);
        waterfall.distribute(p);
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Repaid), "closed");
        assertEq(reserves.deployedTo(id), 0, "nothing outstanding");
        assertTrue(reserves.accrualSnapshot().fresh, "book fresh after retirement");
    }

    // ---------------------------------------------------------------------
    // C2: the cash control closes in two steps and retires
    // ---------------------------------------------------------------------

    function test_lifecycle_cashPayoffShortfallIsStaticAndClosesInTwoSteps() public onFork {
        _mintFromUSDC(alice, 3_000_000e6);
        _stake(alice, 2_000_000e18);
        uint256 t0 = block.timestamp;
        uint256 id = _originateAndFund(P);
        _warpTo(t0 + 45 days);
        vm.prank(carol);
        reserves.checkpointAccrual(32);
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
        assertEq(d.interest, 17_500e18, "canonical cash interest at day 45 is exactly 17,500");

        // Over-attested interest is refused; the standing fact blocks a replacement; one second
        // later the same fact lands (interest grew past it) and leaves a residual.
        {
            uint256 s = vm.snapshotState();
            IWaterfallEngine.Payment memory over = _prepCash(id, 17_500e18 + SCALE, P, "c2-over");
            vm.prank(ops);
            vm.expectRevert(AccrualLoans.AccrualLoans_PaymentAboveDebt.selector);
            waterfall.distribute(over);
            (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) =
                _signedBundle(id, IAttestationOracle.AttestationKind.PaymentReceived, keccak256("c2-replacement"));
            vm.expectRevert(); // Oracle_UnconsumedFact with the standing payload
            oracle.attest(a, sigs);
            _warp(1);
            vm.prank(ops);
            waterfall.distribute(over);
            d = reserves.accruedDebt(id);
            emit log_named_uint("C2 residual after the over-attested cash fact lands one second late", d.interest);
            assertEq(d.principal, 0, "principal discharged");
            assertGt(d.interest, 0, "residual interest");
            assertTrue(vm.revertToState(s), "revert");
        }

        // The realistic miss on a cash note: principal fully paid, interest one unit short.
        _distributeCash(id, 17_500e18 - SCALE, P, "c2-short");
        d = reserves.accruedDebt(id);
        assertEq(d.principal, 0, "principal discharged");
        assertEq(d.interest, SCALE, "one grid unit of interest remains");
        assertTrue(d.active, "loan record still active (cash basis is now zero)");
        assertFalse(reserves.accrualLoanScheduled(id), "no segment: nothing accrues on a zero cash basis");
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Amortizing), "amortizing");

        // Thirty days later the dust is unchanged: the residual is static.
        _warp(30 days);
        vm.prank(carol);
        reserves.checkpointAccrual(32);
        d = reserves.accruedDebt(id);
        assertEq(d.interest, SCALE, "the residual did not grow");
        assertEq(reserves.deployedTo(id), SCALE, "native face is still the dust");

        // A second exact receipt closes and retires the facility; the slot is released.
        uint32 registeredBefore = _registeredCount();
        _distributeCash(id, SCALE, 0, "c2-dust");
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Repaid), "closed");
        assertEq(reserves.deployedTo(id), 0, "nothing outstanding");
        d = reserves.accruedDebt(id);
        assertTrue(d.known && !d.active, "tombstone remains, inactive");
        assertEq(registry.totalBookExposure(), 0, "registry exposure released");
        assertEq(reserves.accrualReservedExposure(), 0, "future reservation released");
        assertTrue(reserves.accrualSnapshot().fresh, "book fresh after retirement");
        assertEq(_registeredCount(), registeredBefore - 1, "the admission slot was released");
        // The tombstone refuses a later mark by name (retired entries are unregistered in the book).
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_UnknownFacility.selector, id));
        defaultManager.markPastDue(id);
    }

    // ---------------------------------------------------------------------
    // C3: a matured cash note: post-maturity servicing, past-due, default, loss, retire
    // ---------------------------------------------------------------------

    function test_lifecycle_maturedCashNoteDefaultsLossesAndRetiresCleanly() public onFork {
        _mintFromUSDC(alice, 3_000_000e6);
        _stake(alice, 2_000_000e18);
        _postFirstLossOps(500_000e18);
        _fundCoverageOps(200_000e18);
        uint256 t0 = block.timestamp;
        uint256 id = _originateAndFund(P);
        uint64 maturity = bridge.facility(id).maturity;
        assertEq(maturity, t0 + 365 days, "term");

        // Nobody pays and nobody checkpoints for 375 days. Both boundaries are overdue.
        _warpTo(maturity + 10 days);
        assertFalse(reserves.accrualSnapshot().fresh, "stale past maturity");
        vm.prank(carol);
        (uint256 processed, bool fresh) = reserves.checkpointAccrual(32);
        assertEq(processed, 2, "technical boundary at maturity-1 and maturity");
        assertTrue(fresh, "fresh");
        uint256 cap = Math.mulDiv(P * RATE_BPS, 365 days, YEAR * 10_000 * SCALE) * SCALE;
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
        assertEq(d.interest, cap, "interest frozen at the term cap");
        assertFalse(d.active, "deactivated at maturity");
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Active), "bridge still Active");

        // (a) A late interest receipt after maturity: the due date may only advance to maturity.
        _distributeCashWithDue(id, 100_000e18, 0, maturity, "c3-late-interest");
        assertEq(reserves.accruedDebt(id).interest, cap - 100_000e18, "interest reduced");
        assertEq(bridge.facility(id).nextPaymentDue, maturity, "due date pinned at maturity");
        assertEq(reserves.deployedTo(id), P + cap - 100_000e18, "face after the receipt");

        // (b) Past due after maturity plus the 21-day grace.
        _warpTo(maturity + 21 days + 1);
        defaultManager.markPastDue(id);
        assertEq(defaultManager.pastDueExposure(), P + cap - 100_000e18, "marked at the full face");

        // (c) Default after maturity: the mark converts to a declared contribution.
        _declareDefault(id, keccak256("c3-default"));
        assertEq(defaultManager.pastDueExposure(), 0, "past-due released at declaration");
        assertEq(defaultManager.declaredDefaultedPrincipal(FILM), P + cap - 100_000e18, "declared at the face");
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Defaulted), "Defaulted");

        // (d) Full loss through the cascade, Resolved, retire.
        uint256 loss = P + cap - 100_000e18;
        uint32 registeredBefore = _registeredCount();
        uint256 curatorBefore = curator.poolBalance(FILM);
        uint256 coverageBefore = sGrove.coverageReserve();
        _realizeLoss(id, loss, bytes32(0));
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Resolved), "Resolved");
        assertEq(reserves.deployedTo(id), 0, "face written to zero");
        assertEq(curator.poolBalance(FILM), 0, "layer 1 exhausted first");
        assertEq(sGrove.coverageReserve(), 0, "layer 2 exhausted second");
        emit log_named_uint("C3 loss absorbed by curator", curatorBefore);
        emit log_named_uint("C3 loss absorbed by sGROVE", coverageBefore);
        emit log_named_uint("C3 loss absorbed by senior", loss - curatorBefore - coverageBefore);
        assertEq(defaultManager.declaredDefaultedPrincipal(FILM), 0, "declared pool cleared");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "no residual impairment");
        assertEq(registry.totalBookExposure(), 0, "registry exposure released");
        assertEq(reserves.accrualReservedExposure(), 0, "reservation released");
        d = reserves.accruedDebt(id);
        assertTrue(d.known && !d.active && d.principal == 0 && d.interest == 0, "tombstone, settled");
        assertEq(_registeredCount(), registeredBefore - 1, "slot released");
        assertTrue(reserves.accrualSnapshot().fresh, "book fresh");
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "backing holds after the write-off");
        assertTrue(controller.backingInvariantHolds(), "controller reports whole");

        // The tombstone refuses every later risk act by name.
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_UnknownFacility.selector, id));
        defaultManager.markPastDue(id);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotPastDueMarked.selector, id));
        defaultManager.clearPastDue(id, keccak256("c3-cure"));
        // And the book still admits a new facility.
        uint256 next = _originateAndFund(100_000e18);
        assertTrue(reserves.accruedDebt(next).active, "a new facility registers after the retirement");
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _fundPik(uint256 t0) internal returns (uint256 id) {
        ClaimBridge.OriginationTerms memory t = _forkTermsFor(
            FILM,
            keccak256("R1_PIK_BORROWER"),
            keccak256("US-GA"),
            P,
            7500,
            uint16(RATE_BPS),
            uint64(t0 + PIK_TERM),
            keccak256("r1-pik-note")
        );
        t.pik = true;
        t.paymentInterval = uint64(PIK_INTERVAL);
        t.nextPaymentDue = uint64(t0 + PIK_INTERVAL);
        id = bridge.totalOriginated() + 1;
        bytes32 termsHash = bridge.creditTermsHash(t);
        _attest(id, IAttestationOracle.AttestationKind.CreditIssued, termsHash);
        _attest(id, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash);
        _attest(id, IAttestationOracle.AttestationKind.UCCFiled, termsHash);
        vm.prank(ops);
        uint256 minted = bridge.originate(ops, t);
        assertEq(minted, id, "PIK facility id");
        vm.prank(ops);
        waterfall.fund(id, P / SCALE);
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
        assertTrue(d.pik && d.active, "registered as an accruing PIK note");
    }

    function _registeredCount() internal view returns (uint32) {
        // AccrualBook.registered is not exposed; use the reservation table as the slot proxy:
        // a retired facility carries a zero reservation. Count facilities with a live debt.
        uint32 n;
        uint256 total = bridge.totalOriginated();
        for (uint256 i = 1; i <= total; ++i) {
            IAccrualLifecycle.Debt memory d = reserves.accruedDebt(i);
            if (d.known && (d.active || d.principal != 0 || d.interest != 0)) ++n;
        }
        return n;
    }

    function _prepPik(uint256 id, uint256 principalLeg, string memory tag)
        internal
        returns (IWaterfallEngine.Payment memory p)
    {
        return _prepCashWithDue(id, 0, principalLeg, bridge.facility(id).nextPaymentDue, tag);
    }

    function _prepCash(uint256 id, uint256 interest, uint256 principal, string memory tag)
        internal
        returns (IWaterfallEngine.Payment memory p)
    {
        ClaimBridge.Facility memory f = bridge.facility(id);
        return _prepCashWithDue(id, interest, principal, f.nextPaymentDue + f.paymentInterval, tag);
    }

    function _prepCashWithDue(uint256 id, uint256 interest, uint256 principal, uint64 nextDue, string memory tag)
        internal
        returns (IWaterfallEngine.Payment memory p)
    {
        uint256 stableAmount = (interest + principal) / SCALE;
        deal(USDC, borrower, IERC20(USDC).balanceOf(borrower) + stableAmount);
        vm.prank(borrower);
        IERC20(USDC).approve(address(reserves), stableAmount);
        bytes32 paymentId = keccak256(abi.encode(tag, id, interest, principal, block.timestamp));
        _attest(
            id,
            IAttestationOracle.AttestationKind.PaymentReceived,
            keccak256(abi.encode(paymentId, id, USDC, borrower, stableAmount, interest, principal, nextDue))
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

    function _distributePik(uint256 id, uint256 principalLeg, string memory tag) internal {
        IWaterfallEngine.Payment memory p = _prepPik(id, principalLeg, tag);
        vm.prank(ops);
        waterfall.distribute(p);
    }

    function _distributeCash(uint256 id, uint256 interest, uint256 principal, string memory tag) internal {
        IWaterfallEngine.Payment memory p = _prepCash(id, interest, principal, tag);
        vm.prank(ops);
        waterfall.distribute(p);
    }

    function _distributeCashWithDue(uint256 id, uint256 interest, uint256 principal, uint64 due, string memory tag)
        internal
    {
        IWaterfallEngine.Payment memory p = _prepCashWithDue(id, interest, principal, due, tag);
        vm.prank(ops);
        waterfall.distribute(p);
    }

    function _signedBundle(uint256 facilityId, IAttestationOracle.AttestationKind kind, bytes32 payload)
        internal
        returns (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs)
    {
        a = IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: kind,
            payload: payload,
            asOf: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 1 hours),
            nonce: ++attestationNonce
        });
        bytes32 digest = oracle.attestationDigest(a);
        (uint256 lo, uint256 hi) = vm.addr(PK1) < vm.addr(PK2) ? (PK1, PK2) : (PK2, PK1);
        sigs = new bytes[](2);
        sigs[0] = _sig(lo, digest);
        sigs[1] = _sig(hi, digest);
    }

    function _sig(uint256 pk, bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _postFirstLossOps(uint256 usdfrAmount) internal {
        _mintFromUSDC(ops, usdfrAmount / SCALE);
        vm.startPrank(ops);
        usdfr.approve(address(curator), usdfrAmount);
        curator.postFirstLoss(FILM, usdfrAmount);
        vm.stopPrank();
    }

    function _fundCoverageOps(uint256 usdfrAmount) internal {
        _mintFromUSDC(ops, usdfrAmount / SCALE);
        vm.startPrank(ops);
        usdfr.approve(address(sGrove), usdfrAmount);
        sGrove.fundCoverage(usdfrAmount);
        vm.stopPrank();
    }

    function _warpTo(uint256 ts) internal {
        require(ts > block.timestamp, "R1: warp must move forward");
        _warp(ts - block.timestamp);
    }
}
