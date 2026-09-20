// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NativeAccrualFixture} from "../helpers/NativeAccrualFixture.sol";
import {AccrualDebtReference} from "../helpers/AccrualDebtReference.sol";

/// @notice Real native accounting with a cash note whose overdue interest continues to earn.
contract AccruingRecoveryAssessmentTest is NativeAccrualFixture {
    using AccrualDebtReference for AccrualDebtReference.Note;

    function _markedAssessment(uint256 assessed) internal {
        _nativeFund(400_000e18);
        _nativeAdvance(nativeStart + 120 days);
        defaultManager.markPastDue(nativeId);
        assertGt(defaultManager.pendingSeniorImpairment(), assessed, "fixture must have recoverable senior risk");
        vm.prank(admin);
        assessedImpairmentSource.setAssessment(
            assessed, uint64(block.timestamp + 7 days), keccak256("accruing-cohort-recovery-memorandum")
        );
    }

    function test_elapsedSecondPreservesAssessmentAndChargesNewDelinquentInterest() public {
        _markedAssessment(0);
        uint256 shares = vault.balanceOf(alice);
        uint256 quoteBefore = vault.previewRedeem(shares);
        uint256 exposureBefore = defaultManager.pastDueExposure();
        uint256 feeMarkBefore = assessedImpairmentSource.performanceFeeImpairment();
        uint256 cashBefore = IERC20(_nativeAsset()).balanceOf(address(reserves));
        uint256 revisionBefore = defaultManager.impairmentRevision();
        bytes32 fullHashBefore = defaultManager.impairmentStateHash();
        // The note model rounds posted debt to the asset grid. This read observes the
        // unposted cohort, so compare its rational one-second amount within one grid unit.
        uint256 referenceEarned = nativeReference.principal * nativeReference.rate / (10_000 * nativeReference.year);

        vm.warp(block.timestamp + 1);

        uint256 quoteAfter = vault.previewRedeem(shares);
        uint256 earned = defaultManager.pastDueExposure() - exposureBefore;
        assertGt(earned, 0, "fixture must cross an interest unit");
        emit log_named_uint("exit quote before elapsed second", quoteBefore);
        emit log_named_uint("exit quote after elapsed second", quoteAfter);
        emit log_named_uint(
            "quote decline in basis points",
            quoteBefore > quoteAfter ? (quoteBefore - quoteAfter) * 10_000 / quoteBefore : 0
        );
        emit log_named_uint("independent rational interest increment", referenceEarned);
        emit log_named_uint("observed cohort increment", earned);
        assertEq(IERC20(_nativeAsset()).balanceOf(address(reserves)), cashBefore, "time moved reserve cash");
        assertEq(defaultManager.impairmentRevision(), revisionBefore, "time changed risk identity");
        assertNotEq(defaultManager.impairmentStateHash(), fullHashBefore, "exact hash must retain growing exposure");
        assertApproxEqAbs(earned, referenceEarned, _nativeScale() + 1, "independent note/cohort mismatch");
        (,,, bool active,) = assessedImpairmentSource.currentAssessment();
        assertTrue(active, "elapsed interest invalidated an otherwise current recovery assessment");
        assertEq(
            assessedImpairmentSource.pendingSeniorImpairment(),
            earned,
            "new delinquent interest escaped the exit reserve"
        );
        assertEq(
            assessedImpairmentSource.performanceFeeImpairment(),
            feeMarkBefore + earned,
            "new delinquent interest escaped the fee reserve"
        );
        assertLe(quoteAfter, quoteBefore, "delinquent-only yield raised the exit price");
        assertLe(quoteBefore - quoteAfter, earned, "a clock tick reinstated the whole conservative loss");
    }

    function test_neutralPostingPreservesTheCohortAndBothAdjustedMarks() public {
        _markedAssessment(100_000e18);
        vm.warp(block.timestamp + 37 minutes);
        uint256 netBefore = assessedImpairmentSource.pendingSeniorImpairment();
        uint256 feeBefore = assessedImpairmentSource.performanceFeeImpairment();
        (bytes32 identityBefore, uint256 exposureBefore,) = defaultManager.impairmentAssessmentState();
        reserves.postAccruedLoan(nativeId);
        (bytes32 identityAfter, uint256 exposureAfter,) = defaultManager.impairmentAssessmentState();
        assertEq(identityAfter, identityBefore, "neutral posting changed assessed risk identity");
        assertEq(exposureAfter, exposureBefore, "posting changed gross overdue face");
        assertEq(assessedImpairmentSource.pendingSeniorImpairment(), netBefore);
        assertEq(assessedImpairmentSource.performanceFeeImpairment(), feeBefore);
        (,,, bool active,) = assessedImpairmentSource.currentAssessment();
        assertTrue(active);
    }

    function test_cureThenRemarkAtTheSameFaceCannotReviveAnOldAssessment() public {
        _markedAssessment(100_000e18);
        (bytes32 identityBefore, uint256 exposureBefore, uint256 capacityBefore) =
            defaultManager.impairmentAssessmentState();
        uint256 revisionBefore = defaultManager.impairmentRevision();
        _clearPastDue(nativeId, keccak256("same-face-cure"));
        defaultManager.markPastDue(nativeId);
        (bytes32 identityAfter, uint256 exposureAfter, uint256 capacityAfter) =
            defaultManager.impairmentAssessmentState();
        assertEq(exposureAfter, exposureBefore, "fixture must restore identical gross exposure");
        assertEq(capacityAfter, capacityBefore);
        assertGt(defaultManager.impairmentRevision(), revisionBefore);
        assertNotEq(identityAfter, identityBefore, "different risk episodes reused the identity");
        _assertAssessmentInactive();
    }

    function test_unrelatedClassCapitalChangeStillInvalidatesTheAssessment() public {
        _markedAssessment(100_000e18);
        uint256 revisionBefore = defaultManager.impairmentRevision();
        _postFirstLoss(anchorCurator, 2, 1_000e18);
        assertEq(defaultManager.impairmentRevision(), revisionBefore, "class pool input must be independently checked");
        _assertAssessmentInactive();
    }

    function test_defaultInvalidatesAndStopsTheCohortBeforeRepublication() public {
        _markedAssessment(100_000e18);
        _nativeDeclare();
        _assertAssessmentInactive();
        assertEq(defaultManager.pastDueExposure(), 0, "declared default remained in earning cohort");
        vm.prank(admin);
        assessedImpairmentSource.setAssessment(
            100_000e18, uint64(block.timestamp + 7 days), keccak256("declared-recovery")
        );
        uint256 netBefore = assessedImpairmentSource.pendingSeniorImpairment();
        uint256 feeBefore = assessedImpairmentSource.performanceFeeImpairment();
        vm.warp(block.timestamp + 1 days);
        assertEq(assessedImpairmentSource.pendingSeniorImpairment(), netBefore);
        assertEq(assessedImpairmentSource.performanceFeeImpairment(), feeBefore);
        (,,, bool active,) = assessedImpairmentSource.currentAssessment();
        assertTrue(active);
    }

    function _assertAssessmentInactive() private view {
        (,,, bool active,) = assessedImpairmentSource.currentAssessment();
        assertFalse(active);
        assertEq(assessedImpairmentSource.pendingSeniorImpairment(), defaultManager.pendingSeniorImpairment());
        assertEq(assessedImpairmentSource.performanceFeeImpairment(), defaultManager.performanceFeeImpairment());
    }

    /// @notice Sixty-four differently spaced readings and postings are checked against the
    ///         note's frozen-principal rational interest, independently of the cohort index.
    struct History {
        uint256 openingExposure;
        uint256 openingTime;
        uint256 publishedExposure;
        uint256 publishedNet;
        uint256 publishedFee;
        uint256 postings;
        uint256 publications;
    }

    function testFuzz_randomPostingAndRepublicationPreserveTheGrossInterestReserve(uint256 seed) public {
        _markedAssessment(0);
        History memory h;
        h.openingExposure = defaultManager.pastDueExposure();
        h.openingTime = block.timestamp;
        h.publishedExposure = h.openingExposure;
        h.publishedNet = 0;
        h.publishedFee = assessedImpairmentSource.performanceFeeImpairment();
        h.postings = 0;
        h.publications = 0;
        for (uint256 i; i < 64; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(block.timestamp + 1 + seed % 900);
            uint256 exposure = defaultManager.pastDueExposure();
            uint256 rational = nativeReference.principal * nativeReference.rate * (block.timestamp - h.openingTime)
                / (10_000 * nativeReference.year);
            // The live book floors its rate to whole normalized wei per second, and the
            // contractual period is rounded once to the asset grid. The independent bound
            // is therefore one grid unit plus one wei for each elapsed second.
            assertApproxEqAbs(exposure - h.openingExposure, rational,
                _nativeScale() + block.timestamp - h.openingTime + 1, "cohort accumulated drift");
            if (i % 2 == 0) {
                reserves.postAccruedLoan(nativeId);
                ++h.postings;
                assertEq(defaultManager.pastDueExposure(), exposure, "posting changed assessed exposure");
            }
            if (i % 7 == 0) {
                h.publishedNet = seed % 100_000e18;
                uint256 feeBase = defaultManager.performanceFeeImpairment();
                uint256 netBase = defaultManager.pendingSeniorImpairment();
                h.publishedFee = h.publishedNet + feeBase - netBase;
                h.publishedExposure = exposure;
                vm.prank(admin);
                assessedImpairmentSource.setAssessment(h.publishedNet, uint64(block.timestamp + 7 days), bytes32(seed));
                ++h.publications;
            }
            assertEq(assessedImpairmentSource.pendingSeniorImpairment(), h.publishedNet + exposure - h.publishedExposure);
            assertEq(assessedImpairmentSource.performanceFeeImpairment(), h.publishedFee + exposure - h.publishedExposure);
            (,,, bool active,) = assessedImpairmentSource.currentAssessment();
            assertTrue(active, "time or posting invalidated an assessed cohort");
        }
        assertEq(h.postings, 32);
        assertEq(h.publications, 10);
    }
}
