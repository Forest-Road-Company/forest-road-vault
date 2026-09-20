// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {Config} from "../../src/libraries/Config.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {MockAttestationOracle} from "../helpers/MockAttestationOracle.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";

/// @title PikLiveness - the family of ways a refused crank manufactures a credit event
///
/// @notice ONE SHAPE, FOUR MEMBERS. `ClaimBridge.nextPaymentDue` only ever advances inside
///         `WaterfallEngine.capitalizePik`, so ANYTHING that blocks the crank converts a borrower
///         performing exactly as contracted into a permissionlessly markable past-due facility, and
///         through `DefaultManager.pastDueExposure` into pending senior impairment. The protocol's
///         own refusal becomes the credit event. That is the property this file defends.
///
/// @dev PROVENANCE, and why this file exists. Three of the four members were reported by an
///      adversarial round on 2026-09-09 and recorded in `STATE.md` as "NOT INDEPENDENTLY
///      REPRODUCED HERE". A finding that has never been executed is a rumour, and a fix written
///      against a rumour cannot be checked. Each test below therefore REPRODUCES first and is only
///      then paired with a fix. The fourth member (a standing backing deficit) was reproduced and
///      fixed on 2026-09-09 and lives in `PikCapitalization.t.sol`.
contract PikLivenessTest is CreditLayerFixture {
    uint256 internal constant P = 1_000_000e18;

    /// @dev A large real default book for the constant-cost servicing regression.
    uint256 internal constant LEDGER_ROWS = 280;
    bytes32 internal constant BORROWER = keccak256("pik-liveness-borrower");
    bytes32 internal constant STATE = keccak256("pik-liveness-state");

    uint256 internal tokenId;

    /// @dev Mutable so one test can originate a CASH-PAY facility inside a PIK suite, which is the
    ///      control for the pause member: the crank is irrelevant to a cash-pay loan, so the pause
    ///      must not shelter one.
    bool internal originatePik = true;

    function _pikFacilities() internal view virtual override returns (bool) {
        return originatePik;
    }

    /// @dev External wrapper so a test can `vm.expectRevert` around the whole of
    ///      `_originateDigital`. The cheat binds to the NEXT call, and the helper makes several
    ///      attestation calls before it reaches `bridge.originate`.
    function originateDigitalExternal(uint256 principal, uint256 markValue) external returns (uint256) {
        return _originateDigital(principal, markValue);
    }

    function _classBit(uint256 classId) internal pure returns (uint256) {
        return 1 << (classId - 1);
    }

    function _nextDue(uint256 id) internal view returns (uint64) {
        return bridge.facility(id).nextPaymentDue;
    }

    function setUp() public override {
        super.setUp();
        _mintUSDfrTo(alice, 10_000_000e18);
        tokenId = _originateFilm(BORROWER, STATE, P);
        _fundFacility(tokenId, P);

        // The PIK crank-liveness guard is inert until governance points the manager at the engine.
        // Wiring it here is what the deploy script does; `test_PIK_theGuardIsInertUntilWired` pins
        // the unwired behaviour so the default really is safe.
        vm.prank(admin);
        defaultManager.setWaterfall(address(waterfall));
    }

    /// @dev Squeezes the Film class limit down so the standing book sits EXACTLY on its allowance.
    ///      The concentration floor is 25,000,000e18 and the book is 1,000,000e18, so the base is
    ///      the floor and a 400 bps limit puts the allowance at exactly 1,000,000e18. `_breaches`
    ///      is a strict `>`, so the book is admitted at the line and anything added breaches.
    ///      This is the "funded at exactly the published headroom" case, reached by moving the
    ///      published headroom rather than by originating up to it, which is the same state.
    function _squeezeClassToExactlyTheBook() internal {
        ICollateralRegistry.ClassParams memory p = registry.classParams(Config.CLASS_FILM_TAX_CREDITS);
        p.concentrationLimitBps = 400;
        vm.prank(admin);
        registry.setClass(Config.CLASS_FILM_TAX_CREDITS, p);
    }

    // ---------------------------------------------------------------------
    // MEMBER 2: concentration re-admission
    // ---------------------------------------------------------------------

    /// @notice CAPITALISATION MUST NOT RE-RUN THE ORIGINATION ADMISSION CHECK.
    ///
    /// @dev THE DEFECT. `capitalizePik` called `CollateralRegistry.recordExposureIncrease`, which
    ///      opens with `_checkConcentration` and REVERTS on breach. Compounding interest is not a
    ///      new origination decision: nobody chose to add it, the borrower cannot decline it and no
    ///      capital moved. Worse, capitalisation consumes its OWN headroom, so a PIK book grows into
    ///      its own limit with no adversary at all and then freezes, and the freeze is the thing
    ///      that manufactures the past-due mark.
    ///
    ///      THE FIX IS NOT A RELAXATION OF THE LIMIT. `recordCapitalizedExposure` books the exposure
    ///      and still runs `_syncClassBreaches`/`_syncBorrowerBreach`/`_syncStateBreach`, so the
    ///      breach flags fire exactly as before and governance sees the limit crossed. What changes
    ///      is that a REPORTING fact stops being a REVERT. `recordExposureDecrease` already carries
    ///      this exact reasoning in its own comment: "Reporting only - never a revert path."
    function test_FIXED_PIK_concentrationDoesNotFreezeTheCrank() public {
        _squeezeClassToExactlyTheBook();

        vm.warp(block.timestamp + 30 days);
        uint256 amount = waterfall.capitalizePik(tokenId);
        assertGt(amount, 0, "a concentration breach froze compounding interest");

        // The limit kept its whole observation function: the breach is still REPORTED. Governance
        // sees the class over its limit exactly as it did before; what it no longer does is brick
        // the borrower. (This assertion is deliberately not the anti-vacuity lever - the two tests
        // below are. `overConcentratedClasses` measures against the RAW book total while admission
        // measures against `max(total, concentrationFloor)`, so in this fixture the class reads as
        // breached on both sides of the crank. The point being pinned is that the report survives.)
        assertTrue(
            registry.overConcentratedClasses() & _classBit(Config.CLASS_FILM_TAX_CREDITS) != 0,
            "the breach must still be reported - the limit is observed, not relaxed"
        );
    }

    /// @notice Concentration limits continue to refuse new loans while signed interest is recorded in full.
    function test_FIXED_PIK_aBreachedDimensionAdmitsNothingWhileInterestIsRecordedInFull() public {
        _squeezeClassToExactlyTheBook();
        // AND SQUEEZE THE BORROWER DIMENSION TOO, because the round measured its impact mostly
        // THERE (4x the per-borrower allowance at the live floor) and because a class-only test is
        // blind to it: with the class squeezed to 400 bps the class is always the binding minimum,
        // so `concentrationHeadroom` would read zero however the borrower ledger behaved. Measured:
        // dropping `$.borrowerExp[borrowerId] += principal` from `recordCapitalizedExposure` left a
        // class-only version of this test GREEN. 400 bps of the 25,000,000e18 floor is 1,000,000e18,
        // exactly the standing exposure, and `_breaches` is a strict `>`, so the borrower dimension
        // is admitted at the line and anything capitalised breaches it.
        vm.prank(admin);
        registry.setBorrowerLimitOverride(BORROWER, 400);
        bytes32 newBorrower = keccak256("third-borrower");

        // PRECONDITION, ASSERTED RATHER THAN ASSUMED: the dimension really is shut to admission
        // before the crank. Without this the post-crank zero could be a zero that was always there
        // for an unrelated reason, and the test would prove nothing.
        assertEq(
            registry.concentrationHeadroom(Config.CLASS_FILM_TAX_CREDITS, newBorrower, STATE),
            0,
            "precondition: the squeezed class must already admit nothing"
        );
        // The SAME borrower is also shut out, on its own dimension, measured directly rather than
        // through the class-bound minimum `concentrationHeadroom` returns.
        assertEq(
            registry.concentrationHeadroom(Config.CLASS_RENEWABLE_ENERGY, BORROWER, bytes32(0)),
            0,
            "precondition: the squeezed BORROWER must already admit nothing, in any class"
        );
        uint256 exposureBefore = registry.classExposure(Config.CLASS_FILM_TAX_CREDITS);
        uint256 borrowerBefore = registry.borrowerExposure(BORROWER);
        uint256 deployedBefore = reserves.deployedTo(tokenId);
        uint256 principal = bridge.facility(tokenId).principal;

        vm.warp(block.timestamp + 30 days);
        uint256 amount = waterfall.capitalizePik(tokenId);
        assertGt(amount, 0, "the crank must actually have deepened the breach, or nothing is proved");

        // 1. STILL SHUT. The breach was deepened and remains inadmissible.
        assertEq(
            registry.concentrationHeadroom(Config.CLASS_FILM_TAX_CREDITS, newBorrower, STATE),
            0,
            "a DEEPENED breach admitted new principal"
        );

        // 1b. AND SO IS THE BORROWER, ON ITS OWN DIMENSION. This is the assertion a class-only
        //     version of this test could not make, and the one the mutation proved was missing.
        assertEq(
            registry.concentrationHeadroom(Config.CLASS_RENEWABLE_ENERGY, BORROWER, bytes32(0)),
            0,
            "a DEEPENED borrower breach admitted new principal in another class"
        );

        // 1c. AND THE DEEPENED BORROWER BREACH IS STILL REPORTED. `overConcentratedBorrowers`
        //     computes LIVE from exposure, so this asserts the disclosure view rather than the
        //     cached flag.
        //
        //     MEASURED LIMIT OF THIS ASSERTION, recorded rather than overstated. Removing
        //     `_syncBorrowerBreach($, borrowerId)` from `recordCapitalizedExposure` leaves this test
        //     GREEN, and that is not a gap in the test: `_syncBorrowerBreach` maintains only the
        //     cached `borrowerOverLimit` flag and emits `BorrowerConcentrationDrift` / `Healed` on a
        //     TRANSITION, and no view in the contract reads the flag. In this fixture the borrower IS
        //     the whole book, so its share is 100% at every instant and no capitalisation can make it
        //     CROSS a limit it is not already past; there is no transition to emit. So the
        //     "reporting is preserved in full" claim that `recordCapitalizedExposure` leans on is
        //     carried, for an already-breached dimension, entirely by the live views. Round seven
        //     raised the same point from the other direction and could not reproduce a consumer for
        //     the flag. Recorded in `STATE.md` rather than closed by a test that cannot fail.
        bytes32[] memory probeBorrowers = new bytes32[](1);
        probeBorrowers[0] = BORROWER;
        assertTrue(
            registry.overConcentratedBorrowers(probeBorrowers)[0],
            "a capitalisation deepened a borrower breach without reporting it"
        );

        // 2. EXACTLY THE CAPITALISED AMOUNT, on all three ledgers.
        assertEq(
            registry.classExposure(Config.CLASS_FILM_TAX_CREDITS) - exposureBefore,
            amount,
            "class exposure moved by something other than the capitalised amount"
        );
        assertEq(
            registry.borrowerExposure(BORROWER) - borrowerBefore,
            amount,
            "BORROWER exposure moved by something other than the capitalised amount"
        );
        assertEq(
            reserves.deployedTo(tokenId) - deployedBefore, amount, "deployed and exposure disagree about the crank"
        );

        // Continue recording the signed interest even after the original principal triples.
        _amendRateAndRoll(tokenId, 10_000);
        _amendRateAndRoll(tokenId, 10_000);
        uint256 expected = reserves.deployedTo(tokenId);
        for (uint256 i; i < 20; ++i) {
            vm.warp(block.timestamp + 30 days);
            uint256 rate = i == 0 ? 1400 : 10_000;
            uint256 coupon = expected * rate / 120_000 / 1e12 * 1e12;
            assertEq(waterfall.capitalizePik(tokenId), coupon);
            expected += coupon;
            assertEq(reserves.deployedTo(tokenId), expected);
        }
        assertGt(expected, principal * 3);
        assertEq(
            registry.classExposure(Config.CLASS_FILM_TAX_CREDITS),
            exposureBefore + (reserves.deployedTo(tokenId) - deployedBefore),
            "exposure and deployed diverged across the whole compounding run"
        );
        assertEq(
            registry.borrowerExposure(BORROWER) - borrowerBefore,
            reserves.deployedTo(tokenId) - deployedBefore,
            "BORROWER exposure and deployed diverged across the whole compounding run"
        );
        assertEq(
            registry.concentrationHeadroom(Config.CLASS_FILM_TAX_CREDITS, newBorrower, STATE),
            0,
            "the class dimension admitted new principal at some point during the run"
        );
        assertEq(
            registry.concentrationHeadroom(Config.CLASS_RENEWABLE_ENERGY, BORROWER, bytes32(0)),
            0,
            "the borrower dimension admitted new principal at some point during the run"
        );
    }

    /// @notice AND THE ORIGINATION PATH MUST STILL REFUSE. The fix must not leak into `fund`.
    /// @dev Anti-vacuity for the test above: if `recordExposureIncrease` had simply been softened,
    ///      this would go green too and the pair would prove nothing.
    function test_PIK_concentrationStillRefusesANewOrigination() public {
        _squeezeClassToExactlyTheBook();

        bytes memory expected = abi.encodeWithSelector(
            ICollateralRegistry.Registry_ConcentrationExceeded.selector, Config.CLASS_FILM_TAX_CREDITS, 2 * P, 400
        );

        // The admission VIEW still refuses. This is the predicate `ClaimBridge.originate` consults.
        vm.expectRevert(expected);
        registry.checkConcentration(Config.CLASS_FILM_TAX_CREDITS, keccak256("second-borrower"), STATE, P);

        // AND THE ORIGINATION WRITE PATH ITSELF STILL REVERTS. This is the sharp end of the
        // anti-vacuity check: if the fix had been made by softening `recordExposureIncrease`
        // instead of by adding a separate capitalisation entry point, this call would succeed and
        // the concentration limit would be gone from the whole protocol. `waterfall` is the
        // CREDIT_ROLE holder, so pranking it exercises the real authorisation path.
        vm.prank(address(waterfall));
        vm.expectRevert(expected);
        registry.recordExposureIncrease(Config.CLASS_FILM_TAX_CREDITS, keccak256("second-borrower"), STATE, P);
    }

    /// @notice AND THE FACILITY STAYS WRITEABLE OFF. Exposure must still track deployed principal.
    /// @dev `realizeLoss` pairs its write-down with `recordExposureDecrease`, which reverts
    ///      `Registry_ExposureUnderflow` if exposure lags. A "fix" that skipped the booking
    ///      entirely, rather than skipping only the admission check, would strand the facility.
    function test_PIK_capitalisedInterestStaysWriteableOff() public {
        _squeezeClassToExactlyTheBook();
        uint256 before = registry.classExposure(Config.CLASS_FILM_TAX_CREDITS);

        vm.warp(block.timestamp + 30 days);
        uint256 amount = waterfall.capitalizePik(tokenId);

        assertEq(
            registry.classExposure(Config.CLASS_FILM_TAX_CREDITS),
            before + amount,
            "registry exposure must track deployed principal or the facility cannot be written off"
        );
    }

    /// @notice DEACTIVATING A CLASS MUST NOT FREEZE THE CRANK EITHER.
    ///
    /// @dev FOUND BY REVIEWING MY OWN FIX, not by a round. `recordCapitalizedExposure` deliberately
    ///      drops TWO gates that `recordExposureIncrease` applies: the concentration admission
    ///      revert, which is the whole point of the function, and the `active` check, which was
    ///      dropped silently and is pinned here.
    ///
    ///      IT IS THE SAME DEFECT BY A DIFFERENT LEVER. `setClass(active: false)` stops the book
    ///      taking on NEW exposure. It is not a statement that existing facilities have stopped
    ///      accruing interest, and the borrower has no say in it. Had capitalisation kept the
    ///      check, deactivating a class would have frozen the crank on every PIK facility in it,
    ///      and a frozen crank converts performing borrowers into permissionlessly markable
    ///      past-due facilities. Governance keeps every tool it had for winding a class down; what
    ///      it does not get is to manufacture a credit event against a borrower paying as
    ///      contracted.
    ///
    ///      ANTI-VACUITY. The origination control below shows the same deactivated class still
    ///      refuses new exposure, so this is not a blanket removal of the `active` flag's meaning.
    function test_PIK_anInactiveClassDoesNotFreezeTheCrank() public {
        ICollateralRegistry.ClassParams memory p = registry.classParams(Config.CLASS_FILM_TAX_CREDITS);
        p.active = false;
        vm.prank(admin);
        registry.setClass(Config.CLASS_FILM_TAX_CREDITS, p);

        vm.warp(block.timestamp + 30 days);
        uint256 amount = waterfall.capitalizePik(tokenId);
        assertGt(amount, 0, "deactivating a class froze compounding interest on a performing loan");

        // CONTROL: the deactivated class still refuses NEW exposure through the origination path.
        vm.prank(address(waterfall));
        vm.expectRevert(
            abi.encodeWithSelector(ICollateralRegistry.Registry_ClassInactive.selector, Config.CLASS_FILM_TAX_CREDITS)
        );
        registry.recordExposureIncrease(Config.CLASS_FILM_TAX_CREDITS, keccak256("new-borrower"), STATE, P);
    }

    // ---------------------------------------------------------------------
    // MEMBER 3: guardian pause
    // ---------------------------------------------------------------------

    /// @notice A GUARDIAN PAUSE MUST NOT MARK THE WHOLE PIK BOOK PAST DUE.
    ///
    /// @dev THE DEFECT. `capitalizePik` is `whenNotPaused`; `DefaultManager.markPastDue` is not,
    ///      and lives in a different contract, so pausing the waterfall does not gate it. A pause
    ///      held longer than one interval plus the class grace window makes every PIK facility in
    ///      the book markable by any passer-by, for a borrower who was never given the chance to
    ///      have their capitalisation processed. The guardian's own safety action becomes a
    ///      protocol-wide credit event.
    ///
    ///      THE FIX. `markPastDue` refuses while the crank that would have cured the delinquency is
    ///      itself paused. This is narrow on purpose: it keys on the WaterfallEngine's paused flag
    ///      and applies only to a PIK facility, because only a PIK facility depends on the crank to
    ///      stay current. A cash-pay facility is marked exactly as before, pause or no pause.
    /// @notice THE EXTENSION IS BOUNDED TO EXACTLY ONE CLASS GRACE WINDOW, PRE-MATURITY TOO.
    ///
    /// @dev ROUND SEVEN, 2026-09-10. The previous design's shelter was UNBOUNDED: while the crank was
    ///      blocked, `markPastDue` reverted for ever. Round seven reached that through two different
    ///      predicates nobody had enumerated - an attested `amendTerms` roll on a balance-capped
    ///      facility (four rolls measured at 2,919 unmarkable days) and a pause spanning maturity -
    ///      and rounds five and six had each reached it through a third. A bound in elapsed time
    ///      cannot be reached through any predicate at all, which is the point of the redesign.
    ///
    ///      This pins the bound itself, one second either side, with the pause STILL STANDING on both
    ///      sides so the only thing that changes across the boundary is the clock.
    function test_FIXED_PIK_theExtensionIsBoundedToOneGraceWindow() public {
        uint64 nextDue = _nextDue(tokenId);
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);
        assertGt(grace, 0, "a zero grace window would make this test vacuous");

        vm.prank(guardian);
        waterfall.pause();

        // The ordinary clock has run and the extension is what is sheltering the facility.
        vm.warp(uint256(nextDue) + uint256(grace) + 1);
        assertTrue(waterfall.pikCrankBlockedByProtocol(tokenId), "the pause must actually block the crank");
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_PikCrankBlocked.selector, tokenId));
        defaultManager.markPastDue(tokenId);

        // LAST SECOND OF THE EXTENSION: still sheltered.
        vm.warp(uint256(nextDue) + 2 * uint256(grace));
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_PikCrankBlocked.selector, tokenId));
        defaultManager.markPastDue(tokenId);

        // ONE SECOND LATER: markable, pause unchanged, crank still blocked. Nothing but time moved.
        vm.warp(uint256(nextDue) + 2 * uint256(grace) + 1);
        assertTrue(waterfall.paused(), "the pause must still be standing, or this proves nothing");
        assertTrue(waterfall.pikCrankBlockedByProtocol(tokenId), "the crank must still be blocked");
        defaultManager.markPastDue(tokenId);
        assertGt(defaultManager.pastDueContribution(tokenId), 0, "the bound must actually expire");
    }

    /// @notice A PAUSE SPANNING MATURITY MUST NOT MARK A BORROWER THE PROTOCOL IS REFUSING TO LET PAY.
    ///
    /// @dev ROUND SEVEN'S CONFIRMED FINDING AGAINST ROUND SIX'S FIX, reproduced to the wei by two
    ///      independent verifiers. Round six deleted the shelter at maturity on the stated premise
    ///      that "after maturity the facility owes in cash and a pause has no bearing on whether the
    ///      borrower paid". `WaterfallEngine.distribute` is
    ///      `onlyRole(SERVICER_ROLE) nonReentrant whenNotPaused` and `ReserveManager.recordPayment` is
    ///      `whenNotPaused`, and `distribute` is the ONLY route by which a repayment can be booked -
    ///      so the premise was false and the fix marked a borrower whose balloon the protocol was
    ///      simultaneously refusing. Measured: 1,149,342.0292e18 marked past due by a random address,
    ///      `pendingSeniorImpairment` 0 to 74,671.0146e18 immediately and 149,342.0292e18 at full
    ///      ramp, while the identical `distribute` call reverted `EnforcedPause` and succeeded the
    ///      moment the pause lifted.
    ///
    ///      THE FIX DOES NOT NEED TO KNOW WHICH LEVER BLOCKS WHICH PATH, and that is deliberate: the
    ///      enumeration of levers has been wrong in three consecutive rounds. Any protocol-side
    ///      blocker buys one class grace window, so a pause that spans maturity delays the mark
    ///      rather than permitting it, and a pause outlasting two cure windows is an incident for
    ///      governance rather than a reason to suppress every PIK distress signal in the book.
    function test_FIXED_PIK_aPauseSpanningMaturityDoesNotMarkABorrowerWhoCannotPay() public {
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);

        // Crank the schedule out, so the facility reaches its terminal period honestly.
        uint256 cranks;
        while (cranks < 400) {
            vm.warp(block.timestamp + 30 days);
            try waterfall.capitalizePik(tokenId) {
                cranks++;
            } catch {
                break;
            }
        }
        assertGt(cranks, 0, "the fixture never cranked");
        uint64 nextDue = _nextDue(tokenId);
        uint64 maturity = bridge.facility(tokenId).maturity;

        // The guardian pauses BEFORE maturity and the pause is still standing afterwards.
        vm.warp(uint256(maturity) - 5 days);
        vm.prank(guardian);
        waterfall.pause();
        vm.warp(uint256(nextDue) + uint256(grace) + 1 days);
        assertGe(block.timestamp, maturity, "the window must actually straddle maturity");

        // THE BORROWER CANNOT PAY. This is the half round six assumed away; assert it rather than
        // assume it, because the whole fix rests on it.
        assertTrue(waterfall.paused(), "the repayment path must really be shut");

        // SO THE MARK IS REFUSED, past maturity, for the length of the extension.
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_PikCrankBlocked.selector, tokenId));
        defaultManager.markPastDue(tokenId);

        // AND IS NOT REFUSED FOR EVER: round six's requirement still holds, bounded.
        vm.warp(uint256(nextDue) + 2 * uint256(grace) + 1);
        defaultManager.markPastDue(tokenId);
        assertGt(defaultManager.pastDueContribution(tokenId), 0, "a matured non-payer must still mark");
    }

    function test_FIXED_PIK_aGuardianPauseDoesNotMarkTheBookPastDue() public {
        uint64 nextDue = _nextDue(tokenId);
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);

        vm.prank(guardian);
        waterfall.pause();

        vm.warp(uint256(nextDue) + uint256(grace) + 1 days);

        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_PikCrankBlocked.selector, tokenId));
        defaultManager.markPastDue(tokenId);
    }

    /// @notice Each pause lever blocks capitalization and delays the mark during the extra
    ///         grace window. The test checks both effects independently for all four modules.
    function test_FIXED_PIK_everyPauseLeverThatBlocksTheCrankAlsoBlocksTheMark() public {
        uint64 nextDue = _nextDue(tokenId);
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);
        uint256 markable = uint256(nextDue) + uint256(grace) + 1 days;

        _assertLeverBlocksBoth(markable, 1);
        _assertLeverBlocksBoth(markable, 2);
        _assertLeverBlocksBoth(markable, 3);
    }

    /// @dev One lever, both halves, then unpaused again so the next case starts clean.
    ///      1 = controller, 2 = reserves, 3 = the USDfr token.
    function _assertLeverBlocksBoth(uint256 markable, uint256 lever) private {
        vm.prank(guardian);
        if (lever == 1) controller.pause();
        else if (lever == 2) reserves.pause();
        else usdfr.pause();

        assertFalse(waterfall.paused(), "the ENGINE must stay unpaused, or this tests the old guard");

        uint256 snap = vm.snapshotState();
        vm.warp(markable);

        // HALF ONE: the crank really is blocked by this lever.
        vm.expectRevert();
        waterfall.capitalizePik(tokenId);

        // HALF TWO: and therefore the mark must be refused.
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_PikCrankBlocked.selector, tokenId));
        defaultManager.markPastDue(tokenId);

        vm.revertToState(snap);
        vm.prank(guardian);
        if (lever == 1) controller.unpause();
        else if (lever == 2) reserves.unpause();
        else usdfr.unpause();
    }

    /// @notice An unpaid balloon remains markable after its bounded servicing grace window.
    function test_PIK_aMaturedFacilityThatDoesNotPayIsStillMarkable() public {
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);

        uint256 cranks;
        while (cranks < 400) {
            vm.warp(block.timestamp + 30 days);
            try waterfall.capitalizePik(tokenId) {
                cranks++;
            } catch {
                break;
            }
        }
        assertLt(cranks, 400, "the loop bound was hit; the schedule shape changed");
        assertGt(cranks, 0, "the fixture never cranked at all");

        // The crank is refused from here on, and the schedule has stopped.
        vm.expectRevert();
        waterfall.capitalizePik(tokenId);

        // PAST MATURITY the facility owes in cash, and non-payment must still be markable - but it
        // is the BOUND that makes it markable, not a claim that nothing is blocked. RESTATED
        // 2026-09-10 when the bound moved out of the view: this test used to assert
        // `pikCrankBlockedByProtocol == false` past maturity, which was an assertion about the old
        // design's internals rather than about the property. The view now answers the honest
        // question - the crank genuinely cannot run here, the terminal period is past maturity - and
        // `markPastDue` is gated on elapsed time instead.
        uint64 nextDue = _nextDue(tokenId);
        assertTrue(
            waterfall.pikCrankBlockedByProtocol(tokenId),
            "the view must report the crank blocked; the terminal period is past maturity"
        );

        // THE BOUND'S NEAR SIDE: still sheltered one second before the extension expires.
        vm.warp(uint256(nextDue) + 2 * uint256(grace));
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_PikCrankBlocked.selector, tokenId));
        defaultManager.markPastDue(tokenId);

        // THE BOUND'S FAR SIDE: one second later it is markable, with nothing else changed.
        vm.warp(uint256(nextDue) + 2 * uint256(grace) + 1);
        defaultManager.markPastDue(tokenId);
        assertGt(defaultManager.pastDueContribution(tokenId), 0, "a matured non-payer must still mark");
    }

    /// @notice An unrepresentable legacy balance is a servicing refusal, with no silent clipping.
    function test_PIK_numericCapacityIsAProtocolBlocker() public {
        assertFalse(waterfall.pikCrankBlockedByProtocol(tokenId));
        bytes32 root = 0xc49ad79e2b58679c441432bede06c67f7802343349e70ccf00d8d1ce92bb1b00;
        uint256 capacity = type(uint176).max;
        vm.store(address(reserves), keccak256(abi.encode(tokenId, uint256(root) + 3)), bytes32(capacity));
        assertEq(reserves.deployedTo(tokenId), capacity, "the storage witness must apply");
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikExposureCapacity.selector, tokenId));
        waterfall.planPik(tokenId);
        assertTrue(waterfall.pikCrankBlockedByProtocol(tokenId));
    }

    /// @notice Fully recognized PIK above the former cap still becomes past due at maturity.
    function test_FIXED_PIK_aLargeUnpaidMaturityIsStillMarkable() public {
        _amendRateAndRoll(tokenId, 10_000);
        _amendRateAndRoll(tokenId, 10_000);
        for (uint256 i; i < 24; ++i) {
            vm.warp(block.timestamp + 30 days);
            assertGt(waterfall.capitalizePik(tokenId), 0);
        }
        assertGt(reserves.deployedTo(tokenId), 3 * P);
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);
        uint64 nextDue = _nextDue(tokenId);
        uint64 maturity = bridge.facility(tokenId).maturity;
        assertLt(nextDue, maturity, "this fixture must include a terminal stub");
        uint256 bound = uint256(nextDue) + 2 * uint256(grace);
        if (uint256(maturity) + grace > bound) bound = uint256(maturity) + grace;
        vm.warp(bound);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_PikCrankBlocked.selector, tokenId));
        defaultManager.markPastDue(tokenId);
        vm.warp(bound + 1);
        defaultManager.markPastDue(tokenId);
        assertGt(defaultManager.pastDueContribution(tokenId), 0);
    }

    function _amendRateAndRoll(uint256 id, uint16 newRateBps) internal {
        ClaimBridge.Facility memory f = bridge.facility(id);
        uint64 rolled =
            f.renewable ? uint64(block.timestamp) + uint64(registry.classParams(f.classId).maxMaturity) - 1 : f.maturity;
        ClaimBridge.Amendment memory a = ClaimBridge.Amendment({
            interestRateBps: newRateBps,
            maturity: rolled,
            paymentInterval: f.paymentInterval,
            nextPaymentDue: uint64(block.timestamp) + f.paymentInterval,
            rateType: f.rateType,
            dayCountConvention: f.dayCountConvention,
            renewable: true,
            paymentScheduleHash: f.paymentScheduleHash,
            rateIndexRef: f.rateIndexRef,
            renewalTermsHash: keccak256("pik-renewal-terms")
        });
        bytes32 amendmentId = keccak256(abi.encode("pik-roll", id, newRateBps, block.timestamp, rolled));
        MockAttestationOracle(address(oracle)).setPayload(
            id,
            IAttestationOracle.AttestationKind.TermsAmended,
            keccak256(abi.encode(amendmentId, id, a)),
            uint64(block.timestamp),
            true
        );
        vm.prank(originator);
        bridge.amendTerms(id, amendmentId, a);
    }

    /// @notice A refused legacy schedule change cannot move either clock or create an early default.
    function test_FIXED_PIK_anAmendmentThatDesyncsTheScheduleDoesNotManufactureADefault() public {
        // Amend so the bridge's next due date lands EARLIER than the cursor's, without cranking.
        ClaimBridge.Facility memory f = bridge.facility(tokenId);
        (uint64 lastAt,) = waterfall.pikCursorOf(tokenId);
        uint64 cursorDue = lastAt + f.paymentInterval;

        ClaimBridge.Amendment memory a = ClaimBridge.Amendment({
            interestRateBps: f.interestRateBps,
            maturity: f.maturity,
            paymentInterval: f.paymentInterval,
            nextPaymentDue: uint64(block.timestamp) + 1 days, // strictly earlier than the cursor
            rateType: f.rateType,
            dayCountConvention: f.dayCountConvention,
            renewable: f.renewable,
            paymentScheduleHash: f.paymentScheduleHash,
            rateIndexRef: f.rateIndexRef,
            renewalTermsHash: f.renewalTermsHash
        });
        bytes32 amendmentId = keccak256(abi.encode("desync", tokenId));
        MockAttestationOracle(address(oracle)).setPayload(
            tokenId,
            IAttestationOracle.AttestationKind.TermsAmended,
            keccak256(abi.encode(amendmentId, tokenId, a)),
            uint64(block.timestamp),
            true
        );
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_LegacyPikScheduleRequiresMigration.selector, tokenId));
        vm.prank(originator);
        bridge.amendTerms(tokenId, amendmentId, a);

        assertEq(_nextDue(tokenId), cursorDue, "rejected amendment moved the bridge clock");
        (uint64 unchangedLastAt,) = waterfall.pikCursorOf(tokenId);
        assertEq(unchangedLastAt, lastAt, "rejected amendment moved the accrual clock");
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);
        vm.warp(uint256(a.nextPaymentDue) + uint256(grace) + 1 days);
        assertLt(block.timestamp, cursorDue, "the proposed earlier date was not exercised");
        vm.expectRevert(
            abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikIntervalNotElapsed.selector, tokenId, cursorDue)
        );
        waterfall.capitalizePik(tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_NotPastDue.selector, tokenId, cursorDue, cursorDue + grace
            )
        );
        defaultManager.markPastDue(tokenId);
        vm.warp(cursorDue);
        assertGt(waterfall.capitalizePik(tokenId), 0, "the original coupon could no longer settle");
        assertEq(_nextDue(tokenId), cursorDue + f.paymentInterval, "coupon settlement drifted");
    }

    /// @notice A pause cannot delay a matured non-payer's mark beyond the bounded grace window.
    /// @dev Exercises all four pause levers after maturity and confirms the mark is recorded.
    function test_FIXED_PIK_noPauseLeverSheltersAMaturedNonPayer() public {
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);

        // Crank until the schedule stops, then go past maturity with nothing paid.
        uint256 cranks;
        while (cranks < 400) {
            vm.warp(block.timestamp + 30 days);
            try waterfall.capitalizePik(tokenId) {
                cranks++;
            } catch {
                break;
            }
        }
        assertGt(cranks, 0, "the fixture never cranked");
        uint64 nextDue = _nextDue(tokenId);
        uint256 boundary = uint256(nextDue) + 2 * uint256(grace);

        // Every lever, one at a time. RESTATED 2026-09-10: each must leave the matured non-payer
        // markable ONCE THE EXTENSION HAS RUN, and sheltered until then. The previous version
        // asserted `pikCrankBlockedByProtocol == false` past maturity, which round seven showed was
        // premised on a falsehood - `WaterfallEngine.distribute` is `whenNotPaused` too, so a pause
        // spanning maturity refuses the borrower's balloon as well as the crank, and marking at the
        // stroke of maturity marks a borrower the protocol is refusing to let pay. Both sides of the
        // bound are pinned per lever, so neither an unbounded shelter nor an instant mark can ship.
        for (uint256 lever = 0; lever < 4; ++lever) {
            uint256 snap = vm.snapshotState();
            vm.prank(guardian);
            if (lever == 0) waterfall.pause();
            else if (lever == 1) controller.pause();
            else if (lever == 2) reserves.pause();
            else usdfr.pause();

            // NEAR SIDE: the borrower whose payment is being refused gets the extension.
            vm.warp(boundary);
            vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_PikCrankBlocked.selector, tokenId));
            defaultManager.markPastDue(tokenId);

            // FAR SIDE: and not one second more, on every lever, pause still standing.
            vm.warp(boundary + 1);
            defaultManager.markPastDue(tokenId);
            assertGt(defaultManager.pastDueContribution(tokenId), 0, "the senior mark must move");
            vm.revertToState(snap);
        }
    }

    /// @notice A PIK FACILITY MAY NOT BE ORIGINATED INTO A MARKED-TO-MARKET CLASS.
    ///
    /// @dev THE FIRST VERSION OF THE TERMS-SHAPE GATE COVERED TWO OF THREE CONDITIONS. `_planPik`
    ///      enforces Fixed, Actual-360, AND a Receivable class; the gate checked only the first
    ///      two. So a PIK facility could be originated and FUNDED into a marked-to-market class and
    ///      then take interest in NEITHER form: every `capitalizePik` reverts
    ///      `Waterfall_PikClassNotReceivable`, and `distribute` refuses any PIK facility carrying
    ///      an interest leg. A funded loan that can never earn or receive a wei, with nothing
    ///      anywhere saying so.
    ///
    ///      It was reachable rather than theoretical: `CLASS_DIGITAL_ASSETS` is MarkedToMarket and
    ///      active on mainnet. And it could not be repaired afterwards, because `pik` is written
    ///      once at origination and the class is not amendable, so the facility would carry the
    ///      defect for its whole life.
    function test_FIXED_PIK_cannotBeOriginatedIntoAMarkedToMarketClass() public {
        // The fixture's `_originateDigital` builds a CLASS_DIGITAL_ASSETS facility, which is
        // MarkedToMarket. With `originatePik` true the gate must refuse it outright.
        // Wrapped in an EXTERNAL self-call so `vm.expectRevert` binds to the WHOLE origination,
        // not to the first of the several attestation calls the fixture helper makes first.
        originatePik = true;
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        this.originateDigitalExternal(500_000e18, 1_000_000e18);

        // CONTROL: the same class is still perfectly originable as a CASH-PAY facility, so the
        // gate refuses the PIK combination rather than the class.
        originatePik = false;
        uint256 id = _originateDigital(500_000e18, 1_000_000e18);
        assertGt(id, 0, "a cash-pay digital-asset facility must still originate");
    }

    /// @notice AND AN UNPAUSED, GENUINELY DELINQUENT PIK FACILITY MUST STILL BE MARKABLE.
    /// @dev Anti-vacuity. Without this, a fix that simply exempted PIK facilities from
    ///      `markPastDue` altogether would pass the test above and delete the whole distress path.
    function test_PIK_anUnpausedDelinquentFacilityIsStillMarkable() public {
        // THE FIXTURE THIS TEST USED TO USE WAS NOT A DELINQUENCY, and round seven is what showed it.
        // It warped one grace window past `nextPaymentDue` with nothing paused and marked the
        // facility. But under PIK the CAPITALISATION IS THE PAYMENT and the PROTOCOL makes it: at
        // that instant `capitalizePik` would have SUCCEEDED, advancing the schedule, and the marker
        // could have called it themselves for gas. So the old fixture measured an UNTURNED CRANK and
        // called it a delinquency, which is exactly the defect the whole file exists to prevent,
        // sitting inside the control meant to prove the opposite.
        //
        // A GENUINE PIK DELINQUENCY IS A FACILITY PAST MATURITY THAT HAS NOT PAID. Before maturity
        // the borrower owes no cash at all - `WaterfallEngine.distribute` reverts
        // `Waterfall_PikCashInterestNotPermitted` on any PIK interest leg - so there is nothing for
        // them to fail to do. This is the anti-vacuity control for the whole guard: it proves the
        // mark path is still REACHABLE, on the only facts that make it right.
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);
        uint256 cranks;
        while (cranks < 400) {
            vm.warp(block.timestamp + 30 days);
            try waterfall.capitalizePik(tokenId) {
                cranks++;
            } catch {
                break;
            }
        }
        assertGt(cranks, 0, "the fixture never cranked");
        assertFalse(waterfall.paused(), "nothing may be paused, or this tests the wrong thing");

        vm.warp(uint256(_nextDue(tokenId)) + 2 * uint256(grace) + 1);
        defaultManager.markPastDue(tokenId);
        assertGt(defaultManager.pastDueContribution(tokenId), 0, "a real delinquency must still mark");
    }

    /// @notice AN UNTURNED CRANK IS NOT A DELINQUENCY. CRANK IT INSTEAD OF MARKING IT.
    ///
    /// @dev ROUND SEVEN, verified medium. `pikCrankBlockedByProtocol` returns FALSE for two states
    ///      that are nothing alike - the crank would run, and the crank is refused for a borrower-side
    ///      reason - and `markPastDue` treated both as permission to mark. So a PIK facility whose
    ///      `capitalizePik` would succeed IN THE SAME BLOCK was permissionlessly markable, for a
    ///      period the protocol was ready to settle and that the marker could have settled for gas.
    ///
    ///      The remedy this refusal names is one permissionless transaction available to whoever
    ///      received the error, which is what makes it different from sheltering the borrower. The
    ///      second half of this test proves the state is exited exactly that way.
    function test_FIXED_PIK_anUnturnedCrankIsNotADelinquency() public {
        uint64 nextDue = _nextDue(tokenId);
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);

        // Past the ordinary clock, nothing paused, and the crank is ready to run.
        vm.warp(uint256(nextDue) + uint256(grace) + 1 days);
        assertFalse(waterfall.paused(), "nothing may be paused, or this measures the other limb");
        assertFalse(waterfall.pikCrankBlockedByProtocol(tokenId), "the crank must NOT be blocked here");
        assertTrue(waterfall.pikCrankIsDue(tokenId), "the crank must be ready to run, or this is vacuous");

        // SO `markPastDue` SETTLES THE PERIOD ITSELF RATHER THAN REFUSING OR MARKING. ROUND NINE.
        //
        // Round seven's version refused with `DefaultManager_PikCrankable` and told the caller to
        // crank. Round eight showed why that is not enough: the refusal EXPIRED, so past the bound the
        // same performing facility was marked anyway, and the view the refusal rested on can be wrong
        // about the write path. Executing the crank removes both problems, and this is the assertion
        // that distinguishes the two designs - a REFUSAL leaves the schedule where it was, a
        // SETTLEMENT advances it.
        //
        // ANY ADDRESS, WITH NO ROLE AND NO BALANCE. That is what makes spending the caller's gas on
        // the remedy legitimate rather than a tax: they could have called `capitalizePik` themselves.
        address passerby = address(uint160(uint256(keccak256("round-nine-passerby"))));
        assertEq(passerby.balance, 0, "the caller must hold nothing, or the claim is weaker than stated");
        vm.prank(passerby);
        defaultManager.markPastDue(tokenId);

        assertEq(defaultManager.pastDueContribution(tokenId), 0, "a performing facility must NOT be marked");
        assertGt(_nextDue(tokenId), nextDue, "the period must have been SETTLED, which advances the schedule");
        assertEq(defaultManager.pastDueExposure(), 0, "nothing may have entered the past-due pool");
    }

    /// @notice AND IT STILL SETTLES RATHER THAN MARKING PAST THE BOUND, which is the defect itself.
    ///
    /// @dev ROUND EIGHT'S HIGHEST SURVIVING FINDING, raised by three lenses independently and verified
    ///      at medium. Under the previous design the crankable refusal was wrapped in the same capped
    ///      window as the blocked one, so past `nextPaymentDue + 2 x graceWindow` a PERFORMING facility
    ///      whose `capitalizePik` would succeed IN THE SAME BLOCK was marked past due by any address -
    ///      and the mark then bricked the crank, recoverable only by a SERVICER_ROLE cure with a
    ///      `PastDueCured` quorum. Measured: 1,097,234.679376e18 marked, `pendingSeniorImpairment` 0 to
    ///      97,234.679376e18 at full ramp, the conservative redemption rate down 10.76%. With no keeper
    ///      in the repository at the time, "nobody cranked for 42 days" was the DEFAULT state.
    ///
    ///      There is no bound on settling, and there should not be: elapsed time cannot make a current
    ///      facility late, and the remedy costs the caller one transaction they were already making.
    function test_FIXED_PIK_aPerformingFacilityIsSettledNotMarkedPastTheBound() public {
        uint64 nextDue = _nextDue(tokenId);
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);

        // WELL past the window the previous design expired at, with nothing paused.
        vm.warp(uint256(nextDue) + 2 * uint256(grace) + 30 days);
        assertFalse(waterfall.paused(), "nothing may be paused, or this measures the other limb");
        assertTrue(waterfall.pikCrankIsDue(tokenId), "the crank must be ready, or this is vacuous");

        defaultManager.markPastDue(tokenId);

        assertEq(
            defaultManager.pastDueContribution(tokenId),
            0,
            "a PERFORMING facility must not be marked, however long nobody cranked"
        );
        assertGt(_nextDue(tokenId), nextDue, "the period must have been settled instead");
    }

    // ---------------------------------------------------------------------
    // MEMBER 4: the relief-episode clock. EXAMINED AND FOUND CORRECT, PINNED RATHER THAN CHANGED.
    // ---------------------------------------------------------------------

    /// @notice A CRANK OPENS A NEW RELIEF EPISODE, AND THAT IS CORRECT FOR A PIK FACILITY.
    ///
    /// @dev THE REPORTED CONCERN. `DefaultManager.markPastDue` keys its relief episode on the pair
    ///      (`tokenId`, `ClaimBridge.nextPaymentDue`) and opens a fresh episode whenever the due
    ///      date advances past the episode high-water mark. Its own NatSpec says that "only an
    ///      authenticated servicing transition that ADVANCES `nextPaymentDue`" may do this. The
    ///      permissionless crank now advances it too, so the stated property is literally false and
    ///      an adversarial round flagged it.
    ///
    ///      WHY IT IS NOT A DEFECT, having reproduced it. The relief ramp exists to stop a SECOND
    ///      mark rewinding the clock and handing a standing cohort its relief back indefinitely.
    ///      That attack needs a mark, a clear and a re-mark. `clearPastDue` is SERVICER_ROLE plus a
    ///      `PastDueCured` quorum, so the attacker cannot supply the middle step. And the crank
    ///      cannot run while the facility is marked at all: `_planPik` refuses on
    ///      `pastDueContribution(tokenId) != 0`. So the crank can only advance the schedule of a
    ///      facility that is NOT in the cohort, which is exactly the case the episode key is meant
    ///      to treat as new.
    ///
    ///      AND SUBSTANTIVELY, A CRANK REALLY IS A NEW PAYMENT EPISODE. Under PIK the
    ///      capitalisation IS the payment (spec decision 7): the obligation grows by the period's
    ///      interest and the senior vault receives it. A borrower with no cash payment to make
    ///      cannot "miss" one, so for a PIK facility the honest reading is that a crank settles the
    ///      period exactly as an attested cash receipt settles a cash-pay period. The NatSpec
    ///      sentence is what is out of date, not the behaviour; it is corrected in
    ///      `DefaultManager.markPastDue`.
    ///
    ///      FOREST ROAD ACCEPTED THIS ON 2026-09-10, asked the question and answered it: "fresh relief
    ///      window is fine". So it is now a DECIDED property rather than a tolerated one, and it is
    ///      tested as such.
    ///
    ///      AND THIS TEST USED TO OVER-CLAIM ITS OWN NAME, which is the defect pattern round seven
    ///      found in a different control. It asserted only that `nextPaymentDue` advanced - true, but
    ///      not the claim in the title. A crank advancing the schedule is NECESSARY for a new episode
    ///      and nowhere near sufficient: the episode is keyed on the due date being past the stored
    ///      high-water mark, and the observable consequence is the RELIEF WEIGHT a later mark lands
    ///      at. So the body now drives the whole sequence the concern was about - mark, cure, crank,
    ///      re-mark - and asserts the weight, which is the thing the decision is actually about.
    function test_PIK_aCrankOpensANewReliefEpisodeAndThatIsIntended() public {
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);

        // 1. A FIRST EPISODE, ON A MID-TERM FACILITY, and the "mid-term" is load-bearing. The first
        //    version of this test cranked to exhaustion and marked a matured non-payer, which cannot
        //    then be cranked at all: `_planPik` reverts `Waterfall_PikPastMaturity`, so there is no
        //    crank left to open a second episode and the test failed at its own anti-vacuity
        //    assertion. A crank can only open a fresh episode for a facility whose schedule can still
        //    advance, so the sequence has to start mid-term.
        //
        //    THE MARK LANDS THROUGH A PAUSE HELD PAST THE BOUND, and it has to: round nine closed the
        //    other route. An earlier version of this test marked the facility through the crankable
        //    limb's expiry - nothing paused, the crank ready, past the bound - which is exactly the
        //    defect round nine fixed, so `markPastDue` now SETTLES that facility instead of marking it
        //    and this test failed at its own first assertion. A pause is the honest route: the crank
        //    genuinely cannot run, the bounded window expires, and the mark lands. It is lifted before
        //    step 4 so the crank can run there.
        uint64 firstDue = _nextDue(tokenId);
        vm.prank(guardian);
        waterfall.pause();
        vm.warp(uint256(firstDue) + 2 * uint256(grace) + 1);
        defaultManager.markPastDue(tokenId);
        uint256 firstAnchor = defaultManager.pastDueReliefAnchor();
        assertEq(firstAnchor, block.timestamp, "the first mark must anchor the cohort clock at itself");

        // 2. LET THE RELIEF DECAY, then cure. `clearPastDue` is SERVICER_ROLE plus a `PastDueCured`
        //    quorum - the step an attacker cannot supply, which is what bounds this whole shape.
        vm.warp(block.timestamp + 10 days);
        vm.prank(guardian);
        waterfall.unpause();
        _clearPastDue(tokenId, keccak256("relief-episode-cure"));
        assertEq(defaultManager.pastDueContribution(tokenId), 0, "the cure must have emptied the cohort");

        // 3. A RE-MARK ON THE SAME DUE DATE REUSES THE SPENT CLOCK. This is the S3-F3 fix and it is
        //    the control: without it, cure-and-re-mark would hand the cohort full relief for ever.
        uint256 snap = vm.snapshotState();
        defaultManager.markPastDue(tokenId);
        assertEq(
            defaultManager.pastDueReliefAnchor(),
            firstAnchor,
            "re-marking the SAME due date must reuse the original episode, not rewind the clock"
        );
        vm.revertToState(snap);

        // 4. A CRANK ADVANCES THE DUE DATE AND THEREFORE OPENS A NEW EPISODE. This is the decided
        //    behaviour: under PIK the capitalisation IS the payment, so a settled period is a new
        //    payment episode exactly as an attested cash receipt would be.
        assertTrue(waterfall.pikCrankIsDue(tokenId), "the cured facility must be crankable, or step 4 is vacuous");
        waterfall.capitalizePik(tokenId);
        uint64 advancedDue = _nextDue(tokenId);
        assertGt(advancedDue, firstDue, "the crank must advance the schedule - it is the payment");

        // AND THE SECOND MARK NEEDS THE CRANK BLOCKED AGAIN, which is round nine asserting itself.
        // Without the pause, `markPastDue` simply SETTLES the next elapsed period and returns, so the
        // facility can never be marked while its crank can run. That is the new invariant, and it is
        // pinned on its own below; here it means the fixture has to block the crank to observe the
        // episode at all.
        vm.prank(guardian);
        waterfall.pause();
        vm.warp(uint256(advancedDue) + 2 * uint256(grace) + 1);
        defaultManager.markPastDue(tokenId);
        assertEq(
            defaultManager.pastDueReliefAnchor(),
            block.timestamp,
            "a crank must open a FRESH episode: the new mark anchors the cohort clock at itself"
        );
        assertGt(defaultManager.pastDueReliefAnchor(), firstAnchor, "the fresh episode must be later than the first");
    }

    /// @notice A CALLER CANNOT GAS-STARVE THE SETTLE AND STILL LAND THE MARK.
    ///
    /// @dev THE ATTACK ROUND NINE HAS TO SURVIVE. If a caller could pick a gas limit that starves the
    ///      crank while leaving enough to finish the mark, ANY ADDRESS could mark a performing facility
    ///      for the price of a carefully sized transaction - exactly the defect round nine claims to
    ///      close, reintroduced through gas instead of through a view.
    ///
    ///      THIS NATSPEC USED TO CITE THE 63/64 RULE AND WAS FALSE, which round ten caught. The shipped
    ///      code carried an ABSOLUTE `PIK_SETTLE_GAS = 2_000_000` cap, so the retained amount was
    ///      `gasleft - 2,000,470` and 63/64 never bound at all; the test passed only because 2,000,000
    ///      happened to exceed the crank's cost in THIS fixture's empty commitment ledger. That is the
    ///      fourth time in this effort a comment has asserted something the code did not do.
    ///
    ///      IT IS NOW TRUE OF THE CODE. `DefaultAccrualLib.settlePikPeriod` forwards `available - (available >> 3)` and
    ///      retains an exact eighth. Seven eighths is below 63/64, so the explicit cap always binds and
    ///      the retained eighth is untouchable by the callee. Starving the crank therefore also starves
    ///      the mark, because the tail's cost driver is the same array the crank walks, at half the
    ///      slope: the attempt runs out of gas rather than marking, which is the safe direction.
    ///
    ///      SO THE ASSERTION IS THE DISJUNCTION, deliberately. At a squeezed gas limit `markPastDue`
    ///      either settles the period or fails outright; what it must never do is complete a MARK.
    function test_FIXED_PIK_aSqueezedGasLimitCannotMarkAPerformingFacility() public {
        uint64 nextDue = _nextDue(tokenId);
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);

        // Past the bound, nothing paused, the crank ready: the state the attack would exploit.
        vm.warp(uint256(nextDue) + 2 * uint256(grace) + 1);
        assertTrue(waterfall.pikCrankIsDue(tokenId), "the crank must be ready, or this proves nothing");

        // Sweep the whole plausible range of squeezed budgets. An external self-call is what lets the
        // gas limit be chosen per attempt; a plain call would inherit the test's whole budget.
        for (uint256 budget = 100_000; budget <= 900_000; budget += 50_000) {
            uint256 snap = vm.snapshotState();
            (bool ok,) =
                address(defaultManager).call{gas: budget}(abi.encodeWithSignature("markPastDue(uint256)", tokenId));
            if (ok) {
                // It may legitimately have SETTLED the period. It may never have MARKED.
                assertEq(
                    defaultManager.pastDueContribution(tokenId), 0, "a squeezed gas limit marked a PERFORMING facility"
                );
                assertGt(_nextDue(tokenId), nextDue, "if it succeeded it must have settled the period");
            }
            vm.revertToState(snap);
        }

        // AND THE CONTROL: with a normal budget it settles, so the sweep above was not passing merely
        // because every attempt ran out of gas before reaching the PIK branch at all.
        defaultManager.markPastDue(tokenId);
        assertEq(defaultManager.pastDueContribution(tokenId), 0, "the unsqueezed call must not mark either");
        assertGt(_nextDue(tokenId), nextDue, "the unsqueezed call must settle");
    }

    /// @notice Empty return data cannot count as a successful capitalization.
    /// @dev Test-only code removal occurs after the engine passes its wiring probe. The
    ///      fixture then checks the grace-window refusal and the eventual past-due mark.
    function test_FIXED_PIK_aCodelessEngineIsNotASuccessfulCrank() public {
        uint64 nextDue = _nextDue(tokenId);
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);

        // Wire the real engine, then strip its code. `setWaterfall` probes `paused()`, so it has to be
        // broken AFTER wiring - which also models the only way this could ever arise.
        vm.prank(admin);
        defaultManager.setWaterfall(address(waterfall));
        vm.etch(address(waterfall), "");
        assertEq(address(waterfall).code.length, 0, "the engine must really be codeless");

        // A raw call here SUCCEEDS. The facility must still take the bounded window and no more.
        vm.warp(uint256(nextDue) + uint256(grace) + 1 days);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_PikCrankBlocked.selector, tokenId));
        defaultManager.markPastDue(tokenId);

        vm.warp(uint256(nextDue) + 2 * uint256(grace) + 1);
        defaultManager.markPastDue(tokenId);
        assertGt(
            defaultManager.pastDueContribution(tokenId), 0, "a codeless engine must not shelter the facility for ever"
        );
    }

    /// @notice THE ROUND-NINE INVARIANT: A PIK FACILITY IS MARKED ONLY WHEN ITS CRANK CANNOT RUN.
    ///
    /// @dev This is the property the whole PIK liveness family has been circling since round four, and
    ///      it is now a single sentence rather than an argument about where a test sits. Rounds five,
    ///      six, seven and eight each found a defect in a design that INFERRED whether the crank could
    ///      run and then decided whether to shelter. `markPastDue` now EXECUTES the crank, so there is
    ///      nothing left to infer: a settleable period is settled, and a facility can only be marked
    ///      when the attempt fails and the bounded window has run.
    ///
    ///      THREE STATES, ALL ASSERTED HERE, because the invariant is only worth having if every branch
    ///      of it is reachable: the crank runs and nothing is marked; the crank is blocked and the
    ///      window shelters; the crank is blocked and the window has expired, so the mark lands.
    function test_FIXED_PIK_aFacilityIsMarkedOnlyWhenItsCrankCannotRun() public {
        uint64 nextDue = _nextDue(tokenId);
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);
        uint256 boundary = uint256(nextDue) + 2 * uint256(grace);

        // STATE 1: the crank can run. However late the caller is, nothing is marked.
        uint256 snap = vm.snapshotState();
        vm.warp(boundary + 365 days);
        defaultManager.markPastDue(tokenId);
        assertEq(defaultManager.pastDueContribution(tokenId), 0, "a runnable crank must never produce a mark");
        assertGt(_nextDue(tokenId), nextDue, "and the period must have been settled instead");
        vm.revertToState(snap);

        // STATE 2: the crank is blocked and the window still stands. Sheltered, and the error no longer
        // claims a pause it cannot know about - it says BLOCKED, which is all the contract established.
        vm.prank(guardian);
        waterfall.pause();
        vm.warp(boundary);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_PikCrankBlocked.selector, tokenId));
        defaultManager.markPastDue(tokenId);

        // STATE 3: blocked, and the window has run. Markable, which is round six's requirement.
        vm.warp(boundary + 1);
        defaultManager.markPastDue(tokenId);
        assertGt(defaultManager.pastDueContribution(tokenId), 0, "a blocked crank past its window must mark");
    }

    /// @notice AND A MARKED FACILITY CANNOT BE CRANKED, which is what closes the rewind.
    /// @dev This is the load-bearing half of the argument above. Without it, an attacker could
    ///      crank a marked facility, advance its due date and buy the standing cohort a fresh
    ///      relief window without ever touching `clearPastDue`.
    function test_PIK_aMarkedFacilityCannotBeCranked() public {
        // The mark has to be LEGITIMATE for this to test anything: round seven showed that marking a
        // facility whose crank would run is itself the defect, so the old fixture's premise was the
        // thing being fixed. Crank the schedule out and mark a matured non-payer instead.
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);
        uint256 cranks;
        while (cranks < 400) {
            vm.warp(block.timestamp + 30 days);
            try waterfall.capitalizePik(tokenId) {
                cranks++;
            } catch {
                break;
            }
        }
        assertGt(cranks, 0, "the fixture never cranked");
        vm.warp(uint256(_nextDue(tokenId)) + 2 * uint256(grace) + 1);
        defaultManager.markPastDue(tokenId);
        assertGt(defaultManager.pastDueContribution(tokenId), 0, "the mark must have landed");

        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikPastDue.selector, tokenId));
        waterfall.capitalizePik(tokenId);
    }

    /// @notice AN UNREADABLE ENGINE MUST NOT SHELTER A FACILITY. The guard fails OPEN.
    ///
    /// @dev FOUND BY REVIEWING MY OWN FIX. The first version called `$.waterfall.paused()` through
    ///      the interface. If the engine were ever upgraded to something that reverts, or wired to
    ///      an address that answers nothing, that call would propagate and brick `markPastDue` for
    ///      the ENTIRE PIK book: the same denial of service the guard exists to prevent, aimed the
    ///      other way, and this time suppressing the distress signal seniors are priced off rather
    ///      than manufacturing one.
    ///
    ///      D5-03 records UNDER-marking as the dangerous direction, so the probe is a bounded
    ///      `staticcall` and "unreadable" resolves to NOT PAUSED. A protocol that cannot see its
    ///      own pause state should mark, not look away.
    ///
    ///      The engine here is etched with code that reverts on every call, which is exactly what a
    ///      bad upgrade or a wrong address looks like from this contract's side.
    function test_PIK_anUnreadableEngineDoesNotShelterTheFacility() public {
        uint64 nextDue = _nextDue(tokenId);
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);

        // Point the manager at an address whose `paused()` reverts. `setWaterfall` probes at set
        // time, so wire the good engine first and then break it, which models an upgrade.
        vm.prank(admin);
        defaultManager.setWaterfall(address(waterfall));
        vm.etch(address(waterfall), hex"60006000fd"); // PUSH1 0 PUSH1 0 REVERT
        (bool ok,) = address(waterfall).staticcall(abi.encodeWithSignature("paused()"));
        assertFalse(ok, "the engine must actually be unreadable, or this test proves nothing");

        // RESTATED 2026-09-10, AND THE CHANGE IS DELIBERATE RATHER THAN A CONCESSION. Before round
        // nine this asserted that an unreadable engine does not shelter AT ALL: the guard read the
        // engine through a bounded `staticcall` that failed OPEN, so an unreadable module left the
        // facility markable immediately. Round nine replaced the read with an ATTEMPT, and an attempt
        // on an unreadable engine necessarily fails, so the facility now takes the same bounded window
        // as any other unsettleable crank.
        //
        // THAT IS THE RIGHT DIRECTION AND IT IS STILL BOUNDED, which is the distinction D5-03 actually
        // draws. An unreadable engine means the borrower genuinely cannot have their period settled by
        // anyone at any price, so marking them instantly was the protocol punishing a borrower for its
        // own broken wiring. What D5-03 forbids is an OPEN-ENDED shelter, and one grace window is not
        // one: both sides of the bound are asserted below, so neither an instant mark nor an indefinite
        // shelter can ship.
        vm.warp(uint256(nextDue) + uint256(grace) + 1 days);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_PikCrankBlocked.selector, tokenId));
        defaultManager.markPastDue(tokenId);

        vm.warp(uint256(nextDue) + 2 * uint256(grace) + 1);
        defaultManager.markPastDue(tokenId);
        assertGt(
            defaultManager.pastDueContribution(tokenId),
            0,
            "an unreadable engine must not suppress the distress signal beyond the bounded window"
        );
    }

    /// @notice THE GUARD IS INERT UNTIL GOVERNANCE WIRES IT, so the upgrade itself changes nothing.
    /// @dev A proxy upgraded to this implementation reads `$.waterfall == address(0)`. That must
    ///      behave exactly as the pre-upgrade contract did, or the upgrade is not safe to ship.
    function test_PIK_theGuardIsInertUntilWired() public {
        vm.prank(admin);
        defaultManager.setWaterfall(address(0));

        uint64 nextDue = _nextDue(tokenId);
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);

        vm.prank(guardian);
        waterfall.pause();
        vm.warp(uint256(nextDue) + uint256(grace) + 1 days);

        defaultManager.markPastDue(tokenId);
        assertGt(
            defaultManager.pastDueContribution(tokenId),
            0,
            "an unwired manager must behave exactly as it did before the field existed"
        );
    }

    /// @notice AND A CASH-PAY FACILITY IS UNAFFECTED BY THE PAUSE.
    /// @dev The crank is irrelevant to a cash-pay loan, so the pause must not shelter one.
    function test_PIK_aCashPayFacilityIsStillMarkableWhilePaused() public {
        originatePik = false;
        uint256 cashId = _originateFilm(keccak256("cash-borrower"), STATE, P);
        _fundFacility(cashId, P);
        originatePik = true;
        uint64 nextDue = _nextDue(cashId);
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);

        vm.prank(guardian);
        waterfall.pause();
        vm.warp(uint256(nextDue) + uint256(grace) + 1 days);

        defaultManager.markPastDue(cashId);
        assertGt(defaultManager.pastDueContribution(cashId), 0, "the pause must not shelter a cash-pay loan");
    }

    // ── ROUND TEN: the fixed gas bound was the wrong KIND of bound ────────

    /// @notice The servicing selector agrees with the callable interface.
    /// @dev The compiled incorrect-selector control also checks actual large-book settlement.
    function test_pik_theCapitalizePikSelectorLiteralMatchesTheInterface() public view {
        assertEq(
            waterfall.capitalizePik.selector,
            bytes4(0x41a3f095),
            "the literal in DefaultManager's assembly no longer matches capitalizePik(uint256)"
        );
    }

    /// @notice A HOSTILE ENGINE CANNOT BRICK THE MARK WITH A RETURNDATA BOMB.
    ///
    /// @dev THIS IS THE ATTACK THAT KILLED A SIBLING DESIGN IN THE SAME ROUND, and it is the reason
    ///      `DefaultAccrualLib.settlePikPeriod` sizes the returndata instead of copying it. Decoding into
    ///      `bytes memory returned` makes solc emit `returndatasize` + allocate + `returndatacopy` on
    ///      BOTH the success and the revert path, so the CALLING frame pays memory expansion for
    ///      whatever the callee chooses to return. Under a proportional reserve a hostile engine
    ///      spends roughly one unit of its seven eighths to burn one unit of the retained eighth, and
    ///      the anti-brick property - the one requirement that killed five previous designs of this
    ///      path - is gone.
    ///
    ///      `out=0, outsize=0` copies nothing, so the blob costs the caller nothing at all. The mark
    ///      must still land.
    function test_pik_aReturndataBombCannotBrickTheMark() public {
        uint64 nextDue = _nextDue(tokenId);
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);

        // Wire the real engine first, because `setWaterfall` probes `paused()`, then replace its code
        // with an engine that answers `paused()` false and returns a megabyte to `capitalizePik`.
        vm.prank(admin);
        defaultManager.setWaterfall(address(waterfall));
        vm.etch(address(waterfall), address(new ReturndataBombEngine()).code);

        // THE BUDGET IS BOUNDED ON PURPOSE, and this is what makes the test non-vacuous. Called with
        // the test's whole budget the retained eighth is millions of gas, which absorbs the copy and
        // the test would pass with or without the fix - measured: it did. At 4,000,000 the eighth is
        // ~500,000: comfortably more than the ~300,000 the marking path needs, and far less than the
        // ~2,195,456 that copying a megabyte costs. So the mark lands only because nothing is copied.
        vm.warp(uint256(nextDue) + 2 * uint256(grace) + 1);
        (bool ok,) =
            address(defaultManager).call{gas: 4_000_000}(abi.encodeWithSignature("markPastDue(uint256)", tokenId));
        assertTrue(ok, "a returndata bomb bricked markPastDue: the retained eighth was spent copying the blob");
        assertGt(
            defaultManager.pastDueContribution(tokenId),
            0,
            "markPastDue returned without marking a facility past its bounded window"
        );
    }

    /// @notice The crank allowance must grow with the caller's transaction budget.
    /// @dev Compares the gas actually received under 6-million and 24-million call budgets.
    function test_pik_theSettleBoundScalesWithTheCallersGas() public {
        GasReportingEngine probe = new GasReportingEngine();
        vm.prank(admin);
        defaultManager.setWaterfall(address(probe));

        uint64 nextDue = _nextDue(tokenId);
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);
        vm.warp(uint256(nextDue) + 2 * uint256(grace) + 1);

        uint256 snap = vm.snapshotState();
        // The outcome is irrelevant here; only the gas the probe SAW is. `deny_warnings` rejects an
        // unused low-level return, so it is consumed deliberately.
        (bool lowOk,) =
            address(defaultManager).call{gas: 6_000_000}(abi.encodeWithSignature("markPastDue(uint256)", tokenId));
        lowOk;
        uint256 low = probe.received();
        vm.revertToState(snap);

        probe.reset();
        (bool highOk,) =
            address(defaultManager).call{gas: 24_000_000}(abi.encodeWithSignature("markPastDue(uint256)", tokenId));
        highOk;
        uint256 high = probe.received();

        emit log_named_uint("forwarded at 6M", low);
        emit log_named_uint("forwarded at 24M", high);
        assertGt(low, 0, "the probe never saw the settle attempt");
        assertGt(high, low * 2, "the forwarded gas did not scale with the caller's budget: an ABSOLUTE bound is back");
    }

    /// @notice Retained gas must finish marking after an external crank consumes its allowance.
    /// @dev The fixed-class ledger shortens the marking tail. A two-million call budget
    ///      still distinguishes retention of one eighth from one sixty-fourth in this fixture.
    function test_pik_retainedGasSupportsMarkingAfterAnExhaustedCrank() public {
        for (uint256 i = 0; i < LEDGER_ROWS; ++i) {
            uint256 id = _liveFilmFacility(5_000e18);
            _attestDefault(id);
            vm.prank(servicer);
            defaultManager.declareDefault(id, FILM_REF);
        }

        uint64 nextDue = _nextDue(tokenId);
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);

        // AN ENGINE THAT BURNS EVERY UNIT IT IS HANDED, which is the actual anti-brick attack. A
        // reverting engine is NOT it: `revert` RETURNS the unused gas, so a bomb that reverts leaves
        // the caller almost its whole budget and the test passes at any reserve - measured, it did.
        // `invalid()` consumes the entire forwarded amount, so the caller is left with EXACTLY the
        // retained fraction and nothing else. That is the state the reserve exists for.
        vm.prank(admin);
        defaultManager.setWaterfall(address(waterfall));
        vm.etch(address(waterfall), address(new GasBurningEngine()).code);

        vm.warp(uint256(nextDue) + 2 * uint256(grace) + 1);
        (bool ok,) =
            address(defaultManager).call{gas: 2_000_000}(abi.encodeWithSignature("markPastDue(uint256)", tokenId));
        assertTrue(ok, "the retained fraction did not cover an expensive marking tail: anti-brick regressed");
        // The engine really did consume everything: a burned call returns no data at all.
        assertGt(defaultManager.pastDueContribution(tokenId), 0, "it returned without marking");
    }

    /// @notice A large declared-default book preserves bounded PIK servicing and borrower status.
    /// @dev Rows are created through real declarations. The optimized crank has a one-million
    ///      gas budget; restoring a row walk or breaking its selector must fail this regression.
    function test_pik_largeLedgerSettlesWithinTheServicingBudget() public {
        // Grow the ledger through the REAL path: one live row per declared default.
        for (uint256 i = 0; i < LEDGER_ROWS; ++i) {
            uint256 id = _liveFilmFacility(5_000e18);
            _attestDefault(id);
            vm.prank(servicer);
            defaultManager.declareDefault(id, FILM_REF);
        }

        uint64 nextDue = _nextDue(tokenId);
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);
        vm.warp(uint256(nextDue) + 2 * uint256(grace) + 1);
        assertTrue(waterfall.pikCrankIsDue(tokenId), "the crank must be ready, or this proves nothing");

        // Measure the actual crank, then restore its state for the marking entry point.
        uint256 snap = vm.snapshotState();
        uint256 before = gasleft();
        waterfall.capitalizePik(tokenId);
        uint256 crankCost = before - gasleft();
        vm.revertToState(snap);
        emit log_named_uint("capitalizePik gas at LEDGER_ROWS rows", crankCost);
        assertLt(crankCost, 1_000_000, "the crank regained a cost per declared row");

        // A performing facility must settle through markPastDue without gaining a risk mark.
        defaultManager.markPastDue(tokenId);
        assertEq(
            defaultManager.pastDueContribution(tokenId),
            0,
            "a grown commitment ledger marked a PERFORMING facility: the settle was starved by the bound"
        );
        assertGt(_nextDue(tokenId), nextDue, "it must have settled the period rather than done nothing");
    }
}

/// @dev An engine that answers the `setWaterfall` probe and REVERTS with a megabyte of returndata.
///
///      It must REVERT rather than return: a bomb that RETURNS is indistinguishable from a real
///      capitalisation (`returndatasize() >= 32`), so `markPastDue` correctly settles and never
///      reaches the marking path at all. The attack is a hostile engine that refuses AND makes the
///      caller pay to find out, which is what a `bytes memory` decode would have charged for.
/// @dev An engine that answers the `setWaterfall` probe and then BURNS every unit of gas forwarded
///      to it. `invalid()` consumes the whole frame, so the caller resumes holding exactly the
///      retained fraction. This is the hostile engine the anti-brick reserve exists for, and it is
///      distinct from `ReturndataBombEngine`: a revert hands the unused gas BACK.
///
///      NOTE THE PLACEMENT. These two `///` runs used to sit adjacent with no declaration between
///      them, so solc concatenated BOTH into `GasBurningEngine.devdoc.details` and
///      `ReturndataBombEngine` got no `details` key at all. Round eleven caught it by compiling the
///      pair and reading solc's own devdoc rather than by reading the source.
contract GasBurningEngine {
    function paused() external pure returns (bool) {
        return false;
    }

    function capitalizePik(uint256) external pure returns (uint256) {
        assembly {
            invalid()
        }
    }
}

/// @dev An engine that records how much gas `capitalizePik` was actually forwarded. Storage-backed,
///      so it is wired with `setWaterfall` directly rather than `vm.etch`, which would not carry it.
contract GasReportingEngine {
    uint256 public received;

    function paused() external pure returns (bool) {
        return false;
    }

    function capitalizePik(uint256) external returns (uint256) {
        received = gasleft();
        return 1;
    }

    function reset() external {
        received = 0;
    }
}

contract ReturndataBombEngine {
    function paused() external pure returns (bool) {
        return false;
    }

    function capitalizePik(uint256) external pure returns (uint256) {
        assembly {
            revert(0, 0x100000)
        }
    }
}
