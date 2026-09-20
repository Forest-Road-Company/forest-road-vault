// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IAccrualLifecycle
/// @notice Authenticated loan events consumed by the reserve's continuous accounting book.
/// @dev These methods accept no caller-selected accounting timestamp or interest correction.
interface IAccrualLifecycle {
    /// @notice Supported forward fixed-rate terms, projected from a consumed bridge amendment.
    struct Terms {
        uint16 rateBps;
        uint32 yearSeconds;
        uint64 nextPaymentDue;
        uint64 paymentInterval;
        uint64 maturity;
    }

    /// @notice Contractual debt, separately disclosed from the reserve's streamed accounting face.
    struct Debt {
        uint256 principal;
        uint256 interest;
        uint256 balanceCeiling;
        uint64 accruedThrough;
        uint64 nextCapitalization;
        uint64 maturity;
        bool pik;
        bool active;
        bool known;
    }

    /// @notice Registers the bound waterfall's just-funded, authenticated bridge facility.
    function registerAccruingLoan(uint256 facilityId) external;

    /// @notice Processes a bounded number of chronological due events; partial progress persists.
    function checkpointAccrual(uint256 maximum) external returns (uint256 processed, bool fresh);

    /// @notice Transfers one facility's existing virtual receivable into its native face ledger.
    function postAccruedLoan(uint256 facilityId) external returns (uint256 amount);

    /// @notice Applies the bridge's consumed, authenticated amendment prospectively.
    function amendAccruingLoan(uint256 facilityId, Terms calldata terms) external;

    /// @notice Aligns and permanently stops the facility before its default declaration snapshot.
    function stopAccruingLoan(uint256 facilityId) external;

    /// @notice Changes only the bound default manager's growing past-due cohort membership.
    function setAccrualPastDue(uint256 facilityId, bool marked) external;

    /// @notice Contractual debt through the capped, coherent portfolio frontier, in constant time.
    function accruedDebt(uint256 facilityId) external view returns (Debt memory);

    /// @notice Additional unposted interest on a class's marked past-due cohort.
    function accruedPastDue(uint256 classId) external view returns (uint256 amount);

    /// @notice Streamed book face not yet posted for one facility; distinct from canonical interest.
    function unpostedAccruedLoan(uint256 facilityId) external view returns (uint256 amount);
}

/// @notice The reserve alone advances already signed PIK capitalization boundaries.
interface IAccrualBridge {
    function setAccruedPaymentDue(uint256 facilityId, uint64 nextDue) external;
}

/// @notice Narrow notification of a posted receivable already counted in effective exposure.
interface IAccrualRegistry {
    function recordAccruedExposure(uint256 classId, bytes32 borrowerId, bytes32 stateId, uint256 amount) external;
}

/// @notice Moves already-counted cohort growth into the default manager's recorded risk carrier.
interface IAccrualRisk {
    function onAccrualPosted(uint256 facilityId, uint256 amount) external;
}

/// @notice The waterfall changes its standing interest fee only prospectively.
interface IAccrualFeeConfig {
    function setAccrualFee(uint16 feeBps, address recipient) external;
}

/// @notice Constant-time servicing of signed dates with no positive queued accrual work.
interface IAccrualServicing {
    function serviceAccruedLoan(uint256 facilityId) external returns (uint256 capitalized);
    function accrualLoanScheduled(uint256 facilityId) external view returns (bool);
}

/// @notice Explicit native loss allocation of an independently derived sub-unit discrepancy.
interface IAccrualRounding {
    /// @notice Monotone unabsorbed contractual rounding loss, never caller-selected debt relief.
    function roundingLossUnabsorbed() external view returns (uint256);

    /// @notice Controller-only consumption of one exact reserve-owned physical burn permit.
    /// @dev Returns false outside a rounding continuation; normal loss admission then applies.
    function consumeAccrualLossBurn(address caller, address from, uint256 amount) external returns (bool);
}

/// @notice The reserve reduces only a marked contribution whose face it has actually written down.
interface IAccrualRoundingRisk {
    function onAccrualRounding(uint256 facilityId, uint256 amount) external;
}

/// @notice Registry continuation paired with a reserve-proved native rounding write-down.
interface IAccrualRoundingRegistry {
    function recordAccruedWriteDown(uint256 classId, bytes32 borrowerId, bytes32 stateId, uint256 amount) external;
}

/// @notice Measured receipt settlement and terminal retirement, separately bound to servicing modules.
interface IAccrualReceipts {
    /// @notice Measures an attested receipt and discharges separately tracked principal and interest.
    function repayAccruingLoan(uint256 facilityId, address payer, uint256 principal, uint256 interest)
        external
        returns (uint256 outstanding);

    /// @notice Releases a fully extinguished, resolved facility's active-book slot after its risk hooks.
    function retireAccruedLoan(uint256 facilityId) external;
}
