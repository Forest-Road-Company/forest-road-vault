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
    /// @param eventId Identifies the loss event for durable observability. ADR-0035 deliberately
    ///        gives this key no separate ceiling or reserved allowance.
    /// @param amount The shortfall remaining after curator first-loss absorption.
    /// @return covered USDfr actually provided (transferred to `msg.sender`); the
    ///         implementation bounds this only by the live coverage reserve, so it may be less
    ///         than `amount`. Under ADR-0035 one event may exhaust layer two entirely; subsequent
    ///         loss reaches senior principal until real USDfr replenishes the reserve.
    function coverShortfall(uint256 eventId, uint256 amount) external returns (uint256 covered);

    /// @notice The whole live USDfr reserve available to the next reported shortfall.
    /// @dev ADR-0035 removes the former per-event ceiling. This value is therefore identical to
    ///      `coverageReserve()` and can fall to zero after one event.
    function coverageCapacity() external view returns (uint256);

    /// @notice Compatibility view for counterfactual accounting; uncapped capacity equals reserve.
    /// @param reserve The hypothetical live reserve.
    function coverageCapacityAt(uint256 reserve) external view returns (uint256);

    /// @notice Compatibility parameters for consumers that still express capacity as a formula.
    /// @dev ADR-0035 fixes these to `(BPS, type(uint256).max)`, the identity function. They are not
    ///      governance parameters and do not create a per-event ceiling.
    function coverageCapParameters() external view returns (uint16 proportionalBps, uint256 absoluteCap);

    /// @notice The full USDfr reserve currently held for coverage.
    function coverageReserve() external view returns (uint256);

    /// @notice The shared live reserve an event would reach if processed next.
    /// @dev Every event id returns the same value: ADR-0035 creates no event-owned commitment.
    /// @param eventId Retained for ABI compatibility and observability; it does not affect capacity.
    /// @return remaining The current shared coverage reserve.
    function remainingCoverage(uint256 eventId) external view returns (uint256 remaining);
}
