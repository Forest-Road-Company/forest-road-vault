// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {IsUSDfr} from "../../src/interfaces/IsUSDfr.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @dev ADVERSARIAL LIVENESS PROBES: things that SHOULD settle. R18's NatSpec claims a guardian
///      pause on either the controller or USDfr now WITHHOLDS rather than reverting, so no single
///      key can stop borrower repayments. These probe that claim and its neighbours.
contract ADV_Liveness is CreditLayerFixture {
    bytes32 internal constant EV = keccak256("adv-liveness");

    /// @notice L1. Controller paused: the repayment must still settle (R18 claim (2)).
    function test_L1_repaymentSurvivesControllerPause() public {
        uint256 id = _liveFilmFacility(300_000e18);
        vm.prank(guardian);
        controller.pause();
        _repay(id, 5_000e18, 20_000e18);
        assertEq(reserves.deployedTo(id), 280_000e18, "L1: repayment refused under controller pause");
    }

    /// @notice L2. USDfr token paused: same claim (R18 claim (4)).
    function test_L2_repaymentSurvivesUsdfrPause() public {
        uint256 id = _liveFilmFacility(300_000e18);
        vm.prank(guardian);
        usdfr.pause();
        _repay(id, 5_000e18, 20_000e18);
        assertEq(reserves.deployedTo(id), 280_000e18, "L2: repayment refused under USDfr pause");
    }

    /// @notice L3. sUSDfr vault paused. `distribute` calls `accrueFees()` UNCONDITIONALLY, on both
    ///         the interest and the pure-principal branch.
    function test_L3_repaymentSurvivesVaultPause() public {
        uint256 id = _liveFilmFacility(300_000e18);
        vm.prank(guardian);
        vault.pause();
        _repay(id, 0, 20_000e18);
        assertEq(reserves.deployedTo(id), 280_000e18, "L3: pure principal refused under vault pause");
    }

    /// @notice L4. THE FEE-OPERATION LATCH. `sUSDfr.accrueFees()` carries `feeCheckpointEntry`,
    ///         which reverts while ANY fee operation is open. `WaterfallEngine.distribute` calls
    ///         `accrueFees()` on every path, so an open operation stops every borrower repayment
    ///         protocol-wide — including a pure principal recovery that moves no supply at all.
    function test_L4_openFeeOperationBricksEveryRepayment() public {
        uint256 id = _liveFilmFacility(300_000e18);
        address feeActor = makeAddr("fee-accounting-actor");
        vm.prank(admin);
        vault.grantRole(Roles.FEE_ACCOUNTING_ROLE, feeActor);
        vm.prank(feeActor);
        vault.beginFeeNeutralMarkedNavChange(); // opened and never closed

        IWaterfallEngine.Payment memory p = _preparePayment(id, 0, 20_000e18);
        vm.prank(servicer);
        vm.expectRevert(IsUSDfr.SUSDfr_FeeAccrualReentrant.selector);
        waterfall.distribute(p);

        // The only cure is DEFAULT_ADMIN (the governance timelock), not the guardian.
        vm.prank(admin);
        vault.clearStaleFeeOperation();
        vm.prank(servicer);
        waterfall.distribute(p);
        assertEq(reserves.deployedTo(id), 280_000e18, "L4: cure did not restore servicing");
    }
}
