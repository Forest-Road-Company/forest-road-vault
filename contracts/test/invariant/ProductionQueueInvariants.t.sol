// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Config} from "../../src/libraries/Config.sol";
import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {MockImpairmentSource} from "../helpers/MockImpairmentSource.sol";
import {AuditQueueHandler} from "./handlers/AuditQueueHandler.sol";

/// @title INV_RedemptionQueue — Phase D invariant suite for INV-11..INV-14
/// @notice Independent-auditor suite derived from `audit/SYSTEM_MODEL.md` §6, NOT from the
///         contract's own NatSpec. The queue is the only exit from sUSDfr (the vault admits
///         `RedemptionQueue` as its sole withdraw/redeem caller), so every property here is a
///         property about whether senior holders can get out.
///
///         - INV-11 (queue solvency) — a settlement never distributes more than the budget
///           SNAPSHOTTED at its open, and never more USDfr than the vault actually held. The
///           snapshot is reconstructed from this suite's own idle-stable ledger; the contract's
///           `availableLiquidity()` / `settlementBudgetRemaining()` are never used as the
///           expected value. The budget is also asserted to EXCLUDE the reserve-instrument mark
///           (`ReserveManager.deployedPrincipal`), under stateful traffic that moves both.
///         - INV-12 (FIFO) — fills land on the audit's own ordered ghost head, ids strictly
///           increase within a chunk, and no request is ever touched while an earlier one is
///           unfilled. Exercised across CHUNKED settlements, which is the only place an
///           ordering defect can appear.
///         - INV-13 (no double claim) — cumulative claimed per request, measured as the
///           claimant's balance delta, never exceeds the amount the event stream says was
///           filled; and a second claim in the same block always finds nothing.
///         - INV-14 (queue liveness) — no reachable state permanently prevents `closeEpoch`
///           from making progress. Progress is encoded concretely: the epoch counter advances,
///           or the heartbeat advances, or the settlement paid out. The precondition under
///           which progress is REQUIRED is computed before every attempt.
///
///         Plus the time/epoch row Phase C left outstanding: the 21-day cooldown is never
///         bypassed; a keeper gap of 1, 10 or 100 missed runs still settles CORRECTLY (no
///         accrued budget, no epoch catch-up, no clock drift, no ordering distortion); and a
///         request landing exactly at `epochEndsAt` is handled consistently.
///
///         SCOPE BOUNDARY: reserve-loss writes are covered by the atomic loss-absorption and
///         cascade families, not this queue campaign. Queue liquidity actions here are backing
///         neutral or backing raising, which keeps the model focused on exit accounting.
contract INV_RedemptionQueue is CreditLayerFixture {
    AuditQueueHandler internal handler;
    MockImpairmentSource internal impairmentSource;

    function setUp() public override {
        super.setUp();

        // Drive the conservative (ADR-0022) exit mark directly. The production wrapper needs a
        // whole default lifecycle per step, which a stateful campaign cannot afford.
        impairmentSource = new MockImpairmentSource();
        vm.prank(admin);
        vault.setImpairmentSource(address(impairmentSource));

        handler = new AuditQueueHandler(
            AuditQueueHandler.Wiring({
                usdc: usdc,
                usdfr: usdfr,
                compliance: compliance,
                reserves: reserves,
                controller: controller,
                vault: vault,
                queue: queue,
                impairment: impairmentSource,
                complianceAdmin: complianceAdmin
            })
        );
        // Stands in for the credit layer, exactly as `creditModule` does in TokenLayerFixture:
        // the handler needs to move stable liquidity into and out of the reserve-instrument
        // mark so the budget-exclusion property has something to exclude.
        vm.prank(admin);
        reserves.grantRole(Roles.CREDIT_ROLE, address(handler));
        // D7-01: the handler is the modeled off-chain settlement keeper. Granting the role here
        // keeps authorization outside the production queue logic while ensuring the mandatory
        // invariant tier still reaches every settlement branch it claims to exercise.
        vm.prank(admin);
        queue.grantRole(Roles.SETTLEMENT_KEEPER_ROLE, address(handler));

        handler.seedFixture();

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = AuditQueueHandler.depositToVault.selector;
        selectors[1] = AuditQueueHandler.requestExit.selector;
        selectors[2] = AuditQueueHandler.settleAfterWarp.selector;
        selectors[3] = AuditQueueHandler.settleNow.selector;
        selectors[4] = AuditQueueHandler.claimRequest.selector;
        selectors[5] = AuditQueueHandler.addStableLiquidity.selector;
        selectors[6] = AuditQueueHandler.drainStableLiquidity.selector;
        selectors[7] = AuditQueueHandler.deployPrincipal.selector;
        selectors[8] = AuditQueueHandler.repayPrincipal.selector;
        selectors[9] = AuditQueueHandler.setImpairment.selector;
        selectors[10] = AuditQueueHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ── ghost integrity (declared first: a ghost defect must be diagnosed as one) ──

    /// @notice The audit's independent ledger must track the protocol exactly. Without this the
    ///         INV-11 budget ghost would be an unfalsifiable guess.
    function invariant_A_auditLedgerReconcilesWithTheProtocol() public view {
        assertEq(handler.gIdleUnits(), reserves.idleUSDC(), "IDLE-STABLE LEDGER DIVERGED");
        assertEq(handler.gDeployedValue(), reserves.deployedPrincipal(), "RESERVE-INSTRUMENT MARK LEDGER DIVERGED");
        assertEq(handler.gEpoch(), queue.currentEpoch(), "EPOCH LEDGER DIVERGED");
        assertEq(handler.requestCount(), queue.totalRequests(), "REQUEST LEDGER LENGTH DIVERGED");
        assertEq(handler.gHead(), queue.head(), "FIFO HEAD LEDGER DIVERGED");
        assertEq(queue.totalQueuedShares(), handler.sumOutstandingShares(), "QUEUED SHARES != SUM OF OPEN REQUESTS");
        assertEq(vault.balanceOf(address(queue)), queue.totalQueuedShares(), "SHARE CUSTODY DRIFTED");
        assertEq(usdfr.balanceOf(address(queue)), handler.sumUnclaimedAssets(), "ASSET CUSTODY != UNCLAIMED FILLS");
        assertFalse(handler.sawAccountingMismatch(), "THE REGISTER IS NOT RECONSTRUCTABLE FROM EVENTS");
        _assertPerRequestLedger();
    }

    // ── INV-11: queue solvency ───────────────────────────────────────────

    /// @notice INV-11. A settlement never distributes more than the budget snapshotted at its
    ///         open, and never more than the USDfr actually available in the vault.
    /// @dev The bound is this suite's own snapshot ghost, captured from its own idle-stable
    ///      ledger at the instant the settlement opened. It is never re-read from the queue.
    function invariant_INV11_settlementNeverExceedsItsSnapshotBudget() public view {
        assertFalse(handler.sawOverDistribution(), "INV-11 VIOLATED: a settlement outspent its snapshot budget");
        assertLe(
            handler.gSettlementDistributed(),
            handler.gSnapshotBudget(),
            "INV-11 VIOLATED: live settlement total exceeds the ghost snapshot"
        );
    }

    /// @notice INV-11 (exclusion half). The budget is drawn from STABLE liquidity only; the
    ///         reserve-instrument mark is a valuation, not cash, and must never fund an exit.
    /// @dev The expected value carries no `deployedPrincipal` term at all. The campaign drives
    ///      idle and the mark in both directions (`deployPrincipal` / `repayPrincipal`), so a
    ///      regression that let the mark leak into the budget fails here under traffic.
    function invariant_INV11_budgetExcludesTheReserveInstrumentMark() public view {
        assertEq(
            queue.availableLiquidity(),
            handler.expectedAvailableLiquidity(),
            "INV-11 VIOLATED: the settlement budget is not stable liquidity alone"
        );
    }

    // ── INV-12: FIFO ─────────────────────────────────────────────────────

    /// @notice INV-12. Requests settle in strictly increasing request-id order and no request is
    ///         skipped while an earlier one is unfilled.
    /// @dev Two independent statements. The flag is the fill-time check against the audit's own
    ///      ordered ghost list (parsed from `RequestFilled`); the loop below re-states the
    ///      property directly against the contract's storage, so neither can hide the other.
    function invariant_INV12_fifoNeverInverts() public view {
        assertFalse(handler.sawFifoViolation(), "INV-12 VIOLATED: a fill did not land on the FIFO head");
        uint256 n = queue.totalRequests();
        for (uint256 j = 0; j < n; ++j) {
            if (!_isTouched(j)) continue;
            for (uint256 i = 0; i < j; ++i) {
                (, uint256 remainingI,,,) = queue.request(i);
                assertEq(remainingI, 0, "INV-12 VIOLATED: a later request settled ahead of an earlier one");
            }
        }
    }

    // ── INV-13: no double claim ──────────────────────────────────────────

    /// @notice INV-13. Each request's claimable amount is claimable exactly once.
    /// @dev Cumulative claimed is measured as the owner's USDfr balance delta and is checked
    ///      against the amount the EVENT STREAM says was filled, not against the contract's
    ///      `assetsClaimable` field. Every claim is followed immediately by a second attempt in
    ///      the same block, which must revert `Queue_NothingClaimable`.
    function invariant_INV13_noDoubleClaim() public view {
        assertFalse(handler.sawDoubleClaim(), "INV-13 VIOLATED: a request paid out more than it was filled");
        uint256 n = handler.requestCount();
        uint256 filledTotal;
        uint256 claimedTotal;
        for (uint256 i = 0; i < n; ++i) {
            (,,, uint256 filled, uint256 claimed) = handler.ghostRequest(i);
            assertLe(claimed, filled, "INV-13 VIOLATED: cumulative claimed exceeds cumulative filled");
            filledTotal += filled;
            claimedTotal += claimed;
        }
        assertEq(
            filledTotal, claimedTotal + handler.sumUnclaimedAssets(), "INV-13 VIOLATED: FILLED != CLAIMED + CLAIMABLE"
        );
    }

    // ── INV-14: queue liveness ───────────────────────────────────────────

    /// @notice INV-14. No reachable state permanently prevents `closeEpoch` from making
    ///         progress. Progress is `currentEpoch` advancing, or `epochEndsAt` advancing, or a
    ///         settlement paying out; it is required whenever the attempt was admissible and
    ///         either the queue was drained (which cannot reach the A1 abandon branch at all) or
    ///         the head was past its hold and its budget-capped fill priced at or above the
    ///         settlement's captured economic floor.
    function invariant_INV14_closeEpochAlwaysProgressesWhenItCan() public view {
        assertFalse(
            handler.sawLivenessViolation(),
            "INV-14 VIOLATED: closeEpoch refused to progress from a state in which it must (see livenessReason)"
        );
    }

    // ── time / epoch row (Phase C left this outstanding) ─────────────────

    /// @notice ADR-0022. The 21-day forced hold and the minimum-hold semantics are never
    ///         bypassed, at any keeper cadence.
    /// @dev `redeemCooldown` is deliberately absent from the action set, so this is a statement
    ///      about the SHIPPED parameter and not about whatever governance last wrote.
    function invariant_cooldownAndMinimumHoldAreNeverBypassed() public view {
        assertFalse(handler.sawCooldownBypass(), "A REQUEST SETTLED INSIDE ITS FORCED HOLD");
        assertGe(
            handler.minObservedHoldSeconds(),
            uint256(Config.DEFAULT_REDEEM_COOLDOWN),
            "A REQUEST SETTLED BEFORE THE 21-DAY COOLDOWN ELAPSED"
        );
    }

    /// @notice Keeper liveness. A long gap must not distort the clock: an epoch close advances
    ///         the counter by exactly one and re-arms the heartbeat from NOW, never catching up
    ///         the missed epochs. The companion budget half is INV-11 (the budget is a share of
    ///         CURRENT liquidity and never accrues over the gap).
    function invariant_epochClockNeverDriftsOrCatchesUp() public view {
        if (handler.sawEpochDrift()) {
            console2.log("drift kind (1=epoch counter, 2=heartbeat)", handler.driftKind());
            console2.log("expected", handler.driftExpected(), "actual", handler.driftActual());
            console2.log("at timestamp", handler.driftAt());
        }
        assertFalse(handler.sawEpochDrift(), "AN EPOCH CLOSE DRIFTED OR CAUGHT UP MISSED EPOCHS");
    }

    /// @notice AUDIT C-1, restated against this suite's independent ghost stream. A settlement
    ///         may never burn a position for zero USDfr; the position must stay queued instead.
    /// @dev Kept even though the repo suite states a version of this, because the INV-12
    ///      ordering ghost consumes the same event stream and would otherwise silently absorb a
    ///      zero-value fill as a legitimate head advance.
    function invariant_settlementNeverBurnsAPositionForZeroAssets() public view {
        assertFalse(handler.sawZeroValueFill(), "A POSITION WAS BURNED FOR ZERO ASSETS");
    }

    // ── anti-vacuity ─────────────────────────────────────────────────────

    /// @notice Proves the campaign actually reached the states these properties are about.
    ///         A green run that never queued, never filled, never closed an epoch, never
    ///         chunked a settlement and never paid a claim is worse than no campaign.
    function afterInvariant() public view {
        _logWitnesses();
        // Only judge FULL-LENGTH sequences. Foundry runs `afterInvariant` during SHRINKING too,
        // and a "this never happened" assertion is satisfied by every truncated sequence — so
        // without this guard the shrinker would latch onto the vacuity check as its failure
        // predicate, collapse any real counterexample to two or three calls, and report the
        // wrong cause. Measured at the default depth of 128 (heavy: 256); the guard is well
        // below both, so every campaign run is judged and only shrink probes are exempt.
        if (handler.callCount() < 64) return;
        assertGt(handler.requestsCreated(), 0, "VACUOUS: no request was ever queued");
        assertGt(handler.fillsObserved(), 0, "VACUOUS: no settlement ever filled a request");
        assertGt(handler.epochsClosed(), 0, "VACUOUS: no epoch ever closed");
        assertGt(handler.claimsMade(), 0, "VACUOUS: no claim was ever paid");
        assertGt(handler.settlementChunksPaid(), 0, "VACUOUS: no settlement ever paid out");
        assertGt(handler.settlementsWithLiveMark(), 0, "VACUOUS: no settlement ran against a live instrument mark");
        assertLt(handler.minObservedHoldSeconds(), type(uint256).max, "VACUOUS: no fill ever cleared a real hold");
        // INV-14 specifically: a liveness property whose precondition never held proves nothing.
        // At least one attempt in this run must have carried an actual obligation to progress.
        assertGt(
            handler.livenessObligationsPayable(),
            0,
            "VACUOUS INV-14: closeEpoch was never obliged to pay a payable head"
        );
    }

    /// @notice Measured reach witnesses, surfaced in the run output. Not asserted here (the
    ///         asserted set is `afterInvariant`), because a given sequence may legitimately
    ///         never line up impairment + cooldown + heartbeat + liquidity for every one of them.
    /// @dev `chunkContinuations` is DELIBERATELY measured rather than asserted per run.
    ///      Chunking is central to INV-12 and is exercised heavily (2..12 continuations in every
    ///      sampled run), but a latch requires the head to fill FULLY with requests still behind
    ///      it, and an adversarial liquidity sequence can leave every fill partial for a whole
    ///      128-call run — measured at roughly 1 run in 256. That is a property of the random
    ///      sequence, not of the protocol, and a flaky gate in a permanently-kept CI suite is a
    ///      liability. The chunked path is instead asserted DETERMINISTICALLY in
    ///      `test_antiVacuity_everyAssertedWitnessIsDeterministicallyReachable`, which fails
    ///      loudly if chunking ever stops working.
    function invariant_callSummary() public view {
        handler.callCount();
        handler.requestsCreated();
        handler.fillsObserved();
        handler.partialFills();
        handler.epochsClosed();
        handler.claimsMade();
        handler.settlementChunksPaid();
        handler.chunkContinuations();
        handler.settlementsWithLiveMark();
        handler.settlementsUnderImpairment();
        handler.loudStops();
        handler.noLiquidityStops();
        handler.cooldownStops();
        handler.epochNotOverStops();
        handler.maxAttemptsSinceProgress();
        handler.longestKeeperGapSeconds();
        handler.livenessReason();
        handler.livenessObligationsDrained();
        handler.livenessObligationsPayable();
        handler.maxBudgetUtilisationBps();
        handler.heartbeatBurnedAgainstLargeBook();
    }

    // ── deterministic companions ─────────────────────────────────────────

    /// @notice Anti-vacuity, deterministically. Drives the handler through every witness the
    ///         `afterInvariant` set asserts, so their reachability is proven without relying on
    ///         a random sequence lining up.
    function test_antiVacuity_everyAssertedWitnessIsDeterministicallyReachable() public {
        handler.settleAfterWarp(1); // 3 chunks at maxRequests == 1: fills + latch + close
        handler.claimRequest(0);
        handler.settleAfterWarp(2);
        assertGt(handler.requestsCreated(), 0, "no request queued");
        assertGt(handler.fillsObserved(), 0, "no fill");
        assertGt(handler.epochsClosed(), 0, "no epoch closed");
        assertGt(handler.claimsMade(), 0, "no claim");
        assertGt(handler.chunkContinuations(), 0, "no chunked settlement");
        assertGt(handler.settlementsWithLiveMark(), 0, "no settlement against a live mark");
        assertLt(handler.minObservedHoldSeconds(), type(uint256).max, "no real hold cleared");
        assertFalse(handler.sawLivenessViolation(), "liveness violated on the deterministic drive");
        assertFalse(handler.sawOverDistribution(), "over-distribution on the deterministic drive");
        assertFalse(handler.sawFifoViolation(), "FIFO violated on the deterministic drive");
        assertFalse(handler.sawDoubleClaim(), "double claim on the deterministic drive");
    }

    /// @notice Keeper liveness, 1 missed run.
    function test_keeperGap_1MissedRunStillSettlesCorrectly() public {
        _assertKeeperGapSettlesCorrectly(1);
    }

    /// @notice Keeper liveness, 10 missed runs.
    function test_keeperGap_10MissedRunsStillSettleCorrectly() public {
        _assertKeeperGapSettlesCorrectly(10);
    }

    /// @notice Keeper liveness, 100 missed runs. A 100-day outage must not accrue 100 epochs of
    ///         exit capacity, must not advance the counter 100 steps, and must not reorder or
    ///         shorten anyone's hold.
    function test_keeperGap_100MissedRunsStillSettleCorrectly() public {
        _assertKeeperGapSettlesCorrectly(100);
    }

    /// @notice Epoch boundary. A request landing at exactly `epochEndsAt` is handled
    ///         consistently: the close at that same instant is admissible (the guard is
    ///         strictly `<`), the joiner queues strictly behind the tail, and it carries the
    ///         full forced hold from that instant rather than settling in the epoch it joined.
    function test_epochBoundary_requestAtExactlyEpochEndsAtIsHandledConsistently() public {
        // settle the seeded book down to a single open request so the boundary case is clean
        queue.closeEpoch(10);

        uint64 endsAt = queue.epochEndsAt();
        vm.warp(uint256(endsAt));
        assertEq(block.timestamp, uint256(endsAt), "warp did not land on the boundary");

        uint256 idBefore = queue.totalRequests();
        address joiner = alice;
        _mintUSDfrTo(joiner, 10_000e18);
        vm.startPrank(joiner);
        usdfr.approve(address(vault), 10_000e18);
        uint256 shares = vault.deposit(10_000e18, joiner);
        vault.approve(address(queue), shares);
        uint256 joinerId = queue.requestRedeem(shares);
        vm.stopPrank();

        assertEq(joinerId, idBefore, "boundary joiner did not queue strictly behind the tail");
        assertEq(
            queue.eligibleToSettleAt(joinerId),
            uint256(endsAt) + uint256(queue.redeemCooldown()),
            "boundary joiner did not receive the full forced hold"
        );

        // The close at exactly `epochEndsAt` is admissible: the guard is `block.timestamp <
        // epochEndsAt`, so it must NOT revert Queue_EpochNotOver here.
        (, uint256 remainingBefore,,,) = queue.request(joinerId);
        queue.closeEpoch(10);
        (, uint256 remainingAfter, uint256 claimableAfter,,) = queue.request(joinerId);
        assertEq(remainingAfter, remainingBefore, "the boundary joiner settled inside its own hold");
        assertEq(claimableAfter, 0, "the boundary joiner was credited inside its own hold");

        // and one second earlier the guard does fire, with the exact deadline
        uint64 nextEndsAt = queue.epochEndsAt();
        vm.warp(uint256(nextEndsAt) - 1);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_EpochNotOver.selector, nextEndsAt));
        queue.closeEpoch(10);
    }

    /// @notice C-11. Raising `minRedemptionValue` while a settlement is latched open must not
    ///         retroactively judge that settlement against the new floor — the frozen budget can
    ///         only shrink, so a retroactive floor would be the RC-01 dead end reached through a
    ///         governance setter.
    function test_c11_raisingTheFloorMidSettlementCannotStrandTheFrozenBudget() public {
        // open a settlement and latch it (maxRequests == 1 with more than one open request)
        queue.closeEpoch(1);
        assertTrue(queue.isSettling(), "settlement did not latch");

        vm.prank(admin);
        queue.setMinRedemptionValue(100e18); // the hard maximum

        // the latched settlement must still be able to finish
        queue.closeEpoch(10);
        assertFalse(queue.isSettling(), "a latched settlement was stranded by a mid-flight floor rise");
        assertEq(queue.currentEpoch(), handler.gEpoch() + 1, "the latched settlement did not close its epoch");
    }

    // ── helpers ──────────────────────────────────────────────────────────

    function _assertKeeperGapSettlesCorrectly(uint256 missedRuns) internal {
        (uint64 duration, uint16 bps) = queue.epochParams();
        vm.warp(block.timestamp + missedRuns * uint256(duration));

        uint256 expectedBudget = Math.mulDiv(reserves.idleReserve(), bps, Config.BPS);
        uint256 epochBefore = queue.currentEpoch();
        uint256 queueBalBefore = usdfr.balanceOf(address(queue));
        uint256 headBefore = queue.head();

        queue.closeEpoch(10);

        uint256 distributed = usdfr.balanceOf(address(queue)) - queueBalBefore;
        assertGt(distributed, 0, "a keeper gap left the queue unable to settle at all");
        assertLe(distributed, expectedBudget, "a keeper gap ACCRUED exit capacity across missed epochs");
        assertEq(queue.currentEpoch(), epochBefore + 1, "a keeper gap advanced the epoch counter more than once");
        assertEq(
            uint256(queue.epochEndsAt()),
            block.timestamp + uint256(duration),
            "the heartbeat did not re-arm from now after the gap"
        );

        // ordering and holds survive the gap: everything before the new head is fully filled,
        // and nothing settled inside its 21-day hold
        uint256 headAfter = queue.head();
        assertGe(headAfter, headBefore, "the head moved backwards");
        for (uint256 i = 0; i < headAfter; ++i) {
            (, uint256 remaining,,, uint256 requestedAt) = queue.request(i);
            assertEq(remaining, 0, "a request before the head was left unfilled after the gap");
            assertGe(
                block.timestamp - requestedAt,
                uint256(Config.DEFAULT_REDEEM_COOLDOWN),
                "a keeper gap let a request settle inside its forced hold"
            );
        }

        // and the credit is claimable exactly once
        (address owner0,, uint256 claimable0,,) = queue.request(0);
        if (claimable0 != 0) {
            uint256 balBefore = usdfr.balanceOf(owner0);
            vm.prank(owner0);
            queue.claim(0);
            assertEq(usdfr.balanceOf(owner0) - balBefore, claimable0, "claim after a keeper gap paid the wrong amount");
            vm.prank(owner0);
            vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NothingClaimable.selector, uint256(0)));
            queue.claim(0);
        }
    }

    function _assertPerRequestLedger() internal view {
        uint256 n = handler.requestCount();
        for (uint256 i = 0; i < n; ++i) {
            (, uint256 remaining, uint256 claimable,,) = queue.request(i);
            (, uint256 requested, uint256 filledShares, uint256 filledAssets, uint256 claimed) = handler.ghostRequest(i);
            assertEq(remaining, requested - filledShares, "PER-REQUEST SHARE LEDGER DIVERGED FROM THE EVENT STREAM");
            assertEq(claimable, filledAssets - claimed, "PER-REQUEST ASSET LEDGER DIVERGED FROM THE EVENT STREAM");
        }
    }

    /// @dev Surfaces one run's reach witnesses in the run output, so "the campaign reached the
    ///      interesting states" is a MEASURED claim and not an inference from a green tick.
    function _logWitnesses() internal view {
        console2.log("handler calls", handler.callCount());
        console2.log("requests queued", handler.requestsCreated());
        console2.log("fills", handler.fillsObserved(), "partial", handler.partialFills());
        console2.log("epochs closed", handler.epochsClosed(), "claims", handler.claimsMade());
        console2.log("paid chunks", handler.settlementChunksPaid(), "chunk continuations", handler.chunkContinuations());
        console2.log(
            "paid with live mark",
            handler.settlementsWithLiveMark(),
            "paid under impairment",
            handler.settlementsUnderImpairment()
        );
        console2.log("stops loud", handler.loudStops(), "noLiquidity", handler.noLiquidityStops());
        console2.log("stops cooldown", handler.cooldownStops(), "epochNotOver", handler.epochNotOverStops());
        console2.log(
            "max attempts without progress",
            handler.maxAttemptsSinceProgress(),
            "longest keeper gap (s)",
            handler.longestKeeperGapSeconds()
        );
        console2.log("min observed hold (s)", handler.minObservedHoldSeconds());
        console2.log(
            "INV-14 obligations: drained",
            handler.livenessObligationsDrained(),
            "payable-head",
            handler.livenessObligationsPayable()
        );
        console2.log("INV-11 peak budget utilisation (bps)", handler.maxBudgetUtilisationBps());
        console2.log("D-04 shape: heartbeats burned against a >=100x book", handler.heartbeatBurnedAgainstLargeBook());
    }

    function _isTouched(uint256 id) internal view returns (bool) {
        (, uint256 remaining, uint256 claimable,,) = queue.request(id);
        (, uint256 requested,,, uint256 claimed) = handler.ghostRequest(id);
        return remaining < requested || claimable != 0 || claimed != 0;
    }
}
