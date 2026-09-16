// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title ATK_DefaultManagerFork — adversarial suite against `DefaultManager` on a pinned mainnet
///        fork, on the REAL deploy topology with REAL USDC and the REAL 2-of-n EIP-712 oracle.
///
/// @notice AUTHORISED assessment of the owner's own pre-audit code on a LOCAL fork. Nothing here
///         broadcasts or moves real value.
///
///         This is an ATTACK suite, not a documentation suite. Each test drives a hostile actor
///         (`carol` — no role, not even KYC'd) or an out-of-context privileged actor at a real
///         entry point and makes the outcome unambiguous: where the attack is BLOCKED, it asserts
///         the exact custom error; where an operation genuinely runs, it asserts the state the
///         attacker was trying to violate did NOT change.
///
///         Two invariants are the target (CLAUDE.md 1.3):
///           (I1) The loss cascade runs curator first-loss -> sGROVE backstop -> sUSDfr senior,
///                and can never be skipped, inverted, or reached by an unauthorised actor.
///           (I2) A single default/loss EVENT cannot double-consume junior coverage.
///
///         The permissionless surface (`markPastDue`, `marginCall`, `clearMarginCall`,
///         `liquidate`) is attacked hardest. `absorbReserveLoss` and `drawForSeniorExit` are
///         nominally external but caller-identity-gated; the tests reach them from hostile and
///         out-of-context callers and prove the gate holds while junior capital sits untouched.
contract ATK_DefaultManagerForkTest is ForkLifecycleFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS; // class 1, receivable

    // ─────────────────────────────────────────────────────────────────────
    // (I1) The junior-capital draw is unreachable by anyone but the controller
    // ─────────────────────────────────────────────────────────────────────

    /// @notice `drawForSeniorExit` burns curator first-loss AND the sGROVE reserve forward through
    ///         the cascade. If any address could call it, an adversary would drain both junior
    ///         layers on demand (the cascade run BACKWARDS). Prove the caller gate holds against a
    ///         hostile actor and against a privileged-but-wrong actor, and that the seeded junior
    ///         capital is EXACTLY untouched by the rejected calls.
    function test_attack_drawForSeniorExit_refusesEveryCallerButTheController() public onFork {
        _postFirstLossOps(500_000e18); // layer 1
        _fundCoverageOps(1_000_000e18); // layer 2
        assertEq(curator.poolBalance(FILM), 500_000e18, "precondition: layer 1 seeded");
        assertEq(sGrove.coverageReserve(), 1_000_000e18, "precondition: layer 2 seeded");

        // hostile actor: no role, not KYC'd.
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ExitDrawCallerNotController.selector, carol)
        );
        defaultManager.drawForSeniorExit(2_000_000e18);

        // even the deployer/servicer/admin is not the controller — caller identity, not a role.
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ExitDrawCallerNotController.selector, ops)
        );
        defaultManager.drawForSeniorExit(2_000_000e18);

        // The cascade could not be inverted: both junior layers sit exactly where they were.
        assertEq(curator.poolBalance(FILM), 500_000e18, "layer 1 untouched by the rejected draws");
        assertEq(sGrove.coverageReserve(), 1_000_000e18, "layer 2 untouched by the rejected draws");
    }

    /// @notice `absorbReserveLoss` moves all three capital layers for a classless custody loss. It
    ///         is reserve-only; a hostile actor (or an out-of-context admin) calling it must be
    ///         rejected before any pool is touched.
    function test_attack_absorbReserveLoss_refusesEveryCallerButTheReserve() public onFork {
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ReserveLossCallerNotReserve.selector, carol)
        );
        defaultManager.absorbReserveLoss(0, 1_000e18);

        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ReserveLossCallerNotReserve.selector, ops)
        );
        defaultManager.absorbReserveLoss(0, 1_000e18);
    }

    /// @notice The cascade ENTRY itself is role-gated. Even holding a genuine attested loss, a
    ///         caller without SERVICER_ROLE cannot realize a loss — so the adversary can neither
    ///         reach the cascade permissionlessly nor trigger it out of turn.
    function test_attack_realizeLoss_isUnreachableByAnUnprivilegedCaller() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        uint256 id = _originateAndFund(1_000_000e18);
        _declareDefault(id, keccak256("atk-acl"));

        bytes32 e = keccak256("atk-acl-loss");
        _attestLoss(id, 100_000e18, e);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.SERVICER_ROLE)
        );
        defaultManager.realizeLoss(id, 100_000e18, e);
    }

    // ─────────────────────────────────────────────────────────────────────
    // (I2) A single loss event cannot double-consume coverage
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attack: realize a loss, then REPLAY the identical (tokenId, loss, evidence) to draw
    ///         the sGROVE reserve a second time for one economic event. The oracle consumes the
    ///         `LossRealized` fact on the first pass, so the replay must revert and NOTHING may
    ///         move. A DISTINCT attested event is still honoured — the guard blocks replay, not all
    ///         further losses.
    function test_attack_realizeLoss_cannotDoubleConsumeTheSameLossAttestation() public onFork {
        _mintFromUSDC(alice, 3_000_000e6); // idle liquidity to fund the facility
        _fundCoverageOps(1_000_000e18); // layer-2 reserve to draw

        uint256 id = _originateAndFund(2_000_000e18);
        _declareDefault(id, keccak256("atk-default"));

        uint256 loss = 100_000e18;
        bytes32 e1 = keccak256("atk-loss-1");
        _attestLoss(id, loss, e1);
        vm.prank(ops);
        defaultManager.realizeLoss(id, loss, e1);

        uint256 consumedAfterFirst = defaultManager.liveDefaultCoverageConsumed();
        uint256 reserveAfterFirst = sGrove.coverageReserve();
        uint256 contributionAfterFirst = defaultManager.defaultedContribution(id);
        assertEq(consumedAfterFirst, loss, "the first realization drew layer 2 for the whole loss");

        // REPLAY the same attested event: the fact was consumed, so it must revert.
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_DefaultNotAttested.selector, id));
        defaultManager.realizeLoss(id, loss, e1);

        // Blocked replay moved nothing: coverage cannot be consumed twice for one event.
        assertEq(defaultManager.liveDefaultCoverageConsumed(), consumedAfterFirst, "no extra coverage on replay");
        assertEq(sGrove.coverageReserve(), reserveAfterFirst, "layer-2 reserve unchanged on replay");
        assertEq(defaultManager.defaultedContribution(id), contributionAfterFirst, "contribution unchanged on replay");

        // A genuinely distinct attested loss event is still honoured.
        bytes32 e2 = keccak256("atk-loss-2");
        _attestLoss(id, loss, e2);
        vm.prank(ops);
        defaultManager.realizeLoss(id, loss, e2);
        assertEq(
            defaultManager.liveDefaultCoverageConsumed(),
            consumedAfterFirst + loss,
            "a fresh attested event consumes fresh coverage exactly once"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // Permissionless `markPastDue`: attacked hardest
    // ─────────────────────────────────────────────────────────────────────

    /// @notice THE HEADLINE ATTACK (compose ops out of order). `markPastDue` is permissionless and
    ///         starts a G2W relief ramp that lightens the conservative senior mark for one payment
    ///         episode. If a bystander could rewind that ramp by clearing and RE-marking the same
    ///         still-delinquent facility, the cohort would sit at maximum relief forever — an
    ///         UNDER-mark, so seniors exiting inside the perpetual window would take value from
    ///         seniors who stay. The S3-F3 fix keys the clock to the payment episode, not to
    ///         whichever mark found the cohort empty. Prove the anchor reuses the ORIGINAL episode
    ///         start after a clear-and-re-mark and is not rewound to now.
    function test_attack_markPastDue_reliefClockCannotBeRewoundByClearAndReMark() public onFork {
        _mintFromUSDC(alice, 3_000_000e6); // idle liquidity to fund
        uint256 id = _originateAndFund(2_000_000e18);
        uint256 outstanding = reserves.deployedTo(id);
        assertEq(outstanding, 2_000_000e18, "precondition: full principal at risk");

        // Run past the first payment plus the 21-day grace window.
        _warp(60 days);

        // STEP 1: a bystander flags it past due (the protocol's own self-healing act).
        uint256 firstMarkTime = block.timestamp;
        vm.prank(carol);
        defaultManager.markPastDue(id);
        uint256 firstAnchor = defaultManager.pastDueReliefAnchor();
        assertEq(firstAnchor, firstMarkTime, "the relief clock anchors at the first mark");
        assertEq(defaultManager.pastDueExposure(), outstanding, "at-risk principal entered the past-due pool");
        assertEq(defaultManager.pastDueContribution(id), outstanding, "counted once for this facility");

        // Idempotence: a second mark cannot double-count the pool.
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_AlreadyPastDue.selector, id));
        defaultManager.markPastDue(id);

        // The servicer cures the mark, emptying the cohort.
        _clearPastDueOps(id, keccak256("atk-cure"));
        assertEq(defaultManager.pastDueExposure(), 0, "the cohort is empty after the cure");

        // Time passes but the payment due date is NOT advanced (no repayment, no amendment).
        _warp(5 days);
        assertGt(block.timestamp, firstAnchor, "wall-clock has moved past the original anchor");

        // STEP 2: re-mark the SAME delinquent episode. The rewind must be unreachable.
        vm.prank(carol);
        defaultManager.markPastDue(id);

        assertEq(
            defaultManager.pastDueReliefAnchor(),
            firstAnchor,
            "S3-F3: the anchor reuses the original episode start; the clear-and-re-mark rewind is blocked"
        );
        assertTrue(defaultManager.pastDueReliefAnchor() != block.timestamp, "the relief clock was NOT rewound to now");
        assertEq(defaultManager.pastDueExposure(), outstanding, "the pool is restored, still counted exactly once");
    }

    /// @notice `markPastDue` on a performing, not-yet-past-due facility must be refused with the
    ///         exact grace-end boundary — an adversary cannot depress the conservative senior NAV
    ///         of a healthy facility.
    function test_attack_markPastDue_refusesAFacilityThatIsNotYetPastDue() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        uint256 id = _originateAndFund(1_000_000e18);

        ClaimBridge.Facility memory f = bridge.facility(id);
        uint64 graceEnd = f.nextPaymentDue + defaultManager.graceWindow(FILM);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_NotPastDue.selector, id, f.nextPaymentDue, graceEnd)
        );
        defaultManager.markPastDue(id);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Permissionless margin path cannot be turned against a receivable facility
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The permissionless margin triggers exist ONLY for marked-to-market collateral, where
    ///         the attested mark is the whole evidence. An adversary must not be able to point them
    ///         at a receivable facility (film/UCC classes) to freeze or liquidate it out of band.
    function test_attack_marginPathIsRefusedOnAReceivableFacility() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        uint256 id = _originateAndFund(1_000_000e18); // FILM = receivable

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotMarkedToMarket.selector, id));
        defaultManager.marginCall(id);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotMarkedToMarket.selector, id));
        defaultManager.liquidate(id);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotMarkedToMarket.selector, id));
        defaultManager.clearMarginCall(id);
    }

    // ─────────────────────────────────────────────────────────────────────
    // helpers (private to this file; the shared fixture is untouched)
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Seed the sGROVE (layer-2) reserve from `ops`, minting the USDfr first through the real
    ///      KYC-gated path. Coverage funding is permissionless.
    function _fundCoverageOps(uint256 usdfrAmount) internal {
        _mintFromUSDC(ops, usdfrAmount / 1e12 + 50_000e6);
        vm.startPrank(ops);
        usdfr.approve(address(sGrove), usdfrAmount);
        sGrove.fundCoverage(usdfrAmount);
        vm.stopPrank();
    }

    /// @dev Post curator first-loss (layer 1) for FILM as the anchor curator (`ops`).
    function _postFirstLossOps(uint256 usdfrAmount) internal {
        _mintFromUSDC(ops, usdfrAmount / 1e12 + 50_000e6);
        vm.startPrank(ops);
        usdfr.approve(address(curator), usdfrAmount);
        curator.postFirstLoss(FILM, usdfrAmount);
        vm.stopPrank();
    }

    /// @dev Servicer cure of a past-due mark: attest the exact `PastDueCured` fact, then clear it.
    function _clearPastDueOps(uint256 tokenId, bytes32 evidence) internal {
        _attest(tokenId, IAttestationOracle.AttestationKind.PastDueCured, keccak256(abi.encode(tokenId, evidence)));
        vm.prank(ops);
        defaultManager.clearPastDue(tokenId, evidence);
    }
}
