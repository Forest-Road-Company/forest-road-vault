// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title LossEventIds — disjoint namespaces for facility and custody-loss events
/// @notice Facility NFTs use the lower half of uint256. Governance-assigned custody incidents
///         use the upper half, so both kinds can safely share SGrove's event-coverage mappings.
library LossEventIds {
    uint256 internal constant CUSTODY_EVENT_NAMESPACE_START = 1 << 255;

    error LossEventIds_InvalidCustodyArm(uint256 armId);

    function isFacilityEvent(uint256 eventId) internal pure returns (bool) {
        return eventId < CUSTODY_EVENT_NAMESPACE_START;
    }

    function isCustodyEvent(uint256 eventId) internal pure returns (bool) {
        return eventId >= CUSTODY_EVENT_NAMESPACE_START;
    }

    /// @dev Arm ids are generated internally, start at one and stay in the lower namespace.
    ///      The explicit post-condition keeps the facility/custody partition executable rather
    ///      than relying on a comment at each call site.
    function custodyEventId(uint256 armId) internal pure returns (uint256 eventId) {
        if (armId == 0 || armId >= CUSTODY_EVENT_NAMESPACE_START) {
            revert LossEventIds_InvalidCustodyArm(armId);
        }
        eventId = type(uint256).max - armId;
        assert(eventId >= CUSTODY_EVENT_NAMESPACE_START);
    }
}
