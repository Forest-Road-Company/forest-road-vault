// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IAttestationOracle} from "./interfaces/IAttestationOracle.sol";
import {IDefaultManager} from "./interfaces/IDefaultManager.sol";

/// @title MtmAtomicExecutor — canonical all-or-nothing MTM protection
/// @notice Permissionlessly relays one threshold-signed valuation and applies the strongest
///         protective action that the resulting on-chain state permits in the same transaction.
///         If the selected action fails, the valuation is rolled back.
///
///         The executor is deliberately immutable, roleless, non-upgradeable, and unable to make
///         arbitrary calls. A keeper key therefore receives no protocol authority: signatures
///         authorize the mark and DefaultManager's on-chain rules authorize the action.
/// @dev Selection is intentionally not supplied by the caller. Liquidation is attempted first.
///      Falling back is allowed only when DefaultManager reports its exact
///      `DefaultManager_ThresholdNotBreached` error; any operational or downstream failure is
///      bubbled instead of being silently downgraded to a margin call or cure.
///
///      AUDIT FIX (G8-L1/G8-L2). Two of those states are reached by ANY unprivileged bystander:
///      a permissionless `DefaultManager.marginCall` (after which every relay of a still-breached
///      mark reverted for the whole cure window) and a permissionless `DefaultManager.liquidate`
///      (after which every relay for that facility reverted forever). In both, DefaultManager's
///      own rules leave NO protective action available because the protective action has already
///      happened, and discarding the mark left the protocol marked on an older, unverified
///      valuation — the unsafe direction, since valuations feed `ReserveManager.totalBackingValue`.
///      Those two exactly-characterized states now report `Action.NoActionAvailable` and KEEP the
///      valuation. This grants a keeper nothing: `AttestationOracle.attest` is itself a
///      permissionless relay of the same threshold-signed bundle, so landing a mark through the
///      executor is exactly as powerful as landing it directly. A mark that is merely healthy
///      with no call standing is deliberately NOT in this set: there the rejected mark is the
///      conservative one, and rolling it back stays the safe direction.
contract MtmAtomicExecutor is ReentrancyGuard {
    enum Action {
        MarginCall,
        ClearMarginCall,
        Liquidate,
        /// @dev AUDIT FIX (G8-L1/G8-L2). TAIL-APPENDED — never reorder or insert above this
        ///      member: `MtmActionExecuted` encodes the action as a uint8 ordinal and keepers
        ///      and indexers decode it by ordinal. Reported when DefaultManager's own rules
        ///      leave NO protective action available for this facility.
        NoActionAvailable
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
            // AUDIT FIX (G8-L2). A permissionless `DefaultManager.liquidate` by ANY bystander
            // moves the facility out of Active/Amortizing, after which `_mtmFacility` rejects
            // all three protective entry points identically and the executor bubbled that
            // revert forever — one unprivileged transaction permanently bricked the canonical
            // relay path for that facility. There is no action left to skip here (marginCall,
            // clearMarginCall and liquidate all begin with the same `_mtmFacility` check), so
            // the mark is kept and the outcome is reported. NEVER widen this to any other
            // DefaultManager error: `NotMarkedToMarket` is a misconfiguration and `EnforcedPause`
            // means the protective layer is down — both must keep aborting the whole relay.
            if (_isCanonicalNotDefaultable(reason, facilityId)) {
                action = Action.NoActionAvailable;
            } else if (!_isCanonicalThresholdMiss(reason, facilityId)) {
                _revert(reason);
            } else if (activeCall) {
                // AUDIT FIX (G8-L1). A standing margin call — which any bystander can open
                // permissionlessly off an in-breach mark — does NOT imply the new mark cures.
                // Calling `clearMarginCall` unconditionally made every relay of a still-breached
                // mark revert for the whole cure window and discarded the mark with it, leaving
                // the book on the older, unverified valuation. Only the canonical cure miss
                // (this facility, ltv >= the margin-call threshold) is tolerated; in that state
                // the standing call already IS the protective action `marginCall` would have
                // opened, so nothing is skipped. Do not delete this catch: any other failure,
                // including a stale mark or a paused manager, must still abort the relay.
                try defaultManager.clearMarginCall(facilityId) {
                    action = Action.ClearMarginCall;
                } catch (bytes memory cureReason) {
                    if (!_isCanonicalCureMiss(cureReason, facilityId)) _revert(cureReason);
                    action = Action.NoActionAvailable;
                }
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

    /// @dev AUDIT FIX (G8-L1). The MIRROR relation of `_isCanonicalThresholdMiss`, for the cure
    ///      leg: `clearMarginCall` reverts with the same error when the mark does NOT cure, i.e.
    ///      `ltv >= threshold`. Requiring the complete canonical ABI shape, this facility ID and
    ///      the not-cured relation keeps a malformed, cross-facility or selector-colliding
    ///      downstream revert from being mistaken for "the standing call is already correct".
    function _isCanonicalCureMiss(bytes memory reason, uint256 facilityId) private pure returns (bool) {
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
        return revertedFacilityId == facilityId && thresholdBps != 0 && ltvBps >= thresholdBps;
    }

    /// @dev AUDIT FIX (G8-L2). Exact `DefaultManager_NotDefaultable(tokenId)` ABI shape for THIS
    ///      facility: 4-byte selector plus one word, nothing else. The length equality is
    ///      load-bearing — a longer payload that merely starts with the selector is not this
    ///      error and must keep aborting the relay.
    function _isCanonicalNotDefaultable(bytes memory reason, uint256 facilityId) private pure returns (bool) {
        if (reason.length != 36 || _selector(reason) != IDefaultManager.DefaultManager_NotDefaultable.selector) {
            return false;
        }
        uint256 revertedFacilityId;
        assembly ("memory-safe") {
            revertedFacilityId := mload(add(reason, 0x24))
        }
        return revertedFacilityId == facilityId;
    }

    function _revert(bytes memory reason) private pure {
        assembly ("memory-safe") {
            revert(add(reason, 0x20), mload(reason))
        }
    }
}
