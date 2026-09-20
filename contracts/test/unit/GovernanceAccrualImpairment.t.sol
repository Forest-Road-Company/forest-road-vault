// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {NativeAccrualFixture} from "../helpers/NativeAccrualFixture.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {AccrualBook} from "../../src/libraries/AccrualBook.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice A valuation mark includes already earned income without issuing or re-earning it.
abstract contract GovernanceAccrualImpairmentChecks is NativeAccrualFixture {
    bytes32 private constant EVIDENCE = keccak256("current receivable valuation");

    function _earn(uint32 elapsed) private {
        _nativeFund(50_000e18);
        vm.warp(nativeStart + uint64(bound(elapsed, 1 days, 80 days)));
        (, bool fresh) = reserves.checkpointAccrual(32);
        assertTrue(fresh);
        assertGt(reserves.accrualSnapshot().unposted, 0, "fixture must include unposted income");
    }

    function _financialDigest() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                reserves.accrualSnapshot(),
                reserves.deployedTo(nativeId),
                reserves.totalPrincipalImpairment(),
                controller.totalUSDfr(),
                controller.backingValue(),
                usdfr.totalSupply(),
                registry.totalBookExposure(),
                defaultManager.impairmentRiskStateHash(),
                bridge.facility(nativeId).nextPaymentDue
            )
        );
    }

    function testFuzz_fullFaceCanBeMarkedInTwoParts(uint32 elapsed, uint16 fraction) public {
        _earn(elapsed);
        uint256 face = reserves.deployedTo(nativeId);
        uint256 backing = controller.backingValue();
        uint256 supply = controller.totalUSDfr();
        uint256 physicalSupply = usdfr.totalSupply();
        uint256 exposure = registry.totalBookExposure();
        uint64 due = bridge.facility(nativeId).nextPaymentDue;
        IContinuousAccrual.Snapshot memory before_ = reserves.accrualSnapshot();
        uint256 first = face * bound(fraction, 1, 9999) / 10_000;
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(nativeId, first, EVIDENCE);
        assertEq(reserves.accrualSnapshot().unposted, 0, "mark must first post earned income");
        assertEq(controller.backingValue(), backing - first);
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(nativeId, face - first, EVIDENCE);
        assertEq(reserves.principalImpairmentOf(nativeId), face, "full face includes unreceived interest");
        assertEq(controller.backingValue(), backing - face);
        assertEq(controller.totalUSDfr(), supply, "valuation alone cannot issue or burn claims");
        assertEq(usdfr.totalSupply(), physicalSupply, "posting cannot mint physical fees or yield");
        assertEq(registry.totalBookExposure(), exposure, "posting must preserve effective exposure");
        assertEq(bridge.facility(nativeId).nextPaymentDue, due, "valuation cannot advance the note schedule");
        IContinuousAccrual.Snapshot memory after_ = reserves.accrualSnapshot();
        assertEq(after_.gross, before_.gross);
        assertEq(after_.seniorUnissued, before_.seniorUnissued);
        assertEq(after_.feeUnissued, before_.feeUnissued);
        assertEq(reserves.postAccruedLoan(nativeId), 0, "income posted twice");
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_ImpairmentExceedsFace.selector, nativeId, 1, 0)
        );
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(nativeId, 1, EVIDENCE);
    }

    function test_failedMarkRollsBackPostingAndKeepsItsAuthority() public {
        _earn(30 days);
        bytes32 before_ = _financialDigest();
        uint256 face = reserves.deployedTo(nativeId);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReserveManager.ReserveManager_ImpairmentExceedsFace.selector, nativeId, face + 1, face
            )
        );
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(nativeId, face + 1, EVIDENCE);
        assertEq(_financialDigest(), before_);
        vm.expectRevert(IReserveManager.ReserveManager_ZeroEvidenceHash.selector);
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(nativeId, face, bytes32(0));
        assertEq(_financialDigest(), before_);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        vm.prank(alice);
        reserves.recognizePrincipalImpairment(nativeId, face, EVIDENCE);
        assertEq(_financialDigest(), before_);
    }

    function test_staleBookRequiresMaintenanceBeforeMark() public {
        _nativeFund(50_000e18);
        vm.warp(nativeStart + (_pikFacilities() ? 91 days : 366 days));
        assertFalse(reserves.accrualSnapshot().fresh);
        bytes32 before_ = _financialDigest();
        vm.expectPartialRevert(AccrualBook.AccrualBook_BoundaryPending.selector);
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(nativeId, 1e18, EVIDENCE);
        assertEq(_financialDigest(), before_);
        (, bool fresh) = reserves.checkpointAccrual(32);
        assertTrue(fresh);
        uint256 face = reserves.deployedTo(nativeId);
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(nativeId, face, EVIDENCE);
        assertEq(reserves.principalImpairmentOf(nativeId), face);
    }

    function test_markDoesNotRestartStoppedEarnings() public {
        _nativeFund(50_000e18);
        _nativeAdvance(nativeStart + 30 days);
        _nativeDeclare();
        uint256 face = reserves.deployedTo(nativeId);
        uint256 gross = reserves.accrualSnapshot().gross;
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(nativeId, face, EVIDENCE);
        vm.warp(nativeStart + 60 days);
        assertEq(reserves.deployedTo(nativeId), face);
        assertEq(reserves.accrualSnapshot().gross, gross);
        assertEq(reserves.postAccruedLoan(nativeId), 0);
    }
}

contract GovernanceCashImpairmentTest is GovernanceAccrualImpairmentChecks {}

contract GovernancePikImpairmentTest is GovernanceAccrualImpairmentChecks {
    function _pikFacilities() internal pure override returns (bool) {
        return true;
    }
}
