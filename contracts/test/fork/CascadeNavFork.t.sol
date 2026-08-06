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
///        mainnet fork, against the REAL deployed stack and REAL USDC.
///
/// @notice `FullLifecycleFork` proves ONE three-layer cascade runs end to end. This suite goes
///         after the two mechanisms that have each produced multiple audit findings and whose
///         interaction is the subtlest thing in the protocol:
///
///         PM-R-07 — the sGROVE per-EVENT coverage cap is CUMULATIVE and SNAPSHOTTED at the
///         event's first draw. Before that fix, `coverShortfall` recomputed `reserve * capBps`
///         on every call, so chunking one facility's loss across several `realizeLoss` calls drew
///         50%, then 50% of the remainder, and so on — approaching the whole reserve and silently
///         voiding the staker protection ADR-0021 advertises.
///
///         PM-R-11 — `pendingSeniorImpairment()` must never mark BELOW the true conservative
///         floor. It netted the residual against the GLOBAL `coverageCapacity()`, which describes
///         what a *fresh* event could draw; an event that has already drawn can only reach
///         `snapshot - drawn`. Three separate revisions of that fix were needed: the raw netting,
///         then a live-capacity netting re-inflated by a permissionless `fundCoverage` or a
///         `setPerEventCap` raise, then a drain-to-zero/refill that re-seeded the pinned floor.
///
///         All three PM-R-11 variants, the PM-R-07 chunking guarantee, the cascade ORDERING
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
///        PM-R-07's per-event reach and PM-R-11's conservative floor, recomputed from first
///        principles rather than trusting the contract's own view (CLAUDE.md §1.5, differential
///        testing).
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
    // 1. PM-R-07 — the per-EVENT cap is cumulative and snapshotted
    // ─────────────────────────────────────────────────────────────────────

    /// @notice ONE facility's loss, realized in FIVE chunks, can never draw more sGROVE coverage
    ///         in total than the cap snapshotted at its FIRST draw.
    /// @dev The pre-PM-R-07 per-CALL cap would have covered all 750,000 (50% of the *current*
    ///      reserve exceeds every 150,000 chunk), leaving depositors untouched. The cumulative cap
    ///      stops at exactly 500,000 and pushes the remaining 250,000 onto the senior layer —
    ///      which is precisely the exposure bound an sGROVE staker is promised.
    function test_fork_perEventCapIsCumulativeAndSnapshottedAtFirstDraw() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 4_000_000e18);
        _mintFromUSDC(ops, 1_000_000e6);
        _fundCoverage(ops, 1_000_000e18);

        assertEq(sGrove.coverageReserve(), 1_000_000e18, "coverage reserve seeded");
        assertEq(sGrove.coverageCapacity(), 500_000e18, "a fresh event may draw 50% of the reserve");
        assertEq(curator.poolBalance(FILM), 0, "precondition: empty curator pool isolates layer 2");

        uint256 id = _originateAndFundIn(FILM, keccak256("BW-CHUNK"), 2_000_000e18, 7500);
        _declare(id);

        (, uint256 capBeforeAnyDraw) = sGrove.eventCoverage(id);
        assertEq(capBeforeAnyDraw, 0, "no snapshot exists until the first draw");

        uint256 vaultAtStart = vault.totalAssets();
        uint256 totalCovered;
        uint256 totalDepositor;
        for (uint256 i = 0; i < 5; ++i) {
            Layers memory got = _realizeAndVerify(id, FILM, 150_000e18);
            totalCovered += got.covered;
            totalDepositor += got.depositorLoss;
            assertEq(got.absorbed, 0, "layer 1 is empty in this scenario");

            (uint256 drawn, uint256 cap) = sGrove.eventCoverage(id);
            assertEq(cap, 500_000e18, "the cap stays pinned at the FIRST draw's snapshot");
            assertLe(drawn, cap, "PM-R-07: cumulative draw never exceeds the snapshotted cap");
            assertEq(drawn, totalCovered, "the event's cumulative draw is exactly what was delivered");
        }

        // The exact chunk-by-chunk split: 150k, 150k, 150k, then 50k (the cap's last room), then 0.
        assertEq(totalCovered, 500_000e18, "PM-R-07: the EVENT drew exactly its snapshotted cap, no more");
        assertEq(totalDepositor, 250_000e18, "the residual 250k reached the senior layer");
        assertEq(totalCovered + totalDepositor, 750_000e18, "value conservation across all five chunks");
        assertEq(sGrove.coverageReserve(), 500_000e18, "half the reserve SURVIVES this event (ADR-0014)");
        assertEq(vaultAtStart - vault.totalAssets(), 250_000e18, "senior absorbed exactly the uncovered residual");
        assertEq(defaultManager.liveDefaultCoverageConsumed(), 500_000e18, "PM-R-11 tracks the consumption");
        assertEq(
            defaultManager.defaultedContribution(id),
            2_000_000e18 - 750_000e18,
            "the facility's unrealized contribution fell by exactly the realized loss"
        );
        _assertNavOrdering("chunked realization");
    }

    /// @notice A SECOND (and third) event re-snapshots against the SMALLER remaining reserve, so a
    ///         residual backstop survives every successive credit event.
    function test_fork_secondEventReSnapshotsAgainstTheSmallerReserve() public onFork {
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
        assertEq(la.covered, 500_000e18, "event A drew its full cap");
        assertEq(la.depositorLoss, 0, "layer 2 covered A entirely");
        assertEq(sGrove.coverageReserve(), 500_000e18, "reserve halved");

        Layers memory lb = _realizeAndVerify(b, FILM, 400_000e18);
        (, uint256 capB) = sGrove.eventCoverage(b);
        assertEq(capB, 250_000e18, "event B re-snapshots against the SMALLER reserve (50% of 500k)");
        assertEq(lb.covered, 250_000e18, "B could only draw its own, smaller cap");
        assertEq(lb.depositorLoss, 150_000e18, "the rest reached the senior layer");
        assertEq(sGrove.coverageReserve(), 250_000e18, "reserve halved again");

        Layers memory lc = _realizeAndVerify(c, FILM, 125_000e18);
        (, uint256 capC) = sGrove.eventCoverage(c);
        assertEq(capC, 125_000e18, "event C re-snapshots smaller still");
        assertEq(lc.covered, 125_000e18, "C drew within its cap");
        assertEq(lc.depositorLoss, 0, "C needed no senior absorption");

        assertGt(sGrove.coverageReserve(), 0, "ADR-0014: a residual backstop survives every event");
        assertEq(sGrove.coverageReserve(), 125_000e18, "and its size is exactly the geometric remainder");
        assertGt(capB, capC, "each successive event's ceiling is strictly smaller");
        assertGt(500_000e18, capB, "and strictly below the first event's ceiling");
        _assertNavOrdering("successive events");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. Cascade ORDERING — never skipped, never inverted
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A loss inside the curator pool must leave the backstop and the senior layer
    ///         EXACTLY untouched — the sGROVE event must not even be snapshotted.
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
        assertEq(cap, 0, "and no per-event cap was ever snapshotted");
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
        Layers memory s1 = _realizeAndVerify(f1, FILM, 100_000e18);
        assertEq(s1.absorbed, 100_000e18, "s1: FILM curator absorbed");
        assertEq(s1.covered, 0, "s1: backstop untouched");
        assertEq(s1.depositorLoss, 0, "s1: senior untouched");

        // 2. RENEWABLE loss with NO first-loss in that class: it must go straight to the backstop
        //    and must NOT reach into FILM's curator pool.
        Layers memory s2 = _realizeAndVerify(f2, RENEWABLE, 100_000e18);
        assertEq(s2.absorbed, 0, "s2: RENEWABLE has no curator capital to absorb");
        assertEq(s2.covered, 100_000e18, "s2: the shared backstop absorbed it");
        assertEq(s2.depositorLoss, 0, "s2: senior untouched");
        assertEq(
            curator.poolBalance(FILM),
            100_000e18,
            "CROSS-CLASS ISOLATION: a FILM curator pool never absorbs a RENEWABLE loss"
        );

        // 3. FILM loss that drains layer 1 and spills into layer 2.
        Layers memory s3 = _realizeAndVerify(f1, FILM, 250_000e18);
        assertEq(s3.absorbed, 100_000e18, "s3: layer 1 drained to zero FIRST");
        assertEq(s3.covered, 150_000e18, "s3: only then did layer 2 draw");
        assertEq(s3.depositorLoss, 0, "s3: senior untouched");
        assertEq(curator.poolBalance(FILM), 0, "s3: FILM first-loss fully wiped");

        // 4. RENEWABLE loss exhausting f2's own event cap: the overflow reaches senior.
        Layers memory s4 = _realizeAndVerify(f2, RENEWABLE, 300_000e18);
        assertEq(s4.absorbed, 0, "s4: no curator capital in RENEWABLE");
        assertEq(s4.covered, 200_000e18, "s4: f2's event cap had 200k of room left");
        assertEq(s4.depositorLoss, 100_000e18, "s4: senior took only the uncoverable remainder");

        // 5. FILM loss with layer 1 gone and f1's event cap partly spent.
        Layers memory s5 = _realizeAndVerify(f1, FILM, 200_000e18);
        assertEq(s5.absorbed, 0, "s5: layer 1 is exhausted");
        assertEq(s5.covered, 100_000e18, "s5: f1's remaining event room");
        assertEq(s5.depositorLoss, 100_000e18, "s5: senior took the remainder");

        // 6. RENEWABLE again with f2's cap fully spent: senior only.
        Layers memory s6 = _realizeAndVerify(f2, RENEWABLE, 100_000e18);
        assertEq(s6.absorbed, 0, "s6: no layer 1");
        assertEq(s6.covered, 0, "s6: f2's event cap is fully consumed");
        assertEq(s6.depositorLoss, 100_000e18, "s6: senior absorbed alone");

        // Aggregate conservation across the whole run.
        uint256 totalLoss = 100_000e18 + 100_000e18 + 250_000e18 + 300_000e18 + 200_000e18 + 100_000e18;
        uint256 totalAbsorbed = s1.absorbed + s2.absorbed + s3.absorbed + s4.absorbed + s5.absorbed + s6.absorbed;
        uint256 totalCovered = s1.covered + s2.covered + s3.covered + s4.covered + s5.covered + s6.covered;
        uint256 totalSenior = s1.depositorLoss + s2.depositorLoss + s3.depositorLoss + s4.depositorLoss
            + s5.depositorLoss + s6.depositorLoss;
        assertEq(totalLoss, 1_050_000e18, "the run realized 1.05M of loss");
        assertEq(totalAbsorbed, 200_000e18, "layer 1 contributed exactly the posted first-loss");
        assertEq(totalCovered, 550_000e18, "layer 2 contributed exactly both events' caps");
        assertEq(totalSenior, 300_000e18, "layer 3 contributed only the true residual");
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

        _attestLoss(id, 500_000e18, bytes32(0));
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_LossExceedsAbsorptionCapacity.selector, id, 500_000e18, vaultAssets
            )
        );
        defaultManager.realizeLoss(id, 500_000e18, bytes32(0));

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
    // 3. PM-R-11 — the conservative NAV never under-marks (three variants)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice VARIANT 1 (the original finding). After a PARTIAL realization has consumed part of
    ///         the event's snapshotted cap, the reported impairment is at or above the true
    ///         conservative floor — never below it.
    function test_fork_navNeverUnderMarksAfterPartialRealization() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 3_000_000e18);
        _mintFromUSDC(ops, 1_000_000e6);
        _fundCoverage(ops, 1_000_000e18);
        assertEq(curator.poolBalance(FILM), 0, "empty curator pool isolates layer 2");

        uint256 freshCapacity = sGrove.coverageCapacity();
        assertEq(freshCapacity, 500_000e18, "50% of the 1M reserve");

        uint256 principal = 2_000_000e18;
        uint256 id = _originateAndFundIn(FILM, keccak256("BW-V1"), principal, 7500);
        _declare(id);

        // Before any draw the mark is EXACT: the full fresh capacity is legitimately nettable.
        assertEq(defaultManager.liveDefaultCoverageConsumed(), 0, "nothing consumed yet");
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            principal - freshCapacity,
            "pre-draw: reported == principal less the full fresh capacity"
        );
        assertEq(defaultManager.pendingSeniorImpairment(), _trueFloorFor(id), "pre-draw: reported == true floor");

        uint256 partialLoss = freshCapacity * 3 / 5; // 300k, entirely absorbed by layer 2
        Layers memory got = _realizeAndVerify(id, FILM, partialLoss);
        assertEq(got.covered, partialLoss, "layer 2 absorbed the whole partial loss");

        (uint256 drawn, uint256 snapshot) = sGrove.eventCoverage(id);
        assertEq(drawn, 300_000e18, "drawn");
        assertEq(snapshot, 500_000e18, "the cap was snapshotted at the first draw");
        assertEq(defaultManager.liveDefaultCoverageConsumed(), 300_000e18, "consumption tracked");

        uint256 reported = defaultManager.pendingSeniorImpairment();
        uint256 trueFloor = _trueFloorFor(id);

        // THE PROPERTY. Before PM-R-11 this read BELOW the floor and a queued senior exited above
        // the true conservative price, pushing the difference onto the seniors who stayed.
        assertGe(reported, trueFloor, "PM-R-11: reported impairment is NEVER below the true floor");

        // The exact arithmetic on the fork: remaining declared, less (capacity - consumed).
        uint256 remainingDeclared = principal - partialLoss;
        assertEq(remainingDeclared, 1_700_000e18, "remaining declared principal");
        assertEq(sGrove.coverageCapacity(), 350_000e18, "capacity recomputed on the 700k reserve");
        assertEq(reported, remainingDeclared - (350_000e18 - 300_000e18), "nets capacity MINUS consumed coverage");
        assertEq(reported, 1_650_000e18, "the exact conservative mark");
        assertEq(trueFloor, 1_500_000e18, "the true floor (event room 200k, reserve 700k)");
        _assertNavOrdering("variant 1");
    }

    /// @notice VARIANT 2. A PERMISSIONLESS `fundCoverage` top-up after a partial draw must not
    ///         hand the drawn default coverage it can no longer reach.
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
        assertEq(sGrove.coverageReserve(), 2_700_000e18, "the top-up landed");

        uint256 markAfter = defaultManager.pendingSeniorImpairment();
        assertEq(markAfter, markBefore, "a top-up must NOT lower the mark for an already-drawn default");
        assertGe(markAfter, _trueFloorFor(id), "still at or above the true conservative floor");
        _assertNavOrdering("variant 2");
    }

    /// @notice VARIANT 3. Governance raising `perEventCapBps` after a partial draw must not
    ///         re-inflate the netting either.
    function test_fork_navNeverUnderMarksAfterPerEventCapRaise() public onFork {
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
        sGrove.setPerEventCap(uint16(Config.BPS)); // 100% — the largest possible raise
        (, uint16 capBpsNow) = sGrove.params();
        assertEq(capBpsNow, uint16(Config.BPS), "the raise really took effect");
        assertGt(sGrove.coverageCapacity(), capacityBefore, "precondition: capacity really did jump");

        assertEq(
            defaultManager.pendingSeniorImpairment(),
            markBefore,
            "a cap raise must NOT lower the mark for an already-drawn default"
        );
        assertGe(defaultManager.pendingSeniorImpairment(), _trueFloorFor(id), "still conservative");
        _assertNavOrdering("variant 3");
    }

    /// @notice VARIANT 3b (the round-3 follow-up). DRAIN the reserve to zero, then REFILL it. The
    ///         pinned capacity floor must NOT be re-seeded at the post-refill capacity — zero is a
    ///         LEGITIMATE floor, not an "unset" sentinel.
    function test_fork_navNeverUnderMarksAfterDrainToZeroThenRefill() public onFork {
        deal(USDC, alice, 12_000_000e6);
        _mintFromUSDC(alice, 12_000_000e6);
        _stake(alice, 8_000_000e18);
        _mintFromUSDC(ops, 5_000_000e6);
        _fundCoverage(ops, 1_000_000e18);

        // A snapshots its cap against the FULL 1M reserve by drawing a single wei.
        uint256 a = _originateAndFundIn(FILM, keccak256("BW-D-A"), 3_000_000e18, 7500);
        _declare(a);
        _realizeAndVerify(a, FILM, 1);
        (, uint256 snapA) = sGrove.eventCoverage(a);
        assertEq(snapA, 500_000e18, "A's cap snapshotted against the full 1M reserve");

        // B and C draw the reserve down below A's (larger, earlier) snapshot.
        uint256 b = _originateAndFundIn(FILM, keccak256("BW-D-B"), 2_000_000e18, 7500);
        _declare(b);
        _realizeAndVerify(b, FILM, 500_000e18);

        uint256 c = _originateAndFundIn(FILM, keccak256("BW-D-C"), 1_000_000e18, 7500);
        _declare(c);
        _realizeAndVerify(c, FILM, 250_000e18);
        assertLt(sGrove.coverageReserve(), snapA, "reserve now strictly below A's snapshot");

        // A draws again: its room exceeds what is left, so `covered` clamps to the reserve and
        // takes it to zero, driving the capacity — and therefore the pinned floor — to zero.
        Layers memory drain = _realizeAndVerify(a, FILM, 600_000e18);
        assertEq(drain.covered, 250_000e18, "clamped to the remaining reserve, not to A's room");
        assertEq(sGrove.coverageReserve(), 0, "reserve fully drained");
        assertEq(sGrove.coverageCapacity(), 0, "capacity, and so the pinned floor, is now zero");
        assertGt(defaultManager.liveDefaultCoverageConsumed(), 0, "live defaults hold consumption");

        // Anyone refills, hugely. This must NOT lift the pinned floor.
        _fundCoverage(ops, 4_000_000e18);
        assertGt(sGrove.coverageCapacity(), 0, "precondition: capacity jumped back");

        // A further draw by a STILL-LIVE default must not re-seed the floor upward.
        _realizeAndVerify(a, FILM, 100_000e18);

        uint256 reported = defaultManager.pendingSeniorImpairment();
        assertGe(
            reported, _trueAggregateFloor(_ids3(a, b, c)), "round 3: drain-then-refill stays at or above the floor"
        );
        // The floor is pinned at ZERO, so nothing at all is netted: the mark equals the raw
        // residual. A re-seeded floor would have netted ~1.95M of unreachable coverage.
        uint256 residual = defaultManager.declaredDefaultedPrincipal(FILM); // curator pool is empty
        assertEq(curator.poolBalance(FILM), 0, "no layer 1 to net per class");
        assertEq(reported, residual, "floor pinned at zero: NOTHING is netted against the live defaults");
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
        assertEq(sGrove.coverageCapacity(), 100_000e18, "50% of the 200k reserve");

        uint256 f1 = _originateAndFundIn(FILM, keccak256("BW-M1"), 500_000e18, 7500);
        uint256 f2 = _originateAndFundIn(RENEWABLE, keccak256("BW-M2"), 200_000e18, 7000);
        _declare(f1);
        _declare(f2);

        // residual = (500k FILM - 100k FILM curator) + max(0, 200k RE - 300k RE curator) = 400k.
        // Then net the global backstop capacity of 100k -> 300k.
        assertEq(defaultManager.declaredDefaultedPrincipal(FILM), 500_000e18, "FILM declared");
        assertEq(defaultManager.declaredDefaultedPrincipal(RENEWABLE), 200_000e18, "RENEWABLE declared");
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            300_000e18,
            "an over-collateralised class contributes ZERO residual; the rest nets the global backstop"
        );

        // Now realize part of the FILM loss so a per-event consumption exists, and recompute.
        Layers memory got = _realizeAndVerify(f1, FILM, 150_000e18);
        assertEq(got.absorbed, 100_000e18, "FILM layer 1 drained first");
        assertEq(got.covered, 50_000e18, "then layer 2");
        assertEq(got.depositorLoss, 0, "senior untouched");

        // residual = 350k (FILM, curator now 0) + 0 (RENEWABLE) = 350k.
        // capacity = 50% of 150k = 75k; floor pinned at 75k; consumed 50k -> nettable 25k.
        assertEq(sGrove.coverageReserve(), 150_000e18, "reserve after the draw");
        assertEq(sGrove.coverageCapacity(), 75_000e18, "capacity after the draw");
        assertEq(defaultManager.liveDefaultCoverageConsumed(), 50_000e18, "consumed by the live default");
        assertEq(defaultManager.pendingSeniorImpairment(), 325_000e18, "exact conservative mark after the draw");
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

        sGrove.setPerEventCap(uint16(Config.BPS));
        _assertNavOrdering("after a cap raise");

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
        assertEq(defaultManager.pendingSeniorImpairment(), 500_000e18 - 50_000e18, "declared less the 50k capacity");
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
        // 1.9M still declared; capacity 450k on the 900k reserve, less 100k already consumed.
        assertEq(defaultManager.pendingSeniorImpairment(), 1_550_000e18, "the default still marks the NAV");

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
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            500_000e18 - sGrove.coverageCapacity(),
            "a closed-out default leaves NO residue on the next one"
        );
        _assertNavOrdering("after release");
    }

    /// @notice Full realization (rather than recovery) also releases the consumption and clears
    ///         the pinned capacity floor, so a later default is netted against the capacity
    ///         actually standing at its OWN draw.
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
        assertEq(capacityNow, 800_000e18, "50% of the 1.6M reserve");
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
        assertEq(sGrove.coverageCapacity(), 200_000e18, "50% of the 400k reserve");

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
        assertEq(defaultManager.pendingSeniorImpairment(), 300_000e18, "500k declared less the 200k capacity");
        assertEq(vault.totalAssets(), totalBefore, "the DEPOSIT base is untouched by a declaration");
        assertEq(vault.redemptionTotalAssets(), totalBefore - 300_000e18, "the EXIT base is marked down");

        // The same cascade settles it.
        Layers memory got = _realizeAndVerify(id, DIGITAL, 300_000e18);
        assertEq(got.absorbed, 0, "no curator capital in the digital-assets class");
        assertEq(got.covered, 200_000e18, "layer 2 up to its event cap");
        assertEq(got.depositorLoss, 100_000e18, "senior took the remainder");
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
        assertEq(got.covered, 200_000e18, "then layer 2, capped at the event snapshot");
        assertEq(got.depositorLoss, 100_000e18, "then layer 3");
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
        assertEq(defaultManager.pendingSeniorImpairment(), 500_000e18 - 200_000e18, "and still nets correctly");
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
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 3_000_000e18);
        _mintFromUSDC(ops, 1_000_000e6);
        _postFirstLoss(FILM, 150_000e18);
        _fundCoverage(ops, 500_000e18); // event cap: 250k

        uint256 id = _originateAndFundIn(FILM, keccak256("BW-FZ1"), 1_000_000e18, 7500);
        _declare(id);

        uint256 loss = bound(lossSeed, 1, 1_000_000e18);
        Layers memory got = _realizeAndVerify(id, FILM, loss);

        assertEq(got.absorbed, loss < 150_000e18 ? loss : 150_000e18, "layer 1 takes min(loss, pool)");
        uint256 residual = loss - got.absorbed;
        assertEq(got.covered, residual < 250_000e18 ? residual : 250_000e18, "layer 2 takes min(residual, cap)");
        assertEq(got.depositorLoss, residual - got.covered, "layer 3 takes only what is left");
        assertLe(got.covered, 250_000e18, "PM-R-07: never beyond the event cap");
        assertLe(vault.redemptionTotalAssets(), vault.totalAssets(), "exit base <= deposit base");
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "backing invariant");
    }

    /// @notice FUZZ: chunking ONE facility's loss across two arbitrary realizations can never draw
    ///         more sGROVE coverage in total than the cap snapshotted at the first draw.
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_fork_chunkedRealizationNeverExceedsTheEventCap(uint256 seedA, uint256 seedB) public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 3_000_000e18);
        _mintFromUSDC(ops, 1_000_000e6);
        _fundCoverage(ops, 1_000_000e18); // event cap: 500k, snapshotted at the first draw

        uint256 id = _originateAndFundIn(FILM, keccak256("BW-FZ2"), 1_500_000e18, 7500);
        _declare(id);

        uint256 chunkA = bound(seedA, 1, 700_000e18);
        uint256 chunkB = bound(seedB, 1, 700_000e18);

        Layers memory a = _realizeAndVerify(id, FILM, chunkA);
        (uint256 drawnA, uint256 capA) = sGrove.eventCoverage(id);
        assertEq(capA, 500_000e18, "the cap is snapshotted at the FIRST draw, against the full reserve");
        assertEq(drawnA, a.covered, "cumulative draw after chunk A");

        Layers memory b = _realizeAndVerify(id, FILM, chunkB);
        (uint256 drawnB, uint256 capB) = sGrove.eventCoverage(id);
        assertEq(capB, capA, "the cap does NOT re-snapshot for the same event");
        assertEq(drawnB, a.covered + b.covered, "cumulative draw after chunk B");
        assertLe(drawnB, capB, "PM-R-07: the EVENT's cumulative draw never exceeds its snapshot");
        assertGe(sGrove.coverageReserve(), 500_000e18, "half the reserve always survives this one event");
        assertEq(
            a.absorbed + a.covered + a.depositorLoss + b.absorbed + b.covered + b.depositorLoss,
            chunkA + chunkB,
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
        ClaimBridge.OriginationTerms memory terms =
            _forkTermsFor(classId, borrowerId, keccak256("US-GA"), principal, ltvBps, 1000, maturity, ref);
        _attest(tokenId, IAttestationOracle.AttestationKind.AssignmentExecuted, keccak256(abi.encode("a", tokenId)));
        _attest(tokenId, IAttestationOracle.AttestationKind.UCCFiled, keccak256(abi.encode("u", tokenId)));
        // AUDIT FIX (H-4): the CreditIssued quorum commits to these exact terms.
        _attest(tokenId, IAttestationOracle.AttestationKind.CreditIssued, bridge.creditTermsHash(terms));

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
            _forkTermsFor(DIGITAL, borrowerId, keccak256("US-NY"), principal, 5000, 1000, maturity, ref);
        _attest(tokenId, IAttestationOracle.AttestationKind.AssignmentExecuted, keccak256(abi.encode("a", tokenId)));
        _attest(tokenId, IAttestationOracle.AttestationKind.Valuation, bytes32(markValue));
        // AUDIT FIX (H-4): CreditIssued is required on EVERY class gate now, bound to the terms.
        _attest(tokenId, IAttestationOracle.AttestationKind.CreditIssued, bridge.creditTermsHash(terms));

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
    ///      the event's remaining room under its snapshotted cap, clamped by the live reserve.
    ///      An event that has never drawn would snapshot the CURRENT capacity.
    function _eventRoom(uint256 tokenId) internal view returns (uint256) {
        uint256 room = _eventRoomUnclamped(tokenId);
        uint256 reserve = sGrove.coverageReserve();
        return room < reserve ? room : reserve;
    }

    /// @dev As `_eventRoom`, without the reserve clamp (used for the aggregate floor, where the
    ///      shared reserve is clamped once across all live events rather than per event).
    function _eventRoomUnclamped(uint256 tokenId) internal view returns (uint256) {
        // The model must mirror the WIRING: with no backstop set, layer 2 does not exist at all.
        if (defaultManager.backstop() != address(sGrove)) return 0;
        (uint256 drawn, uint256 cap) = sGrove.eventCoverage(tokenId);
        if (cap == 0) {
            cap = sGrove.coverageCapacity(); // never drawn: a fresh snapshot would be taken now
            drawn = 0;
        }
        return cap > drawn ? cap - drawn : 0;
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

        _attestLoss(tokenId, loss, bytes32(0));
        vm.recordLogs();
        vm.prank(ops);
        defaultManager.realizeLoss(tokenId, loss, bytes32(0));

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
