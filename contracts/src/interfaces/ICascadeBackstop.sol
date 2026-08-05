// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title ICascadeBackstop — layer 2 of the loss cascade (ADR-0014)
/// @notice The sGROVE backstop's loss-absorption surface. Losses flow: curator
///         first-loss → THIS backstop → sUSDfr (depositor) principal, in that order,
///         never skipping or inverting a layer (CLAUDE.md §1.3).
/// @dev CONTRACT WITH THE CALLER (DefaultManager): `coverShortfall` MUST transfer
///      exactly `covered` USDfr to `msg.sender` before returning, and `covered <=
///      amount`. The caller burns that USDfr in the same transaction so the supply
///      reduction matches the principal write-down (ADR-0012). The real implementation
///      arrives with Phase H (sGROVE); Phase E tests wire a mock honoring this exact
///      contract, mirroring the MockAttestationOracle pattern from Phase D.
interface ICascadeBackstop is IERC165 {
    /// @notice Emitted for every coverage draw, including zero-coverage responses.
    event ShortfallCovered(address indexed caller, uint256 requested, uint256 covered);

    /// @notice Covers up to `amount` of a realized shortfall from backstop capital.
    /// @param amount The residual loss after curator first-loss absorption.
    /// @return covered USDfr actually provided (transferred to `msg.sender`); the
    ///         Phase H implementation caps this per ADR-0014 (≤ 50% of staked sGROVE
    ///         per event) so it may be less than `amount`.
    /// @param eventId Identifies the LOSS EVENT being covered — the defaulted facility's
    ///        `tokenId`. The per-event cap is enforced cumulatively against this key, so a
    ///        single default cannot draw more by being realized in several calls (PM-R-07).
    /// @param amount The shortfall the cascade is asking the backstop to absorb.
    function coverShortfall(uint256 eventId, uint256 amount) external returns (uint256 covered);

    /// @notice What a single shortfall event could draw from backstop capital right now
    ///         (ADR-0014 per-event cap on the coverage reserve). Used by the conservative
    ///         redemption-NAV impairment (ADR-0022) as the sGROVE junior-capacity term — the
    ///         per-event figure is the conservative (smaller) choice, so it never under-marks.
    function coverageCapacity() external view returns (uint256);
}
