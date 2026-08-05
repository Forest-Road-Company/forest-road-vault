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

    /// @notice The compliance module consulted on transfers (zero = no restriction).
    function complianceModule() external view returns (address);

    /// @notice Sets the compliance module. Only DEFAULT_ADMIN_ROLE (timelocked governance).
    function setComplianceModule(address module) external;
}
