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
    /// @dev AUDIT FIX (R18): `fee` is what the BORROWER WAS CHARGED and is capitalised into their
    ///      principal in full. It is no longer necessarily what was MINTED to the fee recipient —
    ///      see `OriginationFeeWithheldForBackingRepair`, which reports any withheld part, so the
    ///      split is reconstructable from logs alone (CLAUDE.md §3.1).
    event OriginationFeeCharged(uint256 indexed tokenId, uint256 indexed classId, uint256 fee);
    /// @notice AUDIT FIX (R18). Part of an ORIGINATION fee was NOT minted to the fee recipient: the
    ///         value stayed in the treasury as unencumbered backing. The origination-leg twin of
    ///         `InterestWithheldForBackingRepair`, and emitted for the same three reasons the
    ///         headroom can be short — a standing deficit, an unreconciled custody shortfall, or
    ///         `MintRedeemController.seniorSubParShortfall()` — plus a controller or USDfr pause.
    /// @dev Before R18 this mint was unclamped and simply REVERTED in those states, which made a
    ///      crystallised senior haircut a freeze on all fee-bearing origination and blocked the only
    ///      cure the retention names (see `MintRedeemController.seniorSubParShortfall`). Emitted
    ///      only when something was withheld, so its absence is the normal case.
    /// @param tokenId The facility being funded.
    /// @param withheld 18-decimal USD of fee retained as backing rather than minted.
    /// @param deficitRemaining `MintRedeemController.recognizedDeficit()` measured at this point.
    ///        AUDIT FIX (SWEEP-2 S2-F2) — READ THIS BEFORE TREATING IT AS "HOW BIG IS THE HOLE".
    ///        IT IS ZERO IN EVERY STATE THIS CLAMP EXISTS FOR. R18 added the clamp for the
    ///        `seniorSubParShortfall` RETENTION state, and `mintYield`'s own NatSpec says that
    ///        state "INCLUDES states the protocol publishes as fully backed and even OVER-backed:
    ///        `backingInvariantHolds()` TRUE, `backingDeficit()` and `recognizedDeficit()` both
    ///        zero." MEASURED: a 10,000e18 origination fee withheld against
    ///        `deficitRemaining == 0`. The same is true of the two PAUSE terms and of ADR-0034
    ///        Y-bis's `exitPrepaidAbsorption()`. The field is retained rather than changed because
    ///        the on-chain register must be reconstructable from events and this one has been
    ///        emitted since R17; treat it as "recognised deficit at this point", NOT as
    ///        "the reason for the withholding". `withheld` is the reliable field.
    event OriginationFeeWithheldForBackingRepair(uint256 indexed tokenId, uint256 withheld, uint256 deficitRemaining);
    /// @notice AUDIT FIX (R16-M5). Part of an interest receipt was NOT distributed as yield: the
    ///         cash stayed in the reserve to repair a standing backing deficit. Emitted only in
    ///         the sub-par state, so its absence is the normal case.
    /// @param withheld 18-decimal USD of interest retained as backing rather than minted.
    /// @param deficitRemaining AUDIT FIX (SWEEP-2 S2-F2) — THIS LINE NAMED THE WRONG FUNCTION.
    ///        It documented `MintRedeemController.backingDeficit()`; the code has emitted
    ///        `recognizedDeficit()` since R17, which is the RECOGNITION-AWARE measure (it nets the
    ///        R4-01 custody shortfall) and differs from `backingDeficit()` in exactly the state R17
    ///        added it for. MEASURED in that state: `backingDeficit() == 0` while
    ///        `recognizedDeficit() == 8,000e18` and the event carried 7,000e18.
    ///        AND IT IS ZERO IN FOUR OF THE FIVE STATES THAT CAUSE A WITHHOLDING: R17's
    ///        `seniorSubParShortfall`, R18's two pause terms and ADR-0034 Y-bis's
    ///        `exitPrepaidAbsorption()` all clamp `mintableHeadroom()` without moving
    ///        `recognizedDeficit()`. MEASURED: a paused controller withheld a 40,000e18 interest
    ///        receipt in full and published `deficitRemaining == 0` on a book where
    ///        `backingInvariantHolds()` was TRUE. Treat it as "recognised deficit at this point",
    ///        NOT as "how much of the hole is still open"; `withheld` is the reliable field.
    event InterestWithheldForBackingRepair(uint256 withheld, uint256 deficitRemaining);
    /// @notice AUDIT FIX (ADV-1). Part of the INTEREST-LEG PROTOCOL FEE was NOT minted to the fee
    ///         recipient: Forest Road may not take a performance fee out of a senior shortfall that
    ///         junior capital has already declined to absorb. The withheld value is never minted, so
    ///         it stays in the reserve as unencumbered backing exactly as
    ///         `InterestWithheldForBackingRepair` describes — but it is sized off a CREDIT-layer
    ///         quantity (`DefaultManager.pendingSeniorImpairment()`) that
    ///         `MintRedeemController.mintableHeadroom()` is structurally blind to, so the two
    ///         withholdings are DISTINCT and are reported separately.
    /// @dev Emitted only when something was withheld, so its absence is the normal case. Together
    ///      with `Distributed` (whose `fee` is the NET minted amount) the gross fee is
    ///      reconstructable from logs alone as `fee + withheld` (CLAUDE.md §3.1). DO NOT "simplify"
    ///      this into `InterestWithheldForBackingRepair`: that event's `deficitRemaining` is the
    ///      RECOGNISED deficit, which is ZERO in exactly the state this event fires in, and an
    ///      indexer could not tell the two causes apart.
    /// @param withheld 18-decimal USD of protocol fee retained as backing rather than minted.
    /// @param seniorImpairment `DefaultManager.pendingSeniorImpairment()` measured at this point,
    ///        i.e. the declared/past-due principal that curator first-loss and the sGROVE backstop
    ///        will NOT absorb and which therefore lands on `sUSDfr` or beyond.
    event ProtocolFeeWithheldForSeniorImpairment(uint256 withheld, uint256 seniorImpairment);
    event OriginationFeeSet(uint256 indexed classId, uint16 feeBps);
    /// @notice Exact USDC receipt and its accounting split.
    /// @dev `fee` IS THE NET MINTED AMOUNT, NOT THE GROSS SKIM (AUDIT FIX ADV-1). It was already
    ///      net of the R16-M5 headroom clamp; it is now also net of the ADV-1 senior-impairment
    ///      withholding. `interest == fee + toVault` therefore holds only in the unimpaired,
    ///      full-headroom state; in general `interest - fee - toVault` is the total retained as
    ///      backing, split across `InterestWithheldForBackingRepair` and
    ///      `ProtocolFeeWithheldForSeniorImpairment`.
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
