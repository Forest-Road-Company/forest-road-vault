// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {MockImpairmentSource} from "../helpers/MockImpairmentSource.sol";
import {QueueHandler} from "./handlers/QueueHandler.sol";

/// @dev Stateful-fuzz invariants for the redemption queue (CLAUDE.md §1.3):
///      - OVER-DISTRIBUTION: settled assets never exceed the settlement's snapshot
///        budget (asserted per settlement in the handler, across chunked closes)
///      - FIFO: requests before the head are fully filled; requests after it are
///        untouched — ordering never inverts
///      - NO DOUBLE-CLAIM: claims pay exactly once (per-call assert) and custody
///        reconciles: queue USDfr == Σ unclaimed fills, queue shares == Σ queued
///      - ZERO-VALUE FILL (AUDIT C-1): a `RequestFilled` with shares > 0 must always
///        carry assets > 0 — a settlement may never burn a position for nothing
///      - LIVENESS (C-1 REMEDIATION): a settlement that REFUSES to settle must not be
///        denying a request that could have been paid. Asserted at the revert site in
///        `QueueHandler._assertNoPayableRequestWasDenied`, because the property is only
///        meaningful at the moment `closeEpoch` reverts. The handler previously tolerated
///        `Queue_NoLiquidity` unconditionally, which made a permanently bricked queue read
///        green; it is now selector-checked AND liveness-checked.
///      - BACKING + MONOTONICITY continue to hold through queue traffic
contract RedemptionQueueInvariants is CreditLayerFixture {
    QueueHandler internal handler;
    MockImpairmentSource internal impairmentSource;

    function setUp() public override {
        super.setUp();
        // Drive both ADR-0022 views independently. The previous single-slot mock collapsed
        // redemption NAV and performance-fee NAV into one value, making the dual-NAV exit
        // law unreachable throughout the queue assurance tier.
        impairmentSource = new MockImpairmentSource();
        vm.prank(admin);
        vault.setImpairmentSource(address(impairmentSource));
        handler = new QueueHandler(
            usdc, usdfr, compliance, reserves, controller, vault, queue, complianceAdmin, impairmentSource
        );
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = QueueHandler.stake.selector;
        selectors[1] = QueueHandler.request.selector;
        selectors[2] = QueueHandler.closeEpochChunk.selector;
        selectors[3] = QueueHandler.claim.selector;
        selectors[4] = QueueHandler.addLiquidity.selector;
        selectors[5] = QueueHandler.drainLiquidity.selector;
        selectors[6] = QueueHandler.donateToVault.selector;
        selectors[7] = QueueHandler.warp.selector;
        selectors[8] = QueueHandler.setImpairment.selector;
        selectors[9] = QueueHandler.setDualImpairment.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice INVARIANT (queue FIFO, §1.3): ordering never inverts.
    function invariant_queue_fifoHolds() public view {
        assertTrue(handler.fifoHolds(), "FIFO INVERTED");
    }

    /// @notice INVARIANT (queue custody / no double-claim): the queue's balances are
    ///         exactly the sum of open positions — a double-claim or over-fill would
    ///         break this equality immediately.
    function invariant_queue_custodyReconciles() public view {
        assertEq(vault.balanceOf(address(queue)), queue.totalQueuedShares(), "SHARE CUSTODY DRIFTED");
        assertEq(queue.totalQueuedShares(), handler.sumSharesRemaining(), "QUEUED SHARES != SUM OF REQUESTS");
        assertEq(usdfr.balanceOf(address(queue)), handler.sumClaimable(), "ASSET CUSTODY != UNCLAIMED FILLS");
        assertEq(
            handler.ghostTotalFilled(),
            handler.ghostTotalClaimed() + handler.sumClaimable(),
            "FILLED != CLAIMED + CLAIMABLE"
        );
    }

    /// @notice INVARIANT (backing, ADR-0012) through queue traffic.
    function invariant_backing_holdsThroughQueueTraffic() public view {
        assertLe(controller.totalUSDfr(), controller.backingValue(), "BACKING VIOLATED");
    }

    /// @notice INVARIANT (monotonicity): no queue operation lowers the exchange rate
    ///         (there are no loss events in this handler).
    /// @dev AUDIT R15-04. This previously compared the live rate against `handler.rateFloor()`,
    ///      which the handler re-anchors to the post-action rate as the last state-touching
    ///      statement of every registered selector — so the assertion was `assertGe(x, x)` and
    ///      made no cross-call statement. The real check is per-call inside
    ///      `_assertAndAdvanceRateFloor`, which bounds any drop by the ERC-4626 rounding
    ///      discontinuity and then requires an observable protocol-fee witness plus the geometric
    ///      fee-retention floor. This asserts that verdict rather than restating a tautology.
    function invariant_exchangeRate_neverFallsFromQueueOps() public view {
        assertFalse(handler.sawUnexplainedRateDrop(), "RATE FELL FROM QUEUE TRAFFIC WITHOUT A FEE CAUSE");
    }

    /// @notice INVARIANT (ADR-0031 dual-NAV hurdle law): the asset hurdle after
    ///         a deposit or a one-exit queue chunk equals the independently derived
    ///         pre-flow carry, within one HWM-rate rounding unit.
    /// @dev The handler derives the deposit law as `H + assets` and the exit law as
    ///      `max(H - assets, H * postSupply / preSupply)`. It does not consult the
    ///      post-flow HWM to decide whether a fee or decline was legitimate.
    function invariant_feeHurdle_followsPreFlowReferenceLaw() public view {
        assertFalse(handler.hurdleCarryViolation(), "FEE HURDLE FLOW LAW VIOLATED");
    }

    /// @notice INVARIANT (AUDIT C-1, CRITICAL): a settlement never burns shares for zero
    ///         assets. Under a declared senior impairment the conservative redemption base
    ///         collapses, and the pre-fix code filled a request's ENTIRE position at a price
    ///         of zero — permanently destroying it. Any fill with shares > 0 must return
    ///         assets > 0; otherwise the position stays queued.
    function invariant_queue_neverFillsForZeroAssets() public view {
        assertFalse(handler.sawZeroValueFill(), "POSITION BURNED FOR ZERO ASSETS");
    }

    /// @notice Anti-vacuity. `settlementsUnderImpairment` is the C-1 witness: settlements
    ///         actually executed while the conservative exit base was marked below the realized
    ///         base. It is measured (a few per run) but NOT asserted, because a given 128-call
    ///         sequence may never line up impairment + cooldown + heartbeat + liquidity, which
    ///         would make the assertion flaky. Non-vacuity is proven deterministically instead:
    ///         reverting the C-1 guard makes `invariant_queue_neverFillsForZeroAssets` fail, and
    ///         `test/audit/Fix_C01-queue-zero-value-fill.t.sol` reproduces the loss directly.
    function invariant_callSummary() public view {
        handler.callCount();
        handler.settlementsUnderImpairment();
        handler.minAdmittedEntryValue();
        // measured reach witnesses (not asserted, per the anti-vacuity note above): confirm the
        // $1 entry floor left the interesting settlement states reachable — the loud C-1 stop, the
        // budget block, positive fills, and the cooldown hold.
        handler.loudStops();
        handler.noLiquidityStops();
        handler.cooldownStops();
        handler.positiveSettlements();
        handler.dualNavStates();
        handler.hurdleCarryChecks();
    }

    /// @notice INVARIANT (C-1 remediation, owner-approved 2026-07-22 — replaces the deferral
    ///         invariant). Deferral is GONE; the anti-dust-wedge protection is now an ENTRY FLOOR
    ///         plus STRICT FIFO. Two guarantees, pinned together:
    ///           (i)  ENTRY FLOOR — no queued request was ever admitted worth less than
    ///                `minRedemptionValue` at the realized rate. Dust is barred at the source, so a
    ///                sub-wei head (and thus the old wedge) cannot arise except under a catastrophic
    ///                full mark, where stopping the queue is correct.
    ///           (ii) STRICT FIFO, NO REORDERING — a fill of request[j] implies every earlier
    ///                request[i<j] is fully filled. With deferral removed there is no sanctioned
    ///                reordering; a regression that filled out of order fails here.
    function invariant_queue_entryFloorAndStrictFifo() public view {
        assertGe(
            handler.minAdmittedEntryValue(),
            queue.minRedemptionValue(),
            "ENTRY FLOOR VIOLATED: a sub-min request was admitted"
        );
        assertTrue(handler.strictFifoNoReordering(), "FIFO REORDERED: a later request filled before an earlier one");
    }

    /// @dev Deterministic replay of the minimized stateful-fuzz sequence that crosses a
    ///      performance-fee boundary on the final donation while marked NAV is below realized
    ///      NAV. The fee-net realized rate may dip because fee shares price at marked NAV, but
    ///      the drop must have a live fee witness and remain within the configured retention.
    function test_replayDonationFeeBoundary() public {
        handler.stake(94446426643442109126640261916808043146796632266977683132435080660167634197544, 2333676741);
        handler.addLiquidity(355360995128290207526555867154017053217, 3239848503639513299632596982123011963);
        handler.request(type(uint256).max - 1, 2);
        handler.donateToVault(15029, 5048);
        handler.setImpairment(22039);
        handler.addLiquidity(101813707234905528312600269383929285169089729197245048122744754035109822201857, 17480);
        handler.warp(1316048495971916762851034678043622395748160509573944438);
        handler.donateToVault(1046363171, 20515);
        handler.closeEpochChunk(272228);
        handler.setImpairment(82958233443515981797617248150871913915139671888812545405552);
        handler.addLiquidity(7916, 1663);
        handler.stake(11442, 19897);
        handler.claim(56126904728136);
        handler.addLiquidity(3194, 3468);
        handler.addLiquidity(122, type(uint256).max - 1);
        handler.donateToVault(64157510423, 0);
        handler.donateToVault(6660766673705532623945607677468126048052062289164, 14);
        handler.donateToVault(1434492526631, 1068402467652765715914788239152104767859890020550378540063);
        handler.request(22005, 8894);

        uint256 actorSeed = 114685323391364422540926128203744780688149623448181870419688387382330015790308;
        uint256 amountSeed = 1060804828604824288318705940506914651891775092770903821469780513244836411995;
        address actor = handler.actors(actorSeed % 3);
        uint256 amount = bound(amountSeed, 1, usdfr.balanceOf(actor));
        uint256 rateBefore = vault.currentExchangeRate();
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 markedAssetsBefore = vault.redemptionTotalAssets();
        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);

        vm.prank(actor);
        usdfr.transfer(address(vault), amount);

        uint256 rateAfter = vault.currentExchangeRate();
        assertEq(vault.totalAssets(), totalAssetsBefore + amount, "donation must increase realized NAV exactly");
        assertEq(
            vault.redemptionTotalAssets(), markedAssetsBefore + amount, "donation must increase marked NAV exactly"
        );
        assertLt(rateAfter, rateBefore, "regression must reach the conservative-NAV fee boundary");
        assertGt(vault.feeExchangeRate(), vault.highWaterMark(), "rate dip must have a pending-fee witness");
        uint256 retainedRate = rateBefore * (10_000 - vault.performanceFeeBps()) / 10_000;
        assertGe(rateAfter, retainedRate, "pending performance fee exceeded its finite dilution bound");

        (uint256 managementShares, uint256 performanceShares) = vault.accrueFees();
        assertEq(managementShares, 0);
        assertGt(performanceShares, 0);
        assertEq(vault.balanceOf(feeRecipient), feeSharesBefore + performanceShares);
        assertEq(vault.currentExchangeRate(), rateAfter, "fee preview and crystallization must be continuous");
        assertGe(vault.highWaterMark(), vault.feeExchangeRate(), "checkpoint must clear the pending fee");
    }
}
