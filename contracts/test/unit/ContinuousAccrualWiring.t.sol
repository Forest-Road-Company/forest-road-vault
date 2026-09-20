// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {Validate} from "../../script/Validate.s.sol";
import {ContinuousAccrualDeployment, IAccrualBoundConsumer} from "../../script/ContinuousAccrualDeployment.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {SUSDfr} from "../../src/sUSDfr.sol";
import {USDfr} from "../../src/USDfr.sol";
import {WaterfallEngine} from "../../src/WaterfallEngine.sol";

contract ContinuousAccrualValidationHarness is Validate {
    function checkAccrual(M memory a) external view {
        _validateContinuousAccrual(a);
    }
}

/// @notice Local construction and wiring fixtures; no deployment entrypoint or receipt policy runs.
contract ContinuousAccrualWiringTest is Test, Deploy {
    D private deployed;
    Ctx private context;
    ContinuousAccrualValidationHarness private validator;

    function setUp() public {
        context.deployer = address(this);
        context.opsAdmin = address(this);
        context.queueKeeper = address(0x1001);
        context.frTreasury = address(0x1002);
        context.feeRecipient = address(0x1003);
        context.anchorCurator = address(0x1004);
        context.attester1 = address(0x1005);
        context.attester2 = address(0x1006);
        context.keepOpsAdmin = true;
        deployed = _deployAll(context);
        validator = new ContinuousAccrualValidationHarness();
    }

    function test_freshWiringEnablesAllConsumers() public {
        _wire(deployed, context);
        validator.checkAccrual(_args());
        IContinuousAccrual.Snapshot memory snapshot = ReserveManager(deployed.reserves).accrualSnapshot();
        assertTrue(snapshot.enabled);
        assertTrue(snapshot.fresh);
        assertEq(snapshot.gross, 0);
        assertEq(snapshot.feeRecipient, context.feeRecipient);
    }

    function test_localMintAndStakeSucceedAfterActivation() public {
        _wire(deployed, context);
        _seed(deployed, context);
        validator.checkAccrual(_args());
        uint256 assets = SUSDfr(deployed.vault).totalAssets();
        assertGt(assets, 0, "mint/stake fixture must hold real mock-backed assets");
        assertEq(assets, USDfr(deployed.usdfr).totalSupply());
        assertEq(assets, ReserveManager(deployed.reserves).totalBackingValue());
        assertGt(SUSDfr(deployed.vault).balanceOf(SEED_SINK), 0);
    }

    function test_validatorRejectsDisabledRecognition() public {
        Validate.M memory args = _args();
        vm.expectRevert(ContinuousAccrualDeployment.AccrualDeployment_Disabled.selector);
        validator.checkAccrual(args);
    }

    function test_validatorEntryPointRequiresEnabledRecognition() public {
        Validate.M memory args = _args();
        vm.expectRevert(ContinuousAccrualDeployment.AccrualDeployment_Disabled.selector);
        validator.validateDeployment(args);
    }

    function test_handoverValidationRequiresEnabledRecognition() public {
        Validate.M memory args = _args();
        vm.expectRevert(ContinuousAccrualDeployment.AccrualDeployment_Disabled.selector);
        validator.validateHandover(args);
    }

    function test_validatorRejectsEachWrongConsumerBinding() public {
        _wire(deployed, context);
        address[7] memory consumers = [
            deployed.usdfr,
            deployed.controller,
            deployed.vault,
            deployed.waterfall,
            deployed.bridge,
            deployed.registry,
            deployed.defaultManager
        ];
        Validate.M memory args = _args();
        address wrong = address(0xBADC0DE);
        for (uint256 i; i < consumers.length; ++i) {
            vm.mockCall(consumers[i], abi.encodeCall(IAccrualBoundConsumer.accrualReserve, ()), abi.encode(wrong));
            vm.expectRevert(
                abi.encodeWithSelector(
                    ContinuousAccrualDeployment.AccrualDeployment_WrongConsumer.selector,
                    consumers[i],
                    wrong,
                    deployed.reserves
                )
            );
            validator.checkAccrual(args);
            vm.clearMockedCalls();
        }
        validator.checkAccrual(args);
    }

    function test_validatorRejectsASeparateLossBackstopMismatch() public {
        _wire(deployed, context);
        Validate.M memory args = _args();
        vm.mockCall(deployed.defaultManager, abi.encodeWithSignature("backstop()"), abi.encode(address(0)));
        vm.expectRevert(ContinuousAccrualDeployment.AccrualDeployment_WrongModules.selector);
        validator.checkAccrual(args);
        vm.clearMockedCalls();
        validator.checkAccrual(args);
    }

    function test_validatorRejectsWrongModuleIdentities() public {
        _wire(deployed, context);
        Validate.M memory args = _args();
        args.usdfr = address(0xBADC0DE);
        vm.expectRevert(ContinuousAccrualDeployment.AccrualDeployment_WrongModules.selector);
        validator.checkAccrual(args);
    }

    function test_validatorRejectsStaleRecognition() public {
        _wire(deployed, context);
        Validate.M memory args = _args();
        IContinuousAccrual.Snapshot memory snapshot = ReserveManager(deployed.reserves).accrualSnapshot();
        snapshot.fresh = false;
        vm.mockCall(deployed.reserves, abi.encodeCall(IContinuousAccrual.accrualSnapshot, ()), abi.encode(snapshot));
        vm.expectRevert(
            abi.encodeWithSelector(
                ContinuousAccrualDeployment.AccrualDeployment_Stale.selector, snapshot.accruedThrough
            )
        );
        validator.checkAccrual(args);
    }

    function test_validatorRejectsWrongFeeRecipient() public {
        _wire(deployed, context);
        Validate.M memory args = _args();
        address wrong = address(0xBADC0DE);
        vm.mockCall(deployed.waterfall, abi.encodeCall(WaterfallEngine.feeRecipient, ()), abi.encode(wrong));
        vm.expectRevert(
            abi.encodeWithSelector(
                ContinuousAccrualDeployment.AccrualDeployment_WrongFeeRecipient.selector, context.feeRecipient, wrong
            )
        );
        validator.checkAccrual(args);
    }

    function test_validatorRejectsVesting() public {
        _wire(deployed, context);
        Validate.M memory args = _args();
        vm.mockCall(deployed.vault, abi.encodeCall(SUSDfr.yieldVestingPeriod, ()), abi.encode(uint64(1)));
        vm.expectRevert(ContinuousAccrualDeployment.AccrualDeployment_VestingEnabled.selector);
        validator.checkAccrual(args);
    }

    function _args() private view returns (Validate.M memory a) {
        a.usdfr = deployed.usdfr;
        a.controller = deployed.controller;
        a.vault = deployed.vault;
        a.waterfall = deployed.waterfall;
        a.bridge = deployed.bridge;
        a.registry = deployed.registry;
        a.defaultManager = deployed.defaultManager;
        a.reserves = deployed.reserves;
    }
}
