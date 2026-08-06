// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {RecoveryTopUpDistributor} from "../../src/RecoveryTopUpDistributor.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

contract FeeOnTransferTopUpToken is MockERC20 {
    constructor() MockERC20("Fee USDfr", "fUSDfr", 18) {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, to, value - fee);
            super._update(from, address(0), fee);
        } else {
            super._update(from, to, value);
        }
    }
}

contract RecoveryTopUpDistributorTest is Test {
    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal relayer = makeAddr("relayer");
    address internal treasury = makeAddr("treasury");

    MockERC20 internal usdfr;
    RecoveryTopUpDistributor internal distributor;

    function setUp() public {
        usdfr = new MockERC20("USDfr", "USDfr", 18);
        distributor = RecoveryTopUpDistributor(
            address(
                new ERC1967Proxy(
                    address(new RecoveryTopUpDistributor()),
                    abi.encodeCall(RecoveryTopUpDistributor.initialize, (admin, guardian, admin, address(usdfr)))
                )
            )
        );
        usdfr.mint(admin, 10_000e18);
        vm.prank(admin);
        usdfr.approve(address(distributor), type(uint256).max);
    }

    function test_storageNamespace_matchesERC7201Annotation() public view {
        bytes32 namespaceSlot = 0x766d1e5b4c4a9feee10f19eeda7837bd901ae43d964c73e846c8ecdd9a853a00;
        assertEq(
            vm.load(address(distributor), namespaceSlot),
            bytes32(uint256(uint160(address(usdfr)))),
            "USDfr not stored at annotated ERC-7201 namespace"
        );
    }

    function test_storageNamespace_preservesLegacyProxyState() public {
        RecoveryTopUpDistributor legacyProxy =
            RecoveryTopUpDistributor(address(new ERC1967Proxy(address(new RecoveryTopUpDistributor()), "")));
        bytes32 legacySlot = 0xb13c75e809bf77814f78f010c4d738958cc961b17d28848da2d34c825238be00;
        vm.store(address(legacyProxy), legacySlot, bytes32(uint256(uint160(address(usdfr)))));

        assertEq(legacyProxy.usdfr(), address(usdfr));
    }

    function _twoLeafRound()
        internal
        returns (
            uint256 roundId,
            bytes32 aliceLeaf,
            bytes32 bobLeaf,
            uint256 aliceRequest,
            uint256 bobRequest,
            uint256 aliceAmount,
            uint256 bobAmount
        )
    {
        roundId = distributor.nextRoundId();
        aliceRequest = 11;
        bobRequest = 22;
        aliceAmount = 100e18;
        bobAmount = 250e18;
        aliceLeaf = distributor.leafHash(roundId, 0, aliceRequest, alice, aliceAmount);
        bobLeaf = distributor.leafHash(roundId, 1, bobRequest, bob, bobAmount);
        bytes32 root = _hashPair(aliceLeaf, bobLeaf);
        vm.prank(admin);
        distributor.createRound(
            root, aliceAmount + bobAmount, uint64(block.timestamp + 30 days), treasury, keccak256("workout-ledger")
        );
    }

    function test_initialize_wiringAndZeroAddresses() public {
        assertEq(distributor.usdfr(), address(usdfr));
        assertEq(distributor.nextRoundId(), 0);

        RecoveryTopUpDistributor impl = new RecoveryTopUpDistributor();
        vm.expectRevert(RecoveryTopUpDistributor.TopUp_ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(RecoveryTopUpDistributor.initialize, (address(0), guardian, admin, address(usdfr)))
        );
        vm.expectRevert(RecoveryTopUpDistributor.TopUp_ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(RecoveryTopUpDistributor.initialize, (admin, guardian, admin, address(0)))
        );
    }

    function test_createRound_fundsUpFrontAndEmits() public {
        bytes32 root = keccak256("root");
        bytes32 evidence = keccak256("workout-ledger");
        uint64 deadline = uint64(block.timestamp + 30 days);

        vm.expectEmit(true, true, true, true);
        emit RecoveryTopUpDistributor.RoundCreated(0, root, 350e18, deadline, treasury, evidence);
        vm.prank(admin);
        uint256 id = distributor.createRound(root, 350e18, deadline, treasury, evidence);
        assertEq(id, 0);
        assertEq(distributor.nextRoundId(), 1);
        assertEq(usdfr.balanceOf(address(distributor)), 350e18);
        RecoveryTopUpDistributor.Round memory r = distributor.round(id);
        assertEq(r.merkleRoot, root);
        assertEq(r.evidenceHash, evidence);
        assertEq(r.refundRecipient, treasury);
        assertEq(r.claimDeadline, deadline);
        assertEq(r.funded, 350e18);
        assertEq(r.claimed, 0);
        assertFalse(r.reclaimed);
    }

    function test_createRound_rejectsFeeOnTransferFundingByExactBalanceDelta() public {
        FeeOnTransferTopUpToken feeToken = new FeeOnTransferTopUpToken();
        RecoveryTopUpDistributor feeDistributor = RecoveryTopUpDistributor(
            address(
                new ERC1967Proxy(
                    address(new RecoveryTopUpDistributor()),
                    abi.encodeCall(RecoveryTopUpDistributor.initialize, (admin, guardian, admin, address(feeToken)))
                )
            )
        );
        feeToken.mint(admin, 100e18);
        vm.startPrank(admin);
        feeToken.approve(address(feeDistributor), 100e18);
        vm.expectRevert(abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_FundingMismatch.selector, 100e18, 99e18));
        feeDistributor.createRound(
            keccak256("fee-root"), 100e18, uint64(block.timestamp + 1 days), treasury, keccak256("fee-evidence")
        );
        vm.stopPrank();
    }

    function test_createRound_validatesInputsAndAccess() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 root = keccak256("root");
        bytes32 evidence = keccak256("evidence");

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        vm.prank(alice);
        distributor.createRound(root, 1e18, deadline, treasury, evidence);

        vm.startPrank(admin);
        vm.expectRevert(RecoveryTopUpDistributor.TopUp_ZeroRoot.selector);
        distributor.createRound(bytes32(0), 1e18, deadline, treasury, evidence);
        vm.expectRevert(RecoveryTopUpDistributor.TopUp_ZeroAmount.selector);
        distributor.createRound(root, 0, deadline, treasury, evidence);
        vm.expectRevert(RecoveryTopUpDistributor.TopUp_ZeroAddress.selector);
        distributor.createRound(root, 1e18, deadline, address(0), evidence);
        vm.expectRevert(RecoveryTopUpDistributor.TopUp_ZeroEvidenceHash.selector);
        distributor.createRound(root, 1e18, deadline, treasury, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_BadDeadline.selector, uint64(block.timestamp))
        );
        distributor.createRound(root, 1e18, uint64(block.timestamp), treasury, evidence);
        vm.stopPrank();
    }

    function test_claim_allowsRelayerPaysLeafAccountAndBlocksReplay() public {
        (uint256 roundId, bytes32 aliceLeaf, bytes32 bobLeaf, uint256 aliceRequest,, uint256 aliceAmount,) =
            _twoLeafRound();
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = bobLeaf;

        vm.expectEmit(true, true, true, true);
        emit RecoveryTopUpDistributor.TopUpClaimed(roundId, 0, aliceRequest, alice, aliceAmount);
        vm.prank(relayer);
        distributor.claim(roundId, 0, aliceRequest, alice, aliceAmount, proof);
        assertEq(usdfr.balanceOf(alice), aliceAmount);
        assertEq(usdfr.balanceOf(relayer), 0, "relayer never receives the recovery");
        assertTrue(distributor.isClaimed(roundId, 0));
        assertFalse(distributor.isClaimed(roundId, 1));
        assertEq(distributor.round(roundId).claimed, aliceAmount);

        vm.expectRevert(abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_AlreadyClaimed.selector, roundId, 0));
        distributor.claim(roundId, 0, aliceRequest, alice, aliceAmount, proof);

        assertTrue(aliceLeaf != bytes32(0)); // retain both leaves in the explicit test model
    }

    function test_claim_rejectsWrongLeafUnknownExpiredAndBadValues() public {
        (uint256 roundId,, bytes32 bobLeaf, uint256 aliceRequest,, uint256 aliceAmount,) = _twoLeafRound();
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = bobLeaf;

        vm.expectRevert(RecoveryTopUpDistributor.TopUp_ZeroAddress.selector);
        distributor.claim(roundId, 0, aliceRequest, address(0), aliceAmount, proof);
        vm.expectRevert(RecoveryTopUpDistributor.TopUp_ZeroAmount.selector);
        distributor.claim(roundId, 0, aliceRequest, alice, 0, proof);
        vm.expectRevert(abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_UnknownRound.selector, uint256(999)));
        distributor.claim(999, 0, aliceRequest, alice, aliceAmount, proof);
        vm.expectRevert(abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_InvalidProof.selector, roundId, 0));
        distributor.claim(roundId, 0, aliceRequest + 1, alice, aliceAmount, proof);

        RecoveryTopUpDistributor.Round memory r = distributor.round(roundId);
        vm.warp(uint256(r.claimDeadline) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_Expired.selector, roundId, r.claimDeadline)
        );
        distributor.claim(roundId, 0, aliceRequest, alice, aliceAmount, proof);
    }

    function test_claim_rejectsRoundAfterItsFundingWasReclaimed() public {
        (uint256 roundId,, bytes32 bobLeaf, uint256 aliceRequest,, uint256 aliceAmount,) = _twoLeafRound();
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = bobLeaf;
        RecoveryTopUpDistributor.Round memory r = distributor.round(roundId);

        vm.warp(uint256(r.claimDeadline) + 1);
        vm.prank(admin);
        distributor.reclaimExpired(roundId);

        vm.expectRevert(abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_RoundReclaimed.selector, roundId));
        distributor.claim(roundId, 0, aliceRequest, alice, aliceAmount, proof);
    }

    function test_claim_rejectsValidAllocationAboveRoundFunding() public {
        uint256 roundId = distributor.nextRoundId();
        uint256 requestId = 44;
        uint256 funded = 100e18;
        uint256 allocation = funded + 1;
        bytes32 leaf = distributor.leafHash(roundId, 0, requestId, alice, allocation);

        vm.prank(admin);
        distributor.createRound(
            leaf, funded, uint64(block.timestamp + 30 days), treasury, keccak256("underfunded-ledger")
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                RecoveryTopUpDistributor.TopUp_AllocationExceedsFunding.selector, roundId, allocation, funded
            )
        );
        distributor.claim(roundId, 0, requestId, alice, allocation, new bytes32[](0));
    }

    function test_pauseBlocksClaimsAndGuardianOnly() public {
        (uint256 roundId,, bytes32 bobLeaf, uint256 aliceRequest,, uint256 aliceAmount,) = _twoLeafRound();
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = bobLeaf;

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.GUARDIAN_ROLE)
        );
        vm.prank(alice);
        distributor.pause();

        vm.prank(guardian);
        distributor.pause();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        distributor.claim(roundId, 0, aliceRequest, alice, aliceAmount, proof);
        vm.prank(guardian);
        distributor.unpause();
        distributor.claim(roundId, 0, aliceRequest, alice, aliceAmount, proof);
    }

    function test_reclaimExpired_returnsOnlyUnclaimedFunding() public {
        (uint256 roundId,, bytes32 bobLeaf, uint256 aliceRequest,, uint256 aliceAmount, uint256 bobAmount) =
            _twoLeafRound();
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = bobLeaf;
        distributor.claim(roundId, 0, aliceRequest, alice, aliceAmount, proof);
        RecoveryTopUpDistributor.Round memory r = distributor.round(roundId);

        vm.expectRevert(
            abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_NotExpired.selector, roundId, r.claimDeadline)
        );
        vm.prank(admin);
        distributor.reclaimExpired(roundId);

        vm.warp(uint256(r.claimDeadline) + 1);
        vm.expectEmit(true, true, false, true);
        emit RecoveryTopUpDistributor.RoundReclaimed(roundId, treasury, bobAmount);
        vm.prank(admin);
        distributor.reclaimExpired(roundId);
        assertEq(usdfr.balanceOf(treasury), bobAmount);
        assertEq(usdfr.balanceOf(address(distributor)), 0);
        assertTrue(distributor.round(roundId).reclaimed);

        vm.expectRevert(abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_RoundReclaimed.selector, roundId));
        vm.prank(admin);
        distributor.reclaimExpired(roundId);
    }

    function test_reclaimExpired_adminOnlyAndUnknownRound() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        vm.prank(alice);
        distributor.reclaimExpired(0);

        vm.expectRevert(abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_UnknownRound.selector, uint256(0)));
        vm.prank(admin);
        distributor.reclaimExpired(0);
    }

    function test_leafDomainSeparationAndBitmapWordBoundary() public view {
        bytes32 here = distributor.leafHash(0, 0, 11, alice, 1e18);
        bytes32 otherRequest = distributor.leafHash(0, 0, 12, alice, 1e18);
        bytes32 otherIndex = distributor.leafHash(0, 256, 11, alice, 1e18);
        assertTrue(here != otherRequest);
        assertTrue(here != otherIndex);
        assertFalse(distributor.isClaimed(0, 0));
        assertFalse(distributor.isClaimed(0, 256));
    }

    function test_upgradeOnlyUpgrader() public {
        address newImpl = address(new RecoveryTopUpDistributor());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.UPGRADER_ROLE)
        );
        vm.prank(alice);
        distributor.upgradeToAndCall(newImpl, "");
        vm.prank(admin);
        distributor.upgradeToAndCall(newImpl, "");
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(bytes.concat(a, b)) : keccak256(bytes.concat(b, a));
    }
}
