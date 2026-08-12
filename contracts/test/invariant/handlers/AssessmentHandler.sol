// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {AssessedImpairmentSource} from "../../../src/AssessedImpairmentSource.sol";
import {DefaultManager} from "../../../src/DefaultManager.sol";

/// @dev Stateful driver for the production recovery-assessment wrapper. Expected values are
///      reconstructed from snapshots owned by this handler; the wrapper's assessment storage is
///      never used as the reference model. Expected reverts are low-level calls so the repository's
///      fail_on_revert invariant policy does not suppress negative-path coverage.
contract AssessmentHandler is Test {
    AssessedImpairmentSource internal source;
    DefaultManager internal base;
    address internal admin;
    address internal outsider = makeAddr("assessment-outsider");

    uint256 public modelAssessed;
    uint256 public modelPerformanceFeeImpairment;
    uint64 public modelValidUntil;
    bytes32 public modelStateHash;
    bytes32 public modelRiskStateHash;
    uint256 public modelBackstopCapacity;
    bool public modelPresent;

    uint256 public publishCount;
    uint256 public expiryCount;
    uint256 public clearCount;
    uint256 public negativeProbeCount;
    uint256 public correctRejectionCount;
    uint256 public unexpectedAcceptanceCount;
    uint256 public wrongSelectorCount;
    uint256 public callCount;

    constructor(AssessedImpairmentSource source_, DefaultManager base_, address admin_) {
        source = source_;
        base = base_;
        admin = admin_;
    }

    function publish(uint256 amountSeed, uint256 ttlSeed) public {
        uint256 conservative = base.pendingSeniorImpairment();
        if (conservative == 0) return;
        uint256 assessed = bound(amountSeed, 0, conservative);
        uint64 ttl = uint64(bound(ttlSeed, 1, source.MAX_ASSESSMENT_TTL()));
        uint64 validUntil = uint64(block.timestamp) + ttl;
        bytes32 evidence = keccak256(abi.encode("invariant-assessment", callCount, assessed, validUntil));

        vm.prank(admin);
        source.setAssessment(assessed, validUntil, evidence);

        modelAssessed = assessed;
        modelPerformanceFeeImpairment = assessed + (base.performanceFeeImpairment() - conservative);
        modelValidUntil = validUntil;
        modelStateHash = base.impairmentStateHash();
        modelRiskStateHash = base.impairmentRiskStateHash();
        modelBackstopCapacity = base.impairmentBackstopCapacity();
        modelPresent = true;
        publishCount++;
        callCount++;
    }

    function clear() public {
        if (!modelPresent) return;
        vm.prank(admin);
        source.clearAssessment();
        _clearModel();
        clearCount++;
        callCount++;
    }

    function warp(uint256 dtSeed) public {
        bool wasLive = expectedActive();
        vm.warp(block.timestamp + bound(dtSeed, 1 hours, 45 days));
        if (wasLive && !expectedActive()) expiryCount++;
        callCount++;
    }

    /// @notice Exercises four distinct custom-error branches and the AccessControl rejection.
    function probeInvalid(uint256 modeSeed) public {
        uint256 mode = modeSeed % 5;
        uint256 conservative = base.pendingSeniorImpairment();
        uint256 amount = conservative == type(uint256).max ? conservative : conservative + 1;
        uint64 validUntil = uint64(block.timestamp + 1 days);
        bytes32 evidence = keccak256("assessment-negative-probe");
        address caller = admin;
        bytes4 expected;

        if (mode == 0) {
            evidence = bytes32(0);
            amount = 0;
            expected = AssessedImpairmentSource.Assessment_ZeroEvidenceHash.selector;
        } else if (mode == 1) {
            validUntil = uint64(block.timestamp);
            amount = 0;
            expected = AssessedImpairmentSource.Assessment_NotFuture.selector;
        } else if (mode == 2) {
            validUntil = uint64(block.timestamp) + source.MAX_ASSESSMENT_TTL() + 1;
            amount = 0;
            expected = AssessedImpairmentSource.Assessment_TooLong.selector;
        } else if (mode == 3) {
            expected = AssessedImpairmentSource.Assessment_ExceedsConservativeBase.selector;
        } else {
            caller = outsider;
            amount = 0;
            expected = IAccessControl.AccessControlUnauthorizedAccount.selector;
        }

        vm.prank(caller);
        (bool ok, bytes memory ret) =
            address(source).call(abi.encodeCall(AssessedImpairmentSource.setAssessment, (amount, validUntil, evidence)));
        negativeProbeCount++;
        if (ok) {
            unexpectedAcceptanceCount++;
        } else if (ret.length < 4 || bytes4(ret) != expected) {
            wrongSelectorCount++;
        } else {
            correctRejectionCount++;
        }
        callCount++;
    }

    function seedShapes() external {
        publish(1, 7 days);
        for (uint256 i = 0; i < 5; ++i) {
            probeInvalid(i);
        }
        warp(source.MAX_ASSESSMENT_TTL() + 1);
        publish(base.pendingSeniorImpairment() / 2, 7 days);
        clear();
        publish(base.pendingSeniorImpairment() / 3, 7 days);
    }

    function expectedActive() public view returns (bool) {
        if (!modelPresent || block.timestamp > modelValidUntil) return false;
        if (base.impairmentStateHash() == modelStateHash) return true;
        return modelRiskStateHash != bytes32(0) && base.impairmentRiskStateHash() == modelRiskStateHash
            && base.impairmentBackstopCapacity() >= modelBackstopCapacity;
    }

    function expectedPendingSeniorImpairment() external view returns (uint256) {
        uint256 conservative = base.pendingSeniorImpairment();
        if (!expectedActive()) return conservative;
        return modelAssessed < conservative ? modelAssessed : conservative;
    }

    function expectedPerformanceFeeImpairment() external view returns (uint256) {
        return expectedActive() ? modelPerformanceFeeImpairment : base.performanceFeeImpairment();
    }

    function _clearModel() private {
        modelAssessed = 0;
        modelPerformanceFeeImpairment = 0;
        modelValidUntil = 0;
        modelStateHash = bytes32(0);
        modelRiskStateHash = bytes32(0);
        modelBackstopCapacity = 0;
        modelPresent = false;
    }
}
