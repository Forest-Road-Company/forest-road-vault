// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title ICollateralRegistry
/// @notice Per-vertical collateral-class parameters and book-level concentration
///         accounting (ADR-0003 as amended: five classes at genesis, one of which is
///         marked-to-market per ADR-0015).
interface ICollateralRegistry {
    /// @notice How a class's collateral behaves — drives valuation and remedy paths.
    enum CollateralModel {
        Receivable, // legal-enforcement remedies (UCC foreclosure, secondary sale)
        MarkedToMarket // margin-call / liquidation remedies (ADR-0015)

    }

    struct ClassParams {
        string name;
        CollateralModel model;
        bool active;
        uint16 maxLtvBps; // draw ceiling (initial LTV for MTM classes)
        uint64 maxMaturity; // seconds from origination
        uint16 concentrationLimitBps; // max share of total book in this class
        // ── marked-to-market extension (zero for receivable classes) ──────
        uint16 marginCallLtvBps; // breach → MarginCalled + cure window
        uint16 liquidationLtvBps; // breach / cure expiry → LiquidationInitiated
        uint64 maxMarkAge; // valuation freshness bound (seconds)
    }

    event ClassSet(uint256 indexed classId);
    event ExposureRecorded(uint256 indexed classId, bytes32 indexed borrowerId, bytes32 indexed stateId, int256 delta);
    event BorrowerLimitSet(uint16 limitBps);
    /// @notice Governance set a per-borrower concentration limit overriding the global one.
    /// @param borrowerId The borrower key.
    /// @param limitBps The borrower's own max share of the book, in bps.
    event BorrowerLimitOverrideSet(bytes32 indexed borrowerId, uint16 limitBps);
    /// @notice Governance removed a per-borrower override; the global limit applies again.
    /// @param borrowerId The borrower key.
    event BorrowerLimitOverrideCleared(bytes32 indexed borrowerId);
    event StateLimitSet(uint16 limitBps);
    event ConcentrationFloorSet(uint256 floor);

    /// @notice A class crossed FROM within its concentration limit TO above it
    ///         (AUDIT FIX M-02). This is a book-shrink artefact: an amortising
    ///         repayment, a default write-down, or the retirement of an unfunded
    ///         facility removes exposure elsewhere, so an untouched class's SHARE of the
    ///         remaining book rises without that class growing. Such a decrease can never
    ///         be blocked (blocking it would let a concentration limit veto a loss being
    ///         realized, inverting the loss cascade), so the breach is reported, not
    ///         prevented — and no new exposure may be added to the class while it stands.
    /// @param classId The class now above its limit.
    /// @param exposure The class's exposure after the change (18-dec).
    /// @param totalExposure The whole book's exposure after the change (18-dec).
    /// @param limitBps The class's configured limit as a share of the book.
    /// @param bookAboveFloor Whether the whole book is above the bootstrap floor. False
    ///        means this is ordinary genesis concentration on a book too small for the
    ///        relative limits to be the operative constraint (the absolute allowance
    ///        `limitBps * floor / BPS` is); alerting should filter on this rather than
    ///        treat a first facility at 100% of a tiny book as a risk incident.
    event ConcentrationDrift(
        uint256 indexed classId, uint256 exposure, uint256 totalExposure, uint16 limitBps, bool bookAboveFloor
    );

    /// @notice A class that was above its concentration limit is back within it — because
    ///         the book grew around it or its own exposure fell (AUDIT FIX M-02).
    /// @param classId The class now within its limit.
    /// @param exposure The class's exposure after the change (18-dec).
    /// @param totalExposure The whole book's exposure after the change (18-dec).
    /// @param limitBps The class's configured limit as a share of the book.
    /// @param bookAboveFloor Whether the whole book is above the bootstrap floor.
    event ConcentrationHealed(
        uint256 indexed classId, uint256 exposure, uint256 totalExposure, uint16 limitBps, bool bookAboveFloor
    );

    /// @notice A borrower crossed FROM within its concentration limit TO above it
    ///         (AUDIT FIX M-02). Emitted for the borrower a write touches and for any id
    ///         passed to `syncConcentrationBreaches`; the borrower key set is unbounded and
    ///         not enumerable on-chain, but is fully recoverable from `ExposureRecorded`.
    event BorrowerConcentrationDrift(
        bytes32 indexed borrowerId, uint256 exposure, uint256 totalExposure, uint16 limitBps, bool bookAboveFloor
    );

    /// @notice A borrower that was above its concentration limit is back within it.
    event BorrowerConcentrationHealed(
        bytes32 indexed borrowerId, uint256 exposure, uint256 totalExposure, uint16 limitBps, bool bookAboveFloor
    );

    /// @notice A US state crossed FROM within its concentration limit TO above it.
    event StateConcentrationDrift(
        bytes32 indexed stateId, uint256 exposure, uint256 totalExposure, uint16 limitBps, bool bookAboveFloor
    );

    /// @notice A US state that was above its concentration limit is back within it.
    event StateConcentrationHealed(
        bytes32 indexed stateId, uint256 exposure, uint256 totalExposure, uint16 limitBps, bool bookAboveFloor
    );

    error Registry_UnknownClass(uint256 classId);
    error Registry_ClassInactive(uint256 classId);
    error Registry_BadParams();
    /// @notice A configured class cannot change between receivable and marked-to-market
    ///         accounting. The model selects materially different valuation and remedy
    ///         paths and is fixed for the lifetime of a launch class.
    error Registry_ModelImmutable(uint256 classId);
    /// @notice The requested principal would push the book past the range in which the
    ///         concentration arithmetic is provably overflow-free. Fails loudly with a
    ///         decodable error rather than an arithmetic panic.
    error Registry_PrincipalTooLarge();
    error Registry_ConcentrationExceeded(uint256 classId, uint256 wouldBe, uint256 limit);
    error Registry_BorrowerConcentrationExceeded(bytes32 borrowerId, uint256 wouldBe, uint256 limit);
    error Registry_StateConcentrationExceeded(bytes32 stateId, uint256 wouldBe, uint256 limit);
    error Registry_ExposureUnderflow();

    /// @notice Sets/updates a collateral class. Timelocked governance only.
    /// @dev A class's collateral model is immutable after its first configuration.
    function setClass(uint256 classId, ClassParams calldata p) external;

    /// @notice Sets a per-borrower concentration limit overriding the global borrower limit.
    function setBorrowerLimitOverride(bytes32 borrowerId, uint16 limitBps) external;

    /// @notice Clears a per-borrower concentration limit override.
    function clearBorrowerLimitOverride(bytes32 borrowerId) external;

    /// @notice Class parameters (reverts for unknown classes).
    function classParams(uint256 classId) external view returns (ClassParams memory);

    /// @notice Reverts unless adding `principal` for (`classId`,`borrowerId`,`stateId`)
    ///         respects every concentration limit (class, borrower, state). View-only;
    ///         `recordExposure` performs the same checks at write time.
    function checkConcentration(uint256 classId, bytes32 borrowerId, bytes32 stateId, uint256 principal)
        external
        view;

    /// @notice Records an exposure increase (origination). Only CREDIT_ROLE (the
    ///         collateral/credit layer). Enforces all concentration limits.
    function recordExposureIncrease(uint256 classId, bytes32 borrowerId, bytes32 stateId, uint256 principal) external;

    /// @notice Records an exposure decrease (repayment/writedown). Only CREDIT_ROLE.
    function recordExposureDecrease(uint256 classId, bytes32 borrowerId, bytes32 stateId, uint256 principal) external;

    /// @notice Current book exposure per class / borrower / state (18-dec).
    function classExposure(uint256 classId) external view returns (uint256);
    function borrowerExposure(bytes32 borrowerId) external view returns (uint256);
    function stateExposure(bytes32 stateId) external view returns (uint256);
    function totalBookExposure() external view returns (uint256);

    /// @notice A class's current share of the whole book, in bps (0 on an empty book).
    function classConcentrationBps(uint256 classId) external view returns (uint256);

    /// @notice Whether a dimension's CURRENT share of the book exceeds its configured
    ///         limit — the standing disclosure fact, floor-independent (AUDIT FIX M-02).
    function isOverConcentrated(uint256 classId, bytes32 borrowerId, bytes32 stateId)
        external
        view
        returns (bool classOver, bool borrowerOver, bool stateOver);

    /// @notice Bitmap of classes currently above their limit; bit `classId - 1` set.
    /// @dev Recomputed from the book on every call — never served from a cached slot, so it
    ///      cannot report a clean book in the window after an implementation upgrade.
    function overConcentratedClasses() external view returns (uint256 bitmap);

    /// @notice The borrower concentration limit actually in force for `borrowerId`.
    /// @dev The global limit assumes a vertical has many borrowers. A SINGLE-BORROWER vertical
    ///      (Digital Assets, ADR-0015) makes the class and borrower dimensions measure the same
    ///      exposure, so governance may set a per-borrower override. Every admission, breach
    ///      and headroom read routes through this same number.
    /// @param borrowerId The borrower key.
    /// @return limitBps The effective limit in bps.
    /// @return overridden True when a per-borrower override is set.
    function effectiveBorrowerLimitBps(bytes32 borrowerId) external view returns (uint16 limitBps, bool overridden);

    /// @notice Whether each supplied borrower currently holds more than the per-borrower limit
    ///         as a share of the book — its OWN limit where one is overridden. The key set is
    ///         unbounded on-chain; recover it from the `ExposureRecorded` stream and pass it in.
    function overConcentratedBorrowers(bytes32[] calldata borrowerIds) external view returns (bool[] memory over);

    /// @notice Whether each supplied state currently holds more than the per-state limit as
    ///         a share of the book. Zero ids read false.
    function overConcentratedStates(bytes32[] calldata stateIds) external view returns (bool[] memory over);

    /// @notice Recomputes and events every concentration transition for all five classes
    ///         plus the supplied borrower/state ids. Permissionless: it moves no value and
    ///         only publishes facts the views already expose, so anyone (a keeper, a risk
    ///         desk, the upgrade transaction itself) can announce a standing breach without
    ///         waiting for the next origination or repayment.
    function syncConcentrationBreaches(bytes32[] calldata borrowerIds, bytes32[] calldata stateIds) external;

    /// @notice The largest `principal` that `checkConcentration` would admit right now for
    ///         (`classId`,`borrowerId`,`stateId`) — the binding minimum across the class,
    ///         borrower and state dimensions. Zero for an unknown or inactive class.
    function concentrationHeadroom(uint256 classId, bytes32 borrowerId, bytes32 stateId)
        external
        view
        returns (uint256);
}
