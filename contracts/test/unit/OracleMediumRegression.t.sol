// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ProductionCreditFixture} from "../helpers/ProductionCreditFixture.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";

contract OracleMediumRegression is ProductionCreditFixture {
    function _input(uint256 id, IAttestationOracle.AttestationKind kind, bytes32 payload)
        private returns (IAttestationOracle.AttestationInput memory)
    {
        return IAttestationOracle.AttestationInput(id, kind, payload, uint64(block.timestamp), uint64(block.timestamp + 1 hours), ++nonceCounter);
    }

    function test_medium_allActionKindsPreservePendingFactAndRetryExactSecondBundle() public {
        IAttestationOracle.AttestationKind[6] memory kinds = [
            IAttestationOracle.AttestationKind.PaymentReceived, IAttestationOracle.AttestationKind.DefaultDeclared,
            IAttestationOracle.AttestationKind.LossRealized, IAttestationOracle.AttestationKind.PastDueCured,
            IAttestationOracle.AttestationKind.TermsAmended, IAttestationOracle.AttestationKind.AccrualOpening
        ];
        for (uint256 i; i < kinds.length; ++i) {
            uint256 id = 900 + i;
            bytes32 first = keccak256(abi.encode("first-action", i));
            bytes32 second = keccak256(abi.encode("second-action", i));
            _attest(id, kinds[i], first, uint64(block.timestamp));
            IAttestationOracle.AttestationInput memory input = _input(id, kinds[i], second);
            bytes[] memory sigs = _signedBundle(input);
            bytes32 digest = realOracle.attestationDigest(input);
            vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_UnconsumedFact.selector, id, kinds[i], first));
            realOracle.attest(input, sigs);
            assertFalse(realOracle.digestUsed(digest), "refused submission consumed its signature");
            (bytes32 payload,, bool satisfied) = realOracle.latestPayload(id, kinds[i]);
            assertEq(payload, first);
            assertTrue(satisfied);
            assertEq(uint256(realOracle.factStatus(id, kinds[i], second)), uint256(IAttestationOracle.FactStatus.None));
            vm.prank(address(waterfall));
            realOracle.consume(id, kinds[i]);
            realOracle.attest(input, sigs);
            (payload,, satisfied) = realOracle.latestPayload(id, kinds[i]);
            assertEq(payload, second);
            assertTrue(satisfied);
            assertEq(uint256(realOracle.factStatus(id, kinds[i], first)), uint256(IAttestationOracle.FactStatus.Consumed));
            vm.prank(address(waterfall));
            realOracle.consume(id, kinds[i]);
            assertEq(uint256(realOracle.factStatus(id, kinds[i], second)), uint256(IAttestationOracle.FactStatus.Consumed));
        }
    }

    function test_medium_revocationAllowsReplacementWithoutRevivingOldAction() public {
        uint256 id = 999;
        IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind.PaymentReceived;
        bytes32 first = keccak256("superseded-approved-receipt");
        _attest(id, kind, first, uint64(block.timestamp));
        vm.prank(admin);
        realOracle.revoke(id, kind);
        _attest(id, kind, keccak256("replacement-approved-receipt"), uint64(block.timestamp));
        IAttestationOracle.AttestationInput memory retry = _input(id, kind, first);
        bytes[] memory sigs = _signedBundle(retry);
        bytes32 fact = realOracle.factKey(id, kind, first);
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_FactAlreadyRealised.selector, fact, IAttestationOracle.FactStatus.Revoked));
        realOracle.attest(retry, sigs);
        assertEq(uint256(realOracle.factStatus(id, kind, first)), uint256(IAttestationOracle.FactStatus.Revoked));
    }

    function test_medium_documentaryAndValuationUpdatesRemainAvailable() public {
        uint256 id = 998;
        for (uint8 k; k < uint8(IAttestationOracle.AttestationKind.PaymentReceived); ++k) {
            IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind(k);
            _attest(id, kind, keccak256(abi.encode("old-document", k)), uint64(block.timestamp));
            bytes32 next = keccak256(abi.encode("new-document", k));
            _attest(id, kind, next, uint64(block.timestamp));
            (bytes32 payload,, bool satisfied) = realOracle.latestPayload(id, kind);
            assertEq(payload, next);
            assertTrue(satisfied);
        }
        _attest(id, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(100e18)), uint64(block.timestamp));
        vm.warp(block.timestamp + 1);
        _attest(id, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(90e18)), uint64(block.timestamp));
        (uint256 value,) = realOracle.latestValuation(id);
        assertEq(value, 90e18);
    }
}
