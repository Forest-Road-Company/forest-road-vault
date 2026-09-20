// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @notice Bridge ABI used by the archived Facility 1 package at Ethereum block 25,848,835.
/// @dev The 17-field tuple is retained from 51769ab59c309e346bfed5777e1ad3e2c6900ea9.
///      The current bridge's appended PIK flag changes both external function selectors.
interface IFacility1Bridge {
    enum RateType {
        Fixed,
        Variable
    }
    enum DayCountConvention {
        Actual360,
        Actual365,
        Thirty360
    }

    struct OriginationTerms {
        uint256 classId;
        bytes32 borrowerId;
        bytes32 stateId;
        uint256 principal;
        uint16 ltvBps;
        uint16 interestRateBps;
        uint64 maturity;
        address fundingRecipient;
        uint64 paymentInterval;
        uint64 nextPaymentDue;
        RateType rateType;
        DayCountConvention dayCountConvention;
        bool renewable;
        bytes32 paymentScheduleHash;
        bytes32 rateIndexRef;
        bytes32 renewalTermsHash;
        bytes32 offchainRef;
    }

    function creditTermsHash(OriginationTerms calldata terms) external pure returns (bytes32);
    function originate(address recipient, OriginationTerms calldata terms) external returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
}
