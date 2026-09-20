// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DefaultManager} from "../../src/DefaultManager.sol";
import {CommitmentLedger} from "../../src/CommitmentLedger.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {Config} from "../../src/libraries/Config.sol";
import {CommitmentLedgerReference} from "../helpers/CommitmentLedgerReference.sol";
import {NativeAccrualFixture} from "../helpers/NativeAccrualFixture.sol";

contract LedgerReplacementSource {
    error LedgerReplacementSource_Busy();
    bool public blocked;

    function setBlocked(bool value) external { blocked = value; }
    function accrualSnapshot() external pure returns (IContinuousAccrual.Snapshot memory s) {
        s.enabled = true;
        s.fresh = true;
    }
    function requireAccrualIdle() external view {
        if (blocked) revert LedgerReplacementSource_Busy();
    }
    function poolBalance(uint256) external pure returns (uint256) { return 0; }
    function conservativeSeniorMark(uint256, uint256 residual, address, uint256) external pure returns (uint256) {
        return residual;
    }
}

/// @dev Real UUPS manager and factory. The old ledger uses the unchanged reference implementation.
contract CommitmentLedgerReplacementTest is Test {
    using stdStorage for StdStorage;

    bytes32 private constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    address private admin;
    DefaultManager private implementation;
    DefaultManager private manager;
    LedgerReplacementSource private source;
    address private originalLedger;
    address private factory;

    function setUp() public {
        admin = makeAddr("ledgerReplacementAdmin");
        source = new LedgerReplacementSource();
        implementation = new DefaultManager();
        DefaultManager.InitModules memory modules = DefaultManager.InitModules({
            bridge: address(source), registry: address(source), reserves: address(source),
            controller: address(source), curator: address(source), oracle: address(source),
            usdfr: address(source), vault: address(source)
        });
        manager = DefaultManager(address(new ERC1967Proxy(address(implementation),
            abi.encodeCall(DefaultManager.initialize, (admin, admin, admin, modules)))));
        factory = vm.computeCreateAddress(address(implementation), 2);
        assertGt(factory.code.length, 0);
        assertEq(_ledger(), vm.computeCreateAddress(factory, 1), "constructor factory prediction is wrong");
        originalLedger = address(new CommitmentLedgerReference(address(manager)));
        stdstore.target(address(manager)).sig("modules()").depth(7).checked_write(originalLedger);
        assertEq(_ledger(), originalLedger, "legacy pointer was not installed");
    }

    function _ledger() private view returns (address ledger) {
        (,,,,,,, ledger) = manager.modules();
    }

    function _replace() private {
        vm.prank(admin);
        manager.replaceCommitmentLedger();
    }

    function _assertUnchanged(uint64 nonce) private view {
        assertEq(_ledger(), originalLedger, "refusal changed the ledger pointer");
        assertEq(vm.getNonce(factory), nonce, "refusal created a child");
        assertEq(CommitmentLedgerReference(originalLedger).eventCount(), 0);
    }

    function test_replacementEmitsBothAddressesAndReadsResolveToTheNewLedger() public {
        uint64 nonce = vm.getNonce(factory);
        address expected = vm.computeCreateAddress(factory, nonce);
        vm.expectEmit(true, true, false, true, address(manager));
        emit IDefaultManager.CommitmentLedgerReplaced(originalLedger, expected);
        _replace();
        assertEq(_ledger(), expected);
        assertEq(CommitmentLedger(expected).manager(), address(manager));
        assertEq(CommitmentLedger(expected).eventCount(), 0);
        assertEq(CommitmentLedger(expected).remainingPrincipalForClass(1), 0);
        assertEq(vm.getNonce(factory), nonce + 1);
        assertEq(manager.impairmentMath().pendingSeniorImpairment(address(manager)), 0);
        vm.prank(address(manager));
        CommitmentLedger(expected).register(77, 1, 123);
        stdstore.target(address(manager)).sig("declaredDefaultedPrincipal(uint256)").with_key(1).checked_write(123);
        assertEq(manager.impairmentMath().pendingSeniorImpairment(address(manager)), 123,
            "calculator reads through DefaultManager still use the old ledger");
        assertEq(manager.pendingSeniorImpairment(), 123);
        assertEq(CommitmentLedgerReference(originalLedger).eventCount(), 0);
        assertEq(CommitmentLedgerReference(originalLedger).remainingAggregate(), 0);
    }

    function testFuzz_replacementRefusesConsumedCoverage(uint256 raw) public {
        uint256 amount = bound(raw, 1, type(uint224).max);
        stdstore.target(address(manager)).sig("liveDefaultCoverageConsumed()").checked_write(amount);
        assertEq(manager.liveDefaultCoverageConsumed(), amount, "consumed coverage seed did not apply");
        uint64 nonce = vm.getNonce(factory);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_CommitmentLedgerMigrationUnsafe.selector, amount));
        _replace();
        _assertUnchanged(nonce);
        assertEq(manager.liveDefaultCoverageConsumed(), amount);
    }

    function testFuzz_replacementRefusesPrincipalInEveryClass(uint8 classSeed, uint256 raw) public {
        uint256 classId = 1 + uint256(classSeed) % Config.NUM_CLASSES;
        uint256 amount = bound(raw, 1, type(uint224).max);
        stdstore.target(address(manager)).sig("declaredDefaultedPrincipal(uint256)").with_key(classId).checked_write(amount);
        assertEq(manager.declaredDefaultedPrincipal(classId), amount, "class principal seed did not apply");
        uint64 nonce = vm.getNonce(factory);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_CommitmentLedgerMigrationUnsafe.selector, amount));
        _replace();
        _assertUnchanged(nonce);
        assertEq(manager.declaredDefaultedPrincipal(classId), amount);
    }

    function testFuzz_replacementRefusesAnUnauthorizedCaller(address caller) public {
        if (caller == admin) caller = address(0);
        uint64 nonce = vm.getNonce(factory);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, bytes32(0)));
        manager.replaceCommitmentLedger();
        _assertUnchanged(nonce);
    }

    function test_replacementWaitsForNativeAccrualToBeIdle() public {
        stdstore.target(address(manager)).sig("accrualReserve()").checked_write(address(source));
        assertEq(manager.accrualReserve(), address(source), "native source seed did not apply");
        source.setBlocked(true);
        uint64 nonce = vm.getNonce(factory);
        vm.expectRevert(LedgerReplacementSource.LedgerReplacementSource_Busy.selector);
        _replace();
        _assertUnchanged(nonce);
        source.setBlocked(false);
        _replace();
        assertNotEq(_ledger(), originalLedger);
    }

    function test_firstInstallationStillRefusesAnAlreadyInstalledLedger() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_CommitmentLedgerAlreadySet.selector, originalLedger));
        manager.initializeCommitmentLedger();
        stdstore.target(address(manager)).sig("modules()").depth(7).checked_write(address(0));
        assertEq(_ledger(), address(0));
        address expected = vm.computeCreateAddress(factory, vm.getNonce(factory));
        vm.expectEmit(true, false, false, true, address(manager));
        emit IDefaultManager.CommitmentLedgerSet(expected);
        vm.prank(admin);
        manager.initializeCommitmentLedger();
        assertEq(_ledger(), expected);
        assertEq(CommitmentLedger(expected).manager(), address(manager));
    }

    function test_atomicUpgradeUsesTheNewImplementationFactory() public {
        DefaultManager next = new DefaultManager();
        address nextFactory = vm.computeCreateAddress(address(next), 2);
        uint64 nonce = vm.getNonce(nextFactory);
        uint64 priorFactoryNonce = vm.getNonce(factory);
        address expected = vm.computeCreateAddress(nextFactory, nonce);
        assertGt(nextFactory.code.length, 0);
        vm.expectEmit(true, true, false, true, address(manager));
        emit IDefaultManager.CommitmentLedgerReplaced(originalLedger, expected);
        vm.prank(admin);
        manager.upgradeToAndCall(address(next), abi.encodeCall(IDefaultManager.replaceCommitmentLedger, ()));
        assertEq(address(uint160(uint256(vm.load(address(manager), IMPLEMENTATION_SLOT)))), address(next));
        assertEq(_ledger(), expected);
        assertEq(CommitmentLedger(expected).manager(), address(manager));
        assertEq(CommitmentLedger(expected).remainingPrincipalForClass(Config.NUM_CLASSES), 0);
        assertEq(vm.getNonce(nextFactory), nonce + 1);
        assertEq(vm.getNonce(factory), priorFactoryNonce, "replacement used the old implementation factory");
    }

    function test_failedAtomicReplacementRollsBackTheImplementationChange() public {
        DefaultManager next = new DefaultManager();
        address nextFactory = vm.computeCreateAddress(address(next), 2);
        uint64 nextNonce = vm.getNonce(nextFactory);
        stdstore.target(address(manager)).sig("declaredDefaultedPrincipal(uint256)").with_key(Config.NUM_CLASSES).checked_write(42);
        assertEq(manager.declaredDefaultedPrincipal(Config.NUM_CLASSES), 42);
        uint64 nonce = vm.getNonce(factory);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_CommitmentLedgerMigrationUnsafe.selector, 42));
        manager.upgradeToAndCall(address(next), abi.encodeCall(IDefaultManager.replaceCommitmentLedger, ()));
        assertEq(address(uint160(uint256(vm.load(address(manager), IMPLEMENTATION_SLOT)))), address(implementation));
        _assertUnchanged(nonce);
        assertEq(vm.getNonce(nextFactory), nextNonce);
    }

    function test_missingFactoryCodeCannotRepointTheLedger() public {
        vm.etch(factory, bytes(""));
        assertEq(factory.code.length, 0, "factory code removal did not apply");
        uint64 nonce = vm.getNonce(factory);
        vm.expectRevert();
        _replace();
        _assertUnchanged(nonce);
    }
}


/// @dev Real signed credit lifecycle with accrual enabled before the empty default ledger is replaced.
abstract contract NativeLedgerReplacementChecks is NativeAccrualFixture {
    function _ledgerAddress() private view returns (address ledger) {
        (,,,,,,, ledger) = defaultManager.modules();
    }

    function _nativeAccounting() private view returns (bytes32) {
        return keccak256(abi.encode(reserves.accrualSnapshot(), reserves.accruedDebt(nativeId),
            controller.totalUSDfr(), reserves.deployedTo(nativeId), registry.totalBookExposure(),
            vault.totalAssets(), vault.totalSupply(), vault.currentExchangeRate()));
    }

    function test_nativeDeclarationPartialLossAndClosureUseTheReplacementLedger() public {
        _nativeFund(50_000e18);
        _nativeAdvance(nativeStart + 90 days);
        address previous = _ledgerAddress();
        assertEq(CommitmentLedger(previous).eventCount(), 0);
        bytes32 before_ = _nativeAccounting();
        vm.prank(admin);
        defaultManager.replaceCommitmentLedger();
        address ledger = _ledgerAddress();
        assertNotEq(ledger, previous);
        assertEq(_nativeAccounting(), before_, "ledger replacement changed live accrual economics");
        _nativeDeclare();
        uint256 principal = reserves.deployedTo(nativeId);
        assertEq(CommitmentLedger(ledger).eventCount(), 1);
        assertEq(CommitmentLedger(ledger).remainingPrincipalForClass(Config.CLASS_FILM_TAX_CREDITS), principal);
        assertEq(CommitmentLedger(previous).eventCount(), 0, "declaration used the discarded ledger");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_CommitmentLedgerMigrationUnsafe.selector, principal));
        defaultManager.replaceCommitmentLedger();
        assertEq(_ledgerAddress(), ledger);
        _nativeLoss(1000e18);
        assertEq(CommitmentLedger(ledger).remainingPrincipalForClass(Config.CLASS_FILM_TAX_CREDITS), principal - 1000e18);
        _nativeLoss(nativeReference.principal + nativeReference.interest);
        assertEq(CommitmentLedger(ledger).eventCount(), 0);
        assertEq(CommitmentLedger(ledger).remainingPrincipalForClass(Config.CLASS_FILM_TAX_CREDITS), 0);
        assertEq(defaultManager.liveDefaultCoverageConsumed(), 0);
        assertEq(defaultManager.declaredDefaultedPrincipal(Config.CLASS_FILM_TAX_CREDITS), 0);
        before_ = _nativeAccounting();
        vm.prank(admin);
        defaultManager.replaceCommitmentLedger();
        assertNotEq(_ledgerAddress(), ledger);
        assertEq(_nativeAccounting(), before_, "empty-book replacement changed settled accrual economics");
        _assertNativeBacking();
    }
}

contract NativeCashLedgerReplacementTest is NativeLedgerReplacementChecks {}

contract NativePikLedgerReplacementTest is NativeLedgerReplacementChecks {
    function _pikFacilities() internal pure override returns (bool) { return true; }
}
