// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PointsModule} from "../../src/PointsModule.sol";
import {PointsHookGas, PointsHook_InsufficientGas} from "../../src/libraries/PointsHookGas.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

/// @notice Regression for the 2026-08-14 Sepolia deployment failure.
///
///         `Fix_F1802-points-hook-gas-floor.t.sol` proves the points-hook gas FLOOR fails closed
///         against a caller that deliberately underfunds. Those tests assert the lock works. None
///         asserted the inverse property, and that is the one that broke a live deployment: an
///         HONEST caller, provisioning gas the way a simulation-derived estimator does, cannot
///         clear the floor.
///
///         `forge script` sizes each broadcast transaction as (simulated consumption x 1.30).
///         Under simulation `gasleft()` is enormous, so the floor never binds and the recorded
///         consumption does not include it. On Sepolia the seed mint was sent with 436,894 gas,
///         reached the hook with 144,478 available against the 500,000 floor, and reverted --
///         leaving the vault deployed and unseeded, the state `NEXT_SESSION.md` section 3 warns
///         permanently ratchets the high-water mark.
///
///         This class of defect is structurally invisible to the rest of the suite: `forge test`
///         runs with an effectively unlimited gas budget, so the floor never binds there either.
///         These tests bind it deliberately.
///
///         THE OPERATIONAL LESSON, pinned by `test_multiplierIsTheWrongInstrument` below: the
///         floor is an ABSOLUTE constant, not a proportion of consumption, so no single
///         `--gas-estimate-multiplier` is correct for a script. The multiplier a call needs
///         varies INVERSELY with how cheap that call is, so the cheapest points-touching call in
///         a script sets the requirement for the whole run.
///
///         This is NOT a defect in `PointsHookGas`. The floor is a deliberate F-18-02 control.
///         What is pinned here is the caller-side provisioning contract that the floor imposes.
contract PointsHookGasProvisioningTest is TokenLayerFixture {
    PointsModule internal points;

    /// @dev The multiplier `forge script` applies to simulated consumption by default.
    uint256 internal constant FORGE_DEFAULT_MULTIPLIER_BPS = 13_000;

    function setUp() public override {
        super.setUp();
        points = PointsModule(
            address(
                new ERC1967Proxy(
                    address(new PointsModule()),
                    abi.encodeCall(
                        PointsModule.initialize, (admin, admin, address(compliance), address(vault), address(usdfr))
                    )
                )
            )
        );
        vm.startPrank(admin);
        vault.setPointsModule(address(points));
        usdfr.setPointsModule(address(points));
        vm.stopPrank();
    }

    /// @dev Funds alice and returns a transfer size that leaves ample balance for repeat sends.
    function _fundAlice() internal returns (uint256 amount) {
        _mintUSDfr(alice, 1_000e6);
        uint256 bal = usdfr.balanceOf(alice);
        assertGt(bal, 0, "fixture must fund alice with USDfr");
        amount = bal / 100; // 1% per send, so every case below has headroom
        assertGt(amount, 0, "transfer size must be non-zero");
    }

    /// @dev Measures what a USDfr transfer consumes when gas is not scarce. The floor is not
    ///      reached here precisely because `gasleft()` is large -- which is the whole defect.
    function _measureTransferConsumption(uint256 amount) internal returns (uint256 consumed) {
        uint256 before = gasleft();
        vm.prank(alice);
        usdfr.transfer(bob, amount);
        consumed = before - gasleft();
        assertGt(consumed, 0, "measurement must observe real consumption");
    }

    /// @notice THE REGRESSION. A simulation-derived budget cannot clear the floor.
    /// @dev This is the exact shape of the failed seed mint.
    function test_simulationDerivedGasBudget_cannotClearTheHookFloor() public {
        uint256 amount = _fundAlice();
        uint256 consumed = _measureTransferConsumption(amount);

        uint256 forgeBudget = (consumed * FORGE_DEFAULT_MULTIPLIER_BPS) / 10_000;
        assertLt(forgeBudget, PointsHookGas.MINIMUM_GAS, "premise: the default budget sits under the floor");

        vm.prank(alice);
        (bool ok, bytes memory ret) =
            address(usdfr).call{gas: forgeBudget}(abi.encodeCall(usdfr.transfer, (bob, amount)));

        assertFalse(ok, "an honest caller on a simulation-derived budget must still fail closed");
        assertEq(bytes4(ret), PointsHook_InsufficientGas.selector, "must fail on the points-hook floor, not elsewhere");
    }

    /// @notice Pins the headroom the floor demands ABOVE what the call actually consumes.
    /// @dev Asserted as a relationship, not a literal, so it tracks `MINIMUM_GAS` if that is
    ///      retuned. This is the number an integrator or runbook needs.
    function test_requiredHeadroom_isTheDeclaredFloor() public {
        uint256 amount = _fundAlice();
        uint256 consumed = _measureTransferConsumption(amount);

        // Just under the floor: must fail closed.
        vm.prank(alice);
        (bool tooLow,) =
            address(usdfr).call{gas: PointsHookGas.MINIMUM_GAS - 1}(abi.encodeCall(usdfr.transfer, (bob, amount)));
        assertFalse(tooLow, "a budget below the declared floor must revert");

        // Consumption plus the floor plus the retained epilogue: must clear.
        uint256 sufficient = consumed + PointsHookGas.MINIMUM_GAS + PointsHookGas.POST_HOOK_RESERVE;
        vm.prank(alice);
        (bool ok,) = address(usdfr).call{gas: sufficient}(abi.encodeCall(usdfr.transfer, (bob, amount)));
        assertTrue(ok, "consumption plus the declared floor and epilogue reserve must clear the hook");
    }

    /// @notice Pins WHY a single `--gas-estimate-multiplier` cannot be correct for a whole script.
    /// @dev The floor is absolute; the multiplier is proportional. The cheaper the call, the
    ///      larger the multiplier it needs. A script must therefore be provisioned for its
    ///      CHEAPEST points-touching call, not its average. If this ever stops holding, the
    ///      floor has become proportional and the runbook guidance can be simplified.
    function test_multiplierIsTheWrongInstrument() public {
        uint256 amount = _fundAlice();
        uint256 consumed = _measureTransferConsumption(amount);

        // The multiplier this specific call would need, in basis points.
        uint256 requiredBps =
            ((consumed + PointsHookGas.MINIMUM_GAS + PointsHookGas.POST_HOOK_RESERVE) * 10_000) / consumed;

        // A cheap transfer needs a far larger multiplier than the 300% that sufficed for the
        // (much more expensive) seed mint -- demonstrating the instrument does not generalise.
        assertGt(requiredBps, 30_000, "a cheap points-touching call needs more than a 300 percent multiplier");

        // And the requirement really is driven by the absolute floor, not by consumption.
        assertGe(
            (consumed * requiredBps) / 10_000,
            PointsHookGas.MINIMUM_GAS,
            "the derived multiplier must clear the absolute floor"
        );
    }
}
