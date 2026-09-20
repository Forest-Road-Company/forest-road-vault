// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SGrove} from "../../src/SGrove.sol";
import {GroveToken} from "../../src/GroveToken.sol";
import {Vm} from "forge-std/Vm.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {ReserveRoundingLib} from "../../src/libraries/ReserveRoundingLib.sol";
import {ReserveAccrualLib} from "../../src/libraries/ReserveAccrualLib.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {RealOracleFixture} from "../helpers/RealOracleFixture.sol";

/// @dev Deliberately exhausts only the optional local points callback, to test retained proof gas.
contract AccrualDeliveryExhaustingPoints {
    function onUSDfrTransfer(address, address, uint256) external pure {
        assembly {
            for {} 1 {} {}
        }
    }
}

/// @dev A deliberately privileged optional hook probes governance during pre-loss fee settlement.
contract AccrualPreparationGovernanceProbe {
    ReserveManager private immutable reserve;
    address private immutable outsider;
    uint256 public attempts;
    uint256 public admitted;
    uint256 public wrongError;

    constructor(ReserveManager reserve_, address outsider_) {
        reserve = reserve_;
        outsider = outsider_;
    }

    function onSharesTransfer(address, address, uint256) external {
        _probe(abi.encodeCall(ReserveManager.pause, ()));
        _probe(abi.encodeWithSignature("grantRole(bytes32,address)", Roles.CREDIT_ROLE, outsider));
        _probe(abi.encodeCall(ReserveManager.setGuardianReserveLossArmsEnabled, (false)));
    }

    function _probe(bytes memory data) private {
        ++attempts;
        (bool ok, bytes memory reason) = address(reserve).call(data);
        if (ok) ++admitted;
        else if (bytes4(reason) != ReserveAccrualLib.ReserveAccrual_OperationInProgress.selector) ++wrongError;
    }
}

/// @dev Real reserve, controller, token, vault and credit proxies with genuine EIP-712 attestations.
///      Only reserve stablecoins and the deliberately failing optional hook are test fixtures.
contract ReserveAccrualDeliveryTest is RealOracleFixture {
    struct PayoffModel {
        uint256 principal;
        uint256 canonical;
        uint256 gross;
        uint256 loss;
        uint256 supply;
        uint256 vaultAssets;
        uint256 feeAssets;
    }

    SGrove private sGrove;
    uint64 private start;
    bool private emptyVaultFixture;
    uint256 private constant PRINCIPAL = 360_000e18;

    function setUp() public override {
        super.setUp();
        _installRealBackstop();
        start = uint64(block.timestamp);
        vm.startPrank(admin);
        ICollateralRegistry.ClassParams memory p = registry.classParams(1);
        p.concentrationLimitBps = 10_000;
        registry.setClass(1, p);
        registry.setBorrowerLimit(10_000);
        registry.setStateLimit(10_000);
        waterfall.setOriginationFee(1, 0);
        defaultManager.setWaterfall(address(waterfall));
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
        usdfr.setAccrualReserve(address(reserves));
        controller.enableContinuousAccrual();
        vault.setAccrualReserve(address(reserves));
        registry.setAccrualReserve(address(reserves));
        bridge.setAccrualReserve(address(reserves));
        waterfall.setAccrualReserve(address(reserves));
        defaultManager.setAccrualReserve(address(reserves));
        reserves.enableContinuousAccrual();
        vm.stopPrank();
        _mintUSDfrTo(alice, 1_000_000e18);
        if (emptyVaultFixture) return;
        vm.startPrank(alice);
        usdfr.approve(address(vault), 800_000e18);
        vault.deposit(800_000e18, alice);
        vm.stopPrank();
    }

    /// @dev Actual governance token and sGROVE implementations; all coverage is explicitly funded.
    function _installRealBackstop() private {
        GroveToken grove = GroveToken(
            address(
                new ERC1967Proxy(
                    address(new GroveToken()), abi.encodeCall(GroveToken.initialize, (admin, admin, feeRecipient))
                )
            )
        );
        sGrove = SGrove(
            address(
                new ERC1967Proxy(
                    address(new SGrove()),
                    abi.encodeCall(
                        SGrove.initialize, (admin, guardian, admin, address(grove), address(usdfr), address(vault))
                    )
                )
            )
        );
        vm.startPrank(admin);
        sGrove.grantRole(Roles.CREDIT_ROLE, address(defaultManager));
        sGrove.grantRole(Roles.CREDIT_ROLE, address(reserves));
        vault.grantRole(Roles.FEE_ACCOUNTING_ROLE, address(sGrove));
        defaultManager.setBackstop(address(sGrove));
        reserves.setReserveLossModules(
            address(curator),
            address(sGrove),
            address(vault),
            address(reserveLossGovernor),
            address(reserveLossTimelock)
        );
        vm.stopPrank();
        vm.prank(admin);
        compliance.setProtocolExempt(address(sGrove), true);
    }

    function _fundCoverage(uint256 amount) private {
        _mintUSDfrTo(bob, amount);
        vm.startPrank(bob);
        usdfr.approve(address(sGrove), amount);
        sGrove.fundCoverage(amount);
        vm.stopPrank();
    }

    function _loan(address asset, bool pik, uint256 principal, uint16 rate) private returns (uint256 id) {
        return _classLoan(1, asset, pik, principal, rate);
    }

    function _classLoan(uint256 classId, address asset, bool pik, uint256 principal, uint16 rate)
        private
        returns (uint256 id)
    {
        id = bridge.totalOriginated() + 1;
        ClaimBridge.OriginationTerms memory t = _facilityTerms(
            classId,
            BORROWER_1,
            classId == 1 ? STATE_GA : bytes32(0),
            principal,
            registry.classParams(classId).maxLtvBps,
            rate,
            start + 360 days,
            FILM_REF
        );
        t.pik = pik;
        t.paymentInterval = 90 days;
        t.nextPaymentDue = start + 90 days;
        _setSatisfied(id, IAttestationOracle.AttestationKind.AssignmentExecuted, true);
        _setSatisfied(id, IAttestationOracle.AttestationKind.UCCFiled, true);
        _attestCreditTerms(id, bridge.creditTermsHash(t));
        if (classId == 5) _setValuation(id, principal * 2, uint64(block.timestamp));
        vm.prank(originator);
        assertEq(bridge.originate(custodian, t), id);
        assertEq(asset, address(usdc), "native reserve is canonical USDC only");
        _fundFacility(id, principal);
    }

    function _repay(uint256 id, address asset, uint256 principal, uint256 interest, uint64 nextDue) private {
        uint256 units = (principal + interest) / 1e12;
        bytes32 paymentId = keccak256(abi.encode("root accrual receipt", id, ++nonceCounter));
        MockERC20(asset).mint(borrower, units);
        vm.prank(borrower);
        MockERC20(asset).approve(address(reserves), units);
        _attest(
            id,
            IAttestationOracle.AttestationKind.PaymentReceived,
            keccak256(abi.encode(paymentId, id, asset, borrower, units, interest, principal, nextDue)),
            uint64(block.timestamp)
        );
        vm.prank(servicer);
        waterfall.distribute(IWaterfallEngine.Payment(id, paymentId, borrower, interest, principal, nextDue));
    }

    function test_deliveryProvesBothPhysicalLegsAndPreservesEveryEconomicPrice() public {
        _loan(address(usdc), false, PRINCIPAL, 1000);
        vm.warp(start + 30 days);
        IContinuousAccrual.Snapshot memory b = reserves.accrualSnapshot();
        uint256 rawSupply = usdfr.totalSupply();
        uint256 rawVault = usdfr.balanceOf(address(vault));
        uint256 rawFee = usdfr.balanceOf(feeRecipient);
        uint256 supply = controller.totalUSDfr();
        uint256 backing = reserves.totalBackingValue();
        uint256 assets = vault.totalAssets();
        uint256 shares = vault.previewDeposit(100e18);
        (uint256 senior, uint256 fee) = reserves.materializeAccrued(3);
        assertEq(senior, b.seniorUnissued);
        assertEq(fee, b.feeUnissued);
        assertGt(senior, 0);
        assertGt(fee, 0);
        assertEq(usdfr.totalSupply(), rawSupply + b.unissued);
        assertEq(usdfr.balanceOf(address(vault)), rawVault + senior);
        assertEq(usdfr.balanceOf(feeRecipient), rawFee + fee);
        assertEq(controller.totalUSDfr(), supply);
        assertEq(reserves.totalBackingValue(), backing);
        assertEq(vault.totalAssets(), assets);
        assertEq(vault.previewDeposit(100e18), shares);
        assertEq(reserves.accrualSnapshot().unissued, 0);
        assertFalse(reserves.accrualDelivery().active);
        reserves.requireAccrualFresh();
    }

    function test_selectedDeliveryLeavesTheOtherFeeOrSeniorClaimOwned() public {
        _loan(address(usdc), true, PRINCIPAL, 1000);
        vm.warp(start + 45 days);
        IContinuousAccrual.Snapshot memory b = reserves.accrualSnapshot();
        uint256 backing = reserves.totalBackingValue();
        uint256 supply = controller.totalUSDfr();
        reserves.materializeAccrued(2);
        assertEq(reserves.accrualSnapshot().feeUnissued, 0);
        assertEq(reserves.accrualSnapshot().seniorUnissued, b.seniorUnissued);
        reserves.materializeAccrued(1);
        assertEq(reserves.accrualSnapshot().unissued, 0);
        assertEq(reserves.totalBackingValue(), backing);
        assertEq(controller.totalUSDfr(), supply);
        reserves.materializeAccrued(3);
        assertEq(controller.totalUSDfr(), supply, "empty delivery cannot replay issuance");
    }

    function test_pausedDeliveryStillMaterializesExistingClaims() public {
        _loan(address(usdc), false, PRINCIPAL, 1000);
        vm.warp(start + 12 days);
        uint256 supply = controller.totalUSDfr();
        vm.startPrank(guardian);
        usdfr.pause();
        controller.pause();
        vault.pause();
        reserves.pause();
        vm.stopPrank();
        reserves.materializeAccrued(3);
        assertEq(controller.totalUSDfr(), supply);
        assertEq(reserves.accrualSnapshot().unissued, 0);
        assertTrue(usdfr.paused() && controller.paused() && vault.paused() && reserves.paused());
    }

    function test_failingOptionalHooksLeaveGasForBothLegsAndReserveProofs() public {
        _loan(address(usdc), false, PRINCIPAL, 1000);
        vm.warp(start + 12 days);
        uint256 supply = controller.totalUSDfr();
        address hook = address(new AccrualDeliveryExhaustingPoints());
        vm.prank(admin);
        usdfr.setPointsModule(hook);
        (bool ok,) = address(reserves).call{gas: 3_000_000}(abi.encodeCall(ReserveManager.materializeAccrued, (3)));
        assertTrue(ok, "caller retained enough gas to prove and close both failed optional hooks");
        assertEq(controller.totalUSDfr(), supply);
        assertEq(reserves.accrualSnapshot().unissued, 0);
        assertFalse(reserves.accrualDelivery().active);
    }

    function test_underfundedDeliveryRevertsEveryClaimAndPhysicalBalance() public {
        _loan(address(usdc), false, PRINCIPAL, 1000);
        vm.warp(start + 12 days);
        uint256 rawSupply = usdfr.totalSupply();
        uint256 claims = reserves.accrualSnapshot().unissued;
        address hook = address(new AccrualDeliveryExhaustingPoints());
        vm.prank(admin);
        usdfr.setPointsModule(hook);
        (bool ok,) = address(reserves).call{gas: 900_000}(abi.encodeCall(ReserveManager.materializeAccrued, (3)));
        assertFalse(ok);
        assertEq(usdfr.totalSupply(), rawSupply);
        assertEq(reserves.accrualSnapshot().unissued, claims);
        assertFalse(reserves.accrualDelivery().active);
        reserves.requireAccrualFresh();
    }

    function test_sixDecimalPikPayoffAllocatesRoundingToClassCuratorAndRetainsBothFees() public {
        _sixDecimalPayoff(true);
    }

    function test_sixDecimalPikPayoffUsesSeniorOnlyAfterClassCuratorIsExhausted() public {
        _sixDecimalPayoff(false);
    }

    function test_restrictedFeeRecipientCannotBlockAProvedSixDecimalPayoff() public {
        address restrictedFee = makeAddr("restricted-accrual-fee-recipient");
        vm.startPrank(admin);
        usdfr.setComplianceModule(address(compliance));
        controller.setYieldSink(restrictedFee, true);
        waterfall.setFeeRecipient(restrictedFee);
        vm.stopPrank();
        assertFalse(compliance.isProtocolExempt(restrictedFee));
        uint256 principal = 1_000e18;

        _mintUSDfrTo(alice, principal);
        _postFirstLoss(anchorCurator, 1, 1e18);
        uint256 id = _loan(address(usdc), true, principal, 1234);
        uint256 canonical;
        uint256 streamed;
        {
            uint256 elapsed = 1 days + 123;
            vm.warp(start + elapsed);
            canonical = principal * 1234 * elapsed / (10_000 * 360 days * 1e12) * 1e12;
            uint256 endpoint = principal * 1234 * 90 days / (10_000 * 360 days * 1e12) * 1e12;
            streamed = Math.mulDiv(endpoint, elapsed, 90 days);
        }
        uint256 loss = streamed - canonical;
        assertGt(loss, 0);
        assertLt(loss, 1e12);
        uint256 fee = streamed * waterfall.protocolFeeBps() / 10_000;
        // Closing reconciles the integer-per-second stream to the exact interpolation.
        uint256[3] memory before_ =
            [usdfr.totalSupply() + streamed, vault.balanceOf(feeRecipient), curator.poolBalance(1)];
        vm.prank(complianceAdmin);
        compliance.setJurisdictionBlocked(restrictedFee, true);
        assertEq(usdfr.complianceModule(), address(compliance));
        assertFalse(compliance.canTransfer(address(usdfr), address(0), restrictedFee));

        _repay(id, address(usdc), principal + canonical, 0, 0);

        IContinuousAccrual.Snapshot memory settled = reserves.accrualSnapshot();
        assertEq(settled.gross, streamed, "neither the correction nor receipt erases earned income");
        assertEq(settled.feeUnissued, fee, "the full blocked fee remains owed to its existing recipient");
        assertEq(settled.seniorUnissued, 0);
        assertEq(usdfr.balanceOf(restrictedFee), 0, "a blocked recipient receives no transfer");
        assertGt(vault.balanceOf(feeRecipient), before_[1], "performance fees remain earned before loss");
        assertEq(curator.poolBalance(1), before_[2] - loss);
        assertEq(controller.totalUSDfr(), before_[0] - loss);
        assertEq(reserves.deployedTo(id), 0);
        assertEq(registry.totalBookExposure(), 0);
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Repaid));

        vm.prank(complianceAdmin);
        compliance.setJurisdictionBlocked(restrictedFee, false);
        reserves.materializeAccrued(2);
        assertEq(usdfr.balanceOf(restrictedFee), fee);
        assertEq(reserves.accrualSnapshot().feeUnissued, 0);
        assertEq(controller.totalUSDfr(), before_[0] - loss, "later fee delivery is neutral");
    }

    function test_restrictedFeeRecipientCannotBlockAnAttestedDefaultLoss() public {
        _attestedLossFeeOwnership(false);
    }

    function test_vaultOwnedFeeIsAvailableBeforeAnAttestedDefaultLoss() public {
        _attestedLossFeeOwnership(true);
    }

    function _attestedLossFeeOwnership(bool vaultOwnsFee) private {
        address recipient = _lossFeeRecipient(vaultOwnsFee);
        _postFirstLoss(anchorCurator, 1, 1_000e18);
        uint256 id = _loan(address(usdc), false, PRINCIPAL, 1000);
        vm.warp(start + 30 days);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        IContinuousAccrual.Snapshot memory claims = reserves.accrualSnapshot();
        uint256 loss = reserves.deployedTo(id);
        uint256 supply = controller.totalUSDfr();
        uint256 assets = usdfr.balanceOf(address(vault));
        assertGt(claims.feeUnissued, 0);

        _realizeLoss(id, loss, keccak256("restricted fee default loss"));

        assertEq(reserves.accrualSnapshot().gross, claims.gross);
        assertEq(reserves.accrualSnapshot().feeUnissued, vaultOwnsFee ? 0 : claims.feeUnissued);
        assertEq(reserves.accrualSnapshot().seniorUnissued, 0);
        if (!vaultOwnsFee) assertEq(usdfr.balanceOf(recipient), 0);
        assertEq(curator.poolBalance(1), 0);
        uint256 owned = claims.seniorUnissued + (vaultOwnsFee ? claims.feeUnissued : 0);
        assertEq(usdfr.balanceOf(address(vault)), assets + owned - (loss - 1_000e18));
        assertEq(controller.totalUSDfr(), supply - loss);
        assertEq(reserves.deployedTo(id), 0);
        assertEq(registry.totalBookExposure(), 0);
        assertEq(defaultManager.defaultedContribution(id), 0);
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Resolved));
        if (!vaultOwnsFee) _deliverRestrictedFee(recipient, claims.feeUnissued);
    }

    function test_restrictedFeeRecipientCannotBlockARatifiedCustodyLoss() public {
        _custodyLossFeeOwnership(false);
    }

    function test_vaultOwnedFeeIsAvailableBeforeARatifiedCustodyLoss() public {
        _custodyLossFeeOwnership(true);
    }

    function _custodyLossFeeOwnership(bool vaultOwnsFee) private {
        address recipient = _lossFeeRecipient(vaultOwnsFee);
        _postFirstLoss(anchorCurator, 1, 1_000e18);
        _loan(address(usdc), false, PRINCIPAL, 1000);
        vm.warp(start + 30 days);
        IContinuousAccrual.Snapshot memory claims = reserves.accrualSnapshot();
        uint256 supply = controller.totalUSDfr();
        uint256 assets = usdfr.balanceOf(address(vault));
        uint256 loss = 1_200e18;
        assertGt(claims.feeUnissued, 0);
        _createReserveShortfall(loss);
        _armReserveLoss(1);

        (, uint256 actualLoss) = _ratifyCurrentReserveLoss(loss);

        assertEq(actualLoss, loss);
        assertEq(reserves.accrualSnapshot().gross, claims.gross);
        assertEq(reserves.accrualSnapshot().feeUnissued, vaultOwnsFee ? 0 : claims.feeUnissued);
        assertEq(reserves.accrualSnapshot().seniorUnissued, 0);
        if (!vaultOwnsFee) assertEq(usdfr.balanceOf(recipient), 0);
        assertEq(curator.poolBalance(1), 0);
        uint256 owned = claims.seniorUnissued + (vaultOwnsFee ? claims.feeUnissued : 0);
        assertEq(usdfr.balanceOf(address(vault)), assets + owned - 200e18);
        assertEq(controller.totalUSDfr(), supply - loss);
        assertTrue(controller.backingInvariantHolds());
        if (!vaultOwnsFee) _deliverRestrictedFee(recipient, claims.feeUnissued);
    }

    function _lossFeeRecipient(bool vaultOwnsFee) private returns (address) {
        if (!vaultOwnsFee) return _restrictedProtocolFee();
        vm.prank(admin);
        waterfall.setFeeRecipient(address(vault));
        return address(vault);
    }

    function _restrictedProtocolFee() private returns (address recipient) {
        recipient = makeAddr("restricted-native-loss-fee-recipient");
        vm.startPrank(admin);
        usdfr.setComplianceModule(address(compliance));
        controller.setYieldSink(recipient, true);
        waterfall.setFeeRecipient(recipient);
        vm.stopPrank();
        vm.prank(complianceAdmin);
        compliance.setJurisdictionBlocked(recipient, true);
        assertFalse(compliance.isProtocolExempt(recipient));
        assertFalse(compliance.canTransfer(address(usdfr), address(0), recipient));
    }

    function _deliverRestrictedFee(address recipient, uint256 fee) private {
        uint256 supply = controller.totalUSDfr();
        vm.prank(complianceAdmin);
        compliance.setJurisdictionBlocked(recipient, false);
        reserves.materializeAccrued(2);
        assertEq(usdfr.balanceOf(recipient), fee);
        assertEq(reserves.accrualSnapshot().feeUnissued, 0);
        assertEq(controller.totalUSDfr(), supply, "later fee delivery is economically neutral");
    }

    function test_preLossFeeHookCannotChangeReserveGovernanceWhileReceiptIsOpen() public {
        AccrualPreparationGovernanceProbe hook = new AccrualPreparationGovernanceProbe(reserves, bob);
        vm.startPrank(admin);
        reserves.grantRole(bytes32(0), address(hook));
        reserves.grantRole(Roles.GUARDIAN_ROLE, address(hook));
        reserves.grantRole(Roles.RESERVE_ADMIN_ROLE, address(hook));
        vault.setPointsModule(address(hook));
        vm.stopPrank();
        _sixDecimalPayoff(true);
        assertGt(hook.attempts(), 0, "the actual pre-loss share callback must run");
        assertEq(hook.admitted(), 0, "an open receipt must freeze reserve governance");
        assertEq(hook.wrongError(), 0, "each probe must reach the operation guard");
        assertFalse(reserves.paused());
        assertFalse(reserves.hasRole(Roles.CREDIT_ROLE, bob));
    }

    function _sixDecimalPayoff(bool junior) private {
        uint256 principal = 1_000e18;

        _mintUSDfrTo(alice, principal);
        if (junior) _postFirstLoss(anchorCurator, 1, 1e18);
        uint256 id = _loan(address(usdc), true, principal, 1234);
        uint256 elapsed = 1 days + 123;
        vm.warp(start + elapsed);
        uint256 canonical = principal * 1234 * elapsed / (10_000 * 360 days * 1e12) * 1e12;
        uint256 endpoint = principal * 1234 * 90 days / (10_000 * 360 days * 1e12) * 1e12;
        uint256 streamed = Math.mulDiv(endpoint, elapsed, 90 days);
        uint256 loss = streamed - canonical;
        assertGt(loss, 0, "must exercise an actual sub-native-unit overstatement");
        assertLt(loss, 1e12);
        uint256 supply = usdfr.totalSupply();
        uint256 vaultBalance = usdfr.balanceOf(address(vault));
        uint256 curatorBalance = curator.poolBalance(1);
        uint256 oldFee = usdfr.balanceOf(feeRecipient);
        uint256 oldFeeShares = vault.balanceOf(feeRecipient);
        _repay(id, address(usdc), principal + canonical, 0, 0);
        uint256 fee = streamed * waterfall.protocolFeeBps() / 10_000;
        assertEq(reserves.accrualSnapshot().gross, streamed, "the loss cannot cancel historical earned income");
        assertEq(reserves.accrualSnapshot().seniorUnissued, 0);
        assertEq(reserves.accrualSnapshot().feeUnissued, fee, "a separate fee remains earned for delivery");
        assertEq(usdfr.balanceOf(feeRecipient), oldFee);
        assertEq(usdfr.totalSupply(), supply + streamed - fee - loss);
        assertEq(controller.totalUSDfr(), supply + streamed - loss);
        reserves.materializeAccrued(2);
        assertEq(reserves.accrualSnapshot().unissued, 0);
        assertEq(usdfr.totalSupply(), supply + streamed - loss);
        assertEq(usdfr.balanceOf(feeRecipient), oldFee + fee, "gross PIK fee remains earned");
        assertGt(vault.balanceOf(feeRecipient), oldFeeShares, "vault performance fee also crystallizes before loss");
        assertEq(curator.poolBalance(1), junior ? curatorBalance - loss : 0);
        assertEq(usdfr.balanceOf(address(vault)), vaultBalance + streamed - fee - (junior ? 0 : loss));
        assertEq(reserves.deployedTo(id), 0);
        assertEq(registry.totalBookExposure(), 0);
        assertEq(reserves.roundingLossUnabsorbed(), 0);
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Repaid));
        assertEq(reserves.accruedDebt(id).principal + reserves.accruedDebt(id).interest, 0);
        assertTrue(controller.backingInvariantHolds());
    }

    function test_nativeRoundingDoesNotTouchSGroveWhileClassCuratorCoversLoss() public {
        _nativeRoundingLayers(0);
    }

    function test_nativeRoundingUsesRealSGroveBeforeSenior() public {
        _nativeRoundingLayers(1);
    }

    function test_nativeRoundingExhaustsBothJuniorsBeforeSenior() public {
        _nativeRoundingLayers(2);
    }

    function test_nativeRoundingCannotSpendUncreditedSGroveGifts() public {
        _nativeRoundingLayers(3);
    }

    function test_nativeRoundingPreservesSGroveOwnedFeeWithoutInventingCoverage() public {
        _nativeRoundingLayers(4);
    }

    /// @dev Independently compute the USDC discrepancy, then fund exact USDfr layer sizes. Each
    ///      value-moving contract is real. No reserve/loan/source storage is modified by the test.
    function _nativeRoundingLayers(uint8 mode) private {
        if (mode == 4) {
            vm.startPrank(admin);
            controller.setYieldSink(address(sGrove), true);
            waterfall.setFeeRecipient(address(sGrove));
            vm.stopPrank();
        }
        PayoffModel memory m;
        m.principal = 1_000e18;
        uint256 elapsed = 1 days + 123;
        m.canonical = m.principal * 1234 * elapsed / (10_000 * 360 days * 1e12) * 1e12;
        uint256 endpoint = m.principal * 1234 * 90 days / (10_000 * 360 days * 1e12) * 1e12;
        m.gross = endpoint * elapsed / 90 days;
        m.loss = m.gross - m.canonical;
        assertGt(m.loss, 0);
        assertLt(m.loss, 1e12);
        uint256 curatorCapital = mode == 0 ? m.loss + 1 : (mode < 3 ? m.loss / 3 : 0);
        uint256 coverage = mode < 2 ? 1e18 : (mode == 2 ? m.loss / 3 : 0);
        if (curatorCapital != 0) {
            _mintUSDfrTo(anchorCurator, 1e18);
            vm.startPrank(anchorCurator);
            usdfr.approve(address(curator), curatorCapital);
            curator.postFirstLoss(1, curatorCapital);
            vm.stopPrank();
        }
        if (coverage != 0) {
            _mintUSDfrTo(bob, 1e18);
            vm.startPrank(bob);
            usdfr.approve(address(sGrove), coverage);
            sGrove.fundCoverage(coverage);
            vm.stopPrank();
        }
        if (mode == 3) {
            vm.prank(alice);
            usdfr.transfer(address(sGrove), 1e18);
            assertEq(sGrove.coverageReserve(), 0, "a direct gift never creates recorded coverage");
        }
        uint256 id = _loan(address(usdc), true, m.principal, 1234);
        vm.warp(start + elapsed);
        m.supply = usdfr.totalSupply();
        m.vaultAssets = usdfr.balanceOf(address(vault));
        _repay(id, address(usdc), m.principal + m.canonical, 0, 0);
        uint256 curatorLoss = curatorCapital < m.loss ? curatorCapital : m.loss;
        uint256 backstopLoss = coverage < m.loss - curatorLoss ? coverage : m.loss - curatorLoss;
        uint256 seniorLoss = m.loss - curatorLoss - backstopLoss;
        uint256 fee = m.gross * waterfall.protocolFeeBps() / 10_000;
        assertEq(curator.poolBalance(1), curatorCapital - curatorLoss);
        assertEq(sGrove.coverageReserve(), coverage - backstopLoss);
        (uint256 drawn,) = sGrove.eventCoverage(id);
        assertEq(drawn, backstopLoss);
        assertEq(usdfr.balanceOf(address(vault)), m.vaultAssets + m.gross - fee - seniorLoss);
        assertEq(controller.totalUSDfr(), m.supply + m.gross - m.loss);
        assertEq(reserves.accrualSnapshot().feeUnissued, fee);
        assertEq(reserves.accrualSnapshot().seniorUnissued, 0);
        assertEq(reserves.deployedTo(id), 0);
        assertEq(registry.totalBookExposure(), 0);
        assertEq(reserves.roundingLossUnabsorbed(), 0);
        assertTrue(controller.backingInvariantHolds());
        if (mode == 3) assertEq(usdfr.balanceOf(address(sGrove)), 1e18, "uncredited gift remains untouched");
        if (mode == 4) {
            assertEq(usdfr.balanceOf(address(sGrove)), 0);
            reserves.materializeAccrued(2);
            assertEq(usdfr.balanceOf(address(sGrove)), fee, "full fee delivered later");
            assertEq(sGrove.coverageReserve(), 0, "fee receipt alone does not fund coverage");
            assertEq(controller.totalUSDfr(), m.supply + m.gross - m.loss);
        }
    }

    function test_roundingBurnContinuationCannotBeRequestedByAnUnrelatedCaller() public {
        vm.expectRevert(ReserveRoundingLib.AccrualRounding_InvalidContinuation.selector);
        reserves.consumeAccrualLossBurn(address(reserves), address(vault), 1);
        vm.prank(address(controller));
        assertFalse(reserves.consumeAccrualLossBurn(address(reserves), address(vault), 1), "no active permit exists");
    }

    function test_invalidSelectedMaskCannotConsumeClaims() public {
        _loan(address(usdc), false, PRINCIPAL, 1000);
        vm.warp(start + 1 days);
        uint256 claims = reserves.accrualSnapshot().unissued;
        vm.expectRevert(abi.encodeWithSelector(ReserveAccrualLib.ReserveAccrual_InvalidLegs.selector, uint8(4)));
        reserves.materializeAccrued(4);
        assertEq(reserves.accrualSnapshot().unissued, claims);
    }

    function test_feeRateChangePreservesTheEarnedEpochAndAppliesOnlyForward() public {
        _loan(address(usdc), false, PRINCIPAL, 1000);
        vm.warp(start + 10 days);
        IContinuousAccrual.Snapshot memory prior = reserves.accrualSnapshot();
        vm.prank(admin);
        waterfall.setProtocolFee(500);
        IContinuousAccrual.Snapshot memory same = reserves.accrualSnapshot();
        assertEq(same.gross, prior.gross);
        assertEq(same.feeUnissued, prior.feeUnissued);
        vm.warp(start + 20 days);
        IContinuousAccrual.Snapshot memory later = reserves.accrualSnapshot();
        assertEq(later.feeUnissued, prior.feeUnissued + (later.gross - prior.gross) * 500 / 10_000);
        assertEq(later.seniorUnissued + later.feeUnissued, later.gross);
    }

    function test_feeRecipientChangeDeliversOldClaimBeforeRedirectingFutureFees() public {
        _loan(address(usdc), false, PRINCIPAL, 1000);
        vm.warp(start + 10 days);
        IContinuousAccrual.Snapshot memory prior = reserves.accrualSnapshot();
        uint256 oldBalance = usdfr.balanceOf(feeRecipient);
        vm.startPrank(admin);
        controller.setYieldSink(bob, true);
        waterfall.setFeeRecipient(bob);
        vm.stopPrank();
        assertEq(usdfr.balanceOf(feeRecipient), oldBalance + prior.feeUnissued);
        assertEq(reserves.accrualSnapshot().feeUnissued, 0);
        assertEq(reserves.accrualSnapshot().seniorUnissued, prior.seniorUnissued);
        assertEq(reserves.accrualSnapshot().feeRecipient, bob);
        vm.warp(start + 20 days);
        uint256 nextFee = reserves.accrualSnapshot().feeUnissued;
        assertGt(nextFee, 0);
        reserves.materializeAccrued(2);
        assertEq(usdfr.balanceOf(bob), nextFee);
        assertEq(usdfr.balanceOf(feeRecipient), oldBalance + prior.feeUnissued);
    }

    function test_aliasedFeeAndSeniorDestinationsReceiveExactlyTheirCombinedClaim() public {
        vm.prank(admin);
        waterfall.setFeeRecipient(address(vault));
        _loan(address(usdc), true, PRINCIPAL, 1000);
        vm.warp(start + 10 days);
        IContinuousAccrual.Snapshot memory prior = reserves.accrualSnapshot();
        uint256 before_ = usdfr.balanceOf(address(vault));
        uint256 assets = vault.totalAssets();
        reserves.materializeAccrued(3);
        assertEq(usdfr.balanceOf(address(vault)), before_ + prior.gross);
        assertEq(vault.totalAssets(), assets);
        assertEq(reserves.accrualSnapshot().unissued, 0);
    }

    function test_unapprovedRecipientCannotStrandOrConsumeTheOldFeeClaim() public {
        _loan(address(usdc), false, PRINCIPAL, 1000);
        vm.warp(start + 10 days);
        uint256 fee = reserves.accrualSnapshot().feeUnissued;
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_WrongModules.selector);
        vm.prank(admin);
        waterfall.setFeeRecipient(bob);
        assertEq(waterfall.feeRecipient(), feeRecipient);
        assertEq(reserves.accrualSnapshot().feeRecipient, feeRecipient);
        assertEq(reserves.accrualSnapshot().feeUnissued, fee);
    }

    function test_unabsorbedSubUnitLossIsRecordedAndCannotBlockARealPayoff() public {
        // A separately deployed real instance with all issued USDfr held unstaked, and no loss capital.
        emptyVaultFixture = true;
        setUp();
        assertEq(usdfr.balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(curator.poolBalance(1), 0);

        _mintUSDfrTo(alice, 100e18);
        uint256 id = _loan(address(usdc), true, 100e18, 1234);
        vm.warp(start + 1);
        assertEq(reserves.accruedDebt(id).interest, 0, "contractual coupon rounds to zero native units");
        uint256 gross = reserves.accrualSnapshot().gross;
        assertGt(gross, 0);
        assertLt(gross, 1e12);
        uint256 fee = gross * uint256(waterfall.protocolFeeBps()) / 10_000;
        uint256 feeBalance = usdfr.balanceOf(feeRecipient);
        _repay(id, address(usdc), 100e18, 0, 0);
        assertEq(reserves.deployedTo(id), 0);
        assertEq(registry.totalBookExposure(), 0);
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Repaid));
        assertEq(reserves.accrualSnapshot().gross, gross);
        assertEq(reserves.accrualSnapshot().feeUnissued, fee, "earned fee is not cancelled");
        assertEq(usdfr.balanceOf(feeRecipient), feeBalance);
        assertEq(usdfr.balanceOf(address(vault)), 0, "available senior assets are fully used after curator");
        assertEq(reserves.roundingLossUnabsorbed(), fee);
        assertEq(controller.recognizedDeficit(), fee);
        assertTrue(reserves.reserveLossExitsLocked(), "unabsorbed loss remains visible to ordinary exits");
        uint256 effectiveSupply = controller.totalUSDfr();
        reserves.materializeAccrued(2);
        assertEq(usdfr.balanceOf(feeRecipient), feeBalance + fee);
        assertEq(reserves.accrualSnapshot().feeUnissued, 0);
        assertEq(controller.totalUSDfr(), effectiveSupply);
        assertEq(controller.recognizedDeficit(), fee);
    }

    function test_vaultOwnedProtocolFeeAlsoAbsorbsAProvedRoundingLoss() public {
        emptyVaultFixture = true;
        setUp();
        vm.prank(admin);
        waterfall.setFeeRecipient(address(vault));

        _mintUSDfrTo(alice, 100e18);
        uint256 id = _loan(address(usdc), true, 100e18, 1234);
        uint256 supply = usdfr.totalSupply();
        vm.warp(start + 1);
        uint256 endpoint = uint256(100e18) * 1234 * 90 days / (10_000 * 360 days * 1e12) * 1e12;
        uint256 streamed = endpoint / 90 days;
        assertGt(streamed * waterfall.protocolFeeBps() / 10_000, 0);
        assertLt(streamed, 1e12);
        assertEq(reserves.accruedDebt(id).interest, 0);
        assertEq(usdfr.balanceOf(address(vault)), 0);
        assertEq(curator.poolBalance(1), 0);

        _repay(id, address(usdc), 100e18, 0, 0);

        assertEq(reserves.accrualSnapshot().gross, streamed);
        assertEq(reserves.accrualSnapshot().unissued, 0, "both vault-owned legs fund the senior loss");
        assertEq(usdfr.balanceOf(address(vault)), 0);
        assertEq(usdfr.totalSupply(), supply, "the exact gross claim is issued and absorbed once");
        assertEq(controller.totalUSDfr(), supply);
        assertEq(reserves.roundingLossUnabsorbed(), 0, "no separate fee remains outside the cascade");
        assertEq(controller.recognizedDeficit(), 0);
        assertEq(reserves.deployedTo(id), 0);
        assertEq(registry.totalBookExposure(), 0);
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Repaid));
    }

    function testFuzz_sixDecimalCashAndPikPayoffsConserveEarnedFeesAndLossOrder(
        uint64 units,
        uint32 elapsed,
        uint16 rate,
        bool pik,
        bool junior,
        bool vaultOwnsFee
    ) public {
        units = uint64(bound(units, 1e6, 100_000e6));
        elapsed = uint32(bound(elapsed, 1, 90 days - 1));
        rate = uint16(bound(rate, 1, 5000));
        PayoffModel memory m;
        m.principal = uint256(units) * 1e12;
        if (vaultOwnsFee) {
            vm.prank(admin);
            waterfall.setFeeRecipient(address(vault));
        }

        _mintUSDfrTo(alice, m.principal);
        if (junior) _postFirstLoss(anchorCurator, 1, 1e18);
        uint256 id = _loan(address(usdc), pik, m.principal, rate);
        vm.warp(start + elapsed);
        // Independent native-unit simple-interest and endpoint-interpolation model.
        // Cash keeps its original principal through maturity; PIK's first basis ends at quarter one.
        // The cash reservation equals its final native-unit coupon. Its last grid increment
        // occurs at ceil(coupon / exact rate); the preceding interpolation ends one second earlier.
        uint256 period = pik ? 90 days : 360 days;
        uint256 endpoint = m.principal * rate * period / (10_000 * 360 days * 1e12) * 1e12;
        if (!pik) {
            period = Math.mulDiv(endpoint, 10_000 * 360 days, m.principal * rate, Math.Rounding.Ceil) - 1;
            endpoint = m.principal * rate * period / (10_000 * 360 days * 1e12) * 1e12;
        }
        assertLt(elapsed, period);
        m.canonical = m.principal * rate * elapsed / (10_000 * 360 days * 1e12) * 1e12;
        m.gross = Math.max(Math.mulDiv(endpoint, elapsed, period), m.canonical);
        m.loss = m.gross - m.canonical;
        assertLt(m.loss, 1e12);
        m.supply = usdfr.totalSupply();
        m.vaultAssets = usdfr.balanceOf(address(vault));
        m.feeAssets = usdfr.balanceOf(feeRecipient);

        _repay(id, address(usdc), m.principal + (pik ? m.canonical : 0), pik ? 0 : m.canonical, 0);
        reserves.materializeAccrued(3);

        uint256 fee = m.gross * waterfall.protocolFeeBps() / 10_000;
        assertEq(reserves.accrualSnapshot().gross, m.gross);
        assertEq(reserves.accrualSnapshot().unissued, 0);
        assertEq(usdfr.totalSupply(), m.supply + m.gross - m.loss);
        assertEq(controller.totalUSDfr(), m.supply + m.canonical);
        assertEq(usdfr.balanceOf(feeRecipient), m.feeAssets + (vaultOwnsFee ? 0 : fee));
        assertEq(
            usdfr.balanceOf(address(vault)), m.vaultAssets + m.gross - (vaultOwnsFee ? 0 : fee) - (junior ? 0 : m.loss)
        );
        assertEq(curator.poolBalance(1), junior ? 1e18 - m.loss : 0);
        assertEq(reserves.deployedTo(id), 0);
        assertEq(registry.totalBookExposure(), 0);
        assertEq(reserves.roundingLossUnabsorbed(), 0);
        assertTrue(controller.backingInvariantHolds());
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Repaid));
    }

    function test_coldActualSixLoanRecoverySourceFitsVaultBudget() public {
        _coldRiskProbe(6, false);
    }

    function test_coldActualHundredLoanRecoverySourceFitsVaultBudget() public {
        _coldRiskProbe(100, false);
    }

    function test_coldActualHundredLoanInvalidatedRecoverySourceFitsVaultBudget() public {
        _coldRiskProbe(100, true);
    }

    function _coldRiskProbe(uint256 count, bool invalidated) private {
        vm.startPrank(admin);
        for (uint256 classId = 2; classId <= 5; ++classId) {
            ICollateralRegistry.ClassParams memory p = registry.classParams(classId);
            p.concentrationLimitBps = 10_000;
            registry.setClass(classId, p);
            waterfall.setOriginationFee(classId, 0);
        }
        vm.stopPrank();
        for (uint256 i; i < count; ++i) {
            _classLoan(1 + i % 5, address(usdc), false, 1_000e18, 1000);
        }
        vm.warp(start + 120 days + 1);
        for (uint256 id = 1; id <= count; ++id) {
            if (id <= 2) {
                defaultManager.markPastDue(id);
            } else {
                _attestDefault(id);
                vm.prank(servicer);
                defaultManager.declareDefault(id, FILM_REF);
            }
        }
        vm.prank(admin);
        assessedImpairmentSource.setAssessment(
            1e18, uint64(block.timestamp + 1 days), keccak256("cold source assessment")
        );
        uint256 exposureBefore = defaultManager.pastDueExposure();
        vm.warp(block.timestamp + 1);
        if (invalidated) {
            _attestDefault(1);
            vm.prank(servicer);
            defaultManager.declareDefault(1, FILM_REF);
        }
        uint256 expected = invalidated
            ? defaultManager.pendingSeniorImpairment()
            : 1e18 + defaultManager.pastDueExposure() - exposureBefore;
        vm.record();
        vm.startStateDiffRecording();
        assertEq(assessedImpairmentSource.pendingSeniorImpairment(), expected);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertGt(accesses.length, 10, "recording must include the actual static/delegatecall tree");
        uint256 cooledReads;
        for (uint256 i; i < accesses.length; ++i) {
            (bytes32[] memory reads,) = vm.accesses(accesses[i].account);
            cooledReads += reads.length;
            for (uint256 j; j < reads.length; ++j) {
                vm.coolSlot(accesses[i].account, reads[j]);
            }
            vm.cool(accesses[i].account);
        }
        assertGt(cooledReads, 60, "cold probe must reset the financial storage reads, not just accounts");
        uint256 beforeGas = gasleft();
        (bool ok, bytes memory data) = address(assessedImpairmentSource).staticcall{gas: 200_000}(
            abi.encodeCall(assessedImpairmentSource.pendingSeniorImpairment, ())
        );
        emit log_named_uint("actual cold source gas including call overhead", beforeGas - gasleft());
        assertTrue(ok, "actual proxy and linked-library source must fit the frozen vault budget");
        assertEq(abi.decode(data, (uint256)), expected);
    }
}
