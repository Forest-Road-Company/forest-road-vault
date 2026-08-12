// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title ISeniorExitDrawSource — the atomic junior draw behind a cascade-ordered exit price
/// @notice ADR-0034 Y-bis. The narrow surface `MintRedeemController._redeem` needs from the loss
///         cascade, kept separate from the full `IDefaultManager` so the controller takes a
///         dependency on ONE function rather than on the whole default-management surface.
/// @dev THE CONTRACT WITH THE CALLER, and every clause is load-bearing:
///
///      1. ORDER. The implementation MUST consult curator first-loss BEFORE the sGROVE backstop,
///         and MUST offer the backstop only what layer 1 declined. The controller cannot check
///         this — it has no vocabulary for "layer" — so the ordering guarantee lives entirely in
///         the implementation's dataflow. `DefaultManager.drawForSeniorExit` is the reference.
///
///      2. DELIVERY. Exactly `drawn` USDfr MUST be standing at the implementation's own address
///         when this returns, over and above what it held on entry. The CALLER burns it in place;
///         the implementation MUST NOT call back into `MintRedeemController.burnLoss`, which is
///         `nonReentrant` on a controller already inside `redeem`.
///
///      3. NEVER MORE THAN ASKED. `drawn <= required`. The controller measures the delta itself
///         and refuses to settle if the report and the movement disagree, so an implementation
///         that lies can only cause a revert — never an overpayment out of junior capital.
///
///      4. NEVER REVERT ON INSUFFICIENCY. `drawn < required` (including zero) is an ordinary
///         answer. Reverting would reintroduce the R16 exit deadlock ADR-0034 exists to remove.
interface ISeniorExitDrawSource {
    /// @notice Draws junior capital forward, in cascade order, to fund a senior exit price.
    /// @param required Junior capital the exit price needs, in 18-decimal USDfr units.
    /// @return drawn USDfr actually provided by layers 1 and 2, standing at this contract.
    function drawForSeniorExit(uint256 required) external returns (uint256 drawn);
}
