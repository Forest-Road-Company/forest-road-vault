// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {USDfr} from "../../src/USDfr.sol";
import {IUSDfr} from "../../src/interfaces/IUSDfr.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IAccrualLifecycle} from "../../src/interfaces/IAccrualLifecycle.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {ControllerAccrualLib} from "../../src/libraries/ControllerAccrualLib.sol";
import {DefaultAccrualLib} from "../../src/libraries/DefaultAccrualLib.sol";
import {ReserveAccrualLib} from "../../src/libraries/ReserveAccrualLib.sol";
import {ReserveAccrualCreditLib} from "../../src/libraries/ReserveAccrualCreditLib.sol";

/// @title OPEN_auth_R1: authentication, callbacks and cross-module trust on the continuous-accrual
///        delta, executed against the full protocol on the pinned mainnet fork.
///
/// @notice Round 1 of the authentication angle. Every function whose authorisation lives inside a
///         library rather than a modifier is reached from the OTHER side of its trust boundary:
///         a roleless actor (carol), a wrong-but-privileged module (pranked), and the trusted
///         module itself with arguments it must still refuse. Three candidates, deepest first:
///
///           C1. A permissionless `postAccruedLoan` on a past-due-marked facility drives the
///               default manager's address-trusted `onAccrualPosted` and the registry's
///               `recordAccruedExposure`. Is that reclassification exactly neutral for every
///               consumer that prices on it (redemption NAV, impairment mark, risk hash, registry
///               concentration, backing), and do the past-due carriers reconcile to the wei
///               through a partial receipt, a cure, a re-mark and a declaration, however many
///               times carol posts in between?
///           C2. The protocol-fee leg is minted to an address the reserve trusts by identity.
///               Rotating the recipient delivers the old claim first. If the old recipient has
///               become undeliverable (yield-sink revoked, or compliance-blocked and not
///               protocol-exempt), what is held hostage: losses, receipts, or only the rotation?
///           C3. The reserve is trusted by the bridge (`setAccruedPaymentDue`), the token and
///               controller (`mintAccrued`), the default manager (three risk callbacks) and the
///               registry (two exposure callbacks). Each is reached by carol, by a wrong module,
///               and by the trusted module with a stale or out-of-range argument.
contract OPEN_auth_R1 is ForkLifecycleFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    uint256 internal constant SCALE = 1e12;
    bytes32 internal constant BORROWER = keccak256("FORK_BORROWER");
    bytes32 internal constant STATE = keccak256("US-GA");

    /// @dev Everything a consumer of the past-due mark can read, taken at one instant.
    struct Carriers {
        uint256 redemptionAssets;
        uint256 totalAssets;
        uint256 pendingSeniorImpairment;
        uint256 performanceImpairment;
        bytes32 riskHash;
        bytes32 stateHash;
        uint256 revision;
        uint256 pastDueExposure;
        uint256 contribution;
        uint256 pastDuePrincipal;
        uint256 cohort; // reserve-side accruedPastDue(FILM)
        uint256 unposted; // reserve-side unpostedAccruedLoan(id)
        uint256 classExposure;
        uint256 borrowerExposure;
        uint256 stateExposure;
        uint256 totalExposure;
        uint256 deployedTo;
        uint256 deployedPrincipal;
        uint256 backing;
        uint256 recognizedBacking;
        uint256 gross;
        uint256 unissued;
        uint256 supply;
        uint256 deficit;
        uint256 rate;
        uint256 exitRate;
    }

    // ── C1 ────────────────────────────────────────────────────────────────

    function test_auth_permissionlessPostingOnAMarkedFacilityIsExactlyNeutral() public onFork {
        _mintFromUSDC(alice, 3_000_000e6);
        _stake(alice, 1_000_000e18);
        _postFirstLossOps(100_000e18);
        _fundCoverageOps(50_000e18);
        uint256 t0 = block.timestamp;
        uint256 id = _originateAndFund(2_000_000e18);

        uint256 face0 = _c1Mark(id);
        _c1PostIsNeutral(id, face0);
        _c1Receipt(id, t0);
        uint256 growth5 = _c1CureAfterAPost(id);
        _c1RemarkPostAndDeclare(id, growth5);
    }

    /// @dev Past the first payment date plus the 21-day grace window: carol marks it.
    function _c1Mark(uint256 id) internal returns (uint256 face0) {
        _warp(60 days);
        vm.prank(carol);
        defaultManager.markPastDue(id);
        face0 = reserves.deployedTo(id);
        assertEq(defaultManager.pastDueContribution(id), face0, "marked at the posted face");
        assertEq(reserves.unpostedAccruedLoan(id), 0, "the mark posted everything");
    }

    /// @dev Twenty days of unposted growth on the marked cohort, then carol reclassifies it.
    function _c1PostIsNeutral(uint256 id, uint256 face0) internal {
        _warp(20 days);
        Carriers memory c0 = _carriers(id);
        uint256 unposted20 = c0.unposted;
        assertGt(unposted20, 0, "precondition: unposted growth exists");
        assertEq(c0.cohort, unposted20, "the cohort is exactly this facility's unposted growth");
        assertEq(c0.contribution, face0 + unposted20, "contribution = recorded + unposted");
        assertEq(c0.deployedTo, face0 + unposted20, "deployedTo = recorded + unposted");
        assertEq(c0.pastDuePrincipal, c0.contribution, "class pool = the one contribution");
        assertEq(c0.pastDueExposure, c0.contribution, "global pool = the one contribution");
        assertGt(c0.pendingSeniorImpairment, 0, "precondition: the mark bites the senior NAV");
        assertLt(c0.redemptionAssets, c0.totalAssets, "precondition: exit NAV is below realised NAV");

        // ATTACK: carol reclassifies the whole cohort into the recorded carrier. The manager's
        // risk callback lands before the reserve's own posting event.
        vm.expectEmit(true, true, true, true, address(defaultManager));
        emit DefaultAccrualLib.PastDueAccrualPosted(id, FILM, unposted20, face0 + unposted20);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccruedLoanPosted(id, USDC, unposted20, face0 + unposted20);
        vm.prank(carol);
        uint256 posted = reserves.postAccruedLoan(id);
        assertEq(posted, unposted20, "carol posted exactly the unposted growth");

        Carriers memory c1 = _carriers(id);
        _assertConsumersUnchanged(c0, c1, "carol's post");
        assertEq(c1.cohort, 0, "the reserve cohort gave up exactly what was posted");
        assertEq(c1.unposted, 0, "nothing unposted remains");

        // A second post in the same block is a no-op on every carrier, including the reserve's.
        vm.prank(carol);
        assertEq(reserves.postAccruedLoan(id), 0, "nothing left to post");
        Carriers memory c2 = _carriers(id);
        _assertConsumersUnchanged(c1, c2, "carol's repeated post");
        assertEq(c2.cohort, 0, "cohort still zero");
    }

    /// @dev Ten more days, then a partial receipt through the real waterfall: 70,000 of interest
    ///      (the exact Actual/360 coupon for 90 days on 2,000,000 at 1400 bps) and 500,000 of
    ///      principal. The re-anchor must derecognise exactly what was paid.
    function _c1Receipt(uint256 id, uint256 t0) internal {
        _warp(10 days);
        assertEq(block.timestamp, t0 + 90 days, "at day 90");
        assertEq(reserves.accruedDebt(id).interest, 70_000e18, "the contractual coupon at day 90");
        assertEq(
            defaultManager.pastDueContribution(id),
            reserves.deployedTo(id),
            "contribution tracks the face before the receipt"
        );
        vm.recordLogs();
        _repay(id, 70_000e18, 500_000e18);
        _assertLogged(
            vm.getRecordedLogs(),
            address(defaultManager),
            keccak256("PastDueReanchored(uint256,uint256,uint256)"),
            id,
            FILM,
            570_000e18,
            "the receipt re-anchored exactly what was paid"
        );
        assertEq(reserves.deployedTo(id), 1_500_000e18, "1,500,000 outstanding after the receipt");
        assertEq(reserves.unpostedAccruedLoan(id), 0, "the receipt posted everything first");
        assertEq(defaultManager.pastDueContribution(id), 1_500_000e18, "re-anchored to the live face");
        assertEq(defaultManager.pastDuePrincipal(FILM), 1_500_000e18, "class pool follows");
        assertEq(defaultManager.pastDueExposure(), 1_500_000e18, "global pool follows");
        assertEq(registry.classExposure(FILM), 1_500_000e18, "registry follows");
        assertEq(reserves.accruedPastDue(FILM), 0, "cohort empty at the receipt instant");
    }

    /// @dev Five days of growth on the rebased curve; carol posts; the servicer cures.
    function _c1CureAfterAPost(uint256 id) internal returns (uint256 growth5) {
        _warp(5 days);
        growth5 = reserves.unpostedAccruedLoan(id);
        assertGt(growth5, 0, "growth resumed on the rebased principal");
        assertEq(reserves.accruedPastDue(FILM), growth5, "the cohort tracks the new growth");
        Carriers memory c3 = _carriers(id);
        vm.prank(carol);
        assertEq(reserves.postAccruedLoan(id), growth5, "carol posts the five days");
        _assertConsumersUnchanged(c3, _carriers(id), "carol's post after the receipt");
        assertEq(defaultManager.pastDueContribution(id), 1_500_000e18 + growth5, "contribution = face");

        vm.recordLogs();
        _clearPastDueOps(id, keccak256("auth-r1-cure"));
        _assertLogged(
            vm.getRecordedLogs(),
            address(defaultManager),
            keccak256("PastDueCleared(uint256,uint256,uint256)"),
            id,
            FILM,
            1_500_000e18 + growth5,
            "the cure released the whole live contribution"
        );
        assertEq(defaultManager.pastDueExposure(), 0, "cure: global pool empty");
        assertEq(defaultManager.pastDuePrincipal(FILM), 0, "cure: class pool empty");
        assertEq(defaultManager.pastDueContribution(id), 0, "cure: contribution zero");
        assertEq(reserves.accruedPastDue(FILM), 0, "cure: reserve cohort empty");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "cure: no impairment stands");
        assertEq(vault.redemptionTotalAssets(), vault.totalAssets(), "cure: exit NAV equals realised NAV");
        assertEq(reserves.deployedTo(id), 1_500_000e18 + growth5, "cure: face untouched");
    }

    /// @dev Re-mark on the same delinquent episode (due t0+60d, grace 21d, now t0+95d), three more
    ///      days, carol posts, then the servicer declares. The facility must be counted exactly
    ///      once, in the declared carrier, at the posted face.
    function _c1RemarkPostAndDeclare(uint256 id, uint256 growth5) internal {
        vm.prank(carol);
        defaultManager.markPastDue(id);
        assertEq(defaultManager.pastDueContribution(id), 1_500_000e18 + growth5, "re-marked at the face");
        _warp(3 days);
        uint256 growth3 = reserves.unpostedAccruedLoan(id);
        vm.prank(carol);
        assertEq(reserves.postAccruedLoan(id), growth3, "carol posts three days");
        uint256 faceBefore = reserves.deployedTo(id);
        assertEq(faceBefore, 1_500_000e18 + growth5 + growth3, "face before the declaration");
        uint256 curatorBefore = curator.poolBalance(FILM);
        vm.recordLogs();
        _declareDefault(id, keccak256("auth-r1-default"));
        uint256 faceAfter = reserves.deployedTo(id);
        // The close first credits the pro-rata remainder of the segment (posted, so the face
        // rises by it), then reconciles the streamed interpolation against the contractual grid:
        // the excess is a rounding loss charged to the class curator first. Both are sub-unit.
        (uint256 remainderPosted, uint256 correction, uint256 roundingLoss) = _closeFigures(vm.getRecordedLogs(), id);
        assertLt(remainderPosted, SCALE, "the remainder credit is sub-unit");
        assertLt(roundingLoss, SCALE, "the rounding loss is sub-unit");
        assertEq(faceAfter, faceBefore + remainderPosted + correction - roundingLoss, "face = before + posted - loss");
        uint256 principalNow = 1_500_000e18;
        uint256 coupon8 = (principalNow * 1400 * 8 days / (10_000 * 360 days)) / SCALE * SCALE;
        assertEq(coupon8, 4_666_666_666e12, "Actual/360 coupon for 8 days on 1.5M at 1400 bps, grid floored");
        assertEq(faceAfter, 1_500_000e18 + coupon8, "the stopped face is principal plus the grid coupon");
        assertEq(curatorBefore - curator.poolBalance(FILM), roundingLoss, "the rounding loss hit the curator first");
        assertEq(sGrove.coverageReserve(), 50_000e18, "layer two untouched");
        assertEq(defaultManager.pastDueExposure(), 0, "declaration: past-due pool released");
        assertEq(defaultManager.pastDueContribution(id), 0, "declaration: past-due contribution released");
        assertEq(reserves.accruedPastDue(FILM), 0, "declaration: reserve cohort released");
        assertEq(reserves.unpostedAccruedLoan(id), 0, "declaration: nothing unposted");
        assertEq(defaultManager.declaredDefaultedPrincipal(FILM), faceAfter, "declared at the posted face");
        assertEq(defaultManager.defaultedContribution(id), faceAfter, "counted once, in the declared carrier");
        assertFalse(reserves.accruedDebt(id).active, "stopped");

        // After the stop, carol's post is a no-op and a fresh mark is refused by state.
        vm.prank(carol);
        assertEq(reserves.postAccruedLoan(id), 0, "nothing to post on a stopped facility");
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotDefaultable.selector, id));
        defaultManager.markPastDue(id);
        assertEq(defaultManager.declaredDefaultedPrincipal(FILM), faceAfter, "declared carrier unchanged");
    }

    // ── C2 ────────────────────────────────────────────────────────────────

    function test_auth_undeliverableFeeRecipientTrapsRotationButNotLossesOrReceipts() public onFork {
        _mintFromUSDC(alice, 3_000_000e6);
        _stake(alice, 1_000_000e18);
        uint256 id = _originateAndFund(1_000_000e18);
        _warp(30 days);

        IContinuousAccrual.Snapshot memory s = reserves.accrualSnapshot();
        uint256 fee0 = s.feeUnissued;
        assertGt(fee0, 0, "precondition: a fee claim stands");
        assertEq(s.feeRecipient, ops, "precondition: ops is the fee recipient");
        assertEq(waterfall.protocolFeeBps(), 1000, "precondition: 10% of interest");

        // Rotate to a fresh, non-exempt treasury. The old claim is delivered to ops first.
        address treasury2 = makeAddr("auth-r1-treasury2");
        controller.setYieldSink(treasury2, true);
        uint256 opsBefore = usdfr.balanceOf(ops);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualLib.AccrualMaterialized(1, uint64(block.timestamp), 2, 0, fee0);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualLib.AccrualFeeConfigured(1000, treasury2, uint64(block.timestamp));
        waterfall.setFeeRecipient(treasury2);
        assertEq(usdfr.balanceOf(ops) - opsBefore, fee0, "the old recipient's claim was delivered at the switch");
        assertEq(reserves.accrualSnapshot().feeRecipient, treasury2, "rotated");
        assertEq(reserves.accrualSnapshot().feeUnissued, 0, "no claim carried across");

        _warp(30 days);
        uint256 fee1 = reserves.accrualSnapshot().feeUnissued;
        assertGt(fee1, 0, "a claim now stands for treasury2");

        // Variant A: the yield-sink authorisation of the current recipient is revoked.
        controller.setYieldSink(treasury2, false);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(ControllerAccrualLib.ControllerAccrual_UnauthorizedRecipient.selector, treasury2)
        );
        reserves.materializeAccrued(2);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(ControllerAccrualLib.ControllerAccrual_UnauthorizedRecipient.selector, treasury2)
        );
        reserves.materializeAccrued(3);
        vm.prank(carol);
        (uint256 seniorA,) = reserves.materializeAccrued(1);
        assertGt(seniorA, 0, "the senior leg still delivers");
        // Rotation back to ops is refused: the old claim must be delivered first and cannot be.
        vm.expectRevert(
            abi.encodeWithSelector(ControllerAccrualLib.ControllerAccrual_UnauthorizedRecipient.selector, treasury2)
        );
        waterfall.setFeeRecipient(ops);
        controller.setYieldSink(treasury2, true);

        // Variant B: the current recipient is compliance-blocked (it is not protocol-exempt).
        assertFalse(compliance.isProtocolExempt(treasury2), "precondition: treasury2 is an ordinary address");
        compliance.setJurisdictionBlocked(treasury2, true);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IUSDfr.USDfr_TransferNotAllowed.selector, address(0), treasury2));
        reserves.materializeAccrued(2);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IUSDfr.USDfr_TransferNotAllowed.selector, address(0), treasury2));
        reserves.materializeAccrued(3);
        vm.prank(carol);
        (uint256 seniorB, uint256 feeB) = reserves.materializeAccrued(1);
        assertEq(seniorB, 0, "already delivered this block");
        assertEq(feeB, 0, "fee leg not selected");
        vm.expectRevert(abi.encodeWithSelector(IUSDfr.USDfr_TransferNotAllowed.selector, address(0), treasury2));
        waterfall.setFeeRecipient(ops);
        // The rate can still be changed prospectively, but the standing claim keeps the trap shut.
        waterfall.setProtocolFee(0);
        assertEq(reserves.accrualSnapshot().feeUnissued, fee1, "the standing claim survives the rate change");
        vm.expectRevert(abi.encodeWithSelector(IUSDfr.USDfr_TransferNotAllowed.selector, address(0), treasury2));
        waterfall.setFeeRecipient(ops);

        // Losses and receipts are not held hostage: the declaration, the loss and a recovery
        // receipt all complete with the fee claim standing.
        uint256 supplyBefore = usdfr.totalSupply();
        _declareDefault(id, keccak256("auth-r1-fee-default"));
        uint256 faceAtDefault = reserves.deployedTo(id);
        _realizeLoss(id, 100_000e18, bytes32(0));
        assertEq(reserves.deployedTo(id), faceAtDefault - 100_000e18, "loss written down");
        assertEq(reserves.accrualSnapshot().feeUnissued, fee1, "the fee claim on unreceived interest is retained");
        assertLt(usdfr.totalSupply(), supplyBefore, "the cascade burned");
        _repay(id, 0, 100_000e18);
        assertEq(reserves.deployedTo(id), faceAtDefault - 200_000e18, "recovery receipt settled");
        assertEq(reserves.accrualSnapshot().feeUnissued, fee1, "the fee claim is still standing after the receipt");

        // The escape is on the compliance side: unblock, and the rotation delivers fee1.
        compliance.setJurisdictionBlocked(treasury2, false);
        waterfall.setFeeRecipient(ops);
        assertEq(usdfr.balanceOf(treasury2), fee1, "the trapped claim was delivered at the rotation");
        assertEq(reserves.accrualSnapshot().feeRecipient, ops, "rotated back");
    }

    // ── C3 ────────────────────────────────────────────────────────────────

    function test_auth_trustedCallbacksRefuseEveryWrongCallerAndEveryWrongArgument() public onFork {
        _mintFromUSDC(alice, 3_000_000e6);
        _stake(alice, 1_000_000e18);
        uint256 t0 = block.timestamp;
        uint256 cashId = _originateAndFund(1_000_000e18);
        uint256 pikId = _originatePik(100_000e18, uint64(t0 + 360 days), 90 days);
        IContinuousAccrual.Modules memory m = reserves.accrualModules();

        // (a) The PIK crank, driven by carol, is what makes the reserve call the bridge's
        //     reserve-only setter; the bridge's date follows the engine and nothing else may move it.
        _warp(90 days);
        vm.prank(carol);
        (uint256 processed, bool fresh) = reserves.checkpointAccrual(32);
        assertEq(processed, 1, "one boundary processed");
        assertTrue(fresh, "fresh");
        assertEq(bridge.facility(pikId).nextPaymentDue, t0 + 180 days, "the bridge followed the engine");
        assertEq(reserves.accruedDebt(pikId).nextCapitalization, t0 + 180 days, "the engine's next date");
        // The default manager prices delinquency on the engine's date: 21 days past the OLD date
        // and it is not past due, because the crank advanced the due date with the capitalisation.
        _warp(21 days + 1);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_NotPastDue.selector, pikId, uint64(t0 + 180 days), uint64(t0 + 201 days)
            )
        );
        defaultManager.markPastDue(pikId);

        // Carol, the waterfall and the default manager are all refused by name.
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_AccrualReserveOnly.selector, carol));
        bridge.setAccruedPaymentDue(pikId, uint64(t0 + 270 days));
        vm.prank(m.waterfall);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_AccrualReserveOnly.selector, m.waterfall));
        bridge.setAccruedPaymentDue(pikId, uint64(t0 + 270 days));
        vm.prank(m.defaultManager);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_AccrualReserveOnly.selector, m.defaultManager));
        bridge.setAccruedPaymentDue(pikId, uint64(t0 + 270 days));
        // The trusted reserve itself is refused a backwards date, a date past maturity and a cash note.
        vm.prank(address(reserves));
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.setAccruedPaymentDue(pikId, uint64(t0 + 180 days));
        vm.prank(address(reserves));
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.setAccruedPaymentDue(pikId, uint64(t0 + 360 days + 1));
        vm.prank(address(reserves));
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.setAccruedPaymentDue(cashId, uint64(t0 + 90 days));
        // The legacy CREDIT_ROLE setter is closed on a PIK note under continuous accrual.
        vm.prank(m.waterfall);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_AccrualDueManaged.selector, pikId));
        bridge.setNextPaymentDue(pikId, uint64(t0 + 270 days));
        assertEq(bridge.facility(pikId).nextPaymentDue, t0 + 180 days, "no refused call moved the date");

        // (b) The delivery permit: one materialisation, then every replay and redirection.
        vm.recordLogs();
        vm.prank(carol);
        (uint256 senior,) = reserves.materializeAccrued(1);
        assertGt(senior, 0, "a delivery happened");
        uint256 supply = usdfr.totalSupply();
        uint256 nonce = _materializedNonce(vm.getRecordedLogs());
        assertEq(nonce, 1, "the first delivery of this run consumed nonce 1");
        vm.prank(carol);
        vm.expectRevert(ControllerAccrualLib.ControllerAccrual_InvalidDelivery.selector);
        controller.mintAccrued(nonce);
        vm.prank(carol);
        vm.expectRevert(ControllerAccrualLib.ControllerAccrual_InvalidDelivery.selector);
        controller.mintAccrued(nonce + 1);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.MINTER_ROLE)
        );
        usdfr.mintAccrued(nonce);
        vm.prank(m.controller);
        vm.expectRevert(abi.encodeWithSelector(USDfr.USDfr_AccrualNonceUsed.selector, nonce, nonce));
        usdfr.mintAccrued(nonce);
        vm.prank(m.controller);
        vm.expectRevert(abi.encodeWithSelector(USDfr.USDfr_InvalidAccrualDelivery.selector, nonce + 1));
        usdfr.mintAccrued(nonce + 1);
        vm.prank(address(reserves));
        vm.expectRevert(ControllerAccrualLib.ControllerAccrual_InvalidDelivery.selector);
        controller.mintAccrued(nonce);
        vm.prank(address(reserves));
        vm.expectRevert(ControllerAccrualLib.ControllerAccrual_InvalidDelivery.selector);
        controller.mintAccrued(nonce + 1);
        assertEq(usdfr.totalSupply(), supply, "no replay minted");

        // (c) The default manager's three reserve-only risk callbacks.
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(DefaultAccrualLib.DefaultAccrual_CallerNotReserve.selector, carol));
        defaultManager.onAccrualPosted(cashId, 1);
        vm.prank(m.waterfall);
        vm.expectRevert(abi.encodeWithSelector(DefaultAccrualLib.DefaultAccrual_CallerNotReserve.selector, m.waterfall));
        defaultManager.onAccrualPosted(cashId, 1);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(DefaultAccrualLib.DefaultAccrual_CallerNotReserve.selector, carol));
        defaultManager.onAccrualRounding(cashId, 1);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(DefaultAccrualLib.DefaultAccrual_CallerNotReserve.selector, carol));
        defaultManager.onAccrualOpening(cashId, 1);
        // The trusted reserve on an unmarked facility: posting is refused, rounding is a silent
        // no-op, an opening is refused outside a migration.
        vm.prank(address(reserves));
        vm.expectRevert(abi.encodeWithSelector(DefaultAccrualLib.DefaultAccrual_NotMarked.selector, cashId));
        defaultManager.onAccrualPosted(cashId, 1);
        uint256 revision = defaultManager.impairmentRevision();
        vm.prank(address(reserves));
        defaultManager.onAccrualRounding(cashId, 1);
        assertEq(defaultManager.impairmentRevision(), revision, "unmarked rounding changed nothing");
        assertEq(defaultManager.pastDueExposure(), 0, "no past-due carrier moved");
        vm.prank(address(reserves));
        vm.expectRevert(DefaultAccrualLib.DefaultAccrual_OperationInProgress.selector);
        defaultManager.onAccrualOpening(cashId, 0);

        // (d) The registry's two reserve-only exposure callbacks.
        uint256 classBefore = registry.classExposure(FILM);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(CollateralRegistry.Registry_AccrualReserveOnly.selector, carol));
        registry.recordAccruedExposure(FILM, BORROWER, STATE, 1);
        vm.prank(m.defaultManager);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralRegistry.Registry_AccrualReserveOnly.selector, m.defaultManager)
        );
        registry.recordAccruedExposure(FILM, BORROWER, STATE, 1);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(CollateralRegistry.Registry_AccrualReserveOnly.selector, carol));
        registry.recordAccruedWriteDown(FILM, BORROWER, STATE, 1);
        vm.prank(m.waterfall);
        vm.expectRevert(abi.encodeWithSelector(CollateralRegistry.Registry_AccrualReserveOnly.selector, m.waterfall));
        registry.recordAccruedWriteDown(FILM, BORROWER, STATE, 1);
        assertEq(registry.classExposure(FILM), classBefore, "no refused call moved exposure");

        // (e) The waterfall's fee synchronisation and the reserve's write-down, from the wrong module.
        vm.prank(m.defaultManager);
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_NotWaterfall.selector);
        reserves.setAccrualFee(1000, ops);
        vm.prank(m.waterfall);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveAccrualCreditLib.AccrualCredit_WrongCaller.selector, m.defaultManager, m.waterfall
            )
        );
        reserves.recordPrincipalWritedown(cashId, 1);
        vm.prank(m.defaultManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveAccrualCreditLib.AccrualCredit_WrongCaller.selector, m.waterfall, m.defaultManager
            )
        );
        reserves.repayAccruingLoan(cashId, borrower, 0, 1e12);
        vm.prank(m.bridge);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveAccrualCreditLib.AccrualCredit_WrongCaller.selector, m.defaultManager, m.bridge
            )
        );
        reserves.stopAccruingLoan(cashId);
        assertTrue(reserves.accruedDebt(cashId).active, "the cash note still accrues");
    }

    // ── helpers ───────────────────────────────────────────────────────────

    function _carriers(uint256 id) internal view returns (Carriers memory c) {
        c.redemptionAssets = vault.redemptionTotalAssets();
        c.totalAssets = vault.totalAssets();
        c.pendingSeniorImpairment = defaultManager.pendingSeniorImpairment();
        c.performanceImpairment = defaultManager.performanceFeeImpairment();
        c.riskHash = defaultManager.impairmentRiskStateHash();
        c.stateHash = defaultManager.impairmentStateHash();
        c.revision = defaultManager.impairmentRevision();
        c.pastDueExposure = defaultManager.pastDueExposure();
        c.contribution = defaultManager.pastDueContribution(id);
        c.pastDuePrincipal = defaultManager.pastDuePrincipal(FILM);
        c.cohort = reserves.accruedPastDue(FILM);
        c.unposted = reserves.unpostedAccruedLoan(id);
        c.classExposure = registry.classExposure(FILM);
        c.borrowerExposure = registry.borrowerExposure(BORROWER);
        c.stateExposure = registry.stateExposure(STATE);
        c.totalExposure = registry.totalBookExposure();
        c.deployedTo = reserves.deployedTo(id);
        c.deployedPrincipal = reserves.deployedPrincipal();
        c.backing = reserves.totalBackingValue();
        c.recognizedBacking = reserves.recognizedBackingValue();
        IContinuousAccrual.Snapshot memory s = reserves.accrualSnapshot();
        c.gross = s.gross;
        c.unissued = s.unissued;
        c.supply = usdfr.totalSupply();
        c.deficit = controller.recognizedDeficit();
        c.rate = vault.convertToAssets(1e18);
        c.exitRate = vault.previewRedeem(1e18);
    }

    /// @dev Every quantity a consumer prices on is identical to the wei; only the reserve's own
    ///      split between recorded and unposted may move.
    function _assertConsumersUnchanged(Carriers memory a, Carriers memory b, string memory what) internal pure {
        assertEq(b.redemptionAssets, a.redemptionAssets, string.concat(what, ": redemption assets moved"));
        assertEq(b.totalAssets, a.totalAssets, string.concat(what, ": total assets moved"));
        assertEq(b.pendingSeniorImpairment, a.pendingSeniorImpairment, string.concat(what, ": senior mark moved"));
        assertEq(b.performanceImpairment, a.performanceImpairment, string.concat(what, ": performance mark moved"));
        assertEq(b.riskHash, a.riskHash, string.concat(what, ": risk hash moved"));
        assertEq(b.stateHash, a.stateHash, string.concat(what, ": state hash moved"));
        assertEq(b.revision, a.revision, string.concat(what, ": revision advanced"));
        assertEq(b.pastDueExposure, a.pastDueExposure, string.concat(what, ": global pool moved"));
        assertEq(b.contribution, a.contribution, string.concat(what, ": contribution moved"));
        assertEq(b.pastDuePrincipal, a.pastDuePrincipal, string.concat(what, ": class pool moved"));
        assertEq(b.classExposure, a.classExposure, string.concat(what, ": class exposure moved"));
        assertEq(b.borrowerExposure, a.borrowerExposure, string.concat(what, ": borrower exposure moved"));
        assertEq(b.stateExposure, a.stateExposure, string.concat(what, ": state exposure moved"));
        assertEq(b.totalExposure, a.totalExposure, string.concat(what, ": total exposure moved"));
        assertEq(b.deployedTo, a.deployedTo, string.concat(what, ": deployedTo moved"));
        assertEq(b.deployedPrincipal, a.deployedPrincipal, string.concat(what, ": deployed principal moved"));
        assertEq(b.backing, a.backing, string.concat(what, ": backing moved"));
        assertEq(b.recognizedBacking, a.recognizedBacking, string.concat(what, ": recognised backing moved"));
        assertEq(b.gross, a.gross, string.concat(what, ": gross moved"));
        assertEq(b.unissued, a.unissued, string.concat(what, ": unissued moved"));
        assertEq(b.supply, a.supply, string.concat(what, ": supply moved"));
        assertEq(b.deficit, a.deficit, string.concat(what, ": deficit moved"));
        assertEq(b.rate, a.rate, string.concat(what, ": share price moved"));
        assertEq(b.exitRate, a.exitRate, string.concat(what, ": exit price moved"));
    }

    function _postFirstLossOps(uint256 usdfrAmount) internal {
        _mintFromUSDC(ops, usdfrAmount / SCALE + 50_000e6);
        vm.startPrank(ops);
        usdfr.approve(address(curator), usdfrAmount);
        curator.postFirstLoss(FILM, usdfrAmount);
        vm.stopPrank();
    }

    function _fundCoverageOps(uint256 usdfrAmount) internal {
        _mintFromUSDC(ops, usdfrAmount / SCALE + 50_000e6);
        vm.startPrank(ops);
        usdfr.approve(address(sGrove), usdfrAmount);
        sGrove.fundCoverage(usdfrAmount);
        vm.stopPrank();
    }

    function _clearPastDueOps(uint256 tokenId, bytes32 evidence) internal {
        _attest(tokenId, IAttestationOracle.AttestationKind.PastDueCured, keccak256(abi.encode(tokenId, evidence)));
        vm.prank(ops);
        defaultManager.clearPastDue(tokenId, evidence);
    }

    function _originatePik(uint256 principal, uint64 maturity, uint64 interval) internal returns (uint256 id) {
        ClaimBridge.OriginationTerms memory t = _forkTermsFor(
            FILM, keccak256("AUTH_PIK_BORROWER"), STATE, principal, 7500, 1400, maturity, keccak256("auth-r1-pik")
        );
        t.pik = true;
        t.paymentInterval = interval;
        t.nextPaymentDue = uint64(block.timestamp) + interval;
        id = bridge.totalOriginated() + 1;
        bytes32 termsHash = bridge.creditTermsHash(t);
        _attest(id, IAttestationOracle.AttestationKind.CreditIssued, termsHash);
        _attest(id, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash);
        _attest(id, IAttestationOracle.AttestationKind.UCCFiled, termsHash);
        vm.prank(ops);
        uint256 minted = bridge.originate(ops, t);
        assertEq(minted, id, "PIK facility id");
        vm.prank(ops);
        waterfall.fund(id, principal / SCALE);
    }

    /// @dev Assert that exactly one (tokenId, classId, amount) event of the given signature was
    ///      emitted by `emitter` within the recorded logs, with the expected non-indexed amount.
    function _assertLogged(
        Vm.Log[] memory logs,
        address emitter,
        bytes32 sig,
        uint256 tokenId,
        uint256 classId,
        uint256 amount,
        string memory what
    ) internal pure {
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != emitter || logs[i].topics[0] != sig) continue;
            assertEq(uint256(logs[i].topics[1]), tokenId, string.concat(what, ": tokenId"));
            assertEq(uint256(logs[i].topics[2]), classId, string.concat(what, ": classId"));
            assertEq(abi.decode(logs[i].data, (uint256)), amount, string.concat(what, ": amount"));
            ++seen;
        }
        assertEq(seen, 1, string.concat(what, ": emitted exactly once"));
    }

    /// @dev From one declaration's logs: the remainder the close posted (AccruedLoanPosted
    ///      amount, since nothing else was unposted), and the AccrualLoanAligned figures.
    function _closeFigures(Vm.Log[] memory logs, uint256 id)
        internal
        view
        returns (uint256 posted, uint256 correction, uint256 roundingLoss)
    {
        bytes32 postedSig = keccak256("AccruedLoanPosted(uint256,address,uint256,uint256)");
        bytes32 alignedSig = keccak256("AccrualLoanAligned(uint256,uint64,uint64,uint256,uint256,bool)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(reserves) || uint256(logs[i].topics[1]) != id) continue;
            if (logs[i].topics[0] == postedSig) {
                (uint256 amount,) = abi.decode(logs[i].data, (uint256, uint256));
                posted += amount;
            } else if (logs[i].topics[0] == alignedSig) {
                (, uint256 pos, uint256 loss,) = abi.decode(logs[i].data, (uint64, uint256, uint256, bool));
                correction = pos;
                roundingLoss = loss;
            }
        }
    }

    /// @dev Recover the delivery nonce from the reserve's own AccrualMaterialized event.
    function _materializedNonce(Vm.Log[] memory logs) internal view returns (uint256 nonce) {
        bytes32 sig = keccak256("AccrualMaterialized(uint256,uint64,uint8,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(reserves) && logs[i].topics[0] == sig) {
                nonce = uint256(logs[i].topics[1]);
            }
        }
        assertGt(nonce, 0, "an AccrualMaterialized event was emitted");
    }
}
