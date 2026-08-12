// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IUSDfr
/// @notice The fully-backed synthetic dollar (brief Part 4). Mint/burn restricted to the
///         controller; optional compliance module consulted on transfers.
interface IUSDfr is IERC20 {
    /// @notice Emitted when the compliance module address is updated.
    event ComplianceModuleUpdated(address indexed module);
    /// @notice Emitted when the participation-points hook changes.
    event PointsModuleUpdated(address indexed module);
    /// @notice Emitted when the (fail-open) points hook reverted on a transfer (P-04 telemetry).
    event PointsHookFailed(address indexed from, address indexed to, uint256 value);

    /// @notice Transfer blocked by the compliance module.
    error USDfr_TransferNotAllowed(address from, address to);

    /// @notice Mints `amount` to `to`. Only MINTER_ROLE (the MintRedeemController).
    function mint(address to, uint256 amount) external;

    /// @notice Burns `amount` from `from`. Only MINTER_ROLE (the controller).
    function burn(address from, uint256 amount) external;

    /// @notice The compliance registry consulted on transfers.
    /// @dev AUDIT FIX (C4-USDFR-03): this used to read "zero = no restriction", which is FALSE
    ///      and dangerously so. Zero does disable the sanctions transfer gate, but the registry
    ///      is ALSO the only on-chain directory of protocol modules, and USDfr's emergency-pause
    ///      carve-out is keyed off that directory. With no registry a pause is TOTAL — the loss
    ///      cascade's burn leg included. Zero is a MORE restrictive setting exactly when
    ///      restriction is most damaging, not a less restrictive one.
    function complianceModule() external view returns (address);

    /// @notice Sets the compliance registry. Only DEFAULT_ADMIN_ROLE (timelocked governance).
    ///         Clearing it (zero) is refused while the token is paused — see
    ///         `USDfr.setComplianceModule` (C4-USDFR-03).
    function setComplianceModule(address module) external;

    /// @notice True while the token's own emergency pause is engaged.
    /// @dev AUDIT FIX (R18) — ADDED SO THE CONTROLLER CAN SEE THIS PAUSE. `USDfr._update` refuses
    ///      every MINT while the token is paused (its protocol-leg carve-out requires
    ///      `from != address(0)`, which a mint can never satisfy), and the same guardian address
    ///      holds `GUARDIAN_ROLE` here and on `MintRedeemController`. R17 made
    ///      `MintRedeemController.mintableHeadroom()` read zero under a CONTROLLER pause so
    ///      `WaterfallEngine._routeInterest` would WITHHOLD instead of reverting an entire borrower
    ///      repayment — but it could not see this pause, so one un-timelocked `USDfr.pause()` still
    ///      reverted every interest-bearing `distribute` in full, principal leg included. The
    ///      headroom now reads both pauses, and that requires this to be on the interface rather
    ///      than reached through a local ad-hoc declaration.
    function paused() external view returns (bool);
}
