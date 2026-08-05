// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title Roles
/// @notice Canonical role identifiers for the protocol's access-control matrix.
/// @dev One place for every role so the access-control matrix (docs/access-control.md)
///      maps 1:1 to code. DEFAULT_ADMIN_ROLE (0x00) is held by the governance timelock.
library Roles {
    /// @notice May authorize UUPS upgrades. Held only by the governance timelock.
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Emergency pause/unpause on value-moving paths. Cannot upgrade or move value.
    bytes32 internal constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice May mint USDfr. Held only by the MintRedeemController.
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Reserve custody operations (deposit/release). Held only by the MintRedeemController.
    bytes32 internal constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");

    /// @notice Principal deployment, atomic payment receipt, and writedown. Held by credit modules.
    bytes32 internal constant CREDIT_ROLE = keccak256("CREDIT_ROLE");

    /// @notice May bracket a junior-capacity change so the vault preserves its
    ///         asset-denominated performance-fee hurdle. Held only by the curator,
    ///         sGROVE, and DefaultManager modules.
    bytes32 internal constant FEE_ACCOUNTING_ROLE = keccak256("FEE_ACCOUNTING_ROLE");

    /// @notice Manages KYC allowlist and jurisdiction blocklist entries.
    bytes32 internal constant COMPLIANCE_ADMIN_ROLE = keccak256("COMPLIANCE_ADMIN_ROLE");

    /// @notice Reserve configuration and conservative USDC custody write-downs.
    bytes32 internal constant RESERVE_ADMIN_ROLE = keccak256("RESERVE_ADMIN_ROLE");

    // NOTE: a QUEUE_ROLE existed here through Phase H but was never consumed — the
    // vault gates its exit by ADDRESS (`sUSDfr.setRedemptionQueue`), which is the
    // stronger check. Removed at Phase I cleanup (STATE.md note).

    /// @notice May originate facilities (Phase D).
    bytes32 internal constant ORIGINATOR_ROLE = keccak256("ORIGINATOR_ROLE");

    /// @notice Authorized attesters (Phase G, ADR-0007).
    bytes32 internal constant ATTESTER_ROLE = keccak256("ATTESTER_ROLE");

    /// @notice Servicing operations: facility funding, repayment distribution, default
    ///         declaration, and loss realization. Held by Forest Road servicing keys
    ///         until Phase G binds these paths to attested facts (the role then gates
    ///         WHO may execute an already-attested action, not what is true).
    bytes32 internal constant SERVICER_ROLE = keccak256("SERVICER_ROLE");
}
