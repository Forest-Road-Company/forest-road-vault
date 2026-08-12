// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Config} from "../../src/libraries/Config.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @title AUDIT FIX (SWEEP-1 RMDM-F2) — an evidenced conservative mark survives ORDINARY
///        scheduled amortisation.
///
/// @notice ═══ THIS FILE ASSERTS THE CURE. THE PROBE IT REPLACES ASSERTED THE DEFECT. ═══
///         `test_S1_P1_conservativeMarkIsErasedByOrdinaryAmortisation` PASSED on the pre-fix
///         tree: a 300,000 facility that governance had marked down 120,000 under an evidence
///         hash was returned to its full pre-mark carrying value of 300,000 by two ordinary
///         60,000 scheduled principal payments — no adjudication, no evidence, no governance
///         transaction. `ReserveManager.recordPayment` now releases only the part of the mark
///         that would otherwise STRAND above the remaining face.
///
/// @dev    WHY THE OLD CONVENTION WAS WRONG, in one line: `recognizePrincipalImpairment`'s own
///         parameter is documented as "Additional UNRECOVERABLE face principal", and cash
///         arriving is definitionally RECOVERABLE face. Releasing `min(principal, recognized)`
///         asserted the opposite — that every dollar collected was a dollar previously deemed
///         lost — and overstated `totalBackingValue()`, the right-hand side of the CLAUDE.md
///         §1.3 backing invariant, by up to `min(cash principal, mark)`.
contract SweepR1_MarkSurvivesOrdinaryCollection is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    bytes32 internal constant ADJ = keccak256("SWEEPR1-adjudication");

    /// @notice THE HEADLINE. Two ordinary scheduled principal payments must not retire an
    ///         evidenced governance mark, and total carrying value must stay flat across them.
    /// @dev DELETION MUTATION: widen `recordPayment` back to the pre-fix call
    ///      `_consumeImpairmentOnFaceDecrease($, facilityId, principal)` (compiles; every operand
    ///      still referenced). This test goes RED on
    ///      "SWEEPR1: ordinary amortisation ground away an evidenced governance mark".
    function test_SWEEPR1_ordinaryAmortisationDoesNotEraseAnEvidencedMark() public {
        uint256 id = _liveFilmFacility(300_000e18);

        // Governance adjudicates that 120k of the 300k face is unrecoverable: the tail.
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(id, 120_000e18, ADJ);
        assertEq(reserves.deployedTo(id), 300_000e18, "setup: face");
        assertEq(reserves.principalImpairmentOf(id), 120_000e18, "setup: mark");
        uint256 backingAfterMark = reserves.totalBackingValue();
        uint256 carriedBefore = reserves.deployedTo(id) - reserves.principalImpairmentOf(id);
        assertEq(carriedBefore, 180_000e18, "setup: the claim is carried at 180k after the adjudication");

        // Two ORDINARY scheduled principal payments. Nothing about the tail changed; nobody
        // adjudicated anything; no evidence hash was committed anywhere.
        _repay(id, 0, 60_000e18);
        _repay(id, 0, 60_000e18);

        assertEq(reserves.deployedTo(id), 180_000e18, "face fell by the cash principal");
        assertEq(
            reserves.principalImpairmentOf(id),
            120_000e18,
            "SWEEPR1: ordinary amortisation ground away an evidenced governance mark"
        );
        assertEq(reserves.totalPrincipalImpairment(), 120_000e18, "the aggregate mark moved too");

        // A mark of M against face F asserts expected recovery F - M. Collecting C in cash leaves
        // expected recovery F - M - C against remaining face F - C, so the mark on what remains
        // is still M and total carrying value is FLAT: the cash simply moved from receivable to
        // idle. Backing must not move.
        uint256 carriedAfter = reserves.deployedTo(id) - reserves.principalImpairmentOf(id);
        assertEq(carriedAfter, 60_000e18, "remaining expected recovery is 180k - 120k collected");
        assertEq(
            reserves.totalBackingValue(),
            backingAfterMark,
            "SWEEPR1: collecting cash on a marked facility silently repaired reported backing"
        );
    }

    /// @notice THE ANTI-STRANDING GUARANTEE G3 SHIPPED FOR IS PRESERVED EXACTLY. The mark may
    ///         never be left sitting above face that no longer exists — that breaks
    ///         `principalImpairment[f] <= deployed[f]` and underflows `_backingValue()`, which
    ///         would revert every mint, redeem and backing read (the H-2 bug class on the backing
    ///         side). A FULL cash recovery therefore clears the mark completely and restores
    ///         backing, because at that point the mark has genuinely been disproved.
    /// @dev DELETION MUTATION: delete the `if (recognized > newFace)` release in `recordPayment`
    ///      entirely. This test goes RED on
    ///      "SWEEPR1: a mark stranded above the face it qualifies".
    function test_SWEEPR1_aFullCashRecoveryStillClearsTheMarkAndRepairsBacking() public {
        uint256 id = _liveFilmFacility(300_000e18);
        uint256 backingAtFace = reserves.totalBackingValue();

        vm.prank(admin);
        reserves.recognizePrincipalImpairment(id, 120_000e18, ADJ);
        assertFalse(controller.backingInvariantHolds(), "setup: the mark must open the shortfall it recognizes");

        // The borrower pays the whole claim. The mark is disproved in full.
        _repay(id, 0, 300_000e18);

        assertEq(reserves.deployedTo(id), 0, "face is gone");
        assertEq(reserves.principalImpairmentOf(id), 0, "SWEEPR1: a mark stranded above the face it qualifies");
        assertEq(reserves.totalPrincipalImpairment(), 0, "the aggregate mark did not follow");
        assertEq(reserves.totalBackingValue(), backingAtFace, "a full recovery must restore backing to face");
        assertTrue(controller.backingInvariantHolds(), "a full cash recovery did not close the shortfall");
    }

    /// @notice PARTIAL STRANDING: a payment that takes face BELOW the standing mark releases
    ///         exactly the excess and not one wei more. This is the boundary between the two
    ///         tests above and is where an off-by-one would live.
    function test_SWEEPR1_theReleaseIsExactlyTheAmountThatWouldHaveStranded() public {
        uint256 id = _liveFilmFacility(300_000e18);

        vm.prank(admin);
        reserves.recognizePrincipalImpairment(id, 200_000e18, ADJ);
        uint256 backingAfterMark = reserves.totalBackingValue();

        // Face 300k -> 120k. The 200k mark would strand 80k above the new face.
        _repay(id, 0, 180_000e18);

        assertEq(reserves.deployedTo(id), 120_000e18, "face");
        assertEq(reserves.principalImpairmentOf(id), 120_000e18, "the mark is clamped to the new face, exactly");
        assertEq(
            reserves.totalBackingValue(),
            backingAfterMark + 80_000e18,
            "SWEEPR1: the release was not exactly the stranded excess"
        );
        // And the claim that remains is carried at zero: face 120k, all of it marked.
        assertEq(reserves.deployedTo(id) - reserves.principalImpairmentOf(id), 0, "remaining claim carried at zero");
    }

    /// @notice LIVENESS — COLLECTION STAYS OPEN. This is the property the R17-01 campaign
    ///         exists to protect and the reason its predecessor test was inverted once already.
    ///         `WaterfallEngine.distribute`'s closing gate has been NON-WORSENING since
    ///         R16-M4/M5, and a FLAT backing delta is non-worsening, so a borrower can still pay
    ///         a marked facility while the protocol is short. The fix narrows what a payment
    ///         REPORTS, never whether it is accepted.
    /// @dev If this ever goes red, the fix has reinstated the R17-01 deadlock and must be
    ///      reverted, not patched around.
    function test_SWEEPR1_collectionIsStillAcceptedWhileTheProtocolIsShort() public {
        uint256 id = _liveFilmFacility(100_000e18);
        uint256 supply = controller.totalUSDfr();

        vm.prank(admin);
        reserves.recognizePrincipalImpairment(id, 10_000e18, ADJ);
        assertFalse(controller.backingInvariantHolds(), "setup: the protocol must be short");

        uint256 deployedBefore = reserves.deployedTo(id);
        _repay(id, 0, 5_000e18);

        assertEq(reserves.deployedTo(id), deployedBefore - 5_000e18, "the partial recovery did not settle");
        assertEq(controller.recognizedDeficit(), 10_000e18, "the honest deficit is the standing mark, unchanged");
        assertEq(reserves.totalBackingValue(), supply - 10_000e18, "backing is flat across the collection");
        assertFalse(controller.backingInvariantHolds(), "a partial repair must not claim the protocol is whole");
    }

    /// @notice `recordPrincipalWritedown` DELIBERATELY KEEPS THE WIDE `min(faceDecrease,
    ///         recognized)` FORM, because there the face going away IS the marked face. Pinned so
    ///         that a later "consistency" sweep does not narrow it too and double-count the loss.
    function test_SWEEPR1_aRealisedWritedownStillConsumesTheMarkOneForOne() public {
        _postFirstLoss(anchorCurator, FILM, 300_000e18);
        uint256 id = _liveFilmFacility(300_000e18);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        vm.prank(admin);
        reserves.recognizePrincipalImpairment(id, 100_000e18, ADJ);
        uint256 backingAfterMark = reserves.totalBackingValue();

        _attestLoss(id, 100_000e18, FILM_REF);
        vm.prank(servicer);
        defaultManager.realizeLoss(id, 100_000e18, FILM_REF);

        assertEq(reserves.principalImpairmentOf(id), 0, "the realized write-down did not consume the mark");
        assertEq(reserves.deployedTo(id), 200_000e18, "face did not fall by the realized loss");
        assertEq(reserves.totalBackingValue(), backingAfterMark, "backing moved TWICE for one dollar of loss");
    }
}
