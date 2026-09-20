// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title ICommitmentLedger — recorded default rows and shared backstop deliverability.
/// @notice Keeps live row metadata and per-class principal aggregates. Conservative residuals
///         use the five class curator pools followed by the shared sGROVE reserve in constant time.
interface ICommitmentLedger {
    function coverDelegate(address backstop, address asset, uint256 eventId, uint256 residual)
        external
        returns (uint256 covered);

    event CommitmentSynced(
        uint256 indexed eventId,
        uint256 remainingCoverage,
        uint256 remainingPrincipal,
        uint256 deliverable,
        uint256 aggregateDeliverable
    );
    event CommitmentRegistered(uint256 indexed eventId, uint256 indexed classId, uint256 remainingPrincipal);
    event CommitmentPrincipalUpdated(uint256 indexed eventId, uint256 remainingPrincipal);
    event CommitmentReleased(uint256 indexed eventId, uint256 releasedDeliverable, uint256 aggregateDeliverable);
    /// @notice Register a declared default and increase its class aggregate by the recorded face.
    /// @dev Rows retain their declaration order for servicing and independent reference checks.
    function register(uint256 eventId, uint256 classId, uint256 remainingPrincipal) external;

    /// @notice Re-anchors a live event's residual principal after a recovery or realization.
    function updatePrincipal(uint256 eventId, uint256 remainingPrincipal) external;

    function sync(uint256 eventId, uint256 remainingCoverage, uint256 remainingPrincipal, uint256 covered)
        external
        returns (bool firstDraw);

    function release(uint256 eventId) external;

    function deliverableAggregate() external view returns (uint256);
    /// @notice Compute the conservative residual from a fixed number of class aggregates.
    /// @return residual Declared and past-due risk remaining after available junior capital.
    /// @return pastDueSenior The past-due portion after its policy-prioritized junior allocation.
    function conservativeResiduals() external view returns (uint256 residual, uint256 pastDueSenior);

    function remainingAggregate() external view returns (uint256);

    function consumed(uint256 eventId) external view returns (uint256);

    function consumedAggregate() external view returns (uint256);

    function deliverable(uint256 eventId) external view returns (uint256);

    function state(uint256 eventId)
        external
        view
        returns (uint256 remainingCoverage, uint256 remainingPrincipal, uint256 eventDeliverable);

    function eventCount() external view returns (uint256);

    function eventAt(uint256 index) external view returns (uint256 eventId);

    /// @notice Complete mark-time inputs for one registered event.
    /// @dev `remainingCoverage` is an ADR-0035 compatibility field equal to the event's remaining
    ///      principal once drawn; physical deliverability is bounded separately by the shared
    ///      reserve during reconstruction.
    function eventInfo(uint256 eventId)
        external
        view
        returns (uint256 classId, bool drawn, uint256 remainingCoverage, uint256 remainingPrincipal);
}
