// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Vm} from "forge-std/Vm.sol";

import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {ICuratorModule} from "../../src/interfaces/ICuratorModule.sol";
import {IGovernanceSchedule, ITimelockSchedule} from "../../src/interfaces/IGovernanceSchedule.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @title AUDIT FIX F3-PA — THE GUARDIAN PRE-ARM BUDGET WAS A TRAP
/// @notice Four defects in the R6-CF1 pre-arm machinery, surfaced only once the seven independent
///         security fixes were merged. The same class was found independently in the sibling
///         `ReserveManager` pre-arm during the C-01 cascade attack: a fail-safe with no reachable
///         exit is a brick, and a freeze that self-releases with no transaction is not a freeze.
///
///   F3-PA-a (HIGH)  `cancelCustodyPreArm` was the ONLY way to replenish the guardian's pre-arm
///                   budget, and it zeroes `custodyPreArmExpiry`. Governance's "we looked, the
///                   incident is REAL, keep going" therefore DESTROYED the active protection, and
///                   a curator could be the very next transaction — taking every dollar of layer-1
///                   headroom out ahead of a loss curator capital is CASCADE LAYER 1 for.
///
///   F3-PA-b         `custodyPreArmCount` was a LIFETIME counter, so
///                   `CUSTODY_PRE_ARM_MAX_CONSECUTIVE`'s own name and NatSpec were false: two arms
///                   ANYWHERE in the protocol's life spent the guardian's emergency lever
///                   permanently, restorable only by a timelocked governance transaction — the
///                   fast lever restorable only at the speed of the slow one it exists to outrun.
///
///   F3-PA-c         `CUSTODY_PRE_ARM_MAX_DURATION = 90 days` capped the DURATION while `_capTerm`
///                   capped each of the THREE governance terms at the same 90 days. A live path of
///                   up to 270 days was summed and then silently truncated to a 90-day window,
///                   inverting the requirement stated in `custodyPreArmDuration`'s own NatSpec
///                   with no signal of any kind.
///
///   F3-PA-d         `_liveGovernancePath` read `CLOCK_MODE()` through `try`/`catch` and its own
///                   comment claimed the preceding `code.length` check made that safe. It does
///                   not: a governor with a permissive fallback answers with SUCCESS and EMPTY
///                   returndata, and Solidity does NOT catch the `abi.decode` failure that
///                   follows. `preArmCustodyFreeze()` reverted — the guardian disarmed exactly
///                   when it is needed, which is the failure the comment ruled out.
///
/// @dev THE EVIDENCE CHAIN, STATED HONESTLY. Four tests here compile unchanged against the UNFIXED
///      contract and are RED against it — they are the defect reproductions:
///        - `test_F3PA_replenishingBudgetMustNotDestroyActiveProtection`   (a)
///        - `test_F3PA_layer1CannotEscapeAnywhereInsideALongGovernancePath` (a + c, economic harm)
///        - `test_F3PA_budgetIsConsecutiveNotLifetime`                      (b)
///        - `test_F3PA_aGovernorWithASilentFallbackDoesNotDisarmTheGuardian` (d)
///      `_governanceRestoreBudget` exists so the first two CAN compile pre-fix; see its comment.
///      The remaining tests exercise APIs the fix introduces, so they cannot be red against code
///      that lacks those APIs; each names, in its own NatSpec, the source mutation that reds it.
contract Fix_F3PA_PreArmBudgetTrap is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    /// @dev Posted into a class with ZERO live exposure, so ADR-0004 subordination headroom is the
    ///      FULL pool and the only thing that can stop a withdrawal is the freeze under test.
    uint256 internal constant POSTED = 300_000e18;

    function setUp() public virtual override {
        super.setUp();
        vm.prank(admin);
        curator.setCuratorApproved(FILM, anchorCurator, true);
        _postFirstLoss(anchorCurator, FILM, POSTED);
        assertEq(curator.headroom(FILM), POSTED, "setup: full headroom (zero class exposure)");
        assertFalse(curator.custodyFreezeActive(), "setup: no custody loss in flight");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  F3-PA-a (HIGH) — replenishing budget must not destroy active protection
    // ─────────────────────────────────────────────────────────────────────

    /// @notice THE HIGH. Governance has adjudicated a custody event that is real but not yet
    ///         visible on-chain, so the guardian's pre-arm is the ONLY limb holding layer-1
    ///         capital. The guardian spends its whole budget; governance restores it so the freeze
    ///         can be carried further. Layer-1 capital must not become withdrawable for so much as
    ///         one transaction while that happens.
    /// @dev PRE-FIX RED, compiles unchanged: the only restoration lever is `cancelCustodyPreArm`,
    ///      which zeroes the expiry, so `custodyFreezeActive()` is false on the line below and the
    ///      300,000e18 withdrawal that follows SUCCEEDS — cascade layer 1 walks out ahead of the
    ///      loss it exists to absorb.
    function test_F3PA_replenishingBudgetMustNotDestroyActiveProtection() public {
        uint32 max = curator.CUSTODY_PRE_ARM_MAX_CONSECUTIVE();
        for (uint32 i = 0; i < max; ++i) {
            vm.prank(guardian);
            curator.preArmCustodyFreeze();
        }
        (uint64 expiryBefore,) = curator.custodyPreArm();
        assertTrue(curator.custodyFreezeActive(), "precondition: the pre-arm is the only live limb");

        _governanceRestoreBudget();

        (uint64 expiryAfter, uint32 countAfter) = curator.custodyPreArm();
        assertEq(expiryAfter, expiryBefore, "F3-PA-a: restoring budget must not move the pre-arm expiry");
        assertEq(countAfter, 0, "F3-PA-a: the budget must actually come back");
        assertTrue(curator.custodyFreezeActive(), "F3-PA-a: THE HIGH - protection dropped while budget was restored");

        vm.prank(anchorCurator);
        vm.expectRevert(ICuratorModule.Curator_CustodyLossFrozen.selector);
        curator.withdrawFirstLoss(FILM, POSTED);
        assertEq(curator.poolBalance(FILM), POSTED, "layer 1 must still stand behind the incident");

        // ...and the guardian really can carry the freeze on from there.
        vm.prank(guardian);
        curator.preArmCustodyFreeze();
        assertTrue(curator.custodyFreezeActive(), "the restored budget must be usable");
    }

    /// @notice CONTINUOUS COVER ACROSS A GOVERNANCE PATH LONGER THAN ONE PRE-ARM WINDOW — the
    ///         composite (a)+(c) failure, and the one that actually loses money. With a 270-day
    ///         live governance path no pre-arm window spans it, so the freeze can only be carried
    ///         by restoring budget mid-flight. Pre-fix the only restoration lever drops the freeze,
    ///         so NO sequence of transactions keeps layer-1 capital frozen for one governance
    ///         cycle.
    /// @dev PRE-FIX RED, compiles unchanged. Asserted in both forms at every step — the predicate
    ///      must be true AND the withdrawal must be refused — because a predicate-only assertion
    ///      would miss a divergence between the view and the gate.
    function test_F3PA_layer1CannotEscapeAnywhereInsideALongGovernancePath() public {
        StubGovernorF3 gov = new StubGovernorF3(90 days, 90 days, 90 days);
        vm.prank(admin);
        curator.setGovernor(address(gov));

        vm.prank(guardian);
        curator.preArmCustodyFreeze();

        uint256 deadline = block.timestamp + 270 days;
        uint256 step = 5 days;
        uint256 iterations;
        while (block.timestamp < deadline) {
            _assertLayer1Sealed("F3-PA-a/c: the freeze lapsed inside the governance path");
            vm.warp(block.timestamp + step);

            (uint64 expiry, uint32 count) = curator.custodyPreArm();
            if (uint256(expiry) <= block.timestamp + step) {
                if (count >= curator.CUSTODY_PRE_ARM_MAX_CONSECUTIVE()) {
                    _governanceRestoreBudget();
                    // THE MOMENT THE HIGH LIVES IN: between governance returning budget and the
                    // guardian re-arming. Pre-fix the freeze is off here and a curator takes the
                    // pool.
                    _assertLayer1Sealed("F3-PA-a: protection dropped at the replenishment");
                }
                vm.prank(guardian);
                curator.preArmCustodyFreeze();
            }
            require(++iterations < 200, "test loop bound");
        }
        _assertLayer1Sealed("F3-PA-a/c: the freeze lapsed at the end of the path");
        assertEq(curator.poolBalance(FILM), POSTED, "no layer-1 capital escaped the whole way through");
    }

    function test_F3PA_replenishIsGovernanceOnly() public {
        vm.prank(guardian);
        curator.preArmCustodyFreeze();
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, bytes32(0))
        );
        curator.replenishCustodyPreArmBudget();
    }

    function test_F3PA_replenishWithNothingSpentReverts() public {
        vm.prank(admin);
        vm.expectRevert(ICuratorModule.Curator_NoPreArm.selector);
        curator.replenishCustodyPreArmBudget();
    }

    /// @notice The replenish lever must NOT become a release lever. It clears budget only; every
    ///         derived limb still refuses the exit, exactly as `cancelCustodyPreArm` does.
    /// @dev Mutating `replenishCustodyPreArmBudget` to touch anything but `custodyPreArmCount`
    ///      reds this and `test_F3PA_replenishingBudgetMustNotDestroyActiveProtection`.
    function test_F3PA_replenishCannotReleaseARealCustodyFreeze() public {
        _openReserveLossIncident(61);
        vm.prank(guardian);
        curator.preArmCustodyFreeze();
        vm.prank(admin);
        curator.replenishCustodyPreArmBudget();
        assertTrue(curator.custodyFreezeActive(), "the incident limb stands on its own");

        vm.prank(admin);
        curator.cancelCustodyPreArm();
        assertTrue(curator.custodyFreezeActive(), "and neither lever can release it");
        vm.prank(anchorCurator);
        vm.expectRevert(ICuratorModule.Curator_CustodyLossFrozen.selector);
        curator.withdrawFirstLoss(FILM, 1e18);
    }

    /// @notice The replenishment is auditable as such: the event echoes the expiry it did NOT
    ///         change, so an observer can verify from logs alone that protection survived.
    function test_F3PA_replenishEmitsTheUnchangedExpiry() public {
        vm.prank(guardian);
        curator.preArmCustodyFreeze();
        vm.prank(guardian);
        curator.preArmCustodyFreeze();
        (uint64 expiry, uint32 count) = curator.custodyPreArm();

        vm.expectEmit(false, false, false, true, address(curator));
        emit ICuratorModule.CustodyFreezePreArmBudgetReplenished(count, expiry);
        vm.prank(admin);
        curator.replenishCustodyPreArmBudget();
    }

    // ─────────────────────────────────────────────────────────────────────
    //  F3-PA-b — the counter must actually be CONSECUTIVE, and still bounded
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The guardian's emergency lever must not be permanently spent. After a full episode
    ///         has lapsed and layer-1 has stood unfrozen long enough, a NEW, unrelated custody
    ///         event must be armable with no governance transaction at all.
    /// @dev PRE-FIX RED, compiles unchanged: `custodyPreArmCount` is a lifetime counter, so this
    ///      arm reverts `Curator_PreArmBudgetExhausted(3, 2)` a year later.
    function test_F3PA_budgetIsConsecutiveNotLifetime() public {
        uint32 max = curator.CUSTODY_PRE_ARM_MAX_CONSECUTIVE();
        for (uint32 i = 0; i < max; ++i) {
            vm.prank(guardian);
            curator.preArmCustodyFreeze();
        }
        vm.warp(block.timestamp + 365 days);
        assertFalse(curator.custodyFreezeActive(), "precondition: the episode has long since lapsed");

        vm.prank(guardian);
        curator.preArmCustodyFreeze();

        (, uint32 count) = curator.custodyPreArm();
        assertEq(count, 1, "F3-PA-b: a lapsed-and-cooled episode must reset the CONSECUTIVE counter");
        assertTrue(curator.custodyFreezeActive(), "and the new episode must actually freeze layer 1");
        vm.prank(anchorCurator);
        vm.expectRevert(ICuratorModule.Curator_CustodyLossFrozen.selector);
        curator.withdrawFirstLoss(FILM, 1e18);
    }

    /// @notice The reset fires exactly at `lapse + cooldown`, and emits, so the episode boundary is
    ///         reconstructable from events.
    /// @dev Deleting the reset predicate from `preArmCustodyFreeze` reds this and
    ///      `test_F3PA_budgetIsConsecutiveNotLifetime`.
    function test_F3PA_theEpisodeResetFiresAtTheCooldownBoundaryAndEmits() public {
        uint32 max = curator.CUSTODY_PRE_ARM_MAX_CONSECUTIVE();
        for (uint32 i = 0; i < max; ++i) {
            vm.prank(guardian);
            curator.preArmCustodyFreeze();
        }
        (uint64 expiry,) = curator.custodyPreArm();
        vm.warp(uint256(expiry) + uint256(curator.custodyPreArmCooldown()));

        vm.expectEmit(false, false, false, true, address(curator));
        emit ICuratorModule.CustodyFreezePreArmEpisodeReset(max, expiry);
        vm.prank(guardian);
        curator.preArmCustodyFreeze();
        (, uint32 count) = curator.custodyPreArm();
        assertEq(count, 1, "the reset must land on the boundary itself");
    }

    /// @notice THE SAFETY HALF OF THE SAME GUARD — the cooldown term. Resetting on mere lapse would
    ///         let a guardian re-arm the instant a window ended and hold a permanent freeze on
    ///         layer-1 capital with the budget still nominally spent. The unfrozen window must be
    ///         real elapsed time, and layer-1 capital must genuinely be free during it.
    /// @dev Deleting the `+ cooldown` term from the reset predicate reds THIS test: the arm at
    ///      `expiry + 1` succeeds. Deleting the whole predicate reds
    ///      `test_F3PA_budgetIsConsecutiveNotLifetime`. Both halves are therefore covered.
    function test_F3PA_theConsecutiveResetCannotHoldAContinuousFreeze() public {
        uint32 max = curator.CUSTODY_PRE_ARM_MAX_CONSECUTIVE();
        for (uint32 i = 0; i < max; ++i) {
            vm.prank(guardian);
            curator.preArmCustodyFreeze();
        }
        (uint64 expiry,) = curator.custodyPreArm();
        uint256 cooldown = uint256(curator.custodyPreArmCooldown());
        assertGt(cooldown, 0, "the cooldown must be a real window");

        uint256[3] memory probes = [uint256(expiry) + 1, uint256(expiry) + cooldown / 2, uint256(expiry) + cooldown - 1];
        for (uint256 i = 0; i < probes.length; ++i) {
            vm.warp(probes[i]);
            assertFalse(curator.custodyFreezeActive(), "the guardian pre-arm must lapse on its own");
            vm.prank(guardian);
            vm.expectRevert(
                abi.encodeWithSelector(ICuratorModule.Curator_PreArmBudgetExhausted.selector, uint32(max + 1), max)
            );
            curator.preArmCustodyFreeze();
        }
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 1e18);
        assertEq(curator.poolBalance(FILM), POSTED - 1e18, "the unfrozen window is real, not nominal");
    }

    /// @notice A partially-spent episode that lapses is still the SAME episode until the cooldown
    ///         runs: the guardian keeps its remaining budget and does not get a free reset.
    function test_F3PA_aPartiallySpentEpisodeDoesNotResetEarly() public {
        vm.prank(guardian);
        curator.preArmCustodyFreeze();
        (uint64 expiry, uint32 count) = curator.custodyPreArm();
        assertEq(count, 1, "one arm used");

        vm.warp(uint256(expiry) + 1);
        vm.prank(guardian);
        curator.preArmCustodyFreeze();
        (, uint32 spent) = curator.custodyPreArm();
        assertEq(spent, 2, "still the same episode: the second arm must consume the second unit");

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(ICuratorModule.Curator_PreArmBudgetExhausted.selector, uint32(3), 2));
        curator.preArmCustodyFreeze();
    }

    /// @notice A replenishment opens budget WITHOUT ending the episode's protection, so the arm
    ///         that follows extends the standing pre-arm rather than restarting anything.
    function test_F3PA_replenishThenArmExtendsRatherThanRestarts() public {
        vm.prank(guardian);
        curator.preArmCustodyFreeze();
        vm.prank(guardian);
        curator.preArmCustodyFreeze();
        (uint64 expiryBefore,) = curator.custodyPreArm();

        vm.prank(admin);
        curator.replenishCustodyPreArmBudget();
        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        curator.preArmCustodyFreeze();

        (uint64 expiryAfter, uint32 count) = curator.custodyPreArm();
        assertEq(count, 1, "the replenished budget starts fresh");
        assertGt(expiryAfter, expiryBefore, "and the arm EXTENDS the standing pre-arm");
        assertTrue(curator.custodyFreezeActive(), "protection never dropped");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  F3-PA-c — the duration bound must match its stated requirement
    // ─────────────────────────────────────────────────────────────────────

    /// @notice THE REQUIREMENT, AS A FUZZED PROPERTY. `custodyPreArmDuration()` must strictly
    ///         exceed the governance path it was derived from at EVERY parameterisation, and the
    ///         cap must bind on the PATH rather than on the duration.
    /// @dev Restoring the old derivation (per-term caps at `CUSTODY_PRE_ARM_MAX_DURATION`, summed,
    ///      then the SUM truncated) reds this at any parameterisation whose sum exceeds 60 days:
    ///      the path published would be 270 days against a 90-day window.
    function testFuzz_F3PA_durationStrictlyExceedsTheDerivationPath(uint256 d, uint256 p, uint256 m) public {
        StubGovernorF3 gov = new StubGovernorF3(bound(d, 0, 400 days), bound(p, 0, 400 days), bound(m, 0, 400 days));
        vm.prank(admin);
        curator.setGovernor(address(gov));

        uint64 duration = curator.custodyPreArmDuration();
        uint64 path = curator.custodyPreArmGovernancePath();
        assertGt(duration, path, "F3-PA-c: the pre-arm must outlast the path it was derived from");
        assertLe(duration, curator.CUSTODY_PRE_ARM_MAX_DURATION(), "and must respect the ceiling");
        assertLe(path, curator.CUSTODY_PRE_ARM_MAX_PATH(), "the PATH is what the cap binds on");
    }

    /// @notice The two constants must stay in the exact 3:2 relation that makes the clamp inside
    ///         `custodyPreArmDuration` provably non-binding. Editing one alone re-opens the silent
    ///         inversion, so they are pinned together here.
    function test_F3PA_theTwoCapsAreConsistentByConstruction() public view {
        assertEq(
            uint256(curator.CUSTODY_PRE_ARM_MAX_DURATION()),
            uint256(curator.CUSTODY_PRE_ARM_MAX_PATH()) * 3 / 2,
            "F3-PA-c: MAX_DURATION must be exactly 3/2 of MAX_PATH"
        );
    }

    /// @notice WHERE THE CAP GENUINELY BINDS IT MUST NOT BIND SILENTLY. A live path beyond
    ///         `CUSTODY_PRE_ARM_MAX_PATH` cannot be covered by one window — a deliberate refusal to
    ///         let a governance parameter become an unbounded lock — so the condition is reported
    ///         by a view AND emitted at the arm, and refused by `script/Validate.s.sol`.
    /// @dev Deleting the `CustodyFreezePreArmTruncated` emit reds this test.
    function test_F3PA_aBindingCapIsReportedAndEmittedNeverSilent() public {
        assertTrue(curator.custodyPreArmCoversLiveGovernancePath(), "launch parameters are comfortably covered");

        StubGovernorF3 gov = new StubGovernorF3(60 days, 60 days, 60 days); // 180-day live path
        vm.prank(admin);
        curator.setGovernor(address(gov));
        assertFalse(curator.custodyPreArmCoversLiveGovernancePath(), "F3-PA-c: the shortfall must be observable");

        vm.expectEmit(false, false, false, true, address(curator));
        emit ICuratorModule.CustodyFreezePreArmTruncated(180 days, curator.custodyPreArmDuration(), 1);
        vm.prank(guardian);
        curator.preArmCustodyFreeze();
    }

    /// @notice And in the covered regime the truncation event must NOT fire — a signal that fires
    ///         always is a signal an operator learns to ignore.
    function test_F3PA_noTruncationSignalWhenTheCapDoesNotBind() public {
        vm.recordLogs();
        vm.prank(guardian);
        curator.preArmCustodyFreeze();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != ICuratorModule.CustodyFreezePreArmTruncated.selector,
                "a covered pre-arm must not report truncation"
            );
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  F3-PA-d — a foreign governor must never disarm the guardian
    // ─────────────────────────────────────────────────────────────────────

    /// @notice THE BRICK. A governor with a permissive fallback answers `CLOCK_MODE()` with SUCCESS
    ///         and EMPTY returndata. Solidity's `try`/`catch` does NOT catch the `abi.decode`
    ///         failure that follows, so the whole call reverts.
    /// @dev PRE-FIX RED, compiles unchanged: `custodyPreArmDuration()` reverts and
    ///      `preArmCustodyFreeze()` with it — the guardian disarmed by a governance wiring choice,
    ///      exactly when a custody event needs arming. `setGovernor` accepts this address happily,
    ///      because the only thing it checks is that the address has code.
    function test_F3PA_aGovernorWithASilentFallbackDoesNotDisarmTheGuardian() public {
        uint64 baseline = curator.custodyPreArmDuration();
        SilentFallbackGovernor gov = new SilentFallbackGovernor();
        vm.prank(admin);
        curator.setGovernor(address(gov));

        assertEq(curator.custodyPreArmDuration(), baseline, "F3-PA-d: must fall back to the Config floor");
        vm.prank(guardian);
        curator.preArmCustodyFreeze();
        assertTrue(curator.custodyFreezeActive(), "F3-PA-d: the guardian must still be able to arm");
    }

    /// @notice The same brick through the OTHER reads: an honest clock but numeric getters that
    ///         answer short, over-long, empty, or point at an EOA timelock.
    /// @dev Reverting `_readUint` to a `try`/`catch` decode reds mode 0 and mode 1.
    function test_F3PA_malformedGovernanceParametersDoNotDisarmTheGuardian() public {
        uint64 baseline = curator.custodyPreArmDuration();
        for (uint256 mode = 0; mode < 4; ++mode) {
            MalformedGovernor gov = new MalformedGovernor(mode);
            vm.prank(admin);
            curator.setGovernor(address(gov));
            assertEq(curator.custodyPreArmDuration(), baseline, "F3-PA-d: malformed reads fall back to the floor");
            assertTrue(curator.custodyPreArmCoversLiveGovernancePath(), "the floor is always covered");
            vm.prank(guardian);
            curator.preArmCustodyFreeze();
            assertTrue(curator.custodyFreezeActive(), "the guardian must arm against any governor");
            vm.prank(admin);
            curator.cancelCustodyPreArm();
        }
    }

    /// @notice A governor that burns every drop of gas it is given must not take the guardian's arm
    ///         down with it.
    /// @dev THE GAS STIPEND IS THE WHOLE TEST, and it is why this is not a decorative assertion.
    ///      EIP-150 leaves the caller 1/64 of its gas when a sub-call reverts, so with a generous
    ///      transaction budget an unbounded `staticcall` looks harmless — the arm still completes
    ///      out of the 1/64 remainder. It stops being harmless when the arming transaction is
    ///      itself gas-constrained, which is the realistic shape for a guardian acting under
    ///      pressure through a multisig or a relayer. MEASURED, at the 200,000 stipend below: with
    ///      the bounds in place the arm completes (and still completes down to 140,000, so the
    ///      stipend carries 60k of headroom against gas-schedule drift); with either bound deleted
    ///      the 63/64 forward burns ~195,000 and the arm cannot finish.
    ///
    ///      THERE ARE TWO SEPARATE BOUNDS AND THIS TEST PROVES BOTH INDEPENDENTLY, because a
    ///      mutation that deletes only one must still be caught: `_clockIsTimestamp` carries one
    ///      (exercised by `GasBurningGovernor`, which burns on `CLOCK_MODE()`) and `_readUint`
    ///      carries the other (exercised by `GasBurningParamGovernor`, which answers the clock
    ///      honestly and burns on `votingDelay()`). Deleting either `{gas: GOV_READ_GAS}` reds the
    ///      corresponding half.
    function test_F3PA_aGasBurningGovernorDoesNotDisarmTheGuardian() public {
        address[2] memory burners = [address(new GasBurningGovernor()), address(new GasBurningParamGovernor())];
        for (uint256 i = 0; i < burners.length; ++i) {
            uint64 baseline = curator.custodyPreArmDuration();
            vm.prank(admin);
            curator.setGovernor(burners[i]);
            assertEq(curator.custodyPreArmDuration(), baseline, "F3-PA-d: an OOG sub-call falls back to the floor");

            vm.prank(guardian);
            (bool ok,) = address(curator).call{gas: 200_000}(abi.encodeWithSignature("preArmCustodyFreeze()"));
            assertTrue(ok, "F3-PA-d: a gas-burning governor disarmed a gas-constrained guardian");
            assertTrue(curator.custodyFreezeActive());

            vm.prank(admin);
            curator.cancelCustodyPreArm();
            vm.prank(admin);
            curator.setGovernor(address(0));
        }
    }

    /// @notice A `timelock()` word with dirty high bits used to be decoded as an `address`, which
    ///         reverts. It must now simply fail the read and fall back.
    /// @dev Restoring `abi.decode(data, (address))` here reds this test.
    function test_F3PA_aDirtyTimelockWordDoesNotDisarmTheGuardian() public {
        uint64 baseline = curator.custodyPreArmDuration();
        DirtyAddressGovernor gov = new DirtyAddressGovernor();
        vm.prank(admin);
        curator.setGovernor(address(gov));
        assertEq(curator.custodyPreArmDuration(), baseline, "F3-PA-d: a dirty address word falls back to the floor");
        vm.prank(guardian);
        curator.preArmCustodyFreeze();
        assertTrue(curator.custodyFreezeActive());
    }

    /// @notice The honest path still works: a wired, well-formed governor lengthens the pre-arm.
    ///         Without this the four negative tests above could all be satisfied by a derivation
    ///         that reads nothing at all.
    function test_F3PA_aWellFormedGovernorIsStillRead() public {
        uint64 baseline = curator.custodyPreArmDuration();
        StubGovernorF3 gov = new StubGovernorF3(5 days, 20 days, 5 days); // 30-day live path
        vm.prank(admin);
        curator.setGovernor(address(gov));
        assertEq(curator.custodyPreArmGovernancePath(), 30 days, "the live reading must be used");
        assertEq(curator.custodyPreArmDuration(), 45 days, "and the +50% margin applied");
        assertGt(curator.custodyPreArmDuration(), baseline, "a longer live path must lengthen the pre-arm");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  helpers
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Governance restores the guardian's budget by the SAFEST lever the deployed ABI offers.
    ///      THE LOW-LEVEL CALL IS DELIBERATE AND MUST NOT BE TIDIED INTO A TYPED ONE. F3-PA-a is
    ///      precisely that the safe lever DID NOT EXIST, so this helper has to be able to observe
    ///      its absence and fall through to the only lever that did — which destroys the protection
    ///      and makes every caller of this helper RED against the unfixed contract. A typed call
    ///      would fail to COMPILE instead, which proves nothing about the deployed system.
    function _governanceRestoreBudget() internal {
        vm.prank(admin);
        (bool ok,) = address(curator).call(abi.encodeWithSignature("replenishCustodyPreArmBudget()"));
        if (!ok) {
            vm.prank(admin);
            curator.cancelCustodyPreArm();
        }
    }

    /// @dev Both forms of the property at once: the predicate AND the gate.
    function _assertLayer1Sealed(string memory why) internal {
        assertTrue(curator.custodyFreezeActive(), why);
        vm.prank(anchorCurator);
        vm.expectRevert(ICuratorModule.Curator_CustodyLossFrozen.selector);
        curator.withdrawFirstLoss(FILM, 1e18);
    }
}

/// @dev Minimal governor stand-in: a source of the three live parameters, not a model of
///      governance behaviour.
contract StubGovernorF3 {
    uint256 public votingDelay;
    uint256 public votingPeriod;
    address public timelock;

    constructor(uint256 delay_, uint256 period_, uint256 minDelay_) {
        votingDelay = delay_;
        votingPeriod = period_;
        timelock = address(new StubTimelockF3(minDelay_));
    }

    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=timestamp";
    }
}

contract StubTimelockF3 {
    uint256 public getMinDelay;

    constructor(uint256 minDelay_) {
        getMinDelay = minDelay_;
    }
}

/// @dev THE F3-PA-d SHAPE. Has code, so `setGovernor` accepts it and the `code.length` check
///      passes, but every call succeeds with EMPTY returndata.
contract SilentFallbackGovernor {
    fallback() external {}
}

/// @dev Honest clock, malformed numbers, with RAW returndata under test control.
///      mode 0: `votingDelay()` answers 2 bytes. mode 1: it answers 64 bytes.
///      mode 2: `timelock()` points at an address with no code.
///      mode 3: `getMinDelay()` answers nothing at all.
contract MalformedGovernor {
    uint256 private immutable MODE;

    constructor(uint256 mode_) {
        MODE = mode_;
    }

    fallback() external {
        uint256 mode = MODE;
        bytes4 sel = msg.sig;
        if (sel == IGovernanceSchedule.CLOCK_MODE.selector) {
            _ret(abi.encode(string("mode=timestamp")));
        } else if (sel == IGovernanceSchedule.timelock.selector) {
            _ret(abi.encode(mode == 2 ? address(0xBEEF) : address(this)));
        } else if (sel == ITimelockSchedule.getMinDelay.selector) {
            if (mode == 3) _ret("");
            _ret(abi.encode(uint256(2 days)));
        } else if (sel == IGovernanceSchedule.votingDelay.selector) {
            if (mode == 0) _ret(hex"0000");
            if (mode == 1) _ret(abi.encode(uint256(1 days), uint256(7)));
            _ret(abi.encode(uint256(1 days)));
        }
        _ret(abi.encode(uint256(7 days))); // votingPeriod() and anything else
    }

    function _ret(bytes memory out) private pure {
        assembly {
            return(add(out, 0x20), mload(out))
        }
    }
}

/// @dev Shared gas sink. One million keccaks is ~1e9 gas: far beyond `GOV_READ_GAS` and beyond any
///      realistic 63/64 forward, so the burn always exhausts whatever it is handed.
abstract contract GasSink {
    uint256 public sink;

    function _burn() internal view {
        uint256 x = sink;
        for (uint256 i = 0; i < 1_000_000; ++i) {
            x = uint256(keccak256(abi.encode(x)));
        }
        require(x != 0, "unreachable");
    }
}

/// @dev Burns on the CLOCK read — exercises `_clockIsTimestamp`'s gas bound.
contract GasBurningGovernor is GasSink {
    function CLOCK_MODE() external view returns (string memory) {
        _burn();
        return "mode=timestamp";
    }
}

/// @dev HONEST clock, burning PARAMETER read — exercises `_readUint`'s gas bound, which is a
///      separate `{gas: GOV_READ_GAS}` site and must therefore be proved separately.
contract GasBurningParamGovernor is GasSink {
    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=timestamp";
    }

    function votingDelay() external view returns (uint256) {
        _burn();
        return 1 days;
    }
}

/// @dev `timelock()` returns a 32-byte word with dirty high bits — `abi.decode(.., (address))`
///      reverts on it, a raw range check does not.
contract DirtyAddressGovernor {
    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=timestamp";
    }

    function votingDelay() external pure returns (uint256) {
        return 1 days;
    }

    function votingPeriod() external pure returns (uint256) {
        return 7 days;
    }

    function timelock() external pure returns (bytes32) {
        return bytes32(type(uint256).max);
    }
}
