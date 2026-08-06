// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IReserveManager
/// @notice Mainnet-v1 treasury for canonical USDC and deployed facility principal.
/// @dev USD values use 18 decimals. USDC amounts use the token's native 6 decimals.
interface IReserveManager {
    event USDCDeposited(address indexed from, uint256 requested, uint256 credited);
    event USDCReleased(address indexed to, uint256 amount);
    event IdleUSDCReconciled(uint256 previous, uint256 current);
    event IdleUSDCWrittenDown(uint256 amount, uint256 remaining);
    event PrincipalDeployed(uint256 indexed facilityId, uint256 amount);
    event FeeCapitalized(uint256 indexed facilityId, uint256 amount);
    event PaymentReceived(
        uint256 indexed facilityId, address indexed payer, uint256 usdcAmount, uint256 principalReturned
    );
    event PrincipalWrittenDown(uint256 indexed facilityId, uint256 amount);

    error ReserveManager_InsufficientIdleValue(uint256 requestedValue, uint256 idleValue);
    error ReserveManager_InsufficientDeployedPrincipal(uint256 facilityId, uint256 requested, uint256 deployed);
    error ReserveManager_ZeroAmount();
    error ReserveManager_ZeroAddress();
    error ReserveManager_NotDepositor(address caller);
    error ReserveManager_NoValueReceived();
    error ReserveManager_UnexpectedUSDCReceipt(uint256 expected, uint256 received);
    error ReserveManager_WriteDownExceedsIdle(uint256 amount, uint256 idle);
    error ReserveManager_SelfDeployment();
    error ReserveManager_ValueNotUSDCExact(uint256 value);
    error ReserveManager_InvalidUSDCDecimals(uint8 decimals);
    error ReserveManager_PrincipalExceedsPayment(uint256 principal, uint256 paymentValue);

    function depositUSDC(address from, uint256 amount) external returns (uint256 credited);
    function releaseUSDC(address to, uint256 amount) external;

    /// @notice Reconciles only custody losses. Unsolicited transfers never create backing.
    function reconcileIdleUSDC() external returns (uint256 current);
    function writeDownIdleUSDC(uint256 amount) external;

    function recordDeployment(uint256 facilityId, address to, uint256 usdcAmount) external;
    function recordFeeCapitalization(uint256 facilityId, uint256 amount) external;

    /// @notice Atomically pulls exact USDC and accounts the principal leg.
    function recordPayment(uint256 facilityId, address payer, uint256 usdcAmount, uint256 principal)
        external
        returns (uint256 receivedValue);

    function recordPrincipalWritedown(uint256 facilityId, uint256 amount) external;

    function idleReserve() external view returns (uint256);
    function idleUSDC() external view returns (uint256);
    function deployedPrincipal() external view returns (uint256);
    function totalBackingValue() external view returns (uint256);
    function deployedTo(uint256 facilityId) external view returns (uint256);
    function usdc() external view returns (address);
    function normalizeUSDC(uint256 amount) external pure returns (uint256);
    function denormalizeUSDC(uint256 value) external pure returns (uint256);
}
