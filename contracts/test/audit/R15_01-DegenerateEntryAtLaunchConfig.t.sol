// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {SUSDfr} from "../../src/sUSDfr.sol";

/// @title R15-01 — the degenerate-entry guard at the LAUNCH vesting configuration
/// @notice REMEDIATED (full-delta round). These began as characterization tests of a live bypass
///         and were INVERTED when the collapsed-price band landed, per the standing rule that a
///         finding's reproduction is inverted rather than deleted. Each `test_fixed_*` below fails
///         against the pre-fix predicate, so together they are the regression for R15-01.
///
/// @dev THE COMPOSITION. `_isDegenerate()` has two clauses: the zero-base point
///      (`totalAssets() == 0`) and the stranded-stream band (`unvestedYield() > K * totalAssets()`).
///      Its own rationale argues at length that a point test is insufficient — "the hazard is NOT
///      the `totalAssets() == 0` POINT — it is the whole neighbourhood".
///
///      ADR-0023's launch decision set the vesting window to zero. `unvestedYield()` is then
///      identically zero, so the band clause evaluates `0 > K * assets` — false in every reachable
///      state. At launch the predicate IS the point test its author rejected.
///
///      Neither slice is wrong alone. The vesting window is a documented economic parameter, and
///      `_isDegenerate` is byte-identical to its pre-ADR-0031 form. The defect is their
///      composition, which is why six incremental rounds did not surface it: every existing
///      `_isDegenerate` test runs at a NON-ZERO window (see
///      `Fix_H3-vesting-period-crystallization.t.sol`, whose `setUp` sets 7 days), so none of them
///      exercises the shipped configuration.
///
///      REACHABILITY IS OPERATIONAL, NOT CONTRIVED. `DefaultManager.realizeLoss` reverts when
///      `vaultAssets < depositorLoss` with a STRICT `<`, so a loss exceeding senior capacity forces
///      the servicer to realize exactly the maximum — landing precisely on `totalAssets() == 0`
///      with full share supply outstanding. Before the fix a single permissionless USDfr transfer
///      of one wei re-opened entry from there; the band now holds it closed.
contract R15_01DegenerateEntryAtLaunchConfigTest is CreditLayerFixture {
    /// @dev Drives the vault to the exact wipe boundary at the LAUNCH configuration.
    function _wipeSeniorLayerAtLaunchConfig() internal returns (uint256 supplyAfterWipe) {
        assertEq(vault.yieldVestingPeriod(), 0, "this suite must run at the launch vesting policy");

        _mintUSDfrTo(alice, 400_000e18);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 400_000e18);
        vault.deposit(400_000e18, alice);
        vm.stopPrank();

        uint256 id = _liveFilmFacility(500_000e18);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        // The maximum the strict `<` bound admits: depositorLoss == vaultAssets.
        uint256 vested = vault.totalAssets();
        vm.prank(servicer);
        _realizeLoss(id, vested, FILM_REF);

        assertEq(vault.totalAssets(), 0, "senior layer written down to nothing");
        assertEq(vault.unvestedYield(), 0, "no stream exists at the launch window, so none is stranded");
        supplyAfterWipe = vault.totalSupply();
        assertGt(supplyAfterWipe, 0, "shares remain outstanding against a zero base");
    }

    // ── the guard does fire at the exact point ───────────────────────────

    /// @notice CONTROL. At `totalAssets() == 0` the point clause fires and entry is closed loudly.
    function test_control_entryIsClosedAtTheExactZeroBasePoint() public {
        uint256 supply = _wipeSeniorLayerAtLaunchConfig();

        assertEq(vault.maxDeposit(bob), 0, "capacity view agrees entry is closed");

        _mintUSDfrTo(bob, 1e18);
        vm.startPrank(bob);
        usdfr.approve(address(vault), 1e18);
        vm.expectRevert(abi.encodeWithSelector(SUSDfr.SUSDfr_DegenerateSharePrice.selector, supply, uint256(0)));
        vault.deposit(1e18, bob);
        vm.stopPrank();
    }

    // ── the finding: one wei steps off the point ─────────────────────────

    /// @notice R15-01 REGRESSION. A permissionless one-wei USDfr transfer moves the vault off the
    ///         measure-zero point. Entry must STAY closed: the collapsed-price band keys on the
    ///         high-water mark, which the wipe did not lower and the donation cannot raise.
    function test_fixed_oneWeiDonationDoesNotReopenEntry() public {
        uint256 supply = _wipeSeniorLayerAtLaunchConfig();

        // Anyone holding USDfr can do this. The vault is protocol-exempt, so compliance does not
        // block it, and nothing else in the vault reacts to a bare balance increase.
        _mintUSDfrTo(bob, 2e18);
        vm.prank(bob);
        usdfr.transfer(address(vault), 1);

        assertEq(vault.totalAssets(), 1, "the base is one wei: off the point, still degenerate");
        assertEq(vault.maxDeposit(bob), 0, "the capacity view must stay closed off the point");

        // The price is still degenerate, which is exactly why entry must not reopen.
        assertGt(vault.previewDeposit(1e18), supply, "a 1-USDfr deposit would still out-mint the supply");

        vm.startPrank(bob);
        usdfr.approve(address(vault), 1e18);
        vm.expectRevert(abi.encodeWithSelector(SUSDfr.SUSDfr_DegenerateSharePrice.selector, supply, uint256(1)));
        vault.deposit(1e18, bob);
        vm.stopPrank();
    }

    /// @notice R15-01 REGRESSION, the load-bearing one. A threshold keyed on "would this deposit
    ///         out-mint the supply" is defeated by simply donating more, so the band must hold
    ///         across donation sizes rather than at one point. Entry stays closed until the vault
    ///         is genuinely recapitalized — here, until the realized rate recovers past 1% of the
    ///         high-water mark, at which point it opens again as it must (a permanently closed
    ///         vault would be its own defect).
    function test_fixed_bandHoldsAcrossDonationSizesUntilGenuineRecapitalization() public {
        uint256 supply = _wipeSeniorLayerAtLaunchConfig();

        // Escalating donations, each far beyond a token amount, all still inside the band.
        uint256[4] memory donations = [uint256(1e12), 1e15, 1e18, 100e18];
        for (uint256 i = 0; i < donations.length; ++i) {
            uint256 snap = vm.snapshotState();
            _mintUSDfrTo(bob, donations[i] + 1e18);
            vm.prank(bob);
            usdfr.transfer(address(vault), donations[i]);

            assertEq(vault.maxDeposit(bob), 0, "the band must not be escapable by donating more");
            vm.startPrank(bob);
            usdfr.approve(address(vault), 1e18);
            vm.expectRevert(abi.encodeWithSelector(SUSDfr.SUSDfr_DegenerateSharePrice.selector, supply, donations[i]));
            vault.deposit(1e18, bob);
            vm.stopPrank();
            vm.revertToState(snap);
        }

        // AND it opens again on genuine recapitalization. Alice staked 400,000 against a par
        // high-water mark, so restoring ~1% of that clears the band and entry resumes.
        _mintUSDfrTo(bob, 10_000e18);
        vm.prank(bob);
        usdfr.transfer(address(vault), 10_000e18);
        assertGt(vault.maxDeposit(bob), 0, "a recapitalized vault must reopen; the band is not a latch");
    }
}
