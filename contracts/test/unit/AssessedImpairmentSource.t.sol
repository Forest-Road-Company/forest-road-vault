// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AssessedImpairmentSource} from "../../src/AssessedImpairmentSource.sol";
import {IImpairmentSource} from "../../src/interfaces/IImpairmentSource.sol";
import {IRevisionedImpairmentSource} from "../../src/interfaces/IRevisionedImpairmentSource.sol";
import {Roles} from "../../src/libraries/Roles.sol";

contract MutableImpairmentSource is IRevisionedImpairmentSource {
    uint256 internal impairment;
    uint256 internal feeImpairment;
    uint256 internal revision;
    uint256 internal backstopCapacity;

    function set(uint256 impairment_) external {
        impairment = impairment_;
        feeImpairment = impairment_;
        revision += 1;
    }

    function setFeeImpairment(uint256 feeImpairment_) external {
        feeImpairment = feeImpairment_;
    }

    function touch() external {
        revision += 1;
    }

    function setBackstop(uint256 capacity_, uint256 impairment_) external {
        backstopCapacity = capacity_;
        impairment = impairment_;
    }

    function pendingSeniorImpairment() external view returns (uint256) {
        return impairment;
    }

    function performanceFeeImpairment() external view returns (uint256) {
        return feeImpairment;
    }

    function impairmentRevision() external view returns (uint256) {
        return revision;
    }

    function impairmentStateHash() external view returns (bytes32) {
        return keccak256(abi.encode(_riskHash(), backstopCapacity));
    }

    function impairmentRiskStateHash() external view returns (bytes32) {
        return _riskHash();
    }

    function impairmentBackstopCapacity() external view returns (uint256) {
        return backstopCapacity;
    }

    function _riskHash() private view returns (bytes32) {
        return keccak256(abi.encode(address(this), revision));
    }
}

contract NonRevisionedImpairmentSource is IImpairmentSource {
    function pendingSeniorImpairment() external pure returns (uint256) {
        return 1_500e18;
    }

    function performanceFeeImpairment() external pure returns (uint256) {
        return 1_500e18;
    }
}

contract IncompleteRevisionedSource {
    function impairmentRevision() external pure returns (uint256) {
        return 1;
    }

    function impairmentStateHash() external pure returns (bytes32) {
        return keccak256("incomplete");
    }
}

contract AssessedImpairmentSourceTest is Test {
    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    MutableImpairmentSource internal base;
    AssessedImpairmentSource internal source;

    function setUp() public {
        base = new MutableImpairmentSource();
        base.set(1_500e18);
        source = AssessedImpairmentSource(
            address(
                new ERC1967Proxy(
                    address(new AssessedImpairmentSource()),
                    abi.encodeCall(AssessedImpairmentSource.initialize, (admin, admin, address(base)))
                )
            )
        );
    }

    function test_initialize_wiresBaseAndRejectsZeroAddresses() public {
        assertEq(source.baseSource(), address(base));
        assertEq(source.pendingSeniorImpairment(), 1_500e18);

        AssessedImpairmentSource impl = new AssessedImpairmentSource();
        vm.expectRevert(AssessedImpairmentSource.Assessment_ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(AssessedImpairmentSource.initialize, (address(0), admin, address(base)))
        );
        vm.expectRevert(AssessedImpairmentSource.Assessment_ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(AssessedImpairmentSource.initialize, (admin, admin, address(0))));
    }

    function test_rejectsBaseWhosePerformanceImpairmentIsBelowRedemptionImpairment() public {
        MutableImpairmentSource invalidBase = new MutableImpairmentSource();
        invalidBase.set(777e18);
        invalidBase.setFeeImpairment(776e18);

        AssessedImpairmentSource impl = new AssessedImpairmentSource();
        vm.expectRevert(
            abi.encodeWithSelector(
                AssessedImpairmentSource.Assessment_InvalidPerformanceFeeImpairment.selector, 776e18, 777e18
            )
        );
        new ERC1967Proxy(
            address(impl), abi.encodeCall(AssessedImpairmentSource.initialize, (admin, admin, address(invalidBase)))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                AssessedImpairmentSource.Assessment_InvalidPerformanceFeeImpairment.selector, 776e18, 777e18
            )
        );
        vm.prank(admin);
        source.setBaseSource(address(invalidBase));
        assertEq(source.baseSource(), address(base));
    }

    function test_storageNamespace_matchesERC7201Annotation() public view {
        bytes32 namespaceSlot = 0x22d1327051d3790a2a295641453e9e7c93d6a209be7b99c1b2a8eee179860200;
        assertEq(
            vm.load(address(source), namespaceSlot),
            bytes32(uint256(uint160(address(base)))),
            "base source not stored at annotated ERC-7201 namespace"
        );
    }

    function test_storageNamespace_preservesLegacyProxyState() public {
        AssessedImpairmentSource legacyProxy =
            AssessedImpairmentSource(address(new ERC1967Proxy(address(new AssessedImpairmentSource()), "")));
        bytes32 legacySlot = 0x07e2328902311370f02c9c7e3d28358251569e375a804933066de765ee700700;
        vm.store(address(legacyProxy), legacySlot, bytes32(uint256(uint160(address(base)))));

        assertEq(legacyProxy.baseSource(), address(base));
    }

    function test_setAssessment_controlsPriceUntilExpiryThenFailsSafe() public {
        uint64 validUntil = uint64(block.timestamp + 7 days);
        bytes32 evidence = keccak256("signed-recovery-memo");
        bytes32 stateHash = base.impairmentStateHash();

        vm.expectEmit(true, true, false, true);
        emit AssessedImpairmentSource.AssessmentSet(500e18, 1_500e18, validUntil, evidence, stateHash);
        vm.prank(admin);
        source.setAssessment(500e18, validUntil, evidence);

        assertEq(source.pendingSeniorImpairment(), 500e18, "assessment lowers the zero-recovery mark");
        (uint256 assessed, uint64 expiry, bytes32 ref, bool active, uint256 conservative) = source.currentAssessment();
        assertEq(assessed, 500e18);
        assertEq(expiry, validUntil);
        assertEq(ref, evidence);
        assertTrue(active);
        assertEq(conservative, 1_500e18);

        vm.warp(validUntil);
        assertEq(source.pendingSeniorImpairment(), 500e18, "assessment is valid through its deadline");
        vm.warp(uint256(validUntil) + 1);
        assertEq(source.pendingSeniorImpairment(), 1_500e18, "expiry automatically restores zero recovery");
        (,,, active,) = source.currentAssessment();
        assertFalse(active);
    }

    function test_setAssessment_zeroSeniorLossIsAllowedWhenJuniorsCoverExpectedLoss() public {
        vm.prank(admin);
        source.setAssessment(0, uint64(block.timestamp + 1 days), keccak256("full-junior-cover"));
        assertEq(source.pendingSeniorImpairment(), 0);
    }

    function test_setAssessment_boundsAndEvidence() public {
        uint64 validUntil = uint64(block.timestamp + 1 days);
        vm.expectRevert(AssessedImpairmentSource.Assessment_ZeroEvidenceHash.selector);
        vm.prank(admin);
        source.setAssessment(1e18, validUntil, bytes32(0));

        vm.expectRevert(
            abi.encodeWithSelector(AssessedImpairmentSource.Assessment_NotFuture.selector, uint64(block.timestamp))
        );
        vm.prank(admin);
        source.setAssessment(1e18, uint64(block.timestamp), keccak256("memo"));

        uint64 tooLong = uint64(block.timestamp) + source.MAX_ASSESSMENT_TTL() + 1;
        uint64 maxValidUntil = uint64(block.timestamp) + source.MAX_ASSESSMENT_TTL();
        vm.expectRevert(
            abi.encodeWithSelector(AssessedImpairmentSource.Assessment_TooLong.selector, tooLong, maxValidUntil)
        );
        vm.prank(admin);
        source.setAssessment(1e18, tooLong, keccak256("memo"));

        vm.expectRevert(
            abi.encodeWithSelector(
                AssessedImpairmentSource.Assessment_ExceedsConservativeBase.selector, 1_501e18, 1_500e18
            )
        );
        vm.prank(admin);
        source.setAssessment(1_501e18, validUntil, keccak256("memo"));
    }

    function test_anyBaseRiskChangeInvalidatesAssessmentAndFailsConservatively() public {
        vm.prank(admin);
        source.setAssessment(500e18, uint64(block.timestamp + 1 days), keccak256("memo"));
        base.set(200e18);
        assertEq(source.pendingSeniorImpairment(), 200e18, "a recovery invalidates the old assessment");
        base.set(900e18);
        assertEq(source.pendingSeniorImpairment(), 900e18, "new risk cannot be suppressed by the old assessment");
        (,,, bool active,) = source.currentAssessment();
        assertFalse(active);
    }

    function test_sameAmountNewRevisionCannotReactivateOldAssessment() public {
        vm.prank(admin);
        source.setAssessment(500e18, uint64(block.timestamp + 1 days), keccak256("memo"));
        bytes32 originalHash = base.impairmentStateHash();

        base.touch();

        assertEq(base.pendingSeniorImpairment(), 1_500e18, "amount deliberately did not change");
        assertNotEq(base.impairmentStateHash(), originalHash, "revision distinguishes the new risk snapshot");
        assertEq(source.pendingSeniorImpairment(), 1_500e18, "old discount fails closed");
        (,,, bool active,) = source.currentAssessment();
        assertFalse(active);

        vm.prank(admin);
        source.setAssessment(400e18, uint64(block.timestamp + 1 days), keccak256("fresh-memo"));
        assertEq(source.pendingSeniorImpairment(), 400e18, "fresh evidence can assess the new snapshot");
    }

    function test_backstopIncreaseKeepsAssessmentButDecreaseBelowSnapshotInvalidates() public {
        base.setBackstop(100e18, 1_400e18);
        vm.prank(admin);
        source.setAssessment(500e18, uint64(block.timestamp + 1 days), keccak256("memo"));
        bytes32 exactBefore = base.impairmentStateHash();

        // Extra global junior protection cannot make the professional estimate less
        // conservative, so it remains live and is still capped by the base.
        base.setBackstop(200e18, 1_300e18);
        assertNotEq(base.impairmentStateHash(), exactBefore, "exact operational state changed");
        assertEq(source.pendingSeniorImpairment(), 500e18, "beneficial top-up preserves the assessment");
        (,,, bool active,) = source.currentAssessment();
        assertTrue(active);
        (bytes32 assessedHash, bytes32 currentHash, bool compatible) = source.assessmentState();
        assertNotEq(assessedHash, currentHash, "exact hashes expose the capacity top-up");
        assertTrue(compatible, "directional binding classifies the top-up as safe");

        // Capacity may later fall from the higher watermark and remain safe while it is
        // still at least the assessed snapshot.
        base.setBackstop(100e18, 1_400e18);
        assertEq(source.pendingSeniorImpairment(), 500e18, "snapshot capacity still protects the memo");

        // Below the snapshot, the old recovery work no longer has the junior protection
        // it was published against and must fail closed.
        base.setBackstop(99e18, 1_401e18);
        assertEq(source.pendingSeniorImpairment(), 1_401e18);
        (,,, active,) = source.currentAssessment();
        assertFalse(active);
    }

    function test_performanceFeeImpairmentSnapshotsJuniorCreditAcrossBeneficialTopups() public {
        // Gross risk stays 1,500 while 100 of backstop capacity lowers the senior
        // zero-recovery mark to 1,400.
        base.setBackstop(100e18, 1_400e18);
        uint64 validUntil = uint64(block.timestamp + 1 days);
        vm.expectEmit(false, false, false, true);
        emit AssessedImpairmentSource.AssessmentPerformanceFeeImpairmentSet(600e18);
        vm.prank(admin);
        source.setAssessment(500e18, validUntil, keccak256("fee-credit-memo"));

        assertEq(source.pendingSeniorImpairment(), 500e18);
        assertEq(
            source.performanceFeeImpairment(),
            600e18,
            "assessment plus publication-time junior credit is the fee impairment"
        );

        // A permitted top-up lowers redemption impairment but cannot move fee accounting.
        base.setBackstop(200e18, 1_300e18);
        assertEq(source.pendingSeniorImpairment(), 500e18);
        assertEq(source.performanceFeeImpairment(), 600e18, "beneficial top-up cannot create fee NAV");

        // Falling below the bound invalidates the assessment and restores gross fee risk.
        base.setBackstop(99e18, 1_401e18);
        assertEq(source.pendingSeniorImpairment(), 1_401e18);
        assertEq(source.performanceFeeImpairment(), 1_500e18);
    }

    function test_setAssessmentRejectsBaseWhoseFeeImpairmentIsBelowRedemptionImpairment() public {
        base.setFeeImpairment(1_499e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssessedImpairmentSource.Assessment_InvalidPerformanceFeeImpairment.selector, 1_499e18, 1_500e18
            )
        );
        vm.prank(admin);
        source.setAssessment(500e18, uint64(block.timestamp + 1 days), keccak256("invalid-fee-base"));
    }

    function test_preSnapshotUpgradeAssessmentFailsConservativelyForPerformanceFees() public {
        vm.prank(admin);
        source.setAssessment(500e18, uint64(block.timestamp + 1 days), keccak256("legacy-live-assessment"));
        assertEq(source.performanceFeeImpairment(), 500e18);

        // Slot +8 is the appended snapshot-presence bit. Clearing it models a live
        // assessment created by an implementation that predates the fee field.
        bytes32 namespaceSlot = 0x22d1327051d3790a2a295641453e9e7c93d6a209be7b99c1b2a8eee179860200;
        vm.store(address(source), bytes32(uint256(namespaceSlot) + 8), bytes32(0));
        assertEq(source.pendingSeniorImpairment(), 500e18, "redemption assessment remains live");
        assertEq(source.performanceFeeImpairment(), 1_500e18, "missing fee snapshot fails to gross risk");
    }

    function test_assessmentStateExposesSnapshotMismatch() public {
        vm.prank(admin);
        source.setAssessment(500e18, uint64(block.timestamp + 1 days), keccak256("memo"));
        (bytes32 assessedHash, bytes32 currentHash, bool matches) = source.assessmentState();
        assertEq(assessedHash, currentHash);
        assertTrue(matches);

        base.touch();
        (assessedHash, currentHash, matches) = source.assessmentState();
        assertNotEq(assessedHash, currentHash);
        assertFalse(matches);
    }

    function test_clearAssessment_restoresConservativeBase() public {
        vm.prank(admin);
        source.setAssessment(500e18, uint64(block.timestamp + 1 days), keccak256("memo"));
        vm.expectEmit(false, false, false, true);
        emit AssessedImpairmentSource.AssessmentCleared();
        vm.prank(admin);
        source.clearAssessment();
        assertEq(source.pendingSeniorImpairment(), 1_500e18);
        (uint256 assessed, uint64 expiry, bytes32 ref, bool active,) = source.currentAssessment();
        assertEq(assessed, 0);
        assertEq(expiry, 0);
        assertEq(ref, bytes32(0));
        assertFalse(active);
        assertEq(source.performanceFeeImpairment(), 1_500e18);
    }

    function test_adminOnlyAssessmentAndBaseChange() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        vm.prank(alice);
        source.setAssessment(500e18, uint64(block.timestamp + 1 days), keccak256("memo"));

        MutableImpairmentSource replacement = new MutableImpairmentSource();
        replacement.set(777e18);
        vm.expectEmit(false, false, false, true);
        emit AssessedImpairmentSource.AssessmentCleared();
        vm.expectEmit(true, true, false, true);
        emit AssessedImpairmentSource.BaseSourceSet(address(base), address(replacement));
        vm.prank(admin);
        source.setBaseSource(address(replacement));
        assertEq(source.baseSource(), address(replacement));
        assertEq(source.pendingSeniorImpairment(), 777e18);

        vm.expectRevert(AssessedImpairmentSource.Assessment_ZeroAddress.selector);
        vm.prank(admin);
        source.setBaseSource(address(0));
    }

    function test_setBaseSourceClearsAssessment() public {
        vm.prank(admin);
        source.setAssessment(500e18, uint64(block.timestamp + 1 days), keccak256("memo"));

        MutableImpairmentSource replacement = new MutableImpairmentSource();
        replacement.set(777e18);
        vm.prank(admin);
        source.setBaseSource(address(replacement));

        assertEq(source.pendingSeniorImpairment(), 777e18);
        (uint256 assessed, uint64 expiry, bytes32 evidence, bool active,) = source.currentAssessment();
        assertEq(assessed, 0);
        assertEq(expiry, 0);
        assertEq(evidence, bytes32(0));
        assertFalse(active);
    }

    function test_rejectsNonRevisionedBaseOnInitializeAndReplacement() public {
        NonRevisionedImpairmentSource oldInterface = new NonRevisionedImpairmentSource();
        AssessedImpairmentSource impl = new AssessedImpairmentSource();
        vm.expectRevert(
            abi.encodeWithSelector(
                AssessedImpairmentSource.Assessment_BaseNotRevisioned.selector, address(oldInterface)
            )
        );
        new ERC1967Proxy(
            address(impl), abi.encodeCall(AssessedImpairmentSource.initialize, (admin, admin, address(oldInterface)))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                AssessedImpairmentSource.Assessment_BaseNotRevisioned.selector, address(oldInterface)
            )
        );
        vm.prank(admin);
        source.setBaseSource(address(oldInterface));
    }

    function test_rejectsRevisionMetadataWithoutTheImpairmentView() public {
        IncompleteRevisionedSource incomplete = new IncompleteRevisionedSource();
        vm.expectRevert(
            abi.encodeWithSelector(AssessedImpairmentSource.Assessment_BaseNotRevisioned.selector, address(incomplete))
        );
        vm.prank(admin);
        source.setBaseSource(address(incomplete));
    }

    function test_upgradeOnlyUpgrader() public {
        address newImpl = address(new AssessedImpairmentSource());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.UPGRADER_ROLE)
        );
        vm.prank(alice);
        source.upgradeToAndCall(newImpl, "");
        vm.prank(admin);
        source.upgradeToAndCall(newImpl, "");
    }

    function test_upgradeRequiresTheInstalledRevisionedBaseToBeReadyFirst() public {
        vm.etch(address(base), hex"");

        address newImplementation = address(new AssessedImpairmentSource());
        vm.expectRevert(
            abi.encodeWithSelector(AssessedImpairmentSource.Assessment_BaseNotRevisioned.selector, address(base))
        );
        vm.prank(admin);
        source.upgradeToAndCall(newImplementation, "");
    }
}
