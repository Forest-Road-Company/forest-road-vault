// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title ICommitmentLedger — recorded default rows and constant-time senior residuals.
/// @notice Keeps live row metadata and per-class principal aggregates. BSC has no layer-two
///         backstop: its three class curator pools absorb recognized losses before senior capital.
interface ICommitmentLedger {
    /// @notice A live event's remaining principal was re-anchored after a recovery or realization.
    event CommitmentPrincipalUpdated(uint256 indexed eventId, uint256 remainingPrincipal);
    /// @notice A declared default entered the declaration-ordered live set.
    event CommitmentRegistered(uint256 indexed eventId, uint256 indexed classId, uint256 remainingPrincipal);
    /// @notice A live event left the set; `releasedPrincipal` is what it still carried on exit.
    event CommitmentReleased(uint256 indexed eventId, uint256 releasedPrincipal, uint256 aggregateRemainingPrincipal);
    /// @notice Register a declared default and increase its class aggregate by the recorded face.
    /// @dev Rows retain their declaration order for servicing and independent reference checks.
    function register(uint256 eventId, uint256 classId, uint256 remainingPrincipal) external;

    /// @notice Re-anchors a live event's residual principal after a recovery or realization.
    /// @param eventId The registered event.
    /// @param remainingPrincipal The principal still at risk.
    function updatePrincipal(uint256 eventId, uint256 remainingPrincipal) external;

    /// @notice Drops a live event's row once nothing of it is left unrealized.
    /// @dev Idempotent: releasing an unknown or already-released event is a no-op, so the two
    ///      terminal callers in `DefaultManager` cannot double-release.
    /// @param eventId The event to release.
    function release(uint256 eventId) external;
    /// @notice Compute the conservative residual from a fixed number of class aggregates.
    /// @return residual Declared and past-due risk remaining after available junior capital.
    /// @return pastDueSenior The past-due portion after its policy-prioritized junior allocation.
    function conservativeResiduals() external view returns (uint256 residual, uint256 pastDueSenior);

    /// @notice Aggregate remaining principal of every live declared event.
    /// @dev Maintained O(1) by `register`/`updatePrincipal`/`release`, so it is always exactly the
    ///      sum the walk would compute. It replaces the deleted layer-two `deliverableAggregate`
    ///      as the ledger's contribution to `DefaultManager.impairmentRiskStateHash()`: an
    ///      ADR-0027 assessment must invalidate when the quantity the NAV nets against MOVES, and
    ///      on this instance that quantity is live gross principal, not layer-two credit.
    function remainingPrincipalAggregate() external view returns (uint256);

    /// @notice Number of live declared events.
    function eventCount() external view returns (uint256);

    /// @notice The event id at `index` in declaration order.
    /// @param index Position in the live set; reverts out of range.
    function eventAt(uint256 index) external view returns (uint256 eventId);

    /// @notice Complete mark-time inputs for one registered event.
    /// @param eventId The event to read.
    /// @return classId The event's collateral class, or zero when it is not registered.
    /// @return remainingPrincipal The principal still at risk.
    function eventInfo(uint256 eventId) external view returns (uint256 classId, uint256 remainingPrincipal);
}
