// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {SUSDfr} from "../../src/sUSDfr.sol";
import {USDfr} from "../../src/USDfr.sol";
import {IImpairmentSource} from "../../src/interfaces/IImpairmentSource.sol";
import {IPointsModule} from "../../src/interfaces/IPointsModule.sol";
import {IsUSDfr} from "../../src/interfaces/IsUSDfr.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

contract MutableFeeImpairment is IImpairmentSource {
    uint256 internal impairment;
    uint256 internal feeImpairment;

    function set(uint256 amount) external {
        impairment = amount;
        feeImpairment = amount;
    }

    function setPerformanceFeeImpairment(uint256 amount) external {
        feeImpairment = amount;
    }

    function pendingSeniorImpairment() external view returns (uint256) {
        return impairment;
    }

    function performanceFeeImpairment() external view returns (uint256) {
        return feeImpairment;
    }
}

contract RevertingFeeImpairment is IImpairmentSource {
    bool internal shouldRevert;

    function setReverting(bool value) external {
        shouldRevert = value;
    }

    function pendingSeniorImpairment() external view returns (uint256) {
        if (shouldRevert) revert("impairment unavailable");
        return 0;
    }

    function performanceFeeImpairment() external view returns (uint256) {
        if (shouldRevert) revert("performance impairment unavailable");
        return 0;
    }
}

contract MalformedFeeImpairment {
    function pendingSeniorImpairment() external pure {
        assembly ("memory-safe") {
            return(0, 0)
        }
    }
}

contract ToggleMalformedFeeImpairment is IImpairmentSource {
    uint256 internal impairment;
    bool internal malformed;

    function set(uint256 amount) external {
        impairment = amount;
    }

    function setMalformed(bool value) external {
        malformed = value;
    }

    function pendingSeniorImpairment() external view returns (uint256) {
        if (malformed) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return impairment;
    }

    function performanceFeeImpairment() external view returns (uint256) {
        if (malformed) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return impairment;
    }
}

contract TogglePerformanceMalformedFeeImpairment is IImpairmentSource {
    uint256 internal impairment;
    bool internal malformed;

    function set(uint256 amount) external {
        impairment = amount;
    }

    function setMalformed(bool value) external {
        malformed = value;
    }

    function pendingSeniorImpairment() external view returns (uint256) {
        return impairment;
    }

    function performanceFeeImpairment() external view returns (uint256) {
        if (malformed) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return impairment;
    }
}

contract FeeReenteringPoints is IPointsModule {
    SUSDfr internal immutable VAULT;

    uint256 public attempts;
    bytes4 public lastRevertSelector;
    bool public unexpectedSuccess;
    bytes4 public nestedTransferRevertSelector;
    bool public nestedTransferUnexpectedSuccess;

    constructor(SUSDfr vault_) {
        VAULT = vault_;
    }

    function onSharesTransfer(address, address, uint256) external {
        attempts++;
        try VAULT.accrueFees() returns (uint256, uint256) {
            unexpectedSuccess = true;
        } catch (bytes memory reason) {
            bytes4 selector;
            assembly {
                selector := mload(add(reason, 0x20))
            }
            lastRevertSelector = selector;
        }

        try VAULT.transfer(address(0xBEEF), 1) returns (bool) {
            nestedTransferUnexpectedSuccess = true;
        } catch (bytes memory reason) {
            bytes4 selector;
            assembly {
                selector := mload(add(reason, 0x20))
            }
            nestedTransferRevertSelector = selector;
        }
    }

    function onUSDfrTransfer(address, address, uint256) external {}

    function onCuratorStakeChange(address, uint256, uint256) external {}

    function onCuratorLoss(uint256, uint256, uint256) external {}
}

contract UnderlyingFeeReenteringPoints is IPointsModule {
    SUSDfr internal immutable VAULT;

    uint256 public attempts;
    bytes4 public lastRevertSelector;
    bool public unexpectedSuccess;

    constructor(SUSDfr vault_) {
        VAULT = vault_;
    }

    function onSharesTransfer(address, address, uint256) external {}

    function onUSDfrTransfer(address, address, uint256) external {
        attempts++;
        try VAULT.accrueFees() returns (uint256, uint256) {
            unexpectedSuccess = true;
        } catch (bytes memory reason) {
            bytes4 selector;
            assembly {
                selector := mload(add(reason, 0x20))
            }
            lastRevertSelector = selector;
        }
    }

    function onCuratorStakeChange(address, uint256, uint256) external {}

    function onCuratorLoss(uint256, uint256, uint256) external {}
}

contract FeeSetterReenteringPoints is IPointsModule {
    SUSDfr internal immutable VAULT;

    bytes4 public lastRevertSelector;
    bool public unexpectedSuccess;

    constructor(SUSDfr vault_) {
        VAULT = vault_;
    }

    function onSharesTransfer(address, address, uint256) external {
        try VAULT.setPerformanceFee(1_000) {
            unexpectedSuccess = true;
        } catch (bytes memory reason) {
            bytes4 selector;
            assembly {
                selector := mload(add(reason, 0x20))
            }
            lastRevertSelector = selector;
        }
    }

    function onUSDfrTransfer(address, address, uint256) external {}

    function onCuratorStakeChange(address, uint256, uint256) external {}

    function onCuratorLoss(uint256, uint256, uint256) external {}
}

contract HwmRaisingPoints is IPointsModule {
    SUSDfr internal immutable VAULT;
    USDfr internal immutable TOKEN;
    uint256 internal immutable DONATION;

    bool public sent;

    constructor(SUSDfr vault_, USDfr token_, uint256 donation_) {
        VAULT = vault_;
        TOKEN = token_;
        DONATION = donation_;
    }

    function onSharesTransfer(address, address, uint256) external {
        if (!sent && TOKEN.balanceOf(address(this)) >= DONATION) {
            sent = true;
            require(TOKEN.transfer(address(VAULT), DONATION));
        }
    }

    function onUSDfrTransfer(address, address, uint256) external {}

    function onCuratorStakeChange(address, uint256, uint256) external {}

    function onCuratorLoss(uint256, uint256, uint256) external {}
}

contract FeeNeutralPreviewCaller {
    function bracketAndPreviewRedeem(SUSDfr vault, uint256 shares) external returns (uint256 assets) {
        vault.beginFeeNeutralMarkedNavChange();
        assets = vault.previewRedeem(shares);
        vault.endFeeNeutralMarkedNavChange();
    }
}

/// @title Protocol-level sUSDfr fee accounting
/// @notice Pins the prospective 10%-at-launch global HWM fee and 0-2% management fee.
contract SUSDfrFeesTest is TokenLayerFixture {
    bytes32 internal constant SUSDFR_STORAGE_LOCATION =
        0x916ccd28d6453e4642f179fb55de273623b632994ad01fe3a90e7b8b8a7e8900;

    function _stake(address user, uint256 assets) internal returns (uint256 shares) {
        require(assets % 1e12 == 0, "whole USDC units only");
        _mintUSDfr(user, assets / 1e12);
        vm.startPrank(user);
        usdfr.approve(address(vault), assets);
        shares = vault.deposit(assets, user);
        vm.stopPrank();
    }

    function _addRecognizedYield(uint256 assets) internal {
        require(assets % 1e12 == 0, "whole USDC units only");
        _receiveYield(address(vault), assets / 1e12);
    }

    function _burnSeniorLoss(uint256 assets) internal {
        require(assets % 1e12 == 0, "whole USDC units only");
        vm.startPrank(creditModule);
        reserves.recordDeployment(777, borrower, assets / 1e12);
        reserves.recordPrincipalWritedown(777, assets);
        controller.burnLoss(address(vault), assets);
        vm.stopPrank();
    }

    function _hurdleAssets() internal view returns (uint256) {
        return Math.mulDiv(vault.highWaterMark(), vault.totalSupply() + 1e6, 10 ** vault.decimals(), Math.Rounding.Ceil);
    }

    function test_feeConfiguration_launchesAtAgreedValuesAndEnforcesAdminCap() public {
        assertEq(vault.performanceFeeBps(), Config.DEFAULT_PERFORMANCE_FEE_BPS);
        assertEq(vault.performanceFeeBps(), 1_000, "10% performance fee at launch");
        assertEq(vault.maxPerformanceFeeBps(), 2_000, "permanent 20% performance cap");
        assertEq(vault.managementFeeBps(), 0, "management fee launches disabled");
        assertEq(vault.maxManagementFeeBps(), 200, "permanent 2% annual cap");
        assertEq(vault.managementFeeYear(), 365 days);
        assertEq(vault.feeRecipient(), feeRecipient);
        assertEq(vault.highWaterMark(), 1e18);
        assertEq(vault.feeExchangeRate(), 1e18);
        assertEq(vault.lastFeeAccrual(), uint64(block.timestamp));

        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, adminRole)
        );
        vault.setManagementFee(1);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, adminRole)
        );
        vault.setPerformanceFee(1);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, adminRole)
        );
        vault.setFeeRecipient(alice);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IsUSDfr.SUSDfr_PerformanceFeeTooHigh.selector, 2_001));
        vault.setPerformanceFee(2_001);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IsUSDfr.SUSDfr_ManagementFeeTooHigh.selector, 201));
        vault.setManagementFee(201);

        vm.prank(admin);
        vault.setPerformanceFee(2_000);
        assertEq(vault.performanceFeeBps(), 2_000);

        vm.prank(admin);
        vault.setManagementFee(200);
        assertEq(vault.managementFeeBps(), 200);

        vm.prank(admin);
        vm.expectRevert(SUSDfr.SUSDfr_ZeroAddress.selector);
        vault.setFeeRecipient(address(0));
    }

    function test_feeConfigurationSetters_emitEveryConfigurationEvent() public {
        address replacement = makeAddr("eventReplacementFeeRecipient");
        vm.prank(admin);
        compliance.setProtocolExempt(replacement, true);

        vm.expectEmit(false, false, false, true, address(vault));
        emit IsUSDfr.PerformanceFeeSet(1_000, 1_500);
        vm.prank(admin);
        vault.setPerformanceFee(1_500);

        vm.expectEmit(false, false, false, true, address(vault));
        emit IsUSDfr.ManagementFeeSet(0, 100);
        vm.prank(admin);
        vault.setManagementFee(100);

        vm.expectEmit(true, true, false, true, address(vault));
        emit IsUSDfr.VaultFeeRecipientSet(feeRecipient, replacement);
        vm.prank(admin);
        vault.setFeeRecipient(replacement);
    }

    function test_performanceCheckpoint_emitsExactAccrualEvent() public {
        _stake(alice, 1_000e18);
        _addRecognizedYield(100e18);

        uint256 markedAssets = vault.redemptionTotalAssets();
        uint256 effectiveSupply = vault.totalSupply() + 1e6;
        uint256 oldHwm = vault.highWaterMark();
        uint256 hurdleAssets = Math.mulDiv(oldHwm, effectiveSupply, 10 ** vault.decimals(), Math.Rounding.Ceil);
        uint256 profitAssets = markedAssets + 1 - hurdleAssets;
        uint256 feeAssets = Math.mulDiv(profitAssets, 1_000, Config.BPS, Math.Rounding.Floor);
        uint256 feeShares = Math.mulDiv(feeAssets, effectiveSupply, markedAssets + 1 - feeAssets, Math.Rounding.Floor);
        uint256 newHwm = Math.mulDiv(
            10 ** vault.decimals(), markedAssets + 1, vault.totalSupply() + feeShares + 1e6, Math.Rounding.Ceil
        );

        vm.expectEmit(false, false, false, true, address(vault));
        emit IsUSDfr.PerformanceFeeAccrued(oldHwm, newHwm, profitAssets, feeAssets, feeShares);
        (, uint256 performanceShares) = vault.accrueFees();

        assertEq(performanceShares, feeShares);
    }

    function test_managementCheckpoint_emitsExactAccrualEvent() public {
        _stake(alice, 1_000e18);
        vm.prank(admin);
        vault.setManagementFee(200);
        vm.warp(block.timestamp + 365 days);

        uint256 markedAssets = vault.redemptionTotalAssets();
        uint256 retentionWad = uint256(FixedPointMathLib.powWad(0.98e18, 1e18));
        uint256 feeAssets = Math.mulDiv(markedAssets, 1e18 - retentionWad, 1e18, Math.Rounding.Floor);
        uint256 feeShares =
            Math.mulDiv(feeAssets, vault.totalSupply() + 1e6, markedAssets + 1 - feeAssets, Math.Rounding.Floor);

        vm.expectEmit(false, false, false, true, address(vault));
        emit IsUSDfr.ManagementFeeAccrued(365 days, feeAssets, feeShares);
        (uint256 managementShares,) = vault.accrueFees();

        assertEq(managementShares, feeShares);
    }

    function test_emptyVaultDonation_emitsExactHighWaterMarkAdjustment() public {
        deal(address(usdfr), address(vault), 100e18);
        uint256 oldHwm = vault.highWaterMark();
        uint256 newHwm = Math.mulDiv(10 ** vault.decimals(), 100e18 + 1, 1e6, Math.Rounding.Ceil);

        vm.expectEmit(false, false, false, true, address(vault));
        emit IsUSDfr.HighWaterMarkAdjusted(oldHwm, newHwm);
        vault.accrueFees();

        assertEq(vault.highWaterMark(), newHwm);
    }

    function test_impairmentSource_rejectsUnreadableReplacementBeforeWiring() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IsUSDfr.SUSDfr_InvalidImpairmentSource.selector, alice));
        vault.setImpairmentSource(alice);

        RevertingFeeImpairment revertingSource = new RevertingFeeImpairment();
        revertingSource.setReverting(true);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IsUSDfr.SUSDfr_InvalidImpairmentSource.selector, address(revertingSource))
        );
        vault.setImpairmentSource(address(revertingSource));

        MalformedFeeImpairment malformedSource = new MalformedFeeImpairment();
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IsUSDfr.SUSDfr_InvalidImpairmentSource.selector, address(malformedSource))
        );
        vault.setImpairmentSource(address(malformedSource));

        assertEq(vault.impairmentSource(), address(0));
    }

    function test_impairmentSource_rejectsPerformanceImpairmentBelowRedemptionImpairment() public {
        MutableFeeImpairment source = new MutableFeeImpairment();
        source.set(200e18);
        source.setPerformanceFeeImpairment(199e18);

        vm.expectRevert(abi.encodeWithSelector(IsUSDfr.SUSDfr_InvalidImpairmentSource.selector, address(source)));
        vm.prank(admin);
        vault.setImpairmentSource(address(source));

        assertEq(vault.impairmentSource(), address(0));
    }

    function test_upgradeRequiresTheInstalledDualNavSourceToBeReadyFirst() public {
        TogglePerformanceMalformedFeeImpairment source = new TogglePerformanceMalformedFeeImpairment();
        vm.prank(admin);
        vault.setImpairmentSource(address(source));
        source.setMalformed(true);

        address newImplementation = address(new SUSDfr());
        vm.expectRevert(abi.encodeWithSelector(IsUSDfr.SUSDfr_InvalidImpairmentSource.selector, address(source)));
        vm.prank(admin);
        vault.upgradeToAndCall(newImplementation, "");
    }

    function test_governanceCanRecoverAStaleMarkedNavFeeOperation() public {
        vm.prank(admin);
        vault.grantRole(Roles.FEE_ACCOUNTING_ROLE, creditModule);

        vm.prank(creditModule);
        vault.beginFeeNeutralMarkedNavChange();
        vm.expectRevert(IsUSDfr.SUSDfr_FeeAccrualReentrant.selector);
        vault.accrueFees();

        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, adminRole)
        );
        vm.prank(alice);
        vault.clearStaleFeeOperation();

        vm.expectEmit(true, true, false, true, address(vault));
        emit IsUSDfr.FeeOperationEmergencyCleared(creditModule, 1);
        vm.prank(admin);
        vault.clearStaleFeeOperation();

        vault.accrueFees();
        vm.expectRevert(abi.encodeWithSelector(IsUSDfr.SUSDfr_InvalidFeeOperation.selector, admin, uint8(1), uint8(0)));
        vm.prank(admin);
        vault.clearStaleFeeOperation();
    }

    function test_governanceCanRecoverAStaleYieldNotification() public {
        vm.prank(admin);
        vault.grantRole(Roles.CREDIT_ROLE, creditModule);
        vm.prank(creditModule);
        vault.beginYieldNotification();

        vm.expectEmit(true, true, false, true, address(vault));
        emit IsUSDfr.FeeOperationEmergencyCleared(creditModule, 2);
        vm.prank(admin);
        vault.clearStaleFeeOperation();

        vault.accrueFees();
    }

    function test_feeNeutralBracketRejectsAChangedShareSupply() public {
        vm.prank(admin);
        vault.grantRole(Roles.FEE_ACCOUNTING_ROLE, address(this));
        uint256 expectedSupply = vault.totalSupply();
        vault.beginFeeNeutralMarkedNavChange();

        deal(address(vault), alice, vault.balanceOf(alice) + 1, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                IsUSDfr.SUSDfr_FeeOperationSupplyChanged.selector, expectedSupply, expectedSupply + 1
            )
        );
        vault.endFeeNeutralMarkedNavChange();

        vm.prank(admin);
        vault.clearStaleFeeOperation();
    }

    function test_juniorCapacityCanImproveRedemptionNavWithoutMovingPerformanceFeeNav() public {
        _stake(alice, 1_000e18);
        MutableFeeImpairment source = new MutableFeeImpairment();
        source.set(400e18);
        vm.prank(admin);
        vault.setImpairmentSource(address(source));

        uint256 feeRateBefore = vault.feeExchangeRate();
        uint256 hwmBefore = vault.highWaterMark();
        assertEq(vault.redemptionTotalAssets(), 600e18);

        // Model 200 of contributed junior protection: senior redemption impairment
        // falls, while fee impairment remains the 400 gross risk.
        source.set(200e18);
        source.setPerformanceFeeImpairment(400e18);
        assertEq(vault.redemptionTotalAssets(), 800e18);
        assertEq(vault.feeExchangeRate(), feeRateBefore);
        (, uint256 performanceShares) = vault.accrueFees();

        assertEq(performanceShares, 0);
        assertEq(vault.highWaterMark(), hwmBefore, "junior protection cannot mutate the HWM");
    }

    function test_emergencyClear_restoresLivenessOnlyAfterCurrentSourceFails() public {
        _stake(alice, 1_000e18);
        RevertingFeeImpairment source = new RevertingFeeImpairment();
        vm.prank(admin);
        vault.setImpairmentSource(address(source));

        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, adminRole)
        );
        vault.clearUnreadableImpairmentSource();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IsUSDfr.SUSDfr_ImpairmentSourceStillReadable.selector, address(source)));
        vault.clearUnreadableImpairmentSource();

        source.setReverting(true);
        vm.prank(admin);
        vm.expectPartialRevert(IsUSDfr.SUSDfr_InsufficientImpairmentRecoveryGas.selector);
        vault.clearUnreadableImpairmentSource{gas: 300_000}();

        vm.prank(admin);
        vm.expectRevert("impairment unavailable");
        vault.setImpairmentSource(address(0));

        vm.expectRevert("impairment unavailable");
        vault.accrueFees();

        bytes memory failure = abi.encodeWithSignature("Error(string)", "impairment unavailable");
        bytes32 failureFirstWord;
        assembly ("memory-safe") {
            failureFirstWord := mload(add(failure, 0x20))
        }
        bytes32 rawFailureHash = keccak256(abi.encode(failure.length, failureFirstWord));
        bytes32 failureHash = keccak256(abi.encode(IImpairmentSource.pendingSeniorImpairment.selector, rawFailureHash));
        vm.expectEmit(true, false, false, true, address(vault));
        emit IsUSDfr.ImpairmentSourceEmergencyCleared(address(source), failureHash);
        vm.expectEmit(true, false, false, true, address(vault));
        emit SUSDfr.ImpairmentSourceUpdated(address(0));
        vm.prank(admin);
        vault.clearUnreadableImpairmentSource();

        assertEq(vault.impairmentSource(), address(0));
        vault.accrueFees();

        _mintUSDfr(bob, 1e6);
        vm.startPrank(bob);
        usdfr.approve(address(vault), 1e18);
        assertGt(vault.deposit(1e18, bob), 0, "vault entry is live after emergency clear");
        vm.stopPrank();

        vm.prank(admin);
        vm.expectRevert(IsUSDfr.SUSDfr_NoImpairmentSource.selector);
        vault.clearUnreadableImpairmentSource();
    }

    function test_emergencyClear_acceptsCurrentSourceThatBecomesMalformedAndRatchetsLiftFeeFree() public {
        _stake(alice, 1_000_000e18);
        ToggleMalformedFeeImpairment source = new ToggleMalformedFeeImpairment();
        vm.prank(admin);
        vault.setImpairmentSource(address(source));

        // Eight million of value arrives while an equal impairment is live. The
        // conservative fee base therefore remains exactly at the old hurdle.
        source.set(800_000e18);
        deal(address(usdfr), address(vault), 1_800_000e18);
        assertEq(vault.redemptionTotalAssets(), 1_000_000e18);
        (, uint256 performanceShares) = vault.accrueFees();
        assertEq(performanceShares, 0, "live impairment suppresses the performance fee");

        // The source was valid when installed but now succeeds with a short ABI
        // response. This is distinct from a reverting source and exercises the
        // malformed-return branch of the fixed-budget probe.
        source.setMalformed(true);
        (bool navReadSucceeded, bytes memory navReadFailure) =
            address(vault).staticcall(abi.encodeCall(SUSDfr.redemptionTotalAssets, ()));
        assertFalse(navReadSucceeded, "a malformed impairment response must fail the live NAV read");
        assertEq(navReadFailure.length, 0, "Solidity rejects the short ABI return without synthetic data");

        bytes32 rawFailureHash = keccak256(abi.encode(uint256(0), bytes32(0)));
        bytes32 failureHash = keccak256(abi.encode(IImpairmentSource.pendingSeniorImpairment.selector, rawFailureHash));
        vm.expectEmit(true, false, false, true, address(vault));
        emit IsUSDfr.ImpairmentSourceEmergencyCleared(address(source), failureHash);
        vm.prank(admin);
        vault.clearUnreadableImpairmentSource();

        assertEq(vault.impairmentSource(), address(0));
        assertEq(vault.redemptionTotalAssets(), 1_800_000e18);
        assertApproxEqAbs(
            vault.highWaterMark(), vault.feeExchangeRate(), 1, "operational NAV lift is ratcheted fee-free"
        );
        (, performanceShares) = vault.accrueFees();
        assertEq(performanceShares, 0, "emergency recovery intentionally waives fees on the lifted mark");
    }

    function test_emergencyClear_detectsMalformedPerformanceImpairmentView() public {
        _stake(alice, 1_000e18);
        TogglePerformanceMalformedFeeImpairment source = new TogglePerformanceMalformedFeeImpairment();
        source.set(200e18);
        vm.prank(admin);
        vault.setImpairmentSource(address(source));

        source.setMalformed(true);
        bytes32 rawFailureHash = keccak256(abi.encode(uint256(0), bytes32(0)));
        bytes32 failureHash = keccak256(abi.encode(IImpairmentSource.performanceFeeImpairment.selector, rawFailureHash));
        vm.expectEmit(true, false, false, true, address(vault));
        emit IsUSDfr.ImpairmentSourceEmergencyCleared(address(source), failureHash);
        vm.prank(admin);
        vault.clearUnreadableImpairmentSource();

        assertEq(vault.impairmentSource(), address(0));
    }

    function test_emergencyClear_recoversFromSemanticallyInvalidImpairmentOrdering() public {
        _stake(alice, 1_000e18);
        MutableFeeImpairment source = new MutableFeeImpairment();
        source.set(200e18);
        vm.prank(admin);
        vault.setImpairmentSource(address(source));

        source.setPerformanceFeeImpairment(199e18);
        vm.expectRevert(abi.encodeWithSelector(IsUSDfr.SUSDfr_InvalidPerformanceFeeImpairment.selector, 200e18, 199e18));
        vault.accrueFees();

        bytes32 failureHash =
            keccak256(abi.encode(IsUSDfr.SUSDfr_InvalidPerformanceFeeImpairment.selector, 200e18, 199e18));
        vm.expectEmit(true, false, false, true, address(vault));
        emit IsUSDfr.ImpairmentSourceEmergencyCleared(address(source), failureHash);
        vm.prank(admin);
        vault.clearUnreadableImpairmentSource();

        assertEq(vault.impairmentSource(), address(0));
        vault.accrueFees();
    }

    function test_performanceFee_isProspectiveVariableAndCrystallizesOldRate() public {
        uint256 aliceShares = _stake(alice, 1_000e18);
        _addRecognizedYield(100e18);

        vm.expectEmit(false, false, false, true, address(vault));
        emit IsUSDfr.PerformanceFeeSet(1_000, 2_000);
        vm.prank(admin);
        vault.setPerformanceFee(2_000);

        uint256 oldRateFeeShares = vault.balanceOf(feeRecipient);
        assertGt(oldRateFeeShares, 0, "old gain crystallized at launch rate");
        assertApproxEqAbs(vault.convertToAssets(aliceShares), 1_090e18, 2, "old 10% rate applied");
        assertEq(vault.performanceFeeBps(), 2_000);

        _addRecognizedYield(100e18);
        (, uint256 newRateFeeShares) = vault.accrueFees();

        assertGt(newRateFeeShares, 0);
        assertApproxEqAbs(
            vault.convertToAssets(newRateFeeShares), 20e18, 100, "new 20% rate applies only to subsequent profit"
        );
    }

    function test_performanceFee_mintsTenPercentOfProfitAndResetsGlobalHwm() public {
        uint256 aliceShares = _stake(alice, 1_000e18);
        _addRecognizedYield(200e18);

        (uint256 managementShares, uint256 performanceShares) = vault.accrueFees();

        assertEq(managementShares, 0);
        assertGt(performanceShares, 0);
        assertApproxEqAbs(vault.convertToAssets(performanceShares), 20e18, 2, "10% of 200 profit");
        assertApproxEqAbs(vault.convertToAssets(aliceShares), 1_180e18, 2, "investor keeps 90% of profit");
        assertGe(vault.highWaterMark(), vault.feeExchangeRate(), "HWM resets post fee");
        assertLe(vault.highWaterMark() - vault.feeExchangeRate(), 1, "upward rounding is at most one rate unit");

        (, uint256 secondCheckpoint) = vault.accrueFees();
        assertEq(secondCheckpoint, 0, "same NAV cannot be charged twice");
    }

    function test_depositCheckpointsOldProfitBeforePricingNewInvestor() public {
        uint256 aliceShares = _stake(alice, 1_000e18);
        _addRecognizedYield(100e18);
        assertEq(vault.balanceOf(feeRecipient), 0, "fee still pending");

        uint256 bobShares = _stake(bob, 1_000e18);

        assertGt(vault.balanceOf(feeRecipient), 0, "old performance crystallized first");
        assertApproxEqAbs(vault.convertToAssets(aliceShares), 1_090e18, 2, "alice bears old fee");
        assertApproxEqAbs(vault.convertToAssets(bobShares), 1_000e18, 2, "bob enters after old fee");
    }

    function test_depositDuringZeroExitImpairmentSharesDeferredGlobalPerformanceFee() public {
        _stake(alice, 1_000_000e18);
        MutableFeeImpairment source = new MutableFeeImpairment();
        source.set(0);
        source.setPerformanceFeeImpairment(400_000e18);
        vm.prank(admin);
        vault.setImpairmentSource(address(source));
        _addRecognizedYield(200_000e18);

        assertEq(source.pendingSeniorImpairment(), 0, "queued-exit impairment is zero");
        assertLt(vault.feeExchangeRate(), vault.highWaterMark(), "performance gain is deferred below the global HWM");
        uint256 bobShares = _stake(bob, 1_000_000e18);
        uint256 bobValueBeforeCure = vault.convertToAssets(bobShares);

        source.setPerformanceFeeImpairment(0);
        uint256 bobFeeNetPreview = vault.convertToAssets(bobShares);
        assertLt(
            bobFeeNetPreview,
            bobValueBeforeCure,
            "the entrant shares the later global fee despite zero exit impairment at entry"
        );

        (, uint256 performanceShares) = vault.accrueFees();
        assertApproxEqAbs(vault.convertToAssets(performanceShares), 20_000e18, 1e6);
        assertApproxEqAbs(
            vault.convertToAssets(bobShares),
            bobFeeNetPreview,
            1,
            "preview discloses the same dilution later crystallized"
        );
    }

    function test_impairedDeposit_preservesAssetHurdleAndChargesOnlyRealYieldOnCure() public {
        _stake(alice, 1_000_000e18);
        MutableFeeImpairment source = new MutableFeeImpairment();
        source.set(800_000e18);
        vm.prank(admin);
        vault.setImpairmentSource(address(source));

        // The vault has earned 500k, but the 800k live impairment leaves marked NAV
        // 300k below the original asset hurdle. No performance fee is due yet.
        _addRecognizedYield(500_000e18);
        assertEq(vault.redemptionTotalAssets(), 700_000e18);
        uint256 hurdleBefore = _hurdleAssets();
        assertApproxEqAbs(hurdleBefore, 1_000_000e18, 1);

        _stake(bob, 1_000_000e18);
        uint256 hurdleAfter = _hurdleAssets();
        assertApproxEqAbs(
            hurdleAfter,
            hurdleBefore + 1_000_000e18,
            1,
            "deposit principal must add to, rather than replace, the pre-flow asset hurdle"
        );

        source.set(0);
        (, uint256 performanceShares) = vault.accrueFees();
        assertApproxEqAbs(
            vault.convertToAssets(performanceShares),
            50_000e18,
            10,
            "only the genuine 500k gain above the preserved hurdle is chargeable"
        );
    }

    function test_impairedRedeem_preservesRemainingAssetHurdleAndCureMintsNoFee() public {
        uint256 aliceShares = _stake(alice, 1_000_000e18);
        MutableFeeImpairment source = new MutableFeeImpairment();
        source.set(300_000e18);
        vm.prank(admin);
        vault.setImpairmentSource(address(source));
        vm.prank(admin);
        vault.setRedemptionQueue(address(this));

        uint256 hurdleBefore = _hurdleAssets();
        uint256 sharesToBurn = aliceShares / 2;
        vm.prank(alice);
        vault.transfer(address(this), sharesToBurn);
        uint256 assetsPaid = vault.redeem(sharesToBurn, alice, address(this));

        assertApproxEqAbs(assetsPaid, 350_000e18, 1);
        assertApproxEqAbs(
            _hurdleAssets(),
            hurdleBefore - assetsPaid,
            1,
            "an impaired exit must carry its exact asset hurdle out with the assets paid"
        );

        source.set(0);
        (, uint256 performanceShares) = vault.accrueFees();
        assertEq(performanceShares, 0, "curing an unrealized mark after an exit is not investment profit");
    }

    function test_redemptionNavAboveFeeNav_exitCarriesProRataHurdleAndCureChargesOnlyStayers() public {
        uint256 aliceShares = _stake(alice, 1_000_000e18);
        MutableFeeImpairment source = new MutableFeeImpairment();
        source.set(0);
        source.setPerformanceFeeImpairment(400_000e18);
        vm.prank(admin);
        vault.setImpairmentSource(address(source));

        _addRecognizedYield(1_000_000e18);
        vault.accrueFees();
        uint256 hurdleBefore = _hurdleAssets();
        uint256 supplyBefore = vault.totalSupply();
        assertGt(vault.redemptionTotalAssets(), 1_900_000e18);
        assertLt(vault.feeExchangeRate(), vault.currentExchangeRate());

        vm.prank(admin);
        vault.setRedemptionQueue(address(this));
        uint256 sharesToBurn = aliceShares * 9 / 10;
        vm.prank(alice);
        vault.transfer(address(this), sharesToBurn);
        uint256 assetsPaid = vault.redeem(sharesToBurn, alice, address(this));

        assertGt(assetsPaid, hurdleBefore, "the regression requires an exit larger than the fee hurdle");
        uint256 assetCarry = assetsPaid >= hurdleBefore ? 0 : hurdleBefore - assetsPaid;
        uint256 proRataCarry =
            Math.mulDiv(hurdleBefore, vault.totalSupply() + 1e6, supplyBefore + 1e6, Math.Rounding.Ceil);
        uint256 expectedHurdleAfter = Math.max(assetCarry, proRataCarry);
        uint256 hwmRoundingDust = Math.ceilDiv(vault.totalSupply() + 1e6, 10 ** vault.decimals());
        assertApproxEqAbs(
            _hurdleAssets(),
            expectedHurdleAfter,
            hwmRoundingDust,
            "an exit cannot transfer the leaver's deferred performance-fee hurdle to stayers"
        );

        source.setPerformanceFeeImpairment(0);
        uint256 expectedProfitAssets = vault.totalAssets() + 1 - _hurdleAssets();
        uint256 expectedPerformanceAssets =
            Math.mulDiv(expectedProfitAssets, vault.performanceFeeBps(), Config.BPS, Math.Rounding.Floor);
        (, uint256 performanceShares) = vault.accrueFees();
        assertApproxEqAbs(
            vault.convertToAssets(performanceShares),
            expectedPerformanceAssets,
            10,
            "the cure charges only the remaining holders' pro-rata deferred profit"
        );
    }

    function test_healthyDepositAndRedeem_keepTheOriginalPerShareHwm() public {
        uint256 aliceShares = _stake(alice, 1_000_000e18);
        assertEq(vault.highWaterMark(), 1e18, "healthy deposit preserves the legacy control value");

        vm.prank(admin);
        vault.setRedemptionQueue(address(this));
        uint256 sharesToBurn = aliceShares / 2;
        vm.prank(alice);
        vault.transfer(address(this), sharesToBurn);
        vault.redeem(sharesToBurn, alice, address(this));

        assertEq(vault.highWaterMark(), 1e18, "healthy exit remains byte-identical to the old HWM control");
    }

    function test_assetFlowHurdle_neverAnchorsBelowFeeNavMovedByTrustedCallback() public {
        _stake(alice, 1_000e18);
        uint256 hurdleBefore = _hurdleAssets();
        uint256 supplyBefore = vault.totalSupply();

        HwmRaisingPoints points = new HwmRaisingPoints(vault, usdfr, 100e18);
        _authorizeYieldSink(address(points)); // R16-M1: mintYield destinations are named
        _receiveYield(address(points), 100e6);
        vm.prank(admin);
        vault.setPointsModule(address(points));

        uint256 bobShares = _stake(bob, 100e18);
        assertTrue(points.sent(), "trusted callback moved the donated assets");

        uint256 principalOnlyRate = Math.mulDiv(
            hurdleBefore + 100e18, 10 ** vault.decimals(), supplyBefore + bobShares + 1e6, Math.Rounding.Ceil
        );
        assertGt(vault.highWaterMark(), principalOnlyRate, "the post-flow fee NAV is the lower bound");
        assertApproxEqAbs(vault.highWaterMark(), vault.feeExchangeRate(), 1, "the HWM cannot finish below live fee NAV");
    }

    function test_erc4626Previews_includePendingFeesAndMatchDepositExecution() public {
        uint256 aliceShares = _stake(alice, 1_000e18);
        _addRecognizedYield(100e18);

        assertEq(vault.balanceOf(feeRecipient), 0, "fee is not yet crystallized");
        assertApproxEqAbs(vault.feeExchangeRate(), 1.1e18, 1, "gross marked fee NAV");
        assertApproxEqAbs(vault.currentExchangeRate(), 1.09e18, 2, "displayed rate is fee-net");
        assertApproxEqAbs(vault.convertToAssets(aliceShares), 1_090e18, 2, "position view is fee-net");

        uint256 previewShares = vault.previewDeposit(1_000e18);
        _mintUSDfr(bob, 1_000e6);
        vm.startPrank(bob);
        usdfr.approve(address(vault), 1_000e18);
        uint256 actualShares = vault.deposit(1_000e18, bob);
        vm.stopPrank();

        assertEq(actualShares, previewShares, "preview simulates the checkpoint deposit executes");
        assertGt(vault.balanceOf(feeRecipient), 0, "deposit crystallized pending fee");
    }

    function test_feeNeutralMarkedNavBracket_usesConcreteSupplyForNestedPreview() public {
        uint256 aliceShares = _stake(alice, 1_000e18);
        uint256 previewBefore = vault.previewRedeem(aliceShares / 2);
        uint256 hurdleBefore = _hurdleAssets();
        FeeNeutralPreviewCaller caller = new FeeNeutralPreviewCaller();

        vm.prank(admin);
        vault.grantRole(Roles.FEE_ACCOUNTING_ROLE, address(caller));

        uint256 previewInside = caller.bracketAndPreviewRedeem(vault, aliceShares / 2);

        assertEq(previewInside, previewBefore, "an active fee bracket uses the concrete share supply");
        assertEq(_hurdleAssets(), hurdleBefore, "a no-op bracket cannot move the asset hurdle");
    }

    function test_feeNeutralMarkedNavBracket_rejectsUnmatchedEnd() public {
        vm.prank(admin);
        vault.grantRole(Roles.FEE_ACCOUNTING_ROLE, alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IsUSDfr.SUSDfr_InvalidFeeOperation.selector, alice, uint8(1), uint8(0)));
        vault.endFeeNeutralMarkedNavChange();
    }

    function test_managementFee_isProspectiveVariableAndCompoundsWithoutLoweringHwm() public {
        uint256 aliceShares = _stake(alice, 1_000e18);

        vm.prank(admin);
        vault.setManagementFee(200);
        vm.warp(block.timestamp + 182.5 days);

        uint256 previewRate = vault.currentExchangeRate();
        assertApproxEqAbs(
            previewRate, 0.989949493661e18, 1e6, "fee-net view reflects geometric half-year management fee"
        );
        assertEq(vault.balanceOf(feeRecipient), 0, "preview does not mutate or mint");

        // Changing the rate crystallizes the old 2% annualized rate first.
        vm.prank(admin);
        vault.setManagementFee(100);
        assertApproxEqAbs(vault.currentExchangeRate(), previewRate, 1, "crystallization does not jump fee-net view");
        assertApproxEqAbs(
            vault.convertToAssets(vault.balanceOf(feeRecipient)),
            10.050506339e18,
            1e9,
            "two half-years compose to the quoted annual fee"
        );

        vm.warp(block.timestamp + 365 days);
        vault.accrueFees();

        assertEq(vault.managementFeeBps(), 100);
        assertApproxEqAbs(
            vault.convertToAssets(aliceShares),
            previewRate * 1_000 * 9_900 / Config.BPS,
            1e6,
            "2% half-year then 1% year"
        );
        assertEq(vault.highWaterMark(), 1e18, "management dilution never lowers the profit hurdle");
        assertEq(vault.lastFeeAccrual(), uint64(block.timestamp));
    }

    function test_managementFee_isCheckpointFrequencyNeutral() public {
        uint256 aliceShares = _stake(alice, 1_000e18);
        vm.prank(admin);
        vault.setManagementFee(200);
        uint256 start = block.timestamp;
        uint256 snapshot = vm.snapshotState();

        vm.warp(start + 365 days);
        vault.accrueFees();
        uint256 annualCheckpointValue = vault.convertToAssets(aliceShares);

        assertTrue(vm.revertToState(snapshot));
        for (uint256 i = 1; i <= 12; i++) {
            vm.warp(start + i * (365 days / 12));
            vault.accrueFees();
        }
        uint256 monthlyCheckpointValue = vault.convertToAssets(aliceShares);

        assertApproxEqAbs(
            monthlyCheckpointValue,
            annualCheckpointValue,
            1e6,
            "permissionless checkpoint cadence cannot materially change the fee"
        );
    }

    function test_managementAndPerformanceFees_stackWithoutDilutingEachOther() public {
        _stake(alice, 1_000e18);
        vm.prank(admin);
        vault.setManagementFee(200);
        _addRecognizedYield(200e18);
        vm.warp(block.timestamp + 365 days);

        uint256 markedAssets = vault.redemptionTotalAssets();
        uint256 supplyBefore = vault.totalSupply();
        uint256 hwm = vault.highWaterMark();
        uint256 aliceShares = vault.balanceOf(alice);
        (uint256 managementShares, uint256 performanceShares) = vault.accrueFees();

        uint256 managementAssets = markedAssets * 200 / Config.BPS;
        uint256 hurdleAssets = (hwm * (supplyBefore + 1e6) + (10 ** vault.decimals()) - 1) / (10 ** vault.decimals());
        uint256 performanceAssets = (markedAssets + 1 - managementAssets - hurdleAssets) * 1_000 / Config.BPS;

        assertGt(managementShares, 0);
        assertGt(performanceShares, 0);
        assertApproxEqAbs(
            vault.convertToAssets(managementShares + performanceShares),
            managementAssets + performanceAssets,
            2_000,
            "combined mint preserves both asset-denominated fees"
        );
        assertApproxEqAbs(
            vault.convertToAssets(aliceShares), 1_158.4e18, 2_000, "management first, then 10% of net profit"
        );
    }

    function test_managementAndPerformanceFees_useDistinctNavBasesInSequence() public {
        _stake(alice, 1_000_000e18);
        MutableFeeImpairment source = new MutableFeeImpairment();
        source.set(100_000e18);
        source.setPerformanceFeeImpairment(400_000e18);
        vm.prank(admin);
        vault.setImpairmentSource(address(source));
        vm.prank(admin);
        vault.setManagementFee(200);

        _addRecognizedYield(600_000e18);
        vm.warp(block.timestamp + 365 days);

        uint256 markedAssets = vault.redemptionTotalAssets();
        uint256 performanceMarkedAssets = vault.totalAssets() - 400_000e18;
        uint256 effectiveSupply = vault.totalSupply() + 1e6;
        uint256 annualRetentionWad = uint256(FixedPointMathLib.powWad(int256(0.98e18), int256(1e18)));
        uint256 managementAssets = Math.mulDiv(markedAssets, 1e18 - annualRetentionWad, 1e18, Math.Rounding.Floor);
        uint256 expectedManagementShares =
            Math.mulDiv(managementAssets, effectiveSupply, markedAssets + 1 - managementAssets);
        uint256 netPerformanceAssets = Math.mulDiv(
            performanceMarkedAssets + 1,
            effectiveSupply,
            effectiveSupply + expectedManagementShares,
            Math.Rounding.Floor
        );
        uint256 profitAssets = netPerformanceAssets - _hurdleAssets();
        uint256 performanceAssets =
            Math.mulDiv(profitAssets, vault.performanceFeeBps(), Config.BPS, Math.Rounding.Floor);
        uint256 expectedTotalShares = Math.mulDiv(
            managementAssets + performanceAssets,
            effectiveSupply,
            markedAssets + 1 - managementAssets - performanceAssets,
            Math.Rounding.Floor
        );

        (uint256 managementShares, uint256 performanceShares) = vault.accrueFees();

        assertEq(managementShares, expectedManagementShares, "management uses redemption NAV");
        assertEq(
            performanceShares,
            expectedTotalShares - expectedManagementShares,
            "performance uses post-management performance NAV"
        );
        assertGt(managementShares, 0);
        assertGt(performanceShares, 0);
    }

    function test_lossRecoveryBelowPriorHwmPaysNoSecondPerformanceFee() public {
        _stake(alice, 1_000e18);
        _addRecognizedYield(200e18);
        vault.accrueFees();
        uint256 firstFeeShares = vault.balanceOf(feeRecipient);
        uint256 peak = vault.highWaterMark();

        _burnSeniorLoss(300e18);
        _addRecognizedYield(200e18);
        vault.accrueFees();

        assertEq(vault.balanceOf(feeRecipient), firstFeeShares, "recovery below peak is fee-free");
        assertEq(vault.highWaterMark(), peak, "loss does not reset HWM downward");

        _addRecognizedYield(120e18);
        vault.accrueFees();
        uint256 incrementalFeeShares = vault.balanceOf(feeRecipient) - firstFeeShares;
        assertApproxEqAbs(vault.convertToAssets(incrementalFeeShares), 2e18, 100, "only new profit above peak charged");
    }

    function test_assessedImpairmentSuppressesFeeUntilNetNavExceedsOldPeak() public {
        _stake(alice, 1_000e18);
        MutableFeeImpairment source = new MutableFeeImpairment();
        source.set(200e18);
        vm.prank(admin);
        vault.setImpairmentSource(address(source));

        _addRecognizedYield(100e18);
        vault.accrueFees();
        assertEq(vault.balanceOf(feeRecipient), 0, "no fee while net marked NAV is below HWM");
        assertEq(vault.feeExchangeRate(), 0.9e18);

        source.set(0);
        vault.accrueFees();
        assertApproxEqAbs(
            vault.convertToAssets(vault.balanceOf(feeRecipient)), 10e18, 2, "10% only on net profit over old peak"
        );
    }

    function test_feeRecipientChange_crystallizesToReplacementAndRequiresExemption() public {
        _stake(alice, 1_000e18);
        _addRecognizedYield(100e18);
        address replacement = makeAddr("replacementFeeRecipient");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IsUSDfr.SUSDfr_FeeRecipientNotExempt.selector, replacement));
        vault.setFeeRecipient(replacement);

        vm.prank(admin);
        compliance.setProtocolExempt(replacement, true);
        vm.prank(admin);
        vault.setFeeRecipient(replacement);

        assertEq(vault.balanceOf(feeRecipient), 0, "rotation happens before the checkpoint");
        assertGt(vault.balanceOf(replacement), 0, "pending fee went to the valid replacement");
        assertEq(vault.feeRecipient(), replacement);
    }

    function test_feeRecipientChange_recoversFromBlockedNonExemptOldRecipient() public {
        _stake(alice, 1_000e18);
        _addRecognizedYield(100e18);
        address replacement = makeAddr("recoveryFeeRecipient");

        vm.startPrank(admin);
        compliance.setProtocolExempt(replacement, true);
        compliance.setProtocolExempt(feeRecipient, false);
        vm.stopPrank();
        vm.prank(complianceAdmin);
        compliance.setJurisdictionBlocked(feeRecipient, true);

        vm.prank(admin);
        vault.setFeeRecipient(replacement);

        assertEq(vault.feeRecipient(), replacement);
        assertEq(vault.balanceOf(feeRecipient), 0);
        assertGt(vault.balanceOf(replacement), 0, "recovery checkpoint bypassed the unusable old recipient");
    }

    function test_managementFee_longDormancyRemainsFinite() public {
        _stake(alice, 1_000e18);
        vm.prank(admin);
        vault.setManagementFee(200);

        vm.warp(block.timestamp + 100 * 365 days);
        (uint256 managementShares,) = vault.accrueFees();

        assertGt(managementShares, 0);
        assertGt(vault.convertToAssets(vault.balanceOf(alice)), 0, "long dormancy cannot hit a division singularity");
        assertEq(vault.lastFeeAccrual(), uint64(block.timestamp));
    }

    function testFuzz_feeCheckpoint_preservesAssetsAndCannotChargeSameStateTwice(
        uint96 stakeUnits,
        uint96 yieldUnits,
        uint16 managementBps,
        uint32 elapsedDays
    ) public {
        uint256 assets = bound(uint256(stakeUnits), 1, 500_000) * 1e18;
        uint256 yieldAssets = bound(uint256(yieldUnits), 0, 500_000) * 1e18;
        managementBps = uint16(bound(uint256(managementBps), 0, Config.MAX_MANAGEMENT_FEE_BPS));
        elapsedDays = uint32(bound(uint256(elapsedDays), 0, 20 * 365));

        _stake(alice, assets);
        if (managementBps != 0) {
            vm.prank(admin);
            vault.setManagementFee(managementBps);
        }
        if (yieldAssets != 0) _addRecognizedYield(yieldAssets);
        vm.warp(block.timestamp + uint256(elapsedDays) * 1 days);

        uint256 assetsBefore = vault.totalAssets();
        uint256 previewRate = vault.currentExchangeRate();
        vault.accrueFees();

        assertEq(vault.totalAssets(), assetsBefore, "fee shares cannot remove backing assets");
        assertApproxEqAbs(
            vault.currentExchangeRate(), previewRate, 5, "crystallization cannot impose previewed dilution twice"
        );
        assertGe(vault.highWaterMark(), vault.feeExchangeRate(), "checkpoint leaves no uncharged peak");

        (uint256 secondManagement, uint256 secondPerformance) = vault.accrueFees();
        assertEq(secondManagement, 0, "zero elapsed management cannot be charged twice");
        assertEq(secondPerformance, 0, "unchanged NAV performance cannot be charged twice");
    }

    function test_pointsCallback_cannotAccrueFeesAgainstTransientShareState() public {
        FeeReenteringPoints points = new FeeReenteringPoints(vault);
        vm.prank(admin);
        vault.setPointsModule(address(points));

        _stake(alice, 1_000e18);
        assertEq(points.attempts(), 1, "deposit mint reached points hook");
        assertEq(points.lastRevertSelector(), IsUSDfr.SUSDfr_FeeAccrualReentrant.selector);
        assertFalse(points.unexpectedSuccess(), "callback cannot checkpoint transient state");
        assertEq(points.nestedTransferRevertSelector(), IsUSDfr.SUSDfr_FeeAccrualReentrant.selector);
        assertFalse(points.nestedTransferUnexpectedSuccess(), "callback cannot nest a share update");

        _addRecognizedYield(100e18);
        vault.accrueFees();

        assertEq(points.attempts(), 2, "fee-share mint also reached points hook");
        assertEq(points.lastRevertSelector(), IsUSDfr.SUSDfr_FeeAccrualReentrant.selector);
        assertFalse(points.unexpectedSuccess());
        assertEq(points.nestedTransferRevertSelector(), IsUSDfr.SUSDfr_FeeAccrualReentrant.selector);
        assertFalse(points.nestedTransferUnexpectedSuccess());
        assertGt(vault.balanceOf(feeRecipient), 0, "outer checkpoint still succeeds");
    }

    function test_privilegedPointsCallback_cannotCheckpointInsideOrdinaryTransfer() public {
        _stake(alice, 1_000e18);
        FeeSetterReenteringPoints points = new FeeSetterReenteringPoints(vault);
        vm.startPrank(admin);
        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), address(points));
        vault.setPointsModule(address(points));
        vm.stopPrank();

        vm.prank(alice);
        assertTrue(vault.transfer(bob, 1));

        assertEq(points.lastRevertSelector(), IsUSDfr.SUSDfr_FeeAccrualReentrant.selector);
        assertFalse(points.unexpectedSuccess(), "share-update lock is independent of caller privilege");
        assertEq(vault.balanceOf(bob), 1, "outer transfer remains fail-open");
    }

    function test_legacyProxy_zeroHwmSeedsCurrentRateWithoutHistoricalCharge() public {
        _stake(alice, 1_000e18);
        _addRecognizedYield(100e18);
        vm.store(address(vault), bytes32(uint256(SUSDFR_STORAGE_LOCATION) + 7), bytes32(0));

        uint256 recipientSharesBefore = vault.balanceOf(feeRecipient);
        vault.accrueFees();

        assertEq(vault.balanceOf(feeRecipient), recipientSharesBefore, "legacy baseline is fee-free");
        assertApproxEqAbs(vault.highWaterMark(), vault.feeExchangeRate(), 1, "HWM seeds at current marked NAV");
    }

    function test_legacyProxy_zeroHwmSeedsRealizedAssetsAcrossBothImpairmentViews() public {
        _stake(alice, 1_000_000e18);
        MutableFeeImpairment source = new MutableFeeImpairment();
        source.set(300_000e18);
        source.setPerformanceFeeImpairment(400_000e18);
        vm.prank(admin);
        vault.setImpairmentSource(address(source));
        _addRecognizedYield(100_000e18);
        vm.store(address(vault), bytes32(uint256(SUSDFR_STORAGE_LOCATION) + 7), bytes32(0));

        uint256 expectedSeed =
            Math.mulDiv(10 ** vault.decimals(), vault.totalAssets() + 1, vault.totalSupply() + 1e6, Math.Rounding.Ceil);
        uint256 recipientSharesBefore = vault.balanceOf(feeRecipient);
        vault.accrueFees();

        assertEq(vault.balanceOf(feeRecipient), recipientSharesBefore, "legacy baseline remains fee-free");
        assertEq(vault.highWaterMark(), expectedSeed, "legacy HWM anchors to all realized assets");
        assertGt(
            vault.highWaterMark(), vault.currentExchangeRate(), "pending impairment cannot lower the migration seed"
        );
        assertGt(vault.highWaterMark(), vault.feeExchangeRate(), "gross impairment cannot lower the migration seed");

        source.set(0);
        (, uint256 performanceShares) = vault.accrueFees();
        assertEq(performanceShares, 0, "pre-upgrade value is not charged when both live marks cure");
    }

    function test_legacyProxy_zeroFeeRecipientFailsLoudlyWhenFeeIsDue() public {
        _stake(alice, 1_000e18);
        _addRecognizedYield(100e18);
        bytes32 packedSlot = bytes32(uint256(SUSDFR_STORAGE_LOCATION) + 6);
        uint256 packed = uint256(vm.load(address(vault), packedSlot));
        vm.store(address(vault), packedSlot, bytes32(packed & ~uint256(type(uint160).max)));
        assertEq(vault.feeRecipient(), address(0), "legacy migration fixture cleared recipient");

        vm.expectRevert(SUSDfr.SUSDfr_ZeroAddress.selector);
        vault.accrueFees();
    }

    function test_underlyingPointsCallback_cannotCheckpointMidDeposit() public {
        _mintUSDfr(alice, 1_000e6);
        UnderlyingFeeReenteringPoints points = new UnderlyingFeeReenteringPoints(vault);
        vm.prank(admin);
        usdfr.setPointsModule(address(points));

        vm.startPrank(alice);
        usdfr.approve(address(vault), 1_000e18);
        uint256 shares = vault.deposit(1_000e18, alice);
        vm.stopPrank();

        assertEq(points.attempts(), 1, "underlying transfer reached points hook");
        assertEq(
            points.lastRevertSelector(),
            ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector,
            "vault-wide guard blocks checkpoint before deposit shares mint"
        );
        assertFalse(points.unexpectedSuccess());
        assertEq(vault.balanceOf(alice), shares, "outer deposit still succeeds");
        assertEq(vault.balanceOf(feeRecipient), 0, "deposit principal cannot be mistaken for profit");
    }
}
