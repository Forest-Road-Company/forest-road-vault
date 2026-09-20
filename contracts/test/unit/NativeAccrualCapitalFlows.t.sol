// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NativeAccrualFixture} from "../helpers/NativeAccrualFixture.sol";

abstract contract NativeAccrualCapitalFlowChecks is NativeAccrualFixture {
    function testFuzz_depositMintAndQueuedExitUseAccruedFeeNetValue(uint64 seed, bool exactShares) public {
        _nativeFund(50_000e18);
        _nativeAdvance(nativeStart + 30 days);
        uint256 amount = (uint256(seed) % 49_001 + 1_000) * 1e18;
        (uint256 assets, uint256 shares) = _expectedEntry(amount, exactShares);
        uint256 assetsBefore = vault.totalAssets();
        uint256 grossBefore = reserves.accrualSnapshot().gross;
        _mintCapital((assets + _nativeScale() - 1) / _nativeScale() * _nativeScale());
        vm.startPrank(bob);
        usdfr.approve(address(vault), assets);
        if (exactShares) assertEq(vault.mint(shares, bob), assets, "exact-share entry ignored accrued fees");
        else assertEq(vault.deposit(assets, bob), shares, "deposit ignored accrued fees");
        vm.stopPrank();
        assertEq(vault.balanceOf(bob), shares, "investor shares");
        assertEq(vault.totalAssets(), assetsBefore + assets, "new capital changed old interest ownership");
        assertEq(reserves.accrualSnapshot().gross, grossBefore, "entry recognized income twice");
        _assertNativeBacking();
        uint256 claimed = _queueExit(shares / 2);
        _redeemCash(claimed / _nativeScale() * _nativeScale());
        _nativePayAll();
        assertEq(registry.totalBookExposure(), 0, "investor flow prevented final loan settlement");
        assertEq(
            nativeReference.paid, nativeReference.original + nativeReference.earned, "contractual borrower receipt"
        );
        _assertNativeBacking();
    }

    function _expectedEntry(uint256 amount, bool exactShares) private view returns (uint256 assets, uint256 shares) {
        uint256 gross = reserves.accrualSnapshot().gross;
        uint256 seniorIncome = gross - gross / 10;
        uint256 virtualShares = 10 ** (vault.decimals() - usdfr.decimals());
        uint256 supply = vault.totalSupply() + virtualShares;
        uint256 value = SENIOR_CAPITAL + seniorIncome + 1;
        uint256 performanceAssets = seniorIncome / 10;
        uint256 performanceShares = performanceAssets * supply / (value - performanceAssets);
        supply += performanceShares;
        assertEq(vault.currentExchangeRate(), 10 ** vault.decimals() * value / supply, "quoted accrued net rate");
        if (exactShares) {
            shares = amount * virtualShares;
            assets = (shares * value + supply - 1) / supply;
            assertEq(vault.previewMint(shares), assets, "independent accrued mint quote");
        } else {
            assets = amount;
            shares = assets * supply / value;
            assertEq(vault.previewDeposit(assets), shares, "independent accrued deposit quote");
        }
    }

    function _queueExit(uint256 shares) private returns (uint256 claimed) {
        vm.startPrank(bob);
        vault.approve(address(queue), shares);
        uint256 requestId = queue.requestRedeem(shares);
        vm.stopPrank();
        uint256 remaining = shares;
        for (uint256 epoch; remaining != 0 && epoch < 16; ++epoch) {
            (uint256 next, uint256 assets) = _fillNativeRequest(requestId, remaining);
            remaining = next;
            claimed += assets;
        }
        assertEq(remaining, 0, "funded request did not complete across available epochs");
        assertEq(nativeReference.paid, 0, "exit test received borrower interest first");
    }

    function _fillNativeRequest(uint256 requestId, uint256 shares)
        private
        returns (uint256 remaining, uint256 claimed)
    {
        uint64 at = uint64(block.timestamp + queue.redeemCooldown());
        if (queue.epochEndsAt() > at) at = queue.epochEndsAt();
        _nativeAdvance(at);
        _refreshCapitalPrices();
        vault.accrueFees();
        uint256 supply = vault.totalSupply() + 10 ** (vault.decimals() - usdfr.decimals());
        uint256 budget = queue.availableLiquidity();
        uint256 assetsBefore = vault.totalAssets();
        uint256 grossBefore = reserves.accrualSnapshot().gross;
        vm.prank(settlementKeeper);
        queue.closeEpoch(1);
        uint256 claimable;
        (, remaining, claimable,,) = queue.request(requestId);
        assertLt(remaining, shares, "liquid native request made no progress");
        assertEq(claimable, (shares - remaining) * (assetsBefore + 1) / supply, "independent fee-net exit value");
        assertLe(claimable, budget, "native exit exceeded its epoch budget");
        assertEq(vault.totalAssets(), assetsBefore - claimable, "queue withdrew another owner's value");
        assertEq(reserves.accrualSnapshot().gross, grossBefore, "exit recognized income twice");
        uint256 before_ = usdfr.balanceOf(bob);
        vm.prank(bob);
        claimed = queue.claim(requestId);
        assertEq(claimed, claimable, "queue claim value");
        assertEq(usdfr.balanceOf(bob), before_ + claimed, "queue did not deliver the investor's claim");
        _assertNativeBacking();
    }

    function _redeemCash(uint256 amount) private {
        uint256 supply = controller.totalUSDfr();
        uint256 backing = controller.backingValue();
        uint256 cash = IERC20(_nativeAsset()).balanceOf(bob);
        vm.prank(bob);
        usdfr.approve(address(controller), amount);
        vm.prank(bob);
        _redeemNativeCapital(amount);
        assertEq(IERC20(_nativeAsset()).balanceOf(bob), cash + amount / _nativeScale(), "native cash delivery");
        assertEq(controller.totalUSDfr(), supply - amount, "cash redemption burn");
        assertEq(controller.backingValue(), backing - amount, "cash redemption backing");
        _assertNativeDebt();
        _assertNativeBacking();
    }

    function _mintCapital(uint256 amount) private {
        _refreshCapitalPrices();
        _mintUSDfrTo(bob, amount);
    }

    function _refreshCapitalPrices() private {}

    function _redeemNativeCapital(uint256 amount) private {
        uint256 paid = controller.redeem(amount);
        assertEq(paid, amount / _nativeScale(), "native par redemption output");
    }
}

contract NativeAccrualCashCapitalFlowsTest is NativeAccrualCapitalFlowChecks {}

contract NativeAccrualPikCapitalFlowsTest is NativeAccrualCapitalFlowChecks {
    function _pikFacilities() internal pure override returns (bool) {
        return true;
    }
}
