// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {CommitmentLedger} from "../../src/CommitmentLedger.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @title ATK_CommitmentLedgerFork — adversarial assault on the live-event conservative-cascade
///        ledger, on a pinned mainnet fork against the REAL deploy-script topology and REAL USDC.
///
/// @notice CommitmentLedger holds no funds but it is the source of truth for how much sGROVE
///         layer-2 coverage each declared default has already consumed. If an outsider could
///         either (a) drive its one permissionless entry point `coverDelegate` to forge a
///         coverage delta, (b) reach any `onlyManager` mutator to inject or double-count a row,
///         or (c) swap the ledger out from under the DefaultManager while it holds consumed
///         coverage, the three-layer loss cascade (CLAUDE.md §1.3) would be corruptible without
///         ever touching a privileged role. This suite ATTEMPTS each of those and pins the
///         outcome — the specific custom error when the contract holds, the violated state if it
///         does not.
///
///         Invariants under attack:
///           - a default event registers exactly once;
///           - consumed coverage cannot be forged or double-counted from outside the manager;
///           - migration is safe (blocked) while consumed coverage / live rows are outstanding.
///
/// @dev The ledger is deployed by the DefaultManager's factory at init and is reachable through
///      `defaultManager.modules()`. Its `manager` immutable is the DefaultManager proxy; a direct
///      call therefore has `address(this) == ledger != manager`, which is the whole defense the
///      permissionless surface leans on. Nothing here broadcasts (CLAUDE.md prime directive 1).
contract ATK_CommitmentLedgerForkTest is ForkLifecycleFixture {
    // ─────────────────────────────────────────────────────────────────────
    // 1. PERMISSIONLESS ENTRY: coverDelegate cannot be reached by any caller
    // ─────────────────────────────────────────────────────────────────────

    /// @notice `coverDelegate` is the only permissionless function. An adversary aims a real
    ///         coverage draw (and then attacker-chosen backstop/asset targets) straight at it to
    ///         forge a `covered` return the manager would trust. Every direct call — adversary or
    ///         privileged operator — must revert `CommitmentLedger_DirectCall` before any backstop
    ///         is consulted, because only the manager's delegatecall context satisfies the guard.
    function test_atk_directCoverDelegate_permissionless_isBlocked() public onFork {
        CommitmentLedger ledger = _ledger();
        assertEq(ledger.manager(), address(defaultManager), "ledger is bound to the manager proxy");

        // (a) adversary points the real sGROVE backstop + real USDfr at the entry point.
        vm.prank(carol);
        vm.expectRevert(CommitmentLedger.CommitmentLedger_DirectCall.selector);
        ledger.coverDelegate(address(sGrove), address(usdfr), 1, 1_000e18);

        // (b) self-chosen inputs: an attacker-controlled backstop, asset, and max residual are
        //     rejected identically — the guard trusts nothing the caller supplies.
        address hostileBackstop = makeAddr("hostileBackstop");
        address hostileAsset = makeAddr("hostileAsset");
        vm.prank(carol);
        vm.expectRevert(CommitmentLedger.CommitmentLedger_DirectCall.selector);
        ledger.coverDelegate(hostileBackstop, hostileAsset, 999, type(uint256).max);

        // (c) a privileged role holder (ops: SERVICER + DEFAULT_ADMIN on the manager) fares no
        //     better — role power is irrelevant, only the delegatecall context matters.
        vm.prank(ops);
        vm.expectRevert(CommitmentLedger.CommitmentLedger_DirectCall.selector);
        ledger.coverDelegate(address(sGrove), address(usdfr), 1, 1_000e18);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. GATED MUTATORS: no external actor can write ledger state directly
    // ─────────────────────────────────────────────────────────────────────

    /// @notice register / sync / updatePrincipal / release are `onlyManager`. This is what makes
    ///         "registers once" and "coverage cannot be double-counted" unforgeable: an adversary
    ///         cannot inject a duplicate row, inflate `consumed`, or terminally release a live row.
    ///         A privileged operator (ops) is refused as well — the binding is to the manager, not
    ///         to any role.
    function test_atk_ledgerStateMutators_onlyManager() public onFork {
        CommitmentLedger ledger = _ledger();
        bytes memory notMgrCarol = abi.encodeWithSelector(CommitmentLedger.CommitmentLedger_NotManager.selector, carol);

        vm.prank(carol);
        vm.expectRevert(notMgrCarol);
        ledger.register(42, Config.CLASS_FILM_TAX_CREDITS, 1_000e18);

        vm.prank(carol);
        vm.expectRevert(notMgrCarol);
        ledger.sync(42, 1_000e18, 1_000e18, 500e18);

        vm.prank(carol);
        vm.expectRevert(notMgrCarol);
        ledger.updatePrincipal(42, 1e18);

        vm.prank(carol);
        vm.expectRevert(notMgrCarol);
        ledger.release(42);

        // ops holds DEFAULT_ADMIN + SERVICER on the manager, yet still cannot poke the ledger.
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(CommitmentLedger.CommitmentLedger_NotManager.selector, ops));
        ledger.register(43, Config.CLASS_FILM_TAX_CREDITS, 1_000e18);

        assertEq(ledger.eventCount(), 0, "no row was ever created by any external caller");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. REGISTERS ONCE: a declared default produces exactly one ledger row
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Drive a real default through the full m-of-n mint gate + funding + declaration,
    ///         then attack the "registers exactly once" invariant from both sides: the manager
    ///         path must refuse to re-declare a defaulted facility (no second row), and an
    ///         adversary must not be able to inject a duplicate row directly.
    ///
    ///         Post-deployment pin (commit 456ae25, Corrovera finding R167). `declareDefault`
    ///         leaves the DefaultDeclared fact STANDING rather than consuming it
    ///         (`DefaultManager.declareDefault` NatSpec: "The attestation stays standing (not
    ///         consumed)"), so the oracle's pending-action rule refuses a SECOND DefaultDeclared
    ///         bundle for the facility with `Oracle_UnconsumedFact(id, DefaultDeclared, <standing
    ///         payload>)` before any manager code runs. Specified by:
    ///           - `IAttestationOracle.Oracle_UnconsumedFact` NatSpec: "Process or revoke the
    ///             current action before submitting another of the same kind";
    ///           - `AttestationOracle.attest`: "A second action must not strand an accepted
    ///             payment, loss or servicing approval";
    ///           - `audit-reports/corrovera-dual-chain-2026-09-13/corrovera-ensemble/
    ///             SUPPORTED-FINDINGS.md`, R167 ("Superseded one-shot facts are permanently
    ///             stranded"), suggested direction: "prevent a same-kind attest from overwriting
    ///             a still-satisfied record before it is consumed";
    ///           - `docs/remediation/ACCRUAL_BUILD_LOG_2026-09-12.md`, entry "2026-09-14,
    ///             Feedback correction: replay lifecycle coverage (ETH)": fixtures that
    ///             "attempted to replace a pending action after R167 correctly prohibited that
    ///             transition" are repaired by retiring the action through the valid lifecycle.
    ///         The manager gate is still reached twice with a `consumeExact`-satisfying fact:
    ///         once with the STANDING fact (replay probe), and once with a fresh fact after
    ///         governance `revoke`, the only retirement for this kind. Both must be refused
    ///         `DefaultManager_NotDefaultable` and the ledger must hold exactly one row.
    function test_atk_defaultRegistersExactlyOnce() public onFork {
        CommitmentLedger ledger = _ledger();
        uint256 principal = 1_000_000e18;

        _mintFromUSDC(alice, 2_000_000e6); // seed idle reserves so the facility can be funded
        assertEq(ledger.eventCount(), 0, "no rows before any default");

        uint256 id = _originateAndFund(principal);
        _declareDefault(id, keccak256("atk-evidence-1"));

        // Registered EXACTLY once, with the real class and captured outstanding principal.
        assertEq(ledger.eventCount(), 1, "one declared default -> one ledger row");
        assertEq(ledger.eventAt(0), id, "the row is this facility");
        (uint256 classId, bool drawn,, uint256 remainingPrincipal) = ledger.eventInfo(id);
        assertEq(classId, Config.CLASS_FILM_TAX_CREDITS, "class recorded on the row");
        assertFalse(drawn, "not drawn before any layer-2 coverage");
        assertEq(remainingPrincipal, principal, "outstanding principal captured");
        assertEq(ledger.consumed(id), 0, "no coverage consumed at declaration");

        // (1) `declareDefault` leaves the DefaultDeclared fact STANDING by design (it is the
        //     on-chain record backing the remedy; DefaultManager.declareDefault NatSpec), so the
        //     oracle's pending-action rule (commit 456ae25, R167) refuses a SECOND DefaultDeclared
        //     fact for this facility before any manager code runs, naming the STANDING payload
        //     (not the submission). Both payloads are the manager's evidence binding,
        //     keccak256(abi.encode(tokenId, evidenceHash)), exactly as `_declareDefault` builds it.
        bytes32 firstPayload = keccak256(abi.encode(id, keccak256("atk-evidence-1")));
        bytes32 secondPayload = keccak256(abi.encode(id, keccak256("atk-evidence-2")));
        (bytes32 standingPayload,, bool standingSatisfied) =
            oracle.latestPayload(id, IAttestationOracle.AttestationKind.DefaultDeclared);
        assertTrue(standingSatisfied, "the declared fact is still standing after declareDefault");
        assertEq(standingPayload, firstPayload, "the standing record is the first evidence-bound fact");
        (IAttestationOracle.AttestationInput memory a2, bytes[] memory sigs2) =
            _signedBundle(id, IAttestationOracle.AttestationKind.DefaultDeclared, secondPayload);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_UnconsumedFact.selector,
                id,
                IAttestationOracle.AttestationKind.DefaultDeclared,
                firstPayload
            )
        );
        oracle.attest(a2, sigs2);

        // (1b) the standing fact is not a replay surface: it satisfies `consumeExact`, so this
        //      call reaches the manager's state gate, where the facility is Defaulted (terminal
        //      for `declareDefault`); re-presenting the SAME evidence is refused and no second
        //      row appears.
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotDefaultable.selector, id));
        defaultManager.declareDefault(id, keccak256("atk-evidence-1"));

        // (1c) once governance retires the pending action (the only retirement for this kind),
        //      the oracle accepts a second fact and the manager path STILL refuses to re-declare.
        vm.prank(ops);
        oracle.revoke(id, IAttestationOracle.AttestationKind.DefaultDeclared);
        _attest(id, IAttestationOracle.AttestationKind.DefaultDeclared, secondPayload);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotDefaultable.selector, id));
        defaultManager.declareDefault(id, keccak256("atk-evidence-2"));

        // (2) an adversary cannot inject a duplicate row directly either.
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(CommitmentLedger.CommitmentLedger_NotManager.selector, carol));
        ledger.register(id, Config.CLASS_FILM_TAX_CREDITS, principal);

        assertEq(ledger.eventCount(), 1, "still exactly one row after both duplicate attempts");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. MIGRATION SAFETY: the one-way ledger cannot be swapped while it holds
    //    consumed coverage / live rows
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Bring the ledger into a state with genuinely CONSUMED layer-2 coverage (declare a
    ///         default, fund sGROVE, realize a fully-covered loss), then attempt to migrate the
    ///         ledger. Both the legitimate admin (blocked by `CommitmentLedgerAlreadySet`, the
    ///         one-way guard) and an adversary (blocked at the role gate) must fail, and the
    ///         ledger + its consumed coverage must be left untouched.
    function test_atk_migrationBlockedWithConsumedCoverageOutstanding() public onFork {
        CommitmentLedger ledger = _ledger();
        uint256 principal = 1_000_000e18;
        uint256 loss = 100_000e18;

        _mintFromUSDC(alice, 2_000_000e6); // fundable idle reserves
        _stake(alice, 500_000e18); // senior principal exists (though this loss stays fully covered)
        _mintFromUSDC(ops, 500_000e6); // ops coverage capital

        uint256 id = _originateAndFund(principal);
        _declareDefault(id, keccak256("atk-mig-evidence"));

        // Fund layer 2 and realize a loss smaller than the reserve: fully covered by sGROVE, so
        // the ledger records genuine consumed coverage against a live row.
        _fundCoverage(ops, 500_000e18);
        _realizeLoss(id, loss, bytes32(0));

        assertEq(ledger.consumed(id), loss, "event consumed exactly the covered loss");
        assertEq(ledger.consumedAggregate(), loss, "aggregate consumption tracks it");
        (, bool drawn,,) = ledger.eventInfo(id);
        assertTrue(drawn, "event marked drawn after the layer-2 draw");

        address current = address(ledger);

        // (a) even the legitimate admin (ops keeps DEFAULT_ADMIN on the fork) is refused: the
        //     ledger is one-way and cannot be replaced while it holds consumed coverage.
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_CommitmentLedgerAlreadySet.selector, current)
        );
        defaultManager.initializeCommitmentLedger();

        // (b) an adversary is refused earlier still, at the role gate.
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, carol, defaultManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(carol);
        defaultManager.initializeCommitmentLedger();

        // Nothing moved: the ledger and its consumed coverage survive the blocked migration.
        (,,,,,,, address ledgerAfter) = defaultManager.modules();
        assertEq(ledgerAfter, current, "ledger address unchanged by the blocked migration");
        assertEq(CommitmentLedger(ledgerAfter).consumed(id), loss, "consumed coverage preserved");
    }

    // ─────────────────────────────────────────────────────────────────────
    // helpers (private to this suite; the shared fixture is not modified)
    // ─────────────────────────────────────────────────────────────────────

    /// @dev The live ledger the DefaultManager proxy deployed and owns.
    function _ledger() internal view returns (CommitmentLedger) {
        (,,,,,,, address ledgerAddr) = defaultManager.modules();
        return CommitmentLedger(ledgerAddr);
    }

    /// @dev A real 2-of-n EIP-712 bundle that is built and signed but NOT submitted, so an
    ///      oracle refusal can be wrapped in `vm.expectRevert` (the fixture's `_attest` submits
    ///      immediately, and its first external call is the `attestationDigest` view).
    ///      Signatures are sorted ascending by signer address, as the oracle enforces.
    function _signedBundle(uint256 facilityId, IAttestationOracle.AttestationKind kind, bytes32 payload)
        internal
        returns (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs)
    {
        a = IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: kind,
            payload: payload,
            asOf: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 1 hours),
            nonce: ++attestationNonce
        });
        bytes32 digest = oracle.attestationDigest(a);
        (uint256 lo, uint256 hi) = vm.addr(PK1) < vm.addr(PK2) ? (PK1, PK2) : (PK2, PK1);
        sigs = new bytes[](2);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(lo, digest);
        sigs[0] = abi.encodePacked(r, s, v);
        (v, r, s) = vm.sign(hi, digest);
        sigs[1] = abi.encodePacked(r, s, v);
    }

    /// @dev Post `amount` USDfr as sGROVE layer-2 coverage from `who`.
    function _fundCoverage(address who, uint256 amount) internal {
        vm.startPrank(who);
        usdfr.approve(address(sGrove), amount);
        sGrove.fundCoverage(amount);
        vm.stopPrank();
    }
}
