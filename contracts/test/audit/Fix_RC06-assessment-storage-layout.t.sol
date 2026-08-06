// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AssessedImpairmentSource} from "../../src/AssessedImpairmentSource.sol";
import {IImpairmentSource} from "../../src/interfaces/IImpairmentSource.sol";
import {IRevisionedImpairmentSource} from "../../src/interfaces/IRevisionedImpairmentSource.sol";

contract LayoutProbeSource is IRevisionedImpairmentSource {
    uint256 public capacity;
    uint256 internal revision = 1;

    function setCapacity(uint256 c) external {
        capacity = c;
    }

    function pendingSeniorImpairment() external pure returns (uint256) {
        return 1_500e18;
    }

    function performanceFeeImpairment() external pure returns (uint256) {
        return 5_500e18;
    }

    function impairmentRevision() external view returns (uint256) {
        return revision;
    }

    function impairmentStateHash() external view returns (bytes32) {
        return keccak256(abi.encode("state", revision, capacity));
    }

    function impairmentRiskStateHash() external view returns (bytes32) {
        return keccak256(abi.encode("risk", revision));
    }

    function impairmentBackstopCapacity() external view returns (uint256) {
        return capacity;
    }
}

/// @dev AUDIT FIX (RC-06 / re-check structural item 1). The FRV-FS-04 remediation grew
///      `AssessmentStorage` from five fields to seven. ADR-0031 later appended the
///      performance-fee impairment snapshot and its presence bit. Nothing in the repository or CI
///      checks storage layout. This contract is UUPS-upgradeable over a live proxy, so a
///      future edit that INSERTS or REORDERS a field — rather than appending — silently
///      reinterprets every later field on the deployed proxy. That is the state-corrupting
///      upgrade class, the only failure mode in this batch the rubric rates High, and it was
///      guarded by eyesight alone.
///
///      ERC-7201 namespaced storage is invisible to `forge inspect storage-layout` (the
///      contract declares no top-level state), so the meaningful check is this: pin every
///      field to its exact offset from the namespace base by reading the slots directly.
///      Inserting a field mid-struct moves everything after it and fails these assertions.
contract FixRC06AssessmentStorageLayoutTest is Test {
    // keccak256(abi.encode(uint256(keccak256("forestroad.storage.AssessedImpairmentSource")) - 1))
    // & ~bytes32(uint256(0xff)) — mirrored from the contract; a change here must be deliberate.
    bytes32 internal constant BASE = 0x22d1327051d3790a2a295641453e9e7c93d6a209be7b99c1b2a8eee179860200;

    address internal admin = makeAddr("admin");
    LayoutProbeSource internal base;
    AssessedImpairmentSource internal source;

    function setUp() public {
        base = new LayoutProbeSource();
        base.setCapacity(4_000e18);
        source = AssessedImpairmentSource(
            address(
                new ERC1967Proxy(
                    address(new AssessedImpairmentSource()),
                    abi.encodeCall(AssessedImpairmentSource.initialize, (admin, admin, address(base)))
                )
            )
        );
    }

    function _slot(uint256 offset) private view returns (bytes32) {
        return vm.load(address(source), bytes32(uint256(BASE) + offset));
    }

    /// @dev Pins all nine fields, in order, at their exact offsets from the namespace base.
    function test_RC06_assessmentStorageFieldsAreAtTheirPinnedOffsets() public {
        uint64 validUntil = uint64(block.timestamp + 10 days);
        bytes32 evidence = keccak256("memorandum");

        vm.prank(admin);
        source.setAssessment(900e18, validUntil, evidence);

        // +0 baseSource (address)
        assertEq(address(uint160(uint256(_slot(0)))), address(base), "slot 0: baseSource moved");
        // +1 assessedSeniorImpairment (uint256)
        assertEq(uint256(_slot(1)), 900e18, "slot 1: assessedSeniorImpairment moved");
        // +2 validUntil (uint64, alone in its slot — next field is bytes32)
        assertEq(uint256(_slot(2)), uint256(validUntil), "slot 2: validUntil moved");
        // +3 evidenceHash (bytes32)
        assertEq(_slot(3), evidence, "slot 3: evidenceHash moved");
        // +4 assessedStateHash (bytes32)
        assertEq(_slot(4), base.impairmentStateHash(), "slot 4: assessedStateHash moved");
        // +5 assessedRiskStateHash (bytes32) — APPENDED by the FRV-FS-04 fix
        assertEq(_slot(5), base.impairmentRiskStateHash(), "slot 5: assessedRiskStateHash moved");
        // +6 assessedBackstopCapacity (uint256) — APPENDED by the FRV-FS-04 fix
        assertEq(uint256(_slot(6)), 4_000e18, "slot 6: assessedBackstopCapacity moved");
        // +7 assessedPerformanceFeeImpairment = assessed 900 + junior credit (5,500 - 1,500)
        assertEq(uint256(_slot(7)), 4_900e18, "slot 7: assessedPerformanceFeeImpairment moved");
        // +8 performanceFeeImpairmentSnapshotted (bool) — APPENDED by ADR-0031
        assertEq(uint256(_slot(8)), 1, "slot 8: performanceFeeImpairmentSnapshotted moved");

        // Nothing may be written past the declared tail: a tenth field would land here and
        // would be invisible to the offsets above.
        assertEq(uint256(_slot(9)), 0, "slot 9: struct grew without updating this layout pin");
    }

    /// @dev Every remediation field must be APPENDED, never inserted. If a future change
    ///      moves them, the pre-existing five keep their offsets — this asserts those
    ///      original fields independently of the append-only tail.
    function test_RC06_preExistingFieldsKeepTheirOffsetsAfterTheAppend() public {
        vm.prank(admin);
        source.setAssessment(123e18, uint64(block.timestamp + 1 days), keccak256("e"));

        assertEq(address(uint160(uint256(_slot(0)))), address(base), "baseSource must stay at +0");
        assertEq(uint256(_slot(1)), 123e18, "assessedSeniorImpairment must stay at +1");
        assertEq(uint256(_slot(2)), uint256(block.timestamp + 1 days), "validUntil must stay at +2");
        assertEq(_slot(3), keccak256("e"), "evidenceHash must stay at +3");

        // Clearing must zero the whole struct, including the appended tail — a partial clear
        // would leave a stale directional snapshot that could revive a dead assessment.
        vm.prank(admin);
        source.clearAssessment();
        for (uint256 i = 1; i <= 8; ++i) {
            assertEq(uint256(_slot(i)), 0, "clearAssessment left a field set");
        }
        assertEq(address(uint160(uint256(_slot(0)))), address(base), "clear must not touch baseSource");
    }
}
