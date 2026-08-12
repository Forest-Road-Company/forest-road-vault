// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPointsModule} from "../../src/interfaces/IPointsModule.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

/// @dev A real contract that does nothing. The control: proves any brick observed below is
///      caused by CODELESSNESS, not by installing a module at all.
contract NoopVaultPoints is IPointsModule {
    function onSharesTransfer(address, address, uint256) external pure {}
    function onUSDfrTransfer(address, address, uint256) external pure {}
    function onCuratorStakeChange(address, uint256, uint256) external pure {}
    function onCuratorLoss(uint256, uint256, uint256) external pure {}
}

/// @title P-48 investigation — is `SUSDfr.setPointsModule` the unremediated sibling of C4-USDFR-01?
/// @notice The §5 Definition-of-Done pass (2026-08-11) named this BLOCKING for publication but
///         recorded it as INFERRED, not executed:
///
///           "HONESTY: I did NOT execute a test to confirm the vault brick; I inferred it from the
///            repo's own measured USDfr result plus the identical no-return-data call shape."
///
///         This file executes it. `USDfr.setPointsModule` (src/USDfr.sol:143) refuses a codeless
///         module with `USDfr_PointsModuleNotAContract` as the remediation of a documented HIGH.
///         `SUSDfr.setPointsModule` (src/sUSDfr.sol:690) carries no such check, and `SUSDfr._update`
///         (:1387) calls `try points.onSharesTransfer{gas}(...)` — a function that, like
///         `onUSDfrTransfer`, returns NO DATA, which is the precondition for solc to emit the
///         `extcodesize` guard that fires OUTSIDE the `try`.
///
///         NOTE THE DIFFERENCE FROM THE USDfr HAZARD PIN. That test
///         (`Fix_C4USDfr_PointsBrickAndPauseOutflow.t.sol:91`) must use `vm.store` to write the
///         slot directly, precisely BECAUSE the setter refuses. Here the module is installed
///         through the ordinary public setter by the ordinary admin role. If these tests are
///         green, one timelocked governance call reaches the state USDfr treats as a HIGH.
///
///         Assertions are deliberately MECHANISM-AGNOSTIC where the remedy is undecided: the
///         install test asserts only that the setter ACCEPTS, and the brick tests assert only
///         that the share move FAILS. Any correct fix — a code-length guard, a try-wrapped
///         probe, an interface check — flips them, and none is presumed here.
contract P48VaultCodelessPointsModuleTest is TokenLayerFixture {
    function _seedShares(address user, uint256 usdcAmount) internal returns (uint256 shares) {
        uint256 assets = _mintUSDfr(user, usdcAmount);
        vm.startPrank(user);
        usdfr.approve(address(vault), assets);
        shares = vault.deposit(assets, user);
        vm.stopPrank();
    }

    /// @dev ERC-7201 slot of the vault's points module, so the hazard pins below can reach the
    ///      bricked state WITHOUT the setter — which is what lets them stay green after a fix.
    ///      Derived at runtime from the live wiring rather than hard-coded.
    function _storePointsModule(address module) internal {
        // ERC-7201: keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff))
        bytes32 base =
            keccak256(abi.encode(uint256(keccak256("forestroad.storage.SUSDfr")) - 1)) & ~bytes32(uint256(0xff));
        for (uint256 i = 0; i < 8; ++i) {
            bytes32 slot = bytes32(uint256(base) + i);
            bytes32 before = vm.load(address(vault), slot);
            vm.store(address(vault), slot, bytes32(uint256(uint160(module))));
            if (vault.pointsModule() == module) return;
            vm.store(address(vault), slot, before);
        }
        revert("could not locate the vault points-module slot");
    }

    // ── THE DISCRIMINATOR: RED before the fix, GREEN after ────────────────

    /// @notice ⚠ THIS IS THE ONLY TEST IN THE FILE THAT IS EXPECTED TO FLIP.
    ///         The vault's setter must refuse a codeless module, as the token's already does.
    ///         Mechanism-agnostic by design — a low-level call asserting only that the install
    ///         FAILS — so any correct remedy (code-length guard, try-wrapped probe, ERC-165
    ///         check) satisfies it and none is presumed.
    ///
    ///         Its paired control is `test_P48_control_theSetterStillAcceptsARealContractAndZero`,
    ///         which is green in BOTH arms and rules out the inadmissible "fix" of refusing every
    ///         module.
    function test_P48_DISCRIMINATOR_theVaultSetterMustRefuseACodelessModule() public {
        address eoa = makeAddr("codeless-points-module");
        assertEq(eoa.code.length, 0, "precondition: the address really is codeless");

        vm.prank(admin);
        (bool installed,) = address(vault).call(abi.encodeWithSignature("setPointsModule(address)", eoa));

        assertFalse(installed, "the vault must refuse a codeless points module, as USDfr does");
        assertEq(vault.pointsModule(), address(0), "and must not have installed it");
    }

    /// @notice THE ASYMMETRY, HALF OF WHICH FLIPS. The token's guard is asserted here so that if
    ///         anyone ever deletes IT, this file reds too. The vault half lives in the
    ///         discriminator above.
    function test_P48_theTokenRefusesACodelessModule_bothArms() public {
        address eoa = makeAddr("codeless-points-module");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("USDfr_PointsModuleNotAContract(address)", eoa));
        usdfr.setPointsModule(eoa);
        assertEq(usdfr.pointsModule(), address(0), "the token refuses a codeless module");
    }

    // ── HAZARD PINS: green in BOTH arms, via the slot, not the setter ─────

    /// @notice WHY THE GUARD IS NEEDED — the consequence, executed. Reaches the bricked state by
    ///         writing the slot directly, exactly as the USDfr hazard pin does, so this test
    ///         documents the hazard rather than the fix and stays green afterwards. If someone
    ///         deletes the guard, THIS is the state they re-open.
    function test_P48_hazardPin_aCodelessModuleBricksShareTransfers() public {
        uint256 shares = _seedShares(alice, 1_000e6);
        assertGt(shares, 0, "precondition: alice holds shares");

        _storePointsModule(makeAddr("codeless-points-module"));

        vm.prank(alice);
        (bool ok,) = address(vault).call(abi.encodeWithSignature("transfer(address,uint256)", bob, shares / 2));
        assertFalse(ok, "MEASURED: a codeless points module bricks share transfers");
    }

    /// @notice The brick reaches the ERC-4626 legs too. `_update` covers mint and burn, so it
    ///         closes deposit AND redeem — i.e. the SENIOR EXIT — not merely p2p transfers.
    function test_P48_hazardPin_aCodelessModuleBricksDepositAndRedeem() public {
        _seedShares(alice, 1_000e6);
        uint256 spare = _mintUSDfr(bob, 500e6);

        _storePointsModule(makeAddr("codeless-points-module"));

        vm.startPrank(bob);
        usdfr.approve(address(vault), spare);
        (bool depositOk,) = address(vault).call(abi.encodeWithSignature("deposit(uint256,address)", spare, bob));
        vm.stopPrank();
        assertFalse(depositOk, "MEASURED: deposit (share mint) is bricked");

        vm.prank(alice);
        (bool redeemOk,) =
            address(vault).call(abi.encodeWithSignature("redeem(uint256,address,address)", uint256(1e18), alice, alice));
        assertFalse(redeemOk, "MEASURED: redeem (share burn) is bricked - the senior exit is closed");
    }

    /// @notice CONTROL 0 — green in BOTH arms. The setter must keep accepting a real contract and
    ///         zero. Without this, "refuse every module" would satisfy the discriminator.
    function test_P48_control_theSetterStillAcceptsARealContractAndZero() public {
        NoopVaultPoints real = new NoopVaultPoints();

        vm.prank(admin);
        vault.setPointsModule(address(real));
        assertEq(vault.pointsModule(), address(real), "a real contract module must still install");

        vm.prank(admin);
        vault.setPointsModule(address(0));
        assertEq(vault.pointsModule(), address(0), "clearing to zero must still be permitted");
    }

    /// @notice CONTROL 1 — a REAL contract module installs and share transfers keep working.
    ///         Without this, the two tests above would also pass against a vault that simply
    ///         refuses every points module, or every transfer.
    function test_P48_control_aRealContractModuleLeavesTransfersWorking() public {
        uint256 shares = _seedShares(alice, 1_000e6);
        NoopVaultPoints real = new NoopVaultPoints();

        vm.prank(admin);
        vault.setPointsModule(address(real));

        vm.prank(alice);
        assertTrue(vault.transfer(bob, shares / 2), "the transfer reports success");
        assertEq(vault.balanceOf(bob), shares / 2, "a real module leaves the vault fully functional");
    }

    /// @notice CONTROL 2 — the pre-existing state transfers fine, so the brick is caused by the
    ///         install and not by the fixture. Also pins the recovery path: `setPointsModule`
    ///         does not route through `_update`, so governance can still clear it.
    function test_P48_control_noModuleWorks_andClearingRecovers() public {
        uint256 shares = _seedShares(alice, 1_000e6);

        vm.prank(alice);
        assertTrue(vault.transfer(bob, shares / 4), "the transfer reports success");
        assertEq(vault.balanceOf(bob), shares / 4, "baseline: transfers work with no module installed");

        // Reached through the SLOT, not the setter, so this control holds in both arms — after
        // the fix the setter refuses this address, which is the discriminator's job to assert.
        _storePointsModule(makeAddr("codeless-points-module"));

        vm.prank(admin);
        vault.setPointsModule(address(0));

        vm.prank(alice);
        assertTrue(vault.transfer(bob, shares / 4), "the transfer reports success");
        assertEq(vault.balanceOf(bob), shares / 2, "clearing the module recovers the vault");
    }
}
