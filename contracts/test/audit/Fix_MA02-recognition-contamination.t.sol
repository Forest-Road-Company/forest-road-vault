// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {Config} from "../../src/libraries/Config.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @title AUDIT FIX (MA-2) — RECOGNITION CONTAMINATION OF PERFORMING CREDIT
/// @notice THE FINDING, and like MA-1 it exists only because independently developed fixes were
///         merged. R4-01 moved `MintRedeemController.backingInvariantHolds()` from the RECORDED
///         ledger onto the RECOGNISED basis (`totalUSDfr() <= recognizedBackingValue()`). That
///         function had THREE consumers, and R4-01's own NatSpec names all three: the dashboard,
///         the invariant campaigns, and `WaterfallEngine.distribute`'s closing gate. Flipping one
///         function flipped all three.
///
///         For the first two the flip is exactly right — they ask "IS THE PROTOCOL SOLVENT", and
///         the honest answer while USDC is missing from custody is no. `distribute` asks a
///         completely different question. Its gate exists (see the AUDIT FIX (M) comment above it)
///         because the principal leg lowers deployed principal with no mint or burn, so on the
///         `interest == 0` path nothing else asserts backing: it is there to prove THE STABLES FOR
///         THIS RECEIPT ACTUALLY ARRIVED. Answering it on the recognised basis makes it a global
///         solvency check, so one dollar of custody missing anywhere in the treasury halted EVERY
///         performing borrower's repayment, protocol-wide.
///
///         THAT IS BACKWARDS IN THE ONE DIRECTION THAT MATTERS. `distribute` is a cash-IN path:
///         `recordPayment` pulls the borrower's USDC into the treasury and verifies receipt by
///         balance delta. The contaminated gate therefore blocked the money that repairs the
///         balance sheet, for a hole in an unrelated part of it, while MA-1's door was still
///         letting money out — a protocol that could pay out but not be paid in. Combined with
///         R6-CF1's curator freeze and R4-01's user freeze (both correct), a single out-of-band
///         token movement stopped the entire business rather than the affected part of it.
///
/// @dev MERGE ADJUDICATION (R18): the original fix's absolute RECORDED-ledger gate was itself a
///      deadlock. It correctly ignored an unrelated custody observation, but still rejected a
///      fully received repayment whenever any adjudicated deficit or impairment remained. The
///      merged rule snapshots the RECOGNISED deficit before the call and requires that it does not
///      increase. Exact receipt checks remain primary; interest that would otherwise be paid out
///      of a shortfall is withheld as backing. `creditServicingBackingHolds()` remains only as a
///      recorded-ledger diagnostic compatibility view and is not an admission predicate.
///      No custody guard is weakened by this: the custody window is closed by
///      `_requireCustodiedReserve` (user par), `_requireIdleFullyCustodied` (BOTH reserve
///      out-doors, after MA-1) and `custodyLossUnabsorbed()` (curator). Performing credit is the
///      one thing that must keep running, because it is how the hole gets filled.
///
///      The former "still catches genuine under-backing" tests are deliberately inverted below:
///      they asserted the absolute-level deadlock as protection. A separate hostile-controller
///      test proves the closing gate still rejects an operation that actually widens the deficit.
contract Fix_MA02_RecognitionContamination is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    bytes32 internal constant EVIDENCE = keccak256("ma2-adjudication");
    address internal sink = makeAddr("ma2-custody-sink");

    /// @dev An out-of-band custody loss: USDC leaves with no ledger entry behind it.
    function _drainCustody(uint256 units) internal {
        vm.prank(address(reserves));
        usdc.transfer(sink, units);
    }

    /// @dev The recognised deficit — supply the recognised balance sheet cannot cover.
    function _recognisedDeficit() internal view returns (uint256) {
        uint256 supply = controller.totalUSDfr();
        uint256 recognised = controller.recognizedBackingValue();
        return supply > recognised ? supply - recognised : 0;
    }

    // ── 1. THE FINDING ───────────────────────────────────────────────────

    /// @notice THE REPRODUCTION. A performing facility, a fully attested borrower payment, and a
    ///         custody incident somewhere else entirely. Pre-fix the servicer's `distribute`
    ///         reverted `Waterfall_BackingWouldBreak` and the borrower could not pay.
    function test_MA2_performingRepaymentSurvivesAnUnrelatedCustodyShortfall() public {
        uint256 id = _liveFilmFacility(300_000e18);
        _mintUSDfrTo(alice, 100_000e18); // spare idle liquidity, so custody has something to lose
        _drainCustody(20_000e6);

        // R4-01 IS PRESERVED: recognition is honest and the user par window is shut.
        assertEq(reserves.idleCustodyShortfall(), 20_000e18, "precondition: the gap is recognised");
        assertFalse(controller.backingInvariantHolds(), "MA-2 must not weaken R4-01 recognition");
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_ReserveCustodyShortfall.selector,
                20_000e18,
                controller.recognizedBackingValue()
            )
        );
        vm.prank(alice);
        controller.redeem(1e18);

        // ...and the performing borrower may nevertheless pay.
        assertTrue(
            controller.creditServicingBackingHolds(), "precondition: the recorded ledger is not independently short"
        );
        uint256 idleBefore = reserves.idleReserve();
        uint256 deficitBefore = _recognisedDeficit();

        _repay(id, 6_000e18, 50_000e18);

        assertEq(reserves.deployedTo(id), 250_000e18, "MA-2: the principal leg never landed");
        assertEq(reserves.idleReserve(), idleBefore + 56_000e18, "MA-2: the borrower's cash never reached the treasury");
        assertEq(reserves.idleCustodyShortfall(), 20_000e18, "a repayment must not move the custody gap");
        assertEq(
            _recognisedDeficit(),
            deficitBefore - 6_000e18,
            "the interest receipt was not retained to repair the recognised gap"
        );
        assertFalse(controller.backingInvariantHolds(), "the custody hole is still reported, honestly");
    }

    /// @notice ═══ INVERTED (R18 HAND-MERGE) — DO NOT RESTORE THE OLD ASSERTION ═══
    ///         The predecessor, `test_MA2_theInterestMintCannotWidenTheRecognisedGap`, asserted
    ///         `supply == supplyBefore + 9_000e18` — i.e. that the protocol MINTS YIELD TO SENIORS
    ///         OUT OF AN OPEN HOLE. Its own precondition `assertGt(deficitBefore, 0)` is exactly
    ///         the state R17 defines `mintableHeadroom()` to be ZERO in, so it demanded a mint the
    ///         merged policy forbids. The merged policy withholds the interest as backing repair:
    ///         supply is unchanged and the gap NARROWS by the full receipt. That is the opposite
    ///         direction from MA-2's harm — repair, not contamination.
    ///
    /// @dev    THIS TEST HAS TEETH — VERIFIED BY MUTATION, NOT ASSUMED (RC3 fixer, 2026-08-08).
    ///         Neutralising the R16-M5 clamp in `WaterfallEngine._routeInterest`
    ///         (`interest <= headroom ? interest : interest`) makes this RED with
    ///         `Controller_RecognizedDeficitWorsened(11000e18, 11900e18)`. Note the revert comes
    ///         from `mintYield`'s OWN recognition assertion, confirming a second, innermost guard
    ///         forbids minting into a hole irrespective of the clamp. Mutation compiled cleanly.
    function test_MA2_interestIsWithheldToRepairRecognisedGapWithoutBlockingRepayment() public {
        uint256 id = _liveFilmFacility(300_000e18);
        _mintUSDfrTo(alice, 100_000e18);
        _drainCustody(20_000e6);

        uint256 supplyBefore = controller.totalUSDfr();
        uint256 deficitBefore = _recognisedDeficit();
        assertGt(deficitBefore, 0, "precondition: the campaign must actually stand in the gap");

        _repay(id, 9_000e18, 0); // interest only: the pure supply-increasing leg

        assertEq(controller.totalUSDfr(), supplyBefore, "interest was minted into a recognised shortfall");
        assertEq(_recognisedDeficit(), deficitBefore - 9_000e18, "withheld interest did not repair the gap");
    }

    /// @notice FUZZED. For any facility size, any spare liquidity and any custody gap, servicing a
    ///         performing loan is permitted and never widens the recognised deficit.
    function testFuzz_MA2_servicingIsPermittedAndNeverWidensTheGap(
        uint256 spareUnits,
        uint256 drainUnits,
        uint256 interest
    ) public {
        uint256 id = _liveFilmFacility(300_000e18);
        spareUnits = bound(spareUnits, 1_000e6, 200_000e6);
        _mintUSDfrTo(alice, spareUnits * 1e12);
        drainUnits = bound(drainUnits, 1, spareUnits);
        _drainCustody(drainUnits);
        interest = bound(interest, 1e18, 20_000e18);
        interest -= interest % 1e12; // whole USDC units
        if (interest == 0) interest = 1e12;

        assertEq(reserves.idleCustodyShortfall(), drainUnits * 1e12);
        uint256 deficitBefore = _recognisedDeficit();

        _repay(id, interest, 0);

        assertLe(_recognisedDeficit(), deficitBefore, "MA-2: servicing widened the recognised gap");
        assertEq(reserves.idleCustodyShortfall(), drainUnits * 1e12, "servicing must not move the custody gap");
    }

    // ── 2. THE SEPARATION IS REAL, IN BOTH DIRECTIONS ────────────────────

    /// @notice The recorded and recognised backing views remain distinct. The recorded view is
    ///         diagnostic only; operation admission is decided by the before/after recognised
    ///         deficit rule in `WaterfallEngine.distribute`.
    function test_MA2_recordedAndRecognizedBackingViewsRemainDistinct() public {
        _liveFilmFacility(300_000e18);
        _mintUSDfrTo(alice, 100_000e18);

        // Whole treasury: both true, and the two bases agree.
        assertTrue(controller.backingInvariantHolds());
        assertTrue(controller.creditServicingBackingHolds());
        assertEq(controller.backingValue(), controller.recognizedBackingValue());

        _drainCustody(20_000e6);

        // Custody gap: the public solvency view says no while the recorded diagnostic remains true.
        assertFalse(controller.backingInvariantHolds(), "solvency must be reported on the recognised basis");
        assertTrue(controller.creditServicingBackingHolds(), "the recorded diagnostic must remain ledger-based");
        assertEq(
            controller.backingValue(),
            controller.recognizedBackingValue() + reserves.idleCustodyShortfall(),
            "the two bases must differ by exactly the recognised shortfall"
        );
    }

    /// @notice ═══ INVERTED (R18 HAND-MERGE) — DO NOT RESTORE THE OLD ASSERTION ═══
    ///         The predecessor, `test_MA2_theCreditPredicateStillStopsAGenuinelyUnderBackedDistribution`,
    ///         asserted that this call MUST revert. That assertion encoded the R17-01 DEADLOCK as
    ///         though it were a safety property: a G3-marked facility could never be repaid,
    ///         because the only cure for the mark was borrower cash and the gate forbade exactly
    ///         that. It is a cash-IN path — `ReserveManager.recordPayment` proves exact receipt by
    ///         balance delta — so refusing it protects nothing and strands the recovery.
    ///
    /// @dev    THIS TEST HAS TEETH — VERIFIED BY MUTATION, NOT ASSUMED (RC3 fixer, 2026-08-08).
    ///         Restoring round 3's absolute gate in `WaterfallEngine.distribute`
    ///         (`if (!$.controller.creditServicingBackingHolds()) revert`) makes this test RED with
    ///         `Waterfall_BackingWouldBreak(1)` — round 3's exact error. The mutation compiled
    ///         cleanly ("Compiler run successful!"), so that RED is behavioural, not a build
    ///         failure. A re-pointed test that cannot fail is worthless; this one fails.
    function test_MA2_genuineUnderBackingAllowsARecoveryThatShrinksTheDeficit() public {
        uint256 id = _liveFilmFacility(300_000e18);
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(id, 250_000e18, EVIDENCE);

        assertFalse(controller.creditServicingBackingHolds(), "the recorded diagnostic must report the deficit");
        assertFalse(controller.backingInvariantHolds(), "and so must the solvency view");

        uint256 deficitBefore = _recognisedDeficit();
        uint256 deployedBefore = reserves.deployedTo(id);
        IWaterfallEngine.Payment memory payment = _preparePayment(id, 0, 100_000e18);
        vm.prank(servicer);
        waterfall.distribute(payment);

        assertEq(reserves.deployedTo(id), deployedBefore - 100_000e18, "the recovery did not settle");
        // ═══ ASSERTION NARROWED (SWEEP-1 RMDM-F2, 2026-08-08) — DO NOT RESTORE THE SUBTRACTION ═══
        // This read `deficitBefore - 100_000e18`, which was an artefact of the OPTIMISTIC mark
        // consumption in `ReserveManager.recordPayment`: an ordinary collection retired an
        // evidenced governance mark 1:1 and repaired reported backing by the cash collected.
        // Backing is now FLAT across a collection on a marked facility (the cash moves from
        // receivable to idle; the mark on the remaining face is unchanged), so the recognised
        // deficit moves ONLY by the part of the mark that would otherwise have STRANDED above the
        // new face — G3's anti-stranding rule, which is untouched. Here the 250,000 mark sits on
        // 300,000 of face and the collection takes face to 200,000, so exactly 50,000 is released
        // and the deficit falls by 50,000, not by the 100,000 of cash collected.
        //
        // MA-2's own property is that the recovery is ACCEPTED under a genuine under-backing —
        // the round-3 absolute gate would revert it — and that is what is asserted above.
        assertEq(
            _recognisedDeficit(), deficitBefore - 50_000e18, "SWEEP-1: the deficit moved by more than the stranded mark"
        );
        assertEq(reserves.principalImpairmentOf(id), 200_000e18, "the mark is clamped to the new face, exactly");
        // The EVIDENCED path is what retires the rest: governance re-marks on the strength of the
        // recovery, and only then does the reported deficit fall further.
        vm.prank(admin);
        reserves.releasePrincipalImpairment(id, 50_000e18, keccak256("MA2-workout-recovered"));
        assertEq(_recognisedDeficit(), deficitBefore - 100_000e18, "the evidenced release did not shrink the deficit");
    }

    /// @notice ═══ INVERTED (R18 HAND-MERGE) — DO NOT RESTORE THE OLD ASSERTION ═══
    ///         The predecessor, `test_MA2_anAbsorbedCustodyLossStillReachesTheCreditGate`, asserted
    ///         that this call MUST revert. Measured, the call is EXACTLY NEUTRAL to the wei: the
    ///         recognised deficit is unchanged, `deployedTo` falls by 10,000e18 and idle reserve
    ///         rises by the same — a par-for-par swap of credit exposure for cash, which is
    ///         strictly the better asset. Refusing it was pure harm, not protection.
    ///
    /// @dev    THIS TEST HAS TEETH — VERIFIED BY MUTATION, NOT ASSUMED (RC3 fixer, 2026-08-08).
    ///         Restoring round 3's absolute gate makes this RED with `Waterfall_BackingWouldBreak(1)`.
    ///         The mutation compiled cleanly, so the RED is behavioural, not a build failure.
    function test_MA2_absorbedCustodyDeficitDoesNotBlockNeutralPrincipalCollection() public {
        uint256 id = _liveFilmFacility(300_000e18);
        _mintUSDfrTo(alice, 100_000e18);
        _drainCustody(100_000e6); // every spare dollar, so absorption cannot be covered by junior

        _armReserveLoss(77);
        _ratifyCurrentReserveLoss(100_000e18);

        // No junior or senior capital was staked, so the cascade cannot absorb the loss and a
        // genuine deficit is LATCHED on the RECORDED ledger. That, not the observable shortfall,
        // is what the credit gate reads — and it still bites.
        assertEq(reserves.idleCustodyShortfall(), 0, "absorption wrote the ledger down to live custody");
        assertGt(reserves.reserveDeficit(), 0, "precondition: an unabsorbed deficit must stand");
        assertGt(controller.totalUSDfr(), controller.backingValue(), "precondition: recorded under-backing");

        assertFalse(controller.creditServicingBackingHolds(), "the recorded diagnostic must report the deficit");
        uint256 deficitBefore = _recognisedDeficit();
        uint256 latchedBefore = reserves.reserveDeficit();
        IWaterfallEngine.Payment memory payment = _preparePayment(id, 0, 10_000e18);
        vm.prank(servicer);
        waterfall.distribute(payment);
        assertEq(reserves.deployedTo(id), 290_000e18, "the neutral principal collection did not settle");
        assertEq(_recognisedDeficit(), deficitBefore, "a neutral collection changed the recognised deficit");
        assertEq(reserves.reserveDeficit(), latchedBefore, "a neutral collection changed the latched loss");
    }

    // ── 3. MA-1 AND MA-2 COEXIST ─────────────────────────────────────────

    /// @notice The two fixes are opposite in direction and must both hold in the same block: money
    ///         may come IN through `distribute` while money may NOT go OUT through `fund`. This is
    ///         the whole shape of the corrected posture and pins it against either fix drifting.
    function test_MA2_cashInIsPermittedWhileCashOutStaysShut() public {
        uint256 live = _liveFilmFacility(300_000e18);
        _mintUSDfrTo(alice, 200_000e18);
        uint256 pending = _originateFilm(BORROWER_2, STATE_GA, 100_000e18);
        _drainCustody(20_000e6);

        // OUT: shut (MA-1).
        vm.expectRevert(
            abi.encodeWithSelector(
                IReserveManager.ReserveManager_IdleCustodyShortfall.selector,
                reserves.idleUSDC(),
                usdc.balanceOf(address(reserves))
            )
        );
        vm.prank(servicer);
        waterfall.fund(pending, 100_000e6);

        // IN: open (MA-2).
        _repay(live, 4_000e18, 25_000e18);
        assertEq(reserves.deployedTo(live), 275_000e18);
        assertEq(
            uint8(bridge.facility(pending).state),
            uint8(ClaimBridge.LoanState.Pending),
            "MA-1: the second facility was funded out of a short treasury"
        );
    }
}
