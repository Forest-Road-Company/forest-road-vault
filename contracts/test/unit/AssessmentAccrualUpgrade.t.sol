// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AssessedImpairmentSource} from "../../src/AssessedImpairmentSource.sol";
import {IRevisionedImpairmentSource} from "../../src/interfaces/IRevisionedImpairmentSource.sol";
import {PreviousAssessmentSource} from "../helpers/PreviousAssessmentSource.sol";
import {MutableImpairmentSource} from "./AssessedImpairmentSource.t.sol";

contract AssessmentAccrualUpgradeTest is Test {
    address private admin = makeAddr("assessment-upgrade-admin");
    MutableImpairmentSource private base;
    PreviousAssessmentSource private previous;
    AssessedImpairmentSource private implementation;

    function setUp() public {
        base = new MutableImpairmentSource();
        base.set(1_500e18);
        base.setCohortExposure(100e18);
        implementation = new AssessedImpairmentSource();
        previous = PreviousAssessmentSource(
            address(
                new ERC1967Proxy(
                    address(new PreviousAssessmentSource()),
                    abi.encodeCall(PreviousAssessmentSource.initialize, (admin, admin, address(base)))
                )
            )
        );
        vm.prank(admin);
        previous.setAssessment(500e18, uint64(block.timestamp + 7 days), keccak256("previous-memorandum"));
    }

    function test_previousWrapperRetainsConservativeFallbackWithTheNewBaseInterface() public {
        base.growPastDue(10e18);
        assertEq(previous.pendingSeniorImpairment(), 1_510e18, "legacy hash compatibility released overdue income");
        assertEq(previous.performanceFeeImpairment(), 1_510e18);
        (,,, bool active,) = previous.currentAssessment();
        assertFalse(active);
    }

    function test_actualPreviousImplementationUpgradeRequiresRepublicationBeforeUsingAccrual() public {
        vm.prank(admin);
        previous.upgradeToAndCall(address(implementation), "");
        AssessedImpairmentSource upgraded = AssessedImpairmentSource(address(previous));
        (bytes32 saved, bytes32 live, bool matches) = upgraded.assessmentState();
        assertEq(saved, live, "upgrade must be checked even when the old exact state matches");
        assertFalse(matches, "an old assessment lacks the new exposure snapshot");
        assertEq(upgraded.pendingSeniorImpairment(), 1_500e18);
        assertEq(upgraded.performanceFeeImpairment(), 1_500e18);
        vm.prank(admin);
        upgraded.setAssessment(500e18, uint64(block.timestamp + 7 days), keccak256("refreshed-memorandum"));
        base.growPastDue(10e18);
        assertEq(upgraded.pendingSeniorImpairment(), 510e18);
        assertEq(upgraded.performanceFeeImpairment(), 510e18);
    }

    function test_outOfOrderUpgradeFallsBackAndCannotPublishUntilTheBaseSupportsAccrualState() public {
        vm.mockCallRevert(
            address(base), abi.encodeCall(IRevisionedImpairmentSource.impairmentAssessmentState, ()), hex"12345678"
        );
        // The previous implementation authorizes this upgrade using its original interface.
        vm.prank(admin);
        previous.upgradeToAndCall(address(implementation), "");
        AssessedImpairmentSource upgraded = AssessedImpairmentSource(address(previous));
        assertEq(upgraded.pendingSeniorImpairment(), 1_500e18);
        assertEq(upgraded.performanceFeeImpairment(), 1_500e18);
        vm.expectRevert(
            abi.encodeWithSelector(AssessedImpairmentSource.Assessment_BaseNotRevisioned.selector, address(base))
        );
        vm.prank(admin);
        upgraded.setAssessment(500e18, uint64(block.timestamp + 7 days), keccak256("too-early-memorandum"));
        vm.clearMockedCalls();
        vm.prank(admin);
        upgraded.setAssessment(500e18, uint64(block.timestamp + 7 days), keccak256("ready-memorandum"));
        base.growPastDue(10e18);
        assertEq(upgraded.pendingSeniorImpairment(), 510e18);
    }
}
