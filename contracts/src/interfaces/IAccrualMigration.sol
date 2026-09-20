// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @notice One governed, attested transition from recorded legacy debt to continuous accrual.
interface IAccrualMigration {
    /// @notice Contractual debt and its original current-period cursor at the migration cutoff.
    /// @dev Terms, asset, identity and recorded face come from the frozen native records.
    ///      nextCapitalization is zero for cash or for PIK with no further signed capitalization.
    struct Opening {
        uint256 facilityId;
        uint256 principal;
        uint256 interest;
        uint256 frozenPikBasis;
        uint64 periodStart;
        uint64 nextCapitalization;
        // A replacement approval can authorize identical balances after a revoked or mistimed fact.
        // The session roster still admits the facility once, regardless of this signed reference.
        bytes32 approvalRef;
    }

    /// @notice Constant-time preparation status; nextFacilityId is zero when all rows are imported.
    struct Progress {
        uint256 nonce;
        bytes32 sessionKey;
        uint64 cutoff;
        uint32 expected;
        uint32 imported;
        uint256 originalFace;
        uint256 importedOriginalFace;
        uint256 nextFacilityId;
        bool active;
    }

    /// @notice Begins or advances a governed migration, or cancels it before its first import.
    /// @dev step = abi.encode(uint8 action, bytes body). Actions: 0 begins with
    ///      abi.encode(uint256[] sortedFacilityIds); 1 imports abi.encode(Opening[]);
    ///      2 cancels with an empty body. Imports contain at most eight rows.
    function prepareContinuousAccrualMigration(bytes calldata step) external;

    /// @notice Returns preparation progress without quoting or advancing a partially imported book.
    function accrualMigration() external view returns (Progress memory);
}

/// @notice Reserve-only continuation that installs opening risk after native face has been posted.
interface IAccrualMigrationRisk {
    /// @return marked True even for a marked facility whose previous recorded contribution was zero.
    function onAccrualOpening(uint256 facilityId, uint256 income) external returns (bool marked);
}
