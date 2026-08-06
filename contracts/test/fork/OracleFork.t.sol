// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {AttestationOracle} from "../../src/AttestationOracle.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title OracleFork — the AttestationOracle, on the REAL deployed stack, on a pinned mainnet fork
/// @notice The attestation layer is the protocol's primary trust boundary (ADR-0007): everything
///         downstream — the ClaimBridge mint gate, the WaterfallEngine payment gate, the
///         DefaultManager margin path and the right-hand side of the ADR-0012 backing invariant —
///         executes faithfully on whatever a quorum of attesters asserts. This suite drives that
///         boundary against the stack `Deploy.s.sol` actually builds, not a hand-wired mock.
///
///         Covered here and nowhere else on a fork:
///           * per-kind m-of-n thresholds, INCLUDING the 2-of-n floor `setThreshold` may not
///             lower (the value-moving / state-freezing kinds);
///           * EIP-712 digest replay refused FOREVER — across revoke, across consume, and 1000
///             days later inside a still-valid expiry window;
///           * signer-set discipline: ascending-sorted signatures, duplicate signer refused,
///             non-attester refused, live role revocation honoured;
///           * `asOf` as ATTESTED OBSERVATION TIME rather than submission time, and expiry;
///           * H-02: the valuation high-watermark surviving BOTH `revoke` and `consume`, an
///             older validly-signed mark refused after a revoke, and the watermark provably
///             un-pushable into the future by any bundle (owner decision 2026-07-22 REMOVED the
///             `resetValuationWatermark` recovery lever; the protection itself is unchanged and a
///             stuck watermark is now recovered via the oracle's timelocked UUPS upgrade);
///           * facility 0 — the treasury reserve instrument — feeding
///             `ReserveManager.totalBackingValue()` live, and a REVOKED or STALE mark
///             contributing exactly ZERO.
///
/// @dev FIXTURE CAPABILITIES ADDED LOCALLY (declared, per the brief): this file needs two
///      things `ForkLifecycleFixture` does not expose, both implemented privately below and
///      neither of them modifying the fixture:
///        1. attestation bundles with ARBITRARY signer sets / signature counts / expiries
///           (`_input`, `_sig`, `_sorted`, `_one`, `_submit`) — the fixture's `_attest` only ever
///           forms a correct, sorted 2-of-n;
///        2. `CREDIT_ROLE` on the oracle for `ops`, so `consume` can be driven directly rather
///           than only via a waterfall distribution (granted in-test by the DEFAULT_ADMIN the
///           fixture deliberately retains).
contract OracleForkTest is ForkLifecycleFixture {
    using ECDSA for bytes32;

    /// @dev A key that is deliberately NOT in the attester set.
    uint256 private constant PK_OUTSIDER = 0xC0FFEE;
    /// @dev EIP-712 domain of the deployed oracle (must match `AttestationOracle.initialize`).
    string private constant DOMAIN_NAME = "ForestRoadAttestationOracle";
    string private constant DOMAIN_VERSION = "1";
    bytes32 private constant ATTESTATION_TYPEHASH =
        keccak256("Attestation(uint256 facilityId,uint8 kind,bytes32 payload,uint64 asOf,uint64 expiry,uint256 nonce)");

    uint256 private _nonceCounter;

    // ─────────────────────────────────────────────────────────────────────
    // 1. THRESHOLDS — m-of-n per kind, and the 2-of-n floor
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The DEPLOYED oracle's per-kind thresholds are the ADR-0007 shape: every kind that
    ///         authorizes a value-moving or state-freezing action starts at 2-of-n; the purely
    ///         documentary kinds start at 1-of-n.
    function test_fork_thresholdDefaultsOnTheDeployedOracle() public onFork {
        assertEq(oracle.threshold(IAttestationOracle.AttestationKind.CreditIssued), 2, "CreditIssued 2-of-n");
        assertEq(oracle.threshold(IAttestationOracle.AttestationKind.Valuation), 2, "Valuation 2-of-n");
        assertEq(oracle.threshold(IAttestationOracle.AttestationKind.PaymentReceived), 2, "PaymentReceived 2-of-n");
        assertEq(oracle.threshold(IAttestationOracle.AttestationKind.DefaultDeclared), 2, "DefaultDeclared 2-of-n");

        assertEq(oracle.threshold(IAttestationOracle.AttestationKind.AssignmentExecuted), 1, "Assignment 1-of-n");
        assertEq(oracle.threshold(IAttestationOracle.AttestationKind.UCCFiled), 1, "UCCFiled 1-of-n");
        assertEq(
            oracle.threshold(IAttestationOracle.AttestationKind.AssignmentExecuted), 1, "documentary assignment 1-of-n"
        );
        assertEq(oracle.threshold(IAttestationOracle.AttestationKind.UCCFiled), 1, "documentary UCC 1-of-n");
    }

    /// @notice A 1-of-n bundle is REFUSED for every high-value kind — one compromised attester
    ///         key can never act alone on the mint gate, the backing mark, a distribution, or
    ///         the loss path.
    function test_fork_oneOfNBundleRefusedForEveryHighValueKind() public onFork {
        IAttestationOracle.AttestationKind[4] memory kinds = [
            IAttestationOracle.AttestationKind.CreditIssued,
            IAttestationOracle.AttestationKind.Valuation,
            IAttestationOracle.AttestationKind.PaymentReceived,
            IAttestationOracle.AttestationKind.DefaultDeclared
        ];
        for (uint256 i = 0; i < kinds.length; ++i) {
            IAttestationOracle.AttestationInput memory a =
                _input(100 + i, kinds[i], keccak256(abi.encode("single", i)), uint64(block.timestamp), 1 hours);
            bytes32 d = oracle.attestationDigest(a);
            bytes[] memory sigs = _one(PK1, d);
            vm.expectRevert(
                abi.encodeWithSelector(IAttestationOracle.Oracle_ThresholdNotMet.selector, uint8(2), uint256(1))
            );
            oracle.attest(a, sigs);
            assertFalse(oracle.isSatisfied(100 + i, kinds[i]), "nothing recorded from a sub-threshold bundle");
            assertFalse(oracle.digestUsed(d), "and the digest was NOT burned by the refusal");
        }
    }

    /// @notice An EMPTY signature array is refused too (the degenerate 0-of-n).
    function test_fork_zeroSignatureBundleRefused() public onFork {
        IAttestationOracle.AttestationInput memory a = _input(
            101,
            IAttestationOracle.AttestationKind.AssignmentExecuted,
            keccak256("empty"),
            uint64(block.timestamp),
            1 hours
        );
        bytes[] memory sigs = new bytes[](0);
        vm.expectRevert(
            abi.encodeWithSelector(IAttestationOracle.Oracle_ThresholdNotMet.selector, uint8(1), uint256(0))
        );
        oracle.attest(a, sigs);
    }

    /// @notice The 2-of-n floor is PER KIND, not global: a documentary kind genuinely accepts a
    ///         single signature. (Without this, the previous test would pass for the wrong
    ///         reason — e.g. if 1-signature bundles were refused everywhere.)
    function test_fork_documentaryKindAcceptsOneOfN() public onFork {
        uint64 asOf = uint64(block.timestamp);
        IAttestationOracle.AttestationInput memory a =
            _input(102, IAttestationOracle.AttestationKind.AssignmentExecuted, keccak256("solo-doc"), asOf, 1 hours);
        bytes32 d = oracle.attestationDigest(a);
        oracle.attest(a, _one(PK1, d));

        (bytes32 payload, uint64 recordedAsOf, bool satisfied) =
            oracle.latestPayload(102, IAttestationOracle.AttestationKind.AssignmentExecuted);
        assertEq(payload, keccak256("solo-doc"), "payload recorded verbatim");
        assertEq(recordedAsOf, asOf, "asOf recorded verbatim");
        assertTrue(satisfied, "a 1-of-n documentary bundle IS on-chain truth");
    }

    /// @notice `setThreshold` may NOT lower a high-value kind below 2 — governance cannot undo
    ///         the single-attester protection, accidentally or maliciously.
    function test_fork_setThresholdCannotLowerHighValueKindsBelowTwo() public onFork {
        IAttestationOracle.AttestationKind[4] memory kinds = [
            IAttestationOracle.AttestationKind.CreditIssued,
            IAttestationOracle.AttestationKind.Valuation,
            IAttestationOracle.AttestationKind.PaymentReceived,
            IAttestationOracle.AttestationKind.DefaultDeclared
        ];
        for (uint256 i = 0; i < kinds.length; ++i) {
            vm.expectRevert(IAttestationOracle.Oracle_BadThreshold.selector);
            oracle.setThreshold(kinds[i], 1);
            vm.expectRevert(IAttestationOracle.Oracle_BadThreshold.selector);
            oracle.setThreshold(kinds[i], 0);
            assertEq(oracle.threshold(kinds[i]), 2, "threshold survived the refused lowering");
        }

        // Zero is refused for EVERY kind, documentary ones included.
        vm.expectRevert(IAttestationOracle.Oracle_BadThreshold.selector);
        oracle.setThreshold(IAttestationOracle.AttestationKind.AssignmentExecuted, 0);

        // Raising a high-value kind is allowed, and it BINDS: a 2-signature bundle is then
        // short of the new quorum.
        vm.expectEmit(true, false, false, true, address(oracle));
        emit IAttestationOracle.ThresholdSet(IAttestationOracle.AttestationKind.Valuation, 3);
        oracle.setThreshold(IAttestationOracle.AttestationKind.Valuation, 3);
        assertEq(oracle.threshold(IAttestationOracle.AttestationKind.Valuation), 3, "raised to 3-of-n");

        IAttestationOracle.AttestationInput memory a = _input(
            103,
            IAttestationOracle.AttestationKind.Valuation,
            bytes32(uint256(1_000e18)),
            uint64(block.timestamp),
            1 hours
        );
        bytes32 d = oracle.attestationDigest(a);
        bytes[] memory sigs = _sorted(PK1, PK2, d);
        vm.expectRevert(
            abi.encodeWithSelector(IAttestationOracle.Oracle_ThresholdNotMet.selector, uint8(3), uint256(2))
        );
        oracle.attest(a, sigs);

        // Coming back down to the FLOOR (2) is allowed; below it is not.
        oracle.setThreshold(IAttestationOracle.AttestationKind.Valuation, 2);
        assertEq(oracle.threshold(IAttestationOracle.AttestationKind.Valuation), 2, "back at the floor");

        // Documentary kinds move freely in both directions.
        oracle.setThreshold(IAttestationOracle.AttestationKind.AssignmentExecuted, 2);
        assertEq(oracle.threshold(IAttestationOracle.AttestationKind.AssignmentExecuted), 2, "documentary raised");
        oracle.setThreshold(IAttestationOracle.AttestationKind.AssignmentExecuted, 1);
        assertEq(
            oracle.threshold(IAttestationOracle.AttestationKind.AssignmentExecuted), 1, "documentary lowered again"
        );
    }

    /// @notice `setThreshold` is DEFAULT_ADMIN-only. Neither an attester nor the guardian may
    ///         turn the quorum.
    function test_fork_setThresholdIsAdminOnly() public onFork {
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0))
        );
        oracle.setThreshold(IAttestationOracle.AttestationKind.Valuation, 3);

        vm.prank(attesterA);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attesterA, bytes32(0))
        );
        oracle.setThreshold(IAttestationOracle.AttestationKind.AssignmentExecuted, 2);

        assertEq(oracle.threshold(IAttestationOracle.AttestationKind.Valuation), 2, "unchanged");
        assertEq(oracle.threshold(IAttestationOracle.AttestationKind.AssignmentExecuted), 1, "unchanged");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. EIP-712 DOMAIN + REPLAY
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The deployed proxy's EIP-712 domain is exactly what attester tooling must sign
    ///         over, and the digest it publishes matches an independent recomputation. The
    ///         domain binds `chainId` and `verifyingContract`, so a bundle signed for another
    ///         chain or another deployment recovers a stranger and is refused.
    function test_fork_eip712DomainAndDigestAreWhatTheAttestersMustSign() public onFork {
        (, string memory name, string memory version, uint256 chainId, address verifying,,) = oracle.eip712Domain();
        assertEq(name, DOMAIN_NAME, "domain name");
        assertEq(version, DOMAIN_VERSION, "domain version");
        assertEq(chainId, block.chainid, "domain chainId is the live chain");
        assertEq(chainId, 1, "and this fork IS mainnet (chainid 1)");
        assertEq(verifying, address(oracle), "domain verifyingContract is the PROXY, not the impl");

        IAttestationOracle.AttestationInput memory a =
            _input(104, IAttestationOracle.AttestationKind.UCCFiled, keccak256("m1"), uint64(block.timestamp), 1 hours);
        bytes32 expected = _digestFor(a, block.chainid, address(oracle));
        assertEq(oracle.attestationDigest(a), expected, "published digest == independently recomputed digest");

        // A signature produced against a DIFFERENT chainId domain recovers an address that is
        // not an attester — cross-chain / cross-deployment replay is dead on arrival.
        bytes32 wrongChainDigest = _digestFor(a, 11_155_111, address(oracle));
        bytes memory sig = _sig(PK1, wrongChainDigest);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;
        address recovered = ECDSA.recover(expected, sig);
        assertTrue(recovered != attesterA, "the wrong-domain signature does not recover an attester");
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_NotAttester.selector, recovered));
        oracle.attest(a, sigs);
    }

    /// @notice A consumed digest is refused FOREVER — immediately, after a governance revoke,
    ///         after a credit-layer consume, and 1000 days later while still inside the signed
    ///         expiry window. The replay guard fires BEFORE the valuation staleness rule, so a
    ///         revoked mark cannot be resurrected by re-relaying its own bundle.
    function test_fork_digestReplayRefusedForever() public onFork {
        uint64 asOf = uint64(block.timestamp);
        IAttestationOracle.AttestationInput memory a =
            _input(105, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(2_000_000e18)), asOf, 3650 days);
        bytes32 d = oracle.attestationDigest(a);
        assertFalse(oracle.digestUsed(d), "unused before submission");
        oracle.attest(a, _sorted(PK1, PK2, d));
        assertTrue(oracle.digestUsed(d), "burned on acceptance");

        bytes[] memory sigs = _sorted(PK1, PK2, d);
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_DigestAlreadyUsed.selector, d));
        oracle.attest(a, sigs);

        // ...after governance revokes the fact (the dangerous case: revoke zeroes the live
        // record, and without the burn the SAME bundle would re-install the revoked mark).
        oracle.revoke(105, IAttestationOracle.AttestationKind.Valuation);
        assertFalse(oracle.isSatisfied(105, IAttestationOracle.AttestationKind.Valuation), "revoked");
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_DigestAlreadyUsed.selector, d));
        oracle.attest(a, sigs);

        // ...and 1000 days later, still inside the signed expiry.
        _warp(1000 days);
        assertLt(block.timestamp, a.expiry, "still inside the signed expiry window");
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_DigestAlreadyUsed.selector, d));
        oracle.attest(a, sigs);
        assertTrue(oracle.digestUsed(d), "still burned");
    }

    /// @notice A digest stays burned across `consume` as well — a spent PaymentReceived cannot
    ///         be re-relayed to authorize a second distribution of the same cash.
    function test_fork_digestReplayRefusedAfterConsume() public onFork {
        _grantCreditRoleToOps();
        uint64 asOf = uint64(block.timestamp);
        bytes32 payload = keccak256(abi.encode(uint256(106), uint256(1e18), uint256(0)));
        IAttestationOracle.AttestationInput memory a =
            _input(106, IAttestationOracle.AttestationKind.PaymentReceived, payload, asOf, 3650 days);
        bytes32 d = oracle.attestationDigest(a);
        oracle.attest(a, _sorted(PK1, PK2, d));

        vm.expectEmit(true, true, true, false, address(oracle));
        emit IAttestationOracle.AttestationConsumed(106, IAttestationOracle.AttestationKind.PaymentReceived, ops);
        oracle.consume(106, IAttestationOracle.AttestationKind.PaymentReceived);

        (bytes32 keptPayload, uint64 keptAsOf, bool satisfied) =
            oracle.latestPayload(106, IAttestationOracle.AttestationKind.PaymentReceived);
        assertEq(keptPayload, payload, "consume RETAINS the payload for audit");
        assertEq(keptAsOf, asOf, "consume RETAINS asOf for audit");
        assertFalse(satisfied, "but the fact is spent");

        bytes[] memory sigs = _sorted(PK1, PK2, d);
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_DigestAlreadyUsed.selector, d));
        oracle.attest(a, sigs);

        // Double-consume is refused.
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_NotSatisfied.selector,
                uint256(106),
                IAttestationOracle.AttestationKind.PaymentReceived
            )
        );
        oracle.consume(106, IAttestationOracle.AttestationKind.PaymentReceived);
    }

    /// @notice `consume` is CREDIT_ROLE-only.
    function test_fork_consumeIsCreditRoleOnly() public onFork {
        _submit(
            _input(
                107,
                IAttestationOracle.AttestationKind.PaymentReceived,
                keccak256("p"),
                uint64(block.timestamp),
                1 hours
            )
        );
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.CREDIT_ROLE)
        );
        oracle.consume(107, IAttestationOracle.AttestationKind.PaymentReceived);
        assertTrue(oracle.isSatisfied(107, IAttestationOracle.AttestationKind.PaymentReceived), "still satisfied");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. SIGNER-SET DISCIPLINE
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Signatures must be sorted strictly ascending by recovered signer — the
    ///         distinctness proof. Descending order is refused with the exact pair.
    function test_fork_signaturesMustBeSortedAscending() public onFork {
        (uint256 loPk, uint256 hiPk) = _lowHigh();
        IAttestationOracle.AttestationInput memory a = _input(
            108, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(5e18)), uint64(block.timestamp), 1 hours
        );
        bytes32 d = oracle.attestationDigest(a);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sig(hiPk, d);
        sigs[1] = _sig(loPk, d);
        vm.expectRevert(
            abi.encodeWithSelector(IAttestationOracle.Oracle_UnorderedSigners.selector, vm.addr(hiPk), vm.addr(loPk))
        );
        oracle.attest(a, sigs);
        assertFalse(oracle.isSatisfied(108, IAttestationOracle.AttestationKind.Valuation), "nothing recorded");
    }

    /// @notice The SAME attester signing twice cannot fake a quorum — `signer <= prev` catches
    ///         it, for the low key and the high key alike.
    function test_fork_duplicateSignerRejected() public onFork {
        (uint256 loPk, uint256 hiPk) = _lowHigh();

        IAttestationOracle.AttestationInput memory a = _input(
            109, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(5e18)), uint64(block.timestamp), 1 hours
        );
        bytes32 d = oracle.attestationDigest(a);
        bytes[] memory dupLo = new bytes[](2);
        dupLo[0] = _sig(loPk, d);
        dupLo[1] = _sig(loPk, d);
        vm.expectRevert(
            abi.encodeWithSelector(IAttestationOracle.Oracle_UnorderedSigners.selector, vm.addr(loPk), vm.addr(loPk))
        );
        oracle.attest(a, dupLo);

        bytes[] memory dupHi = new bytes[](2);
        dupHi[0] = _sig(hiPk, d);
        dupHi[1] = _sig(hiPk, d);
        vm.expectRevert(
            abi.encodeWithSelector(IAttestationOracle.Oracle_UnorderedSigners.selector, vm.addr(hiPk), vm.addr(hiPk))
        );
        oracle.attest(a, dupHi);

        assertFalse(oracle.isSatisfied(109, IAttestationOracle.AttestationKind.Valuation), "nothing recorded");
    }

    /// @notice A signature from a key outside the attester set is refused, and revoking
    ///         ATTESTER_ROLE takes effect IMMEDIATELY — a rotated-out attester's signature stops
    ///         counting on the next block, not on the next deploy.
    function test_fork_nonAttesterSignatureRejectedAndRotationIsLive() public onFork {
        address outsider = vm.addr(PK_OUTSIDER);
        assertFalse(oracle.hasRole(Roles.ATTESTER_ROLE, outsider), "outsider is not an attester");

        IAttestationOracle.AttestationInput memory a = _input(
            110, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(9e18)), uint64(block.timestamp), 1 hours
        );
        bytes32 d = oracle.attestationDigest(a);
        bytes[] memory sigs = _sorted(PK1, PK_OUTSIDER, d);
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_NotAttester.selector, outsider));
        oracle.attest(a, sigs);

        // Rotate attesterA out; the identical quorum shape is now refused naming attesterA.
        oracle.revokeRole(Roles.ATTESTER_ROLE, attesterA);
        IAttestationOracle.AttestationInput memory b = _input(
            111, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(9e18)), uint64(block.timestamp), 1 hours
        );
        bytes32 d2 = oracle.attestationDigest(b);
        bytes[] memory sigs2 = _sorted(PK1, PK2, d2);
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_NotAttester.selector, attesterA));
        oracle.attest(b, sigs2);

        // Rotate back in; the same shape is accepted again.
        oracle.grantRole(Roles.ATTESTER_ROLE, attesterA);
        oracle.attest(b, sigs2);
        assertTrue(oracle.isSatisfied(111, IAttestationOracle.AttestationKind.Valuation), "accepted after re-grant");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. asOf SEMANTICS + EXPIRY
    // ─────────────────────────────────────────────────────────────────────

    /// @notice `asOf` is the ATTESTED OBSERVATION time carried inside the signed struct — NOT
    ///         the submission time. The two are recorded separately: the record keeps `asOf`,
    ///         the `Attested` event keeps the submission block time. Every freshness rule
    ///         downstream (ADR-0015/0017) is meaningless if these are conflated.
    function test_fork_asOfIsAttestedObservationTimeNotSubmissionTime() public onFork {
        uint64 observedAt = uint64(block.timestamp - 6 hours);
        IAttestationOracle.AttestationInput memory a =
            _input(112, IAttestationOracle.AttestationKind.AssignmentExecuted, keccak256("audit"), observedAt, 1 hours);
        bytes32 d = oracle.attestationDigest(a);

        vm.expectEmit(true, true, true, true, address(oracle));
        emit IAttestationOracle.Attested(
            112, IAttestationOracle.AttestationKind.AssignmentExecuted, attesterA, uint64(block.timestamp)
        );
        vm.expectEmit(true, true, false, true, address(oracle));
        emit IAttestationOracle.AttestationSatisfied(
            112, IAttestationOracle.AttestationKind.AssignmentExecuted, keccak256("audit"), observedAt
        );
        oracle.attest(a, _one(PK1, d));

        (, uint64 recordedAsOf,) = oracle.latestPayload(112, IAttestationOracle.AttestationKind.AssignmentExecuted);
        assertEq(recordedAsOf, observedAt, "the record keeps the OBSERVATION time");
        assertEq(recordedAsOf, uint64(block.timestamp) - 6 hours, "which is 6h before submission");
        assertTrue(recordedAsOf != uint64(block.timestamp), "and is NOT the submission time");
    }

    /// @notice `asOf` bounds: zero is refused, a FUTURE observation is refused, and `asOf ==
    ///         block.timestamp` is the accepted boundary.
    function test_fork_asOfBounds() public onFork {
        IAttestationOracle.AttestationInput memory zeroAsOf =
            _input(113, IAttestationOracle.AttestationKind.UCCFiled, keccak256("z"), 0, 1 hours);
        bytes32 d0 = oracle.attestationDigest(zeroAsOf);
        bytes[] memory s0 = _one(PK1, d0);
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_BadAsOf.selector, uint64(0)));
        oracle.attest(zeroAsOf, s0);

        uint64 future = uint64(block.timestamp + 1);
        IAttestationOracle.AttestationInput memory futureAsOf =
            _input(113, IAttestationOracle.AttestationKind.UCCFiled, keccak256("f"), future, 1 hours);
        bytes32 d1 = oracle.attestationDigest(futureAsOf);
        bytes[] memory s1 = _one(PK1, d1);
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_BadAsOf.selector, future));
        oracle.attest(futureAsOf, s1);

        uint64 nowAsOf = uint64(block.timestamp);
        IAttestationOracle.AttestationInput memory boundary =
            _input(113, IAttestationOracle.AttestationKind.UCCFiled, keccak256("n"), nowAsOf, 1 hours);
        bytes32 d2 = oracle.attestationDigest(boundary);
        oracle.attest(boundary, _one(PK1, d2));
        (, uint64 recorded,) = oracle.latestPayload(113, IAttestationOracle.AttestationKind.UCCFiled);
        assertEq(recorded, nowAsOf, "asOf == now is the accepted boundary");
    }

    /// @notice Expiry is a hard submission deadline, checked FIRST — before the quorum count —
    ///         so an expired bundle can never be diagnosed as merely under-signed. `block
    ///         .timestamp == expiry` is still valid (the check is strictly greater-than).
    function test_fork_expiryIsEnforcedAndCheckedBeforeTheQuorum() public onFork {
        uint64 expired = uint64(block.timestamp - 1);
        IAttestationOracle.AttestationInput memory a = IAttestationOracle.AttestationInput({
            facilityId: 114,
            kind: IAttestationOracle.AttestationKind.Valuation,
            payload: bytes32(uint256(7e18)),
            asOf: uint64(block.timestamp),
            expiry: expired,
            nonce: _nextNonce()
        });
        bytes32 d = oracle.attestationDigest(a);
        bytes[] memory two = _sorted(PK1, PK2, d);
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_Expired.selector, expired));
        oracle.attest(a, two);

        // Expired AND under-quorum: expiry wins, proving the ordering.
        bytes[] memory one = _one(PK1, d);
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_Expired.selector, expired));
        oracle.attest(a, one);

        // expiry == now: still valid.
        IAttestationOracle.AttestationInput memory b = IAttestationOracle.AttestationInput({
            facilityId: 115,
            kind: IAttestationOracle.AttestationKind.Valuation,
            payload: bytes32(uint256(7e18)),
            asOf: uint64(block.timestamp),
            expiry: uint64(block.timestamp),
            nonce: _nextNonce()
        });
        bytes32 db = oracle.attestationDigest(b);
        oracle.attest(b, _sorted(PK1, PK2, db));
        assertTrue(oracle.isSatisfied(115, IAttestationOracle.AttestationKind.Valuation), "expiry==now accepted");
    }

    /// @notice A zero Valuation payload is refused, and the refusal does NOT burn the digest —
    ///         a malformed bundle cannot be used to grief a facility's nonce space.
    function test_fork_zeroValuationRefusedAndDoesNotBurnTheDigest() public onFork {
        IAttestationOracle.AttestationInput memory a =
            _input(116, IAttestationOracle.AttestationKind.Valuation, bytes32(0), uint64(block.timestamp), 1 hours);
        bytes32 d = oracle.attestationDigest(a);
        bytes[] memory sigs = _sorted(PK1, PK2, d);
        vm.expectRevert(IAttestationOracle.Oracle_ZeroValuation.selector);
        oracle.attest(a, sigs);

        assertFalse(oracle.digestUsed(d), "the refused bundle did not burn its digest");
        assertEq(oracle.valuationWatermark(116), 0, "and did not move the watermark");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5. GUARDIAN PAUSE
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The guardian pause halts SUBMISSIONS only. Reads and credit-layer consumption
    ///         keep working, so pausing the oracle cannot strand an already-attested value flow.
    function test_fork_guardianPauseHaltsSubmissionsButNotReadsOrConsume() public onFork {
        _grantCreditRoleToOps();
        uint64 asOf = uint64(block.timestamp);
        _submit(_input(117, IAttestationOracle.AttestationKind.PaymentReceived, keccak256("pay"), asOf, 1 hours));

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.GUARDIAN_ROLE)
        );
        oracle.pause();

        oracle.pause(); // ops == opsAdmin == guardian in this deploy shape
        assertTrue(oracle.paused(), "paused");

        IAttestationOracle.AttestationInput memory blocked =
            _input(118, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(1e18)), asOf, 1 hours);
        bytes32 d = oracle.attestationDigest(blocked);
        bytes[] memory sigs = _sorted(PK1, PK2, d);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        oracle.attest(blocked, sigs);

        // Reads are unaffected.
        assertTrue(oracle.isSatisfied(117, IAttestationOracle.AttestationKind.PaymentReceived), "read works");
        assertEq(oracle.threshold(IAttestationOracle.AttestationKind.Valuation), 2, "read works");
        assertEq(oracle.valuationWatermark(117), 0, "read works");

        // Consumption is deliberately NOT pausable.
        oracle.consume(117, IAttestationOracle.AttestationKind.PaymentReceived);
        assertFalse(oracle.isSatisfied(117, IAttestationOracle.AttestationKind.PaymentReceived), "consumed");

        oracle.unpause();
        assertFalse(oracle.paused(), "unpaused");
        oracle.attest(blocked, sigs);
        assertTrue(oracle.isSatisfied(118, IAttestationOracle.AttestationKind.Valuation), "submissions resumed");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 6. REVOKE SEMANTICS
    // ─────────────────────────────────────────────────────────────────────

    /// @notice `revoke` clears the satisfied flag; for a Valuation it additionally ZEROES the
    ///         mark (so nothing downstream keeps steering off a fact governance disowned),
    ///         while for every other kind the payload is RETAINED for audit.
    function test_fork_revokeSemanticsDifferForValuationAndDocumentaryKinds() public onFork {
        uint64 asOf = uint64(block.timestamp);
        _submit(_input(119, IAttestationOracle.AttestationKind.UCCFiled, keccak256("ucc"), asOf, 1 hours));

        vm.expectEmit(true, true, false, false, address(oracle));
        emit IAttestationOracle.AttestationRevoked(119, IAttestationOracle.AttestationKind.UCCFiled);
        oracle.revoke(119, IAttestationOracle.AttestationKind.UCCFiled);

        (bytes32 p, uint64 t, bool sat) = oracle.latestPayload(119, IAttestationOracle.AttestationKind.UCCFiled);
        assertEq(p, keccak256("ucc"), "documentary payload RETAINED after revoke");
        assertEq(t, asOf, "documentary asOf RETAINED after revoke");
        assertFalse(sat, "but not satisfied");

        // A documentary record with a retained payload can be revoked again (idempotent).
        oracle.revoke(119, IAttestationOracle.AttestationKind.UCCFiled);

        _submit(_input(119, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(4_000e18)), asOf, 1 hours));
        oracle.revoke(119, IAttestationOracle.AttestationKind.Valuation);
        (uint256 v, uint64 vAsOf) = oracle.latestValuation(119);
        assertEq(v, 0, "revoked Valuation is ZEROED");
        assertEq(vAsOf, 0, "revoked Valuation asOf is ZEROED");

        // ...and, being fully zeroed, it cannot be revoked a second time.
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_NotSatisfied.selector,
                uint256(119),
                IAttestationOracle.AttestationKind.Valuation
            )
        );
        oracle.revoke(119, IAttestationOracle.AttestationKind.Valuation);
    }

    /// @notice `revoke` on a never-attested fact reverts, and is DEFAULT_ADMIN-only.
    function test_fork_revokeGuards() public onFork {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_NotSatisfied.selector,
                uint256(120),
                IAttestationOracle.AttestationKind.CreditIssued
            )
        );
        oracle.revoke(120, IAttestationOracle.AttestationKind.CreditIssued);

        _submit(
            _input(
                120, IAttestationOracle.AttestationKind.CreditIssued, keccak256("c"), uint64(block.timestamp), 1 hours
            )
        );
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0))
        );
        oracle.revoke(120, IAttestationOracle.AttestationKind.CreditIssued);
        assertTrue(oracle.isSatisfied(120, IAttestationOracle.AttestationKind.CreditIssued), "still satisfied");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 7. H-02 — THE VALUATION HIGH-WATERMARK
    // ─────────────────────────────────────────────────────────────────────

    /// @notice H-02 CORE. The watermark survives `revoke`: after governance zeroes a bad mark,
    ///         an OLDER but perfectly-signed mark still cannot be installed. Before the fix,
    ///         `revoke` reset the comparison basis (the live record) to zero, so the instant
    ///         governance disowned a bad mark ANY stale mark could be replayed straight into
    ///         `ReserveManager.totalBackingValue()`.
    function test_fork_H02_watermarkSurvivesRevokeAndOlderMarkCannotBeReplayed() public onFork {
        uint256 fid = 121;
        _warp(10 days); // headroom so strictly-older observation times exist
        uint64 t1 = uint64(block.timestamp);

        _submit(_input(fid, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(3_000_000e18)), t1, 1 hours));
        assertEq(oracle.valuationWatermark(fid), t1, "watermark set to the accepted asOf");

        oracle.revoke(fid, IAttestationOracle.AttestationKind.Valuation);
        {
            (uint256 v, uint64 asOf) = oracle.latestValuation(fid);
            assertEq(v, 0, "live mark zeroed");
            assertEq(asOf, 0, "live asOf zeroed");
        }
        assertEq(oracle.valuationWatermark(fid), t1, "WATERMARK SURVIVED THE REVOKE");

        // A strictly older, freshly-signed, never-before-submitted bundle: refused.
        _assertValuationRejectedAsStale(fid, 9_000_000e18, t1 - 1, t1);

        // Equal asOf is refused too — the rule is STRICTLY increasing.
        _assertValuationRejectedAsStale(fid, 9_000_000e18, t1, t1);

        // A strictly newer mark is accepted and advances the watermark.
        _warp(1 hours);
        uint64 t2 = uint64(block.timestamp);
        _submit(_input(fid, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(2_500_000e18)), t2, 1 hours));
        {
            (uint256 v2, uint64 asOf2) = oracle.latestValuation(fid);
            assertEq(v2, 2_500_000e18, "fresh mark installed");
            assertEq(asOf2, t2, "at the new observation time");
        }
        assertEq(oracle.valuationWatermark(fid), t2, "watermark advanced");
    }

    /// @notice H-02. The watermark also survives `consume` — the credit layer spending a fact
    ///         must not reopen the rollback window either.
    function test_fork_H02_watermarkSurvivesConsume() public onFork {
        _grantCreditRoleToOps();
        uint256 fid = 122;
        _warp(10 days);
        uint64 t1 = uint64(block.timestamp);
        _submit(_input(fid, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(1_000e18)), t1, 1 hours));
        assertEq(oracle.valuationWatermark(fid), t1, "watermark set");

        oracle.consume(fid, IAttestationOracle.AttestationKind.Valuation);
        (bytes32 p, uint64 keptAsOf, bool sat) = oracle.latestPayload(fid, IAttestationOracle.AttestationKind.Valuation);
        assertEq(p, bytes32(uint256(1_000e18)), "consume retains the payload");
        assertEq(keptAsOf, t1, "consume retains asOf");
        assertFalse(sat, "consumed");
        assertEq(oracle.valuationWatermark(fid), t1, "WATERMARK SURVIVED THE CONSUME");

        _assertValuationRejectedAsStale(fid, 8_000e18, t1 - 100, t1);
    }

    /// @notice H-02. The watermark is MONOTONIC across a run of marks: it tracks the maximum
    ///         accepted `asOf`, and once advanced, nothing in between can be back-filled.
    function test_fork_H02_watermarkIsMonotonicAcrossManyMarks() public onFork {
        uint256 fid = 123;
        _warp(10 days);
        uint64 t1 = uint64(block.timestamp);
        _submit(_input(fid, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(1e18)), t1, 1 hours));
        assertEq(oracle.valuationWatermark(fid), t1, "wm 1");

        _warp(1 days);
        uint64 t2 = uint64(block.timestamp);
        _submit(_input(fid, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(2e18)), t2, 1 hours));
        assertEq(oracle.valuationWatermark(fid), t2, "wm 2");

        _warp(1 days);
        uint64 t3 = uint64(block.timestamp);
        _submit(_input(fid, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(3e18)), t3, 1 hours));
        assertEq(oracle.valuationWatermark(fid), t3, "wm 3");

        // A mark observed BETWEEN t2 and t3 can never be back-filled.
        uint64 between = t2 + 100;
        _assertValuationRejectedAsStale(fid, 99e18, between, t3);

        (uint256 v,) = oracle.latestValuation(fid);
        assertEq(v, 3e18, "the newest mark still stands");
    }

    /// @notice H-02. `asOf` may never exceed `block.timestamp`, so the watermark can never be
    ///         pushed into the future by ANY bundle. This bounds the worst reachable poisoning to
    ///         the current block time: there is NO reachable "far-future" stuck watermark, which is
    ///         why no dedicated recovery lever is needed (owner decision 2026-07-22 removed the
    ///         `resetValuationWatermark` lever; the rare stuck case is a timelocked UUPS upgrade).
    function test_fork_H02_watermarkCanNeverBePushedIntoTheFuture() public onFork {
        uint256 fid = 127;
        uint64 future = uint64(block.timestamp + 3650 days);
        IAttestationOracle.AttestationInput memory a = _input(
            fid, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(1e18)), future, 3650 days + 1 days
        );
        bytes32 d = oracle.attestationDigest(a);
        bytes[] memory sigs = _sorted(PK1, PK2, d);
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_BadAsOf.selector, future));
        oracle.attest(a, sigs);
        assertEq(oracle.valuationWatermark(fid), 0, "no future watermark reachable");

        // The maximum reachable watermark is exactly the current block time.
        uint64 nowTs = uint64(block.timestamp);
        _submit(_input(fid, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(1e18)), nowTs, 1 hours));
        assertEq(oracle.valuationWatermark(fid), nowTs, "watermark capped at block.timestamp");
        assertLe(oracle.valuationWatermark(fid), uint64(block.timestamp), "never ahead of the chain");
    }

    // ─────────────────────────────────────────────────────────────────────

    /// @notice The attested mark IS the origination bound for a marked-to-market class: the
    ///         draw is capped at `value * ltv`, a missing mark blocks origination outright, and
    ///         a mark older than the class's `maxMarkAge` blocks it too.
    function test_fork_markedToMarketOriginationIsBoundedByTheAttestedMark() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        uint256 id = bridge.totalOriginated() + 1;
        uint256 markValue = 1_000_000e18;

        // No mark at all → refused. NOTE the ORDER: `Valuation` is in class 5's required-mint
        // mask, so the mask gate fires FIRST and the freshness gate is never reached with a
        // zero asOf. `Bridge_ValuationStale(_, 0, _)` is therefore unreachable at origination
        // for any class whose mask includes Valuation — a fact worth pinning, since a reader of
        // ClaimBridge.originate would assume the `asOf == 0` branch is the missing-mark path.
        _attest(id, IAttestationOracle.AttestationKind.AssignmentExecuted, keccak256("assign"));
        uint64 daMaturity1 = uint64(block.timestamp + 300 days);
        _attestDaTerms(id, keccak256("DA-BORROWER"), 500_000e18, daMaturity1, keccak256("da-ref"));
        ClaimBridge.OriginationTerms memory terms1 =
            _daTerms(keccak256("DA-BORROWER"), 500_000e18, daMaturity1, keccak256("da-ref"));
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimBridge.Bridge_AttestationMissing.selector,
                Config.CLASS_DIGITAL_ASSETS,
                IAttestationOracle.AttestationKind.Valuation
            )
        );
        bridge.originate(ops, terms1);

        // With a mark: the draw is capped at value * ltvBps / BPS == 500_000e18.
        _attest(id, IAttestationOracle.AttestationKind.Valuation, bytes32(markValue));
        uint64 daMaturity2 = uint64(block.timestamp + 300 days);
        _attestDaTerms(id, keccak256("DA-BORROWER"), 500_001e18, daMaturity2, keccak256("da-ref"));
        ClaimBridge.OriginationTerms memory terms2 =
            _daTerms(keccak256("DA-BORROWER"), 500_001e18, daMaturity2, keccak256("da-ref"));
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_LtvExceedsValue.selector, 500_001e18, 500_000e18));
        bridge.originate(ops, terms2);

        // Aging the mark past the class bound blocks origination.
        uint64 markAsOf = uint64(block.timestamp);
        _warp(1 days + 1);
        uint64 daMaturity3 = uint64(block.timestamp + 300 days);
        _attestDaTerms(id, keccak256("DA-BORROWER"), 500_000e18, daMaturity3, keccak256("da-ref"));
        ClaimBridge.OriginationTerms memory terms3 =
            _daTerms(keccak256("DA-BORROWER"), 500_000e18, daMaturity3, keccak256("da-ref"));
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(ClaimBridge.Bridge_ValuationStale.selector, uint256(0), markAsOf, uint64(1 days))
        );
        bridge.originate(ops, terms3);

        // A governance REVOKE of the mark also blocks origination (via the mask gate).
        oracle.revoke(id, IAttestationOracle.AttestationKind.Valuation);
        uint64 daMaturity4 = uint64(block.timestamp + 300 days);
        _attestDaTerms(id, keccak256("DA-BORROWER"), 500_000e18, daMaturity4, keccak256("da-ref"));
        ClaimBridge.OriginationTerms memory terms4 =
            _daTerms(keccak256("DA-BORROWER"), 500_000e18, daMaturity4, keccak256("da-ref"));
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimBridge.Bridge_AttestationMissing.selector,
                Config.CLASS_DIGITAL_ASSETS,
                IAttestationOracle.AttestationKind.Valuation
            )
        );
        bridge.originate(ops, terms4);

        // A fresh mark (which must beat the H-02 watermark, and does) re-opens it, and the
        // exact bound is accepted.
        _attest(id, IAttestationOracle.AttestationKind.Valuation, bytes32(markValue));
        uint64 daMaturity5 = uint64(block.timestamp + 300 days);
        _attestDaTerms(id, keccak256("DA-BORROWER"), 500_000e18, daMaturity5, keccak256("da-ref"));
        ClaimBridge.OriginationTerms memory terms5 =
            _daTerms(keccak256("DA-BORROWER"), 500_000e18, daMaturity5, keccak256("da-ref"));
        vm.prank(ops);
        uint256 minted = bridge.originate(ops, terms5);
        assertEq(minted, id, "facility minted at the exact value bound");
    }

    /// @dev AUDIT FIX (H-4): the CreditIssued quorum committing to a digital-assets facility's
    ///      exact terms. Kept separate from the `originate` call so the cheatcodes on the next
    ///      line (`vm.prank` / `vm.expectRevert`) still target the origination itself.
    function _attestDaTerms(uint256 facilityId, bytes32 borrowerId, uint256 principal, uint64 maturity, bytes32 ref)
        private
    {
        bytes32 want = bridge.creditTermsHash(_daTerms(borrowerId, principal, maturity, ref));
        // Re-signing an identical bundle in the same block would hit the oracle's replay guard
        // (`Oracle_DigestAlreadyUsed`); if the quorum already stands on these terms, leave it.
        (bytes32 have,, bool standing) =
            oracle.latestPayload(facilityId, IAttestationOracle.AttestationKind.CreditIssued);
        if (standing && have == want) return;
        _attest(facilityId, IAttestationOracle.AttestationKind.CreditIssued, want);
    }

    function _daTerms(bytes32 borrowerId, uint256 principal, uint64 maturity, bytes32 ref)
        private
        view
        returns (ClaimBridge.OriginationTerms memory)
    {
        return _forkTermsFor(
            Config.CLASS_DIGITAL_ASSETS, borrowerId, keccak256("US-NY"), principal, 5000, 1000, maturity, ref
        );
    }

    /// @notice The margin path runs entirely off the attested mark: LTV is computed from it,
    ///         and a governance REVOKE of the mark blocks margin call / liquidation / cure with
    ///         `DefaultManager_NoValuation` rather than acting on a disowned number.
    function test_fork_marginPathReadsTheAttestedMarkAndStopsWhenItIsRevoked() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        uint256 id = bridge.totalOriginated() + 1;

        _attest(id, IAttestationOracle.AttestationKind.AssignmentExecuted, keccak256("assign"));
        _attest(id, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(1_000_000e18)));
        uint64 daMaturity6 = uint64(block.timestamp + 300 days);
        _attestDaTerms(id, keccak256("DA-BORROWER-2"), 400_000e18, daMaturity6, keccak256("da-ref-2"));
        vm.prank(ops);
        bridge.originate(ops, _daTerms(keccak256("DA-BORROWER-2"), 400_000e18, daMaturity6, keccak256("da-ref-2")));
        vm.prank(ops);
        waterfall.fund(id, 400_000e6);
        assertEq(reserves.deployedTo(id), 400_000e18, "full principal is the outstanding (fee capitalized)");

        // LTV off the mark: 400k / 1.0m = 4000bps, below the 6500bps trigger.
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_ThresholdNotBreached.selector, id, uint256(4000), uint256(6500)
            )
        );
        defaultManager.marginCall(id);

        // Mark the collateral down; the SAME loan now breaches. 400k / 600k = 6666bps.
        _warp(1);
        _attest(id, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(600_000e18)));
        defaultManager.marginCall(id);

        // Governance disowns the mark: the margin path stops dead rather than guessing.
        uint64 markedAsOf = uint64(block.timestamp);
        oracle.revoke(id, IAttestationOracle.AttestationKind.Valuation);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NoValuation.selector, id));
        defaultManager.liquidate(id);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NoValuation.selector, id));
        defaultManager.clearMarginCall(id);

        // And the H-02 watermark survived on a live credit facility: the pre-markdown mark
        // (which would have CLEARED the margin call) cannot be replayed.
        assertEq(oracle.valuationWatermark(id), markedAsOf, "watermark survived on a funded facility");
        IAttestationOracle.AttestationInput memory rollback = _input(
            id, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(1_000_000e18)), markedAsOf - 1, 1 hours
        );
        bytes32 d = oracle.attestationDigest(rollback);
        bytes[] memory sigs = _sorted(PK1, PK2, d);
        vm.expectRevert(
            abi.encodeWithSelector(IAttestationOracle.Oracle_StaleValuation.selector, markedAsOf - 1, markedAsOf)
        );
        oracle.attest(rollback, sigs);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 10. UPGRADE SAFETY (the watermark lives in the proxy, not the impl)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The oracle proxy is UPGRADER_ROLE-gated (held by the timelock on this deploy),
    ///         `initialize` cannot be replayed, and — the part that matters for H-02 — the
    ///         valuation watermark, the records and the thresholds all SURVIVE an
    ///         implementation upgrade, because they live in the namespaced proxy storage.
    function test_fork_upgradeIsGatedAndTheWatermarkSurvivesIt() public onFork {
        assertTrue(oracle.hasRole(Roles.UPGRADER_ROLE, timelock), "the timelock is the upgrade authority");
        assertFalse(oracle.hasRole(Roles.UPGRADER_ROLE, ops), "the operator is NOT");

        uint256 fid = 129;
        uint64 asOf = uint64(block.timestamp);
        _submit(_input(fid, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(1_234e18)), asOf, 1 hours));
        oracle.setThreshold(IAttestationOracle.AttestationKind.AssignmentExecuted, 2);

        address newImpl = address(new AttestationOracle());
        _assertOracleUpgradeRejected(carol, newImpl);
        _assertOracleUpgradeRejected(ops, newImpl);
        _assertOracleCannotReinitialize();

        vm.prank(timelock);
        oracle.upgradeToAndCall(newImpl, "");

        assertEq(oracle.valuationWatermark(fid), asOf, "WATERMARK SURVIVED THE UPGRADE");
        {
            (uint256 v, uint64 a) = oracle.latestValuation(fid);
            assertEq(v, 1_234e18, "record survived");
            assertEq(a, asOf, "record asOf survived");
        }
        assertEq(oracle.threshold(IAttestationOracle.AttestationKind.AssignmentExecuted), 2, "threshold survived");
        assertEq(oracle.threshold(IAttestationOracle.AttestationKind.Valuation), 2, "2-of-n floor survived");
        assertTrue(oracle.hasRole(Roles.ATTESTER_ROLE, attesterA), "attester set survived");

        // And the anti-rollback rule still binds after the upgrade.
        _assertOlderValuationRejected(fid, asOf);
    }

    /// @dev Small frames keep the fork regression compilable under coverage instrumentation,
    ///      whose source probes add stack pressure that production compilation does not have.
    function _assertOracleUpgradeRejected(address caller, address newImpl) private {
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, caller, Roles.UPGRADER_ROLE
            )
        );
        oracle.upgradeToAndCall(newImpl, "");
    }

    function _assertOracleCannotReinitialize() private {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        oracle.initialize(carol, carol, carol);
    }

    function _assertOlderValuationRejected(uint256 fid, uint64 asOf) private {
        _assertValuationRejectedAsStale(fid, 9e18, asOf - 1, asOf);
    }

    function _assertValuationRejectedAsStale(uint256 facilityId, uint256 value, uint64 attemptedAsOf, uint64 watermark)
        private
    {
        IAttestationOracle.AttestationInput memory candidate =
            _input(facilityId, IAttestationOracle.AttestationKind.Valuation, bytes32(value), attemptedAsOf, 1 hours);
        bytes32 digest = oracle.attestationDigest(candidate);
        bytes[] memory sigs = _sorted(PK1, PK2, digest);
        assertFalse(oracle.digestUsed(digest), "a genuinely NEW bundle, not a replay");
        vm.expectRevert(
            abi.encodeWithSelector(IAttestationOracle.Oracle_StaleValuation.selector, attemptedAsOf, watermark)
        );
        oracle.attest(candidate, sigs);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Local helpers (see the FIXTURE CAPABILITIES note on the contract)
    // ─────────────────────────────────────────────────────────────────────

    function _nextNonce() private returns (uint256) {
        return uint256(keccak256(abi.encode("oracle-fork-nonce", ++_nonceCounter, block.timestamp)));
    }

    function _input(
        uint256 facilityId,
        IAttestationOracle.AttestationKind kind,
        bytes32 payload,
        uint64 asOf,
        uint64 ttl
    ) private returns (IAttestationOracle.AttestationInput memory) {
        return IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: kind,
            payload: payload,
            asOf: asOf,
            expiry: uint64(block.timestamp) + ttl,
            nonce: _nextNonce()
        });
    }

    function _sig(uint256 pk, bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _one(uint256 pk, bytes32 digest) private pure returns (bytes[] memory sigs) {
        sigs = new bytes[](1);
        sigs[0] = _sig(pk, digest);
    }

    /// @dev Two signatures sorted ascending by recovered signer address, as the oracle demands.
    function _sorted(uint256 pkA, uint256 pkB, bytes32 digest) private pure returns (bytes[] memory sigs) {
        (uint256 lo, uint256 hi) = vm.addr(pkA) < vm.addr(pkB) ? (pkA, pkB) : (pkB, pkA);
        sigs = new bytes[](2);
        sigs[0] = _sig(lo, digest);
        sigs[1] = _sig(hi, digest);
    }

    /// @dev The two attester keys ordered by address (low first).
    function _lowHigh() private pure returns (uint256 loPk, uint256 hiPk) {
        (loPk, hiPk) = vm.addr(PK1) < vm.addr(PK2) ? (PK1, PK2) : (PK2, PK1);
    }

    /// @dev Submit a correct quorum bundle; returns the burned digest.
    function _submit(IAttestationOracle.AttestationInput memory a) private returns (bytes32 digest) {
        digest = oracle.attestationDigest(a);
        oracle.attest(a, _sorted(PK1, PK2, digest));
    }

    /// @dev An independent recomputation of the EIP-712 digest (never reuses oracle code).
    function _digestFor(IAttestationOracle.AttestationInput memory a, uint256 chainId, address verifying)
        private
        pure
        returns (bytes32)
    {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(DOMAIN_NAME)),
                keccak256(bytes(DOMAIN_VERSION)),
                chainId,
                verifying
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(ATTESTATION_TYPEHASH, a.facilityId, uint8(a.kind), a.payload, a.asOf, a.expiry, a.nonce)
        );
        return keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
    }

    /// @dev FIXTURE CAPABILITY ADDED LOCALLY: CREDIT_ROLE on the oracle for `ops`, so `consume`
    ///      can be driven directly. Granted by the DEFAULT_ADMIN the fixture retains; in
    ///      production only the WaterfallEngine holds it.
    function _grantCreditRoleToOps() private {
        oracle.grantRole(Roles.CREDIT_ROLE, ops);
    }
}
