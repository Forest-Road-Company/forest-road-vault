// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AssessedImpairmentSource} from "../../src/AssessedImpairmentSource.sol";
import {Config} from "../../src/libraries/Config.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @notice End-to-end pricing proof for the recovery-assessment design:
///         facility default -> zero-recovery junior waterfall -> professional assessment ->
///         sUSDfr redemption preview -> automatic conservative fallback on expiry.
contract RecoveryAssessmentFlowTest is CreditLayerFixture {
    uint256 internal constant FILM = 1;

    function test_assessedRecoveryIsAppliedAfterCuratorAndBackstopProtection() public {
        // The live sUSDfr risk pool. Unstaked USDfr reserves are deliberately not the
        // denominator: they back circulating USDfr that does not participate in credit yield.
        _mintUSDfrTo(alice, 21_000e18);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 21_000e18);
        uint256 shares = vault.deposit(21_000e18, alice);
        vm.stopPrank();

        // Junior protection: 3,000 curator + 1,500 backstop.
        _postFirstLoss(anchorCurator, FILM, 3_000e18);
        _mintUSDfrTo(bob, 1_500e18);
        vm.prank(bob);
        usdfr.transfer(address(backstopMock), 1_500e18);

        uint256 tokenId = _liveFilmFacility(6_000e18);
        _attestDefault(tokenId);
        vm.prank(servicer);
        defaultManager.declareDefault(tokenId, FILM_REF);

        // Zero recovery: 6,000 - 3,000 curator - 1,500 backstop = 1,500 to seniors.
        assertEq(defaultManager.pendingSeniorImpairment(), 1_500e18);
        uint256 zeroRecoveryExit = vault.previewRedeem(shares);
        assertLt(zeroRecoveryExit, vault.convertToAssets(shares));

        AssessedImpairmentSource assessed = _wireAssessedSource();

        // Professional estimate: the gross facility loss is no more than 3,000, so the
        // curator layer covers all of it and the correct SENIOR impairment is zero.
        vm.prank(admin);
        assessed.setAssessment(0, uint64(block.timestamp + 7 days), keccak256("signed-50pc-recovery-memo"));
        assertEq(vault.redemptionTotalAssets(), vault.totalAssets());
        assertEq(vault.previewRedeem(shares), vault.convertToAssets(shares));

        // A less favorable professional estimate can publish a non-zero residual senior loss,
        // still capped by the zero-recovery engine.
        vm.prank(admin);
        assessed.setAssessment(500e18, uint64(block.timestamp + 7 days), keccak256("signed-revised-memo"));
        uint256 assessedExit = vault.previewRedeem(shares);
        assertGt(assessedExit, zeroRecoveryExit);
        assertLt(assessedExit, vault.convertToAssets(shares));

        // If governance does not refresh the professional work, pricing fails safe.
        vm.warp(block.timestamp + 7 days + 1);
        assertEq(vault.previewRedeem(shares), zeroRecoveryExit);
    }

    function test_newDefaultInvalidatesGlobalAssessmentImmediately() public {
        uint256 first = _defaultFilmFacility(6_000e18);
        assertEq(defaultManager.pendingSeniorImpairment(), 6_000e18);

        AssessedImpairmentSource assessed = _wireAssessedSource();
        vm.prank(admin);
        assessed.setAssessment(500e18, uint64(block.timestamp + 7 days), keccak256("first-facility-memo"));
        assertEq(assessed.pendingSeniorImpairment(), 500e18);

        uint256 revisionBefore = defaultManager.impairmentRevision();
        uint256 second = _liveFilmFacility(1_000e18);
        _attestDefault(second);
        vm.prank(servicer);
        defaultManager.declareDefault(second, FILM_REF);

        assertGt(defaultManager.impairmentRevision(), revisionBefore);
        assertEq(defaultManager.pendingSeniorImpairment(), 7_000e18);
        assertEq(assessed.pendingSeniorImpairment(), 7_000e18, "new default restores zero-recovery pricing");
        (,,, bool active,) = assessed.currentAssessment();
        assertFalse(active, "memo for the earlier book cannot assess the new default");
        assertEq(defaultManager.defaultedContribution(first), 6_000e18);
    }

    /// @dev Stakes `amount` into the sUSDfr vault so there is a senior tranche for the cascade to
    ///      charge. OWNER DECISION (Forest Road, 2026-08-07): the UNATTESTED past-due cohort is
    ///      bounded by what `realizeLoss` could ACTUALLY burn from the vault today, so with an
    ///      empty vault a past-due mark contributes nothing — correctly, since there is no senior
    ///      NAV to mark and `redemptionTotalAssets()` is zero either way. These assessment tests
    ///      use the mark to CREATE a non-zero conservative base, so they must stake first. This is
    ///      a fixture correction, not a weakened assertion: every property they assert
    ///      (invalidation on every past-due lifecycle transition) is unchanged and still checked.
    function _stakeSeniors(uint256 amount) internal {
        _mintUSDfrTo(alice, amount);
        vm.startPrank(alice);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();
    }

    function test_newPastDueMarkInvalidatesGlobalAssessmentImmediately() public {
        _stakeSeniors(50_000e18);
        _defaultFilmFacility(6_000e18);
        uint256 pastDueCandidate = _liveFilmFacility(1_000e18);
        uint64 maturity = bridge.facility(pastDueCandidate).maturity;
        vm.warp(uint256(maturity) + defaultManager.graceWindow(FILM) + 1);

        AssessedImpairmentSource assessed = _wireAssessedSource();
        vm.prank(admin);
        assessed.setAssessment(500e18, uint64(block.timestamp + 7 days), keccak256("declared-only-memo"));
        assertEq(assessed.pendingSeniorImpairment(), 500e18);

        defaultManager.markPastDue(pastDueCandidate);

        // OWNER DECISION 2026-08-07: 6,000e18 ATTESTED (full weight) + 1,000e18 UNATTESTED at the
        // governed weight. The invalidation property this test guards is untouched.
        uint256 mixed = 6_000e18 + registry.weightedPastDueImpairment(1_000e18);
        assertEq(defaultManager.pendingSeniorImpairment(), mixed);
        assertEq(assessed.pendingSeniorImpairment(), mixed, "new past-due risk fails closed");
        (,,, bool active,) = assessed.currentAssessment();
        assertFalse(active);
    }

    function test_partialRecoveryInvalidatesAssessmentForFreshProfessionalReview() public {
        uint256 tokenId = _defaultFilmFacility(6_000e18);
        AssessedImpairmentSource assessed = _wireAssessedSource();
        vm.prank(admin);
        assessed.setAssessment(500e18, uint64(block.timestamp + 7 days), keccak256("pre-recovery-memo"));

        _repay(tokenId, 0, 1_000e18);

        assertEq(defaultManager.pendingSeniorImpairment(), 5_000e18);
        assertEq(assessed.pendingSeniorImpairment(), 5_000e18, "recovery requires a refreshed assessment");
        (,,, bool active,) = assessed.currentAssessment();
        assertFalse(active);
    }

    function test_equalAggregateAfterLossRealizationCannotReviveStaleAssessment() public {
        // Before realization: 6,000 gross risk - 1,000 curator = 5,000 senior impairment.
        _postFirstLoss(anchorCurator, FILM, 1_000e18);
        uint256 tokenId = _defaultFilmFacility(6_000e18);
        assertEq(defaultManager.pendingSeniorImpairment(), 5_000e18);

        AssessedImpairmentSource assessed = _wireAssessedSource();
        vm.prank(admin);
        assessed.setAssessment(500e18, uint64(block.timestamp + 7 days), keccak256("pre-write-down-memo"));
        bytes32 assessedHashBefore = defaultManager.impairmentStateHash();

        // After realization: 5,000 gross risk - 0 curator = the SAME 5,000 aggregate. An
        // amount-only guard cannot see this equal-and-offsetting transition; the revision can.
        vm.prank(servicer);
        _realizeLoss(tokenId, 1_000e18, FILM_REF);

        assertEq(defaultManager.pendingSeniorImpairment(), 5_000e18, "aggregate deliberately unchanged");
        assertNotEq(defaultManager.impairmentStateHash(), assessedHashBefore, "risk identity changed");
        assertEq(assessed.pendingSeniorImpairment(), 5_000e18, "stale 500 discount cannot revive");
        (,,, bool active,) = assessed.currentAssessment();
        assertFalse(active);
    }

    function test_externalJuniorCapacityChangesAreBoundDirectionally() public {
        _defaultFilmFacility(6_000e18);
        AssessedImpairmentSource assessed = _wireAssessedSource();
        vm.prank(admin);
        assessed.setAssessment(500e18, uint64(block.timestamp + 7 days), keccak256("pre-capital-memo"));

        // CuratorModule owns this input, so DefaultManager's monotonic revision does not move.
        // The full state fingerprint must still detect it.
        uint256 revisionBefore = defaultManager.impairmentRevision();
        _postFirstLoss(anchorCurator, FILM, 1_000e18);
        assertEq(defaultManager.impairmentRevision(), revisionBefore);

        assertEq(defaultManager.pendingSeniorImpairment(), 5_000e18);
        assertEq(assessed.pendingSeniorImpairment(), 5_000e18);
        (,,, bool active,) = assessed.currentAssessment();
        assertFalse(active);

        // Refresh against the curator-funded snapshot, then increase the global junior
        // layer without touching DefaultManager storage. Unlike a class-specific curator
        // change, a global backstop top-up can only improve senior protection and must not
        // let an unprivileged dust contribution void the professional work.
        vm.prank(admin);
        assessed.setAssessment(400e18, uint64(block.timestamp + 7 days), keccak256("post-curator-memo"));
        _mintUSDfrTo(bob, 1_000e18);
        vm.prank(bob);
        usdfr.transfer(address(backstopMock), 1_000e18);

        assertEq(defaultManager.impairmentRevision(), revisionBefore);
        assertEq(defaultManager.pendingSeniorImpairment(), 4_000e18);
        assertEq(assessed.pendingSeniorImpairment(), 400e18, "beneficial global top-up preserves the memo");
        (,,, active,) = assessed.currentAssessment();
        assertTrue(active);
    }

    function test_unrelatedCuratorDustCannotTurnAssessmentRepublicationIntoPerformance() public {
        uint256 tokenId = _liveFilmFacility(6_000e18);
        _mintUSDfrTo(alice, 50_000_000e18);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 50_000_000e18);
        vault.deposit(50_000_000e18, alice);
        vm.stopPrank();

        _attestDefault(tokenId);
        vm.prank(servicer);
        defaultManager.declareDefault(tokenId, FILM_REF);

        AssessedImpairmentSource assessed = _wireAssessedSource();
        vm.prank(admin);
        assessed.setAssessment(1_000e18, uint64(block.timestamp + 7 days), keccak256("round-2-live-assessment"));
        assertEq(assessed.performanceFeeImpairment(), 1_000e18);

        uint256 hwmBefore = vault.highWaterMark();
        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);

        // One token on a healthy, unrelated class changes the assessment risk hash.
        // It moves no impairment and must not move the permanent HWM.
        _postFirstLoss(anchorCurator, Config.CLASS_RENEWABLE_ENERGY, 1e18);
        (,,, bool active,) = assessed.currentAssessment();
        assertFalse(active, "curator state change invalidates the old professional work");
        assertEq(assessed.performanceFeeImpairment(), 6_000e18, "invalid assessment fails to gross risk");
        assertEq(vault.highWaterMark(), hwmBefore, "free-running assessment fallback cannot lower the HWM");
        assertEq(vault.balanceOf(feeRecipient), feeSharesBefore);

        vm.prank(admin);
        assessed.setAssessment(1_000e18, uint64(block.timestamp + 7 days), keccak256("round-2-refreshed-assessment"));
        (, uint256 republishFeeShares) = vault.accrueFees();
        assertEq(republishFeeShares, 0, "republication with no yield cannot mint performance shares");
        assertEq(vault.highWaterMark(), hwmBefore);

        _repay(tokenId, 0, 6_000e18);
        (, uint256 cureFeeShares) = vault.accrueFees();
        assertEq(cureFeeShares, 0, "full cure with no yield cannot mint performance shares");
        assertEq(vault.balanceOf(feeRecipient), feeSharesBefore);
    }

    function test_pastDueLifecycleTransitionsAllInvalidateAssessment() public {
        _stakeSeniors(50_000e18);
        uint256 tokenId = _liveFilmFacility(6_000e18);
        uint64 maturity = bridge.facility(tokenId).maturity;
        vm.warp(uint256(maturity) + defaultManager.graceWindow(FILM) + 1);
        defaultManager.markPastDue(tokenId);

        AssessedImpairmentSource assessed = _wireAssessedSource();
        vm.prank(admin);
        assessed.setAssessment(500e18, uint64(block.timestamp + 7 days), keccak256("past-due-memo"));

        // Performing partial repayment re-anchors the past-due mark.
        _repay(tokenId, 0, 1_000e18);
        uint256 reanchored = registry.weightedPastDueImpairment(5_000e18);
        assertEq(defaultManager.pendingSeniorImpairment(), reanchored);
        assertEq(assessed.pendingSeniorImpairment(), reanchored);
        (,,, bool active,) = assessed.currentAssessment();
        assertFalse(active);

        // Fresh work on the reduced exposure cannot survive a later servicer cure.
        vm.prank(admin);
        assessed.setAssessment(400e18, uint64(block.timestamp + 7 days), keccak256("re-anchored-memo"));
        _clearPastDue(tokenId, FILM_REF);
        assertEq(defaultManager.pendingSeniorImpairment(), 0);
        (,,, active,) = assessed.currentAssessment();
        assertFalse(active, "clearPastDue changes the assessed risk snapshot");
    }

    function test_pastDueToDeclaredConversionInvalidatesEvenWhenAmountIsUnchanged() public {
        _stakeSeniors(50_000e18);
        uint256 tokenId = _liveFilmFacility(6_000e18);
        uint64 maturity = bridge.facility(tokenId).maturity;
        vm.warp(uint256(maturity) + defaultManager.graceWindow(FILM) + 1);
        defaultManager.markPastDue(tokenId);

        AssessedImpairmentSource assessed = _wireAssessedSource();
        vm.prank(admin);
        assessed.setAssessment(500e18, uint64(block.timestamp + 7 days), keccak256("past-due-only-memo"));
        uint256 beforeConversion = defaultManager.pendingSeniorImpairment();

        _attestDefault(tokenId);
        vm.prank(servicer);
        defaultManager.declareDefault(tokenId, FILM_REF);

        // INVERTED DELIBERATELY — OWNER DECISION 2026-08-07. The AMOUNT is no longer unchanged
        // across the conversion, and that is the whole point of the decision: the same principal
        // carries a heavier forward mark once the attestation quorum has been consumed and
        // `realizeLoss` has become reachable. The property this test guards — that the conversion
        // INVALIDATES a standing assessment even though the underlying facility did not move — is
        // asserted unchanged below, and is now additionally visible in the amount.
        assertEq(beforeConversion, registry.weightedPastDueImpairment(6_000e18), "unattested: governed weight");
        assertEq(defaultManager.pendingSeniorImpairment(), 6_000e18, "attested: FULL weight");
        assertGt(defaultManager.pendingSeniorImpairment(), beforeConversion, "attestation raises the mark");
        assertEq(assessed.pendingSeniorImpairment(), 6_000e18);
        (,,, bool active,) = assessed.currentAssessment();
        assertFalse(active);
    }

    function test_cleanDefaultResolutionAndBackstopRewireInvalidateAssessment() public {
        uint256 tokenId = _defaultFilmFacility(6_000e18);
        AssessedImpairmentSource assessed = _wireAssessedSource();
        vm.prank(admin);
        assessed.setAssessment(500e18, uint64(block.timestamp + 7 days), keccak256("workout-memo"));

        _repay(tokenId, 0, 6_000e18);
        assertEq(defaultManager.pendingSeniorImpairment(), 0);
        (,,, bool active,) = assessed.currentAssessment();
        assertFalse(active, "clean resolution retires the old workout evidence");

        // Create a fresh risk snapshot and prove that rewiring an equally empty backstop is still
        // a revision event: capacity is numerically unchanged, but the protection source changed.
        _defaultFilmFacility(1_000e18);
        vm.prank(admin);
        assessed.setAssessment(100e18, uint64(block.timestamp + 7 days), keccak256("new-workout-memo"));
        uint256 conservativeBefore = defaultManager.pendingSeniorImpairment();
        vm.prank(admin);
        defaultManager.setBackstop(address(0));

        assertEq(defaultManager.pendingSeniorImpairment(), conservativeBefore);
        assertEq(assessed.pendingSeniorImpairment(), conservativeBefore);
        (,,, active,) = assessed.currentAssessment();
        assertFalse(active, "backstop identity is part of the assessment snapshot");
    }

    function test_mtmLiquidationInvalidatesAssessment() public {
        _mintUSDfrTo(alice, 6_000e18);
        uint256 tokenId = _originateDigital(6_000e18, 12_000e18);
        _fundFacility(tokenId, 6_000e18);

        AssessedImpairmentSource assessed = _wireAssessedSource();
        vm.prank(admin);
        assessed.setAssessment(0, uint64(block.timestamp + 7 days), keccak256("clean-book-memo"));

        _setValuation(tokenId, 7_000e18, uint64(block.timestamp)); // 85.7% >= 80% liquidation LTV
        defaultManager.liquidate(tokenId);

        assertEq(defaultManager.pendingSeniorImpairment(), 6_000e18);
        assertEq(assessed.pendingSeniorImpairment(), 6_000e18);
        (,,, bool active,) = assessed.currentAssessment();
        assertFalse(active);
    }

    function _defaultFilmFacility(uint256 principal) internal returns (uint256 tokenId) {
        tokenId = _liveFilmFacility(principal);
        _attestDefault(tokenId);
        vm.prank(servicer);
        defaultManager.declareDefault(tokenId, FILM_REF);
    }

    function _wireAssessedSource() internal view returns (AssessedImpairmentSource assessed) {
        return assessedImpairmentSource;
    }
}
