// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IMintRedeemController
/// @notice KYC-gated 1:1 mint/redeem between canonical USDC and USDfr, and the
///         enforcement point of the backing invariant (ADR-0012):
///         `USDfr.totalSupply() <= backingValue()` after every supply-affecting op.
interface IMintRedeemController {
    // ── Events ───────────────────────────────────────────────────────────
    event Minted(address indexed user, uint256 usdcIn, uint256 usdfrOut);
    event Redeemed(address indexed user, uint256 usdfrIn, uint256 usdcOut);
    /// @notice Emitted when USDfr is minted against attested yield receipts (waterfall path).
    event YieldMinted(address indexed to, uint256 amount);
    /// @notice Emitted when USDfr is burned to realize a loss (cascade layer 3).
    event LossBurned(address indexed from, uint256 amount);

    // ── Errors ───────────────────────────────────────────────────────────
    error Controller_NotKYCAllowed(address account);
    error Controller_BackingInvariantViolated(uint256 supply, uint256 backing);
    error Controller_ZeroAmount();
    error Controller_AmountTooSmall(uint256 usdfrAmount);

    // ── User paths (KYC-gated) ───────────────────────────────────────────
    /// @notice Deposits USDC (6 decimals) and mints USDfr 1:1 in 18-decimal USD units.
    function mint(uint256 usdcAmount) external returns (uint256 usdfrOut);

    /// @notice Burns USDfr and releases the whole-USDC-unit equivalent from idle reserves.
    function redeem(uint256 usdfrAmount) external returns (uint256 usdcOut);

    // ── Protocol paths (CREDIT_ROLE; wired in Phases E/G) ────────────────
    /// @notice Mints USDfr to `to` against newly received, attested backing (loan
    ///         interest / reserve yield). Enforces the backing invariant post-mint.
    function mintYield(address to, uint256 amount) external;

    /// @notice Burns USDfr from `from` to realize a loss through the cascade.
    function burnLoss(address from, uint256 amount) external;

    // ── Views ────────────────────────────────────────────────────────────
    /// @notice Current backing value (delegates to ReserveManager.totalBackingValue()).
    function backingValue() external view returns (uint256);

    /// @notice Current USDfr total supply.
    function totalUSDfr() external view returns (uint256);

    /// @notice True if the backing invariant currently holds. Public so anyone can check.
    function backingInvariantHolds() external view returns (bool);
}
