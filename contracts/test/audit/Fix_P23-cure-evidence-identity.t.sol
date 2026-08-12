// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {RealOracleFixture} from "../helpers/RealOracleFixture.sol";

/// @notice P-23 discriminator — the C4-01 zero-evidence guard on `clearPastDue`.
/// @dev WRITTEN BY THE AUDIT STREAM, NOT BY THE STREAM THAT FIXES IT. That separation is the point:
///      the merge dropped this guard and every existing test stayed green, because the sole test
///      asserting `DefaultManager_ZeroEvidenceHash` exercises `realizeLoss` — the guard that
///      survived (`Fix_C401FactReplay.t.sol:252`). Nothing covered `clearPastDue`.
///
///      THE THREE TREES, MEASURED 2026-08-11:
///        three-input  `DefaultManager.sol:284` (realizeLoss) AND `:480` (clearPastDue) — both guarded
///        W7 / input 1  neither guarded
///        four-input merge `279cad0`  realizeLoss guarded at `:482`; clearPastDue NOT guarded
///
///      So this is a W7-vs-input-2 collision resolved in W7's favour, reverting a landed audit fix
///      with nothing recorded — the second instance of the P-19 shape at the same boundary.
///
///      WHY IT MATTERS. `clearPastDue` derives its durable fact key as
///      `keccak256(abi.encode(tokenId, evidenceHash))`. With a zero hash accepted, EVERY past-due
///      cure for a given `tokenId` collapses onto one key, so the ledger cannot distinguish two cure
///      events for two different due revisions. That is exactly the ambiguity C4-01 closed, and it
///      cuts against CLAUDE.md §3.1: the on-chain register must be reconstructable purely from
///      events. It is NOT a High — no value moves on this path and the cascade is unaffected.
///
///      HOW TO READ THIS FILE. It is a discriminator, so it is two-sided by construction:
///        - `test_pastDueCureRequiresAStableEconomicEventIdentifier` REDs on the unfixed tree and
///          GREENs once the guard is restored. A discriminator that cannot go red proves nothing.
///        - `test_twoDistinctCuresWithDistinctEvidenceAreBothAccepted` GREENs on BOTH, and exists so
///          the fix cannot be "make `clearPastDue` revert always." A guard that over-blocks is not a
///          fix, and a one-sided test would not catch that.
contract FixP23CureEvidenceIdentityTest is RealOracleFixture {
    uint256 internal constant PRINCIPAL = 2_000_000e18;
    bytes32 internal constant CURE_1 = keccak256("p23-cure-revision-1");
    bytes32 internal constant CURE_2 = keccak256("p23-cure-revision-2");

    function _seedSeniors(uint256 amount) internal {
        _mintUSDfrTo(alice, amount);
        vm.startPrank(alice);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();
    }

    /// @dev Drives a live receivable facility past its grace window and marks it. `markPastDue` is
    ///      deliberately permissionless in production, so no prank is needed.
    function _facilityMarkedPastDue() internal returns (uint256 id) {
        _seedSeniors(3_000_000e18);
        id = _liveFilmFacility(PRINCIPAL);
        vm.warp(block.timestamp + 365 days); // clear nextPaymentDue + the class grace window
        defaultManager.markPastDue(id);
    }

    /// @notice P-23: a cure event needs a stable economic identifier, exactly as a loss event does.
    /// @dev The direct sibling of `test_lossRealizationRequiresAStableEconomicEventIdentifier`.
    ///      REDs on merge `279cad0`; GREENs once the guard is restored.
    function test_pastDueCureRequiresAStableEconomicEventIdentifier() public {
        uint256 id = _facilityMarkedPastDue();

        // Attest the cure under the ambiguous zero identity, so the ONLY thing that can stop the
        // call is the production guard itself — not a missing attestation.
        _attestPastDueCure(id, bytes32(0));

        vm.prank(servicer);
        vm.expectRevert(IDefaultManager.DefaultManager_ZeroEvidenceHash.selector);
        defaultManager.clearPastDue(id, bytes32(0));
    }

    /// @notice The guard must reject only the ambiguous identity, never a legitimate cure.
    /// @dev Passes on BOTH the fixed and unfixed trees. Its job is to make "revert always" an
    ///      inadmissible fix, so the discriminator above cannot be satisfied by over-blocking.
    function test_twoDistinctCuresWithDistinctEvidenceAreBothAccepted() public {
        uint256 id = _facilityMarkedPastDue();

        _attestPastDueCure(id, CURE_1);
        vm.prank(servicer);
        defaultManager.clearPastDue(id, CURE_1);

        // A second, genuinely distinct due revision, cured under its own durable evidence.
        vm.warp(block.timestamp + 365 days);
        defaultManager.markPastDue(id);
        _attestPastDueCure(id, CURE_2);
        vm.prank(servicer);
        defaultManager.clearPastDue(id, CURE_2);
    }
}
