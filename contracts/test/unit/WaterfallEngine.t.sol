// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {WaterfallEngine} from "../../src/WaterfallEngine.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {MockAttestationOracle} from "../helpers/MockAttestationOracle.sol";

contract WaterfallReserveProbe {
    address internal immutable stable;
    uint256 internal outstanding;
    uint256 internal receipt;

    constructor(address stable_) {
        stable = stable_;
    }

    function configure(uint256 outstanding_, uint256 receipt_) external {
        outstanding = outstanding_;
        receipt = receipt_;
    }

    function usdc() external view returns (address) {
        return stable;
    }

    function denormalizeUSDC(uint256 value) external pure returns (uint256) {
        return value / 1e12;
    }

    function deployedTo(uint256) external view returns (uint256) {
        return outstanding;
    }

    function recordPayment(uint256, address, uint256, uint256) external view returns (uint256) {
        return receipt;
    }
}

contract FalseBackingController {
    function backingInvariantHolds() external pure returns (bool) {
        return false;
    }

    function mintYield(address, uint256) external pure {}
}

contract WaterfallEngineTest is CreditLayerFixture {
    function _probeWaterfall(address reserve, address controller_) internal returns (WaterfallEngine probe) {
        probe = WaterfallEngine(
            address(
                new ERC1967Proxy(
                    address(new WaterfallEngine()),
                    abi.encodeCall(
                        WaterfallEngine.initialize,
                        (
                            admin,
                            guardian,
                            admin,
                            WaterfallEngine.InitModules({
                                bridge: address(bridge),
                                registry: address(registry),
                                reserves: reserve,
                                controller: controller_,
                                vault: address(vault),
                                feeRecipient: feeRecipient,
                                oracle: address(oracle)
                            })
                        )
                    )
                )
            )
        );
        vm.startPrank(admin);
        probe.grantRole(Roles.SERVICER_ROLE, servicer);
        bridge.grantRole(Roles.CREDIT_ROLE, address(probe));
        registry.grantRole(Roles.CREDIT_ROLE, address(probe));
        vm.stopPrank();
    }

    function _attestProbePayment(IWaterfallEngine.Payment memory payment, address stable) internal {
        MockAttestationOracle(address(oracle)).setPayload(
            payment.tokenId,
            IAttestationOracle.AttestationKind.PaymentReceived,
            keccak256(
                abi.encode(
                    payment.paymentId,
                    payment.tokenId,
                    stable,
                    payment.payer,
                    (payment.interest + payment.principal) / 1e12,
                    payment.interest,
                    payment.principal,
                    payment.nextPaymentDue
                )
            ),
            uint64(block.timestamp),
            true
        );
    }

    function test_initialize_rejectsEveryZeroPrincipalAndModule() public {
        WaterfallEngine impl = new WaterfallEngine();
        address[10] memory args = [
            admin,
            guardian,
            admin,
            address(bridge),
            address(registry),
            address(reserves),
            address(controller),
            address(vault),
            feeRecipient,
            address(oracle)
        ];
        for (uint256 i; i < args.length; ++i) {
            address saved = args[i];
            args[i] = address(0);
            WaterfallEngine.InitModules memory m = WaterfallEngine.InitModules({
                bridge: args[3],
                registry: args[4],
                reserves: args[5],
                controller: args[6],
                vault: args[7],
                feeRecipient: args[8],
                oracle: args[9]
            });
            vm.expectRevert(IWaterfallEngine.Waterfall_ZeroAddress.selector);
            new ERC1967Proxy(address(impl), abi.encodeCall(WaterfallEngine.initialize, (args[0], args[1], args[2], m)));
            args[i] = saved;
        }
    }

    function test_fund_usesSignedRecipientAndCapitalizesOID() public {
        _mintUSDfrTo(alice, 500_000e18);
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 500_000e18);
        uint256 recipientBefore = usdc.balanceOf(borrower);

        vm.expectEmit(true, true, false, true, address(waterfall));
        emit IWaterfallEngine.Funded(id, borrower, 500_000e18);
        vm.prank(servicer);
        waterfall.fund(id, 500_000e6);

        assertEq(usdc.balanceOf(borrower) - recipientBefore, 490_000e6, "recipient nets principal less 2% OID");
        assertEq(reserves.deployedTo(id), 500_000e18, "full claim remains outstanding");
        assertEq(usdfr.balanceOf(feeRecipient), 10_000e18, "OID minted to fee recipient");
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Active));
    }

    function test_fund_rejectsAmountMismatch() public {
        _mintUSDfrTo(alice, 500_000e18);
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 500_000e18);
        vm.prank(servicer);
        vm.expectRevert(
            abi.encodeWithSelector(IWaterfallEngine.Waterfall_PrincipalMismatch.selector, id, 500_000e18, 499_999e18)
        );
        waterfall.fund(id, 499_999e6);
    }

    function test_fund_onlyServicer() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.SERVICER_ROLE)
        );
        vm.prank(alice);
        waterfall.fund(1, 1);
    }

    function test_fund_rejectsAlreadyActiveFacility() public {
        uint256 id = _liveFilmFacility(100_000e18);
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_NotFundable.selector, id));
        waterfall.fund(id, 100_000e6);
    }

    function test_distribute_atomicallyPullsUSDCAndSplitsInterest() public {
        uint256 id = _liveFilmFacility(500_000e18);
        uint256 interest = 40_000e18;
        uint256 principal = 100_000e18;
        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        uint256 feeBefore = usdfr.balanceOf(feeRecipient);

        _repay(id, interest, principal);

        assertEq(reserves.deployedTo(id), 400_000e18);
        assertEq(usdc.balanceOf(address(reserves)), 150_000e6, "retained OID plus exact payment are idle");
        assertEq(usdfr.balanceOf(feeRecipient) - feeBefore, 4_000e18);
        assertEq(usdfr.balanceOf(address(vault)) - vaultBefore, 36_000e18);
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Amortizing));
        assertTrue(controller.backingInvariantHolds());
    }

    function test_distribute_fullProtocolFeeStillCheckpointsWithoutVaultDelivery() public {
        uint256 id = _liveFilmFacility(500_000e18);
        vm.prank(admin);
        waterfall.setProtocolFee(uint16(Config.BPS));

        uint256 interest = 40_000e18;
        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        uint256 feeBefore = usdfr.balanceOf(feeRecipient);
        _repay(id, interest, 0);

        assertEq(usdfr.balanceOf(feeRecipient) - feeBefore, interest, "all interest follows the configured fee");
        assertEq(usdfr.balanceOf(address(vault)), vaultBefore, "zero senior leg mints nothing to the vault");
        assertEq(vault.unvestedYield(), 0);
    }

    function test_distribute_rejectsZeroAndPendingFacility() public {
        IWaterfallEngine.Payment memory payment = IWaterfallEngine.Payment({
            tokenId: 1,
            paymentId: bytes32(0),
            payer: borrower,
            interest: 0,
            principal: 0,
            nextPaymentDue: 0
        });
        vm.prank(servicer);
        vm.expectRevert(IWaterfallEngine.Waterfall_ZeroAmount.selector);
        waterfall.distribute(payment);

        _mintUSDfrTo(alice, 100_000e18);
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 100_000e18);
        payment.tokenId = id;
        payment.interest = 1e18;
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_NotDistributable.selector, id));
        waterfall.distribute(payment);
    }

    function test_distribute_rejectsPrincipalAboveOutstanding() public {
        uint256 id = _liveFilmFacility(100_000e18);
        IWaterfallEngine.Payment memory payment = _preparePayment(id, 0, 100_001e18);
        vm.prank(servicer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWaterfallEngine.Waterfall_PrincipalExceedsOutstanding.selector, id, 100_001e18, 100_000e18
            )
        );
        waterfall.distribute(payment);
    }

    function test_distribute_rejectsDishonestReserveReceipt() public {
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 100_000e18);
        vm.prank(address(waterfall));
        bridge.transitionState(id, ClaimBridge.LoanState.Active);

        WaterfallReserveProbe reserveProbe = new WaterfallReserveProbe(address(usdc));
        reserveProbe.configure(0, 2e18);
        WaterfallEngine probe = _probeWaterfall(address(reserveProbe), address(new FalseBackingController()));
        IWaterfallEngine.Payment memory payment = IWaterfallEngine.Payment({
            tokenId: id,
            paymentId: keccak256("dishonest-receipt"),
            payer: borrower,
            interest: 1e18,
            principal: 0,
            nextPaymentDue: 0
        });
        _attestProbePayment(payment, address(usdc));

        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_BackingWouldBreak.selector, id));
        probe.distribute(payment);
    }

    function test_distribute_rejectsFalseFinalBackingAssertion() public {
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 100_000e18);
        vm.prank(address(waterfall));
        bridge.transitionState(id, ClaimBridge.LoanState.Active);

        WaterfallReserveProbe reserveProbe = new WaterfallReserveProbe(address(usdc));
        reserveProbe.configure(1e18, 1e18);
        WaterfallEngine probe = _probeWaterfall(address(reserveProbe), address(new FalseBackingController()));
        IWaterfallEngine.Payment memory payment = IWaterfallEngine.Payment({
            tokenId: id,
            paymentId: keccak256("false-backing"),
            payer: borrower,
            interest: 0,
            principal: 1e18,
            nextPaymentDue: 0
        });
        _attestProbePayment(payment, address(usdc));

        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_BackingWouldBreak.selector, id));
        probe.distribute(payment);
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Active), "revert is atomic");
    }

    function test_distribute_requiresExactPayerAmountAndDueDate() public {
        uint256 id = _liveFilmFacility(500_000e18);
        uint256 interest = 10_000e18;
        uint256 principal = 100_000e18;
        _fundPayment(interest, principal);
        _attestPayment(id, interest, principal);

        IWaterfallEngine.Payment memory payment = _payment(id, interest, principal);
        payment.payer = bob;
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PaymentNotAttested.selector, id));
        waterfall.distribute(payment);

        payment = _payment(id, interest, principal);
        payment.nextPaymentDue += 1;
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PaymentNotAttested.selector, id));
        waterfall.distribute(payment);

        payment = _payment(id, interest, principal);
        payment.interest += 1e18;
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PaymentNotAttested.selector, id));
        waterfall.distribute(payment);
    }

    function test_distribute_replayFailsBeforeSecondPull() public {
        uint256 id = _liveFilmFacility(500_000e18);
        uint256 interest = 10_000e18;
        uint256 principal = 100_000e18;
        _fundPayment(interest, principal);
        _attestPayment(id, interest, principal);
        IWaterfallEngine.Payment memory payment = _payment(id, interest, principal);

        vm.prank(servicer);
        waterfall.distribute(payment);
        uint256 reserveBefore = usdc.balanceOf(address(reserves));

        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PaymentNotAttested.selector, id));
        waterfall.distribute(payment);
        assertEq(usdc.balanceOf(address(reserves)), reserveBefore);
    }

    function test_distribute_withoutUSDCApprovalRevertsAtomically() public {
        uint256 id = _liveFilmFacility(500_000e18);
        _attestPayment(id, 10_000e18, 100_000e18);
        IWaterfallEngine.Payment memory payment = _payment(id, 10_000e18, 100_000e18);

        vm.prank(servicer);
        vm.expectRevert();
        waterfall.distribute(payment);
        assertEq(reserves.deployedTo(id), 500_000e18);
    }

    function test_distribute_fullPrincipalResolvesPerformingFacility() public {
        uint256 id = _liveFilmFacility(500_000e18);
        _repay(id, 10_000e18, 500_000e18);
        assertEq(reserves.deployedTo(id), 0);
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Repaid));
    }

    function test_distribute_servicesInterestAndPartialPrincipalAtTerminalDueDate() public {
        uint64 maturity = uint64(block.timestamp + 30 days);
        uint256 id = _liveBulletFacility(100_000e18, maturity);
        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        uint256 feeBefore = usdfr.balanceOf(feeRecipient);

        _repay(id, 10_000e18, 0);

        ClaimBridge.Facility memory afterInterest = bridge.facility(id);
        assertEq(afterInterest.nextPaymentDue, maturity, "terminal due date remains at maturity");
        assertEq(reserves.deployedTo(id), 100_000e18, "interest-only receipt leaves principal intact");
        assertEq(uint8(afterInterest.state), uint8(ClaimBridge.LoanState.Active));

        _repay(id, 5_000e18, 20_000e18);

        ClaimBridge.Facility memory afterPartial = bridge.facility(id);
        assertEq(afterPartial.nextPaymentDue, maturity, "partial receipt cannot advance beyond maturity");
        assertEq(reserves.deployedTo(id), 80_000e18, "partial principal receipt remains serviceable");
        assertEq(uint8(afterPartial.state), uint8(ClaimBridge.LoanState.Amortizing));
        assertEq(usdfr.balanceOf(address(vault)) - vaultBefore, 13_500e18, "senior interest is not stranded");
        assertEq(usdfr.balanceOf(feeRecipient) - feeBefore, 1_500e18, "protocol fee is still routed");
        assertTrue(controller.backingInvariantHolds());
    }

    function test_distribute_sameDueBeforeMaturityStillReverts() public {
        uint256 id = _liveFilmFacility(100_000e18);
        ClaimBridge.Facility memory f = bridge.facility(id);
        IWaterfallEngine.Payment memory payment = IWaterfallEngine.Payment({
            tokenId: id,
            paymentId: keccak256("non-terminal-same-due"),
            payer: borrower,
            interest: 1_000e18,
            principal: 0,
            nextPaymentDue: f.nextPaymentDue
        });
        _fundPayment(payment.interest, payment.principal);
        _attestProbePayment(payment, address(usdc));

        uint256 reserveBefore = usdc.balanceOf(address(reserves));
        vm.prank(servicer);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        waterfall.distribute(payment);

        assertEq(usdc.balanceOf(address(reserves)), reserveBefore, "rejected receipt is atomic");
        assertEq(bridge.facility(id).nextPaymentDue, f.nextPaymentDue);
    }

    function test_distribute_walksOneFacilityThroughItsFullSchedule() public {
        uint256 id = _liveFilmFacility(100_000e18);
        uint64 maturity = bridge.facility(id).maturity;

        // Exercise every monthly schedule transition, including an interest-only
        // receipt and the maturity-clamped terminal period. This deterministic
        // lifetime walk covers the long sequence that the broad invariant handler
        // is unlikely to select for one facility by chance.
        for (uint256 i; i < 13; ++i) {
            ClaimBridge.Facility memory beforePayment = bridge.facility(id);
            vm.warp(uint256(beforePayment.nextPaymentDue) - 1);
            uint256 principal = i == 5 ? 0 : 1_000e18;
            _repay(id, (i + 1) * 1_000e18, principal);
        }

        ClaimBridge.Facility memory terminal = bridge.facility(id);
        assertEq(terminal.nextPaymentDue, maturity, "schedule reaches and remains at maturity");
        assertEq(reserves.deployedTo(id), 88_000e18, "all twelve principal receipts recorded");
        assertEq(uint8(terminal.state), uint8(ClaimBridge.LoanState.Amortizing));
        assertTrue(controller.backingInvariantHolds());
    }

    function test_feeConfigurationBoundsAndPause() public {
        vm.prank(admin);
        waterfall.setProtocolFee(1200);
        assertEq(waterfall.protocolFeeBps(), 1200);

        vm.prank(admin);
        waterfall.setOriginationFee(Config.CLASS_FILM_TAX_CREDITS, Config.MAX_ORIGINATION_FEE_BPS);
        assertEq(waterfall.originationFeeBps(Config.CLASS_FILM_TAX_CREDITS), Config.MAX_ORIGINATION_FEE_BPS);

        vm.prank(guardian);
        waterfall.pause();
        vm.prank(servicer);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        waterfall.fund(1, 1);

        vm.prank(guardian);
        waterfall.unpause();
        assertFalse(waterfall.paused());
    }

    function test_feeConfiguration_rejectsAllBoundsAndZeroRecipient() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_BadFee.selector, uint16(10_001)));
        waterfall.setProtocolFee(10_001);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_UnknownClass.selector, 0));
        waterfall.setOriginationFee(0, 0);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_UnknownClass.selector, 6));
        waterfall.setOriginationFee(6, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWaterfallEngine.Waterfall_BadFee.selector, uint16(Config.MAX_ORIGINATION_FEE_BPS + 1)
            )
        );
        waterfall.setOriginationFee(Config.CLASS_FILM_TAX_CREDITS, uint16(Config.MAX_ORIGINATION_FEE_BPS + 1));
        vm.expectRevert(IWaterfallEngine.Waterfall_ZeroAddress.selector);
        waterfall.setFeeRecipient(address(0));
        vm.stopPrank();
    }

    function test_setFeeRecipient_andUpgradeAuthorization() public {
        address replacementRecipient = makeAddr("replacementFeeRecipient");
        vm.prank(admin);
        waterfall.setFeeRecipient(replacementRecipient);
        assertEq(waterfall.feeRecipient(), replacementRecipient);

        address newImpl = address(new WaterfallEngine());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.UPGRADER_ROLE)
        );
        vm.prank(alice);
        waterfall.upgradeToAndCall(newImpl, "");

        vm.prank(admin);
        waterfall.upgradeToAndCall(newImpl, "");
    }

    function _fundPayment(uint256 interest, uint256 principal) internal {
        uint256 units = (interest + principal) / 1e12;
        usdc.mint(borrower, units);
        vm.prank(borrower);
        usdc.approve(address(reserves), units);
    }

    function _payment(uint256 id, uint256 interest, uint256 principal)
        internal
        view
        returns (IWaterfallEngine.Payment memory)
    {
        return IWaterfallEngine.Payment({
            tokenId: id,
            paymentId: _paymentId(id, interest, principal),
            payer: borrower,
            interest: interest,
            principal: principal,
            nextPaymentDue: _nextDue(id, principal)
        });
    }

    function _liveBulletFacility(uint256 principal, uint64 maturity) internal returns (uint256 id) {
        _mintUSDfrTo(alice, principal);

        ClaimBridge.OriginationTerms memory terms = _facilityTerms(
            Config.CLASS_FILM_TAX_CREDITS,
            BORROWER_1,
            STATE_GA,
            principal,
            FILM_LTV_BPS,
            FILM_RATE_BPS,
            maturity,
            FILM_REF
        );
        terms.nextPaymentDue = maturity;
        terms.paymentScheduleHash = keccak256("fixture-bullet-schedule");

        uint256 nextId = bridge.totalOriginated() + 1;
        _setSatisfied(nextId, IAttestationOracle.AttestationKind.AssignmentExecuted, true);
        _setSatisfied(nextId, IAttestationOracle.AttestationKind.UCCFiled, true);
        _attestCreditTerms(nextId, bridge.creditTermsHash(terms));

        vm.prank(originator);
        id = bridge.originate(custodian, terms);
        _fundFacility(id, principal);
    }
}
