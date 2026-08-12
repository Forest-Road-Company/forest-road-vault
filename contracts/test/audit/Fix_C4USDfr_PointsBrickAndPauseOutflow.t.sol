// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IPointsModule} from "../../src/interfaces/IPointsModule.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

/// @dev A points module that does nothing. Used only to prove the install guard still
///      admits a real contract.
contract NoopPoints is IPointsModule {
    function onSharesTransfer(address, address, uint256) external pure {}
    function onUSDfrTransfer(address, address, uint256) external pure {}
    function onCuratorStakeChange(address, uint256, uint256) external pure {}
    function onCuratorLoss(uint256, uint256, uint256) external pure {}
}

/// @title Campaign-4 USDfr findings — codeless points module, and the one-way pause carve-out
/// @notice Two HIGHs on the synthetic dollar, plus the compliance-module documentation defect
///         that falls out of the second.
///
///         C4-USDFR-01 (points brick): `setPointsModule` accepted ANY address. Solidity emits
///         an `extcodesize` guard BEFORE an external call whose callee returns no data, and
///         that guard reverts OUTSIDE the `try`. So a CODELESS points module (an EOA, a
///         precompile, an address not yet deployed) makes the fail-open hook fail CLOSED and
///         bricks every transfer, mint and burn of USDfr in one governance transaction.
///
///         C4-USDFR-02 (one-way pause): the emergency-pause carve-out permitted `x -> 0` burns
///         unconditionally while closing every inflow. A paused USDfr therefore still settled
///         user redemptions — the guardian stopped new capital arriving and left the reserve
///         draining at par, which is worse than not pausing at all.
///
///         C4-USDFR-03 (compliance doc): the registry is LOAD-BEARING for the pause carve-out,
///         so "zero = no restriction" was false — clearing it makes a pause TOTAL.
contract Fix_C4USDfrPointsBrickAndPauseOutflowTest is TokenLayerFixture {
    /// @dev `USDfrStorage.pointsModule` is the SECOND word of the ERC-7201 namespace.
    ///      keccak256(abi.encode(uint256(keccak256("forestroad.storage.USDfr")) - 1)) & ~0xff
    bytes32 private constant USDFR_STORAGE_LOCATION = 0xc3fcf06498ffe1eac01a14cc645fb1e6aacc447c7b2a7d46a005df569b521500;
    bytes32 private constant POINTS_MODULE_SLOT = bytes32(uint256(USDFR_STORAGE_LOCATION) + 1);

    // ── C4-USDFR-01: a codeless points module bricks the token ───────────

    /// @notice REGRESSION (C4-USDFR-01): the install guard rejects a plain wallet.
    function test_a_setPointsModule_rejectsCodelessWallet() public {
        address eoa = makeAddr("someOperatorWallet");
        assertEq(eoa.code.length, 0, "precondition: the candidate has no code");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("USDfr_PointsModuleNotAContract(address)", eoa));
        usdfr.setPointsModule(eoa);

        assertEq(usdfr.pointsModule(), address(0), "a codeless module must never be installed");
    }

    /// @notice REGRESSION (C4-USDFR-01): precompiles are codeless too, and calling one through
    ///         the typed interface reverts exactly the same way. `address(1)` is `ecrecover`.
    function test_a_setPointsModule_rejectsPrecompile() public {
        address precompile = address(uint160(1));
        assertEq(precompile.code.length, 0, "precondition: a precompile reports no code");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("USDfr_PointsModuleNotAContract(address)", precompile));
        usdfr.setPointsModule(precompile);
    }

    /// @notice The guard must not break the legitimate installs: a real contract, and zero
    ///         (which disables the hook entirely).
    function test_a_setPointsModule_stillAcceptsContractAndZero() public {
        NoopPoints ok = new NoopPoints();

        vm.prank(admin);
        usdfr.setPointsModule(address(ok));
        assertEq(usdfr.pointsModule(), address(ok), "a real contract installs");

        vm.prank(admin);
        usdfr.setPointsModule(address(0));
        assertEq(usdfr.pointsModule(), address(0), "zero still disables the hook");

        // and the token keeps working across both states
        _mintUSDfr(alice, 1_000e6);
        vm.prank(alice);
        usdfr.transfer(bob, 1e18);
        assertEq(usdfr.balanceOf(bob), 1e18);
    }

    /// @notice WHY THE INSTALL GUARD EXISTS. Writes a codeless address straight into the
    ///         ERC-7201 slot, bypassing the setter, and shows the consequence the guard now
    ///         prevents: EVERY transfer, mint and burn reverts. This test is green before and
    ///         after the fix — it pins the hazard, not the fix. If someone ever deletes the
    ///         guard in `setPointsModule`, THIS is the state they re-open.
    function test_a_codelessModuleBricksTransfersMintsAndBurns_hazardPin() public {
        _mintUSDfr(alice, 1_000e6);
        address eoa = makeAddr("bricker");

        vm.store(address(usdfr), POINTS_MODULE_SLOT, bytes32(uint256(uint160(eoa))));
        assertEq(usdfr.pointsModule(), eoa, "storage write landed on the points slot");

        // Transfer: bricked. The revert carries no data — it is solc's extcodesize guard,
        // which fires before the call and therefore outside the fail-open `try`.
        vm.prank(alice);
        vm.expectRevert(bytes(""));
        usdfr.transfer(bob, 1e18);

        // Mint: bricked.
        vm.prank(address(controller));
        vm.expectRevert(bytes(""));
        usdfr.mint(alice, 1e18);

        // Burn: bricked — including the loss cascade's burn leg.
        vm.prank(address(controller));
        vm.expectRevert(bytes(""));
        usdfr.burn(alice, 1e18);

        // Recovery is governance-only and takes the timelock delay: `setPointsModule` does
        // not route through `_update`, so it is still callable while the token is bricked.
        vm.prank(admin);
        usdfr.setPointsModule(address(0));
        vm.prank(alice);
        usdfr.transfer(bob, 1e18);
        assertEq(usdfr.balanceOf(bob), 1e18, "clearing the module unbricks the token");
    }

    // ── C4-USDFR-02: the pause must close the outflow, not just the inflow ─

    /// @notice REGRESSION (C4-USDFR-02): a paused USDfr no longer burns a USER's balance.
    ///         Before the fix `to == address(0)` short-circuited the whole pause branch, so
    ///         the redemption burn went through while paused.
    function test_b_pause_blocksTheUserRedemptionBurn() public {
        _mintUSDfr(alice, 10_000e6);
        vm.prank(admin);
        usdfr.setComplianceModule(address(compliance));

        vm.prank(guardian);
        usdfr.pause();

        uint256 supplyBefore = usdfr.totalSupply();
        vm.prank(address(controller));
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        usdfr.burn(alice, 1e18);
        assertEq(usdfr.totalSupply(), supplyBefore, "supply must not move while paused");
    }

    /// @notice REGRESSION (C4-USDFR-02), end to end: the reserve stops draining. The
    ///         controller itself is NOT paused here — only the token is — which is exactly the
    ///         configuration in which the old carve-out left the outflow wide open.
    function test_b_pause_stopsTheReserveOutflowEndToEnd() public {
        _mintUSDfr(alice, 10_000e6);
        vm.prank(admin);
        usdfr.setComplianceModule(address(compliance));

        vm.prank(guardian);
        usdfr.pause();
        assertFalse(controller.paused(), "precondition: only the TOKEN is paused");

        uint256 reserveUSDCBefore = usdc.balanceOf(address(reserves));
        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        controller.redeem(1_000e18);
        assertEq(usdc.balanceOf(address(reserves)), reserveUSDCBefore, "no collateral left while paused");
    }

    /// @notice LOAD-BEARING LIVENESS: the loss cascade must never be freezable by the token.
    ///         `DefaultManager.burnLoss` burns from `address(this)` or from the vault, and both
    ///         are governance-listed protocol modules, so the cascade leg survives the pause.
    ///         If this test ever goes red the pause has become a cascade deadlock.
    function test_b_pause_keepsTheProtocolModuleBurnLive() public {
        _mintUSDfr(alice, 10_000e6);
        vm.prank(alice);
        usdfr.transfer(address(vault), 5_000e18);

        vm.startPrank(admin);
        compliance.setProtocolExempt(address(vault), true);
        usdfr.setComplianceModule(address(compliance));
        vm.stopPrank();

        vm.prank(guardian);
        usdfr.pause();

        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        vm.prank(address(controller));
        usdfr.burn(address(vault), 1_000e18);
        assertEq(usdfr.balanceOf(address(vault)), vaultBefore - 1_000e18, "cascade burn survives the pause");
    }

    /// @notice The unchanged half of the carve-out, pinned so a future edit cannot widen it:
    ///         module-to-module transfers stay live, mints stay closed, user transfers stay
    ///         closed. A pause must never permit supply EXPANSION, not even a protocol leg.
    function test_b_pause_keepsModuleTransfersLiveAndAllInflowsClosed() public {
        address moduleA = makeAddr("moduleA");
        address moduleB = makeAddr("moduleB");
        vm.startPrank(admin);
        compliance.setProtocolExempt(moduleA, true);
        compliance.setProtocolExempt(moduleB, true);
        usdfr.setComplianceModule(address(compliance));
        vm.stopPrank();

        _mintUSDfr(alice, 10_000e6);
        vm.prank(alice);
        usdfr.transfer(moduleA, 1_000e18);

        vm.prank(guardian);
        usdfr.pause();

        // module -> module: live
        vm.prank(moduleA);
        usdfr.transfer(moduleB, 400e18);
        assertEq(usdfr.balanceOf(moduleB), 400e18);

        // mint to a protocol module: still closed (no supply expansion under a pause)
        vm.prank(address(controller));
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        usdfr.mint(moduleA, 1e18);

        // user -> module and module -> user: closed
        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        usdfr.transfer(moduleA, 1e18);
        vm.prank(moduleA);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        usdfr.transfer(alice, 1e18);
    }

    /// @notice A pause must not be escapable by routing through a protocol module: a user
    ///         cannot push value out to an exempt address, so the "both legs exempt" rule is
    ///         genuinely both-legs.
    function test_b_pause_cannotBeRoutedThroughAnExemptModule() public {
        vm.startPrank(admin);
        compliance.setProtocolExempt(address(vault), true);
        usdfr.setComplianceModule(address(compliance));
        vm.stopPrank();
        _mintUSDfr(alice, 10_000e6);

        vm.prank(guardian);
        usdfr.pause();

        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        usdfr.transfer(address(vault), 1e18);
    }

    // ── C4-USDFR-03: the registry is load-bearing for the pause carve-out ─

    /// @notice REGRESSION (C4-USDFR-03): the registry cannot be unwired WHILE PAUSED. Clearing
    ///         it removes the only directory of protocol modules, which would silently convert
    ///         a targeted pause into a total freeze of the loss cascade — the exact opposite of
    ///         the "zero = no restriction" the interface used to claim.
    function test_c_setComplianceModule_cannotBeClearedWhilePaused() public {
        vm.prank(admin);
        usdfr.setComplianceModule(address(compliance));
        vm.prank(guardian);
        usdfr.pause();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("USDfr_ComplianceModuleRequiredWhilePaused()"));
        usdfr.setComplianceModule(address(0));
        assertEq(usdfr.complianceModule(), address(compliance), "the registry stays wired");

        // replacing it with ANOTHER registry stays legal while paused — only clearing is barred
        vm.prank(admin);
        usdfr.setComplianceModule(address(compliance));
    }

    /// @notice The documented capability survives: clearing the registry is still permitted
    ///         while the token is live, and it still removes the sanctions gate.
    function test_c_setComplianceModule_zeroStillAllowedWhileUnpaused() public {
        _mintUSDfr(alice, 1_000e6);
        vm.startPrank(admin);
        usdfr.setComplianceModule(address(compliance));
        usdfr.setComplianceModule(address(0));
        vm.stopPrank();
        assertEq(usdfr.complianceModule(), address(0), "zero remains a legal live-state setting");

        vm.prank(complianceAdmin);
        compliance.setJurisdictionBlocked(bob, true);
        vm.prank(alice);
        usdfr.transfer(bob, 1e18); // ungated: the registry is not consulted
        assertEq(usdfr.balanceOf(bob), 1e18);
    }

    /// @notice HONEST RESIDUAL (C4-USDFR-03): with NO registry wired there is no way to
    ///         identify a protocol module, so a pause is TOTAL — the cascade burn is frozen
    ///         too. That is the safe direction and it is recoverable in one governance call,
    ///         but it is a real operating constraint and it is pinned here rather than assumed.
    function test_c_pauseWithNoRegistryIsTotalAndRecoverable() public {
        _mintUSDfr(alice, 1_000e6);
        vm.prank(alice);
        usdfr.transfer(address(vault), 500e18);
        assertEq(usdfr.complianceModule(), address(0), "precondition: no registry wired");

        vm.prank(guardian);
        usdfr.pause();

        vm.prank(address(controller));
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        usdfr.burn(address(vault), 1e18);

        // Recovery: wiring the registry while paused restores the protocol carve-out.
        vm.startPrank(admin);
        compliance.setProtocolExempt(address(vault), true);
        usdfr.setComplianceModule(address(compliance));
        vm.stopPrank();

        vm.prank(address(controller));
        usdfr.burn(address(vault), 1e18);
        assertEq(usdfr.balanceOf(address(vault)), 499e18, "cascade leg restored without unpausing");
    }
}
