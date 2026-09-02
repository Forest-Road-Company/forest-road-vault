// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {ICuratorModule} from "../../src/interfaces/ICuratorModule.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title CascadeNavFork — the three-layer loss cascade and the conservative NAV, on a pinned
///        mainnet fork, against a locally deployed current-source stack and REAL USDC.
///
/// @notice `FullLifecycleFork` proves ONE three-layer cascade runs end to end. This suite goes
///         after the two mechanisms that have each produced multiple audit findings and whose
///         interaction is the subtlest thing in the protocol:
///
///         ADR-0035 supersedes PM-R-07: sGROVE is one live shared reserve, with no event-owned
///         ceiling and no first-draw snapshot. One event may exhaust it; chunking and event order
///         cannot create more coverage than the physical reserve, and replenishment immediately
///         becomes reachable by every live event.
///
///         PM-R-11 — `pendingSeniorImpairment()` must never mark BELOW the true conservative
///         floor. Its historical capped-tree cases remain recognizable, but this current-source
///         fixture deliberately re-points them to the owner-selected live-reserve rule.
///
///         All PM-R-11 variants, the ADR-0035 shared-reserve guarantee, the cascade ORDERING
///         across multiple facilities in multiple classes, the `redemptionTotalAssets() <=
///         totalAssets()` invariant, and the clean-recovery restore path are exercised here on
///         the real deployment topology rather than a hand-rolled fixture.
///
/// @dev FIXTURE ADDITIONS MADE PRIVATELY IN THIS FILE (the shared fixture is not modified):
///      - `_originateAndFundIn` — originate in an ARBITRARY class with an arbitrary borrowerId
///        (the fixture's `_originateAndFund` is hard-wired to FILM and one borrower, so it cannot
///        express the multi-facility / multi-class scenarios this suite needs).
///      - `_declare` / `_fundCoverage` / `_postFirstLoss` / `_stakeAsCurator` — small wrappers.
///      - `_eventRoom` / `_eventRoomUnclamped` / `_trueAggregateFloor` — an INDEPENDENT model of
///        ADR-0035's physical shared reach and PM-R-11's conservative floor, recomputed from the
///        reserve balance rather than trusting the compatibility event view (CLAUDE.md §1.5,
///        differential testing).
///      - `_realizeAndVerify` — runs `realizeLoss` and checks the resulting (curator, backstop,
///        depositor) split against that independent model, from BOTH the observed balance deltas
///        and the emitted `LossRealized` event, and asserts the ordering can never invert.
contract CascadeNavForkTest is ForkLifecycleFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS; // 1, receivable
    uint256 internal constant RENEWABLE = Config.CLASS_RENEWABLE_ENERGY; // 2, receivable
    uint256 internal constant DIGITAL = Config.CLASS_DIGITAL_ASSETS; // 5, marked-to-market

    bytes32 internal constant LOSS_REALIZED_SIG =
        keccak256("LossRealized(uint256,uint256,uint256,uint256,uint256,uint256)");

    /// @dev The cascade split for one `realizeLoss`: layer 1, layer 2, layer 3.
    struct Layers {
        uint256 absorbed; // curator first-loss
        uint256 covered; // sGROVE backstop
        uint256 depositorLoss; // sUSDfr senior principal
    }

    // ─────────────────────────────────────────────────────────────────────
    // 1. ADR-0035 — one event may consume the live shared reserve, but never more
    // ─────────────────────────────────────────────────────────────────────

    /// @notice ONE facility's loss, realized in FIVE chunks, may consume the shared reserve but
    ///         can never draw more than its physical funding.
    /// @dev The 750,000 aggregate loss is below the 1,000,000 reserve, so ADR-0035 requires layer
    ///      two to absorb every chunk and leaves exactly 250,000 for later events.
    function test_fork_oneEventChunkingConsumesOnlyTheSharedReserve() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 4_000_000e18);
        _mintFromUSDC(ops, 1_000_000e6);
        _fundCoverage(ops, 1_000_000e18);

        assertEq(sGrove.coverageReserve(), 1_000_000e18, "coverage reserve seeded");
        assertEq(sGrove.coverageCapacity(), 1_000_000e18, "capacity is the whole live reserve");
        assertEq(curator.poolBalance(FILM), 0, "precondition: empty curator pool isolates layer 2");

        uint256 id = _originateAndFundIn(FILM, keccak256("BW-CHUNK"), 2_000_000e18, 7500);
        _declare(id);

        (uint256 drawnBefore, uint256 reachBefore) = sGrove.eventCoverage(id);
        assertEq(drawnBefore, 0, "nothing drawn before realization");
        assertEq(reachBefore, 1_000_000e18, "every event immediately sees the shared reserve");

        uint256 vaultAtStart = vault.totalAssets();
        uint256 totalCovered;
        uint256 totalDepositor;
        for (uint256 i = 0; i < 5; ++i) {
            Layers memory got = _realizeAndVerify(id, FILM, 150_000e18);
            totalCovered += got.covered;
            totalDepositor += got.depositorLoss;
            assertEq(got.absorbed, 0, "layer 1 is empty in this scenario");

            (uint256 drawn, uint256 reach) = sGrove.eventCoverage(id);
            assertEq(reach, 1_000_000e18, "drawn plus live reserve conserves initial funding");
            assertLe(drawn, reach, "cumulative draw never exceeds physical funding");
            assertEq(drawn, totalCovered, "the event's cumulative draw is exactly what was delivered");
        }

        assertEq(totalCovered, 750_000e18, "ADR-0035: layer two absorbed every funded chunk");
        assertEq(totalDepositor, 0, "senior stays untouched while shared reserve remains");
        assertEq(totalCovered + totalDepositor, 750_000e18, "value conservation across all five chunks");
        assertEq(sGrove.coverageReserve(), 250_000e18, "unspent physical reserve survives for later events");
        assertEq(vaultAtStart - vault.totalAssets(), 0, "senior absorbed no funded loss");
        assertEq(defaultManager.liveDefaultCoverageConsumed(), 750_000e18, "consumption remains observable");
        assertEq(
            defaultManager.defaultedContribution(id),
            2_000_000e18 - 750_000e18,
            "the facility's unrealized contribution fell by exactly the realized loss"
        );
        _assertNavOrdering("chunked realization");
    }

    /// @notice Successive events consume the SAME pool in report order; they do not mint separate
    ///         allowances or preserve a geometric remainder.
    function test_fork_successiveEventsConsumeTheSameSharedReserve() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 2_000_000e18);
        _mintFromUSDC(ops, 1_000_000e6);
        _fundCoverage(ops, 1_000_000e18);

        uint256 a = _originateAndFundIn(FILM, keccak256("BW-A"), 1_000_000e18, 7500);
        uint256 b = _originateAndFundIn(FILM, keccak256("BW-B"), 1_000_000e18, 7500);
        uint256 c = _originateAndFundIn(FILM, keccak256("BW-C"), 1_000_000e18, 7500);
        _declare(a);
        _declare(b);
        _declare(c);

        Layers memory la = _realizeAndVerify(a, FILM, 500_000e18);
        assertEq(la.covered, 500_000e18, "event A drew from the shared reserve");
        assertEq(la.depositorLoss, 0, "layer 2 covered A entirely");
        assertEq(sGrove.coverageReserve(), 500_000e18, "reserve halved");

        Layers memory lb = _realizeAndVerify(b, FILM, 400_000e18);
        (, uint256 reachB) = sGrove.eventCoverage(b);
        assertEq(reachB, 500_000e18, "B's cumulative draw plus live reserve is the pool it encountered");
        assertEq(lb.covered, 400_000e18, "B draws its whole loss from available shared reserve");
        assertEq(lb.depositorLoss, 0, "senior remains untouched while reserve funds the loss");
        assertEq(sGrove.coverageReserve(), 100_000e18, "only physical consumption reduces the reserve");

        Layers memory lc = _realizeAndVerify(c, FILM, 125_000e18);
        (, uint256 reachC) = sGrove.eventCoverage(c);
        assertEq(reachC, 100_000e18, "C's event view exposes only the pool it encountered");
        assertEq(lc.covered, 100_000e18, "C exhausts the shared reserve");
        assertEq(lc.depositorLoss, 25_000e18, "senior takes only the unfunded remainder");

        assertEq(sGrove.coverageReserve(), 0, "a single later event may exhaust layer two");
        _assertNavOrdering("successive events");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. Cascade ORDERING — never skipped, never inverted
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A loss inside the curator pool must leave the backstop and the senior layer
    ///         EXACTLY untouched — the sGROVE event must record no draw.
    function test_fork_curatorFirstLossAbsorbsEntirelyBeforeTheBackstopIsTouched() public onFork {
        _mintFromUSDC(alice, 4_000_000e6);
        _stake(alice, 2_000_000e18);
        _mintFromUSDC(ops, 2_000_000e6);
        _postFirstLoss(FILM, 500_000e18);
        _fundCoverage(ops, 1_000_000e18);

        uint256 id = _originateAndFundIn(FILM, keccak256("BW-L1"), 1_000_000e18, 7500);
        _declare(id);

        uint256 reserveBefore = sGrove.coverageReserve();
        uint256 vaultBefore = vault.totalAssets();

        Layers memory got = _realizeAndVerify(id, FILM, 300_000e18);

        assertEq(got.absorbed, 300_000e18, "layer 1 took the WHOLE loss");
        assertEq(got.covered, 0, "layer 2 was never asked");
        assertEq(got.depositorLoss, 0, "layer 3 was never asked");
        assertEq(curator.poolBalance(FILM), 200_000e18, "curator pool drawn down by exactly the loss");
        assertEq(sGrove.coverageReserve(), reserveBefore, "backstop reserve EXACTLY untouched");
        assertEq(vault.totalAssets(), vaultBefore, "senior assets EXACTLY untouched");
        (uint256 drawn, uint256 cap) = sGrove.eventCoverage(id);
        assertEq(drawn, 0, "the event drew nothing");
        assertEq(cap, reserveBefore, "the compatibility view exposes live reserve without a draw");
        assertEq(defaultManager.liveDefaultCoverageConsumed(), 0, "no coverage consumed");
        _assertNavOrdering("layer 1 only");
    }

    /// @notice A loss past the curator pool but inside the event's cap must leave the SENIOR layer
    ///         exactly untouched — layer 2 is never skipped in favour of layer 3.
    function test_fork_backstopAbsorbsEntirelyBeforeDepositors() public onFork {
        _mintFromUSDC(alice, 4_000_000e6);
        _stake(alice, 2_000_000e18);
        _mintFromUSDC(ops, 2_000_000e6);
        _postFirstLoss(FILM, 100_000e18);
        _fundCoverage(ops, 1_000_000e18);

        uint256 id = _originateAndFundIn(FILM, keccak256("BW-L2"), 1_000_000e18, 7500);
        _declare(id);

        uint256 vaultBefore = vault.totalAssets();
        Layers memory got = _realizeAndVerify(id, FILM, 400_000e18);

        assertEq(got.absorbed, 100_000e18, "layer 1 drained FIRST, in full");
        assertEq(got.covered, 300_000e18, "layer 2 took the entire residual");
        assertEq(got.depositorLoss, 0, "layer 3 untouched while layer 2 still had room");
        assertEq(curator.poolBalance(FILM), 0, "curator pool fully wiped before the backstop was asked");
        assertEq(vault.totalAssets(), vaultBefore, "senior assets EXACTLY untouched");
        assertEq(sGrove.coverageReserve(), 700_000e18, "reserve fell by exactly the covered amount");
        _assertNavOrdering("layer 1 then layer 2");
    }

    /// @notice ORDERING ACROSS MULTIPLE FACILITIES IN MULTIPLE CLASSES. Six interleaved
    ///         realizations against two facilities in two different collateral classes, each one
    ///         checked against an independent model of the cascade. Curator first-loss always
    ///         absorbs before sGROVE, sGROVE always before depositors, and one class's curator
    ///         pool never absorbs another class's loss.
    function test_fork_cascadeOrderingNeverInvertsAcrossFacilitiesAndClasses() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 2_000_000e18);
        _mintFromUSDC(ops, 1_000_000e6);
        _postFirstLoss(FILM, 200_000e18); // layer 1 exists for FILM only
        _fundCoverage(ops, 600_000e18); // one GLOBAL backstop shared by both classes

        uint256 f1 = _originateAndFundIn(FILM, keccak256("BW-F1"), 800_000e18, 7500);
        uint256 f2 = _originateAndFundIn(RENEWABLE, keccak256("BW-F2"), 800_000e18, 7000);
        _declare(f1);
        _declare(f2);

        assertEq(curator.poolBalance(FILM), 200_000e18, "FILM first-loss posted");
        assertEq(curator.poolBalance(RENEWABLE), 0, "RENEWABLE has no first-loss");

        // 1. FILM loss inside its curator pool: nothing else moves.
        Layers memory s1 = _realizeAndVerify(f1, FILM, 101_000e18);
        assertEq(s1.absorbed, 101_000e18, "s1: FILM curator absorbed the whole distinct loss");
        assertEq(s1.covered, 0, "s1: backstop untouched");
        assertEq(s1.depositorLoss, 0, "s1: senior untouched");

        // 2. RENEWABLE loss with NO first-loss in that class: it must go straight to the backstop
        //    and must NOT reach into FILM's curator pool.
        Layers memory s2 = _realizeAndVerify(f2, RENEWABLE, 102_000e18);
        assertEq(s2.absorbed, 0, "s2: RENEWABLE has no curator capital to absorb");
        assertEq(s2.covered, 102_000e18, "s2: the shared backstop absorbed the whole distinct loss");
        assertEq(s2.depositorLoss, 0, "s2: senior untouched");
        assertEq(
            curator.poolBalance(FILM),
            99_000e18,
            "CROSS-CLASS ISOLATION: a FILM curator pool never absorbs a RENEWABLE loss"
        );

        // 3. FILM loss that drains layer 1 and spills into layer 2.
        Layers memory s3 = _realizeAndVerify(f1, FILM, 253_000e18);
        assertEq(s3.absorbed, 99_000e18, "s3: layer 1 drained to zero FIRST");
        assertEq(s3.covered, 154_000e18, "s3: only then did layer 2 draw");
        assertEq(s3.depositorLoss, 0, "s3: senior untouched");
        assertEq(curator.poolBalance(FILM), 0, "s3: FILM first-loss fully wiped");

        // 4. RENEWABLE consumes from the same live reserve.
        Layers memory s4 = _realizeAndVerify(f2, RENEWABLE, 301_000e18);
        assertEq(s4.absorbed, 0, "s4: no curator capital in RENEWABLE");
        assertEq(s4.covered, 301_000e18, "s4: shared reserve funds the whole distinct loss");
        assertEq(s4.depositorLoss, 0, "s4: senior stays untouched while reserve remains");

        // 5. FILM consumes the last shared reserve, then senior takes the remainder.
        Layers memory s5 = _realizeAndVerify(f1, FILM, 199_000e18);
        assertEq(s5.absorbed, 0, "s5: layer 1 is exhausted");
        assertEq(s5.covered, 43_000e18, "s5: layer 2 contributes its last physical reserve");
        assertEq(s5.depositorLoss, 156_000e18, "s5: senior took only the unfunded remainder");

        // 6. RENEWABLE again after the shared reserve is exhausted: senior only.
        Layers memory s6 = _realizeAndVerify(f2, RENEWABLE, 103_000e18);
        assertEq(s6.absorbed, 0, "s6: no layer 1");
        assertEq(s6.covered, 0, "s6: layer 2 is fully consumed");
        assertEq(s6.depositorLoss, 103_000e18, "s6: senior absorbed the whole distinct loss alone");

        // Aggregate conservation across the whole run.
        // A2: six pairwise-distinct loss operands keep this a non-degenerate split, rather than
        // proving only the repeated-value fixture that previously let a broken branch coincide.
        uint256 totalLoss = 101_000e18 + 102_000e18 + 253_000e18 + 301_000e18 + 199_000e18 + 103_000e18;
        uint256 totalAbsorbed = s1.absorbed + s2.absorbed + s3.absorbed + s4.absorbed + s5.absorbed + s6.absorbed;
        uint256 totalCovered = s1.covered + s2.covered + s3.covered + s4.covered + s5.covered + s6.covered;
        uint256 totalSenior = s1.depositorLoss + s2.depositorLoss + s3.depositorLoss + s4.depositorLoss
            + s5.depositorLoss + s6.depositorLoss;
        assertEq(totalLoss, 1_059_000e18, "the run realized 1.059M of pairwise-distinct loss");
        assertEq(totalAbsorbed, 200_000e18, "layer 1 contributed exactly the posted first-loss");
        assertEq(totalCovered, 600_000e18, "layer 2 contributed exactly its funded reserve");
        assertEq(totalSenior, 259_000e18, "layer 3 contributed only the unfunded residual");
        assertEq(totalAbsorbed + totalCovered + totalSenior, totalLoss, "VALUE CONSERVATION over the whole run");
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "BACKING INVARIANT holds throughout");
        _assertNavOrdering("multi-class cascade");
    }

    /// @notice A loss beyond EVERY layer must fail loudly with the exact custom error, and must
    ///         leave the whole cascade untouched. Silently impairing unstaked USDfr is never the
    ///         answer (CLAUDE.md prime directive 4).
    function test_fork_lossBeyondEveryLayerRevertsLoudlyAndChangesNothing() public onFork {
        _mintFromUSDC(alice, 3_000_000e6);
        _stake(alice, 100_000e18);

        uint256 id = _originateAndFundIn(FILM, keccak256("BW-CAP"), 1_000_000e18, 7500);
        _declare(id);

        assertEq(curator.poolBalance(FILM), 0, "no layer 1");
        assertEq(sGrove.coverageReserve(), 0, "no layer 2");

        uint256 vaultAssets = vault.totalAssets(); // hoisted: expectRevert applies to the NEXT call
        uint256 supplyBefore = usdfr.totalSupply();
        uint256 outstandingBefore = reserves.deployedTo(id);

        bytes32 lossEvidence = _attestLoss(id, 500_000e18, bytes32(0));
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_LossExceedsAbsorptionCapacity.selector, id, 500_000e18, vaultAssets
            )
        );
        defaultManager.realizeLoss(id, 500_000e18, lossEvidence);

        assertEq(vault.totalAssets(), vaultAssets, "vault untouched by the reverted realization");
        assertEq(usdfr.totalSupply(), supplyBefore, "no USDfr burned");
        assertEq(reserves.deployedTo(id), outstandingBefore, "no write-down applied");
        assertEq(defaultManager.defaultedContribution(id), 1_000_000e18, "impairment contribution intact");
    }

    /// @notice A loss larger than the facility's own outstanding principal is refused with the
    ///         exact error — the cascade cannot be used to burn value a facility never held.
    function test_fork_lossExceedingOutstandingIsRefused() public onFork {
        _mintFromUSDC(alice, 3_000_000e6);
        _stake(alice, 1_000_000e18);
        uint256 id = _originateAndFundIn(FILM, keccak256("BW-OUT"), 500_000e18, 7500);
        _declare(id);

        uint256 outstanding = reserves.deployedTo(id); // hoisted
        assertEq(outstanding, 500_000e18, "the facility's deployed principal");
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_LossExceedsOutstanding.selector, id, 500_000e18 + 1, outstanding
            )
        );
        defaultManager.realizeLoss(id, 500_000e18 + 1, bytes32(0));
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. PM-R-11 / ADR-0035 — the conservative NAV follows live shared reach
    // ─────────────────────────────────────────────────────────────────────

    /// @notice VARIANT 1 (the original finding). After a PARTIAL realization, the reported
    ///         impairment is at or above the true floor from the remaining shared reserve.
    function test_fork_navNeverUnderMarksAfterPartialRealization() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 3_000_000e18);
        _mintFromUSDC(ops, 1_000_000e6);
        _fundCoverage(ops, 1_000_000e18);
        assertEq(curator.poolBalance(FILM), 0, "empty curator pool isolates layer 2");

        uint256 freshCapacity = sGrove.coverageCapacity();
        assertEq(freshCapacity, 1_000_000e18, "the full 1M reserve is live capacity");

        uint256 principal = 2_000_000e18;
        uint256 id = _originateAndFundIn(FILM, keccak256("BW-V1"), principal, 7500);
        _declare(id);

        // Before any draw the mark is EXACT: the full live reserve is legitimately nettable.
        assertEq(defaultManager.liveDefaultCoverageConsumed(), 0, "nothing consumed yet");
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            principal - freshCapacity,
            "pre-draw: reported == principal less the full live reserve"
        );
        assertEq(defaultManager.pendingSeniorImpairment(), _trueFloorFor(id), "pre-draw: reported == true floor");

        uint256 partialLoss = freshCapacity * 3 / 5; // 600k, entirely absorbed by layer 2
        Layers memory got = _realizeAndVerify(id, FILM, partialLoss);
        assertEq(got.covered, partialLoss, "layer 2 absorbed the whole partial loss");

        (uint256 drawn, uint256 snapshot) = sGrove.eventCoverage(id);
        assertEq(drawn, 600_000e18, "drawn");
        assertEq(snapshot, 1_000_000e18, "drawn plus live reserve preserves the event-view identity");
        assertEq(defaultManager.liveDefaultCoverageConsumed(), 600_000e18, "consumption tracked");

        uint256 reported = defaultManager.pendingSeniorImpairment();
        uint256 trueFloor = _trueFloorFor(id);

        // THE PROPERTY. Before PM-R-11 this read BELOW the floor and a queued senior exited above
        // the true conservative price, pushing the difference onto the seniors who stayed.
        assertGe(reported, trueFloor, "PM-R-11: reported impairment is NEVER below the true floor");

        // Exact arithmetic: remaining declared less the still-live shared reserve.
        uint256 remainingDeclared = principal - partialLoss;
        assertEq(remainingDeclared, 1_400_000e18, "remaining declared principal");
        assertEq(sGrove.coverageCapacity(), 400_000e18, "capacity is the remaining reserve");
        assertEq(reported, remainingDeclared - 400_000e18, "nets the remaining shared reserve once");
        assertEq(reported, 1_000_000e18, "the exact conservative mark");
        assertEq(trueFloor, 1_000_000e18, "the independently reconstructed physical floor");
        _assertNavOrdering("variant 1");
    }

    /// @notice VARIANT 2. A PERMISSIONLESS `fundCoverage` top-up after a partial draw immediately
    ///         restores protection to the live cohort.
    /// @dev Funded here by `carol`, who is deliberately NOT KYC'd — `fundCoverage` is role-less
    ///      and unpausable by design, so the attack surface is genuinely open to anyone. Carol
    ///      cannot mint USDfr, so alice transfers her some first (USDfr transfers are
    ///      permissionless except for sanctions, per the 2026-07-14 directive).
    function test_fork_navNeverUnderMarksAfterPermissionlessFundCoverageTopUp() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 2_000_000e18);
        _mintFromUSDC(ops, 1_000_000e6);
        _fundCoverage(ops, 1_000_000e18);

        uint256 id = _originateAndFundIn(FILM, keccak256("BW-V2"), 2_000_000e18, 7500);
        _declare(id);

        uint256 partialDraw = sGrove.coverageCapacity() * 3 / 5; // hoisted (prank consumption)
        _realizeAndVerify(id, FILM, partialDraw);

        uint256 markBefore = defaultManager.pendingSeniorImpairment();
        assertGe(markBefore, _trueFloorFor(id), "precondition: already conservative");

        // A completely unrelated, non-KYC'd party tops the reserve up.
        vm.prank(alice);
        bool sent = usdfr.transfer(carol, 2_000_000e18);
        assertTrue(sent, "USDfr moves to a non-KYC'd party (transfers are permissionless)");
        assertFalse(compliance.isAllowed(carol), "carol is deliberately NOT KYC'd");
        uint256 capacityBefore = sGrove.coverageCapacity();
        _fundCoverage(carol, 2_000_000e18);
        assertGt(sGrove.coverageCapacity(), capacityBefore, "precondition: capacity really did jump");
        assertEq(sGrove.coverageReserve(), 2_400_000e18, "the top-up landed after a 600k draw");

        uint256 markAfter = defaultManager.pendingSeniorImpairment();
        assertLt(markAfter, markBefore, "real replenishment must reduce the live cohort's mark");
        assertEq(markAfter, 0, "the replenished reserve fully protects remaining principal");
        assertEq(markAfter, _trueFloorFor(id), "reported mark equals the physical floor");
        _assertNavOrdering("variant 2");
    }

    /// @notice VARIANT 3. ADR-0035 publishes an uncapped identity at every reserve size; probing
    ///         that compatibility surface after a partial draw must not mutate the mark.
    function test_fork_navNeverUnderMarksAfterUncappedCapacityProbe() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 2_000_000e18);
        _mintFromUSDC(ops, 1_000_000e6);
        _fundCoverage(ops, 1_000_000e18);

        uint256 id = _originateAndFundIn(FILM, keccak256("BW-V3"), 2_000_000e18, 7500);
        _declare(id);

        uint256 partialDraw = sGrove.coverageCapacity() * 3 / 5; // hoisted
        _realizeAndVerify(id, FILM, partialDraw);
        uint256 markBefore = defaultManager.pendingSeniorImpairment();

        uint256 capacityBefore = sGrove.coverageCapacity();
        assertEq(sGrove.coverageCapacityAt(capacityBefore), capacityBefore, "capacity must be identity");
        (uint16 capBpsNow, uint256 absoluteCap) = sGrove.coverageCapParameters();
        assertEq(capBpsNow, uint16(Config.BPS), "compatibility bps must publish uncapped identity");
        assertEq(absoluteCap, type(uint256).max, "compatibility absolute cap must be unbounded");
        assertEq(sGrove.coverageCapacity(), capacityBefore, "a pure capacity probe mutated reserve");

        assertEq(
            defaultManager.pendingSeniorImpairment(), markBefore, "a capacity identity probe must NOT move the mark"
        );
        assertGe(defaultManager.pendingSeniorImpairment(), _trueFloorFor(id), "still conservative");
        _assertNavOrdering("variant 3");
    }

    /// @notice VARIANT 3b (the round-3 follow-up). DRAIN the reserve to zero, then REFILL it. Under
    ///         ADR-0035 the refill must immediately rearm the still-live cohort.
    function test_fork_navNeverUnderMarksAfterDrainToZeroThenRefill() public onFork {
        deal(USDC, alice, 12_000_000e6);
        _mintFromUSDC(alice, 12_000_000e6);
        _stake(alice, 8_000_000e18);
        _mintFromUSDC(ops, 5_000_000e6);
        _fundCoverage(ops, 1_000_000e18);

        // A draws one wei; the compatibility view remains cumulative draw plus live reserve.
        uint256 a = _originateAndFundIn(FILM, keccak256("BW-D-A"), 3_000_000e18, 7500);
        _declare(a);
        _realizeAndVerify(a, FILM, 1);
        (, uint256 snapA) = sGrove.eventCoverage(a);
        assertEq(snapA, 1_000_000e18, "A's event view equals its draw plus shared reserve");

        // B and C consume the shared reserve in report order.
        uint256 b = _originateAndFundIn(FILM, keccak256("BW-D-B"), 2_000_000e18, 7500);
        _declare(b);
        _realizeAndVerify(b, FILM, 500_000e18);

        uint256 c = _originateAndFundIn(FILM, keccak256("BW-D-C"), 1_000_000e18, 7500);
        _declare(c);
        _realizeAndVerify(c, FILM, 250_000e18);
        assertLt(sGrove.coverageReserve(), snapA, "reserve fell through physical draws");

        // A draws again: coverage clamps to the remaining physical reserve and takes it to zero.
        Layers memory drain = _realizeAndVerify(a, FILM, 600_000e18);
        assertEq(drain.covered, 250_000e18 - 1, "clamped to the remaining reserve after A's one wei");
        assertEq(sGrove.coverageReserve(), 0, "reserve fully drained");
        assertEq(sGrove.coverageCapacity(), 0, "capacity, and so the pinned floor, is now zero");
        assertGt(defaultManager.liveDefaultCoverageConsumed(), 0, "live defaults hold consumption");

        // Anyone refills, hugely. The new capital is real and must become reachable.
        _fundCoverage(ops, 4_000_000e18);
        assertGt(sGrove.coverageCapacity(), 0, "precondition: capacity jumped back");

        // A further draw by a STILL-LIVE default consumes the replenished reserve.
        _realizeAndVerify(a, FILM, 100_000e18);

        uint256 reported = defaultManager.pendingSeniorImpairment();
        assertGe(
            reported, _trueAggregateFloor(_ids3(a, b, c)), "round 3: drain-then-refill stays at or above the floor"
        );
        uint256 residual = defaultManager.declaredDefaultedPrincipal(FILM); // curator pool is empty
        assertEq(curator.poolBalance(FILM), 0, "no layer 1 to net per class");
        assertEq(sGrove.coverageReserve(), 3_900_000e18, "refilled reserve less A's final draw");
        assertEq(reported, residual - sGrove.coverageReserve(), "refill is netted exactly once across the cohort");
        assertEq(reported, 650_000e18 - 1, "exact mark retains A's one-wei initial realization");
        _assertNavOrdering("drain then refill");
    }

    /// @notice The conservative NAV nets layer 1 PER CLASS and layer 2 GLOBALLY, in cascade order,
    ///         with a class whose curator pool exceeds its declared default contributing nothing.
    function test_fork_impairmentNetsCuratorPerClassThenTheGlobalBackstop() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 2_000_000e18);
        _mintFromUSDC(ops, 1_000_000e6);
        _postFirstLoss(FILM, 100_000e18);
        _postFirstLoss(RENEWABLE, 300_000e18);
        _fundCoverage(ops, 200_000e18);
        assertEq(sGrove.coverageCapacity(), 200_000e18, "the whole 200k reserve is live capacity");

        uint256 f1 = _originateAndFundIn(FILM, keccak256("BW-M1"), 500_000e18, 7500);
        uint256 f2 = _originateAndFundIn(RENEWABLE, keccak256("BW-M2"), 200_000e18, 7000);
        _declare(f1);
        _declare(f2);

        // residual = (500k FILM - 100k FILM curator) + max(0, 200k RE - 300k RE curator) = 400k.
        // Then net the 200k shared reserve -> 200k.
        assertEq(defaultManager.declaredDefaultedPrincipal(FILM), 500_000e18, "FILM declared");
        assertEq(defaultManager.declaredDefaultedPrincipal(RENEWABLE), 200_000e18, "RENEWABLE declared");
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            200_000e18,
            "an over-collateralised class contributes ZERO residual; the rest nets the global backstop"
        );

        // Now realize part of the FILM loss so a per-event consumption exists, and recompute.
        Layers memory got = _realizeAndVerify(f1, FILM, 150_000e18);
        assertEq(got.absorbed, 100_000e18, "FILM layer 1 drained first");
        assertEq(got.covered, 50_000e18, "then layer 2");
        assertEq(got.depositorLoss, 0, "senior untouched");

        // residual = 350k (FILM, curator now 0) + 0 (RENEWABLE) = 350k.
        // The remaining 150k reserve is offered once to the live cohort.
        assertEq(sGrove.coverageReserve(), 150_000e18, "reserve after the draw");
        assertEq(sGrove.coverageCapacity(), 150_000e18, "capacity equals reserve after the draw");
        assertEq(defaultManager.liveDefaultCoverageConsumed(), 50_000e18, "consumed by the live default");
        assertEq(defaultManager.pendingSeniorImpairment(), 200_000e18, "exact conservative mark after the draw");
        assertGe(
            defaultManager.pendingSeniorImpairment(),
            _trueAggregateFloor(_ids2(f1, f2)),
            "at or above the true multi-facility floor"
        );
        _assertNavOrdering("multi-class NAV");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. redemptionTotalAssets() <= totalAssets(), always
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The exit price is checked against the deposit price at EVERY step of a full
    ///         workout. This test explicitly enables optional ADR-0023 smoothing so the
    ///         non-launch branch remains covered against the production topology.
    function test_fork_redemptionNavNeverExceedsTotalAssetsAcrossAWholeWorkout() public onFork {
        uint64 optionalStreamPeriod = 7 days;
        vault.setYieldVestingPeriod(optionalStreamPeriod);
        _mintFromUSDC(alice, 5_000_000e6);
        _assertNavOrdering("after mint");
        _stake(alice, 3_000_000e18);
        _assertNavOrdering("after stake");
        _mintFromUSDC(ops, 1_000_000e6);
        _fundCoverage(ops, 600_000e18);
        _assertNavOrdering("after coverage funding");

        uint256 id = _originateAndFundIn(FILM, keccak256("BW-NAV"), 1_500_000e18, 7500);
        _assertNavOrdering("after origination");

        // Realized yield lands and begins vesting: totalAssets() deliberately EXCLUDES the
        // unvested stream (ADR-0023), so the two bases must still order correctly.
        _repay(id, 100_000e18, 0);
        assertGt(vault.unvestedYield(), 0, "precondition: yield is mid-stream");
        _assertNavOrdering("yield mid-vest");
        _warp(optionalStreamPeriod / 2);
        _assertNavOrdering("yield half vested");

        _declare(id);
        assertGt(defaultManager.pendingSeniorImpairment(), 0, "a declared default marks the exit price down");
        assertLt(vault.redemptionTotalAssets(), vault.totalAssets(), "exit strictly below deposit while marked");
        _assertNavOrdering("declared");

        _realizeAndVerify(id, FILM, 200_000e18);
        _assertNavOrdering("partially realized");

        _fundCoverage(ops, 300_000e18);
        _assertNavOrdering("after a top-up");

        assertEq(sGrove.coverageCapacityAt(sGrove.coverageReserve()), sGrove.coverageReserve());
        _assertNavOrdering("after an uncapped-capacity probe");

        _warp(optionalStreamPeriod);
        assertEq(vault.unvestedYield(), 0, "the stream fully vested");
        _assertNavOrdering("fully vested");

        // Clean recovery of everything still outstanding.
        _repay(id, 0, reserves.deployedTo(id));
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "a clean resolve clears the mark");
        assertEq(vault.redemptionTotalAssets(), vault.totalAssets(), "exit price back at the realized NAV");
        _assertNavOrdering("resolved");
    }

    /// @notice An impairment LARGER than the vault's assets clamps the exit price to zero rather
    ///         than underflowing — the senior layer reads as fully impaired, which is the honest
    ///         and conservative reading.
    function test_fork_impairmentBeyondVaultAssetsClampsTheExitPriceToZero() public onFork {
        _mintFromUSDC(alice, 3_000_000e6);
        _stake(alice, 100_000e18);

        uint256 id = _originateAndFundIn(FILM, keccak256("BW-CLAMP"), 1_000_000e18, 7500);
        _declare(id);

        assertEq(defaultManager.pendingSeniorImpairment(), 1_000_000e18, "no junior layers exist to net");
        assertGt(defaultManager.pendingSeniorImpairment(), vault.totalAssets(), "the mark exceeds vault assets");
        assertEq(vault.redemptionTotalAssets(), 0, "the conservative base clamps at zero");
        assertEq(vault.previewRedeem(10 ** vault.decimals()), 0, "and the exit price with it");
        assertGt(vault.totalAssets(), 0, "while the DEPOSIT base is untouched (ADR-0022 asymmetry)");
        _assertNavOrdering("clamped");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5. Clean recovery — the mark clears and the exit price is restored
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A default declared and then FULLY recovered must return the exit price to EXACTLY
    ///         where it stood before the declaration. Without `onDefaultResolved` the mark would
    ///         depress the conservative NAV forever after a clean workout.
    function test_fork_cleanRecoveryClearsTheMarkAndRestoresTheExitPriceExactly() public onFork {
        _mintFromUSDC(alice, 3_000_000e6);
        _stake(alice, 1_000_000e18);
        _mintFromUSDC(ops, 200_000e6);
        _fundCoverage(ops, 100_000e18);

        uint256 id = _originateAndFundIn(FILM, keccak256("BW-REC"), 500_000e18, 7500);

        uint256 unit = 10 ** vault.decimals();
        uint256 exitBefore = vault.previewRedeem(unit);
        uint256 depositBefore = vault.convertToAssets(unit);
        assertEq(exitBefore, depositBefore, "no mark: exit == deposit price");
        assertEq(vault.redemptionTotalAssets(), vault.totalAssets(), "and the bases agree");

        _declare(id);
        assertEq(defaultManager.pendingSeniorImpairment(), 400_000e18, "declared less the 100k shared reserve");
        assertLt(vault.previewRedeem(unit), exitBefore, "the exit price fell on declaration");
        assertEq(vault.convertToAssets(unit), depositBefore, "the DEPOSIT price did not move (ADR-0022)");

        // Full recovery: the borrower repays the entire outstanding, the facility closes to
        // Resolved and the WaterfallEngine fires `onDefaultResolved`.
        _repay(id, 0, 500_000e18);

        assertEq(defaultManager.declaredDefaultedPrincipal(FILM), 0, "the impairment pool is empty");
        assertEq(defaultManager.defaultedContribution(id), 0, "the facility's contribution is cleared");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "the mark is gone");
        assertEq(vault.previewRedeem(unit), exitBefore, "EXIT PRICE RESTORED EXACTLY");
        assertEq(vault.convertToAssets(unit), depositBefore, "deposit price unchanged throughout");
        assertEq(vault.redemptionTotalAssets(), vault.totalAssets(), "the two bases agree again");
        assertEq(sGrove.coverageReserve(), 100_000e18, "the backstop was never drawn on a clean recovery");
        _assertNavOrdering("clean recovery");
    }

    /// @notice A clean resolve AFTER coverage was already drawn must release the recorded
    ///         consumption, or a long-lived deployment ratchets the deduction up forever and
    ///         permanently over-marks every later default.
    function test_fork_cleanResolveAfterAPartialDrawReleasesTheConsumption() public onFork {
        _mintFromUSDC(alice, 4_000_000e6);
        _stake(alice, 2_000_000e18);
        _mintFromUSDC(ops, 1_000_000e6);
        _fundCoverage(ops, 1_000_000e18);

        // Deliberately larger than the reachable coverage, so a NON-ZERO mark exists to clear.
        uint256 id = _originateAndFundIn(FILM, keccak256("BW-REL"), 2_000_000e18, 7500);
        _declare(id);

        Layers memory got = _realizeAndVerify(id, FILM, 100_000e18);
        assertEq(got.covered, 100_000e18, "layer 2 drew while the default was live");
        assertEq(defaultManager.liveDefaultCoverageConsumed(), 100_000e18, "consumption recorded");
        // 1.9M still declared against 900k of physical shared reserve.
        assertEq(defaultManager.pendingSeniorImpairment(), 1_000_000e18, "the default still marks the NAV");

        // The borrower recovers everything still outstanding.
        uint256 outstanding = reserves.deployedTo(id);
        assertEq(outstanding, 1_900_000e18, "outstanding after the 100k write-down");
        _repay(id, 0, outstanding);

        assertEq(defaultManager.liveDefaultCoverageConsumed(), 0, "PM-R-11: a clean resolve RELEASES the consumption");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "no live default, no mark");
        assertEq(vault.redemptionTotalAssets(), vault.totalAssets(), "exit prices at the realized NAV again");

        // A LATER, unrelated default must now net the full current capacity with no residue.
        uint256 later = _originateAndFundIn(FILM, keccak256("BW-REL2"), 500_000e18, 7500);
        _declare(later);
        assertGt(sGrove.coverageCapacity(), 500_000e18, "shared reserve exceeds the later default");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "a closed-out default leaves NO residue on the next one");
        _assertNavOrdering("after release");
    }

    /// @notice Full realization (rather than recovery) also releases the consumption and clears
    ///         its ledger row, so a later default is netted against the shared reserve actually
    ///         standing at declaration.
    function test_fork_fullRealizationReleasesConsumptionAndClearsTheFloor() public onFork {
        _mintFromUSDC(alice, 4_000_000e6);
        _stake(alice, 2_000_000e18);
        _mintFromUSDC(ops, 2_000_000e6);
        _fundCoverage(ops, 1_000_000e18);

        uint256 first = _originateAndFundIn(FILM, keccak256("BW-FR1"), 400_000e18, 7500);
        _declare(first);
        _realizeAndVerify(first, FILM, 200_000e18); // partial: consumption held
        assertEq(defaultManager.liveDefaultCoverageConsumed(), 200_000e18, "held while live");
        _realizeAndVerify(first, FILM, 200_000e18); // the rest: contribution reaches zero
        assertEq(defaultManager.defaultedContribution(first), 0, "the facility is fully realized");
        assertEq(defaultManager.liveDefaultCoverageConsumed(), 0, "consumption released");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "no live default, no mark");

        // Top the reserve back up, then declare an unrelated default: with no live consumption
        // the FULL current capacity must be nettable (a stale floor would have depressed it).
        _fundCoverage(ops, 1_000_000e18);
        uint256 second = _originateAndFundIn(FILM, keccak256("BW-FR2"), 500_000e18, 7500);
        _declare(second);
        assertEq(sGrove.coverageReserve(), 1_600_000e18, "600k left after the two draws, plus the 1M top-up");
        uint256 capacityNow = sGrove.coverageCapacity();
        assertEq(capacityNow, 1_600_000e18, "capacity equals the full replenished reserve");
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            0,
            "capacity now exceeds the declared principal: a stale floor would have left a mark"
        );
        assertGt(capacityNow, 500_000e18, "sanity: the topped-up capacity fully covers this default");
        _assertNavOrdering("floor cleared");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 6. The OTHER entry points into the impairment pool and the cascade
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The MARKED-TO-MARKET fast path (ADR-0015, class 5). A PERMISSIONLESS `liquidate`
    ///         enters the same unrealized-impairment pool as `declareDefault` and marks the exit
    ///         price down, then the same three-layer cascade settles it.
    /// @dev `liquidate` is deliberately callable by anyone — the attested mark is the whole
    ///      evidence. Driven here by `carol`, who holds no role and is not even KYC'd.
    function test_fork_permissionlessLiquidationEntersTheImpairmentPoolAndCascades() public onFork {
        _mintFromUSDC(alice, 4_000_000e6);
        _stake(alice, 2_000_000e18);
        _mintFromUSDC(ops, 1_000_000e6);
        _fundCoverage(ops, 400_000e18);
        assertEq(sGrove.coverageCapacity(), 400_000e18, "the whole 400k reserve is live capacity");

        // Originated at a 33% LTV against a 1.5M mark.
        uint256 id = _originateAndFundMtm(keccak256("BW-MTM"), 500_000e18, 1_500_000e18);
        (uint256 ltvAtOrigination,) = defaultManager.currentLtvBps(id);
        assertEq(ltvAtOrigination, 3333, "LTV at origination");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "no impairment while performing");

        // The mark collapses. A strictly-newer attested valuation is required (H-02 watermark).
        _warp(1 hours);
        _attest(id, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(600_000e18)));
        (uint256 ltvAfterMark,) = defaultManager.currentLtvBps(id);
        assertEq(ltvAfterMark, 8333, "LTV breached the 8000 liquidation threshold");

        uint256 totalBefore = vault.totalAssets();
        vm.prank(carol); // PERMISSIONLESS: no role, no KYC
        defaultManager.liquidate(id);

        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Defaulted), "frozen by liquidation");
        assertEq(defaultManager.declaredDefaultedPrincipal(DIGITAL), 500_000e18, "entered the impairment pool");
        assertEq(defaultManager.defaultedContribution(id), 500_000e18, "the facility's contribution was recorded");
        assertEq(curator.unresolvedDefaults(DIGITAL), 1, "curator withdrawals frozen for the class");
        assertEq(defaultManager.pendingSeniorImpairment(), 100_000e18, "500k declared less the 400k reserve");
        assertEq(vault.totalAssets(), totalBefore, "the DEPOSIT base is untouched by a declaration");
        assertEq(vault.redemptionTotalAssets(), totalBefore - 100_000e18, "the EXIT base is marked down");

        // The same cascade settles it.
        Layers memory got = _realizeAndVerify(id, DIGITAL, 300_000e18);
        assertEq(got.absorbed, 0, "no curator capital in the digital-assets class");
        assertEq(got.covered, 300_000e18, "layer 2 funds the entire residual from shared reserve");
        assertEq(got.depositorLoss, 0, "senior stays untouched while reserve remains");
        _assertNavOrdering("mtm liquidation");
    }

    /// @notice The cascade runs identically from the ACCELERATED state, not just Defaulted.
    function test_fork_cascadeRunsFromTheAcceleratedState() public onFork {
        _mintFromUSDC(alice, 4_000_000e6);
        _stake(alice, 2_000_000e18);
        _mintFromUSDC(ops, 1_000_000e6);
        _postFirstLoss(FILM, 100_000e18);
        _fundCoverage(ops, 400_000e18);

        uint256 id = _originateAndFundIn(FILM, keccak256("BW-ACC"), 800_000e18, 7500);
        _declare(id);
        vm.prank(ops);
        defaultManager.accelerate(id);
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Accelerated), "accelerated");

        Layers memory got = _realizeAndVerify(id, FILM, 400_000e18);
        assertEq(got.absorbed, 100_000e18, "layer 1 first, from the accelerated state too");
        assertEq(got.covered, 300_000e18, "then layer 2 draws the funded residual");
        assertEq(got.depositorLoss, 0, "layer 3 is untouched while reserve remains");
        _assertNavOrdering("accelerated");
    }

    /// @notice With NO backstop wired (the pre-Phase-H shape, and the shape governance falls back
    ///         to if sGROVE is ever unwired), layer 2 simply does not exist: losses run curator ->
    ///         depositors, and the conservative NAV nets NO coverage at all.
    function test_fork_cascadeWithNoBackstopWiredGoesStraightToDepositors() public onFork {
        _mintFromUSDC(alice, 4_000_000e6);
        _stake(alice, 2_000_000e18);
        _mintFromUSDC(ops, 1_000_000e6);
        _postFirstLoss(FILM, 100_000e18);
        _fundCoverage(ops, 500_000e18); // funded, but about to be unreachable

        defaultManager.setBackstop(address(0));
        assertEq(defaultManager.backstop(), address(0), "layer 2 unwired");

        uint256 id = _originateAndFundIn(FILM, keccak256("BW-NOBS"), 800_000e18, 7500);
        _declare(id);

        // The NAV nets layer 1 per class and NOTHING for layer 2.
        assertEq(defaultManager.pendingSeniorImpairment(), 700_000e18, "800k declared less the 100k curator pool");

        uint256 reserveBefore = sGrove.coverageReserve();
        Layers memory got = _realizeAndVerify(id, FILM, 300_000e18);
        assertEq(got.absorbed, 100_000e18, "layer 1 still absorbs first");
        assertEq(got.covered, 0, "layer 2 does not exist");
        assertEq(got.depositorLoss, 200_000e18, "the residual went straight to depositors");
        assertEq(sGrove.coverageReserve(), reserveBefore, "the funded-but-unwired reserve is untouched");
        assertEq(defaultManager.liveDefaultCoverageConsumed(), 0, "nothing consumed");
        _assertNavOrdering("no backstop");
    }

    /// @notice Every guard on the cascade entry points, each with its exact custom error.
    function test_fork_cascadeAccessAndInputGuards() public onFork {
        _mintFromUSDC(alice, 3_000_000e6);
        _stake(alice, 1_000_000e18);
        _mintFromUSDC(ops, 500_000e6);
        _fundCoverage(ops, 400_000e18);

        uint256 id = _originateAndFundIn(FILM, keccak256("BW-GUARD"), 500_000e18, 7500);

        // realizeLoss on a PERFORMING facility.
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotInDefault.selector, id));
        defaultManager.realizeLoss(id, 1e18, bytes32(0));

        _declare(id);

        // zero amount.
        vm.prank(ops);
        vm.expectRevert(IDefaultManager.DefaultManager_ZeroAmount.selector);
        defaultManager.realizeLoss(id, 0, bytes32(0));

        // an unauthorized caller cannot realize a loss.
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.SERVICER_ROLE)
        );
        defaultManager.realizeLoss(id, 1e18, bytes32(0));

        // nobody outside the credit layer may drain layer 2 directly...
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.CREDIT_ROLE)
        );
        sGrove.coverShortfall(id, 1e18);

        // ...nor layer 1.
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.CREDIT_ROLE)
        );
        curator.absorbLoss(FILM, 1e18);

        // ...nor may anyone clear a live default's impairment mark.
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.CREDIT_ROLE)
        );
        defaultManager.onDefaultResolved(id);

        // Even the CREDIT_ROLE holder (the WaterfallEngine) cannot zero a STILL-DEFAULTED
        // facility's contribution — that would UNDER-mark impairment, the unsafe direction.
        vm.prank(address(waterfall));
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotResolved.selector, id));
        defaultManager.onDefaultResolved(id);

        // Curator withdrawals are frozen for the class while the default is unresolved.
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ICuratorModule.Curator_ClassDefaultFrozen.selector, FILM));
        curator.withdrawFirstLoss(FILM, 1e18);

        assertEq(defaultManager.defaultedContribution(id), 500_000e18, "the mark survived every rejected call");
        assertEq(defaultManager.pendingSeniorImpairment(), 100_000e18, "and still nets the 400k shared reserve");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 7. Layer 1 internals under the cascade
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A PARTIAL absorption dilutes every curator in the class EXACTLY pro-rata — no
    ///         curator is subordinated to another, and the senior layer is untouched throughout.
    function test_fork_partialAbsorptionDilutesEveryCuratorProRata() public onFork {
        _mintFromUSDC(alice, 4_000_000e6);
        _stake(alice, 2_000_000e18);
        _mintFromUSDC(ops, 500_000e6);
        _mintFromUSDC(bob, 500_000e6);
        curator.setCuratorApproved(FILM, bob, true);

        _postFirstLossFrom(ops, FILM, 100_000e18);
        _postFirstLossFrom(bob, FILM, 300_000e18);
        assertEq(curator.poolBalance(FILM), 400_000e18, "pool funded by two curators");
        assertEq(curator.poolShares(FILM), 400_000e18, "shares issued 1:1 into a fresh pool");
        assertEq(curator.postedOf(FILM, ops), 100_000e18, "ops posted");
        assertEq(curator.postedOf(FILM, bob), 300_000e18, "bob posted");

        uint256 id = _originateAndFundIn(FILM, keccak256("BW-PRO"), 800_000e18, 7500);
        _declare(id);

        uint256 vaultBefore = vault.totalAssets();
        Layers memory got = _realizeAndVerify(id, FILM, 200_000e18);
        assertEq(got.absorbed, 200_000e18, "layer 1 absorbed the whole loss");
        assertEq(got.depositorLoss, 0, "senior untouched");
        assertEq(vault.totalAssets(), vaultBefore, "senior is never subordinated to curator capital");

        assertEq(curator.poolBalance(FILM), 200_000e18, "half the pool remains");
        assertEq(curator.poolShares(FILM), 400_000e18, "SHARES are untouched: dilution is via the balance");
        assertEq(curator.postedOf(FILM, ops), 50_000e18, "ops diluted exactly 50%");
        assertEq(curator.postedOf(FILM, bob), 150_000e18, "bob diluted exactly 50%");
        assertEq(
            curator.postedOf(FILM, ops) + curator.postedOf(FILM, bob),
            curator.poolBalance(FILM),
            "the parts reconcile to the pool"
        );
        _assertNavOrdering("pro-rata dilution");
    }

    /// @notice Layer 1 REFILLED mid-workout: a wiped pool advances to a new share round, the
    ///         worthless old shares do not dilute the fresh capital, and the refilled layer absorbs
    ///         the next realization in full — the backstop is never asked while it has capital.
    function test_fork_wipedCuratorPoolRefillsIntoANewRoundAndAbsorbsAgain() public onFork {
        _mintFromUSDC(alice, 4_000_000e6);
        _stake(alice, 2_000_000e18);
        _mintFromUSDC(ops, 1_000_000e6);
        _postFirstLoss(FILM, 100_000e18);
        _fundCoverage(ops, 400_000e18);
        assertEq(curator.poolRound(FILM), 0, "the genesis round");

        uint256 id = _originateAndFundIn(FILM, keccak256("BW-ROUND"), 800_000e18, 7500);
        _declare(id);

        Layers memory first = _realizeAndVerify(id, FILM, 100_000e18);
        assertEq(first.absorbed, 100_000e18, "layer 1 wiped by the first realization");
        assertEq(first.covered, 0, "layer 2 never asked");
        assertEq(curator.poolBalance(FILM), 0, "the pool is empty");
        assertEq(curator.poolShares(FILM), 100_000e18, "but the worthless shares are still outstanding");
        assertEq(curator.poolRound(FILM), 0, "the round only advances on the next POST");
        assertEq(curator.postedOf(FILM, ops), 0, "a wiped stake is worth exactly zero");

        // Refill mid-workout. Posting is NOT frozen by the default (only withdrawing is).
        _postFirstLoss(FILM, 200_000e18);
        assertEq(curator.poolRound(FILM), 1, "the wipe-out advanced the share round");
        assertEq(curator.poolShares(FILM), 200_000e18, "stale shares were cleared, not carried");
        assertEq(curator.postedOf(FILM, ops), 200_000e18, "the fresh capital is NOT diluted by the old round");

        uint256 reserveBefore = sGrove.coverageReserve();
        Layers memory second = _realizeAndVerify(id, FILM, 150_000e18);
        assertEq(second.absorbed, 150_000e18, "the REFILLED layer 1 absorbs before layer 2, again");
        assertEq(second.covered, 0, "layer 2 still never asked");
        assertEq(second.depositorLoss, 0, "senior still untouched");
        assertEq(sGrove.coverageReserve(), reserveBefore, "the backstop reserve is exactly untouched");
        assertEq(curator.poolBalance(FILM), 50_000e18, "what the refill left over");
        _assertNavOrdering("refilled layer 1");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 8. Bounded fuzz over the cascade split
    // ─────────────────────────────────────────────────────────────────────

    /// @notice FUZZ: for any absorbable loss, the split is exactly
    ///         `min(loss, curatorPool)` / `min(residual, eventRoom)` / remainder, and the ordering
    ///         never inverts. `_realizeAndVerify` checks the split against the independent model
    ///         from both the balance deltas and the emitted event.
    /// @dev Pinned at the CLAUDE.md §1.4 critical-suite floor (>= 10,000 runs) even though each
    ///      case re-executes the whole cascade on the fork. Measured cost: ~36s for this test.
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_fork_cascadeSplitAndOrdering(uint256 lossSeed) public onFork {
        _assertCascadeSplitAndOrdering(lossSeed);
    }

    /// @notice Deterministic promotion of the saved Foundry fuzz counterexample for this property.
    /// @dev The predecessor lived only in cache/fuzz/failures, where removing or renaming the fuzz
    ///      target could silently orphan it. Keep this ordinary test even while the fuzz campaign
    ///      remains green.
    function test_regression_persistedCascadeSplitBoundary() public onFork {
        _assertCascadeSplitAndOrdering(0xf589);
    }

    function _assertCascadeSplitAndOrdering(uint256 lossSeed) internal {
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 3_000_000e18);
        _mintFromUSDC(ops, 1_000_000e6);
        _postFirstLoss(FILM, 150_000e18);
        _fundCoverage(ops, 500_000e18); // one shared layer-two reserve

        uint256 id = _originateAndFundIn(FILM, keccak256("BW-FZ1"), 1_000_000e18, 7500);
        _declare(id);

        uint256 loss = bound(lossSeed, 1, 1_000_000e18);
        Layers memory got = _realizeAndVerify(id, FILM, loss);

        assertEq(got.absorbed, loss < 150_000e18 ? loss : 150_000e18, "layer 1 takes min(loss, pool)");
        uint256 residual = loss - got.absorbed;
        assertEq(got.covered, residual < 500_000e18 ? residual : 500_000e18, "layer 2 takes min(residual, reserve)");
        assertEq(got.depositorLoss, residual - got.covered, "layer 3 takes only what is left");
        assertLe(got.covered, 500_000e18, "ADR-0035: never beyond physical reserve");
        assertLe(vault.redemptionTotalAssets(), vault.totalAssets(), "exit base <= deposit base");
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "backing invariant");
    }

    /// @notice FUZZ: chunking ONE facility's loss across two arbitrary realizations can never draw
    ///         more sGROVE coverage in total than the shared reserve initially funded.
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_fork_chunkedRealizationNeverExceedsTheSharedReserve(uint256 seedA, uint256 seedB) public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 3_000_000e18);
        _mintFromUSDC(ops, 1_000_000e6);
        _fundCoverage(ops, 1_000_000e18);

        uint256 id = _originateAndFundIn(FILM, keccak256("BW-FZ2"), 1_500_000e18, 7500);
        _declare(id);

        uint256 chunkA = bound(seedA, 1, 700_000e18);
        uint256 chunkB = bound(seedB, 1, 700_000e18);

        Layers memory a = _realizeAndVerify(id, FILM, chunkA);
        (uint256 drawnA, uint256 capA) = sGrove.eventCoverage(id);
        assertEq(capA, 1_000_000e18, "drawn plus reserve preserves the initial funded amount");
        assertEq(drawnA, a.covered, "cumulative draw after chunk A");

        Layers memory b = _realizeAndVerify(id, FILM, chunkB);
        (uint256 drawnB, uint256 capB) = sGrove.eventCoverage(id);
        assertEq(capB, capA, "cumulative draw plus live reserve remains conserved");
        assertEq(drawnB, a.covered + b.covered, "cumulative draw after chunk B");
        assertLe(drawnB, capB, "cumulative delivery never exceeds initial physical funding");
        uint256 totalLoss = chunkA + chunkB;
        uint256 expectedCovered = totalLoss < 1_000_000e18 ? totalLoss : 1_000_000e18;
        assertEq(drawnB, expectedCovered, "chunking cannot change aggregate shared-reserve delivery");
        assertEq(sGrove.coverageReserve(), 1_000_000e18 - expectedCovered, "reserve delta equals delivery");
        assertEq(
            a.absorbed + a.covered + a.depositorLoss + b.absorbed + b.covered + b.depositorLoss,
            totalLoss,
            "value conservation across both chunks"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // helpers (private to this file; the shared fixture is untouched)
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Originate in an ARBITRARY class with an arbitrary borrowerId, through the real 2-of-n
    ///      mint gate, then fund it with REAL USDC.
    function _originateAndFundIn(uint256 classId, bytes32 borrowerId, uint256 principal, uint16 ltvBps)
        internal
        returns (uint256 tokenId)
    {
        tokenId = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + 365 days);
        bytes32 ref = keccak256(abi.encode("ref", tokenId));
        bytes32 stateId = classId == Config.CLASS_FILM_TAX_CREDITS ? keccak256("US-GA") : bytes32(0);
        ClaimBridge.OriginationTerms memory terms =
            _forkTermsFor(classId, borrowerId, stateId, principal, ltvBps, 1000, maturity, ref);
        bytes32 termsHash = bridge.creditTermsHash(terms);
        _attest(tokenId, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash);
        if (classId != Config.CLASS_DIGITAL_ASSETS) {
            _attest(tokenId, IAttestationOracle.AttestationKind.UCCFiled, termsHash);
        }
        // AUDIT FIX (H-4): the CreditIssued quorum commits to these exact terms.
        _attest(tokenId, IAttestationOracle.AttestationKind.CreditIssued, termsHash);

        vm.prank(ops);
        uint256 id = bridge.originate(ops, terms);
        require(id == tokenId, "CascadeNavFork: tokenId drift");

        vm.prank(ops);
        waterfall.fund(tokenId, principal / 1e12);
    }

    /// @dev Originate and fund a MARKED-TO-MARKET (digital-assets, class 5) facility. Its mint
    ///      gate is AssignmentExecuted + Valuation + CreditIssued (AUDIT FIX H-4), and the draw
    ///      is bounded by the attested mark.
    function _originateAndFundMtm(bytes32 borrowerId, uint256 principal, uint256 markValue)
        internal
        returns (uint256 tokenId)
    {
        tokenId = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + 365 days);
        bytes32 ref = keccak256(abi.encode("ref", tokenId));
        ClaimBridge.OriginationTerms memory terms =
            _forkTermsFor(DIGITAL, borrowerId, bytes32(0), principal, 5000, 1000, maturity, ref);
        bytes32 termsHash = bridge.creditTermsHash(terms);
        _attest(tokenId, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash);
        _attest(tokenId, IAttestationOracle.AttestationKind.Valuation, bytes32(markValue));
        // AUDIT FIX (H-4): CreditIssued is required on EVERY class gate now, bound to the terms.
        _attest(tokenId, IAttestationOracle.AttestationKind.CreditIssued, termsHash);

        vm.prank(ops);
        uint256 id = bridge.originate(ops, terms);
        require(id == tokenId, "CascadeNavFork: tokenId drift");

        vm.prank(ops);
        waterfall.fund(tokenId, principal / 1e12);
    }

    /// @dev Attest and declare a default through the real servicer path.
    function _declare(uint256 tokenId) internal {
        bytes32 evidenceHash = keccak256(abi.encode("d", tokenId));
        _attest(
            tokenId, IAttestationOracle.AttestationKind.DefaultDeclared, keccak256(abi.encode(tokenId, evidenceHash))
        );
        vm.prank(ops);
        defaultManager.declareDefault(tokenId, evidenceHash);
    }

    /// @dev Permissionless coverage funding from an arbitrary holder.
    function _fundCoverage(address who, uint256 amount) internal {
        vm.startPrank(who);
        usdfr.approve(address(sGrove), amount);
        sGrove.fundCoverage(amount);
        vm.stopPrank();
    }

    /// @dev Post curator first-loss for a class as the anchor curator (`ops`).
    function _postFirstLoss(uint256 classId, uint256 amount) internal {
        _postFirstLossFrom(ops, classId, amount);
    }

    /// @dev Post curator first-loss from an arbitrary approved curator.
    function _postFirstLossFrom(address who, uint256 classId, uint256 amount) internal {
        vm.startPrank(who);
        usdfr.approve(address(curator), amount);
        curator.postFirstLoss(classId, amount);
        vm.stopPrank();
    }

    /// @dev INDEPENDENT MODEL of what `coverShortfall` will deliver for `tokenId` right now:
    ///      every wired event reaches the same physical shared reserve.
    function _eventRoom(uint256 tokenId) internal view returns (uint256) {
        uint256 room = _eventRoomUnclamped(tokenId);
        uint256 reserve = sGrove.coverageReserve();
        return room < reserve ? room : reserve;
    }

    /// @dev As `_eventRoom`, before the aggregate floor clamps the shared reserve once across all
    ///      live events. Under ADR-0035 this is the reserve itself for every wired event.
    function _eventRoomUnclamped(uint256 tokenId) internal view returns (uint256) {
        // The model must mirror the WIRING: with no backstop set, layer 2 does not exist at all.
        if (defaultManager.backstop() != address(sGrove)) return 0;
        tokenId; // event identity deliberately cannot change shared physical reach
        return sGrove.coverageReserve();
    }

    /// @dev The TRUE conservative floor for a single live default: its remaining declared
    ///      contribution, less the coverage it can genuinely still reach. `pendingSeniorImpairment`
    ///      must never report BELOW this.
    function _trueFloorFor(uint256 tokenId) internal view returns (uint256) {
        uint256[] memory one = new uint256[](1);
        one[0] = tokenId;
        return _trueAggregateFloor(one);
    }

    /// @dev The TRUE conservative floor across several live defaults, recomputed from first
    ///      principles: per-class residual after curator first-loss, less the MAXIMUM coverage the
    ///      live events could collectively still draw (their summed rooms, clamped by the one
    ///      shared reserve). Assuming the largest reachable coverage yields the LOWEST admissible
    ///      mark, so `reported >= this` is the safety property.
    function _trueAggregateFloor(uint256[] memory tokenIds) internal view returns (uint256) {
        uint256 residual;
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            uint256 d = defaultManager.declaredDefaultedPrincipal(classId);
            if (d == 0) continue;
            uint256 pool = curator.poolBalance(classId);
            if (d > pool) residual += d - pool;
        }
        uint256 rooms;
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            rooms += _eventRoomUnclamped(tokenIds[i]);
        }
        uint256 reserve = sGrove.coverageReserve();
        uint256 reachable = rooms < reserve ? rooms : reserve;
        return residual > reachable ? residual - reachable : 0;
    }

    /// @dev Runs `realizeLoss` and verifies the (layer 1, layer 2, layer 3) split against the
    ///      independent model, from BOTH the observed balance deltas and the `LossRealized` event,
    ///      and asserts the ordering can never invert or skip a layer.
    function _realizeAndVerify(uint256 tokenId, uint256 classId, uint256 loss) internal returns (Layers memory got) {
        uint256 curatorBefore = curator.poolBalance(classId);
        uint256 reserveBefore = sGrove.coverageReserve();
        uint256 roomBefore = _eventRoom(tokenId);
        uint256 vaultBefore = vault.totalAssets();

        Layers memory want;
        want.absorbed = loss < curatorBefore ? loss : curatorBefore;
        uint256 residual = loss - want.absorbed;
        want.covered = residual < roomBefore ? residual : roomBefore;
        want.depositorLoss = residual - want.covered;

        bytes32 lossEvidence = _attestLoss(tokenId, loss, bytes32(0));
        vm.recordLogs();
        vm.prank(ops);
        defaultManager.realizeLoss(tokenId, loss, lossEvidence);

        got.absorbed = curatorBefore - curator.poolBalance(classId);
        got.covered = reserveBefore - sGrove.coverageReserve();
        got.depositorLoss = vaultBefore - vault.totalAssets();

        // 1. The split matches the independent model, exactly.
        assertEq(got.absorbed, want.absorbed, "layer 1 (curator) absorbed the modelled amount");
        assertEq(got.covered, want.covered, "layer 2 (sGROVE) covered the modelled amount");
        assertEq(got.depositorLoss, want.depositorLoss, "layer 3 (senior) took the modelled amount");

        // 2. Value conservation: nothing created, nothing destroyed.
        assertEq(got.absorbed + got.covered + got.depositorLoss, loss, "the cascade allocates the loss exactly");

        // 3. ORDERING. Layer 2 is only reachable once layer 1 is EMPTY; layer 3 only once BOTH
        //    junior layers are exhausted for this event.
        if (got.covered != 0) {
            assertEq(curator.poolBalance(classId), 0, "ORDERING: layer 2 drew only after layer 1 was emptied");
        }
        if (got.depositorLoss != 0) {
            assertEq(curator.poolBalance(classId), 0, "ORDERING: layer 3 only after layer 1 was emptied");
            assertEq(_eventRoom(tokenId), 0, "ORDERING: layer 3 only after layer 2 had no room left");
        }

        // 4. The emitted record must agree with what actually moved.
        _assertLossRealizedEvent(tokenId, classId, loss, got);

        // 5. The backing invariant survives every realization.
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "BACKING INVARIANT holds after realizeLoss");
        // 6. And the exit price never rises above the deposit price.
        assertLe(vault.redemptionTotalAssets(), vault.totalAssets(), "redemption NAV <= deposit NAV");
    }

    /// @dev Locates the `LossRealized` record and asserts it matches the observed movements.
    function _assertLossRealizedEvent(uint256 tokenId, uint256 classId, uint256 loss, Layers memory got) private view {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].emitter != address(defaultManager)) continue;
            if (entries[i].topics.length != 3 || entries[i].topics[0] != LOSS_REALIZED_SIG) continue;
            assertEq(uint256(entries[i].topics[1]), tokenId, "event: tokenId");
            assertEq(uint256(entries[i].topics[2]), classId, "event: classId");
            (uint256 lossE, uint256 absorbedE, uint256 coveredE, uint256 depositorE) =
                abi.decode(entries[i].data, (uint256, uint256, uint256, uint256));
            assertEq(lossE, loss, "event: loss");
            assertEq(absorbedE, got.absorbed, "event: curatorAbsorbed matches the observed movement");
            assertEq(coveredE, got.covered, "event: backstopCovered matches the observed movement");
            assertEq(depositorE, got.depositorLoss, "event: depositorLoss matches the observed movement");
            found = true;
        }
        assertTrue(found, "LossRealized was emitted");
    }

    /// @dev The ADR-0022 exit/deposit ordering, checked on both the asset base and the price.
    function _assertNavOrdering(string memory label) internal view {
        assertLe(
            vault.redemptionTotalAssets(), vault.totalAssets(), string.concat(label, ": redemption base <= total base")
        );
        uint256 unit = 10 ** vault.decimals();
        assertLe(
            vault.previewRedeem(unit),
            vault.convertToAssets(unit),
            string.concat(label, ": exit price <= deposit price")
        );
    }

    function _ids2(uint256 a, uint256 b) private pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
    }

    function _ids3(uint256 a, uint256 b, uint256 c) private pure returns (uint256[] memory ids) {
        ids = new uint256[](3);
        ids[0] = a;
        ids[1] = b;
        ids[2] = c;
    }
}
