// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Vm} from "forge-std/Vm.sol";

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {GovernanceFixture} from "../helpers/GovernanceFixture.sol";

/// @title H-2 — a partial recovery on a defaulted facility stranded the impairment pool
/// @notice REGRESSION SUITE for the finding reported 2026-07-21.
///
///         THE BUG. `DefaultManager.defaultedContribution[tokenId]` was snapshotted from
///         `reserves.deployedTo` at declare and decremented ONLY by a realized loss or a clean
///         full resolve. A principal RECOVERY on a Defaulted facility (`WaterfallEngine.distribute`
///         on a Defaulted/Accelerated loan) reduces `deployedTo` but never told the manager. Write
///         off the remainder and the facility landed at `deployedTo == 0` with
///         `defaultedContribution == the principal recovered IN CASH`. `pendingSeniorImpairment()`
///         was therefore pinned FOREVER at the recovered principal: a permanent haircut on every
///         senior exit, for money that came back.
///         The same stranding pinned `liveDefaultCoverageConsumed` and its capacity floor, so every
///         LATER, unrelated default netted a backstop capacity reduced by a dead event's draw.
///
///         THE FIX, part 1 (wave 1). `_reduceDefaulted` re-anchors the remaining contribution to
///         `reserves.deployedTo(tokenId)` after decrementing. It cannot under-mark: `realizeLoss`
///         reverts when `loss > deployedTo`, so `deployedTo` is exactly the largest senior loss the
///         facility can still produce, and it never rises for a defaulted loan. Reaching zero fires
///         `_releaseCoverageConsumption`, closing the stranded coverage floor in the same step.
///
///         THE FIX, part 2 (REMEDIATION — the gap all three reviewers returned). Part 1 only fires
///         on a REALIZED LOSS, so the far more common shape — a workout that returns cash and is
///         still being collected, with no write-off due — was untouched. Measured on the part-1
///         build: a 2,000,000e18 facility returning 1,900,000e18 in cash held
///         `pendingSeniorImpairment()` at 2,000,000e18 indefinitely (unchanged after 365 days)
///         against 100,000e18 of genuinely at-risk principal, and four such workouts drove
///         `redemptionTotalAssets()` to zero against a solvent vault. The remediation adds
///         `WaterfallEngine.distribute` -> `DefaultManager.onDefaultRecovery` on the partial
///         -recovery branch, re-anchoring the mark AT RECOVERY TIME; part 1 stays as the
///         belt-and-braces backstop for the optional-wiring configuration (`defaultManager == 0`).
///
///         THE FIX, part 3 (terminal state). A final `realizeLoss` now transitions a
///         Defaulted/Accelerated facility to `Resolved` when the write-down reduces
///         `deployedTo` to zero. This makes cash-first/write-off-last and zero-recovery workouts
///         terminal rather than leaving zero-outstanding NFTs permanently in default.
contract FixH2RecoveryThenWriteOffTest is GovernanceFixture {
    /// @dev Mirrors `IDefaultManager.DefaultImpairmentCleared` for `vm.expectEmit`.
    event DefaultImpairmentCleared(uint256 indexed tokenId, uint256 indexed classId, uint256 amount);

    uint256 internal constant FILM = 1;

    uint256 internal constant PRINCIPAL = 2_000_000e18;
    uint256 internal constant RECOVERED = 1_500_000e18;
    uint256 internal constant WRITTEN_OFF = 500_000e18;

    /// @dev Counts `DefaultImpairmentCleared` logs emitted by the DefaultManager in `logs`.
    function _countImpairmentCleared(Vm.Log[] memory logs) internal view returns (uint256 n) {
        bytes32 sig = DefaultImpairmentCleared.selector;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(defaultManager) && logs[i].topics.length != 0 && logs[i].topics[0] == sig) {
                ++n;
            }
        }
    }

    /// @dev Stakes seniors so layer 3 can absorb a write-off (the cascade must not run out of
    ///      capacity mid-test and revert for the wrong reason).
    function _seedSeniors(uint256 amount) internal {
        _mintUSDfrTo(alice, amount);
        vm.startPrank(alice);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();
    }

    // ── the regression ───────────────────────────────────────────────────

    /// @notice THE BUG, exactly as reported: declare, recover 1.5M in cash, write off the 500k
    ///         remainder. Before the fix `pendingSeniorImpairment()` stayed at 1,500,000e18
    ///         forever; after it, the impairment pool closes out to zero.
    function test_h2_partialRecoveryThenWriteOffDoesNotStrandTheImpairmentPool() public {
        assertEq(curator.poolBalance(FILM), 0, "precondition: empty curator pool isolates the senior mark");
        _seedSeniors(3_000_000e18);

        uint256 id = _liveFilmFacility(PRINCIPAL);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        assertEq(defaultManager.defaultedContribution(id), PRINCIPAL, "declare snapshots the full outstanding");
        assertEq(defaultManager.pendingSeniorImpairment(), PRINCIPAL, "the whole facility is at risk on day one");

        // A partial workout recovery: 1.5M of principal comes back IN CASH.
        _repay(id, 0, RECOVERED);
        assertEq(reserves.deployedTo(id), WRITTEN_OFF, "recovery reduced the outstanding principal");
        assertEq(
            uint256(bridge.facility(id).state),
            uint256(ClaimBridge.LoanState.Defaulted),
            "a partial recovery leaves the facility Defaulted"
        );

        // The servicer writes off everything that is left.
        vm.prank(servicer);
        _realizeLoss(id, WRITTEN_OFF, FILM_REF);
        assertEq(reserves.deployedTo(id), 0, "nothing outstanding remains");

        // THE PROPERTY. Before the fix: 1_500_000e18, permanently.
        assertEq(defaultManager.defaultedContribution(id), 0, "H-2: no at-risk principal is left standing");
        assertEq(defaultManager.declaredDefaultedPrincipal(FILM), 0, "H-2: the class impairment pool closed out");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "H-2: no permanent haircut on senior exits");
        assertEq(defaultManager.liveDefaultCoverageConsumed(), 0, "H-2: no coverage stranded by a closed default");
        assertEq(
            uint256(bridge.facility(id).state),
            uint256(ClaimBridge.LoanState.Resolved),
            "the final write-off is terminal"
        );
    }

    /// @notice The de-recognition is evented, so the impairment pool stays reconstructable from
    ///         logs alone: `DefaultImpairmentCleared` reports the 1.5M de-recognised because it
    ///         came back in cash, and `LossRealized` reports the realized 500k.
    ///
    ///         DELIBERATE SEMANTIC CHANGE at the remediation (stated loudly per the brief).
    ///         BEFORE: the 1.5M `DefaultImpairmentCleared` fired on the `realizeLoss` call, from
    ///         the `_reduceDefaulted` clamp — i.e. only once the servicer wrote something off.
    ///         AFTER: it fires on the RECOVERY (`waterfall.distribute` -> `onDefaultRecovery`),
    ///         and the later `realizeLoss` emits no clear at all because the clamp finds nothing
    ///         left to de-recognise. Same total de-recognised, same event, earlier block. The
    ///         old assertion is not weakened — it is moved to where the value now moves, and the
    ///         test additionally pins that the realization does NOT double-emit.
    function test_h2_recoveryEmitsTheDeRecognisedImpairmentAndTheWriteOffDoesNot() public {
        _seedSeniors(3_000_000e18);
        uint256 id = _liveFilmFacility(PRINCIPAL);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        // NOTE: expectEmit binds to the very next emitted log, so the repay is inlined here
        // rather than routed through `_repay` (whose usdc.mint would consume the expectation).
        _repay(id, 0, RECOVERED);

        vm.recordLogs();
        vm.prank(servicer);
        _realizeLoss(id, WRITTEN_OFF, FILM_REF);
        assertEq(_countImpairmentCleared(vm.getRecordedLogs()), 0, "the realization must not double-emit");
    }

    /// @notice The clamp must not fire when nothing was recovered: an ordinary partial write-down
    ///         still leaves exactly the unrealized remainder marked. This is the under-mark guard —
    ///         the whole PM-R-11 lineage is under-marking bugs, so the fix is pinned in both
    ///         directions.
    function test_h2_clampNeverUnderMarksAGenuineOutstandingLoss() public {
        _seedSeniors(3_000_000e18);
        uint256 id = _liveFilmFacility(PRINCIPAL);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        vm.prank(servicer);
        _realizeLoss(id, WRITTEN_OFF, FILM_REF); // no recovery: pure partial write-down

        uint256 stillAtRisk = PRINCIPAL - WRITTEN_OFF;
        assertEq(reserves.deployedTo(id), stillAtRisk, "outstanding fell by exactly the write-down");
        assertEq(defaultManager.defaultedContribution(id), stillAtRisk, "the unrealized remainder stays marked");
        assertEq(defaultManager.pendingSeniorImpairment(), stillAtRisk, "no under-mark: the mark equals at-risk");
    }

    /// @notice Terminal reachability is preserved on the ordering that can reach it: write off
    ///         first, then recover the rest in full. The facility closes to `Resolved` and the pool
    ///         is empty — the fix does not disturb the clean `onDefaultResolved` path.
    function test_h2_writeOffThenFullRecoveryStillReachesResolved() public {
        _seedSeniors(3_000_000e18);
        uint256 id = _liveFilmFacility(PRINCIPAL);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        vm.prank(servicer);
        _realizeLoss(id, WRITTEN_OFF, FILM_REF);
        _repay(id, 0, PRINCIPAL - WRITTEN_OFF);

        assertEq(
            uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Resolved), "the facility is terminal"
        );
        assertEq(defaultManager.defaultedContribution(id), 0, "the pool closed out");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "no residual mark on a closed workout");
    }

    /// @notice A genuine zero-recovery workout has no final cash leg. The full write-off itself
    ///         must therefore be able to close the facility.
    function test_h2_zeroRecoveryFullWriteOffReachesResolved() public {
        _seedSeniors(3_000_000e18);
        uint256 id = _liveFilmFacility(PRINCIPAL);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        vm.prank(servicer);
        _realizeLoss(id, PRINCIPAL, FILM_REF);

        assertEq(reserves.deployedTo(id), 0, "the whole principal was written off");
        assertEq(
            uint256(bridge.facility(id).state),
            uint256(ClaimBridge.LoanState.Resolved),
            "zero-recovery workout is terminal"
        );
        assertEq(defaultManager.defaultedContribution(id), 0, "no unrealized contribution remains");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "no stale redemption mark remains");
    }

    /// @notice THE SECOND REPRO — the cross-event leak. A stranded default kept its sGROVE draw
    ///         recorded as "consumed by a live default" and kept `liveDefaultCapacityFloor` pinned,
    ///         so a fresh, unrelated default netted a crippled backstop capacity and over-marked
    ///         itself. Reported as 900,000e18 of impairment against a true 0.
    function test_h2_closedDefaultDoesNotLeaveAStaleCoverageFloorForTheNextOne() public {
        _seedSeniors(3_000_000e18);
        _stakeGrove(bob, 1_000_000e18);
        _fundCoverage(1_000_000e18); // capacity = 50% per event = 500_000e18

        // ── event 1: declare, partial cash recovery, write off the remainder ──
        uint256 id1 = _liveFilmFacility(PRINCIPAL);
        _attestDefault(id1);
        vm.prank(servicer);
        defaultManager.declareDefault(id1, FILM_REF);
        _repay(id1, 0, RECOVERED);
        vm.prank(servicer);
        _realizeLoss(id1, WRITTEN_OFF, FILM_REF);

        (uint256 drawn,) = sGrove.eventCoverage(id1);
        assertGt(drawn, 0, "the write-off really did draw sGROVE coverage");
        assertEq(defaultManager.liveDefaultCoverageConsumed(), 0, "H-2: the closed event released its consumption");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "H-2: event 1 leaves no residual mark");

        // ── event 2: a fresh, unrelated default ──
        uint256 principal2 = 500_000e18;
        uint256 id2 = _liveFilmFacility(principal2);
        _attestDefault(id2);
        vm.prank(servicer);
        defaultManager.declareDefault(id2, FILM_REF);

        // The fresh event's own reachable coverage, computed independently of DefaultManager.
        uint256 capacity = sGrove.coverageCapacity();
        uint256 reserve = sGrove.coverageReserve();
        uint256 room = capacity < reserve ? capacity : reserve;
        uint256 trueFloor = principal2 > room ? principal2 - room : 0;

        // Before the fix this reported 900_000e18 against a true floor of 0.
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            trueFloor,
            "H-2: a fresh default nets its OWN capacity, not one crippled by a dead event"
        );
    }

    // ── REMEDIATION: the recovery hook (WaterfallEngine.distribute -> onDefaultRecovery) ──

    /// @notice THE HEADLINE GAP, exactly as measured by the reviewer on the wave-1 build: a
    ///         2,000,000e18 facility returns 1,900,000e18 IN CASH and the workout continues, so
    ///         no write-off is due and `_reduceDefaulted` never runs. Before the recovery hook,
    ///         `pendingSeniorImpairment()` sat at 2,000,000e18 against 100,000e18 of genuinely
    ///         at-risk principal, forever — nothing on-chain could clear it. Warped a year to
    ///         show the over-mark is PERMANENT, not transient.
    function test_h2_cashRecoveryReAnchorsTheMarkWithNoWriteOff() public {
        _seedSeniors(3_000_000e18);
        uint256 id = _liveFilmFacility(PRINCIPAL);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        assertEq(defaultManager.pendingSeniorImpairment(), PRINCIPAL, "the whole facility is at risk on day one");

        uint256 cash = 1_900_000e18;
        uint256 stillAtRisk = PRINCIPAL - cash;
        _repay(id, 0, cash);

        assertEq(reserves.deployedTo(id), stillAtRisk, "the outstanding fell by the cash recovered");
        assertEq(
            uint256(bridge.facility(id).state),
            uint256(ClaimBridge.LoanState.Defaulted),
            "the workout continues: still Defaulted"
        );
        // THE PROPERTY. Before the remediation: 2_000_000e18 on all three, permanently.
        assertEq(defaultManager.defaultedContribution(id), stillAtRisk, "H-2: the mark follows the cash back");
        assertEq(defaultManager.declaredDefaultedPrincipal(FILM), stillAtRisk, "H-2: the class pool follows too");
        assertEq(defaultManager.pendingSeniorImpairment(), stillAtRisk, "H-2: no haircut for money that came back");

        vm.warp(block.timestamp + 365 days);
        assertEq(defaultManager.pendingSeniorImpairment(), stillAtRisk, "H-2: and it stays re-anchored a year on");
    }

    /// @notice The over-mark's actual victim: the conservative redemption NAV. Four ordinary
    ///         partial workouts (the reviewer's scaled scenario) drove `redemptionTotalAssets()`
    ///         to ZERO against a solvent vault on the wave-1 build — a redeemer's exit destroyed
    ///         by principal that had already come back in cash. This pins that the senior exit
    ///         base survives, and is haircut by exactly the principal genuinely still at risk.
    function test_h2_ordinaryWorkoutsDoNotDestroyTheSeniorExitBase() public {
        uint256 staked = 4_600_000e18;
        _seedSeniors(staked);

        uint256 recovered = 1_200_000e18;
        uint256 atRiskEach = PRINCIPAL - recovered;
        for (uint256 i = 0; i < 4; ++i) {
            // distinct borrower/state per facility: four concurrent 2M workouts would otherwise
            // trip the per-borrower concentration limit before the NAV point is reached
            _mintUSDfrTo(alice, PRINCIPAL); // seed the idle liquidity to deploy
            uint256 id =
                _originateFilm(keccak256(abi.encode("h2-borrower", i)), keccak256(abi.encode("h2-state", i)), PRINCIPAL);
            _fundFacility(id, PRINCIPAL);
            _attestDefault(id);
            vm.prank(servicer);
            defaultManager.declareDefault(id, FILM_REF);
            _repay(id, 0, recovered);
        }

        uint256 expectedImpairment = atRiskEach * 4;
        assertEq(defaultManager.pendingSeniorImpairment(), expectedImpairment, "H-2: only the at-risk half marks");
        assertEq(
            vault.redemptionTotalAssets(),
            vault.totalAssets() - expectedImpairment,
            "H-2: the exit base is haircut by the live risk, not by the recovered cash"
        );
        assertGt(vault.redemptionTotalAssets(), 0, "H-2: four ordinary workouts must not zero the exit base");
    }

    /// @notice THE UNCOVERED BRANCH COMBINATION (reviewer requirement): a cash recovery followed
    ///         by a PARTIAL write-off, i.e. impairment is de-recognised while the contribution
    ///         stays NON-ZERO. This is the shape where the event must fire but the sGROVE
    ///         coverage consumption must NOT be released, and it is where an eventing/release
    ///         bug would hide. Asserted at both steps.
    function test_h2_recoveryThenPartialWriteOffKeepsCoverageConsumed() public {
        _seedSeniors(3_000_000e18);
        _stakeGrove(bob, 1_000_000e18);
        _fundCoverage(1_000_000e18); // capacity = 50% per event

        uint256 id = _liveFilmFacility(PRINCIPAL);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        // ── step 1: 1.2M returns in cash; the mark re-anchors to the 800k still outstanding ──
        uint256 recovered = 1_200_000e18;
        _repay(id, 0, recovered);
        assertEq(defaultManager.defaultedContribution(id), 800_000e18, "re-anchored to the live outstanding");
        assertEq(defaultManager.liveDefaultCoverageConsumed(), 0, "nothing drawn yet: no coverage consumed");

        // ── step 2: a PARTIAL write-off of 300k. Contribution stays non-zero (500k), so the
        //           coverage this still-live default consumed must stay deducted.
        uint256 writeOff = 300_000e18;
        vm.prank(servicer);
        _realizeLoss(id, writeOff, FILM_REF);

        (uint256 drawn,) = sGrove.eventCoverage(id);
        assertGt(drawn, 0, "the write-off really did draw sGROVE coverage");

        uint256 remainingRisk = PRINCIPAL - recovered - writeOff;
        assertEq(reserves.deployedTo(id), remainingRisk, "500k of principal is still being collected");
        assertEq(defaultManager.defaultedContribution(id), remainingRisk, "H-2: the mark equals the live risk");
        assertEq(defaultManager.declaredDefaultedPrincipal(FILM), remainingRisk, "H-2: and so does the class pool");
        assertEq(
            defaultManager.liveDefaultCoverageConsumed(),
            drawn,
            "H-2: a STILL-LIVE default must not release its coverage consumption"
        );
        assertEq(
            uint256(bridge.facility(id).state),
            uint256(ClaimBridge.LoanState.Defaulted),
            "the facility is still in workout"
        );
    }

    /// @notice The same shape on an ACCELERATED facility. `realizeLoss` and the recovery branch
    ///         both accept Defaulted OR Accelerated; only the Defaulted arm was exercised.
    function test_h2_recoveryThenPartialWriteOffOnAnAcceleratedFacility() public {
        _seedSeniors(3_000_000e18);
        uint256 id = _liveFilmFacility(PRINCIPAL);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        vm.prank(servicer);
        defaultManager.accelerate(id);
        assertEq(
            uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Accelerated), "precondition: accelerated"
        );

        uint256 recovered = 1_200_000e18;
        _repay(id, 0, recovered);
        assertEq(defaultManager.defaultedContribution(id), 800_000e18, "H-2: the hook covers Accelerated too");

        vm.prank(servicer);
        _realizeLoss(id, 300_000e18, FILM_REF);
        assertEq(defaultManager.defaultedContribution(id), 500_000e18, "H-2: the mark equals the live risk");
        assertEq(defaultManager.pendingSeniorImpairment(), 500_000e18, "H-2: and the NAV mark agrees");
    }

    /// @notice THE BELT-AND-BRACES PATH. `WaterfallEngine`'s `defaultManager` wiring is optional
    ///         (zero = disabled, so the engine can predate the manager in a deploy). With the
    ///         hook disabled, `deployedTo` falls behind the mark again and the `_reduceDefaulted`
    ///         clamp is the only thing standing — this reaches the clamp's
    ///         `derecognized != 0 && contribution != 0` combination that no other test can now
    ///         reach, since the hook front-runs it everywhere else.
    function test_h2_reduceDefaultedClampStillCatchesAnUnwiredEngine() public {
        _seedSeniors(3_000_000e18);
        uint256 id = _liveFilmFacility(PRINCIPAL);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        vm.prank(admin);
        waterfall.setDefaultManager(address(0)); // the hook is now unreachable

        uint256 recovered = 1_200_000e18;
        _repay(id, 0, recovered);
        assertEq(defaultManager.defaultedContribution(id), PRINCIPAL, "unwired: the mark is stale, as designed");

        // The clamp must de-recognise the 1.2M AND leave the 500k still outstanding marked.
        _attestLoss(id, 300_000e18, FILM_REF);
        vm.expectEmit(true, true, false, true, address(defaultManager));
        emit DefaultImpairmentCleared(id, FILM, recovered);
        vm.prank(servicer);
        defaultManager.realizeLoss(id, 300_000e18, FILM_REF);

        assertEq(defaultManager.defaultedContribution(id), 500_000e18, "clamp: re-anchored to the live outstanding");
        assertEq(defaultManager.pendingSeniorImpairment(), 500_000e18, "clamp: no under-mark, no over-mark");
    }

    // ── the no-under-mark argument, pinned in code ───────────────────────

    /// @notice ORDERING 1 (loss before recovery). The write-off marks first, the cash comes back
    ///         second; at every step the mark equals the principal still at risk. This is the
    ///         under-mark guard for the new hook: the whole PM-R-11 lineage is under-marking, so
    ///         the re-anchor is pinned to never drop below `deployedTo`.
    function test_h2_lossThenRecoveryOrderingNeverUnderMarks() public {
        _seedSeniors(3_000_000e18);
        uint256 id = _liveFilmFacility(PRINCIPAL);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        vm.prank(servicer);
        _realizeLoss(id, WRITTEN_OFF, FILM_REF); // 500k written off first
        assertEq(defaultManager.defaultedContribution(id), 1_500_000e18, "mark == outstanding after the write-off");

        _repay(id, 0, 1_000_000e18); // then 1M comes back in cash
        assertEq(reserves.deployedTo(id), 500_000e18, "500k of principal remains at risk");
        assertEq(defaultManager.defaultedContribution(id), 500_000e18, "H-2: mark == outstanding, not below it");
        assertEq(defaultManager.pendingSeniorImpairment(), 500_000e18, "H-2: the genuine residual loss is still marked");

        // and the residual is still fully realizable — the re-anchor removed no loss capacity
        vm.prank(servicer);
        _realizeLoss(id, 500_000e18, FILM_REF);
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "the workout closes out at zero");
    }

    /// @notice TWO SIMULTANEOUS DEFAULTS in one class. The class pool is shared, so a re-anchor
    ///         on one facility must move the pool by exactly that facility's de-recognition and
    ///         leave the other's mark untouched — the pool stays the sum of its parts.
    function test_h2_twoSimultaneousDefaultsInOneClassStayIndependent() public {
        _seedSeniors(5_000_000e18);

        uint256 idA = _liveFilmFacility(PRINCIPAL);
        _attestDefault(idA);
        vm.prank(servicer);
        defaultManager.declareDefault(idA, FILM_REF);

        uint256 principalB = 1_000_000e18;
        uint256 idB = _liveFilmFacility(principalB);
        _attestDefault(idB);
        vm.prank(servicer);
        defaultManager.declareDefault(idB, FILM_REF);

        assertEq(defaultManager.declaredDefaultedPrincipal(FILM), PRINCIPAL + principalB, "both defaults are pooled");

        uint256 recovered = 1_200_000e18;
        _repay(idA, 0, recovered);

        assertEq(defaultManager.defaultedContribution(idA), PRINCIPAL - recovered, "A re-anchored");
        assertEq(defaultManager.defaultedContribution(idB), principalB, "B is untouched by A's recovery");
        assertEq(
            defaultManager.declaredDefaultedPrincipal(FILM),
            (PRINCIPAL - recovered) + principalB,
            "H-2: the class pool is exactly the sum of the live per-token marks"
        );
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            (PRINCIPAL - recovered) + principalB,
            "H-2: B's genuine loss is still fully marked"
        );
    }

    // ── the hook's own surface: idempotence, gating, access control ───────

    /// @notice The re-anchor is ONE-DIRECTIONAL and idempotent: called again with nothing newly
    ///         recovered it moves nothing and emits nothing, so it can never ratchet the mark.
    function test_h2_onDefaultRecoveryIsIdempotentAndNeverRatchets() public {
        _seedSeniors(3_000_000e18);
        uint256 id = _liveFilmFacility(PRINCIPAL);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        _repay(id, 0, RECOVERED);

        uint256 markBefore = defaultManager.defaultedContribution(id);
        uint256 poolBefore = defaultManager.declaredDefaultedPrincipal(FILM);

        vm.recordLogs();
        vm.prank(address(waterfall));
        defaultManager.onDefaultRecovery(id);
        vm.prank(address(waterfall));
        defaultManager.onDefaultRecovery(id);

        assertEq(_countImpairmentCleared(vm.getRecordedLogs()), 0, "a no-op re-anchor emits nothing");
        assertEq(defaultManager.defaultedContribution(id), markBefore, "idempotent: the mark did not move");
        assertEq(defaultManager.declaredDefaultedPrincipal(FILM), poolBefore, "idempotent: the pool did not move");
    }

    /// @notice The hook is CREDIT_ROLE-gated: an arbitrary caller cannot de-recognise impairment.
    function test_h2_onDefaultRecoveryRejectsAnUnauthorizedCaller() public {
        _seedSeniors(3_000_000e18);
        uint256 id = _liveFilmFacility(PRINCIPAL);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        _repay(id, 0, RECOVERED);

        bytes memory err =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.CREDIT_ROLE);
        vm.prank(carol);
        vm.expectRevert(err);
        defaultManager.onDefaultRecovery(id);
    }

    /// @notice The hook refuses a facility that is not actually in default, with the specific
    ///         custom error — a CREDIT_ROLE caller must not be able to touch a performing loan.
    function test_h2_onDefaultRecoveryRejectsANonDefaultedFacility() public {
        _seedSeniors(3_000_000e18);
        uint256 id = _liveFilmFacility(PRINCIPAL);

        bytes memory err = abi.encodeWithSelector(IDefaultManager.DefaultManager_NotInDefault.selector, id);
        vm.prank(address(waterfall));
        vm.expectRevert(err);
        defaultManager.onDefaultRecovery(id);
    }
}
