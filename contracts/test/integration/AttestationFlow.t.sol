// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {Config} from "../../src/libraries/Config.sol";
import {RealOracleFixture} from "../helpers/RealOracleFixture.sol";

/// @dev The brief's lifecycle flows with NO mock anywhere: every gate runs on real
///      EIP-712 m-of-n attester signatures through the production AttestationOracle —
///      originate (mint gate) → fund → attested repayment (payment gate, consumed) →
///      attested default → cascade; the ADR-0015 margin path on 2-of-n signed marks;
///      and the marked-to-market credit path.
contract AttestationFlowTest is RealOracleFixture {
    uint256 internal constant FILM = 1;

    function _stake(address who, uint256 usdcAmount) internal {
        _mintUSDfrTo(who, usdcAmount * 1e12);
        vm.startPrank(who);
        usdfr.approve(address(vault), usdcAmount * 1e12);
        vault.deposit(usdcAmount * 1e12, who);
        vm.stopPrank();
    }

    /// @notice Full performing lifecycle where every material event is a verified
    ///         signature bundle, and each PaymentReceived authorizes EXACTLY one
    ///         distribution (consumed on use).
    function test_realSigs_performingLifecycleAndSingleUsePayments() public {
        _stake(alice, 2_000_000e6);
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 1_000_000e18); // real signed mint gate
        _fundFacility(id, 1_000_000e18);

        // attested payment distributes once…
        _repay(id, 40_000e18, 500_000e18);
        assertEq(reserves.deployedTo(id), 500_000e18);

        // …and its attestation is SPENT: replaying the identical distribution without
        // a fresh attested receipt must fail (the ADR-0020 single-use guarantee)
        usdc.mint(borrower, 540_000e6);
        vm.prank(borrower);
        usdc.approve(address(reserves), 540_000e6);
        IWaterfallEngine.Payment memory payment = IWaterfallEngine.Payment({
            tokenId: id,
            paymentId: _paymentId(id, 40_000e18, 500_000e18),
            payer: borrower,
            interest: 40_000e18,
            principal: 500_000e18,
            nextPaymentDue: _nextDue(id, 500_000e18)
        });
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PaymentNotAttested.selector, id));
        vm.prank(servicer);
        waterfall.distribute(payment);

        // a mismatched amount against a fresh attestation also fails
        _attestPayment(id, 40_000e18, 500_000e18);
        IWaterfallEngine.Payment memory mismatched = IWaterfallEngine.Payment({
            tokenId: payment.tokenId,
            paymentId: payment.paymentId,
            payer: payment.payer,
            interest: payment.interest,
            principal: 499_999e18,
            nextPaymentDue: payment.nextPaymentDue
        });
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PaymentNotAttested.selector, id));
        vm.prank(servicer);
        waterfall.distribute(mismatched);

        // the honest one closes the facility
        vm.prank(servicer);
        waterfall.distribute(payment);
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Repaid));
        assertTrue(controller.backingInvariantHolds());
    }

    /// @notice Attested default → recovery → cascade, all on real signatures.
    function test_realSigs_defaultAndCascade() public {
        _stake(alice, 2_000_000e6);
        _postFirstLoss(anchorCurator, FILM, 300_000e18);
        uint256 id = _liveFilmFacility(1_000_000e18);

        _attestDefault(id); // real DefaultDeclared signature
        vm.startPrank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        vm.stopPrank();

        _repay(id, 0, 800_000e18); // attested recovery
        vm.prank(servicer);
        _realizeLoss(id, 200_000e18, FILM_REF);
        assertEq(curator.poolBalance(FILM), 100_000e18, "first-loss absorbed the shortfall");
        assertEq(registry.classExposure(FILM), 0);
        assertTrue(controller.backingInvariantHolds());
    }

    /// @notice ADR-0015 margin path on 2-of-n signed marks: slide → permissionless
    ///         margin call → deeper slide → liquidation → recovery → cascade.
    function test_realSigs_mtmMarginPathOnSignedMarks() public {
        _stake(alice, 2_000_000e6);
        _postFirstLoss(anchorCurator, Config.CLASS_DIGITAL_ASSETS, 150_000e18);
        uint256 id = _originateDigital(500_000e18, 1_000_000e18); // mark signed 2-of-n
        _fundFacility(id, 500_000e18);

        vm.warp(block.timestamp + 1 hours);
        _setValuation(id, 750_000e18, uint64(block.timestamp)); // fresh signed slide
        defaultManager.marginCall(id);
        assertGt(defaultManager.cureDeadline(id), 0);

        vm.warp(block.timestamp + 2 hours);
        _setValuation(id, 590_000e18, uint64(block.timestamp)); // gap move, signed
        defaultManager.liquidate(id);
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Defaulted));

        _repay(id, 0, 430_000e18); // attested custodian proceeds
        vm.prank(servicer);
        _realizeLoss(id, 70_000e18, FILM_REF);
        assertEq(curator.poolBalance(Config.CLASS_DIGITAL_ASSETS), 80_000e18);
        assertTrue(controller.backingInvariantHolds());
    }
}
