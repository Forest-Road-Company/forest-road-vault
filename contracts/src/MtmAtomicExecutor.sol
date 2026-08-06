// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IAttestationOracle} from "./interfaces/IAttestationOracle.sol";
import {IDefaultManager} from "./interfaces/IDefaultManager.sol";

/// @title MtmAtomicExecutor — canonical all-or-nothing MTM protection
/// @notice Permissionlessly relays one threshold-signed valuation and applies the strongest
///         protective action that the resulting on-chain state permits in the same transaction.
///         If no action is available, or the selected action fails, the valuation is rolled back.
///
///         The executor is deliberately immutable, roleless, non-upgradeable, and unable to make
///         arbitrary calls. A keeper key therefore receives no protocol authority: signatures
///         authorize the mark and DefaultManager's on-chain rules authorize the action.
/// @dev Selection is intentionally not supplied by the caller. Liquidation is attempted first.
///      Falling back is allowed only when DefaultManager reports its exact
///      `DefaultManager_ThresholdNotBreached` error; any operational or downstream failure is
///      bubbled instead of being silently downgraded to a margin call or cure.
contract MtmAtomicExecutor is ReentrancyGuard {
    enum Action {
        MarginCall,
        ClearMarginCall,
        Liquidate
    }

    IAttestationOracle public immutable oracle;
    IDefaultManager public immutable defaultManager;

    event MtmActionExecuted(
        uint256 indexed facilityId, bytes32 indexed attestationDigest, address indexed keeper, Action action
    );

    error MtmExecutor_ZeroAddress();
    error MtmExecutor_NoCode(address target);
    error MtmExecutor_NotValuation(IAttestationOracle.AttestationKind kind);

    constructor(address oracle_, address defaultManager_) {
        if (oracle_ == address(0) || defaultManager_ == address(0)) revert MtmExecutor_ZeroAddress();
        if (oracle_.code.length == 0) revert MtmExecutor_NoCode(oracle_);
        if (defaultManager_.code.length == 0) revert MtmExecutor_NoCode(defaultManager_);
        oracle = IAttestationOracle(oracle_);
        defaultManager = IDefaultManager(defaultManager_);
    }

    /// @notice Atomically attest a valuation and execute its canonical protective action.
    /// @param attestation Threshold-signed Valuation input for one facility.
    /// @param signatures Ascending recovered-signer order, as required by AttestationOracle.
    /// @return action The action completed in this transaction.
    function execute(IAttestationOracle.AttestationInput calldata attestation, bytes[] calldata signatures)
        external
        nonReentrant
        returns (Action action)
    {
        if (attestation.kind != IAttestationOracle.AttestationKind.Valuation) {
            revert MtmExecutor_NotValuation(attestation.kind);
        }

        bytes32 digest = oracle.attestationDigest(attestation);
        oracle.attest(attestation, signatures);

        uint256 facilityId = attestation.facilityId;
        bool activeCall = defaultManager.cureDeadline(facilityId) != 0;

        // A hard-threshold breach, or a still-breached call strictly after its deadline,
        // always wins. Only the canonical "threshold not breached" result may fall through.
        try defaultManager.liquidate(facilityId) {
            action = Action.Liquidate;
        } catch (bytes memory reason) {
            if (!_isCanonicalThresholdMiss(reason, facilityId)) {
                _revert(reason);
            }
            if (activeCall) {
                defaultManager.clearMarginCall(facilityId);
                action = Action.ClearMarginCall;
            } else {
                defaultManager.marginCall(facilityId);
                action = Action.MarginCall;
            }
        }

        emit MtmActionExecuted(facilityId, digest, msg.sender, action);
    }

    function _selector(bytes memory reason) private pure returns (bytes4 selector) {
        if (reason.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(reason, 0x20))
        }
    }

    /// @dev Custom-error selectors do not carry provenance. Requiring the complete canonical ABI
    ///      shape, this facility ID, and the threshold-miss relation prevents a malformed or
    ///      selector-colliding downstream revert from downgrading liquidation to a lesser action.
    function _isCanonicalThresholdMiss(bytes memory reason, uint256 facilityId) private pure returns (bool) {
        if (reason.length != 100 || _selector(reason) != IDefaultManager.DefaultManager_ThresholdNotBreached.selector) {
            return false;
        }
        uint256 revertedFacilityId;
        uint256 ltvBps;
        uint256 thresholdBps;
        assembly ("memory-safe") {
            revertedFacilityId := mload(add(reason, 0x24))
            ltvBps := mload(add(reason, 0x44))
            thresholdBps := mload(add(reason, 0x64))
        }
        return revertedFacilityId == facilityId && thresholdBps != 0 && ltvBps < thresholdBps;
    }

    function _revert(bytes memory reason) private pure {
        assembly ("memory-safe") {
            revert(add(reason, 0x20), mload(reason))
        }
    }
}
