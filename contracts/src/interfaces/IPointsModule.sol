// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IPointsModule
/// @notice Balance-change hooks consumed by the sUSDfr vault and the USDfr token (ADR-0016,
///         2026-07-14 directive). Both are fail-open at the caller.
interface IPointsModule {
    /// @notice Notifies the points ledger of an sUSDfr share balance change (vault-only).
    function onSharesTransfer(address from, address to, uint256 amount) external;

    /// @notice Notifies the points ledger of a USDfr balance change (USDfr-token-only).
    ///         USDfr holders accrue at a governance multiple of the sUSDfr rate, in lieu of yield.
    function onUSDfrTransfer(address from, address to, uint256 amount) external;

    /// @notice Notifies the points ledger of a curator's new posted first-loss for a class
    ///         (CuratorModule-only). First-loss capital accrues at the curator multiple (P-01).
    /// @param newPosted The curator's live postedOf(classId, curator) after the change.
    function onCuratorStakeChange(address curator, uint256 classId, uint256 newPosted) external;

    /// @notice Notifies the points ledger that a class absorbed a loss (CuratorModule-only).
    ///         Curator positions in that class stop accruing at their cached balance until
    ///         reconciled, so impaired first-loss can't out-accrue live capital.
    /// @dev LEGACY form, retained so an un-upgraded CuratorModule keeps recording the freeze.
    ///      It carries no dilution ratio, so the ledger distrusts every cached balance in the
    ///      class — conservative, never over-crediting. Prefer the three-argument form.
    /// @notice Notifies the points ledger that a class absorbed a loss, with the pool balances
    ///         bracketing the absorption (CuratorModule-only). Equal balances are ignored because
    ///         a representation-only normalization is not an economic loss. For an economic loss,
    ///         the ratio lets the ledger write cached balances down without iterating curators
    ///         (H-03/M-4).
    /// @param classId The collateral class that absorbed the loss.
    /// @param poolBalanceBefore The class first-loss pool balance immediately before absorption.
    /// @param poolBalanceAfter The class first-loss pool balance immediately after absorption.
    function onCuratorLoss(uint256 classId, uint256 poolBalanceBefore, uint256 poolBalanceAfter) external;
}
