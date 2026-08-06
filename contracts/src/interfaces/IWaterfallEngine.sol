// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IWaterfallEngine — repayment routing (brief Part 5 §9)
/// @notice Routes every attested repayment with exact conservation (CLAUDE.md §1.3):
///         principal returns to reserves (backing composition shifts, exposure falls);
///         interest splits protocol fee → sUSDfr vault yield.
///         Senior (`sUSDfr`) is never subordinated to junior (curator): curator capital
///         is only released as exposure falls, never paid from repayments ahead of the
///         vault. Also owns facility funding (deployment is distribution's inverse).
interface IWaterfallEngine {
    struct Payment {
        uint256 tokenId;
        bytes32 paymentId;
        address payer;
        uint256 interest;
        uint256 principal;
        uint64 nextPaymentDue;
    }
    // ── Events ───────────────────────────────────────────────────────────

    event Funded(uint256 indexed tokenId, address indexed recipient, uint256 principal);
    /// @notice OID origination fee (ADR-0019): the borrower netted `principal - fee`;
    ///         the fee's stables stay in the treasury and the fee mints to the
    ///         protocol fee recipient against them.
    event OriginationFeeCharged(uint256 indexed tokenId, uint256 indexed classId, uint256 fee);
    event OriginationFeeSet(uint256 indexed classId, uint16 feeBps);
    /// @notice Exact USDC receipt and its accounting split.
    event Distributed(
        uint256 indexed tokenId,
        bytes32 indexed paymentId,
        address indexed payer,
        uint256 interest,
        uint256 principal,
        uint256 fee,
        uint256 toVault
    );
    event ProtocolFeeSet(uint16 feeBps);
    event FeeRecipientSet(address indexed recipient);

    // ── Errors ───────────────────────────────────────────────────────────
    error Waterfall_ZeroAddress();
    error Waterfall_ZeroAmount();
    error Waterfall_BadFee(uint16 feeBps);
    error Waterfall_UnknownClass(uint256 classId);
    error Waterfall_NotFundable(uint256 tokenId);
    error Waterfall_NotDistributable(uint256 tokenId);
    error Waterfall_PrincipalMismatch(uint256 tokenId, uint256 expected, uint256 got);
    /// @notice No current PaymentReceived attestation commits to the exact receipt.
    error Waterfall_PaymentNotAttested(uint256 tokenId);
    /// @notice A distribution would leave USDfr supply above backing (the returning
    ///         principal stables did not actually arrive in the treasury this tx).
    error Waterfall_BackingWouldBreak(uint256 tokenId);
    error Waterfall_PrincipalExceedsOutstanding(uint256 tokenId, uint256 principal, uint256 outstanding);

    // ── Servicing paths (SERVICER_ROLE; attested facts per ADR-0007) ─────
    /// @notice Funds a Pending facility: deploys exactly its principal from idle
    ///         reserves to `recipient` (escrow/borrower account) and activates it.
    function fund(uint256 tokenId, uint256 usdcAmount) external;

    /// @notice Distributes an attested repayment receipt. The corresponding stables
    ///         MUST already sit in the treasury (same transaction); the backing
    ///         invariant assertion inside `mintYield` enforces this for the interest
    ///         leg. Auto-transitions: first partial principal → Amortizing; outstanding
    ///         reaching zero → Repaid. Callable while Defaulted/Accelerated to route
    ///         recovery proceeds.
    function distribute(Payment calldata payment) external;

    // ── Governance ───────────────────────────────────────────────────────
    /// @notice Sets the protocol fee on interest (bps). Timelocked governance only.
    function setProtocolFee(uint16 feeBps) external;

    /// @notice Sets a class's origination fee (bps of principal, hard-capped at
    ///         Config.MAX_ORIGINATION_FEE_BPS; zero = no fee). Timelocked governance.
    function setOriginationFee(uint256 classId, uint16 feeBps) external;

    /// @notice Sets the protocol fee recipient. Timelocked governance only.
    function setFeeRecipient(address recipient) external;

    // ── Views ────────────────────────────────────────────────────────────
    /// @notice Current protocol fee on distributed interest (bps).
    function protocolFeeBps() external view returns (uint16);

    /// @notice Current origination fee for a class (bps of principal).
    function originationFeeBps(uint256 classId) external view returns (uint16);

    /// @notice Current protocol fee recipient.
    function feeRecipient() external view returns (address);
}
