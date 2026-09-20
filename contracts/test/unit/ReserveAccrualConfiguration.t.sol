// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {RealOracleFixture} from "../helpers/RealOracleFixture.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {ReserveAccrualLib} from "../../src/libraries/ReserveAccrualLib.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @dev Real native modules; mocked read replies represent inconsistent module configuration.
contract ReserveAccrualConfigurationTest is RealOracleFixture {
    event AccrualConfigured(address indexed token, address indexed controller, address indexed vault);
    event AccrualEnabled(uint64 indexed at, uint16 feeBps, address feeRecipient);

    function _modules() private view returns (IContinuousAccrual.Modules memory) {
        return IContinuousAccrual.Modules(
            address(usdfr),
            address(controller),
            address(vault),
            address(waterfall),
            address(bridge),
            address(registry),
            address(defaultManager)
        );
    }

    function _addresses() private view returns (address[7] memory) {
        return [
            address(usdfr),
            address(controller),
            address(vault),
            address(waterfall),
            address(bridge),
            address(registry),
            address(defaultManager)
        ];
    }

    function _reject(IContinuousAccrual.Modules memory m) private {
        vm.prank(admin);
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_WrongModules.selector);
        reserves.configureContinuousAccrual(m);
        assertEq(keccak256(abi.encode(reserves.accrualModules())), keccak256(new bytes(7 * 32)), "partial tuple write");
        assertFalse(reserves.accrualSnapshot().enabled);
    }

    function _configure() private {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit AccrualConfigured(address(usdfr), address(controller), address(vault));
        reserves.configureContinuousAccrual(_modules());
        assertEq(keccak256(abi.encode(reserves.accrualModules())), keccak256(abi.encode(_modules())));
    }

    function _bindConsumers() private {
        vm.startPrank(admin);
        usdfr.setAccrualReserve(address(reserves));
        controller.enableContinuousAccrual();
        vault.setAccrualReserve(address(reserves));
        registry.setAccrualReserve(address(reserves));
        bridge.setAccrualReserve(address(reserves));
        waterfall.setAccrualReserve(address(reserves));
        defaultManager.setAccrualReserve(address(reserves));
        vm.stopPrank();
    }

    function _enable() private {
        uint16 fee = waterfall.protocolFeeBps();
        address recipient = waterfall.feeRecipient();
        vm.prank(admin);
        vm.expectEmit(true, false, false, true, address(reserves));
        emit AccrualEnabled(uint64(block.timestamp), fee, recipient);
        reserves.enableContinuousAccrual();
        IContinuousAccrual.Snapshot memory s = reserves.accrualSnapshot();
        assertTrue(s.enabled);
        assertTrue(s.fresh);
        assertEq(s.accruedThrough, block.timestamp);
        assertEq(s.gross, 0);
        assertEq(s.unposted, 0);
        assertEq(s.unissued, 0);
        assertEq(s.feeRecipient, recipient);
    }

    function test_everyModuleRequiresCodeBeforeTheTupleIsStored() public {
        for (uint256 i; i < 7; ++i) {
            for (uint256 empty; empty < 2; ++empty) {
                address[7] memory values = _addresses();
                values[i] = empty == 0 ? address(0) : address(0xBADC0DE);
                _reject(abi.decode(abi.encode(values), (IContinuousAccrual.Modules)));
            }
        }
        _configure();
    }

    function test_nativeLossBindingsCannotBeReplacedByAnotherContract() public {
        uint256[4] memory positions = [uint256(0), uint256(1), uint256(2), uint256(6)];
        for (uint256 i; i < positions.length; ++i) {
            address[7] memory values = _addresses();
            values[positions[i]] = address(registry);
            _reject(abi.decode(abi.encode(values), (IContinuousAccrual.Modules)));
        }
        _configure();
    }

    function _reply(address target, bytes memory request) private view returns (bytes memory data) {
        bool ok;
        (ok, data) = target.staticcall(request);
        assertTrue(ok, "fixture read failed");
    }

    function _rejectReply(address target, bytes memory request, bytes memory reply) private {
        vm.mockCall(target, request, reply);
        _reject(_modules());
        vm.clearMockedCalls();
    }

    function _checkRoute(address target, bytes memory request) private {
        bytes memory original = _reply(target, request);
        for (uint256 i; i < original.length / 32; ++i) {
            bytes memory changed = bytes.concat(original);
            assembly ("memory-safe") {
                mstore(add(add(changed, 32), mul(i, 32)), not(0))
            }
            _rejectReply(target, request, changed);
        }
        _rejectReply(target, request, new bytes(original.length - 1));
        _rejectReply(target, request, bytes.concat(original, bytes32(0)));
        vm.mockCallRevert(target, request, abi.encodeWithSignature("Fixture_ReadRefused()"));
        _reject(_modules());
        vm.clearMockedCalls();
    }

    function test_everyForwardRouteRejectsWrongWordsLengthsAndFailedReads() public {
        _checkRoute(address(controller), abi.encodeWithSignature("modules()"));
        _checkRoute(address(vault), abi.encodeWithSignature("asset()"));
        _checkRoute(address(bridge), abi.encodeWithSignature("modules()"));
        _checkRoute(address(waterfall), abi.encodeWithSignature("modules()"));
        _checkRoute(address(waterfall), abi.encodeWithSignature("defaultManager()"));
        _checkRoute(address(defaultManager), abi.encodeWithSignature("modules()"));
        _checkRoute(address(defaultManager), abi.encodeWithSignature("backstop()"));
        bytes memory reply = _reply(address(bridge), abi.encodeWithSignature("modules()"));
        assembly ("memory-safe") {
            mstore(add(reply, 64), 0)
        }
        _rejectReply(address(bridge), abi.encodeWithSignature("modules()"), reply);
        reply = _reply(address(defaultManager), abi.encodeWithSignature("modules()"));
        assembly ("memory-safe") {
            mstore(add(reply, 256), 0)
        }
        _rejectReply(address(defaultManager), abi.encodeWithSignature("modules()"), reply);
        _configure();
    }

    function test_configurationAndActivationArePermanentAndOrdered() public {
        vm.prank(admin);
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_WrongModules.selector);
        reserves.enableContinuousAccrual();
        _configure();
        vm.prank(admin);
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_AlreadyConfigured.selector);
        reserves.configureContinuousAccrual(_modules());
        vm.prank(admin);
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_WrongModules.selector);
        reserves.enableContinuousAccrual();
        _bindConsumers();
        _enable();
        vm.prank(admin);
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_AlreadyConfigured.selector);
        reserves.enableContinuousAccrual();
    }

    function test_activationRequiresEveryConsumerToPointBackAtThisReserve() public {
        _configure();
        _bindConsumers();
        address[7] memory consumers = _addresses();
        for (uint256 i; i < consumers.length; ++i) {
            vm.mockCall(consumers[i], abi.encodeWithSignature("accrualReserve()"), abi.encode(address(0)));
            vm.prank(admin);
            vm.expectRevert(ReserveAccrualLib.ReserveAccrual_WrongModules.selector);
            reserves.enableContinuousAccrual();
            assertFalse(reserves.accrualSnapshot().enabled, "partial activation");
            vm.clearMockedCalls();
        }
        _enable();
    }

    function test_activationRejectsInvalidFeeOrRecipientWithoutStartingTheBook() public {
        _configure();
        _bindConsumers();
        uint16 invalidFee = Config.MAX_PROTOCOL_FEE_BPS + 1;
        vm.mockCall(address(waterfall), abi.encodeWithSignature("protocolFeeBps()"), abi.encode(invalidFee));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ReserveAccrualLib.ReserveAccrual_InvalidFee.selector, invalidFee));
        reserves.enableContinuousAccrual();
        assertFalse(reserves.accrualSnapshot().enabled);
        vm.clearMockedCalls();
        vm.mockCall(address(waterfall), abi.encodeWithSignature("feeRecipient()"), abi.encode(address(0)));
        vm.prank(admin);
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_WrongModules.selector);
        reserves.enableContinuousAccrual();
        assertFalse(reserves.accrualSnapshot().enabled);
        vm.clearMockedCalls();
        _enable();
    }

    function test_existingDeployedFaceRequiresAnExplicitMigration() public {
        _postFirstLoss(anchorCurator, Config.CLASS_FILM_TAX_CREDITS, 10_000e18);
        _mintUSDfrTo(alice, 100_000e18);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 80_000e18);
        vault.deposit(80_000e18, alice);
        vm.stopPrank();
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 1000e18);
        _fundFacility(id, 1000e18);
        uint256 deployed = reserves.deployedPrincipal();
        uint256 exposure = registry.totalBookExposure();
        assertGt(deployed, 0, "fixture did not create a legacy receivable");
        _configure();
        _bindConsumers();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ReserveAccrualLib.ReserveAccrual_MigrationRequired.selector, deployed));
        reserves.enableContinuousAccrual();
        assertFalse(reserves.accrualSnapshot().enabled);
        assertEq(reserves.accrualSnapshot().gross, 0);
        assertEq(reserves.deployedPrincipal(), deployed, "activation refusal changed legacy face");
        assertEq(registry.totalBookExposure(), exposure, "activation refusal changed legacy exposure");
    }
}
