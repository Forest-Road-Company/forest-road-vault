// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Config} from "../../src/libraries/Config.sol";
import {GovernanceFixture} from "../helpers/GovernanceFixture.sol";

/// @dev Phase H end-to-end: the REAL sGROVE backstop as cascade layer 2 (replacing the
///      Phase E mock), the ADR-0035 live shared reserve binding inside a real loss event,
///      and the fee-share routing surface (coverage + staker rewards) working
///      together. ADR-0021 honesty: stakers' GROVE is never converted or seized —
///      coverage capacity IS the USDfr reserve.
contract GovernanceFlowTest is GovernanceFixture {
    uint256 internal constant FILM = 1;

    function _stake(address who, uint256 usdcAmount) internal {
        _mintUSDfrTo(who, usdcAmount * 1e12);
        vm.startPrank(who);
        usdfr.approve(address(vault), usdcAmount * 1e12);
        vault.deposit(usdcAmount * 1e12, who);
        vm.stopPrank();
    }

    /// @notice Default → cascade with the REAL backstop: curator first, then the
    ///         live coverage reserve, then depositors — and the stakers' GROVE stays
    ///         untouched throughout.
    function test_flow_cascadeThroughRealBackstop() public {
        _stake(alice, 2_000_000e6);
        _postFirstLoss(anchorCurator, FILM, 100_000e18);
        _stakeGrove(secondCurator, 1_000_000e18); // GROVE staked — never at risk of conversion
        _fundCoverage(200_000e18); // the backstop's live reserve

        uint256 id = _liveFilmFacility(1_000_000e18);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        _repay(id, 0, 600_000e18); // recovery

        // shortfall 400k: curator 100k -> backstop drains its live 200k ->
        // depositors 100k. One event can exhaust layer two under ADR-0035.
        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        uint256 groveBefore = grove.balanceOf(address(sGrove));
        vm.prank(servicer);
        _realizeLoss(id, 400_000e18, FILM_REF);

        assertEq(curator.poolBalance(FILM), 0, "layer 1 exhausted first");
        assertEq(sGrove.coverageReserve(), 0, "one event can exhaust layer 2");
        assertEq(vaultBefore - usdfr.balanceOf(address(vault)), 100_000e18, "layer 3 bears the rest");
        assertEq(grove.balanceOf(address(sGrove)), groveBefore, "staked GROVE untouched (ADR-0021)");
        assertEq(sGrove.stakedOf(secondCurator), 1_000_000e18);
        assertTrue(controller.backingInvariantHolds());

        // a second event receives zero until permissionless replenishment.
        assertEq(sGrove.coverageCapacity(), 0);
    }

    /// @notice The governance-routed fee share in motion: protocol fees flow to the
    ///         fee recipient, which routes a share to staker rewards and a share to
    ///         the coverage reserve; stakers claim; coverage stands ready.
    function test_flow_feeShareRoutingToBackstop() public {
        _stake(alice, 2_000_000e6);
        _stakeGrove(secondCurator, 500_000e18);
        uint256 id = _liveFilmFacility(1_000_000e18);
        _repay(id, 100_000e18, 0); // 10% fee -> 10_000e18 to feeRecipient

        // governance routing decision (ADR-0019/0021: routing is a parameter, not a
        // promise): feeRecipient splits its take 50/50 rewards/coverage
        vm.startPrank(feeRecipient);
        usdfr.approve(address(sGrove), 10_000e18);
        sGrove.notifyRewards(5_000e18); // streams over the reward duration (R4-EC1)
        sGrove.fundCoverage(5_000e18);
        vm.stopPrank();

        // the reward now streams in over time rather than landing instantly
        assertEq(sGrove.pendingRewards(secondCurator), 0, "nothing streamed at t0");
        vm.warp(block.timestamp + Config.SGROVE_REWARDS_DURATION);
        assertApproxEqAbs(sGrove.pendingRewards(secondCurator), 5_000e18, 1e7, "sole staker earns the full share");
        vm.prank(secondCurator);
        uint256 got = sGrove.claimRewards();
        assertApproxEqAbs(got, 5_000e18, 1e7);
        assertEq(sGrove.coverageReserve(), 5_000e18);
        assertEq(sGrove.coverageCapacity(), 5_000e18);
        assertTrue(controller.backingInvariantHolds());
    }

    /// @notice ADR-0014's unbonding in a live-protocol context: requesting exit stops
    ///         rewards immediately and the GROVE stays locked for 21 days.
    function test_flow_unbondingDiscipline() public {
        _stakeGrove(secondCurator, 100_000e18);
        vm.prank(secondCurator);
        uint256 unbondId = sGrove.requestUnstake(100_000e18);

        // fee share arriving during the unbond earns them nothing
        _stake(alice, 1_000_000e6);
        uint256 id = _liveFilmFacility(500_000e18);
        _repay(id, 50_000e18, 0);
        vm.startPrank(feeRecipient);
        usdfr.approve(address(sGrove), 1_000e18);
        vm.expectRevert(); // SGrove_NoStakers: the earning set is empty
        sGrove.notifyRewards(1_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + Config.SGROVE_UNBONDING_PERIOD + 1);
        vm.prank(secondCurator);
        sGrove.claimUnstake(unbondId);
        assertEq(grove.balanceOf(secondCurator), 100_000e18, "made whole after the cooldown");
    }
}
