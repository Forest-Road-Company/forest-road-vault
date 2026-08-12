// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";

import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {CustodyPreArmHandler, PreArmSilentGovernor} from "./handlers/CustodyPreArmHandler.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @title INV_CustodyPreArm — stateful invariants for the guardian pre-arm budget/expiry machine
/// @notice AUDIT FIX F3-PA. The R6-CF1 pre-arm shipped with NO stateful coverage: every property
///         it claimed was pinned by single-shot unit tests, and three of its four defects are
///         state-machine defects that only a SEQUENCE exposes —
///
///           PA-a  the only budget-replenishing lever also zeroed the expiry, so regaining budget
///                 destroyed the active protection;
///           PA-b  the "consecutive" counter was a LIFETIME counter, permanently spending the
///                 guardian's emergency lever after two arms;
///           PA-c  the duration cap silently inverted the requirement it was written to enforce;
///           PA-d  a governor with a permissive fallback reverted `preArmCustodyFreeze` outright.
///
///         WHICH TIER CATCHES WHAT (this is the point of the suite):
///           - deleting the episode reset from `preArmCustodyFreeze`      -> `invariant_PA1`
///           - deleting the `+ cooldown` term from that same predicate    -> `invariant_PA1`
///           - making `replenishCustodyPreArmBudget` touch the expiry     -> `invariant_PA1`, `PA2`
///           - any governor shape that reverts the arm                    -> `invariant_PA4`
///           - a derivation whose duration stops exceeding its own path   -> `invariant_PA5`
///
/// @dev ANTI-VACUITY IS ASSERTED, NOT LOGGED. `afterInvariant` fails the campaign if the states
///      these invariants claim to police were never entered: no arm accepted, no budget bound
///      fired, no episode ever reset, no replenishment while protection stood, no frozen
///      withdrawal refused, no free withdrawal completed. A green campaign that never got there is
///      worse than no campaign — six vacuous suites have already been caught in this engagement.
///
///      `fail_on_revert = true` (repo default) is load-bearing here and is NOT relaxed.
contract INV_CustodyPreArm is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    uint256 internal constant SEED_CAPITAL = 2_000_000e18;

    CustodyPreArmHandler internal preArmHandler;

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        curator.setCuratorApproved(FILM, anchorCurator, true);
        _mintUSDfrTo(anchorCurator, SEED_CAPITAL);
        vm.startPrank(anchorCurator);
        usdfr.approve(address(curator), type(uint256).max);
        curator.postFirstLoss(FILM, 500_000e18);
        vm.stopPrank();

        // The class carries ZERO live exposure, so ADR-0004 subordination headroom is the whole
        // pool and the ONLY thing that can refuse a withdrawal is the freeze under test. Without
        // that the campaign could not tell a working guard from an unrelated headroom refusal.
        assertEq(curator.headroom(FILM), 500_000e18, "setup: full headroom");
        assertFalse(curator.custodyFreezeActive(), "setup: nothing armed, nothing unabsorbed");

        preArmHandler = new CustodyPreArmHandler(
            address(curator), admin, guardian, anchorCurator, FILM, address(new PreArmSilentGovernor())
        );
        preArmHandler.seedPreArmShapes();

        targetContract(address(preArmHandler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = CustodyPreArmHandler.guardianPreArm.selector;
        selectors[1] = CustodyPreArmHandler.governanceReplenishBudget.selector;
        selectors[2] = CustodyPreArmHandler.governanceCancelPreArm.selector;
        selectors[3] = CustodyPreArmHandler.warp.selector;
        selectors[4] = CustodyPreArmHandler.curatorWithdraw.selector;
        selectors[5] = CustodyPreArmHandler.curatorPost.selector;
        selectors[6] = CustodyPreArmHandler.retuneGovernance.selector;
        selectors[7] = CustodyPreArmHandler.pointGovernorAt.selector;
        targetSelector(FuzzSelector({addr: address(preArmHandler), selectors: selectors}));
    }

    // ─────────────────────────────────────────────────────────────────────
    //  THE STATE MACHINE
    // ─────────────────────────────────────────────────────────────────────

    /// @notice PA1. The contract's `(expiry, count)` equals the handler's INDEPENDENT model of them
    ///         at every reachable state.
    /// @dev THE WORKHORSE. Three guards live inside this one equality and every one of them is
    ///      falsified by it:
    ///        - the consecutive-episode reset: delete it and the contract's count stays at the
    ///          budget while the model resets to one;
    ///        - the `+ cooldown` term inside that reset: delete it and the contract resets at the
    ///          lapse while the model still holds the spent budget;
    ///        - `replenishCustodyPreArmBudget` not writing the expiry: add that write and the
    ///          contract's expiry drops to zero while the model keeps the standing pre-arm.
    ///      The model commits its prediction BEFORE each call's outcome is known, so the very
    ///      first divergence is reported rather than being absorbed.
    function invariant_PA1_stateMachineMatchesIndependentModel() public view {
        (uint64 expiry, uint32 count) = curator.custodyPreArm();
        assertEq(uint256(expiry), preArmHandler.mExpiry(), "F3-PA: pre-arm EXPIRY diverged from the independent model");
        assertEq(uint256(count), preArmHandler.mCount(), "F3-PA: pre-arm COUNT diverged from the independent model");
    }

    /// @notice PA2. The freeze predicate agrees with the model's pre-arm limb.
    /// @dev The model carries ONLY the guardian pre-arm. That is deliberate: this campaign never
    ///      opens a reserve incident, never moves treasury USDC and never marks principal down, so
    ///      `IReserveManager.custodyLossUnabsorbed()` must stay false throughout — and this
    ///      equality fails loudly if it does not, which would mean the campaign had wandered out of
    ///      the regime it claims to test. `invariant_PA3` pins that separately so the two failure
    ///      modes stay attributable.
    function invariant_PA2_freezeMatchesIndependentModel() public view {
        assertEq(
            curator.custodyFreezeActive(),
            preArmHandler.mPreArmActive(),
            "F3-PA: custodyFreezeActive() != the independent model of the guardian pre-arm limb"
        );
    }

    /// @notice PA3. The derived limbs stayed quiet, so PA2's equality is about the pre-arm and
    ///         nothing else.
    function invariant_PA3_derivedLimbsStayedQuiet() public view {
        assertFalse(reserves.custodyLossUnabsorbed(), "campaign wandered: a DERIVED custody limb fired");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  THE PROPERTIES THE MACHINE EXISTS FOR
    // ─────────────────────────────────────────────────────────────────────

    /// @notice PA4a. No curator withdrawal ever completed while the guardian pre-arm was live.
    ///         This is the whole purpose of the pre-arm — layer-1 capital may not leave ahead of a
    ///         loss it is CASCADE LAYER 1 for.
    function invariant_PA4a_noWithdrawalEverEscapedALivePreArm() public view {
        assertEq(
            preArmHandler.ghostFrozenWithdrawAccepted(),
            0,
            "F3-PA: a curator withdrawal completed while the guardian pre-arm was live"
        );
    }

    /// @notice PA4b. AND THE OTHER DIRECTION — the freeze is not a lock. A custody refusal while
    ///         the model says nothing is armed would mean the pre-arm outlived its own expiry with
    ///         no reachable exit, which is the brick the sibling `ReserveManager` finding is about.
    function invariant_PA4b_thePreArmAlwaysHasAReachableExit() public view {
        assertEq(
            preArmHandler.ghostUnexpectedFreeze(),
            0,
            "F3-PA: layer 1 refused while nothing was armed - the pre-arm has become a lock"
        );
    }

    /// @notice PA4c. F3-PA-d. NO governor shape ever disarms the guardian. The only refusal
    ///         `preArmCustodyFreeze` may ever produce is the budget bound.
    /// @dev Restoring the `try`/`catch` reads in `_liveGovernancePath` reds this the moment the
    ///      campaign points the module at `PreArmSilentGovernor`, which the seed guarantees.
    function invariant_PA4c_noGovernorShapeEverDisarmsTheGuardian() public view {
        assertEq(
            preArmHandler.ghostArmRefusalsOther(),
            0,
            "F3-PA-d: preArmCustodyFreeze refused for a reason other than the budget bound"
        );
    }

    /// @notice PA4d. The budget bound is exact in BOTH directions: never accepted over budget,
    ///         never refused within it.
    function invariant_PA4d_theBudgetBoundIsExact() public view {
        assertEq(preArmHandler.ghostArmsAcceptedOverBudget(), 0, "F3-PA-b: an arm was accepted over budget");
        assertEq(preArmHandler.ghostArmsRefusedWithinBudget(), 0, "F3-PA-b: an arm was refused within budget");
        (, uint32 count) = curator.custodyPreArm();
        assertLe(uint256(count), 2, "F3-PA-b: the consecutive counter exceeded its own bound");
    }

    /// @notice PA5. F3-PA-c, as a standing property across every governance parameterisation the
    ///         campaign reaches: the pre-arm strictly outlasts the path it was derived from, the
    ///         cap binds on the PATH, and the published derivation matches the model rebuilt from
    ///         the handler's own governor inputs.
    function invariant_PA5_durationAlwaysExceedsItsDerivationPath() public view {
        uint64 duration = curator.custodyPreArmDuration();
        uint64 path = curator.custodyPreArmGovernancePath();
        assertGt(duration, path, "F3-PA-c: the pre-arm stopped outlasting its own derivation path");
        assertLe(duration, curator.CUSTODY_PRE_ARM_MAX_DURATION(), "F3-PA-c: duration ceiling breached");
        assertLe(path, curator.CUSTODY_PRE_ARM_MAX_PATH(), "F3-PA-c: the cap must bind on the PATH");
        assertEq(duration, preArmHandler.mDuration(), "F3-PA-c: derivation diverged from the independent model");
        assertEq(
            curator.custodyPreArmCooldown(),
            preArmHandler.mCooldown(),
            "F3-PA-b: cooldown diverged from the independent model"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    //  ANTI-VACUITY — asserted, and it is the whole point
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Fails the campaign if the states these invariants claim to police were never
    ///         entered.
    /// @dev TWO BASES, following the house pattern.
    ///      (1) THE WIRING TOOTH — `fuzzActionEntries` increments at the top of the registered
    ///          selectors ONLY and is never touched by `seedPreArmShapes`. If a selector is missing
    ///          from `targetSelector`, or the handler is not the target contract, it is exactly
    ///          zero and the campaign FAILS even though every other counter is non-zero from the
    ///          seed.
    ///      (2) SEED-BACKED SHAPE FLOORS — forge restarts every run from the post-`setUp` state and
    ///          `afterInvariant` samples ONE run, so a single run's fuzz reach is not a safe floor
    ///          for a narrow conjunction such as "an episode that lapsed AND cooled AND was
    ///          re-armed". The seed guarantees every run was evaluated against a state where each
    ///          shape exists; everything above that floor is the campaign's own reach and is
    ///          printed rather than asserted.
    function afterInvariant() public view {
        _report();
        assertGt(preArmHandler.fuzzActionEntries(), 0, "NO FUZZ ACTION EXECUTED (targetSelector wiring broken)");
        assertGt(preArmHandler.callCount(), 0, "NO HANDLER ACTION COMPLETED");

        assertGt(preArmHandler.ghostArms(), 0, "VACUOUS: no pre-arm was ever accepted");
        assertGt(preArmHandler.ghostArmRefusalsBudget(), 0, "VACUOUS: the budget bound never fired");
        assertGt(preArmHandler.ghostEpisodeResets(), 0, "VACUOUS: no episode ever reset (F3-PA-b unexercised)");
        assertGt(
            preArmHandler.ghostReplenishesWhileProtected(),
            0,
            "VACUOUS: budget was never replenished while protection stood (F3-PA-a unexercised)"
        );
        assertGt(preArmHandler.ghostCancels(), 0, "VACUOUS: the false-alarm lever was never used");
        assertGt(
            preArmHandler.ghostArmsAgainstSilentGovernor(),
            0,
            "VACUOUS: the guardian never armed against the F3-PA-d governor shape"
        );
        assertGt(preArmHandler.ghostTruncatedArms(), 0, "VACUOUS: the truncating regime was never reached (F3-PA-c)");
        assertGt(
            preArmHandler.ghostFrozenWithdrawRefusals(), 0, "VACUOUS: no withdrawal was ever refused by the pre-arm"
        );
        assertGt(
            preArmHandler.ghostFreeWithdrawals(),
            0,
            "VACUOUS: no withdrawal ever completed - the campaign never left the frozen regime"
        );
    }

    function _report() private view {
        console2.log("--- INV_CustodyPreArm reach ---");
        console2.log("arms accepted            ", preArmHandler.ghostArms());
        console2.log("arms refused (budget)    ", preArmHandler.ghostArmRefusalsBudget());
        console2.log("arms refused (OTHER)     ", preArmHandler.ghostArmRefusalsOther());
        console2.log("episode resets           ", preArmHandler.ghostEpisodeResets());
        console2.log("truncated arms           ", preArmHandler.ghostTruncatedArms());
        console2.log("arms vs silent governor  ", preArmHandler.ghostArmsAgainstSilentGovernor());
        console2.log("replenishments           ", preArmHandler.ghostReplenishes());
        console2.log("  ...while protected     ", preArmHandler.ghostReplenishesWhileProtected());
        console2.log("cancels                  ", preArmHandler.ghostCancels());
        console2.log("withdrawals refused      ", preArmHandler.ghostFrozenWithdrawRefusals());
        console2.log("withdrawals completed    ", preArmHandler.ghostFreeWithdrawals());
        console2.log("posts                    ", preArmHandler.ghostPosts());
    }
}
