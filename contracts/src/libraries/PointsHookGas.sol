// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @notice A caller deliberately supplied too little gas to execute a token's configured
///         points hook while retaining enough gas to complete the token epilogue safely.
error PointsHook_InsufficientGas(uint256 available, uint256 required);

/// @title PointsHookGas
/// @notice Shared gas policy for the USDfr and sUSDfr participation-points hooks.
/// @dev The policy is fail-closed only for caller-controlled underfunding. Once the floor is
///      present, an ordinary points-module failure remains fail-open and observable. Reserving
///      gas explicitly also avoids relying on EIP-150's retained 1/64 to fund catch telemetry
///      and, for sUSDfr, release the share-update lock.
library PointsHookGas {
    /// @dev Covers both live accounting legs at the configured module with substantial margin.
    uint256 internal constant MINIMUM_GAS = 500_000;

    /// @dev Retained by the token rather than offered to the hook. At the minimum this leaves
    ///      400,000 gas for the hook; above it the hook receives every additional unit, subject
    ///      only to the EVM's normal EIP-150 forwarding cap.
    uint256 internal constant POST_HOOK_RESERVE = 100_000;

    /// @notice Enforces the shared floor and returns the maximum gas the caller may offer.
    function hookGasLimit() internal view returns (uint256 hookGas) {
        uint256 available = gasleft();
        if (available < MINIMUM_GAS) revert PointsHook_InsufficientGas(available, MINIMUM_GAS);
        unchecked {
            hookGas = available - POST_HOOK_RESERVE;
        }
    }
}
