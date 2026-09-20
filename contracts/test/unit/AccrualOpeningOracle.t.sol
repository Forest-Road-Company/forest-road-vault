// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AttestationOracleTest} from "./AttestationOracle.t.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Migration openings use the existing signature and one-shot fact machinery.
contract AccrualOpeningOracleTest is AttestationOracleTest {
    IAttestationOracle.AttestationKind private constant OPENING = IAttestationOracle.AttestationKind.AccrualOpening;

    function test_openingAppendsAKindWithAnEnforcedQuorum() public {
        assertEq(uint8(IAttestationOracle.AttestationKind.TermsAmended), 8);
        assertEq(uint8(OPENING), 9);
        for (uint8 k; k <= uint8(OPENING); ++k) {
            assertEq(oracle.threshold(IAttestationOracle.AttestationKind(k)), k < 2 ? 1 : 2);
        }
        for (uint8 threshold; threshold < 2; ++threshold) {
            vm.prank(admin);
            vm.expectRevert(IAttestationOracle.Oracle_BadThreshold.selector);
            oracle.setThreshold(OPENING, threshold);
        }
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), bytes32(0))
        );
        oracle.setThreshold(OPENING, 2);
        vm.prank(admin);
        oracle.setThreshold(OPENING, 3);
        assertEq(oracle.threshold(OPENING), 3);
        vm.prank(admin);
        oracle.setThreshold(OPENING, 2);
        assertEq(oracle.threshold(OPENING), 2);
    }

    function test_openingNeedsDistinctSignersAndCanBeConsumedOnlyOnce() public {
        IAttestationOracle.AttestationInput memory a = _input(OPENING, keccak256("opening"), uint64(block.timestamp), 1);
        bytes[] memory one = _sigs1(pk1, a);
        vm.expectRevert(
            abi.encodeWithSelector(IAttestationOracle.Oracle_ThresholdNotMet.selector, uint8(2), uint256(1))
        );
        oracle.attest(a, one);
        bytes[] memory repeated = new bytes[](2);
        repeated[0] = one[0];
        repeated[1] = one[0];
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_UnorderedSigners.selector, att1, att1));
        oracle.attest(a, repeated);
        oracle.attest(a, _sigs2(pk1, pk2, a));
        (bytes32 payload, uint64 asOf, bool satisfied) = oracle.latestPayload(FACILITY, OPENING);
        assertEq(payload, a.payload);
        assertEq(asOf, a.asOf);
        assertTrue(satisfied);
        assertEq(uint8(oracle.factStatus(FACILITY, OPENING, a.payload)), uint8(IAttestationOracle.FactStatus.Recorded));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), Roles.CREDIT_ROLE
            )
        );
        oracle.consume(FACILITY, OPENING);
        vm.prank(creditModule);
        oracle.consume(FACILITY, OPENING);
        assertFalse(oracle.isSatisfied(FACILITY, OPENING));
        assertEq(uint8(oracle.factStatus(FACILITY, OPENING, a.payload)), uint8(IAttestationOracle.FactStatus.Consumed));
        vm.prank(creditModule);
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_NotSatisfied.selector, FACILITY, OPENING));
        oracle.consume(FACILITY, OPENING);
        ++a.nonce;
        bytes[] memory signatures = _sigs2(pk1, pk2, a);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_FactAlreadyRealised.selector,
                oracle.factKey(FACILITY, OPENING, a.payload),
                IAttestationOracle.FactStatus.Consumed
            )
        );
        oracle.attest(a, signatures);
    }

    function test_revokedOpeningCannotBePublishedWithAFreshNonce() public {
        IAttestationOracle.AttestationInput memory a =
            _input(OPENING, keccak256("revoked opening"), uint64(block.timestamp), 1);
        oracle.attest(a, _sigs2(pk1, pk2, a));
        vm.prank(admin);
        oracle.revoke(FACILITY, OPENING);
        assertFalse(oracle.isSatisfied(FACILITY, OPENING));
        assertEq(uint8(oracle.factStatus(FACILITY, OPENING, a.payload)), uint8(IAttestationOracle.FactStatus.Revoked));
        ++a.nonce;
        bytes[] memory signatures = _sigs2(pk1, pk2, a);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_FactAlreadyRealised.selector,
                oracle.factKey(FACILITY, OPENING, a.payload),
                IAttestationOracle.FactStatus.Revoked
            )
        );
        oracle.attest(a, signatures);
    }

    function test_preexistingProxyRequiresExplicitOpeningThresholdConfiguration() public {
        // The new mapping key is zero on an upgraded proxy. Assert the exact seed slot first.
        bytes32 slot = keccak256(
            abi.encode(
                uint256(uint8(OPENING)), uint256(0xac9508c5303c175f6440d43a5e3eadcf5afa63ca3c359d94d58c5e5919cebf00) + 1
            )
        );
        assertEq(uint256(vm.load(address(oracle), slot)), 2);
        vm.store(address(oracle), slot, bytes32(0));
        assertEq(oracle.threshold(OPENING), 0);
        IAttestationOracle.AttestationInput memory a =
            _input(OPENING, keccak256("legacy opening"), uint64(block.timestamp), 1);
        bytes[] memory signatures = _sigs2(pk1, pk2, a);
        vm.expectRevert(IAttestationOracle.Oracle_BadThreshold.selector);
        oracle.attest(a, signatures);
        assertFalse(oracle.digestUsed(oracle.attestationDigest(a)));
        vm.prank(admin);
        oracle.setThreshold(OPENING, 2);
        oracle.attest(a, signatures);
        assertTrue(oracle.isSatisfied(FACILITY, OPENING));
        assertEq(oracle.threshold(IAttestationOracle.AttestationKind.CreditIssued), 2);
    }

    function testFuzz_openingSignaturesBindThePayloadAndFacility(bytes32 payload, uint256 id) public {
        IAttestationOracle.AttestationInput memory a = _input(OPENING, payload, uint64(block.timestamp), 1);
        a.facilityId = id;
        bytes[] memory signatures = _sigs2(pk1, pk2, a);
        a.payload = payload ^ bytes32(uint256(1));
        vm.expectPartialRevert(IAttestationOracle.Oracle_NotAttester.selector);
        oracle.attest(a, signatures);
        a.payload = payload;
        a.facilityId = id ^ 1;
        vm.expectPartialRevert(IAttestationOracle.Oracle_NotAttester.selector);
        oracle.attest(a, signatures);
        a.facilityId = id;
        oracle.attest(a, signatures);
        assertTrue(oracle.isSatisfied(id, OPENING));
        assertFalse(oracle.isSatisfied(id ^ 1, OPENING));
    }
}
