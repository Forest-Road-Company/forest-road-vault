// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @title ADJUDICATION — the COMPLETE branch reached on a LATER fill, with the settlement
///        budget already drawn down below `availableLiquidity()`. This is the only state
///        that discriminates `settlementBudget` from `liveCap`, and the whole §1.3 budget
///        ceiling on the hybrid path rests on that distinction.
contract ADJ_MidSettlement is CreditLayerFixture {
    uint256 internal constant MIN_RESIDUE_VALUE = 1e12;

    function _stakeVault(address who, uint256 amount) internal returns (uint256 shares) {
        _mintUSDfrTo(who, amount);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _queue(address who, uint256 shares) internal returns (uint256 id) {
        vm.startPrank(who);
        vault.approve(address(queue), shares);
        id = queue.requestRedeem(shares);
        vm.stopPrank();
    }

    /// @dev Largest share count whose conservative value does not exceed `target`.
    function _sharesWorthAtMost(uint256 target, uint256 hi) internal view returns (uint256) {
        uint256 lo = 0;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (vault.previewRedeem(mid) <= target) lo = mid;
            else hi = mid - 1;
        }
        return lo;
    }

    /// @notice Request A consumes most of the budget; request B is then sized to sit INSIDE the
    ///         residue margin of what remains, and to be fully payable out of THAT remainder —
    ///         but NOT out of `availableLiquidity()`, which never fell. The COMPLETE branch must
    ///         price B against the drawn-down settlement budget.
    function test_ADJ_completeOnSecondFill_budgetAlreadyDrawnDown() public {
        uint256 aliceShares = _stakeVault(alice, 200_000e18);
        uint256 bobShares = _stakeVault(bob, 400_000e18);

        vm.prank(admin);
        queue.setEpochLiquidityBps(2_000);
        uint256 budget = queue.availableLiquidity();
        emit log_named_uint("availableLiquidity (== first budget)", budget);

        // A takes 2/3 of the budget exactly.
        uint256 aShares = _sharesWorthAtMost((budget * 2) / 3, aliceShares);
        uint256 aValue = vault.previewRedeem(aShares);
        uint256 remaining = budget - aValue;

        // B: fully payable out of `remaining`, and inside the margin of `remaining`'s
        // budgetShares, so the COMPLETE branch is the one that decides it.
        uint256 bShares = _sharesWorthAtMost(remaining, bobShares);
        uint256 remBudgetShares = vault.convertToSharesAtRedemption(remaining);
        assertGt(bShares, remBudgetShares, "precondition: COMPLETE must over-fill past budgetShares");
        assertLe(vault.previewRedeem(bShares), remaining, "precondition: payable out of the REMAINDER");
        assertGt(
            vault.previewRedeem(bShares) + MIN_RESIDUE_VALUE,
            remaining,
            "precondition: B sits inside one margin of the remainder"
        );

        _queue(alice, aShares);
        uint256 idB = _queue(bob, bShares);
        _queue(bob, bobShares / 8); // something behind, so !drained

        vm.warp(uint256(queue.eligibleToSettleAt(idB)) + 1);

        // Chunk 1: A only. The settlement LATCHES with the budget drawn down, while
        // `availableLiquidity()` is unchanged — the two quantities now differ.
        queue.closeEpoch(1);
        assertTrue(queue.isSettling(), "precondition: latched");
        uint256 liveNow = queue.availableLiquidity();
        uint256 budgetNow = queue.settlementBudgetRemaining();
        emit log_named_uint("after chunk 1: availableLiquidity", liveNow);
        emit log_named_uint("after chunk 1: settlementBudgetRemaining", budgetNow);
        assertGt(liveNow, budgetNow, "THE DISCRIMINATING STATE: liveCap strictly exceeds the budget");

        // Chunk 2: B is the head. COMPLETE must be decided against `budgetNow`, not `liveNow`.
        queue.closeEpoch(1);

        (, uint256 bRem, uint256 bClaim,,) = queue.request(idB);
        emit log_named_uint("B remaining", bRem);
        emit log_named_uint("B claimable", bClaim);
        assertLe(bClaim, budgetNow, "BUDGET CEILING BREACHED on the hybrid path");
        assertLe(queue.settlementBudgetRemaining(), budgetNow, "budget went backwards");
    }

    /// @notice Same shape, but B is deliberately sized so it is payable out of
    ///         `availableLiquidity()` and NOT out of the remaining settlement budget.
    ///         Correct behaviour: under-fill (REDUCE) or a soft stop — never a panic.
    function test_ADJ_completeMustNotUseLiveLiquidity() public {
        uint256 aliceShares = _stakeVault(alice, 200_000e18);
        uint256 bobShares = _stakeVault(bob, 400_000e18);

        vm.prank(admin);
        queue.setEpochLiquidityBps(2_000);
        uint256 budget = queue.availableLiquidity();

        uint256 aShares = _sharesWorthAtMost((budget * 2) / 3, aliceShares);
        uint256 remaining = budget - vault.previewRedeem(aShares);

        // B just OVER the remainder but well under live liquidity, and inside the margin.
        uint256 remBudgetShares = vault.convertToSharesAtRedemption(remaining);
        uint256 minResidue = vault.previewWithdraw(MIN_RESIDUE_VALUE);
        uint256 bShares = remBudgetShares + minResidue / 2;
        assertLe(bShares, bobShares, "B fits");
        assertGt(vault.previewRedeem(bShares), remaining, "precondition: NOT payable out of the remainder");
        assertLe(vault.previewRedeem(bShares), budget, "precondition: payable out of LIVE liquidity");

        _queue(alice, aShares);
        uint256 idB = _queue(bob, bShares);
        _queue(bob, bobShares / 8);

        vm.warp(uint256(queue.eligibleToSettleAt(idB)) + 1);
        queue.closeEpoch(1);
        assertTrue(queue.isSettling(), "precondition: latched");
        uint256 budgetNow = queue.settlementBudgetRemaining();
        assertGt(queue.availableLiquidity(), budgetNow, "THE DISCRIMINATING STATE");

        vm.prank(address(0xBEEF));
        (bool ok, bytes memory ret) = address(queue).call(abi.encodeCall(IRedemptionQueue.closeEpoch, (1)));
        emit log_named_string("chunk 2 ok", ok ? "yes" : "no");
        if (!ok) emit log_named_bytes32("revert data", bytes32(ret));
        // A panic (0x4e487b71 / 0x11 arithmetic underflow) is the failure this pins.
        assertTrue(ok || bytes4(ret) != bytes4(0x4e487b71), "ARITHMETIC PANIC: settlementBudget underflowed");

        (, uint256 bRem, uint256 bClaim,,) = queue.request(idB);
        emit log_named_uint("B remaining", bRem);
        emit log_named_uint("B claimable", bClaim);
        assertLe(bClaim, budgetNow, "BUDGET CEILING BREACHED on the hybrid path");
        if (bRem != 0 && bRem != bShares) {
            assertGe(vault.previewRedeem(bRem), MIN_RESIDUE_VALUE, "residue below the margin");
        }
    }
}
