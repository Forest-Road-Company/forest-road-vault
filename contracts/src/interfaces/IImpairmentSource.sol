// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IImpairmentSource — declared-but-unrealized senior impairment (ADR-0022 Option Y)
/// @notice The minimal surface the senior vault needs to price redemptions conservatively
///         and keep junior-capital changes out of performance-fee profit. Deliberately narrow:
///         the token layer must not depend on the whole credit layer, and a future implementation
///         (a governance-set manual mark or an aggregator over several credit books) can satisfy
///         this without being a DefaultManager.
/// @dev `pendingSeniorImpairment` is the senior (`sUSDfr`) principal impaired AFTER the junior
///      cascade layers absorb in strict order. `performanceFeeImpairment` removes any temporary
///      uplift supplied by those junior layers from the performance-fee base. See ADR-0022 §Y
///      and ADR-0031.
interface IImpairmentSource {
    /// @notice Senior principal impaired by declared-but-unrealized defaults, net of junior capacity.
    /// @return The impairment in USDfr (18 decimals); zero when the junior layers fully cover.
    function pendingSeniorImpairment() external view returns (uint256);

    /// @notice Impairment deducted when measuring protocol-level performance-fee profit.
    /// @dev Must be greater than or equal to `pendingSeniorImpairment()`. The difference is
    ///      fee-neutral junior-capital or valuation credit: it can improve redemption protection
    ///      but cannot itself be charged as senior investment performance. A professional
    ///      assessment may snapshot a lower value that recognizes supported recovery while
    ///      preserving the junior-capital credit standing when that assessment was published.
    /// @return The performance-fee impairment in USDfr (18 decimals).
    function performanceFeeImpairment() external view returns (uint256);
}
