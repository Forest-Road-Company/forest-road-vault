// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {Config} from "../../src/libraries/Config.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {MockImpairmentSource} from "../helpers/MockImpairmentSource.sol";

/// @notice ANGLE-3: drive the NEW Q-01 branch while a GENUINE declared senior impairment is live.
///         Checks: (a) nothing is burned for zero, (b) the budget ceiling holds, (c) the residue
///         carries the full margin AT THE CONSERVATIVE rate, (d) the loud stopReason-3 halt still
///         fires when the mark goes near-total, and (e) it still cures with nothing burned.
contract A3_ImpairmentBranch is CreditLayerFixture {
    MockImpairmentSource internal mock;
    uint256 internal idHead;
    uint256 internal idBehind;

    uint256 internal constant MIN_RESIDUE_VALUE = 1e12;

    function _stake(address who, uint256 amount18) internal returns (uint256 shares) {
        _mintUSDfrTo(who, amount18);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount18);
        shares = vault.deposit(amount18, who);
        vm.stopPrank();
    }

    function _queueIt(address who, uint256 shares) internal returns (uint256 id) {
        vm.startPrank(who);
        IERC20(address(vault)).approve(address(queue), shares);
        id = queue.requestRedeem(shares);
        vm.stopPrank();
    }

    function _bs() internal view returns (uint256) {
        return vault.convertToSharesAtRedemption(queue.availableLiquidity());
    }

    function _run(uint256 impairmentNumer, uint256 impairmentDenom) internal returns (uint256 residue) {
        uint256 headShares = _stake(alice, 100_000e18);
        uint256 sharesBehind = _stake(bob, 400_000e18);

        idHead = _queueIt(alice, headShares);
        idBehind = _queueIt(bob, sharesBehind);
        vm.warp(uint256(queue.eligibleToSettleAt(idHead)) + 1);

        // GENUINE declared senior impairment, live before any settlement.
        mock = new MockImpairmentSource();
        vm.prank(admin);
        vault.setImpairmentSource(address(mock));
        mock.setImpairment(vault.totalAssets() * impairmentNumer / impairmentDenom);

        uint256 minResidue = vault.previewWithdraw(MIN_RESIDUE_VALUE);
        emit log_named_uint("impairment %  (num/denom)", impairmentNumer * 100 / impairmentDenom);
        emit log_named_uint("redemptionTotalAssets", vault.redemptionTotalAssets());
        emit log_named_uint("minResidue (share units)", minResidue);
        emit log_named_uint("head shares", headShares);
        require(headShares > minResidue, "pick a bigger head");

        // Coarse lever: ordinary KYC'd mints raise idle reserve so the budget lands just under
        // the head. No donation, no privileged call.
        uint256 want = vault.previewRedeem(headShares - minResidue) * uint256(Config.BPS)
            / uint256(Config.DEFAULT_EPOCH_LIQUIDITY_BPS);
        if (want > reserves.idleReserve()) {
            _mintUSDfrTo(alice, (want - reserves.idleReserve()) / 1e12 * 1e12);
        }
        uint256 guard;
        while (_bs() < headShares && headShares - _bs() >= minResidue) {
            _mintUSDfrTo(alice, 1e12);
            require(++guard < 200_000, "tuning did not converge");
        }
        uint256 budgetShares = _bs();
        emit log_named_uint("budgetShares at settlement", budgetShares);
        if (budgetShares >= headShares) {
            // DEEP IMPAIRMENT: `convertToSharesAtRedemption` divides by `redemptionTotalAssets()+1`,
            // so the deeper the mark the LARGER `budgetShares` gets. It has already overtaken the
            // whole head, so `fillShares == sharesRemaining` and the new Q-01 block is structurally
            // UNREACHABLE — the C-1 guard runs exactly as it did before the fix. Assert that.
            emit log("deep-impairment regime: the Q-01 block is unreachable, C-1 unchanged");
            queue.closeEpoch(10);
            (, uint256 rem, uint256 claim,,) = queue.request(idHead);
            emit log_named_uint("head shares remaining", rem);
            emit log_named_uint("head claimable", claim);
            assertEq(rem, 0, "deep impairment: the head is completed in one fill, no residue");
            assertGt(claim, 0, "deep impairment: nothing burned for zero");
            return 0;
        }
        require(headShares - budgetShares < minResidue, "undershot: branch would not fire");

        uint256 budgetBefore = queue.availableLiquidity();
        uint256 supplyBefore = IERC20(address(vault)).totalSupply();

        queue.closeEpoch(10);

        uint256 claimable;
        (, residue, claimable,,) = queue.request(idHead);
        emit log_named_uint("residue (share units)", residue);
        emit log_named_uint("residue value at the CONSERVATIVE rate", vault.previewRedeem(residue));
        emit log_named_uint("head claimable", claimable);

        // (a) nothing burned for zero
        if (supplyBefore != IERC20(address(vault)).totalSupply()) {
            assertGt(claimable, 0, "A3: C-1 VIOLATED - shares burned for zero USDfr");
        }
        // (b) the budget ceiling
        assertLe(claimable, budgetBefore, "A3: distributed more than the settlement budget");
        // (c) the residue carries the full margin at the CONSERVATIVE rate
        if (residue != 0) {
            assertGe(
                vault.previewRedeem(residue),
                MIN_RESIDUE_VALUE,
                "A3: residue does NOT carry the full margin under a live impairment"
            );
        }
    }

    function test_A3_branchUnderHalfImpairment() public {
        _run(1, 2);
    }

    function test_A3_branchUnder90pctImpairment() public {
        _run(9, 10);
    }

    function test_A3_branchUnder99pctImpairment() public {
        _run(99, 100);
    }

    function test_A3_branchUnder99_99pctImpairment() public {
        _run(9999, 10_000);
    }

    /// @dev (d) + (e): escalate the SAME board to a near-total mark. The loud halt must still fire
    ///      on the residue the fix just created, and must cure with nothing burned.
    function test_A3_loudStopStillFiresOnTheResidueTheFixCreated() public {
        uint256 residue = _run(1, 2);
        assertGt(residue, 0, "precondition: the fix left a residue");

        mock.setImpairment(type(uint128).max); // clamps redemptionTotalAssets() to 0
        vm.warp(block.timestamp + 2 days);
        assertEq(vault.previewRedeem(residue), 0, "near-total mark prices the residue to zero");
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_HeadNotRedeemable.selector, idHead, residue));
        queue.closeEpoch(10);

        mock.setImpairment(0);
        vm.warp(block.timestamp + 2 days);
        queue.closeEpoch(10);
        (, uint256 rem2, uint256 claim2,,) = queue.request(idHead);
        emit log_named_uint("head shares remaining after the cure", rem2);
        emit log_named_uint("head claimable after the cure", claim2);
        assertGt(claim2, 0, "nothing was burned: the residue settles at a real price once cured");
    }
}
