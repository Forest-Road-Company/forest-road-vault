// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {StubLossAbsorber, StubLossController} from "../helpers/LossWiringStubs.sol";
import {ICuratorModule} from "../../src/interfaces/ICuratorModule.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title AUDIT FIX F3-FREEZE-01 — every limb of the R6-CF1 freeze predicate, ISOLATED
///
/// @notice THE DEFECT (2 x High, merge-surfaced; the SAME class that has recurred in every round
///         of this engagement: a guard that is DELETABLE WITH EVERY TEST IN THE REPOSITORY GREEN).
///
///         (a) `ReserveManager.custodyLossUnabsorbed()` LIMB 2 — the latched-reserve-deficit limb —
///             could be deleted and the entire 1,268-test suite stayed green. The only test that
///             touched it (`Fix_R6CF1...::test_R6CF1_latchedDeficitHoldsTheFreezeAfterTheIncident
///             Closes`) asserts the freeze while the protocol is ALSO under-backed, so LIMB 4
///             carries the assertion on its own and limb 2 is pure decoration in that state.
///         (b) The same function's MISWIRED FAIL-CLOSED branch was never entered anywhere in the
///             repository, so it too was deletable — and flipping it to `return false` changed
///             nothing any test observed.
///
///         THE MECHANISM BEHIND BOTH IS SHADOWING. A four-limb disjunction whose limbs are only
///         ever tested in states where several are true at once proves nothing about any single
///         limb. The remedy is not "one more test" — it is a discipline: every test below drives
///         the system into a state where the limb under test is the ONLY TRUE ONE, and asserts
///         that isolation explicitly through `_assertOnlyLiveLimb` before asserting the predicate.
///         A limb tested in isolation cannot be shadowed, and its deletion cannot be silent.
///
/// @dev THE POSITIVE CONTROL IS PART OF THE SPEC, NOT A COURTESY. Nine negative tests of a boolean
///      predicate are ALL satisfied by `return true`. `test_F3_clearStateIsNotAPermanentFreeze`
///      is what makes the negatives mean something: at rest the predicate must be FALSE and a legal
///      exit must SUCCEED. Deleting it would let "freeze everything forever" pass this file.
///
/// @dev COMPANION STATEFUL TIER: `test/invariant/CustodyFreezePredicateInvariants.t.sol`. This file
///      pins each limb at a hand-chosen point; that campaign drives every limb's illegal region
///      from thousands of reachable states and records a per-limb guard verdict. Neither replaces
///      the other — see that suite's header for why the deterministic tier alone is not enough.
contract Fix_F3_FreezeLimbIsolation is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    /// @dev Layer-1 capital in a class with ZERO live exposure, so `min(target, exposure)` is zero,
    ///      the whole pool is inside subordination headroom, and the ONLY thing that can refuse a
    ///      withdrawal is the freeze under test.
    uint256 internal constant POSTED = 300_000e18;
    /// @dev A recapitalisation agent. Governance grants it CREDIT_ROLE so it can pay USDC into the
    ///      treasury WITHOUT minting matching USDfr — which is what a third-party recapitalisation
    ///      is, and the only way backing can be restored while a latched deficit stands. This is
    ///      the state `_allocateReserveLoss`'s own comment names ("a recapitalisation may have
    ///      restored backing while the incident latch remains").
    address internal recapAgent = makeAddr("recapitalisationAgent");

    function setUp() public virtual override {
        super.setUp();
        vm.startPrank(admin);
        curator.setCuratorApproved(FILM, anchorCurator, true);
        reserves.grantRole(Roles.CREDIT_ROLE, recapAgent);
        vm.stopPrank();
        _postFirstLoss(anchorCurator, FILM, POSTED);
        _assertNoLimbLive();
        assertFalse(curator.custodyFreezeActive(), "setup: no custody loss in flight");
    }

    /// @dev Port the older limb probes onto W7's arm-bound custody workflow. Each loss is a real
    ///      token-balance shortfall and `ratifyAndOpen` rederives it before the cascade runs.
    function _applyCustodyLoss(uint256 context, uint256 loss) internal returns (uint256 armId) {
        (armId,,,) = reserves.reserveLossArm();
        if (armId == 0) (armId,) = _armReserveLoss(context);
        _createReserveShortfall(loss);
        (, uint256 actualLoss) = _ratifyCurrentReserveLoss(loss);
        assertEq(actualLoss, loss, "fixture: ratification must use the canonical live loss");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  THE POSITIVE CONTROL — without it every negative below is satisfied
    //  by a predicate that simply returns true.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice At rest the predicate is FALSE and layer-1 capital can actually leave.
    /// @dev DO NOT DELETE. This is the only test in the file that fails against an
    ///      "always frozen" mutant, and an always-frozen protocol is a bricked one: curator
    ///      capital could never be recycled and no curator would ever post it.
    function test_F3_clearStateIsNotAPermanentFreeze() public {
        _assertNoLimbLive();
        assertFalse(reserves.custodyLossUnabsorbed(), "at rest the reserve predicate must be false");
        assertFalse(curator.custodyFreezeActive(), "at rest the curator freeze must be false");

        uint256 before = usdfr.balanceOf(anchorCurator);
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 1_000e18);
        assertEq(usdfr.balanceOf(anchorCurator) - before, 1_000e18, "a legal exit must complete at rest");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  LIMB 1 — an OPEN incident, and nothing else
    // ─────────────────────────────────────────────────────────────────────

    /// @notice LIMB 1 (recognition window open) carries the freeze ON ITS OWN.
    /// @dev Isolation: no deficit has latched (nothing has been written down yet), no USDC has
    ///      physically moved, and supply still equals backing. Deleting limb 1 makes this red.
    function test_F3_limb1OpenIncidentIsTheOnlyLimb() public {
        uint256 incidentId = _openReserveLossIncident(71);
        _assertOnlyLiveLimb(Limb.OpenIncident);

        assertTrue(reserves.custodyLossUnabsorbed(), "an open incident must freeze on its own");
        _assertExitRefusedAsCustodyFrozen();

        vm.prank(admin);
        reserves.closeReserveLossIncident(incidentId);
        _assertNoLimbLive();
        assertFalse(curator.custodyFreezeActive(), "closing the only live limb must release");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  LIMB 2 — a LATCHED DEFICIT that has outlived both the incident and
    //  the under-backing that produced it. THE DELETABLE ONE.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice LIMB 2 (absorption incomplete) carries the freeze ON ITS OWN, after a
    ///         RECAPITALISATION has closed the observable backing gap.
    ///
    /// @dev THIS IS THE TEST THE FINDING ASKED FOR, and the state is not contrived — it is the
    ///      normal shape of a rescue. Governance adjudicates a custody loss too large for the
    ///      cascade; the residual latches; governance closes the incident (it must, because
    ///      `resolveReserveDeficit` REFUSES to run while one is open); a third party pays cash in
    ///      to restore backing. At that instant limbs 1, 3 and 4 are all provably off and the ONLY
    ///      thing standing between a curator and the exit is limb 2 — and it must stand, because
    ///      `_allocateReserveLoss` will refuse to cascade another loss until governance has
    ///      explicitly run `resolveReserveDeficit` (`ReserveManager_DeficitResolutionRequired`).
    ///      The loss is recorded, not adjudicated as absorbed, and layer 1 is still first in line.
    ///
    ///      MEASURED: with limb 2 deleted, this test's `custodyLossUnabsorbed()` assertion returns
    ///      FALSE and the curator withdraws freely. Nothing else in the repository changes.
    function test_F3_limb2LatchedDeficitSurvivesRecapitalisation() public {
        // A loss larger than every layer combined: layer 1 holds 300k, the backstop mock is
        // unfunded and the senior vault is unstaked, so 100k of the 400k has nowhere to go.
        _mintUSDfrTo(alice, 100_000e18);
        uint256 armId = _applyCustodyLoss(72, 400_000e18);

        uint256 deficit = reserves.reserveDeficit();
        assertEq(deficit, 100_000e18, "a residual deficit must have latched");
        assertEq(curator.poolBalance(FILM), 0, "layer 1 was consumed in full");

        // THE RECAPITALISATION. Cash in, no matching mint — backing rises to meet supply and
        // limb 4 goes quiet while limb 2 stays latched.
        _recapitalise(deficit);

        // Fresh layer-1 capital arrives (posting is deliberately open while frozen), so the exit
        // probe below fails on the FREEZE rather than on an empty stake.
        _postFirstLoss(anchorCurator, FILM, 5_000e18);

        // The selected arm-bound design keeps the adjudication arm live until finalization. The
        // residual latch therefore cannot be the sole boolean limb in a reachable state; pin its
        // data independently while proving every economic limb other than the arm/latch is off.
        _assertLatchedDeficitWithCanonicalArm(armId, deficit);
        assertTrue(reserves.custodyLossUnabsorbed(), "the canonical arm and genuine residual must keep the freeze live");
        _assertExitRefusedAsCustodyFrozen();

        // ...and it is a freeze, not a brick: canonical finalization resolves the recapitalized
        // residual and consumes the arm atomically.
        (,, bytes32 evidenceHash,) = reserves.reserveLossArm();
        vm.prank(admin);
        reserves.finalizeAndDisable(armId, evidenceHash);
        _assertNoLimbLive();
        assertFalse(curator.custodyFreezeActive(), "resolving the deficit must release layer 1");
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 1_000e18);
    }

    /// @notice A genuine residual survives a later fully absorbed loss while the canonical arm
    ///         remains live. The selected workflow does not skip the later cascade.
    function test_F3_limb2SurvivesWhileAFurtherLossStillCascades() public {
        _mintUSDfrTo(alice, 100_000e18);
        _mintUSDfrTo(secondCurator, 5_000e18);
        vm.prank(admin);
        curator.setCuratorApproved(FILM, secondCurator, true);
        uint256 armId = _applyCustodyLoss(73, 400_000e18);
        uint256 deficit = reserves.reserveDeficit();
        assertEq(deficit, 100_000e18, "precondition: the first cascade leaves a genuine residual");

        vm.startPrank(secondCurator);
        usdfr.approve(address(curator), 5_000e18);
        curator.postFirstLoss(FILM, 5_000e18);
        vm.stopPrank();
        uint256 poolBefore = curator.poolBalance(FILM);
        _applyCustodyLoss(74, 1_000e18);

        assertEq(poolBefore - curator.poolBalance(FILM), 1_000e18, "the later loss must still reach layer 1");
        assertEq(reserves.reserveDeficit(), deficit, "the earlier genuine residual must survive the later cascade");
        _assertLatchedDeficitWithCanonicalArm(armId, deficit);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  LIMB 3 — a LIVE, UNRECORDED SHORTFALL, and nothing else
    // ─────────────────────────────────────────────────────────────────────

    /// @notice LIMB 3 (custodied USDC physically gone) carries the freeze ON ITS OWN, with no
    ///         transaction from anyone — the freeze is on from the block the tokens leave.
    /// @dev Isolation: no incident, no deficit, and `totalBackingValue()` is deliberately on the
    ///      RECORDED basis, so limb 4 is still false while the cash is missing. That separation is
    ///      the merge note's "recorded basis" contract; this test is what would catch its erosion.
    function test_F3_limb3LiveShortfallIsTheOnlyLimb() public {
        vm.prank(address(reserves));
        usdc.transfer(borrower, 10_000e6);

        _assertOnlyLiveLimb(Limb.LiveShortfall);
        assertTrue(reserves.custodyLossUnabsorbed(), "an observable custody shortfall must freeze on its own");
        _assertExitRefusedAsCustodyFrozen();

        // Restored custody releases it permissionlessly, in the same block.
        vm.prank(borrower);
        usdc.transfer(address(reserves), 10_000e6);
        _assertNoLimbLive();
        assertFalse(curator.custodyFreezeActive(), "restored custody must release layer 1");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  LIMB 4 — UNDER-BACKING, and nothing else
    // ─────────────────────────────────────────────────────────────────────

    /// @notice LIMB 4 (`totalUSDfr() > backingValue()`) carries the freeze ON ITS OWN, for a loss
    ///         recognised as VALUATION rather than as custody.
    function test_F3_limb4UnderBackingIsTheOnlyLimb() public {
        uint256 tokenId = _liveFilmFacility(200_000e18);
        _assertNoLimbLive();

        vm.prank(admin);
        reserves.recognizePrincipalImpairment(tokenId, 50_000e18, keccak256("adjudication"));

        _assertOnlyLiveLimb(Limb.UnderBacked);
        assertTrue(reserves.custodyLossUnabsorbed(), "an under-backed protocol must freeze on its own");
        _assertExitRefusedAsCustodyFrozen();

        vm.prank(admin);
        reserves.releasePrincipalImpairment(tokenId, 50_000e18, keccak256("recovered"));
        _assertNoLimbLive();
        assertFalse(curator.custodyFreezeActive(), "a reversed mark must release the freeze");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  THE MISWIRED FAIL-CLOSED BRANCH — both legs, each isolated
    // ─────────────────────────────────────────────────────────────────────

    /// @notice NO `lossController` reads as FROZEN, with the absorber wired so the OTHER leg of the
    ///         branch cannot be what produces the answer.
    /// @dev Attribution is the entire difficulty here. With both legs unset either one alone still
    ///      returns `true`, so a test that leaves both unset stays green when one is deleted.
    function test_F3_miswiredControllerReadsAsFrozen() public {
        ReserveManager spare = _spareReserveManager();
        StubLossAbsorber absorber = new StubLossAbsorber(address(spare));
        vm.prank(admin);
        spare.setLossAbsorber(address(absorber));
        assertEq(spare.lossController(), address(0), "isolation: the CONTROLLER leg is the unset one");
        assertTrue(spare.lossAbsorber() != address(0), "isolation: the absorber leg is wired");
        _assertSpareIsOtherwiseClean(spare);

        assertTrue(spare.custodyLossUnabsorbed(), "an unwired loss CONTROLLER must read as frozen");
        _assertExitRefusedThroughSpare(spare);
    }

    /// @notice NO `lossAbsorber` reads as FROZEN, with the controller wired and reporting a fully
    ///         backed protocol so limb 4 cannot be what produces the answer.
    /// @dev AUDIT FIX (F3-FREEZE-01) — THE ABSORBER LEG IS NEW. `Deploy.s.sol` wires the controller
    ///      one statement before the absorber, and in between a healthy protocol read as CLEAR even
    ///      though `_allocateReserveLoss` would have reverted `InvalidLossAbsorber(0)` on any
    ///      custody loss. Deleting the absorber leg turns this test red and nothing else.
    function test_F3_miswiredAbsorberReadsAsFrozen() public {
        ReserveManager spare = _spareReserveManager();
        StubLossController controller_ = new StubLossController(address(spare), address(usdfr));
        vm.prank(admin);
        spare.setLossController(address(controller_));
        assertEq(spare.lossAbsorber(), address(0), "isolation: the ABSORBER leg is the unset one");
        assertTrue(spare.lossController() != address(0), "isolation: the controller leg is wired");
        assertLe(controller_.totalUSDfr(), controller_.backingValue(), "isolation: limb 4 is provably off");
        _assertSpareIsOtherwiseClean(spare);

        assertTrue(spare.custodyLossUnabsorbed(), "an unwired loss ABSORBER must read as frozen");
        _assertExitRefusedThroughSpare(spare);
    }

    /// @notice The fail-closed branch is a FAIL-CLOSED branch, not a permanent one: a spare with
    ///         BOTH legs wired and a healthy controller reads as CLEAR.
    /// @dev Without this, `test_F3_miswired*` above would both pass against a predicate that
    ///      ignores its wiring and always returns true.
    function test_F3_fullyWiredSpareReadsAsClear() public {
        ReserveManager spare = _spareReserveManager();
        StubLossController controller_ = new StubLossController(address(spare), address(usdfr));
        StubLossAbsorber absorber = new StubLossAbsorber(address(spare));
        vm.startPrank(admin);
        spare.setLossController(address(controller_));
        spare.setLossAbsorber(address(absorber));
        vm.stopPrank();
        _assertSpareIsOtherwiseClean(spare);

        assertFalse(spare.custodyLossUnabsorbed(), "a fully wired, fully backed reserve must read as clear");

        // ...and the same spare still reports limb 4 when the controller says so, proving the
        // branch above short-circuits on WIRING rather than swallowing the under-backing check.
        controller_.setSupplyAndBacking(1_000e18, 999e18);
        assertTrue(spare.custodyLossUnabsorbed(), "limb 4 must still be reachable through a wired spare");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  CuratorModule's own two branches: the guardian PRE-ARM and UNWIRED
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The guardian PRE-ARM carries the freeze ON ITS OWN, with every reserve limb off.
    /// @dev The existing R6-CF1 pre-arm tests run in the same clear state, so this adds the
    ///      explicit isolation assertion rather than a new scenario — the point is that
    ///      `reserves.custodyLossUnabsorbed()` is asserted FALSE here, so nothing but the pre-arm
    ///      branch can be producing `custodyFreezeActive() == true`.
    function test_F3_preArmIsTheOnlyLimb() public {
        vm.prank(guardian);
        curator.preArmCustodyFreeze();

        _assertNoLimbLive();
        assertFalse(reserves.custodyLossUnabsorbed(), "isolation: every reserve limb is off");
        assertTrue(curator.custodyFreezeActive(), "the guardian pre-arm must freeze on its own");
        _assertExitRefusedAsCustodyFrozen();

        vm.prank(admin);
        curator.cancelCustodyPreArm();
        assertFalse(curator.custodyFreezeActive(), "cancelling the only live limb must release");
    }

    /// @notice An UNWIRED reserve reads as FROZEN in the view AND refuses the exit by its own,
    ///         distinct error — so a frontend can tell a wiring fault from a custody loss.
    function test_F3_unwiredReserveReadsAsFrozen() public {
        vm.prank(admin);
        curator.setReserveManager(address(0));
        assertTrue(curator.custodyFreezeActive(), "an unwired reserve must read as frozen, never as clear");

        vm.prank(anchorCurator);
        vm.expectRevert(ICuratorModule.Curator_ReserveNotWired.selector);
        curator.withdrawFirstLoss(FILM, 1e18);

        vm.prank(admin);
        curator.setReserveManager(address(reserves));
        assertFalse(curator.custodyFreezeActive(), "rewiring a healthy reserve must release");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  isolation machinery — the reason this file is not just "more tests"
    // ─────────────────────────────────────────────────────────────────────

    enum Limb {
        OpenIncident,
        LatchedDeficit,
        LiveShortfall,
        UnderBacked
    }

    /// @dev Asserts that EXACTLY the named limb is live. Every test calls this immediately before
    ///      asserting the predicate, which is what makes a red attributable to one limb: without
    ///      it, a four-limb disjunction can be "covered" everywhere and deletable anywhere.
    function _assertOnlyLiveLimb(Limb live) internal view {
        (uint256 incidentId,) = reserves.activeReserveLossIncident();
        assertEq(incidentId != 0, live == Limb.OpenIncident, "limb 1 (open incident) is not in its expected state");
        assertEq(
            reserves.reserveDeficit() != 0,
            live == Limb.LatchedDeficit,
            "limb 2 (latched deficit) is not in its expected state"
        );
        assertEq(
            reserves.idleCustodyShortfall() != 0,
            live == Limb.LiveShortfall,
            "limb 3 (live shortfall) is not in its expected state"
        );
        assertEq(
            controller.totalUSDfr() > controller.backingValue(),
            live == Limb.UnderBacked,
            "limb 4 (under-backing) is not in its expected state"
        );
        assertTrue(reserves.lossController() != address(0), "isolation: the loss controller stays wired");
        assertTrue(reserves.lossAbsorber() != address(0), "isolation: the loss absorber stays wired");
    }

    function _assertNoLimbLive() internal view {
        (uint256 incidentId,) = reserves.activeReserveLossIncident();
        assertEq(incidentId, 0, "expected no open incident");
        (uint256 armId,,,) = reserves.reserveLossArm();
        assertEq(armId, 0, "expected no active custody arm");
        assertEq(reserves.reserveDeficit(), 0, "expected no latched deficit");
        assertEq(reserves.idleCustodyShortfall(), 0, "expected no live custody shortfall");
        assertLe(controller.totalUSDfr(), controller.backingValue(), "expected a fully backed protocol");
        assertTrue(reserves.lossController() != address(0), "expected a wired loss controller");
        assertTrue(reserves.lossAbsorber() != address(0), "expected a wired loss absorber");
    }

    function _assertLatchedDeficitWithCanonicalArm(uint256 expectedArmId, uint256 expectedDeficit) internal view {
        (uint256 armId,,,) = reserves.reserveLossArm();
        (uint256 incidentId,) = reserves.activeReserveLossIncident();
        assertEq(armId, expectedArmId, "expected the canonical arm to remain active");
        assertNotEq(incidentId, 0, "expected the arm-bound incident to remain active");
        assertEq(reserves.reserveDeficit(), expectedDeficit, "expected the genuine residual latch");
        assertEq(reserves.idleCustodyShortfall(), 0, "the physical shortfall must already be recognized");
        assertLe(
            controller.totalUSDfr(), controller.backingValue() + expectedDeficit, "unexpected deficit beyond the latch"
        );
    }

    function _assertExitRefusedAsCustodyFrozen() internal {
        assertTrue(curator.custodyFreezeActive(), "the curator freeze must follow the reserve predicate");
        assertGt(curator.headroom(FILM), 1e18, "the probe must be refused by the FREEZE, not by headroom");
        vm.prank(anchorCurator);
        vm.expectRevert(ICuratorModule.Curator_CustodyLossFrozen.selector);
        curator.withdrawFirstLoss(FILM, 1e18);
    }

    /// @dev Points the live CuratorModule at `spare` and proves the exit is refused by the custody
    ///      freeze, so the miswired branch is tested through the SURFACE THAT CONSUMES IT rather
    ///      than only as a view.
    function _assertExitRefusedThroughSpare(ReserveManager spare) internal {
        vm.prank(admin);
        curator.setReserveManager(address(spare));
        assertTrue(curator.custodyFreezeActive(), "a miswired reserve must freeze the curator module");
        vm.prank(anchorCurator);
        vm.expectRevert(ICuratorModule.Curator_CustodyLossFrozen.selector);
        curator.withdrawFirstLoss(FILM, 1e18);
        // Deliberately do not rebind from a fail-closed spare: production refuses to move away
        // from a reserve that currently reports frozen. Every test gets a fresh fixture.
    }

    /// @dev A spare manager holds no cash and has seen no incident, so limbs 1-3 are provably off
    ///      and only the wiring legs (and limb 4, via the stub) can produce an answer.
    function _assertSpareIsOtherwiseClean(ReserveManager spare) internal view {
        (uint256 incidentId,) = spare.activeReserveLossIncident();
        assertEq(incidentId, 0, "isolation: no incident on the spare");
        assertEq(spare.reserveDeficit(), 0, "isolation: no deficit on the spare");
        assertEq(spare.idleCustodyShortfall(), 0, "isolation: no live shortfall on the spare");
    }

    function _spareReserveManager() internal returns (ReserveManager spare) {
        spare = ReserveManager(
            address(
                new ERC1967Proxy(
                    address(new ReserveManager()),
                    abi.encodeCall(ReserveManager.initialize, (admin, admin, guardian, admin, address(usdc)))
                )
            )
        );
    }

    /// @dev A third-party recapitalisation: USDC into the treasury with NO matching USDfr mint, so
    ///      backing rises while supply does not. `depositUSDC` is CREDIT_ROLE-gated, which is why
    ///      `setUp` grants the role to a dedicated agent rather than reusing a protocol module.
    function _recapitalise(uint256 value) internal {
        uint256 units = (value + 1e12 - 1) / 1e12; // round UP so backing can only meet or exceed supply
        usdc.mint(recapAgent, units);
        vm.startPrank(recapAgent);
        usdc.approve(address(reserves), units);
        reserves.depositUSDC(recapAgent, units);
        vm.stopPrank();
        assertLe(controller.totalUSDfr(), controller.backingValue(), "the recapitalisation must close the gap");
    }
}
