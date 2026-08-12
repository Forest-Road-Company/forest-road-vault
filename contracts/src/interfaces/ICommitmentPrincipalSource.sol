// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

interface ICommitmentPrincipalSource {
    function defaultedContribution(uint256 eventId) external view returns (uint256);
}
