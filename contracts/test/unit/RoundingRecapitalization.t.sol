// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NativeAccrualFixture, NativeAccrualMintableAsset} from "../helpers/NativeAccrualFixture.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";

/// @dev Exercises the measured funding call used by the rounding keeper. It grants no recovery authority.
contract RoundingRecapitalizationTest is NativeAccrualFixture {
    function setUp() public virtual override {
        super.setUp();
        _nativeFund(100_000e18);
        _nativeAdvance(nativeStart + 17 days);
    }

    function _recap(uint256 units) internal returns (uint256) {
        return reserves.recapitalize(units);
    }

    function testFuzz_recapitalizationAddsExactBackingWithoutIssuingClaims(uint64 input) public {
        uint256 units = bound(uint256(input), 1, 17);
        uint256 credited = units * _nativeScale();
        address asset = _nativeAsset();
        NativeAccrualMintableAsset(asset).mint(carol, units);
        uint256 backing = reserves.recognizedBackingValue();
        uint256 physicalSupply = usdfr.totalSupply();
        uint256 effectiveSupply = controller.totalUSDfr();
        uint256 funderBalance = IERC20(asset).balanceOf(carol);
        IContinuousAccrual.Snapshot memory before_ = reserves.accrualSnapshot();
        assertGt(before_.feeUnissued, 0, "fee preservation must be exercised");
        vm.startPrank(carol);
        IERC20(asset).approve(address(reserves), units);
        vm.expectEmit(true, false, false, true, address(reserves));
        emit IReserveManager.Recapitalized(carol, units, credited, backing + credited, 0);
        assertEq(_recap(units), credited);
        vm.stopPrank();
        assertEq(reserves.recognizedBackingValue(), backing + credited);
        assertEq(IERC20(asset).balanceOf(carol), funderBalance - units);
        assertEq(usdfr.totalSupply(), physicalSupply);
        assertEq(controller.totalUSDfr(), effectiveSupply);
        assertEq(keccak256(abi.encode(reserves.accrualSnapshot())), keccak256(abi.encode(before_)));
        assertEq(reserves.idleCustodyShortfall(), 0);
    }

    function test_missingFundingAllowanceLeavesBookUnchanged() public {
        NativeAccrualMintableAsset(_nativeAsset()).mint(carol, 1);
        uint256 backing = reserves.recognizedBackingValue();
        uint256 supply = controller.totalUSDfr();
        vm.prank(carol);
        vm.expectRevert();
        this.fundWithoutAllowance();
        assertEq(reserves.recognizedBackingValue(), backing);
        assertEq(controller.totalUSDfr(), supply);
    }

    function fundWithoutAllowance() external {
        vm.prank(carol);
        _recap(1);
    }
}
