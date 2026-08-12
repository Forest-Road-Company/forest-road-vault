// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {AssessmentHandler} from "./handlers/AssessmentHandler.sol";

/// @notice Production-wrapper invariant coverage for assessment publication, expiry, clearing,
///         conservative fallback, and exact negative-path selector classification.
contract AssessmentInvariants is CreditLayerFixture {
    AssessmentHandler internal handler;

    function setUp() public override {
        super.setUp();

        uint256 principal = 1_000_000e18;
        uint256 tokenId = _liveFilmFacility(principal);
        vm.startPrank(alice);
        usdfr.approve(address(vault), principal);
        vault.deposit(principal, alice);
        vm.stopPrank();
        _attestDefault(tokenId);
        vm.prank(servicer);
        defaultManager.declareDefault(tokenId, FILM_REF);
        assertGt(defaultManager.pendingSeniorImpairment(), 0, "assessment fixture has no conservative impairment");

        handler = new AssessmentHandler(assessedImpairmentSource, defaultManager, admin);
        handler.seedShapes();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = AssessmentHandler.publish.selector;
        selectors[1] = AssessmentHandler.clear.selector;
        selectors[2] = AssessmentHandler.warp.selector;
        selectors[3] = AssessmentHandler.probeInvalid.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_assessmentUsesIndependentExpectedValue() public view {
        assertEq(
            assessedImpairmentSource.pendingSeniorImpairment(),
            handler.expectedPendingSeniorImpairment(),
            "assessed redemption impairment diverged from independent model"
        );
        assertEq(
            assessedImpairmentSource.performanceFeeImpairment(),
            handler.expectedPerformanceFeeImpairment(),
            "assessed performance-fee impairment diverged from independent model"
        );
        (,,, bool active,) = assessedImpairmentSource.currentAssessment();
        assertEq(active, handler.expectedActive(), "assessment active flag diverged from independent model");
    }

    function invariant_invalidAssessmentsFailWithExactSelectors() public view {
        assertEq(handler.unexpectedAcceptanceCount(), 0, "an invalid assessment was accepted");
        assertEq(handler.wrongSelectorCount(), 0, "an invalid assessment failed for the wrong reason");
    }

    function invariant_conservativeBaseRemainsTheFallback() public view {
        if (!handler.expectedActive()) {
            assertEq(
                assessedImpairmentSource.pendingSeniorImpairment(),
                defaultManager.pendingSeniorImpairment(),
                "inactive assessment did not fall back to the conservative base"
            );
        }
    }

    function afterInvariant() public view {
        assertGt(handler.publishCount(), 0, "VACUOUS: assessment was never published");
        assertGt(handler.expiryCount(), 0, "VACUOUS: assessment expiry was never reached");
        assertGt(handler.clearCount(), 0, "VACUOUS: assessment clear was never reached");
        assertGe(handler.negativeProbeCount(), 5, "VACUOUS: assessment rejection matrix was not reached");
        assertEq(
            handler.correctRejectionCount(),
            handler.negativeProbeCount(),
            "assessment rejection matrix contains an unclassified result"
        );
    }
}
