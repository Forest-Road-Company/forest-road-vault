// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {AttestationOracle} from "../../src/AttestationOracle.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {Roles} from "../../src/libraries/Roles.sol";

contract AttestationOracleTest is Test {
    AttestationOracle internal oracle;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal creditModule = makeAddr("creditModule");

    uint256 internal pk1 = 0xA11CE;
    uint256 internal pk2 = 0xB0B;
    uint256 internal pk3 = 0xCAFE;
    address internal att1;
    address internal att2;
    address internal att3;
    uint256 internal outsiderPk = 0xBAD;

    uint256 internal constant FACILITY = 1;

    function setUp() public {
        vm.warp(1_750_000_000);
        att1 = vm.addr(pk1);
        att2 = vm.addr(pk2);
        att3 = vm.addr(pk3);
        oracle = AttestationOracle(
            address(
                new ERC1967Proxy(
                    address(new AttestationOracle()),
                    abi.encodeCall(AttestationOracle.initialize, (admin, guardian, admin))
                )
            )
        );
        vm.startPrank(admin);
        oracle.grantRole(Roles.ATTESTER_ROLE, att1);
        oracle.grantRole(Roles.ATTESTER_ROLE, att2);
        oracle.grantRole(Roles.ATTESTER_ROLE, att3);
        oracle.grantRole(Roles.CREDIT_ROLE, creditModule);
        vm.stopPrank();
    }

    // ── signing helpers ──────────────────────────────────────────────────

    function _input(IAttestationOracle.AttestationKind kind, bytes32 payload, uint64 asOf, uint256 nonce)
        internal
        view
        returns (IAttestationOracle.AttestationInput memory)
    {
        return IAttestationOracle.AttestationInput({
            facilityId: FACILITY,
            kind: kind,
            payload: payload,
            asOf: asOf,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: nonce
        });
    }

    function _sign(uint256 pk, IAttestationOracle.AttestationInput memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, oracle.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Signatures sorted by ascending signer address (the contract's requirement).
    function _sigs2(uint256 pkA, uint256 pkB, IAttestationOracle.AttestationInput memory a)
        internal
        view
        returns (bytes[] memory sigs)
    {
        (uint256 lo, uint256 hi) = vm.addr(pkA) < vm.addr(pkB) ? (pkA, pkB) : (pkB, pkA);
        sigs = new bytes[](2);
        sigs[0] = _sign(lo, a);
        sigs[1] = _sign(hi, a);
    }

    function _sigs1(uint256 pk, IAttestationOracle.AttestationInput memory a)
        internal
        view
        returns (bytes[] memory sigs)
    {
        sigs = new bytes[](1);
        sigs[0] = _sign(pk, a);
    }

    function _attestAssignment() internal returns (IAttestationOracle.AttestationInput memory a) {
        a = _input(IAttestationOracle.AttestationKind.AssignmentExecuted, keccak256("doc"), uint64(block.timestamp), 1);
        oracle.attest(a, _sigs1(pk1, a));
    }

    // ── initialize ───────────────────────────────────────────────────────

    function test_initialize_zeroAddressReverts() public {
        AttestationOracle impl = new AttestationOracle();
        vm.expectRevert(AttestationOracle.Oracle_ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(AttestationOracle.initialize, (address(0), guardian, admin)));
        vm.expectRevert(AttestationOracle.Oracle_ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(AttestationOracle.initialize, (admin, address(0), admin)));
        vm.expectRevert(AttestationOracle.Oracle_ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(AttestationOracle.initialize, (admin, guardian, address(0))));
    }

    function test_initialize_thresholdDefaults_highValueKindsAtTwo() public view {
        // AUDIT FIX: every value-moving / state-freezing kind defaults to 2-of-n —
        // CreditIssued, Valuation, PaymentReceived (authorizes a distribution),
        // DefaultDeclared, LossRealized, PastDueCured, and TermsAmended. Documentary
        // kinds start 1-of-n.
        for (uint8 k = 0; k < 9; ++k) {
            IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind(k);
            uint8 expected = (
                kind == IAttestationOracle.AttestationKind.CreditIssued
                    || kind == IAttestationOracle.AttestationKind.Valuation
                    || kind == IAttestationOracle.AttestationKind.PaymentReceived
                    || kind == IAttestationOracle.AttestationKind.DefaultDeclared
                    || kind == IAttestationOracle.AttestationKind.LossRealized
                    || kind == IAttestationOracle.AttestationKind.PastDueCured
                    || kind == IAttestationOracle.AttestationKind.TermsAmended
            ) ? 2 : 1;
            assertEq(oracle.threshold(kind), expected, "ADR-0007 threshold default");
        }
    }

    // ── attest: happy paths ──────────────────────────────────────────────

    function test_attest_singleSignerKind() public {
        IAttestationOracle.AttestationInput memory a = _input(
            IAttestationOracle.AttestationKind.AssignmentExecuted,
            keccak256("assignment-doc"),
            uint64(block.timestamp - 60),
            1
        );
        bytes32 digest = oracle.attestationDigest(a);
        assertFalse(oracle.digestUsed(digest));

        vm.expectEmit(true, true, true, true);
        emit IAttestationOracle.Attested(
            FACILITY, IAttestationOracle.AttestationKind.AssignmentExecuted, att1, uint64(block.timestamp)
        );
        vm.expectEmit(true, true, false, true);
        emit IAttestationOracle.AttestationSatisfied(
            FACILITY, IAttestationOracle.AttestationKind.AssignmentExecuted, keccak256("assignment-doc"), a.asOf
        );
        oracle.attest(a, _sigs1(pk1, a)); // anyone can relay — no prank needed

        assertTrue(oracle.isSatisfied(FACILITY, IAttestationOracle.AttestationKind.AssignmentExecuted));
        assertTrue(oracle.digestUsed(digest));
        (bytes32 payload, uint64 asOf, bool ok) =
            oracle.latestPayload(FACILITY, IAttestationOracle.AttestationKind.AssignmentExecuted);
        assertEq(payload, keccak256("assignment-doc"));
        assertEq(asOf, a.asOf);
        assertTrue(ok);
    }

    function test_attest_valuationTwoOfN() public {
        IAttestationOracle.AttestationInput memory a = _input(
            IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(750_000e18)), uint64(block.timestamp), 7
        );
        oracle.attest(a, _sigs2(pk1, pk2, a));
        (uint256 value, uint64 asOf) = oracle.latestValuation(FACILITY);
        assertEq(value, 750_000e18);
        assertEq(asOf, a.asOf);
        assertTrue(oracle.isSatisfied(FACILITY, IAttestationOracle.AttestationKind.Valuation));
    }

    function test_attest_extraSignaturesBeyondThresholdAccepted() public {
        IAttestationOracle.AttestationInput memory a =
            _input(IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(1e18)), uint64(block.timestamp), 9);
        // all three attesters sign, sorted ascending
        uint256[3] memory pks = [pk1, pk2, pk3];
        // insertion sort by address
        for (uint256 i = 1; i < 3; ++i) {
            for (uint256 j = i; j > 0 && vm.addr(pks[j - 1]) > vm.addr(pks[j]); --j) {
                (pks[j - 1], pks[j]) = (pks[j], pks[j - 1]);
            }
        }
        bytes[] memory sigs = new bytes[](3);
        for (uint256 i = 0; i < 3; ++i) {
            sigs[i] = _sign(pks[i], a);
        }
        oracle.attest(a, sigs);
        assertTrue(oracle.isSatisfied(FACILITY, IAttestationOracle.AttestationKind.Valuation));
    }

    function test_attest_reAttestNewNonceRefreshesFact() public {
        IAttestationOracle.AttestationInput memory a = _attestAssignment();
        // consume then re-attest with a fresh nonce: fact becomes true again
        vm.prank(creditModule);
        oracle.consume(FACILITY, IAttestationOracle.AttestationKind.AssignmentExecuted);
        assertFalse(oracle.isSatisfied(FACILITY, IAttestationOracle.AttestationKind.AssignmentExecuted));
        a.nonce = 2;
        oracle.attest(a, _sigs1(pk1, a));
        assertTrue(oracle.isSatisfied(FACILITY, IAttestationOracle.AttestationKind.AssignmentExecuted));
    }

    // ── attest: guards ───────────────────────────────────────────────────

    function test_attest_expiredReverts() public {
        IAttestationOracle.AttestationInput memory a =
            _input(IAttestationOracle.AttestationKind.AssignmentExecuted, keccak256("doc"), uint64(block.timestamp), 1);
        a.expiry = uint64(block.timestamp - 1);
        bytes[] memory sigsPre1 = _sigs1(pk1, a);
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_Expired.selector, a.expiry));
        oracle.attest(a, sigsPre1);
    }

    function test_attest_badAsOfReverts() public {
        IAttestationOracle.AttestationInput memory a =
            _input(IAttestationOracle.AttestationKind.AssignmentExecuted, keccak256("doc"), 0, 1);
        bytes[] memory sigsPre2 = _sigs1(pk1, a);
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_BadAsOf.selector, 0));
        oracle.attest(a, sigsPre2);

        a.asOf = uint64(block.timestamp + 10); // the future cannot be observed
        bytes[] memory sigsPre3 = _sigs1(pk1, a);
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_BadAsOf.selector, a.asOf));
        oracle.attest(a, sigsPre3);
    }

    function test_attest_replayedDigestReverts() public {
        IAttestationOracle.AttestationInput memory a = _attestAssignment();
        bytes[] memory sigsPre4 = _sigs1(pk1, a);
        vm.expectRevert(
            abi.encodeWithSelector(IAttestationOracle.Oracle_DigestAlreadyUsed.selector, oracle.attestationDigest(a))
        );
        oracle.attest(a, sigsPre4);
    }

    function test_attest_thresholdNotMetReverts() public {
        IAttestationOracle.AttestationInput memory a =
            _input(IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(1e18)), uint64(block.timestamp), 1);
        bytes[] memory sigsPre5 = _sigs1(pk1, a);
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_ThresholdNotMet.selector, 2, 1));
        oracle.attest(a, sigsPre5); // Valuation needs 2-of-n
    }

    function test_attest_zeroThresholdRevertsFailClosed() public {
        AttestationOracle uninitialized =
            AttestationOracle(address(new ERC1967Proxy(address(new AttestationOracle()), "")));
        IAttestationOracle.AttestationInput memory a = IAttestationOracle.AttestationInput({
            facilityId: FACILITY,
            kind: IAttestationOracle.AttestationKind.TermsAmended,
            payload: keccak256("unconfigured-kind"),
            asOf: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 1 hours),
            nonce: 1
        });

        vm.expectRevert(IAttestationOracle.Oracle_BadThreshold.selector);
        uninitialized.attest(a, new bytes[](0));
        assertFalse(uninitialized.isSatisfied(FACILITY, IAttestationOracle.AttestationKind.TermsAmended));
    }

    function test_attest_nonAttesterSignerReverts() public {
        IAttestationOracle.AttestationInput memory a =
            _input(IAttestationOracle.AttestationKind.AssignmentExecuted, keccak256("doc"), uint64(block.timestamp), 1);
        bytes[] memory sigsPre6 = _sigs1(outsiderPk, a);
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_NotAttester.selector, vm.addr(outsiderPk)));
        oracle.attest(a, sigsPre6);
    }

    function test_attest_mutatedPayloadBreaksSignature() public {
        IAttestationOracle.AttestationInput memory a =
            _input(IAttestationOracle.AttestationKind.AssignmentExecuted, keccak256("doc"), uint64(block.timestamp), 1);
        bytes[] memory sigs = _sigs1(pk1, a);
        a.payload = keccak256("tampered"); // signature no longer covers the struct
        // recovery yields some unauthorized address -> NotAttester
        vm.expectRevert();
        oracle.attest(a, sigs);
        assertFalse(oracle.isSatisfied(FACILITY, IAttestationOracle.AttestationKind.AssignmentExecuted));
    }

    function test_attest_duplicateOrUnorderedSignersRevert() public {
        IAttestationOracle.AttestationInput memory a =
            _input(IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(1e18)), uint64(block.timestamp), 1);
        // duplicate: same attester twice can never satisfy 2-of-n
        bytes[] memory dup = new bytes[](2);
        dup[0] = _sign(pk1, a);
        dup[1] = _sign(pk1, a);
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_UnorderedSigners.selector, att1, att1));
        oracle.attest(a, dup);

        // unordered: valid distinct signers in descending order are rejected
        (uint256 hiPk, uint256 loPk) = att1 > att2 ? (pk1, pk2) : (pk2, pk1);
        bytes[] memory desc = new bytes[](2);
        desc[0] = _sign(hiPk, a);
        desc[1] = _sign(loPk, a);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_UnorderedSigners.selector,
                vm.addr(hiPk) > vm.addr(loPk) ? vm.addr(hiPk) : vm.addr(loPk),
                vm.addr(hiPk) > vm.addr(loPk) ? vm.addr(loPk) : vm.addr(hiPk)
            )
        );
        oracle.attest(a, desc);
    }

    function test_attest_zeroValuationReverts() public {
        IAttestationOracle.AttestationInput memory a =
            _input(IAttestationOracle.AttestationKind.Valuation, bytes32(0), uint64(block.timestamp), 1);
        bytes[] memory sigsPre7 = _sigs2(pk1, pk2, a);
        vm.expectRevert(IAttestationOracle.Oracle_ZeroValuation.selector);
        oracle.attest(a, sigsPre7);
    }

    /// @dev The rollback defense: a genuinely-signed but OLDER mark can never replace
    ///      a newer one (ADR-0020 — asOf is attested time, strictly increasing).
    function test_attest_staleValuationReverts() public {
        IAttestationOracle.AttestationInput memory fresh =
            _input(IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(2e18)), uint64(block.timestamp), 1);
        oracle.attest(fresh, _sigs2(pk1, pk2, fresh));

        IAttestationOracle.AttestationInput memory stale =
            _input(IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(9e18)), fresh.asOf - 1, 2);
        bytes[] memory sigsPre8 = _sigs2(pk1, pk2, stale);
        vm.expectRevert(
            abi.encodeWithSelector(IAttestationOracle.Oracle_StaleValuation.selector, stale.asOf, fresh.asOf)
        );
        oracle.attest(stale, sigsPre8);

        // equal asOf is also a rollback attempt
        stale.asOf = fresh.asOf;
        stale.nonce = 3;
        bytes[] memory sigsPre9 = _sigs2(pk1, pk2, stale);
        vm.expectRevert(
            abi.encodeWithSelector(IAttestationOracle.Oracle_StaleValuation.selector, fresh.asOf, fresh.asOf)
        );
        oracle.attest(stale, sigsPre9);
    }

    function test_attest_revokedAttesterSignatureRejected() public {
        vm.prank(admin);
        oracle.revokeRole(Roles.ATTESTER_ROLE, att1);
        IAttestationOracle.AttestationInput memory a =
            _input(IAttestationOracle.AttestationKind.AssignmentExecuted, keccak256("doc"), uint64(block.timestamp), 1);
        bytes[] memory sigsPre10 = _sigs1(pk1, a);
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_NotAttester.selector, att1));
        oracle.attest(a, sigsPre10);
    }

    // ── consume ──────────────────────────────────────────────────────────

    function test_consume_clearsSatisfiedKeepsAudit() public {
        IAttestationOracle.AttestationInput memory a = _attestAssignment();
        vm.expectEmit(true, true, true, true);
        emit IAttestationOracle.AttestationConsumed(
            FACILITY, IAttestationOracle.AttestationKind.AssignmentExecuted, creditModule
        );
        vm.prank(creditModule);
        oracle.consume(FACILITY, IAttestationOracle.AttestationKind.AssignmentExecuted);

        assertFalse(oracle.isSatisfied(FACILITY, IAttestationOracle.AttestationKind.AssignmentExecuted));
        (bytes32 payload, uint64 asOf,) =
            oracle.latestPayload(FACILITY, IAttestationOracle.AttestationKind.AssignmentExecuted);
        assertEq(payload, a.payload, "audit trail retained");
        assertEq(asOf, a.asOf);
    }

    function test_consume_guards() public {
        vm.prank(creditModule);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_NotSatisfied.selector,
                FACILITY,
                IAttestationOracle.AttestationKind.PaymentReceived
            )
        );
        oracle.consume(FACILITY, IAttestationOracle.AttestationKind.PaymentReceived);

        _attestAssignment();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, att1, Roles.CREDIT_ROLE)
        );
        vm.prank(att1);
        oracle.consume(FACILITY, IAttestationOracle.AttestationKind.AssignmentExecuted);
    }

    // ── revoke ───────────────────────────────────────────────────────────

    function test_revoke_valuationZeroesTheMark() public {
        IAttestationOracle.AttestationInput memory a =
            _input(IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(5e18)), uint64(block.timestamp), 1);
        oracle.attest(a, _sigs2(pk1, pk2, a));

        vm.expectEmit(true, true, false, true);
        emit IAttestationOracle.AttestationRevoked(FACILITY, IAttestationOracle.AttestationKind.Valuation);
        vm.prank(admin);
        oracle.revoke(FACILITY, IAttestationOracle.AttestationKind.Valuation);

        (uint256 value, uint64 asOf) = oracle.latestValuation(FACILITY);
        assertEq(value, 0, "a revoked mark cannot keep steering the margin path");
        assertEq(asOf, 0);
        assertFalse(oracle.isSatisfied(FACILITY, IAttestationOracle.AttestationKind.Valuation));

        // AUDIT FIX (H-02): the watermark SURVIVES revocation, so re-attesting the same
        // `asOf` is now correctly rejected. Only a mark observed strictly LATER may land —
        // revocation is an emergency stop on the live mark, never a rollback window.
        assertEq(oracle.valuationWatermark(FACILITY), a.asOf, "watermark survives revoke");
        a.nonce = 2;
        bytes[] memory sameTimeSigs = _sigs2(pk1, pk2, a); // built first: expectRevert is call-scoped
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_StaleValuation.selector, a.asOf, a.asOf));
        oracle.attest(a, sameTimeSigs);

        // A strictly newer observation lands normally.
        vm.warp(block.timestamp + 1);
        a.nonce = 3;
        a.asOf = uint64(block.timestamp);
        oracle.attest(a, _sigs2(pk1, pk2, a));
        (value,) = oracle.latestValuation(FACILITY);
        assertEq(value, 5e18);
        assertEq(oracle.valuationWatermark(FACILITY), a.asOf, "watermark advanced to the new mark");
    }

    function test_revoke_nonValuationKeepsPayloadForAudit() public {
        IAttestationOracle.AttestationInput memory a = _attestAssignment();
        vm.prank(admin);
        oracle.revoke(FACILITY, IAttestationOracle.AttestationKind.AssignmentExecuted);
        assertFalse(oracle.isSatisfied(FACILITY, IAttestationOracle.AttestationKind.AssignmentExecuted));
        (bytes32 payload,,) = oracle.latestPayload(FACILITY, IAttestationOracle.AttestationKind.AssignmentExecuted);
        assertEq(payload, a.payload);
    }

    function test_revoke_guards() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_NotSatisfied.selector, FACILITY, IAttestationOracle.AttestationKind.UCCFiled
            )
        );
        oracle.revoke(FACILITY, IAttestationOracle.AttestationKind.UCCFiled);

        _attestAssignment();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, att1, bytes32(0))
        );
        vm.prank(att1);
        oracle.revoke(FACILITY, IAttestationOracle.AttestationKind.AssignmentExecuted);
    }

    // ── thresholds ───────────────────────────────────────────────────────

    function test_setThreshold_takesEffectAndGuards() public {
        vm.expectEmit(true, false, false, true);
        emit IAttestationOracle.ThresholdSet(IAttestationOracle.AttestationKind.AssignmentExecuted, 3);
        vm.prank(admin);
        oracle.setThreshold(IAttestationOracle.AttestationKind.AssignmentExecuted, 3);

        IAttestationOracle.AttestationInput memory a =
            _input(IAttestationOracle.AttestationKind.AssignmentExecuted, keccak256("doc"), uint64(block.timestamp), 1);
        bytes[] memory sigsPre11 = _sigs2(pk1, pk2, a);
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_ThresholdNotMet.selector, 3, 2));
        oracle.attest(a, sigsPre11);

        vm.prank(admin);
        vm.expectRevert(IAttestationOracle.Oracle_BadThreshold.selector);
        oracle.setThreshold(IAttestationOracle.AttestationKind.AssignmentExecuted, 0);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, att1, bytes32(0))
        );
        vm.prank(att1);
        oracle.setThreshold(IAttestationOracle.AttestationKind.AssignmentExecuted, 1);
    }

    /// @dev AUDIT REGRESSION (SM-2): the value-moving/state-freezing kinds are floored
    ///      at 2-of-n — governance can't lower them to 1-of-n and undo the
    ///      single-attester protection.
    function test_setThreshold_highValueKindsFlooredAtTwo() public {
        vm.startPrank(admin);
        IAttestationOracle.AttestationKind[4] memory hi = [
            IAttestationOracle.AttestationKind.CreditIssued,
            IAttestationOracle.AttestationKind.Valuation,
            IAttestationOracle.AttestationKind.PaymentReceived,
            IAttestationOracle.AttestationKind.DefaultDeclared
        ];
        for (uint256 i = 0; i < 4; ++i) {
            vm.expectRevert(IAttestationOracle.Oracle_BadThreshold.selector);
            oracle.setThreshold(hi[i], 1);
            oracle.setThreshold(hi[i], 3); // >= 2 is fine
            assertEq(oracle.threshold(hi[i]), 3);
        }
        // documentary kinds can still go to 1-of-n
        oracle.setThreshold(IAttestationOracle.AttestationKind.AssignmentExecuted, 1);
        assertEq(oracle.threshold(IAttestationOracle.AttestationKind.AssignmentExecuted), 1);
        vm.stopPrank();
    }

    // ── pause ────────────────────────────────────────────────────────────

    function test_pause_blocksSubmissionsNeverReadsOrConsumption() public {
        IAttestationOracle.AttestationInput memory a = _attestAssignment();
        vm.prank(guardian);
        oracle.pause();

        a.nonce = 2;
        bytes[] memory sigsPre12 = _sigs1(pk1, a);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        oracle.attest(a, sigsPre12);

        // reads and consumption keep flowing while paused
        assertTrue(oracle.isSatisfied(FACILITY, IAttestationOracle.AttestationKind.AssignmentExecuted));
        vm.prank(creditModule);
        oracle.consume(FACILITY, IAttestationOracle.AttestationKind.AssignmentExecuted);

        vm.prank(guardian);
        oracle.unpause();
        oracle.attest(a, _sigs1(pk1, a));
    }

    function test_pause_onlyGuardian() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, att1, Roles.GUARDIAN_ROLE)
        );
        vm.prank(att1);
        oracle.pause();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, att1, Roles.GUARDIAN_ROLE)
        );
        vm.prank(att1);
        oracle.unpause();
    }

    // ── upgrade authorization ────────────────────────────────────────────

    function test_upgrade_onlyUpgraderRole() public {
        address newImpl = address(new AttestationOracle());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, att1, Roles.UPGRADER_ROLE)
        );
        vm.prank(att1);
        oracle.upgradeToAndCall(newImpl, "");
        vm.prank(admin);
        oracle.upgradeToAndCall(newImpl, "");
    }

    // ── fuzz: threshold boundary is exact ────────────────────────────────

    /// @dev For any threshold m in [1,3]: m distinct valid signers satisfy the fact;
    ///      m-1 never do. The m-of-n boundary is exact.
    function testFuzz_attest_thresholdBoundaryExact(uint8 m, uint64 asOfSeed) public {
        m = uint8(bound(m, 1, 3));
        uint64 asOf = uint64(bound(asOfSeed, 1, block.timestamp));
        vm.prank(admin);
        oracle.setThreshold(IAttestationOracle.AttestationKind.UCCFiled, m);

        IAttestationOracle.AttestationInput memory a =
            _input(IAttestationOracle.AttestationKind.UCCFiled, keccak256("UCC filing"), asOf, uint256(asOfSeed) + 1);

        // sort the three attesters by address
        uint256[3] memory pks = [pk1, pk2, pk3];
        for (uint256 i = 1; i < 3; ++i) {
            for (uint256 j = i; j > 0 && vm.addr(pks[j - 1]) > vm.addr(pks[j]); --j) {
                (pks[j - 1], pks[j]) = (pks[j], pks[j - 1]);
            }
        }

        if (m > 1) {
            bytes[] memory short = new bytes[](m - 1);
            for (uint256 i = 0; i < m - 1; ++i) {
                short[i] = _sign(pks[i], a);
            }
            vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_ThresholdNotMet.selector, m, m - 1));
            oracle.attest(a, short);
        }

        bytes[] memory sigs = new bytes[](m);
        for (uint256 i = 0; i < m; ++i) {
            sigs[i] = _sign(pks[i], a);
        }
        oracle.attest(a, sigs);
        assertTrue(oracle.isSatisfied(FACILITY, IAttestationOracle.AttestationKind.UCCFiled));
    }
}
