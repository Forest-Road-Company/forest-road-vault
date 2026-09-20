// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title ISeniorExitDrawSource - the atomic junior draw behind a cascade-ordered exit price
/// @notice ADR-0034 Y-bis. The narrow surface `MintRedeemController._redeem` needs from the loss
///         cascade, kept separate from the full `IDefaultManager` so the controller takes a
///         dependency on ONE function rather than on the whole default-management surface.
/// @dev THE CONTRACT WITH THE CALLER, and every clause is load-bearing:
///
///      1. ORDER. THIS CLAUSE IS WHAT AN AUDITOR READS TO CHECK CLAUDE.md SECTION 1.3, SO IT IS
///         WRITTEN OUT RATHER THAN INHERITED. On the Ethereum instance it required the
///         implementation to consult curator first-loss BEFORE the sGROVE backstop and to offer
///         the backstop only what layer 1 declined. ADR-0037 D3a(ii) removes layer two from THIS
///         instance entirely: there is no sGROVE, no GROVE and no backstop, so LAYER 1 IS THE
///         WHOLE JUNIOR DRAW and what it declines is borne by the caller's own settlement price.
///
///         The ordering property therefore rests on a different, weaker theorem, and it must not
///         be allowed to decay into an unchecked assertion: layer 1 is called UNCONDITIONALLY
///         with the full `required`; `absorbGlobalLoss` clamps to the pools' total; therefore a
///         non-zero residual means the curator pools are EXHAUSTED. An implementation that adds
///         any second junior source MUST hand it layer 1's leftover, and only its leftover, or
///         the guarantee is gone with no guard to fail. The controller cannot check any of this -
///         it has no vocabulary for "layer" - so the guarantee lives entirely in the
///         implementation's dataflow. `DefaultManager.drawForSeniorExit` is the reference.
///
///         The disclosure that follows is not optional: POSTING FIRST-LOSS IS NOT A GATE, so
///         until curator capital is posted this function draws nothing and every senior exit
///         prices at the gross mark with no junior capital in front of it.
///
///      2. DELIVERY. Exactly `drawn` USDfr MUST be standing at the implementation's own address
///         when this returns, over and above what it held on entry. The CALLER burns it in place;
///         the implementation MUST NOT call back into `MintRedeemController.burnLoss`, which is
///         `nonReentrant` on a controller already inside `redeem`.
///
///      3. NEVER MORE THAN ASKED. `drawn <= required`. The controller measures the delta itself
///         and refuses to settle if the report and the movement disagree, so an implementation
///         that lies can only cause a revert - never an overpayment out of junior capital.
///
///      4. NEVER REVERT ON INSUFFICIENCY. `drawn < required` (including zero) is an ordinary
///         answer. Reverting would reintroduce the R16 exit deadlock ADR-0034 exists to remove.
interface ISeniorExitDrawSource {
    /// @notice Draws junior capital forward, in cascade order, to fund a senior exit price.
    /// @param required Junior capital the exit price needs, in 18-decimal USDfr units.
    /// @return drawn USDfr actually provided by curator first-loss, standing at this contract.
    function drawForSeniorExit(uint256 required) external returns (uint256 drawn);
}
