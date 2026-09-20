// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {Config} from "../../src/libraries/Config.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @title PikTerminalPeriod - the bound may not expire before the obligation it would mark exists
///
/// @notice ROUND EIGHT'S ONE SURVIVING DEFECT, and the only finding of twenty-three that two
///         independent verifiers both reproduced with their own fixtures and both rated medium.
///
/// @dev WHY A SEPARATE FILE. The defect needs a schedule the shared fixture does not originate: a
///      payment interval LONGER THAN TWO CLASS GRACE WINDOWS, on a tenor that is not a whole number
///      of those intervals. Quarterly PIK against the 21-day class grace default is exactly that, and
///      it is ordinary configuration rather than a contrivance.
///
///      IT DOES NOT INHERIT `PikLivenessTest`, DELIBERATELY. The first version did, on the theory that
///      re-running that file's assertions against a quarterly schedule was a free bonus. It is not:
///      twelve of them hard-code 30-day warps and went red on a fixture they were never written for,
///      which is noise rather than coverage. A suite that re-runs someone else's tests against a
///      different fixture is asserting things nobody checked.
///
///      THE DEFECT. `WaterfallEngine.capitalizePik` advances the schedule only while the NEXT period
///      still ends on or before maturity (`if (nextDue > plan.previousDue && nextDue <= plan.maturity)`).
///      So the final crank capitalises and then SKIPS `setNextPaymentDue`, freezing `f.nextPaymentDue`
///      at the second-to-last date for the rest of the facility's life, and the engine then reports the
///      resulting clock desync as protocol-blocked for ever - correctly.
///
///      `DefaultManager._pikExtendedGraceEnd` anchored its capped extension on that FROZEN date, so the
///      extension expired `2 x graceWindow` after it. When `paymentInterval > 2 x graceWindow` that
///      instant falls BEFORE MATURITY, and the facility was marked past due while the protocol was
///      refusing its crank and the borrower owed nothing at all: under PIK there is no cash obligation
///      before maturity, because `distribute` reverts `Waterfall_PikCashInterestNotPermitted` on any
///      PIK interest leg. A credit event manufactured out of the protocol's own schedule arithmetic,
///      with no pause, no amendment and no privileged action anywhere in the path.
///
///      Measured by the verifiers on a 90-day / 410-day facility: marked SEVEN DAYS BEFORE MATURITY,
///      1,147,523.000625e18 of exposure, senior impairment 73,761.5003125e18 immediately and
///      147,523.000625e18 at full ramp.
///
///      THE FIX USES MATURITY TO DECIDE WHEN THE OBLIGATION EXISTS, not whether to shelter. That
///      distinction is the whole point: round seven removed a maturity test that decided WHETHER to
///      shelter, because it was reachable through every predicate nobody had enumerated. The bound is
///      still one capped elapsed-time window; the terminal period just measures it from maturity.
contract PikTerminalPeriodTest is CreditLayerFixture {
    uint256 internal constant P = 1_000_000e18;
    bytes32 internal constant BORROWER = keccak256("pik-terminal-borrower");
    bytes32 internal constant STATE = keccak256("pik-terminal-state");

    uint256 internal tokenId;

    function _pikFacilities() internal view virtual override returns (bool) {
        return true;
    }

    /// @dev Quarterly, which is `> 2 x graceWindow` (21 days) on every Receivable class.
    function _fixturePaymentInterval() internal view virtual override returns (uint64) {
        return 90 days;
    }

    /// @dev 410 days leaves a 50-day stub after the fourth period ends at day 360, and 50 days is
    ///      longer than the 42-day extension. At the default 365 days the stub is 5 days and the
    ///      extension already outlives maturity, which is why nothing caught this.
    function _fixtureFilmTenor() internal view virtual override returns (uint64) {
        return 410 days;
    }

    function setUp() public override {
        super.setUp();
        _mintUSDfrTo(alice, 10_000_000e18);
        tokenId = _originateFilm(BORROWER, STATE, P);
        _fundFacility(tokenId, P);
        vm.prank(admin);
        defaultManager.setWaterfall(address(waterfall));
    }

    function _nextDue(uint256 id) internal view returns (uint64) {
        return bridge.facility(id).nextPaymentDue;
    }

    /// @dev Cranks until the schedule stops advancing, and asserts that it really did stop while still
    ///      short of maturity. Returns the frozen due date.
    function _crankIntoTheTerminalPeriod() private returns (uint64 frozenDue) {
        uint64 maturity = bridge.facility(tokenId).maturity;
        uint256 cranks;
        uint64 due = _nextDue(tokenId);
        while (cranks < 40) {
            vm.warp(uint256(due));
            try waterfall.capitalizePik(tokenId) {
                cranks++;
            } catch {
                break;
            }
            uint64 next = _nextDue(tokenId);
            if (next == due) break; // the crank ran but the schedule did not advance: terminal period
            due = next;
        }
        assertGt(cranks, 0, "the fixture never cranked");
        frozenDue = _nextDue(tokenId);
        assertLt(frozenDue, maturity, "the due date must be FROZEN SHORT of maturity, or this is vacuous");
        assertGt(
            uint256(maturity) - uint256(frozenDue),
            2 * uint256(defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS)),
            "the stub must exceed two grace windows, or the old bound already outlived maturity"
        );
    }

    /// @notice A PIK FACILITY IN ITS TERMINAL PERIOD MUST NOT BE MARKABLE BEFORE ITS BALLOON IS DUE.
    function test_FIXED_PIK_theTerminalPeriodIsNotMarkableBeforeMaturity() public {
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);
        uint64 frozenDue = _crankIntoTheTerminalPeriod();
        uint64 maturity = bridge.facility(tokenId).maturity;

        // THE INSTANT THE OLD BOUND EXPIRED, which is before maturity. The protocol is refusing the
        // crank here and the borrower owes nothing, so a mark would be manufactured entirely out of
        // the protocol's own schedule arithmetic.
        uint256 oldBound = uint256(frozenDue) + 2 * uint256(grace);
        assertLt(oldBound, uint256(maturity), "the old bound must really have expired pre-maturity");
        vm.warp(oldBound + 1);
        assertTrue(waterfall.pikCrankBlockedByProtocol(tokenId), "the crank must be refused here");
        assertFalse(waterfall.pikCrankIsDue(tokenId), "and it must not be merely unturned");
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_PikCrankBlocked.selector, tokenId));
        defaultManager.markPastDue(tokenId);

        // STILL NOT MARKABLE ONE SECOND BEFORE THE BALLOON'S OWN CURE WINDOW CLOSES.
        vm.warp(uint256(maturity) + uint256(grace));
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_PikCrankBlocked.selector, tokenId));
        defaultManager.markPastDue(tokenId);

        // AND MARKABLE ONE SECOND LATER. Round six's requirement: a matured non-payer is never
        // sheltered indefinitely, whatever the blocker.
        vm.warp(uint256(maturity) + uint256(grace) + 1);
        defaultManager.markPastDue(tokenId);
        assertGt(defaultManager.pastDueContribution(tokenId), 0, "a matured non-payer must still mark");
    }

    /// @notice AND THE MARK THAT DOES LAND IS A REAL ONE: the balloon fell due and was not paid.
    /// @dev Anti-vacuity for the test above. Without this, a fix that simply made the terminal period
    ///      unmarkable for ever would pass it.
    function test_FIXED_PIK_theTerminalPeriodIsStillMarkableAfterMaturity() public {
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);
        _crankIntoTheTerminalPeriod();
        uint64 maturity = bridge.facility(tokenId).maturity;

        vm.warp(uint256(maturity) + uint256(grace) + 1);
        assertFalse(waterfall.paused(), "nothing may be paused, or this measures the other limb");
        uint256 outstanding = reserves.deployedTo(tokenId);
        assertGt(outstanding, 0, "the facility must still owe principal");

        defaultManager.markPastDue(tokenId);
        assertEq(defaultManager.pastDueContribution(tokenId), outstanding, "the whole balloon must be marked");
    }

    /// @notice NOTHING MID-TERM IS SHELTERED ONE SECOND LONGER THAN BEFORE.
    /// @dev The terminal-period floor must apply ONLY where the schedule can no longer advance. If it
    ///      leaked into the mid-term case it would shelter a facility for its whole tenor, which is the
    ///      under-marking direction D5-03 names as dangerous. Measured at the SECOND period, where
    ///      three more cranks remain and `nextPaymentDue + paymentInterval <= maturity` holds.
    function test_FIXED_PIK_theTerminalFloorDoesNotLeakIntoAMidTermFacility() public {
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);
        uint64 firstDue = _nextDue(tokenId);
        vm.warp(uint256(firstDue));
        waterfall.capitalizePik(tokenId);

        ClaimBridge.Facility memory f = bridge.facility(tokenId);
        assertLe(
            uint256(f.nextPaymentDue) + uint256(f.paymentInterval),
            uint256(f.maturity),
            "precondition: the schedule must still be able to advance"
        );

        // The guardian pauses, so the crank is blocked and the extension is what is sheltering it.
        vm.prank(guardian);
        waterfall.pause();

        vm.warp(uint256(f.nextPaymentDue) + 2 * uint256(grace));
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_PikCrankBlocked.selector, tokenId));
        defaultManager.markPastDue(tokenId);

        // ONE SECOND LATER IT IS MARKABLE, hundreds of days before maturity, pause still standing.
        vm.warp(uint256(f.nextPaymentDue) + 2 * uint256(grace) + 1);
        assertLt(block.timestamp, uint256(f.maturity), "this must still be mid-term, or the test proves nothing");
        assertTrue(waterfall.paused(), "the pause must still be standing");
        defaultManager.markPastDue(tokenId);
        assertGt(defaultManager.pastDueContribution(tokenId), 0, "the mid-term bound must be unchanged");
    }

    /// @notice `pikCrankIsDue` MUST BE FALSE UNDER THE ENGINE'S OWN PAUSE, which it was not.
    ///
    /// @dev ROUND EIGHT. `_planPik` is a plain `view` with no `whenNotPaused`, so `pikCrankIsDue`
    ///      returned TRUE while `capitalizePik` reverted `EnforcedPause`: the view's name and NatSpec
    ///      were false, and `markPastDue` was relying on the ORDER of its two limbs to mask it. Both
    ///      verifiers reproduced it. The view now checks `paused()` first, which makes the two limbs
    ///      order-independent and makes a public view mean what it says.
    ///
    ///      The residual blindness to the three MODULE pauses and to the write path is recorded and
    ///      bounded, not fixed here: `_planPik` cannot see them either, and the enumeration of which
    ///      lever blocks which call has been wrong in three consecutive rounds.
    function test_FIXED_PIK_theCrankIsDueViewRespectsTheEnginePause() public {
        uint64 firstDue = _nextDue(tokenId);
        vm.warp(uint256(firstDue));

        // Unpaused, the crank really would run: this is the anti-vacuity half.
        assertTrue(waterfall.pikCrankIsDue(tokenId), "precondition: the crank must be ready to run");

        vm.prank(guardian);
        waterfall.pause();
        assertFalse(waterfall.pikCrankIsDue(tokenId), "a paused engine cannot run the crank, and must not say it would");
        assertTrue(waterfall.pikCrankBlockedByProtocol(tokenId), "and the blocker view must report it");
    }
}
