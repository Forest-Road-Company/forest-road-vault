// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AssessedImpairmentSource} from "../../src/AssessedImpairmentSource.sol";
import {IRevisionedImpairmentSource} from "../../src/interfaces/IRevisionedImpairmentSource.sol";
import {MutableImpairmentSource} from "./AssessedImpairmentSource.t.sol";

contract AssessmentAccrualTest is Test {
    bytes32 private constant ROOT = 0x22d1327051d3790a2a295641453e9e7c93d6a209be7b99c1b2a8eee179860200;
    address private admin = makeAddr("assessment-admin");
    AssessedImpairmentSource private implementation;
    MutableImpairmentSource private base;
    AssessedImpairmentSource private source;

    function setUp() public {
        implementation = new AssessedImpairmentSource();
        base = new MutableImpairmentSource();
        base.set(1_500e18);
        source = _deploy(address(base));
    }

    function _deploy(address target) private returns (AssessedImpairmentSource) {
        return AssessedImpairmentSource(
            address(
                new ERC1967Proxy(
                    address(implementation), abi.encodeCall(AssessedImpairmentSource.initialize, (admin, admin, target))
                )
            )
        );
    }

    function _publish(uint256 amount) private {
        vm.prank(admin);
        source.setAssessment(amount, uint64(block.timestamp + 7 days), keccak256("accruing-risk-memorandum"));
    }

    function test_growthAdjustsBothMarksWithoutChangingThePublishedAmount() public {
        base.setCohortExposure(400e18);
        base.setFeeImpairment(1_700e18);
        _publish(500e18);
        base.growPastDue(30e18);
        assertEq(source.pendingSeniorImpairment(), 530e18);
        assertEq(source.performanceFeeImpairment(), 730e18);
        (uint256 published,,, bool active,) = source.currentAssessment();
        assertEq(published, 500e18, "publication record changed with time");
        assertTrue(active);
        (bytes32 original, bytes32 current, bool matches) = source.assessmentState();
        assertNotEq(original, current, "exact state still includes the moving cohort");
        assertTrue(matches, "elapsed income is compatible when fully reserved");
    }

    function test_backstopTopupCannotOffsetAccrualOrCreateFeePerformance() public {
        base.setCohortExposure(600e18);
        base.setBackstop(100e18, 1_400e18);
        _publish(500e18);
        base.growPastDue(100e18);
        base.setBackstop(600e18, 1_000e18);
        assertEq(source.pendingSeniorImpairment(), 600e18);
        assertEq(source.performanceFeeImpairment(), 700e18, "capital contribution changed the fixed junior credit");
        base.setBackstop(2_000e18, 20e18);
        assertEq(source.pendingSeniorImpairment(), 20e18, "live conservative ceiling was exceeded");
        assertEq(source.performanceFeeImpairment(), 700e18, "redemption protection became fee profit");
        base.setBackstop(3_000e18, 0);
        assertEq(source.pendingSeniorImpairment(), 0);
        assertEq(source.performanceFeeImpairment(), 700e18);
    }

    function test_lowerExposureWithUnchangedIdentityFailsConservatively() public {
        base.setCohortExposure(100e18);
        _publish(500e18);
        base.setCohortExposure(100e18 - 1);
        _assertInactive();
    }

    function test_lowerCapacityWithUnchangedIdentityFailsConservatively() public {
        base.setBackstop(100e18, 1_400e18);
        _publish(500e18);
        base.setBackstop(100e18 - 1, 1_400e18 + 1);
        _assertInactive();
    }

    function test_sameAmountsWithNewRiskIdentityCannotReuseTheAssessment() public {
        _publish(500e18);
        base.touch();
        _assertInactive();
    }

    function _assertInactive() private view {
        (,,, bool active,) = source.currentAssessment();
        assertFalse(active);
        assertEq(source.pendingSeniorImpairment(), base.pendingSeniorImpairment());
        assertEq(source.performanceFeeImpairment(), base.performanceFeeImpairment());
        (,, bool matches) = source.assessmentState();
        assertFalse(matches);
    }

    function test_missingAccrualSnapshotFailsClosedEvenAtTheExactOriginalState() public {
        _publish(500e18);
        (bytes32 original, bytes32 current,) = source.assessmentState();
        assertEq(original, current);
        vm.store(address(source), bytes32(uint256(ROOT) + 11), bytes32(0));
        _assertInactive();
        _publish(400e18);
        base.growPastDue(1);
        assertEq(source.pendingSeniorImpairment(), 400e18 + 1);
    }

    function test_clearAndBaseReplacementEraseTheAccrualSnapshot() public {
        base.setCohortExposure(100e18);
        _publish(500e18);
        vm.prank(admin);
        source.clearAssessment();
        _assertTailCleared();
        _publish(400e18);
        MutableImpairmentSource replacement = new MutableImpairmentSource();
        replacement.set(700e18);
        vm.prank(admin);
        source.setBaseSource(address(replacement));
        _assertTailCleared();
        assertEq(source.pendingSeniorImpairment(), 700e18);
    }

    function _assertTailCleared() private view {
        for (uint256 offset = 9; offset <= 11; ++offset) {
            assertEq(vm.load(address(source), bytes32(uint256(ROOT) + offset)), bytes32(0));
        }
    }

    function test_newStateReadRejectsEveryMalformedTupleAndARevertingSource() public {
        _publish(500e18);
        bytes memory selector = abi.encodeCall(IRevisionedImpairmentSource.impairmentAssessmentState, ());
        bytes memory expected =
            abi.encodeWithSelector(AssessedImpairmentSource.Assessment_BaseNotRevisioned.selector, address(base));
        uint256[4] memory lengths = [uint256(0), 32, 64, 128];
        for (uint256 i; i < lengths.length; ++i) {
            vm.mockCall(address(base), selector, new bytes(lengths[i]));
            vm.expectRevert(expected);
            source.pendingSeniorImpairment();
            vm.expectRevert(expected);
            source.performanceFeeImpairment();
            vm.expectRevert(expected);
            _deploy(address(base));
            vm.clearMockedCalls();
        }
        vm.mockCallRevert(address(base), selector, hex"12345678");
        vm.expectRevert(expected);
        source.pendingSeniorImpairment();
        vm.expectRevert(expected);
        _deploy(address(base));
        vm.clearMockedCalls();
        assertEq(source.pendingSeniorImpairment(), 500e18);
    }

    function test_growthAtTheUint256BoundaryPreservesTheConservativeCeiling() public {
        base.set(type(uint256).max - 1);
        base.setCohortExposure(1);
        _publish(type(uint256).max - 1);
        base.growPastDue(1);
        assertEq(source.pendingSeniorImpairment(), type(uint256).max);
        assertEq(source.performanceFeeImpairment(), type(uint256).max);
    }

    function testFuzz_growthAndBeneficialCapacityChangesMatchIndependentArithmetic(
        uint96 rawPrincipal,
        uint96 rawAssessment,
        uint96 rawGrowth,
        uint96 rawCeiling
    ) public {
        uint256 principal = bound(rawPrincipal, 2, type(uint96).max);
        uint256 conservative = principal / 2;
        uint256 assessed = bound(rawAssessment, 0, conservative);
        uint256 growth = uint256(rawGrowth);
        base.set(conservative);
        base.setFeeImpairment(principal);
        base.setCohortExposure(principal / 3);
        _publish(assessed);
        base.growPastDue(growth);
        uint256 ceiling = bound(rawCeiling, 0, conservative + growth);
        base.setBackstop(1, ceiling);
        uint256 adjusted = assessed + growth;
        assertEq(source.pendingSeniorImpairment(), adjusted < ceiling ? adjusted : ceiling);
        assertEq(source.performanceFeeImpairment(), assessed + principal - conservative + growth);
        (,,, bool active,) = source.currentAssessment();
        assertTrue(active);
    }

    function test_revisionMetadataMustRemainCompleteWhenTheAccrualTupleIsPresent() public {
        bytes4[6] memory selectors = [
            bytes4(keccak256("pendingSeniorImpairment()")),
            bytes4(keccak256("performanceFeeImpairment()")),
            bytes4(keccak256("impairmentRevision()")),
            bytes4(keccak256("impairmentStateHash()")),
            bytes4(keccak256("impairmentRiskStateHash()")),
            bytes4(keccak256("impairmentBackstopCapacity()"))
        ];
        bytes memory expected = abi.encodeWithSelector(
            AssessedImpairmentSource.Assessment_BaseNotRevisioned.selector, address(base)
        );
        for (uint256 i; i < selectors.length; ++i) {
            vm.mockCall(address(base), abi.encodeWithSelector(selectors[i]), new bytes(64));
            vm.expectRevert(expected);
            _deploy(address(base));
            vm.clearMockedCalls();
            vm.mockCallRevert(address(base), abi.encodeWithSelector(selectors[i]), hex"12345678");
            vm.expectRevert(expected);
            _deploy(address(base));
            vm.clearMockedCalls();
        }
    }
}
