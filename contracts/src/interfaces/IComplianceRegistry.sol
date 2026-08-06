// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IComplianceRegistry
/// @notice Compliance capability layer (ADR-0011, as amended by the 2026-07-14 directive):
///         a KYC allowlist consulted ONLY at the mint/redeem primary gate, and a narrow
///         sanctions blocklist consulted on transfers. The per-token transfer-allowlist
///         capability was removed — transfers are permissionless (sanctions-only). Policy
///         (who is eligible/sanctioned) is set by governance/counsel off this interface.
interface IComplianceRegistry {
    /// @notice Emitted when an account's KYC allowlist status changes.
    event AllowlistUpdated(address indexed account, bool allowed);
    /// @notice Emitted when an account's sanctions/jurisdiction-block status changes.
    event JurisdictionBlockUpdated(address indexed account, bool blocked);

    /// @notice True if `account` has passed KYC and may use the gated primary paths
    ///         (USDfr mint/redeem). Holding and transferring are permissionless.
    function isAllowed(address account) external view returns (bool);

    /// @notice True if `account` is on the sanctions/jurisdiction blocklist.
    function isJurisdictionBlocked(address account) external view returns (bool);

    /// @notice True for a governance-designated internal protocol module.
    function isProtocolExempt(address module) external view returns (bool);

    /// @notice Transfer gate consulted by protocol tokens on every transfer. Transfers are
    ///         permissionless except for sanctioned (blocked) parties; burns are always
    ///         permitted; protocol modules are never treated as blocked.
    /// @param token Retained for interface stability; no longer affects the result.
    /// @param from Sender (zero on mint).
    /// @param to Recipient (zero on burn).
    /// @return True if the transfer may proceed.
    function canTransfer(address token, address from, address to) external view returns (bool);
}
