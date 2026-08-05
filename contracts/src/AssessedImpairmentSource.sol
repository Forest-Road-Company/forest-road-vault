// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IImpairmentSource} from "./interfaces/IImpairmentSource.sol";
import {IRevisionedImpairmentSource} from "./interfaces/IRevisionedImpairmentSource.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title AssessedImpairmentSource — governed recovery assessment for redemption pricing
/// @notice Wraps the protocol's zero-recovery impairment source and permits governance to publish
///         a time-limited, professionally assessed senior impairment. The assessed amount is an
///         absolute USDfr loss AFTER applying estimated recoveries and the curator/sGROVE cascade;
///         this avoids the incorrect result produced by simply multiplying the zero-recovery
///         senior impairment by a recovery percentage.
///
///         Safety is deliberately one-sided:
///         - an assessment can only LOWER the base source's zero-recovery impairment;
///         - an assessment is bound to one revisioned risk-state fingerprint; any new default,
///           past-due mark, recovery, realization, curator-capacity change, or global-backstop
///           capacity decrease invalidates it immediately and restores the conservative base;
///         - a global-backstop top-up does not invalidate professional work because it can only
///           add junior protection; the returned assessment is still capped by the now-lower
///           conservative base;
///         - an expired or cleared assessment falls back automatically to the base source;
///         - every assessment commits to an evidence hash and is governance/timelock controlled.
/// @dev Intended to replace `DefaultManager` as sUSDfr's narrow `IImpairmentSource`, while retaining
///      `DefaultManager` as the underlying conservative base. It never moves value.
contract AssessedImpairmentSource is Initializable, AccessControlUpgradeable, UUPSUpgradeable, IImpairmentSource {
    /// @custom:storage-location erc7201:forestroad.storage.AssessedImpairmentSource
    struct AssessmentStorage {
        IRevisionedImpairmentSource baseSource;
        uint256 assessedSeniorImpairment;
        uint64 validUntil;
        bytes32 evidenceHash;
        bytes32 assessedStateHash;
        // ── append-only (upgrade safety): directional backstop binding ─────
        bytes32 assessedRiskStateHash;
        uint256 assessedBackstopCapacity;
        // ── append-only: ADR-0031 fee-neutral junior-capacity credit ───────
        // A separate presence bit makes upgraded pre-field assessments fail
        // conservatively instead of treating their default-zero slot as a valid snapshot.
        uint256 assessedPerformanceFeeImpairment;
        bool performanceFeeImpairmentSnapshotted;
    }

    // keccak256(abi.encode(uint256(keccak256("forestroad.storage.AssessedImpairmentSource")) - 1))
    // & ~bytes32(uint256(0xff))
    bytes32 private constant ASSESSMENT_STORAGE_LOCATION =
        0x22d1327051d3790a2a295641453e9e7c93d6a209be7b99c1b2a8eee179860200;
    // Pre-fix testnet implementations wrote this struct to a slot that did not match the
    // annotation. Keep a read/write fallback so an existing proxy can be upgraded without
    // orphaning its assessment state. Fresh deployments always select the canonical slot above.
    bytes32 private constant LEGACY_ASSESSMENT_STORAGE_LOCATION =
        0x07e2328902311370f02c9c7e3d28358251569e375a804933066de765ee700700;

    /// @notice Maximum lifetime of one professional recovery assessment.
    /// @dev Forces a monthly refresh during a workout. On expiry, pricing automatically returns
    ///      to the zero-recovery base rather than silently relying on stale professional judgment.
    uint64 public constant MAX_ASSESSMENT_TTL = 30 days;

    event AssessmentSet(
        uint256 assessedSeniorImpairment,
        uint256 zeroRecoverySeniorImpairment,
        uint64 validUntil,
        bytes32 indexed evidenceHash,
        bytes32 indexed stateHash
    );
    event AssessmentCleared();
    event BaseSourceSet(address indexed oldSource, address indexed newSource);
    /// @notice Records the performance-fee impairment bound to a professional assessment.
    /// @dev This is the assessed senior amount plus the fee-neutral junior-capital credit
    ///      standing when the assessment was published.
    event AssessmentPerformanceFeeImpairmentSet(uint256 performanceFeeImpairment);

    error Assessment_ZeroAddress();
    error Assessment_ZeroEvidenceHash();
    error Assessment_NotFuture(uint64 validUntil);
    error Assessment_TooLong(uint64 validUntil, uint64 maxValidUntil);
    error Assessment_ExceedsConservativeBase(uint256 assessed, uint256 conservativeBase);
    error Assessment_InvalidPerformanceFeeImpairment(uint256 performanceFeeImpairment, uint256 conservativeBase);
    error Assessment_BaseNotRevisioned(address source);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the assessed impairment wrapper.
    /// @param admin Governance timelock; the only authority that may publish an assessment.
    /// @param upgrader Upgrade authority, expected to be the same governance timelock.
    /// @param baseSource_ The zero-recovery impairment source (normally DefaultManager).
    function initialize(address admin, address upgrader, address baseSource_) external initializer {
        if (admin == address(0) || upgrader == address(0) || baseSource_ == address(0)) {
            revert Assessment_ZeroAddress();
        }
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
        _requireRevisionedSource(baseSource_);
        _storage().baseSource = IRevisionedImpairmentSource(baseSource_);
        emit BaseSourceSet(address(0), baseSource_);
    }

    /// @notice Publishes a time-limited professional assessment of the loss that can reach seniors.
    /// @dev `assessedSeniorImpairment` is an absolute 18-decimal USDfr amount after estimated
    ///      recoveries and both junior layers. It may be zero. It cannot exceed the current
    ///      zero-recovery result, because this override exists to recognize supportable recovery,
    ///      not to invent a harsher mark than the conservative engine.
    /// @param assessedSeniorImpairment The assessed senior loss in USDfr.
    /// @param validUntil Expiry timestamp, no more than 30 days from this transaction.
    /// @param evidenceHash Hash of the signed valuation/recovery memorandum and supporting data.
    function setAssessment(uint256 assessedSeniorImpairment, uint64 validUntil, bytes32 evidenceHash)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (evidenceHash == bytes32(0)) revert Assessment_ZeroEvidenceHash();
        if (validUntil <= block.timestamp) revert Assessment_NotFuture(validUntil);
        uint64 maxValidUntil = uint64(block.timestamp) + MAX_ASSESSMENT_TTL;
        if (validUntil > maxValidUntil) revert Assessment_TooLong(validUntil, maxValidUntil);

        AssessmentStorage storage $ = _storage();
        uint256 conservativeBase = $.baseSource.pendingSeniorImpairment();
        if (assessedSeniorImpairment > conservativeBase) {
            revert Assessment_ExceedsConservativeBase(assessedSeniorImpairment, conservativeBase);
        }
        uint256 basePerformanceFeeImpairment = $.baseSource.performanceFeeImpairment();
        if (basePerformanceFeeImpairment < conservativeBase) {
            revert Assessment_InvalidPerformanceFeeImpairment(basePerformanceFeeImpairment, conservativeBase);
        }
        $.assessedSeniorImpairment = assessedSeniorImpairment;
        // Snapshot only the junior-capital credit, not a free-running NAV delta.
        // Supported recovery remains performance-bearing above the old HWM, while later
        // curator/backstop changes cannot manufacture performance.
        $.assessedPerformanceFeeImpairment =
            assessedSeniorImpairment + (basePerformanceFeeImpairment - conservativeBase);
        $.performanceFeeImpairmentSnapshotted = true;
        $.validUntil = validUntil;
        $.evidenceHash = evidenceHash;
        bytes32 stateHash = $.baseSource.impairmentStateHash();
        $.assessedStateHash = stateHash;
        $.assessedRiskStateHash = $.baseSource.impairmentRiskStateHash();
        $.assessedBackstopCapacity = $.baseSource.impairmentBackstopCapacity();
        emit AssessmentSet(assessedSeniorImpairment, conservativeBase, validUntil, evidenceHash, stateHash);
        emit AssessmentPerformanceFeeImpairmentSet($.assessedPerformanceFeeImpairment);
    }

    /// @notice Clears the live assessment immediately; redemption pricing returns to zero recovery.
    function clearAssessment() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _clearAssessment(_storage());
    }

    /// @notice Changes the underlying zero-recovery impairment engine.
    /// @dev Governance-only and evented. A base change clears the assessment: professional work
    ///      performed against one engine must never carry into a different engine.
    function setBaseSource(address newSource) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSource == address(0)) revert Assessment_ZeroAddress();
        _requireRevisionedSource(newSource);
        AssessmentStorage storage $ = _storage();
        address oldSource = address($.baseSource);
        $.baseSource = IRevisionedImpairmentSource(newSource);
        _clearAssessment($);
        emit BaseSourceSet(oldSource, newSource);
    }

    /// @inheritdoc IImpairmentSource
    function pendingSeniorImpairment() external view returns (uint256) {
        AssessmentStorage storage $ = _storage();
        uint256 conservativeBase = $.baseSource.pendingSeniorImpairment();
        if ($.validUntil == 0 || block.timestamp > $.validUntil) return conservativeBase;
        if (!_assessmentStateMatches($)) return conservativeBase;
        uint256 assessed = $.assessedSeniorImpairment;
        return assessed < conservativeBase ? assessed : conservativeBase;
    }

    /// @inheritdoc IImpairmentSource
    /// @dev The assessment snapshots the junior-capital credit standing at publication.
    ///      A permitted global-backstop increase therefore cannot move this fee base even
    ///      though it may improve redemption protection. Expired, invalid, cleared, or
    ///      pre-upgrade assessments fail conservatively to the base source's gross view.
    function performanceFeeImpairment() external view returns (uint256) {
        AssessmentStorage storage $ = _storage();
        if (
            !$.performanceFeeImpairmentSnapshotted || $.validUntil == 0 || block.timestamp > $.validUntil
                || !_assessmentStateMatches($)
        ) {
            return $.baseSource.performanceFeeImpairment();
        }
        return $.assessedPerformanceFeeImpairment;
    }

    /// @notice Returns the current assessment and the zero-recovery comparison value.
    /// @return assessedSeniorImpairment The submitted senior impairment.
    /// @return validUntil Its expiry timestamp.
    /// @return evidenceHash Hash of the supporting recovery memorandum.
    /// @return active Whether the assessment currently controls the returned value.
    /// @return zeroRecoverySeniorImpairment The live result from the conservative base source.
    function currentAssessment()
        external
        view
        returns (
            uint256 assessedSeniorImpairment,
            uint64 validUntil,
            bytes32 evidenceHash,
            bool active,
            uint256 zeroRecoverySeniorImpairment
        )
    {
        AssessmentStorage storage $ = _storage();
        assessedSeniorImpairment = $.assessedSeniorImpairment;
        validUntil = $.validUntil;
        evidenceHash = $.evidenceHash;
        zeroRecoverySeniorImpairment = $.baseSource.pendingSeniorImpairment();
        active = validUntil != 0 && block.timestamp <= validUntil && _assessmentStateMatches($);
    }

    /// @notice Shows the snapshot binding used to decide whether an assessment is still active.
    /// @return assessedStateHash Hash captured when governance published the assessment.
    /// @return currentStateHash Live hash from the conservative base.
    /// @return matches Whether the live state is assessment-compatible. The exact hashes may
    ///         differ only when global backstop capacity increased from the assessed snapshot.
    function assessmentState()
        external
        view
        returns (bytes32 assessedStateHash, bytes32 currentStateHash, bool matches)
    {
        AssessmentStorage storage $ = _storage();
        assessedStateHash = $.assessedStateHash;
        currentStateHash = $.baseSource.impairmentStateHash();
        matches = assessedStateHash != bytes32(0) && _assessmentStateMatches($);
    }

    /// @notice The wired zero-recovery impairment source.
    function baseSource() external view returns (address) {
        return address(_storage().baseSource);
    }

    function _authorizeUpgrade(address) internal view override onlyRole(Roles.UPGRADER_ROLE) {
        // Enforce the first dependency edge of the dual-NAV upgrade order. The base
        // DefaultManager proxy must already expose the complete revisioned interface before
        // this wrapper can move to another implementation.
        _requireRevisionedSource(address(_storage().baseSource));
    }

    function _clearAssessment(AssessmentStorage storage $) private {
        $.assessedSeniorImpairment = 0;
        $.validUntil = 0;
        $.evidenceHash = bytes32(0);
        $.assessedStateHash = bytes32(0);
        $.assessedRiskStateHash = bytes32(0);
        $.assessedBackstopCapacity = 0;
        $.assessedPerformanceFeeImpairment = 0;
        $.performanceFeeImpairmentSnapshotted = false;
        emit AssessmentCleared();
    }

    function _assessmentStateMatches(AssessmentStorage storage $) private view returns (bool) {
        bytes32 currentStateHash = $.baseSource.impairmentStateHash();
        if ($.assessedStateHash == currentStateHash) return true;
        // A pre-upgrade assessment has no directional snapshots and must fail closed
        // after any exact-state change. Governance can republish it against the new model.
        if ($.assessedRiskStateHash == bytes32(0)) return false;
        if ($.assessedRiskStateHash != $.baseSource.impairmentRiskStateHash()) return false;
        return $.baseSource.impairmentBackstopCapacity() >= $.assessedBackstopCapacity;
    }

    /// @dev Validate the complete revisioned interface explicitly. This wrapper must never silently
    ///      accept the old amount-only interface, because that recreates the stale-assessment
    ///      vulnerability; nor should it accept a revision-only source that later bricks pricing.
    function _requireRevisionedSource(address source) private view {
        (bool impairmentOk, bytes memory impairmentData) =
            source.staticcall(abi.encodeCall(IImpairmentSource.pendingSeniorImpairment, ()));
        (bool performanceImpairmentOk, bytes memory performanceImpairmentData) =
            source.staticcall(abi.encodeCall(IImpairmentSource.performanceFeeImpairment, ()));
        (bool revisionOk, bytes memory revisionData) =
            source.staticcall(abi.encodeCall(IRevisionedImpairmentSource.impairmentRevision, ()));
        (bool hashOk, bytes memory hashData) =
            source.staticcall(abi.encodeCall(IRevisionedImpairmentSource.impairmentStateHash, ()));
        (bool riskHashOk, bytes memory riskHashData) =
            source.staticcall(abi.encodeCall(IRevisionedImpairmentSource.impairmentRiskStateHash, ()));
        (bool capacityOk, bytes memory capacityData) =
            source.staticcall(abi.encodeCall(IRevisionedImpairmentSource.impairmentBackstopCapacity, ()));
        if (
            !impairmentOk || impairmentData.length != 32 || !performanceImpairmentOk
                || performanceImpairmentData.length != 32 || !revisionOk || revisionData.length != 32 || !hashOk
                || hashData.length != 32 || !riskHashOk || riskHashData.length != 32 || !capacityOk
                || capacityData.length != 32
        ) {
            revert Assessment_BaseNotRevisioned(source);
        }
        uint256 conservativeBase = abi.decode(impairmentData, (uint256));
        uint256 performanceFeeBase = abi.decode(performanceImpairmentData, (uint256));
        if (performanceFeeBase < conservativeBase) {
            revert Assessment_InvalidPerformanceFeeImpairment(performanceFeeBase, conservativeBase);
        }
    }

    function _storage() private view returns (AssessmentStorage storage $) {
        bytes32 slot = ASSESSMENT_STORAGE_LOCATION;
        bytes32 legacySlot = LEGACY_ASSESSMENT_STORAGE_LOCATION;
        assembly {
            // baseSource is permanently non-zero after initialization, so it is a reliable
            // discriminator between a fresh canonical deployment and an upgraded legacy proxy.
            if and(iszero(sload(slot)), iszero(iszero(sload(legacySlot)))) { slot := legacySlot }
            $.slot := slot
        }
    }
}
