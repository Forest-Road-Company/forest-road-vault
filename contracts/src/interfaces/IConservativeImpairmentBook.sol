// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IConservativeImpairmentBook — the raw impairment inputs `ConservativeImpairmentMath` reads
/// @notice Every value the ADR-0022 conservative-redemption NAV needs from the credit book, and
///         nothing else. `DefaultManager` satisfies this with getters that already existed for
///         observability; only `pastDuePrincipal` was added when the arithmetic was extracted.
/// @dev Deliberately NOT `IDefaultManager`: the calculator must not be able to reach a state
///      transition on the book, and a reader interface this narrow makes that structural rather
///      than a review promise. Every member is `view`.
///
///      DO NOT WIDEN THIS INTERFACE to include a non-view function. The calculator is handed an
///      arbitrary `book` address by its caller; keeping the surface read-only is what guarantees a
///      mis-wired or hostile caller cannot use the calculator as a proxy for a privileged call.
interface IConservativeImpairmentBook {
    /// @notice Per-class outstanding principal of loans in default whose loss is not yet realized.
    function declaredDefaultedPrincipal(uint256 classId) external view returns (uint256);

    /// @notice Per-class at-risk principal of facilities flagged past due (AUDIT FIX H-5).
    function pastDuePrincipal(uint256 classId) external view returns (uint256);

    /// @notice Historical per-class drawn-cohort principal retained for observability.
    /// @dev ADR-0035 gives this cohort no distinct coverage formula.
    function drawnDefaultPrincipal(uint256 classId) external view returns (uint256);

    /// @notice sGROVE coverage already drawn by defaults that are still declared-but-unrealized.
    function liveDefaultCoverageConsumed() external view returns (uint256);

    /// @notice Aggregate remaining-principal claim of live drawn defaults.
    /// @dev ADR-0035 makes this demand-side observability, not physical capacity. The ledger applies
    ///      the one shared live reserve separately when reconstructing the cascade.
    function liveDefaultCoverageRemaining() external view returns (uint256);

    /// @notice The sGROVE cascade backstop, or the zero address when none is wired.
    function backstop() external view returns (address);

    /// @notice When the UNATTESTED past-due cohort last went empty -> non-empty (OWNER DECISION
    ///         2026-08-07, G2W). ZERO MEANS UNSET and must fail SAFE to full weight.
    /// @dev Added by the G2W merge. `DefaultManager` holds the slot, but the ramp that consumes it
    ///      lives in `ConservativeImpairmentMath`, so it has to cross the seam. Still `view`.
    function pastDueReliefAnchor() external view returns (uint256);

    /// @notice Wired module addresses; the calculator uses only `curator`.
    function modules()
        external
        view
        returns (
            address bridge,
            address registry,
            address reserves,
            address controller,
            address curator,
            address oracle,
            address vault,
            address commitmentLedger
        );
}
