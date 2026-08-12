// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AttestationOracle} from "../../src/AttestationOracle.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {RealOracleFixture} from "../helpers/RealOracleFixture.sol";

/// @notice C4-01/C4-02: digest salt must not make a one-shot economic fact reusable.
contract FixC401FactReplaySurfaceTest is Test {
    AttestationOracle internal oracle;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal creditModule = makeAddr("creditModule");
    uint256 internal pk1 = 0xC401A;
    uint256 internal pk2 = 0xC401B;
    uint256 internal nonce;

    uint256 internal constant FACILITY = 77;
    bytes32 internal constant ROOT = 0xac9508c5303c175f6440d43a5e3eadcf5afa63ca3c359d94d58c5e5919cebf00;

    function setUp() public {
        vm.warp(1_750_000_000);
        oracle = AttestationOracle(
            address(
                new ERC1967Proxy(
                    address(new AttestationOracle()),
                    abi.encodeCall(AttestationOracle.initialize, (admin, guardian, admin))
                )
            )
        );
        vm.startPrank(admin);
        oracle.grantRole(Roles.ATTESTER_ROLE, vm.addr(pk1));
        oracle.grantRole(Roles.ATTESTER_ROLE, vm.addr(pk2));
        oracle.grantRole(Roles.CREDIT_ROLE, creditModule);
        vm.stopPrank();
    }

    function _input(IAttestationOracle.AttestationKind kind, bytes32 payload)
        internal
        returns (IAttestationOracle.AttestationInput memory a)
    {
        a = IAttestationOracle.AttestationInput({
            facilityId: FACILITY,
            kind: kind,
            payload: payload,
            asOf: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 1 hours),
            nonce: ++nonce
        });
    }

    function _bundle(IAttestationOracle.AttestationInput memory a) internal view returns (bytes[] memory sigs) {
        uint8 required = oracle.threshold(a.kind);
        (uint256 lo, uint256 hi) = vm.addr(pk1) < vm.addr(pk2) ? (pk1, pk2) : (pk2, pk1);
        sigs = new bytes[](required);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(lo, oracle.attestationDigest(a));
        sigs[0] = abi.encodePacked(r, s, v);
        if (required > 1) {
            (v, r, s) = vm.sign(hi, oracle.attestationDigest(a));
            sigs[1] = abi.encodePacked(r, s, v);
        }
    }

    function _eventKind(uint8 k) internal pure returns (IAttestationOracle.AttestationKind) {
        // All kinds except Valuation (index 5), which is a monotone observation series.
        return IAttestationOracle.AttestationKind(k < 5 ? k : k + 1);
    }

    /// @dev This is the load-bearing primary-ledger shape: the current record contains B,
    ///      so only the permanent ledger can remember that the older A was already realised.
    function test_supersededFactsRemainTerminalForEveryOneShotKind() public {
        for (uint8 k = 0; k < 8; ++k) {
            IAttestationOracle.AttestationKind kind = _eventKind(k);
            bytes32 payloadA = keccak256(abi.encode("fact-a", k));
            bytes32 payloadB = keccak256(abi.encode("fact-b", k));

            IAttestationOracle.AttestationInput memory a = _input(kind, payloadA);
            oracle.attest(a, _bundle(a));
            IAttestationOracle.AttestationInput memory b = _input(kind, payloadB);
            oracle.attest(b, _bundle(b));

            (bytes32 current,,) = oracle.latestPayload(FACILITY, kind);
            assertEq(current, payloadB, "precondition: A must be superseded");

            IAttestationOracle.AttestationInput memory replay = _input(kind, payloadA);
            bytes[] memory sigs = _bundle(replay);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAttestationOracle.Oracle_FactAlreadyRealised.selector,
                    oracle.factKey(FACILITY, kind, payloadA),
                    IAttestationOracle.FactStatus.Recorded
                )
            );
            oracle.attest(replay, sigs);
        }
    }

    function test_supersededConsumedFactRemainsTerminal() public {
        IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind.PaymentReceived;
        bytes32 consumed = keccak256("payment-11");
        IAttestationOracle.AttestationInput memory a = _input(kind, consumed);
        oracle.attest(a, _bundle(a));
        vm.prank(creditModule);
        oracle.consume(FACILITY, kind);

        bytes32 currentPayload = keccak256("payment-12");
        IAttestationOracle.AttestationInput memory b = _input(kind, currentPayload);
        oracle.attest(b, _bundle(b));
        IAttestationOracle.AttestationInput memory replay = _input(kind, consumed);
        bytes[] memory replaySigs = _bundle(replay);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_FactAlreadyRealised.selector,
                oracle.factKey(FACILITY, kind, consumed),
                IAttestationOracle.FactStatus.Consumed
            )
        );
        oracle.attest(replay, replaySigs);
    }

    function test_supersededRevokedFactRemainsTerminal() public {
        IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind.PaymentReceived;
        bytes32 currentPayload = keccak256("payment-12");
        IAttestationOracle.AttestationInput memory b = _input(kind, currentPayload);
        oracle.attest(b, _bundle(b));
        vm.prank(admin);
        oracle.revoke(FACILITY, kind);
        bytes32 afterRevocation = keccak256("payment-13");
        IAttestationOracle.AttestationInput memory c = _input(kind, afterRevocation);
        oracle.attest(c, _bundle(c));
        IAttestationOracle.AttestationInput memory replayRevoked = _input(kind, currentPayload);
        bytes[] memory revokedSigs = _bundle(replayRevoked);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_FactAlreadyRealised.selector,
                oracle.factKey(FACILITY, kind, currentPayload),
                IAttestationOracle.FactStatus.Revoked
            )
        );
        oracle.attest(replayRevoked, revokedSigs);
    }

    /// @dev Pins the separate in-place-upgrade shadow guard. Clearing the appended ledger
    ///      simulates a legacy proxy whose current record predates the upgrade.
    function test_legacyCurrentRecordStillBlocksReplayWhenAppendedLedgerIsEmpty() public {
        IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind.LossRealized;
        bytes32 payload = keccak256("legacy-loss");
        IAttestationOracle.AttestationInput memory a = _input(kind, payload);
        oracle.attest(a, _bundle(a));
        vm.prank(creditModule);
        oracle.consume(FACILITY, kind);

        bytes32 ledgerBase = bytes32(uint256(ROOT) + 4);
        bytes32 statusSlot = keccak256(abi.encode(oracle.factKey(FACILITY, kind, payload), ledgerBase));
        vm.store(address(oracle), statusSlot, bytes32(0));
        assertEq(uint256(oracle.factStatus(FACILITY, kind, payload)), uint256(IAttestationOracle.FactStatus.None));

        IAttestationOracle.AttestationInput memory replay = _input(kind, payload);
        bytes[] memory sigs = _bundle(replay);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_FactAlreadyRealised.selector,
                oracle.factKey(FACILITY, kind, payload),
                IAttestationOracle.FactStatus.Consumed
            )
        );
        oracle.attest(replay, sigs);
    }

    function test_valuationMayRepeatAValueAtANewerObservationTime() public {
        IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind.Valuation;
        bytes32 value = bytes32(uint256(750_000e18));
        IAttestationOracle.AttestationInput memory a = _input(kind, value);
        oracle.attest(a, _bundle(a));
        vm.warp(block.timestamp + 1 days);
        IAttestationOracle.AttestationInput memory b = _input(kind, value);
        oracle.attest(b, _bundle(b));
        assertEq(uint256(oracle.factStatus(FACILITY, kind, value)), uint256(IAttestationOracle.FactStatus.None));
        (, uint64 asOf) = oracle.latestValuation(FACILITY);
        assertEq(asOf, b.asOf);
    }
}

/// @notice Economic C4-01 regression: two real losses must never become three write-downs.
contract FixC401EconomicReplayTest is RealOracleFixture {
    uint256 internal constant PRINCIPAL = 2_000_000e18;
    uint256 internal constant LOSS = 300_000e18;
    bytes32 internal constant EVIDENCE_1 = keccak256("c4-01-tranche-1");
    bytes32 internal constant EVIDENCE_2 = keccak256("c4-01-tranche-2");

    function _seedSeniors(uint256 amount) internal {
        _mintUSDfrTo(alice, amount);
        vm.startPrank(alice);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();
    }

    function test_supersededLossFactCannotWriteDownPrincipalTwice() public {
        _seedSeniors(3_000_000e18);
        uint256 id = _liveFilmFacility(PRINCIPAL);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        uint256 outstandingBefore = reserves.deployedTo(id);
        _realizeLoss(id, LOSS, EVIDENCE_1);
        _realizeLoss(id, LOSS, EVIDENCE_2);
        uint256 outstandingAfter = reserves.deployedTo(id);
        uint256 vaultAfter = vault.totalAssets();
        assertEq(outstandingAfter, outstandingBefore - 2 * LOSS, "two events must produce two write-downs");

        bytes32 payload = keccak256(abi.encode(id, LOSS, EVIDENCE_1));
        IAttestationOracle.AttestationInput memory replay = IAttestationOracle.AttestationInput({
            facilityId: id,
            kind: IAttestationOracle.AttestationKind.LossRealized,
            payload: payload,
            asOf: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 1 hours),
            nonce: 0xC401
        });
        bytes[] memory sigs = _signedBundle(replay);
        (bool accepted,) = address(realOracle).call(abi.encodeCall(AttestationOracle.attest, (replay, sigs)));
        if (accepted) {
            vm.prank(servicer);
            defaultManager.realizeLoss(id, LOSS, EVIDENCE_1);
        }

        assertFalse(accepted, "a superseded loss fact was accepted under fresh digest salt");
        assertEq(reserves.deployedTo(id), outstandingAfter, "one economic loss was written down twice");
        assertEq(vault.totalAssets(), vaultAfter, "senior principal was burned twice for one loss");
    }

    /// @notice A signature nonce is transport salt, not an economic-event identifier.
    /// @dev The predecessor accepted zero evidence, so two legitimate equal tranches collided
    ///      in the durable fact ledger. Refuse that ambiguous schema at the value-moving edge.
    function test_lossRealizationRequiresAStableEconomicEventIdentifier() public {
        _seedSeniors(3_000_000e18);
        uint256 id = _liveFilmFacility(PRINCIPAL);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        _attestLoss(id, LOSS, bytes32(0));
        vm.prank(servicer);
        vm.expectRevert(IDefaultManager.DefaultManager_ZeroEvidenceHash.selector);
        defaultManager.realizeLoss(id, LOSS, bytes32(0));
    }
}
