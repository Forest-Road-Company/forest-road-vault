// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NativeAccrualFixture, NativeAccrualMintableAsset} from "../helpers/NativeAccrualFixture.sol";
import {Config} from "../../src/libraries/Config.sol";

contract PrepaymentMediumRegression is NativeAccrualFixture {
    struct Scenario {
        uint256 prepaid;
        uint256 extra;
        uint256 loss;
        uint256 retired;
        uint256 supply;
        uint256 curatorBalance;
    }

    function test_medium_custodyCannotSpendPrepaymentTwice() public {
        _checkSequence(0, 10_000);
    }

    function test_medium_freeSurplusPreservesPrepayment() public {
        _checkSequence(1_000e18 / _nativeScale(), 500);
    }

    function testFuzz_medium_custodyPrepaymentConservesValue(uint64 extraSeed, uint16 lossFraction) public {
        _checkSequence(bound(uint256(extraSeed), 0, 1_000e18 / _nativeScale()),
            bound(uint256(lossFraction), 1, 10_000));
    }

    function _checkSequence(uint256 extraUnits, uint256 lossBps) private {
        Scenario memory s;
        _nativeFund(100_000e18);
        _mintUSDfrTo(bob, 100_000e18);
        bytes32 mark = keccak256("temporary credit mark");
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(nativeId, 1_000e18, mark);
        vm.prank(bob);
        controller.redeem(100_000e18);
        s.prepaid = reserves.exitPrepaidAbsorption();
        assertGt(s.prepaid, 0);
        vm.prank(admin);
        reserves.releasePrincipalImpairment(nativeId, 1_000e18, mark);
        assertEq(controller.backingValue() - controller.totalUSDfr(), s.prepaid);
        if (extraUnits != 0) {
            NativeAccrualMintableAsset(_nativeAsset()).mint(bob, extraUnits);
            vm.startPrank(bob);
            IERC20(_nativeAsset()).approve(address(reserves), extraUnits);
            reserves.recapitalize(extraUnits);
            vm.stopPrank();
        }
        s.extra = extraUnits * _nativeScale();
        uint256 lossUnits = ((s.prepaid + s.extra) / _nativeScale()) * lossBps / 10_000;
        if (lossUnits == 0) lossUnits = 1;
        s.loss = lossUnits * _nativeScale();
        s.retired = s.loss > s.extra ? s.loss - s.extra : 0;
        s.supply = controller.totalUSDfr();
        s.curatorBalance = curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS);
        vm.prank(guardian);
        (uint256 armId,) = reserves.armReserveLossFreeze(mark);
        vm.prank(address(reserves));
        assertTrue(IERC20(_nativeAsset()).transfer(borrower, lossUnits));

        vm.prank(admin);
        reserves.ratifyAndOpen(armId, mark, s.loss);
        assertEq(reserves.exitPrepaidAbsorption(), s.prepaid - s.retired);
        assertEq(controller.totalUSDfr(), s.supply, "custody used existing surplus");
        assertEq(curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS), s.curatorBalance);
        assertEq(controller.backingValue() - s.supply, s.prepaid + s.extra - s.loss);
        _checkLaterFacilityLoss(s, mark);
    }

    function _checkLaterFacilityLoss(Scenario memory s, bytes32 mark) private {
        _attestDefault(nativeId);
        vm.prank(servicer);
        defaultManager.declareDefault(nativeId, FILM_REF);
        uint256 loss = s.prepaid / _nativeScale() * _nativeScale();
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(nativeId, loss, mark);
        uint256 remaining = s.prepaid - s.retired;
        uint256 reused = remaining < loss ? remaining : loss;
        uint256 freshBurn = loss - reused;
        uint256 seniorBefore = usdfr.balanceOf(address(vault));
        uint256 backstopBefore = usdfr.balanceOf(address(sGrove));
        _realizeLoss(nativeId, loss, keccak256("later distinct facility loss"));
        assertEq(reserves.exitPrepaidAbsorption(), remaining - reused);
        assertEq(s.supply - controller.totalUSDfr(), freshBurn);
        assertEq(s.curatorBalance - curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS), freshBurn);
        assertEq(usdfr.balanceOf(address(vault)), seniorBefore, "curator covers the fresh loss first");
        assertEq(usdfr.balanceOf(address(sGrove)), backstopBefore);
        assertTrue(controller.backingInvariantHolds());
        assertEq(controller.backingValue() - controller.totalUSDfr(),
            s.prepaid + s.extra - s.loss - reused);
    }
}
