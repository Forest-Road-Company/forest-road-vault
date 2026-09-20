// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @notice Earned PIK follows full paired issuance under the owner's current accrual policy.
contract LegacyPikFeePolicyTest is CreditLayerFixture {
    uint256 private constant P = 1_000_000e18;
    uint256 private constant LOSS = 300_000e18;
    uint256 private earning;
    uint256 private impaired;

    function _pikFacilities() internal pure override returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();
        earning = _liveFilmFacility(P);
        impaired = _liveFilmFacility(LOSS);
        vm.startPrank(admin);
        vault.setManagementFee(0);
        vault.setPerformanceFee(1000);
        vm.stopPrank();
        vm.startPrank(alice);
        usdfr.approve(address(vault), P);
        vault.deposit(P, alice);
        vm.stopPrank();
        _attestDefault(impaired);
        vm.prank(servicer);
        defaultManager.declareDefault(impaired, FILM_REF);
        assertEq(curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS), 0);
        assertEq(defaultManager.pendingSeniorImpairment(), LOSS, "the senior impairment must actually exist");
    }

    function test_earnedPikFeeKeepsTheFullLossInTheCascade() public {
        _check(1000);
    }

    function testFuzz_pikFeeAndSeniorLegConserveTheFullEarnedCoupon(uint16 feeSeed) public {
        _check(uint16(bound(feeSeed, 0, 1000)));
    }

    function _check(uint16 feeBps) private {
        vm.prank(admin);
        waterfall.setProtocolFee(feeBps);
        uint256 scale = 1e12;
        uint256 coupon = P * 1400 / 120_000 / scale * scale;
        uint256 fee = coupon * feeBps / 10_000;
        uint256 protocolBefore = usdfr.balanceOf(feeRecipient);
        uint256 seniorBefore = usdfr.balanceOf(address(vault));
        uint256 supplyBefore = usdfr.totalSupply();
        uint256 backingBefore = reserves.totalBackingValue();
        vm.warp(bridge.facility(earning).nextPaymentDue);
        assertEq(waterfall.capitalizePik(earning), coupon);
        assertEq(usdfr.balanceOf(feeRecipient) - protocolBefore, fee, "earned protocol fee was canceled");
        assertEq(usdfr.balanceOf(address(vault)) - seniorBefore, coupon - fee, "senior split changed");
        assertEq(usdfr.totalSupply() - supplyBefore, coupon, "paired issuance left an unowned surplus");
        assertEq(reserves.totalBackingValue() - backingBefore, coupon);
        assertEq(defaultManager.pendingSeniorImpairment(), LOSS);
        assertEq(vault.performanceFeeBps(), 1000);

        // With no junior capital, the whole recorded loss must reach senior principal.
        // A withheld PIK fee cannot become a surplus that absorbs part of that loss first.
        uint256 seniorAtLoss = usdfr.balanceOf(address(vault));
        uint256 supplyAtLoss = usdfr.totalSupply();
        _realizeLoss(impaired, LOSS, keccak256("pik-fee-policy-loss"));
        assertEq(seniorAtLoss - usdfr.balanceOf(address(vault)), LOSS, "PIK surplus changed cascade delivery");
        assertEq(supplyAtLoss - usdfr.totalSupply(), LOSS);
        assertEq(usdfr.balanceOf(feeRecipient) - protocolBefore, fee);
    }
}
