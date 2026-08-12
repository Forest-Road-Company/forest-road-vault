// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ComplianceRegistry} from "../../../src/ComplianceRegistry.sol";
import {IRedemptionQueue} from "../../../src/interfaces/IRedemptionQueue.sol";
import {MintRedeemController} from "../../../src/MintRedeemController.sol";
import {RedemptionQueue} from "../../../src/RedemptionQueue.sol";
import {ReserveManager} from "../../../src/ReserveManager.sol";
import {SUSDfr} from "../../../src/sUSDfr.sol";
import {USDfr} from "../../../src/USDfr.sol";
import {Config} from "../../../src/libraries/Config.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {MockImpairmentSource} from "../../helpers/MockImpairmentSource.sol";

/// @title AuditQueueHandler — Phase D handler for the audit's own RedemptionQueue model
/// @notice INDEPENDENT-GHOST handler for INV-11..INV-14 of `audit/SYSTEM_MODEL.md` §6.
///
///         DESIGN RULE (audit protocol, Phase D): every expected quantity in this handler is
///         reconstructed from (a) the arguments THIS handler passed in and (b) the contract's
///         own EVENT STREAM — never by re-reading the accounting variable under test. In
///         particular:
///           - the settlement budget ghost is derived from `gIdleUnits`, which this handler
///             maintains itself from every mint / redeem / deployment / repayment it drives.
///             It is never copied from `queue.availableLiquidity()` or
///             `queue.settlementBudgetRemaining()`. `_reconcileGhosts()` asserts the ghost
///             against `ReserveManager` on every action, so a divergence is itself a failure.
///           - fills are read from `RequestFilled` logs and folded into a per-request ledger
///             that is compared against `queue.request(...)` by the top-level invariants —
///             i.e. the register must be reconstructable purely from events (CLAUDE.md §3.1).
///           - claims are measured as the claimant's USDfr balance delta, not as the return
///             value of `claim()`.
///
///         `fail_on_revert = true`: every entrypoint is bounded so it cannot revert. The four
///         documented `closeEpoch` abandons are caught with a low-level call and classified;
///         any other selector is a handler bug or a finding and fails loudly.
///
///         DELIBERATE EXCLUSIONS (reported in the slot return value):
///           - reserve-loss writes are exercised by the atomic loss-absorption and cascade
///             families. Every reserve write here is backing-neutral (`recordDeployment`) or
///             backing-raising (`recordPayment`) so the queue model remains independently scoped.
///           - `setRedeemCooldown` is NOT in the action set, so `redeemCooldown` stays at the
///             shipped 21 days and `minObservedHoldSeconds >= 21 days` is a real assertion
///             rather than a restatement of whatever governance last set.
contract AuditQueueHandler is Test {
    // ── wiring ───────────────────────────────────────────────────────────

    struct Wiring {
        MockERC20 usdc;
        USDfr usdfr;
        ComplianceRegistry compliance;
        ReserveManager reserves;
        MintRedeemController controller;
        SUSDfr vault;
        RedemptionQueue queue;
        MockImpairmentSource impairment;
        address complianceAdmin;
    }

    MockERC20 internal usdc;
    USDfr internal usdfr;
    ReserveManager internal reserves;
    MintRedeemController internal controller;
    SUSDfr internal vault;
    RedemptionQueue internal queue;
    MockImpairmentSource internal impairment;

    address[3] public actors;
    address internal facilitySink;

    /// @dev The single synthetic facility this handler deploys principal into, so the
    ///      reserve-instrument mark (`ReserveManager.deployedPrincipal`) is non-zero while the
    ///      queue settles. The budget must EXCLUDE it; see `invariant_INV11_*`.
    uint256 internal constant FACILITY_ID = 1;

    /// @dev The floor `repayPrincipal` leaves standing on the reserve-instrument mark. See the
    ///      note on `repayPrincipal`.
    uint256 internal constant MARK_FLOOR = 250_000e18;

    bytes32 private constant FILLED_SIG = keccak256("RequestFilled(uint256,uint256,uint256,uint256)");
    bytes32 private constant CLOSED_SIG = keccak256("EpochClosed(uint256,uint256,uint256,uint64)");

    // ── independent ghost state ──────────────────────────────────────────

    struct GhostRequest {
        address owner;
        uint64 requestedAt;
        uint256 requestedShares;
        uint256 filledShares;
        uint256 filledAssets;
        uint256 claimedAssets;
    }

    GhostRequest[] internal g; // dense: index == requestId (this handler is the sole requester)

    /// @notice My own model of the FIFO head: the lowest id that is not fully filled.
    uint256 public gHead;

    /// @notice My own model of `ReserveManager.idleUSDCUnits` (6-dec USDC units).
    uint256 public gIdleUnits;
    /// @notice My own model of `ReserveManager.totalDeployedPrincipal` (18-dec) — the mark.
    uint256 public gDeployedValue;

    /// @notice My own model of `currentEpoch`.
    uint256 public gEpoch;
    bool public gSettling;
    /// @notice Budget ghost captured from MY idle ghost at the instant the settlement opened.
    uint256 public gSnapshotBudget;
    uint256 public gSettlementDistributed;
    /// @notice C-11 `settlementMinValue` has no getter; ghosted at settlement open.
    uint256 public gSettlementMinValue;

    // ── violation flags (read by the named invariants; deliberately NOT asserted here, so
    //    each property fails under its own name with its own message) ──────
    bool public sawOverDistribution; // INV-11
    bool public sawFifoViolation; // INV-12
    bool public sawDoubleClaim; // INV-13
    bool public sawLivenessViolation; // INV-14
    uint8 public livenessReason; // 1 = drained queue did not close; 2 = payable head not paid
    bool public sawCooldownBypass; // ADR-0022 forced hold
    bool public sawEpochDrift; // keeper-gap correctness
    uint8 public driftKind; // 1 = epoch counter, 2 = heartbeat re-arm
    uint256 public driftExpected;
    uint256 public driftActual;
    uint256 public driftAt;
    bool public sawAccountingMismatch; // event totals vs my ghost totals
    bool public sawZeroValueFill; // C-1: never burn a position for nothing

    // ── measured witnesses (anti-vacuity) ────────────────────────────────
    uint256 public callCount;
    uint256 public requestsCreated;
    uint256 public fillsObserved;
    uint256 public partialFills;
    uint256 public epochsClosed;
    uint256 public claimsMade;
    uint256 public settlementChunksPaid;
    uint256 public chunkContinuations; // closeEpoch calls that resumed a latched settlement
    uint256 public settlementsWithLiveMark; // paid chunks while deployedPrincipal > 0
    uint256 public settlementsUnderImpairment; // paid chunks while conservative NAV < realized
    /// @dev MEASURED CORROBORATION OF FINDING D-04 (heartbeat buy-out), not an asserted
    ///      property. Counts epoch closes that consumed the settlement heartbeat while paying
    ///      out less than 1% of the conservative value of the book still queued behind them.
    ///      INV-14 as written in `audit/SYSTEM_MODEL.md` §6 is a PROGRESS property and is fully
    ///      satisfied by exactly this state, which is why it cannot catch D-04; the number below
    ///      shows the shape arises spontaneously under random traffic, not only under the
    ///      hand-built attack.
    uint256 public heartbeatBurnedAgainstLargeBook;
    uint256 public loudStops; // Queue_HeadNotRedeemable
    uint256 public noLiquidityStops; // Queue_NoLiquidity
    uint256 public cooldownStops; // Queue_AllInCooldown
    uint256 public epochNotOverStops; // Queue_EpochNotOver
    uint256 public minObservedHoldSeconds = type(uint256).max;
    uint256 public attemptsSinceProgress;
    uint256 public maxAttemptsSinceProgress;
    uint256 public longestKeeperGapSeconds;
    /// @dev INV-14 anti-vacuity. A liveness property whose PRECONDITION never held proves
    ///      nothing. These count the attempts at which progress was actually OBLIGATORY, split
    ///      by which half of the precondition supplied the obligation.
    uint256 public livenessObligationsDrained; // admissible close of an empty queue
    uint256 public livenessObligationsPayable; // eligible head, budget buys a fill above the floor
    /// @dev INV-11 tightness. The highest fraction of a settlement's snapshot budget that was
    ///      actually spent, in bps. A bound that is never approached is a weak bound.
    uint256 public maxBudgetUtilisationBps;

    // ── memory carriers (stack budget) ───────────────────────────────────

    struct CloseState {
        bool wasSettling;
        bool drained;
        bool progressExpected;
        bool obligationIsDrained;
        uint64 endsAtBefore;
        uint256 epochBefore;
        uint256 queueBalBefore;
        uint256 vaultBalBefore;
        uint256 snapshotBudget;
        uint256 minValue;
    }

    struct ChunkResult {
        uint256 distributed;
        bool closed;
        uint256 closedEpoch;
        uint256 closedBudget;
        uint256 closedDistributed;
        uint256 nextEndsAt;
    }

    constructor(Wiring memory w) {
        usdc = w.usdc;
        usdfr = w.usdfr;
        reserves = w.reserves;
        controller = w.controller;
        vault = w.vault;
        queue = w.queue;
        impairment = w.impairment;
        actors[0] = makeAddr("auditQueueActor0");
        actors[1] = makeAddr("auditQueueActor1");
        actors[2] = makeAddr("auditQueueActor2");
        facilitySink = makeAddr("auditFacilitySink");
        vm.startPrank(w.complianceAdmin);
        for (uint256 i = 0; i < 3; ++i) {
            w.compliance.setAllowed(actors[i], true);
        }
        vm.stopPrank();
        gEpoch = queue.currentEpoch();
        gIdleUnits = reserves.idleUSDC();
        gDeployedValue = reserves.deployedPrincipal();
    }

    // ── deterministic seed (NOT a fuzz selector) ─────────────────────────

    /// @notice Puts the fixture into the state the INV-11..14 properties are about, so every
    ///         invariant run starts from a queue that is actually usable: funded treasury, a
    ///         non-zero reserve-instrument mark, three live requests past their 21-day hold.
    /// @dev Called once from the suite's `setUp`. Deliberately excluded from `targetSelector`.
    function seedFixture() external {
        _addLiquidity(actors[0], 4_000_000e6);
        _addLiquidity(actors[1], 3_000_000e6);
        _deposit(actors[0], 1_500_000e18);
        _deposit(actors[1], 1_200_000e18);
        // a live reserve-instrument mark: idle -> deployed, backing-neutral
        _deploy(2_000_000e6);
        // A DEEP book of requests that are individually small against one epoch's budget
        // (~83.5k USDfr on this treasury). Depth plus small heads is what makes the RC-01 LATCH
        // reachable: a head that fills FULLY with another request behind it latches the
        // settlement open, and the next `closeEpoch` is then a continuation CHUNK.
        _queueRequest(actors[0], 6_000e24);
        _queueRequest(actors[1], 9_000e24);
        _queueRequest(actors[0], 12_000e24);
        _queueRequest(actors[1], 15_000e24);
        _queueRequest(actors[0], 20_000e24);
        _queueRequest(actors[1], 25_000e24);
        // clear the ADR-0022 forced hold on the seeded requests
        vm.warp(block.timestamp + uint256(queue.redeemCooldown()) + 1);
    }

    // ── fuzz actions ─────────────────────────────────────────────────────

    /// @notice Mint USDfr and deposit it into the vault (raises idle liquidity AND vault NAV).
    function depositToVault(uint256 actorSeed, uint256 usdcAmount) external {
        _reconcileGhosts();
        address actor = actors[actorSeed % 3];
        usdcAmount = bound(usdcAmount, 1_000e6, 500_000e6);
        _addLiquidity(actor, usdcAmount);
        if (vault.maxDeposit(actor) < usdcAmount * 1e12) {
            callCount++;
            return; // degenerate share price: entry is closed by design (R15-01)
        }
        _deposit(actor, usdcAmount * 1e12);
        callCount++;
    }

    /// @notice Join the redemption queue (the sole sUSDfr exit).
    function requestExit(uint256 actorSeed, uint256 shares) external {
        _reconcileGhosts();
        address actor = actors[actorSeed % 3];
        uint256 bal = vault.balanceOf(actor);
        if (bal == 0) {
            callCount++;
            return;
        }
        uint256 floorAssets = queue.minRedemptionValue();
        uint256 minShares = floorAssets == 0 ? 1 : vault.previewWithdraw(floorAssets);
        if (minShares == 0) minShares = 1;
        if (bal < minShares) {
            callCount++;
            return;
        }
        // Cap the request BELOW one epoch's budget on the seeded treasury (~83.5k USDfr).
        // Unbounded requests always exceed one epoch's throughput, so every fill would be
        // partial, the head would never turn over, and the CHUNKED multi-request settlement
        // path that INV-12 most needs would be starved. Partial fills stay abundantly
        // reachable anyway, because `drainStableLiquidity` and `deployPrincipal` routinely
        // shrink the budget far below this cap.
        uint256 cap = bal < 40_000e24 ? bal : 40_000e24;
        if (cap < minShares) cap = minShares;
        _queueRequest(actor, bound(shares, minShares, cap));
        callCount++;
    }

    /// @notice Keeper settlement: warp to the earliest instant settlement is admissible, then
    ///         drive up to three CHUNKS of the same settlement. Chunking is deliberate — a FIFO
    ///         or budget-carry defect only shows up across chunk boundaries.
    function settleAfterWarp(uint256 maxRequests) external {
        _reconcileGhosts();
        if (!queue.isSettling()) {
            uint256 target = block.timestamp;
            uint64 endsAt = queue.epochEndsAt();
            if (endsAt > target) target = endsAt;
            if (gHead < g.length) {
                uint256 eligibleAt = uint256(g[gHead].requestedAt) + queue.redeemCooldown();
                if (eligibleAt > target) target = eligibleAt;
            }
            if (target > block.timestamp) {
                if (target - block.timestamp > longestKeeperGapSeconds) {
                    longestKeeperGapSeconds = target - block.timestamp;
                }
                vm.warp(target);
            }
        }
        // The FIRST chunk is deliberately `maxRequests == 1`. With more than one outstanding
        // request that forces the RC-01 latch, so the rest of this action runs as CONTINUATION
        // chunks of the same settlement — the only place a FIFO or budget-carry defect can
        // present. Single-chunk settlements at fuzzed widths are covered by `settleNow`.
        uint256 chunkSize = bound(maxRequests, 1, 3);
        for (uint256 i = 0; i < 3; ++i) {
            if (!_closeOnce(i == 0 ? 1 : chunkSize)) break;
            if (!queue.isSettling()) break;
        }
        // A real claimant claims straight after settlement. Folding this in gives the
        // no-double-claim witness a second reachable entrypoint.
        if (chunkSize % 2 == 1) _claimFirstClaimable();
        callCount++;
    }

    /// @notice Settlement attempted at the CURRENT timestamp with no keeper assistance. This is
    ///         what exercises `Queue_EpochNotOver` (epoch-boundary law) and `Queue_AllInCooldown`
    ///         (ADR-0022 hold), and it is where a liveness defect would present as a stall.
    function settleNow(uint256 maxRequests) external {
        _reconcileGhosts();
        _closeOnce(bound(maxRequests, 1, 5));
        callCount++;
    }

    /// @notice Claim a settled request; measured as the owner's USDfr balance delta, then
    ///         immediately probed for a second payout (INV-13).
    function claimRequest(uint256 reqSeed) external {
        _reconcileGhosts();
        if (g.length != 0) {
            uint256 id = reqSeed % g.length;
            if (g[id].filledAssets > g[id].claimedAssets) {
                _claim(id);
            } else {
                _claimFirstClaimable();
            }
        }
        callCount++;
    }

    /// @notice Stable liquidity in: the ONLY source of the settlement budget.
    function addStableLiquidity(uint256 actorSeed, uint256 usdcAmount) external {
        _reconcileGhosts();
        _addLiquidity(actors[actorSeed % 3], bound(usdcAmount, 1e6, 1_000_000e6));
        callCount++;
    }

    /// @notice Stable liquidity out: drains the pool the budget is drawn from.
    function drainStableLiquidity(uint256 actorSeed, uint256 amount) external {
        _reconcileGhosts();
        address actor = actors[actorSeed % 3];
        uint256 bal = usdfr.balanceOf(actor);
        uint256 idleValue = gIdleUnits * 1e12;
        uint256 max = bal < idleValue ? bal : idleValue;
        if (max >= 1e12) {
            uint256 usdfrAmount = bound(amount, 1e12, max);
            vm.prank(actor);
            controller.redeem(usdfrAmount);
            gIdleUnits -= usdfrAmount / 1e12;
        }
        callCount++;
    }

    /// @notice Move stable liquidity into the reserve-instrument MARK (idle -> deployed).
    ///         Backing-neutral; it exists purely to
    ///         prove the settlement budget excludes the mark.
    function deployPrincipal(uint256 usdcAmount) external {
        _reconcileGhosts();
        if (gIdleUnits >= 2) {
            _deploy(bound(usdcAmount, 1, gIdleUnits / 2));
        }
        callCount++;
    }

    /// @notice Facility repayment: the mark converts back into stable liquidity.
    /// @dev Repayment stops at `MARK_FLOOR` rather than draining the book to zero, so the
    ///      reserve-instrument mark is non-zero in EVERY reachable state of this campaign. That
    ///      is what makes `settlementsWithLiveMark` a real witness: every settlement this suite
    ///      measures ran with a live mark that the budget had to exclude. A zero mark is not an
    ///      interesting state for this family (with nothing to exclude, the exclusion property
    ///      is trivially satisfied), so nothing is lost by holding the floor.
    function repayPrincipal(uint256 usdcAmount) external {
        _reconcileGhosts();
        usdcAmount = bound(usdcAmount, 1e6, 500_000e6);
        uint256 received = usdcAmount * 1e12;
        uint256 repayable = gDeployedValue > MARK_FLOOR ? gDeployedValue - MARK_FLOOR : 0;
        uint256 principal = repayable < received ? repayable : received;
        usdc.mint(address(this), usdcAmount);
        usdc.approve(address(reserves), usdcAmount);
        reserves.recordPayment(FACILITY_ID, address(this), usdcAmount, principal);
        gIdleUnits += usdcAmount;
        gDeployedValue -= principal;
        callCount++;
    }

    /// @notice Declared-but-unrealized senior impairment: moves the CONSERVATIVE exit NAV the
    ///         settlement prices against, without moving realized NAV. Biased 3:1 towards the
    ///         redeemable region so a run cannot spend all of itself in the clamped state.
    function setImpairment(uint256 seed) external {
        _reconcileGhosts();
        uint256 assets = vault.totalAssets();
        uint256 amount;
        if (seed % 4 == 0) {
            amount = bound(seed, assets, assets + assets / 2 + 1e18); // reach the clamped base
        } else {
            amount = assets == 0 ? 0 : bound(seed, 0, assets / 2);
        }
        impairment.setImpairment(amount);
        callCount++;
    }

    /// @notice Keeper outage / time passage. Bounded well past the 1-day heartbeat and the
    ///         21-day hold so both boundaries are crossed in both directions.
    function warp(uint256 secs) external {
        _reconcileGhosts();
        uint256 delta = bound(secs, 1 hours, 45 days);
        if (delta > longestKeeperGapSeconds) longestKeeperGapSeconds = delta;
        vm.warp(block.timestamp + delta);
        callCount++;
    }

    // ── settlement core ──────────────────────────────────────────────────

    function _closeOnce(uint256 maxRequests) internal returns (bool ok) {
        // `closeEpoch` crystallizes fees as its first act; do it here too so the precondition
        // arithmetic below is evaluated against exactly the state the settlement will see.
        vault.accrueFees();
        CloseState memory cs = _preClose();
        uint256 cooldown = queue.redeemCooldown();

        vm.recordLogs();
        bytes memory ret;
        (ok, ret) = address(queue).call(abi.encodeCall(IRedemptionQueue.closeEpoch, (maxRequests)));

        if (!ok) {
            vm.getRecordedLogs(); // drain; a reverted call emits nothing
            _classifyAbandon(cs, ret);
            _recordProgress(cs, 0);
            return false;
        }

        if (!cs.wasSettling) {
            gSettling = true;
            gSnapshotBudget = cs.snapshotBudget;
            gSettlementDistributed = 0;
            gSettlementMinValue = cs.minValue;
        } else {
            chunkContinuations++;
        }

        ChunkResult memory cr = _parseChunk(cooldown);

        // INV-11 (queue solvency), asserted against MY snapshot ghost, never against
        // `settlementBudgetRemaining()`.
        if (gSettlementDistributed + cr.distributed > gSnapshotBudget) sawOverDistribution = true;
        // ... and never more than the USDfr that actually existed in the vault to pay it with.
        if (cr.distributed > cs.vaultBalBefore) sawOverDistribution = true;
        // custody must move by exactly the sum of the fill events
        if (usdfr.balanceOf(address(queue)) - cs.queueBalBefore != cr.distributed) sawAccountingMismatch = true;

        gSettlementDistributed += cr.distributed;

        if (gSnapshotBudget != 0) {
            uint256 utilisation = Math.mulDiv(gSettlementDistributed, Config.BPS, gSnapshotBudget);
            if (utilisation > maxBudgetUtilisationBps) maxBudgetUtilisationBps = utilisation;
        }

        if (cr.closed) _applyClose(cr);

        if (cr.distributed != 0) {
            settlementChunksPaid++;
            if (gDeployedValue != 0) settlementsWithLiveMark++;
            if (vault.redemptionTotalAssets() < vault.totalAssets()) settlementsUnderImpairment++;
        }
        _recordProgress(cs, cr.distributed);
        return true;
    }

    function _preClose() internal view returns (CloseState memory cs) {
        cs.wasSettling = queue.isSettling();
        cs.drained = gHead >= g.length;
        cs.endsAtBefore = queue.epochEndsAt();
        cs.epochBefore = queue.currentEpoch();
        cs.queueBalBefore = usdfr.balanceOf(address(queue));
        cs.vaultBalBefore = usdfr.balanceOf(address(vault));
        cs.minValue = cs.wasSettling ? gSettlementMinValue : queue.minRedemptionValue();
        cs.snapshotBudget = _liveBudgetFromGhost();

        if (!cs.wasSettling && block.timestamp < cs.endsAtBefore) return cs; // not admissible yet
        if (cs.drained) {
            // INV-14, unconditional half: `drained` implies `stopReason == 0`, which the A1
            // abandon branch cannot catch, so an admissible close of an empty queue MUST close
            // the epoch. No liquidity, mark, impairment or fee state can excuse it.
            cs.progressExpected = true;
            cs.obligationIsDrained = true;
            return cs;
        }
        if (block.timestamp < uint256(g[gHead].requestedAt) + queue.redeemCooldown()) return cs;

        // A latched settlement's remaining budget can have been ratcheted down by the H-04 live
        // cap in an earlier chunk, and that ratchet is persistent. The PRECONDITION therefore
        // consults it; the asserted quantity (over-distribution) never does.
        uint256 budgetAvail =
            cs.wasSettling ? Math.min(queue.settlementBudgetRemaining(), cs.snapshotBudget) : cs.snapshotBudget;
        uint256 outstanding = g[gHead].requestedShares - g[gHead].filledShares;
        uint256 budgetShares = vault.convertToSharesAtRedemption(budgetAvail);
        uint256 fill = outstanding < budgetShares ? outstanding : budgetShares;
        uint256 payableAssets = vault.previewRedeem(fill);
        cs.progressExpected = payableAssets != 0 && payableAssets >= cs.minValue;
    }

    function _parseChunk(uint256 cooldown) internal returns (ChunkResult memory cr) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 lastId = type(uint256).max;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(queue) || logs[i].topics.length < 2) continue;
            if (logs[i].topics[0] == FILLED_SIG) {
                uint256 id = uint256(logs[i].topics[1]);
                (uint256 shares, uint256 assets,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                _recordFill(id, shares, assets, cooldown, lastId);
                lastId = id;
                cr.distributed += assets;
            } else if (logs[i].topics[0] == CLOSED_SIG) {
                cr.closed = true;
                cr.closedEpoch = uint256(logs[i].topics[1]);
                (cr.closedBudget, cr.closedDistributed, cr.nextEndsAt) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
    }

    /// @dev INV-12 + INV-13 + ADR-0022, all evaluated against the ghost list rather than the
    ///      contract's `head`/`sharesRemaining`.
    function _recordFill(uint256 id, uint256 shares, uint256 assets, uint256 cooldown, uint256 lastId) internal {
        if (id >= g.length) {
            sawAccountingMismatch = true;
            return;
        }
        // C-1: a settlement must never burn a position for nothing.
        if (shares == 0 || assets == 0) sawZeroValueFill = true;
        // strictly increasing within a chunk, and always landing on the ghost head
        if (lastId != type(uint256).max && id <= lastId) sawFifoViolation = true;
        if (id != gHead) sawFifoViolation = true;
        for (uint256 i = 0; i < id; ++i) {
            if (g[i].filledShares < g[i].requestedShares) sawFifoViolation = true;
        }

        GhostRequest storage r = g[id];
        if (r.filledShares + shares > r.requestedShares) sawAccountingMismatch = true;

        uint256 held = block.timestamp - uint256(r.requestedAt);
        if (held < cooldown) sawCooldownBypass = true;
        if (held < minObservedHoldSeconds) minObservedHoldSeconds = held;

        r.filledShares = r.filledShares + shares > r.requestedShares ? r.requestedShares : r.filledShares + shares;
        r.filledAssets += assets;
        fillsObserved++;
        if (r.filledShares == r.requestedShares) {
            while (gHead < g.length && g[gHead].filledShares >= g[gHead].requestedShares) {
                gHead++;
            }
        } else {
            partialFills++;
        }
    }

    /// @dev Keeper-gap correctness: an epoch close after N missed runs must advance the counter
    ///      by exactly one and re-arm the heartbeat from NOW — never catch up N epochs, and
    ///      never accrue N epochs of budget (the budget bound is INV-11 above).
    function _applyClose(ChunkResult memory cr) internal {
        if (cr.closedEpoch != gEpoch) {
            sawEpochDrift = true;
            _recordDrift(1, gEpoch, cr.closedEpoch);
        }
        // `gSettlementDistributed` already includes THIS chunk by the time this runs, and the
        // queue's `EpochClosed.distributed` is the settlement total across every chunk. The two
        // must agree exactly.
        if (cr.closedDistributed != gSettlementDistributed) sawAccountingMismatch = true;
        if (cr.closedBudget > gSnapshotBudget) sawOverDistribution = true;
        (uint64 duration,) = queue.epochParams();
        if (cr.nextEndsAt != block.timestamp + duration) {
            sawEpochDrift = true;
            _recordDrift(2, block.timestamp + duration, cr.nextEndsAt);
        }
        // D-04 corroboration witness; see the declaration.
        uint256 bookLeft = vault.previewRedeem(queue.totalQueuedShares());
        if (gSettlementDistributed != 0 && bookLeft >= 100 * gSettlementDistributed) {
            heartbeatBurnedAgainstLargeBook++;
        }
        gEpoch += 1;
        epochsClosed++;
        gSettling = false;
        gSettlementDistributed = 0;
        gSnapshotBudget = 0;
    }

    /// @dev A violated invariant must carry its own evidence. `kind` 1 = epoch-counter drift,
    ///      2 = heartbeat re-arm drift. Only the FIRST violation is recorded.
    function _recordDrift(uint8 kind, uint256 expected, uint256 actual) internal {
        if (driftKind != 0) return;
        driftKind = kind;
        driftExpected = expected;
        driftActual = actual;
        driftAt = block.timestamp;
    }

    function _recordProgress(CloseState memory cs, uint256 distributed) internal {
        bool progressed =
            queue.currentEpoch() > cs.epochBefore || queue.epochEndsAt() > cs.endsAtBefore || distributed != 0;
        if (cs.progressExpected) {
            if (cs.obligationIsDrained) livenessObligationsDrained++;
            else livenessObligationsPayable++;
            if (!progressed) {
                sawLivenessViolation = true;
                livenessReason = cs.obligationIsDrained ? 1 : 2;
            }
        }
        if (progressed) {
            attemptsSinceProgress = 0;
        } else {
            attemptsSinceProgress++;
            if (attemptsSinceProgress > maxAttemptsSinceProgress) maxAttemptsSinceProgress = attemptsSinceProgress;
        }
    }

    function _classifyAbandon(CloseState memory cs, bytes memory ret) internal {
        bytes4 sel = bytes4(ret);
        if (sel == IRedemptionQueue.Queue_EpochNotOver.selector) {
            epochNotOverStops++;
            // epoch-boundary law: refusal only before the boundary, and only while not settling
            assertFalse(cs.wasSettling, "EPOCH GUARD FIRED INSIDE A LIVE SETTLEMENT");
            assertLt(block.timestamp, _errArg(ret, 0), "EPOCH GUARD FIRED AT OR AFTER epochEndsAt");
            assertEq(_errArg(ret, 0), uint256(cs.endsAtBefore), "EPOCH GUARD REPORTED A DIFFERENT DEADLINE");
        } else if (sel == IRedemptionQueue.Queue_AllInCooldown.selector) {
            cooldownStops++;
            assertLt(block.timestamp, _errArg(ret, 0), "COOLDOWN GUARD FIRED AFTER ELIGIBILITY");
        } else if (sel == IRedemptionQueue.Queue_HeadNotRedeemable.selector) {
            loudStops++;
            assertGe(_errArg(ret, 0), gHead, "LOUD STOP REPORTED A REQUEST BEHIND THE HEAD");
        } else if (sel == IRedemptionQueue.Queue_NoLiquidity.selector) {
            noLiquidityStops++;
        } else {
            assertTrue(false, string(abi.encodePacked("UNEXPECTED closeEpoch REVERT ", vm.toString(sel))));
        }
    }

    // ── primitives ───────────────────────────────────────────────────────

    function _addLiquidity(address actor, uint256 usdcAmount) internal {
        usdc.mint(actor, usdcAmount);
        vm.startPrank(actor);
        usdc.approve(address(controller), usdcAmount);
        controller.mint(usdcAmount);
        vm.stopPrank();
        gIdleUnits += usdcAmount;
    }

    function _deposit(address actor, uint256 assets) internal {
        vm.startPrank(actor);
        usdfr.approve(address(vault), assets);
        vault.deposit(assets, actor);
        vm.stopPrank();
    }

    function _deploy(uint256 usdcAmount) internal {
        reserves.recordDeployment(FACILITY_ID, facilitySink, usdcAmount);
        gIdleUnits -= usdcAmount;
        gDeployedValue += usdcAmount * 1e12;
    }

    function _queueRequest(address actor, uint256 shares) internal {
        vm.startPrank(actor);
        vault.approve(address(queue), shares);
        uint256 id = queue.requestRedeem(shares);
        vm.stopPrank();
        assertEq(id, g.length, "REQUEST IDS ARE NOT DENSE");
        g.push(
            GhostRequest({
                owner: actor,
                requestedAt: uint64(block.timestamp),
                requestedShares: shares,
                filledShares: 0,
                filledAssets: 0,
                claimedAssets: 0
            })
        );
        requestsCreated++;
    }

    function _claimFirstClaimable() internal {
        for (uint256 i = 0; i < g.length; ++i) {
            if (g[i].filledAssets > g[i].claimedAssets) {
                _claim(i);
                return;
            }
        }
    }

    /// @dev INV-13. The expected payout is MY event-derived outstanding fill, and the realised
    ///      payout is MEASURED as the owner's balance delta. A second claim in the same block
    ///      must then find nothing.
    function _claim(uint256 id) internal {
        GhostRequest storage r = g[id];
        uint256 expected = r.filledAssets - r.claimedAssets;
        uint256 balBefore = usdfr.balanceOf(r.owner);
        vm.prank(r.owner);
        uint256 got = queue.claim(id);
        uint256 delta = usdfr.balanceOf(r.owner) - balBefore;
        if (delta != expected || got != expected) sawDoubleClaim = true;
        r.claimedAssets += delta;
        if (r.claimedAssets > r.filledAssets) sawDoubleClaim = true;
        claimsMade++;

        // immediate second-claim probe: the same credit must not be payable twice
        vm.prank(r.owner);
        (bool ok, bytes memory ret) = address(queue).call(abi.encodeCall(IRedemptionQueue.claim, (id)));
        if (ok) {
            sawDoubleClaim = true;
        } else {
            assertEq(
                bytes4(ret),
                IRedemptionQueue.Queue_NothingClaimable.selector,
                "SECOND CLAIM FAILED FOR THE WRONG REASON"
            );
        }
    }

    // ── views used by the suite ──────────────────────────────────────────

    function requestCount() external view returns (uint256) {
        return g.length;
    }

    function ghostRequest(uint256 id)
        external
        view
        returns (address owner, uint256 requestedShares, uint256 filledShares, uint256 filledAssets, uint256 claimed)
    {
        GhostRequest storage r = g[id];
        return (r.owner, r.requestedShares, r.filledShares, r.filledAssets, r.claimedAssets);
    }

    function sumOutstandingShares() external view returns (uint256 total) {
        for (uint256 i = 0; i < g.length; ++i) {
            total += g[i].requestedShares - g[i].filledShares;
        }
    }

    function sumUnclaimedAssets() external view returns (uint256 total) {
        for (uint256 i = 0; i < g.length; ++i) {
            total += g[i].filledAssets - g[i].claimedAssets;
        }
    }

    /// @notice The budget the queue is ENTITLED to, derived from this handler's own idle-stable
    ///         ledger. Deliberately has no `deployedPrincipal` term: the reserve-instrument mark
    ///         is a valuation, not cash, and must never fund an exit.
    function expectedAvailableLiquidity() public view returns (uint256) {
        (, uint16 bps) = queue.epochParams();
        return Math.mulDiv(gIdleUnits * 1e12, bps, Config.BPS);
    }

    function _liveBudgetFromGhost() internal view returns (uint256) {
        return expectedAvailableLiquidity();
    }

    function _reconcileGhosts() internal view {
        assertEq(gIdleUnits, reserves.idleUSDC(), "IDLE-STABLE GHOST DIVERGED FROM THE RESERVE");
        assertEq(gDeployedValue, reserves.deployedPrincipal(), "MARK GHOST DIVERGED FROM THE RESERVE");
    }

    function _errArg(bytes memory ret, uint256 index) private pure returns (uint256 v) {
        if (ret.length < 4 + 32 * (index + 1)) return 0;
        assembly {
            v := mload(add(add(ret, 0x24), mul(index, 0x20)))
        }
    }
}
