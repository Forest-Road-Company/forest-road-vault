// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPointsModule} from "../../src/interfaces/IPointsModule.sol";
import {Config} from "../../src/libraries/Config.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @dev Control module: a real contract that does nothing.
contract NoopCuratorPoints is IPointsModule {
    function onSharesTransfer(address, address, uint256) external pure {}
    function onUSDfrTransfer(address, address, uint256) external pure {}
    function onCuratorStakeChange(address, uint256, uint256) external pure {}
    function onCuratorLoss(uint256, uint256, uint256) external pure {}
}

/// @title P-48b — the THIRD unguarded `setPointsModule`, on the curator first-loss layer
/// @notice `USDfr.setPointsModule` refuses a codeless module (C4-USDFR-01, a remediated HIGH).
///         `SUSDfr.setPointsModule` did not (P-48). `CuratorModule.setPointsModule`
///         (src/CuratorModule.sol:316) does not either, and its hooks have the same
///         no-return-data shape that makes solc emit an `extcodesize` guard OUTSIDE the `try`:
///
///           - `_notifyPoints` :1464  `try pm.onCuratorStakeChange(...) {} catch {}`
///           - `absorbLoss`    :609   `try pm.onCuratorLoss(...) {} catch {}`
///           - `:663`                 `try pm.onCuratorLoss(...) {} catch {}`
///
///         WHY THIS ONE MATTERS MOST. The source declares the fail-open property as
///         load-bearing, in terms, at both sites:
///
///           :605  "FAIL-OPEN — never block the never-pausable cascade."
///           :1458 "FAIL-OPEN — a points failure must never block first-loss post/withdraw
///                  (which are cascade-relevant capital movements)."
///
///         A codeless module would make the fail-open hook fail CLOSED and defeat exactly the
///         property those comments promise — on the layer that absorbs losses FIRST in the
///         CLAUDE.md §1.3 cascade.
///
///         MEASURED, NOT INFERRED. Every assertion below is mechanism-agnostic (low-level call,
///         success/failure only). This file states what the tree does today; it presumes no
///         remedy and asserts nothing about how a fix should be shaped.
contract P48bCuratorCodelessPointsModuleTest is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;

    /// @dev Reach the bricked state through the ERC-7201 slot rather than the setter, so the
    ///      hazard pins below stay GREEN after a fix (the setter then refuses this address —
    ///      which is the discriminator's job to assert, not theirs).
    function _storeCuratorPoints(address module) internal {
        bytes32 base =
            keccak256(abi.encode(uint256(keccak256("forestroad.storage.CuratorModule")) - 1)) & ~bytes32(uint256(0xff));
        for (uint256 i = 0; i < 24; ++i) {
            bytes32 slot = bytes32(uint256(base) + i);
            bytes32 before = vm.load(address(curator), slot);
            vm.store(address(curator), slot, bytes32(uint256(uint160(module))));
            if (curator.pointsModule() == module) return;
            vm.store(address(curator), slot, before);
        }
        revert("could not locate the curator points-module slot");
    }

    /// @notice ⚠ THE DISCRIMINATOR — the only test here expected to flip. Mechanism-agnostic:
    ///         asserts only that the install FAILS, so any correct remedy satisfies it.
    ///         Paired with `test_P48b_control_theSetterStillAcceptsARealContractAndZero`, which
    ///         is green in BOTH arms and rules out "refuse every module".
    function test_P48b_DISCRIMINATOR_theCuratorSetterMustRefuseACodelessModule() public {
        address eoa = makeAddr("codeless-curator-points");
        assertEq(eoa.code.length, 0, "precondition: the address really is codeless");

        vm.prank(admin);
        (bool installed,) = address(curator).call(abi.encodeWithSignature("setPointsModule(address)", eoa));

        assertFalse(installed, "the curator module must refuse a codeless points module, as USDfr does");
        assertEq(curator.pointsModule(), address(0), "and must not have installed it");
    }

    /// @notice CONTROL — green in BOTH arms: a real contract and zero must still be accepted.
    function test_P48b_control_theSetterStillAcceptsARealContractAndZero() public {
        NoopCuratorPoints real = new NoopCuratorPoints();
        vm.prank(admin);
        curator.setPointsModule(address(real));
        assertEq(curator.pointsModule(), address(real), "a real contract module must still install");

        vm.prank(admin);
        curator.setPointsModule(address(0));
        assertEq(curator.pointsModule(), address(0), "clearing to zero must still be permitted");
    }

    /// @notice Does it brick `postFirstLoss` — the capital movement the :1458 comment says a
    ///         points failure must never block?
    function test_P48b_hazardPin_bricksFirstLossPosting() public {
        // Baseline: posting works before the module is installed.
        _postFirstLoss(anchorCurator, FILM, 100_000e18);

        _storeCuratorPoints(makeAddr("codeless-curator-points"));

        vm.prank(anchorCurator);
        (bool ok,) =
            address(curator).call(abi.encodeWithSignature("postFirstLoss(uint256,uint256)", FILM, uint256(1_000e18)));

        assertFalse(ok, "MEASURED: a codeless points module blocks first-loss posting, defeating the stated fail-open");
    }

    /// @notice Does it brick `withdrawFirstLoss` — curator capital exit?
    function test_P48b_hazardPin_bricksFirstLossWithdrawal() public {
        _postFirstLoss(anchorCurator, FILM, 100_000e18);

        _storeCuratorPoints(makeAddr("codeless-curator-points"));

        vm.prank(anchorCurator);
        (bool ok,) = address(curator).call(
            abi.encodeWithSignature("withdrawFirstLoss(uint256,uint256)", FILM, uint256(1_000e18))
        );

        assertFalse(ok, "MEASURED: a codeless points module blocks first-loss withdrawal");
    }

    /// @notice THE ONE THAT MATTERS. Does it brick `absorbLoss` — layer 1 of the §1.3 cascade,
    ///         which the :605 comment says must NEVER be blocked?
    function test_P48b_hazardPin_bricksTheCascadeAbsorbLeg() public {
        _postFirstLoss(anchorCurator, FILM, 100_000e18);

        _storeCuratorPoints(makeAddr("codeless-curator-points"));

        vm.prank(address(defaultManager));
        (bool ok,) =
            address(curator).call(abi.encodeWithSignature("absorbLoss(uint256,uint256)", FILM, uint256(10_000e18)));

        assertFalse(ok, "MEASURED: a codeless points module blocks the cascade's curator first-loss absorb leg");
    }

    /// @notice CONTROL — a REAL contract module leaves every path above working, so the failures
    ///         are caused by CODELESSNESS and not by installing a module, nor by the fixture.
    function test_P48b_control_aRealModuleLeavesEveryPathWorking() public {
        _postFirstLoss(anchorCurator, FILM, 100_000e18);

        // Deploy FIRST: `new` is itself a call and would consume the prank, leaving
        // `setPointsModule` to be sent by the test contract (which holds no admin role).
        NoopCuratorPoints real = new NoopCuratorPoints();
        vm.prank(admin);
        curator.setPointsModule(address(real));

        _postFirstLoss(anchorCurator, FILM, 1_000e18);

        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 1_000e18);

        vm.prank(address(defaultManager));
        (uint256 absorbed,) = curator.absorbLoss(FILM, 10_000e18);
        assertGt(absorbed, 0, "the cascade absorb leg works with a real module installed");
    }
}
