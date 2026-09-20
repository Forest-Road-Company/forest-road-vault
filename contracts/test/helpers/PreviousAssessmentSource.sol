// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

// Test-only previous implementation, executable source preserved from the baseline commit.
// Original SHA-256: db9eef3813d7f9d723928be453e4cb77dce47b2d21e736aa799883faeb86d3d0

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IImpairmentSource} from "../../src/interfaces/IImpairmentSource.sol";
import {IRevisionedImpairmentSource} from "../../src/interfaces/IRevisionedImpairmentSource.sol";
import {Roles} from "../../src/libraries/Roles.sol";

contract PreviousAssessmentSource is Initializable, AccessControlUpgradeable, UUPSUpgradeable, IImpairmentSource {
    struct AssessmentStorage {
        IRevisionedImpairmentSource baseSource;
        uint256 assessedSeniorImpairment;
        uint64 validUntil;
        bytes32 evidenceHash;
        bytes32 assessedStateHash;
        bytes32 assessedRiskStateHash;
        uint256 assessedBackstopCapacity;
        uint256 assessedPerformanceFeeImpairment;
        bool performanceFeeImpairmentSnapshotted;
    }

    bytes32 private constant ASSESSMENT_STORAGE_LOCATION =
        0x22d1327051d3790a2a295641453e9e7c93d6a209be7b99c1b2a8eee179860200;
    bytes32 private constant LEGACY_ASSESSMENT_STORAGE_LOCATION =
        0x07e2328902311370f02c9c7e3d28358251569e375a804933066de765ee700700;

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
    event AssessmentPerformanceFeeImpairmentSet(uint256 performanceFeeImpairment);

    error Assessment_ZeroAddress();
    error Assessment_ZeroEvidenceHash();
    error Assessment_NotFuture(uint64 validUntil);
    error Assessment_TooLong(uint64 validUntil, uint64 maxValidUntil);
    error Assessment_ExceedsConservativeBase(uint256 assessed, uint256 conservativeBase);
    error Assessment_InvalidPerformanceFeeImpairment(uint256 performanceFeeImpairment, uint256 conservativeBase);
    error Assessment_BaseNotRevisioned(address source);

    constructor() {
        _disableInitializers();
    }

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

    function clearAssessment() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _clearAssessment(_storage());
    }

    function setBaseSource(address newSource) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSource == address(0)) revert Assessment_ZeroAddress();
        _requireRevisionedSource(newSource);
        AssessmentStorage storage $ = _storage();
        address oldSource = address($.baseSource);
        $.baseSource = IRevisionedImpairmentSource(newSource);
        _clearAssessment($);
        emit BaseSourceSet(oldSource, newSource);
    }

    function pendingSeniorImpairment() external view returns (uint256) {
        AssessmentStorage storage $ = _storage();
        uint256 conservativeBase = $.baseSource.pendingSeniorImpairment();
        if ($.validUntil == 0 || block.timestamp > $.validUntil) return conservativeBase;
        if (!_assessmentStateMatches($)) return conservativeBase;
        uint256 assessed = $.assessedSeniorImpairment;
        return assessed < conservativeBase ? assessed : conservativeBase;
    }

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

    function baseSource() external view returns (address) {
        return address(_storage().baseSource);
    }

    function _authorizeUpgrade(address) internal view override onlyRole(Roles.UPGRADER_ROLE) {
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
        if ($.assessedRiskStateHash == bytes32(0)) return false;
        if ($.assessedRiskStateHash != $.baseSource.impairmentRiskStateHash()) return false;
        return $.baseSource.impairmentBackstopCapacity() >= $.assessedBackstopCapacity;
    }

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
            if and(iszero(sload(slot)), iszero(iszero(sload(legacySlot)))) { slot := legacySlot }
            $.slot := slot
        }
    }
}
