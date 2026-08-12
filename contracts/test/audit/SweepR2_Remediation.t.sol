// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {ICuratorModule} from "../../src/interfaces/ICuratorModule.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {IPointsModule} from "../../src/interfaces/IPointsModule.sol";
import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {Config} from "../../src/libraries/Config.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {GovernanceFixture} from "../helpers/GovernanceFixture.sol";

/// @dev SWEEP-2 S2-F5. A one-shot participation-points module that moves ONE WEI of USDfr into the
///      draw source from inside the `CuratorModule -> DefaultManager` transfer that
///      `MintRedeemController._drawJuniorForExit` measures across. `USDfr._update` wraps this hook
///      in `try/catch` under the protocol-wide rule that "a points-module failure must never block a
///      USDfr transfer, mint, or burn" (finding C4-USDFR-01), so this contract cannot break anything
///      by REVERTING — before the SWEEP-2 fix it broke the exit by SUCCEEDING, from outside that
///      `try/catch`, because the delivery check was a STRICT EQUALITY on a balance delta.
contract S2ExitDrawGriefer is IPointsModule {
    IERC20 public immutable USDFR;
    address public immutable TARGET;
    bool public armed;
    bool public fired;

    constructor(IERC20 usdfr_, address target_) {
        USDFR = usdfr_;
        TARGET = target_;
    }

    function arm() external {
        armed = true;
    }

    function onUSDfrTransfer(address, address to, uint256) external override {
        if (!armed || fired) return;
        if (to != TARGET) return;
        fired = true;
        USDFR.transfer(TARGET, 1);
    }

    function onSharesTransfer(address, address, uint256) external override {}
    function onCuratorStakeChange(address, uint256, uint256) external override {}
    function onCuratorLoss(uint256, uint256, uint256) external override {}
}

/// @title SWEEP-2 REMEDIATION — regressions for the HIGH and MEDIUM findings of sweep round 2
/// @notice EVERY TEST HERE IS A NAMED FALSIFIER FOR A GUARD ADDED OR CHANGED IN THIS ROUND, and
///         every one of them was RED on the tree as received. The mutation that reds each is stated
///         on the test. Deleting a test here re-opens the finding it names.
contract SweepR2_RemediationCredit is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;

    // ═════════════════════════════════════════════════════════════════════
    //  S2-F5 — the fail-open points hook is no longer a redemption kill
    //          switch on the ADR-0034 Y-bis draw window.
    // ═════════════════════════════════════════════════════════════════════

    /// @notice R18 found that `_redeem`'s outflow window contained a call the deliberately
    ///         FAIL-OPEN points hook could influence, hoisted the burn out, and wrote a GENERAL
    ///         RULE into `_redeem`'s NatSpec: "no call that a redeemer or a governance-set module
    ///         can influence may be added between `payeeBefore` and `payeeAfter`." ADR-0034 Y-bis
    ///         then opened a SECOND strict-equality window in `_drawJuniorForExit`, containing
    ///         `drawForSeniorExit` — i.e. `CuratorModule.absorbGlobalLoss`'s USDfr transfer to
    ///         `DefaultManager` and `SGrove.coverShortfall`'s. MEASURED PRE-FIX:
    ///             Controller_ExitDrawNotDelivered(target = 4950495049504950495050,
    ///                                             reported = 4950495049504950495050,
    ///                                             measured = 4950495049504950495051)
    ///         — exactly ONE WEI bricked every under-backed exit, the one path ADR-0034 exists to
    ///         keep open, and the revert happened OUTSIDE the token's `try/catch`.
    /// @dev MUTATION: restore `if (delivered != reported || reported > target)` in
    ///      `MintRedeemController._drawJuniorForExit` (compiles; both operands still read) -> RED
    ///      here on the armed leg.
    function test_S2_F5_aOneWeiDonationIntoTheDrawWindowCannotBrickAnUnderBackedExit() public {
        _shortBookWithJuniorCapital();

        S2ExitDrawGriefer griefer = new S2ExitDrawGriefer(IERC20(address(usdfr)), address(defaultManager));
        // The module funds itself with one wei out of alice's own holding — no privilege at all.
        vm.prank(alice);
        usdfr.transfer(address(griefer), 1);
        vm.prank(admin);
        usdfr.setPointsModule(address(griefer));

        // CONTROL: with the module inert the exit settles, so a red below is the module's doing.
        vm.prank(alice);
        uint256 control = controller.redeem(50_000e18, 0, block.timestamp);
        assertGt(control, 0, "control: the exit settles while the module is inert");
        assertFalse(griefer.fired(), "control: the module did not act");

        // ARMED: one wei into the draw source INSIDE the measurement window.
        uint256 poolBefore = curator.poolBalance(FILM);
        uint256 dmBefore = usdfr.balanceOf(address(defaultManager));
        griefer.arm();
        vm.prank(alice);
        uint256 armedOut = controller.redeem(50_000e18, 0, block.timestamp);

        assertTrue(griefer.fired(), "the griefing module DID act inside the window");
        assertGt(armedOut, 0, "S2-F5: the exit must survive a third-party donation into the window");
        assertLt(curator.poolBalance(FILM), poolBefore, "the junior draw still happened");
        // The donated wei is neither burned nor credited: it simply sits at the loss absorber.
        assertEq(usdfr.balanceOf(address(defaultManager)) - dmBefore, 1, "the donated wei stayed put, unburned");
    }

    /// @notice DISCRIMINATING CONTROL for the same fix. The two failure modes the measurement
    ///         exists for are STILL fail-closed: a source that under-delivers what it reported is
    ///         refused, and so is one that reports more than it was asked for. Only the third-party
    ///         donation is tolerated.
    /// @dev The over-report leg is also the SWEEP-2 M3 vacuity: in its old `drawn > target` form it
    ///      was unfalsifiable, because `LyingExitDrawSource` never moves a token and both of its
    ///      modes were caught by the equality alone. See
    ///      `S2_GuardVacuity.t.sol::test_S2_anOverDeliveringDrawSourceMustStillBeRefused`.
    function test_S2_F5_control_anUnderDeliveringOrOverReportingSourceIsStillRefused() public {
        _shortBookWithJuniorCapital();
        S2LyingDrawSource liar = new S2LyingDrawSource(address(reserves));
        vm.startPrank(admin);
        reserves.setLossAbsorber(address(liar));
        controller.setLossSource(address(liar), true);
        vm.stopPrank();

        liar.setMode(S2LyingDrawSource.Mode.OverReport); // reports `target`, delivers nothing
        vm.prank(alice);
        vm.expectPartialRevert(IMintRedeemController.Controller_ExitDrawNotDelivered.selector);
        controller.redeem(50_000e18, 0, block.timestamp);

        liar.setMode(S2LyingDrawSource.Mode.OverRequest); // reports MORE than it was asked for
        vm.prank(alice);
        vm.expectPartialRevert(IMintRedeemController.Controller_ExitDrawNotDelivered.selector);
        controller.redeem(50_000e18, 0, block.timestamp);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  CSG-F1 — layer-1 capital the conservative NAV credits cannot leave.
    // ═════════════════════════════════════════════════════════════════════

    /// @notice THE MEASURED HIGH, INVERTED. Pre-fix, with a past-due mark standing and NO freeze
    ///         armed anywhere, a curator withdrew 800,000e18 of layer-1 capital with no revert and
    ///         the senior redemption price fell 1,000,000e18 -> 650,000e18. The two formulas
    ///         disagreed: what could LEAVE was `poolBalance - min(target, exposure)`, while the
    ///         conservative senior NAV CREDITS `min(declared + pastDue, poolBalance)`.
    /// @dev MUTATION: drop the `marked` term from `CuratorModule._requiredFirstLoss` (return
    ///      `required` alone, `marked` still computed and compared in a no-op so it still compiles)
    ///      -> RED here: the withdrawal succeeds and the mark moves.
    function test_CSGF1_aWithdrawalCannotRemoveLayer1CreditTheSeniorPriceIsExtending() public {
        vm.prank(admin);
        curator.setFirstLossTarget(FILM, 100_000e18);
        _postFirstLoss(anchorCurator, FILM, 900_000e18);
        uint256 id = _liveFilmFacility(700_000e18);

        // A past-due mark: it freezes NOTHING (H-5 design) and does not move `totalBackingValue()`,
        // so R6-CF1 limb 4 is false too. It is the one loss path with no freeze at all.
        uint64 nextDue = bridge.facility(id).nextPaymentDue;
        vm.warp(uint256(nextDue) + defaultManager.graceWindow(FILM) + 1);
        defaultManager.markPastDue(id);
        assertEq(curator.unresolvedDefaults(FILM), 0, "precondition: no class freeze");
        assertFalse(reserves.custodyLossUnabsorbed(), "precondition: no custody freeze either");

        uint256 markBefore = defaultManager.pendingSeniorImpairment();
        uint256 credited = defaultManager.declaredDefaultedPrincipal(FILM) + defaultManager.pastDuePrincipal(FILM);
        assertEq(credited, 700_000e18, "the mark credits the full past-due principal as layer 1");

        // Pre-fix headroom was `900,000 - min(100,000, 700,000)` = 800,000e18. It is now
        // `900,000 - max(100,000, 700,000)` = 200,000e18: exactly the UNCREDITED excess.
        assertEq(curator.requiredFirstLoss(FILM), 700_000e18, "the requirement is floored at what the mark credits");
        assertEq(curator.headroom(FILM), 200_000e18, "only uncredited capital is free");

        vm.expectRevert(
            abi.encodeWithSelector(
                ICuratorModule.Curator_HeadroomExceeded.selector, FILM, uint256(800_000e18), uint256(200_000e18)
            )
        );
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 800_000e18);

        // ...and the uncredited excess still leaves freely: this is a FLOOR, not a freeze.
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 200_000e18);
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            markBefore,
            "CSG-F1: no withdrawal may reduce the layer-1 credit the senior price is extending"
        );
    }

    /// @notice THE ONE-CALL ROUTE IN, CLOSED. `CuratorModule.setFirstLossTarget` has no lower bound
    ///         — unlike every neighbouring governed dial — and was the ONLY governance input to the
    ///         old requirement, so one call manufactured headroom out of credited capital. It can no
    ///         longer reach below the marked floor.
    /// @dev MUTATION: as above -> RED here (the zeroed target frees the whole pool again).
    function test_CSGF1_zeroingTheFirstLossTargetCannotFreeCreditedCapital() public {
        vm.prank(admin);
        curator.setFirstLossTarget(FILM, 100_000e18);
        _postFirstLoss(anchorCurator, FILM, 900_000e18);
        uint256 id = _liveFilmFacility(700_000e18);
        uint64 nextDue = bridge.facility(id).nextPaymentDue;
        vm.warp(uint256(nextDue) + defaultManager.graceWindow(FILM) + 1);
        defaultManager.markPastDue(id);

        vm.prank(admin);
        curator.setFirstLossTarget(FILM, 0);
        assertEq(curator.headroom(FILM), 200_000e18, "CSG-F1: one governance call moved credited capital out");
    }

    /// @notice THE FAIL-CLOSED HALF OF THE SAME GUARD. `ReserveManager.setLossAbsorber` validates
    ///         only `reserveLossSource()`, so a mis-wired or not-yet-upgraded absorber can be
    ///         present and unable to answer the two credit getters. "Cannot tell" must not read as
    ///         "nothing is credited" — the same reasoning `custodyFreezeActive()` states for its own
    ///         unwired case — so an unreadable book LOCKS the pool. It must do so WITHOUT
    ///         reverting: `headroom()` and `requiredFirstLoss()` are read by `Validate.s.sol`, by
    ///         dashboards and by the invariant oracles.
    /// @dev MUTATION: `if (!okDeclared || !okPastDue) return 0;` in
    ///      `CuratorModule._markedFirstLoss` (compiles; both operands still read) -> RED here.
    function test_CSGF1_anUnreadableCreditBookLocksThePoolWithoutRevertingTheViews() public {
        vm.prank(admin);
        curator.setFirstLossTarget(FILM, 0);
        _postFirstLoss(anchorCurator, FILM, 100_000e18);
        assertEq(curator.headroom(FILM), 100_000e18, "precondition: with no mark the whole pool is free");

        S2MuteCreditBook mute = new S2MuteCreditBook(address(reserves));
        vm.prank(admin);
        reserves.setLossAbsorber(address(mute));

        // The VIEWS still answer -- loudly, with a sentinel, and never by reverting.
        assertEq(curator.requiredFirstLoss(FILM), type(uint128).max, "an unreadable book publishes the lock sentinel");
        assertEq(curator.headroom(FILM), 0, "an unreadable book locks the pool");
        vm.expectRevert(
            abi.encodeWithSelector(ICuratorModule.Curator_HeadroomExceeded.selector, FILM, uint256(1e18), uint256(0))
        );
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 1e18);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  helpers
    // ═════════════════════════════════════════════════════════════════════

    function _shortBookWithJuniorCapital() private returns (uint256 id) {
        id = _liveFilmFacility(500_000e18);
        _mintUSDfrTo(alice, 400_000e18);
        _mintUSDfrTo(anchorCurator, 200_000e18);
        vm.prank(admin);
        curator.setCuratorApproved(FILM, anchorCurator, true);
        vm.startPrank(anchorCurator);
        usdfr.approve(address(curator), 200_000e18);
        curator.postFirstLoss(FILM, 200_000e18);
        vm.stopPrank();
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(id, 100_000e18, keccak256("sweep2-mark"));
    }
}

/// @dev SWEEP-2 CSG-F1. A loss absorber that passes `ReserveManager.setLossAbsorber`'s only check
///      (`reserveLossSource()`) and cannot answer the two credit getters — a mis-wired or
///      not-yet-upgraded manager. It has no fallback, so the raw staticcalls REVERT; a permissive
///      fallback answering with empty returndata is covered by the same length check.
contract S2MuteCreditBook {
    address internal immutable RESERVE_SOURCE;

    constructor(address reserveSource) {
        RESERVE_SOURCE = reserveSource;
    }

    function reserveLossSource() external view returns (address) {
        return RESERVE_SOURCE;
    }
}

/// @dev SWEEP-2 S2-F5 control. Unlike `LyingExitDrawSource` this one is parameterised over BOTH
///      failure modes the delivery measurement must still refuse.
contract S2LyingDrawSource {
    enum Mode {
        OverReport, // reports `required`, moves nothing
        OverRequest // reports MORE than `required`

    }

    address internal immutable RESERVE_SOURCE;
    Mode public mode;

    constructor(address reserveSource) {
        RESERVE_SOURCE = reserveSource;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function reserveLossSource() external view returns (address) {
        return RESERVE_SOURCE;
    }

    function drawForSeniorExit(uint256 required) external view returns (uint256) {
        return mode == Mode.OverReport ? required : required + 1;
    }
}

/// @title SWEEP-2 REMEDIATION — the reserve/custody cascade and the affordability ceiling
contract SweepR2_RemediationReserve is GovernanceFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;

    /// @dev `sUSDfr.IMPAIRMENT_SOURCE_PROBE_GAS` after SWEEP-2 F-S2-01 raised it from 200,000.
    uint256 internal constant HARD_PROBE_CAP = 400_000;
    /// @dev The affordability ceiling, re-pinned against the PRODUCTION shape (measured 187,865).
    uint256 internal constant PRODUCTION_CEILING = 250_000;

    /// @dev Compose the older sweep scenarios with W7's arm-bound custody adjudication. Reuse the
    ///      standing arm for a later incremental loss in the same test; every amount is still
    ///      rederived from a real physical shortfall at execution.
    function _applyCustodyLoss(uint256 context, uint256 loss) internal {
        (uint256 armId,,,) = reserves.reserveLossArm();
        if (armId == 0) _armReserveLoss(context);
        _createReserveShortfall(loss);
        (, uint256 actualLoss) = _ratifyCurrentReserveLoss(loss);
        assertEq(actualLoss, loss, "fixture: ratification must use the canonical live loss");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  F-S2-02 (HIGH) — a custody loss landing on a standing G3 mark must
    //                   still run the cascade.
    // ═════════════════════════════════════════════════════════════════════

    /// @notice CONTROL — with NO standing G3 mark, a custody write-down charges cascade layer 1.
    ///         Kept so a red on the test below is attributable to the mark and not the fixture.
    function test_FS202_control_aCustodyLossChargesLayer1WhenNoMarkStands() public {
        _postFirstLoss(anchorCurator, FILM, 300_000e18);
        uint256 poolBefore = curator.poolBalance(FILM);

        _applyCustodyLoss(41, 50_000e18);

        assertEq(poolBefore - curator.poolBalance(FILM), 50_000e18, "control: layer 1 absorbs the whole custody loss");
    }

    /// @notice ══════════════ THE MEASURED HIGH, INVERTED (SWEEP-2 F-S2-02) ══════════════════════
    ///         `_allocateReserveLoss` branched on `deficitBefore != 0` while its own comment said
    ///         "once genuine insolvency is LATCHED" — and the latch is `$.reserveDeficit`.
    ///         `recognizePrincipalImpairment` (the G3 governance valuation act) lowers backing
    ///         WITHOUT burning supply and WITHOUT writing any latch, so `supply > backing` with
    ///         `reserveDeficit == 0` is the ORDINARY state of a workout. A custody write-down
    ///         landing there took the record-only branch and NEVER CALLED THE ABSORBER AT ALL.
    ///         MEASURED PRE-FIX: the identical 50,000e18 custody loss charged layer 1 in full with
    ///         no mark standing, and charged NOBODY with one — curator pool, sGROVE capacity and
    ///         vault assets bit-for-bit unchanged, the loss simply latching. That is ADR-0034 X
    ///         layer 4 (every USDfr holder, through the price) paying while layers 1-3 sit intact:
    ///         the locked §1.3 cascade skipped entirely, not merely inverted.
    /// @dev MUTATION: change the branch predicate back to `if (deficitBefore != 0)` (compiles;
    ///      `$.reserveDeficit` is still read three lines above) -> RED here.
    function test_FS202_aCustodyLossLandingOnAStandingMarkStillRunsTheCascade() public {
        _postFirstLoss(anchorCurator, FILM, 300_000e18);
        uint256 id = _liveFilmFacility(1_000_000e18);
        uint256 poolBefore = curator.poolBalance(FILM);

        // the G3 valuation act: under-backed with NO incident, NO reserveDeficit, NO live shortfall
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(id, 400_000e18, keccak256("adjudication"));
        assertGt(controller.totalUSDfr(), controller.backingValue(), "precondition: the mark leaves the book short");
        assertEq(reserves.reserveDeficit(), 0, "precondition: no LATCHED deficit -- this is a mark, not insolvency");
        uint256 deficitBefore = controller.totalUSDfr() - controller.backingValue();

        _applyCustodyLoss(42, 50_000e18);

        assertEq(
            poolBefore - curator.poolBalance(FILM),
            50_000e18,
            "F-S2-02: layer 1 must absorb the NEW custody loss even while a G3 mark stands"
        );
        // ═══════════ INVERTED LOUDLY (SWEEP-3 F-S3-02, HIGH) — DO NOT REVERT THIS ═══════════
        // THIS ASSERTION USED TO READ `assertEq(reserves.reserveDeficit(), deficitBefore)`, i.e. it
        // ASSERTED THE DEFECT AS A SAFETY PROPERTY. It is not one. `$.reserveDeficit` is the LATCH
        // `_allocateReserveLoss` branches on; latching the carried mark armed the record-only
        // branch, so the NEXT custody loss skipped layers 1-3 ENTIRELY — the verbatim defect
        // F-S2-02 was written to close, back one transaction later. See the SWEEP-3 F-S3-02 block
        // on `ReserveManager._recordPostLossDeficit` and
        // `test_S3_F2_aSecondCustodyLossOnAStandingMarkSkipsTheCascadeEntirely`.
        //
        // The correct property: a cascade that absorbed the whole NEW hole latches NOTHING. The
        // carried mark is still re-published in `allocation.residualDeficit` (the reconciliation is
        // untouched, to the wei) and still visible as `supply > backing`; it is simply not a
        // cascade shortfall and does not arm the record-only branch.
        assertGt(deficitBefore, 0, "precondition: the mark really did leave a carried deficit to mis-latch");
        assertEq(
            reserves.reserveDeficit(),
            0,
            "F-S3-02: a fully absorbed loss must latch NOTHING -- the carried mark is not a cascade shortfall"
        );
        assertGt(controller.totalUSDfr(), controller.backingValue(), "the carried mark is still visible as a mark");
    }

    /// @notice ═══════ INVERTED LOUDLY (SWEEP-3 F-S3-02 STEP 2, HIGH) — DO NOT REVERT THIS ═══════
    ///
    ///         THIS TEST USED TO ASSERT THE DEFECT AS A SAFETY PROPERTY. Under the name
    ///         `test_FS202_aLatchedInsolvencyStillRecordsWithoutSpendingMoreJuniorCapital` it
    ///         asserted `curator.poolBalance(FILM) == poolBefore` — i.e. that FRESH curator
    ///         first-loss capital, posted deliberately AFTER the latch and sitting there for
    ///         exactly this purpose, must NOT absorb the next custody loss. That is the locked
    ///         §1.3 cascade ordering skipped, not merely inverted: 10,000e18 of a NEW, separately
    ///         adjudicated loss went straight to ADR-0034 X layer 4 (every USDfr holder, through
    ///         the price) over a live 15,000e18 layer-1 pool.
    ///
    ///         "Governance recapitalises explicitly" was the stated justification, and it does not
    ///         survive contact with the state: the curator CANNOT withdraw that capital
    ///         (`custodyLossUnabsorbed()` limb 2 is latched and holds layer 1 frozen), so the
    ///         protocol was simultaneously refusing to let layer 1 leave AND refusing to let it
    ///         absorb. Capital conscripted and then not used is the worst of both.
    ///
    ///         THE CORRECT PROPERTY, which is what is asserted below: every new loss is an
    ///         INCREMENTAL DELTA and is offered to all three layers unconditionally. A standing
    ///         latch constrains EXITS; it never suppresses the next cascade.
    /// @dev MUTATION: reintroduce the record-only branch in `_allocateReserveLoss` —
    ///      `if ($.reserveDeficit != 0) { expectedAccounted = deficitBefore + backingReduction;
    ///      allocation.residualDeficit = expectedAccounted; } else { ...the shipped body... }`
    ///      (compiles; every operand is still read) -> RED here. Shipped as `S2D-1` in
    ///      `mutations/s2delta_mut.py`.
    function test_S3_F2_freshLayer1CapitalAbsorbsALaterLossEvenWithALatchedInsolvency() public {
        _postFirstLoss(anchorCurator, FILM, 20_000e18);
        _mintUSDfrTo(alice, 200_000e18); // idle USDC to write down; alice does not stake
        // Pre-minted, posted AFTER the latch: minting is CLOSED while under-backed, so a
        // post-latch top-up can only come from USDfr that already exists.
        _mintUSDfrTo(secondCurator, 15_000e18);
        vm.prank(admin);
        curator.setCuratorApproved(FILM, secondCurator, true);
        _applyCustodyLoss(43, 190_000e18); // exhausts every layer -> latches
        assertEq(curator.poolBalance(FILM), 0, "precondition: layer 1 was fully consumed first");
        assertGt(reserves.reserveDeficit(), 0, "precondition: the cascade could not absorb, so it latched");

        vm.startPrank(secondCurator); // fresh layer-1 capital arrives post-latch
        usdfr.approve(address(curator), 15_000e18);
        curator.postFirstLoss(FILM, 15_000e18);
        vm.stopPrank();
        uint256 poolBefore = curator.poolBalance(FILM);
        uint256 latchBefore = reserves.reserveDeficit();
        assertEq(poolBefore, 15_000e18, "precondition: layer 1 is refilled and able to absorb");
        assertTrue(
            reserves.custodyLossUnabsorbed(),
            "precondition: the freeze holds that capital in place -- it cannot be withdrawn instead"
        );

        _applyCustodyLoss(43, 10_000e18);

        assertEq(
            poolBefore - curator.poolBalance(FILM),
            10_000e18,
            "F-S3-02 STEP 2: the NEW loss must be offered to layer 1 even while a previous deficit is latched"
        );
        // ...and the previous, genuine residual is NOT erased by the later fully-absorbed loss.
        // The delta is the whole of the change: latch += incrementalHole - burns == 0.
        assertEq(
            reserves.reserveDeficit(), latchBefore, "the standing residual survives; the new loss added nothing to it"
        );
    }

    /// @notice GUARANTEE — A PRE-EXISTING VALUATION MARK IS NOT CHARGED TWICE. The delta transition
    ///         runs unconditionally, so the obvious wrong way to write it is to offer the absorber
    ///         the WHOLE hole (`totalHole`) rather than the increment. That would charge the junior
    ///         tranche 450,000e18 for a 50,000e18 custody loss — collecting the standing G3 mark a
    ///         second time, when `DefaultManager.realizeLoss` is what consumes it through its own
    ///         cascade. Layer 1 must move by the loss and by nothing more, and layers 2 and 3 must
    ///         not be reached at all while layer 1 can still pay.
    /// @dev MUTATION: `absorber.absorbReserveLoss(incidentId, totalHole)` (compiles;
    ///      `incrementalHole` is still read by `expectedSurplus`) -> RED here.
    ///      Shipped as `S2D-4` in `mutations/s2delta_mut.py`.
    function test_S3_F2d_aStandingValuationMarkIsNeverChargedToTheCascadeASecondTime() public {
        _postFirstLoss(anchorCurator, FILM, 500_000e18);
        uint256 id = _liveFilmFacility(1_000_000e18);
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(id, 400_000e18, keccak256("adjudication"));

        uint256 poolBefore = curator.poolBalance(FILM);
        uint256 backstopBefore = usdfr.balanceOf(address(backstopMock));
        uint256 vaultBefore = vault.totalAssets();
        assertGe(poolBefore, 450_000e18, "precondition: layer 1 COULD pay the mark twice over if asked");

        _applyCustodyLoss(47, 50_000e18);

        assertEq(poolBefore - curator.poolBalance(FILM), 50_000e18, "layer 1 pays the INCREMENT, not the whole hole");
        assertEq(usdfr.balanceOf(address(backstopMock)), backstopBefore, "layer 2 is not reached");
        assertEq(vault.totalAssets(), vaultBefore, "layer 3 is not reached");
        assertEq(reserves.totalPrincipalImpairment(), 400_000e18, "the mark itself is untouched -- it is still owed");
    }

    /// @notice GUARANTEE — A GENUINE PREVIOUS RESIDUAL STAYS VISIBLE. The companion to the test
    ///         above, isolating the LATCH rather than the cascade. Netting the whole of
    ///         `deficitBefore` off the latch (the obvious, wrong simplification of the carried-mark
    ///         subtraction) would report the protocol as having NO unabsorbed cascade shortfall the
    ///         instant a later, fully-absorbed loss landed on a standing insolvency — releasing
    ///         `custodyLossUnabsorbed()` limb 2, and with it cascade layer 1, over a book that is
    ///         still short by the original residual.
    /// @dev MUTATION: `carriedDeficit = deficitBefore;` (drop the `latchedBefore` clamp; compiles,
    ///      `latchedBefore` is still read by the `DeficitResolutionRequired` guard) -> RED here.
    ///      Shipped as `S2D-2` in `mutations/s2delta_mut.py`.
    function test_S3_F2b_aGenuineLatchedResidualSurvivesALaterFullyAbsorbedLoss() public {
        _postFirstLoss(anchorCurator, FILM, 20_000e18);
        _mintUSDfrTo(alice, 200_000e18);
        _mintUSDfrTo(secondCurator, 15_000e18);
        vm.prank(admin);
        curator.setCuratorApproved(FILM, secondCurator, true);
        _applyCustodyLoss(44, 190_000e18); // exhausts every layer -> latches a GENUINE residual
        uint256 residual = reserves.reserveDeficit();
        assertGt(residual, 0, "precondition: a genuine, cascaded-but-unabsorbed shortfall stands");

        vm.startPrank(secondCurator);
        usdfr.approve(address(curator), 15_000e18);
        curator.postFirstLoss(FILM, 15_000e18);
        vm.stopPrank();

        _applyCustodyLoss(44, 10_000e18); // fully absorbed by the refilled layer 1

        assertEq(curator.poolBalance(FILM), 5_000e18, "precondition: the new loss really was absorbed IN FULL");
        assertEq(
            reserves.reserveDeficit(),
            residual,
            "F-S3-02 STEP 2: the standing residual must survive -- it is not a carried valuation mark"
        );
        assertTrue(reserves.custodyLossUnabsorbed(), "limb 2 must still hold layer 1 over a book that is still short");
    }

    /// @notice THE INCREMENTAL-ACCOUNTING IDENTITY, FUZZED OVER THE WHOLE LATCHED REGION.
    ///
    ///         WHY A FUZZ TEST AND NOT AN INVARIANT. `CascadeSeniorityHandler._maxCustodyLoss`
    ///         opens with `if (supplyNow > backingNow || reserves.reserveDeficit() != 0) return 0;`
    ///         — the stateful custody campaign REFUSES BY CONSTRUCTION to enter the region this fix
    ///         is about, so it would report green over any behaviour here whatsoever. (That gate is
    ///         correct for what that handler models: its layer-by-layer predictions are all written
    ///         for `deficitBefore == 0`.) Rather than re-derive that model, the region is covered
    ///         densely here instead.
    ///
    ///         TWO PROPERTIES, both of which the deleted record-only branch violated:
    ///           1. THE CASCADE IS CONSULTED. With layer-1 capital standing, a new loss burns
    ///              supply. The record-only branch burned exactly zero, always.
    ///           2. THE DELTA IDENTITY. `latchAfter == latchBefore + loss - burned`. The latch is
    ///              an OUTPUT of the transition, never an input to it.
    ///         Deliberately asserted against SUPPLY BURNED rather than against `CuratorModule`'s
    ///         internal allocation policy, so this stays a statement about `ReserveManager` while a
    ///         parallel stream is editing the curator.
    function testFuzz_S3_F2_theLatchIsAnOutputOfEveryLossNotAnInputToIt(
        uint256 rawLatch,
        uint256 rawRefill,
        uint256 rawLoss
    ) public {
        // Whole USDC units throughout: `_mintUSDfrTo` and `writeDownIdleUSDC` both refuse dust.
        uint256 refill = (bound(rawRefill, 1_000e18, 60_000e18) / 1e12) * 1e12;
        uint256 latch0 = (bound(rawLatch, 10_000e18, 120_000e18) / 1e12) * 1e12;
        // Everything is minted BEFORE the hole: issuance is closed while under-backed.
        _mintUSDfrTo(alice, 400_000e18); // idle USDC; unstaked, so layers 2 and 3 stay empty
        _mintUSDfrTo(secondCurator, refill);
        vm.prank(admin);
        curator.setCuratorApproved(FILM, secondCurator, true);

        // A GENUINE latched shortfall: no junior capital is posted yet, so this cascade absorbs
        // nothing and the whole write-down latches.
        _applyCustodyLoss(48, latch0);
        assertEq(reserves.reserveDeficit(), latch0, "fixture: the whole first loss latched");

        vm.startPrank(secondCurator);
        usdfr.approve(address(curator), refill);
        curator.postFirstLoss(FILM, refill);
        vm.stopPrank();

        uint256 loss = (bound(rawLoss, 1_000e18, reserves.idleReserve()) / 1e12) * 1e12;
        uint256 supplyBefore = controller.totalUSDfr();
        _applyCustodyLoss(48, loss);
        uint256 burned = supplyBefore - controller.totalUSDfr();

        assertGt(burned, 0, "F-S3-02 STEP 2: a latched deficit must not stop the cascade being consulted");
        assertLe(burned, loss, "the cascade can never burn more supply than the backing the loss destroyed");
        assertEq(
            reserves.reserveDeficit(),
            latch0 + loss - burned,
            "F-S3-02 STEP 2: latchAfter == latchBefore + incrementalHole - actualBurns"
        );
    }

    /// @notice GUARANTEE — THE CASCADE NEVER BRANCHES ON `reserveDeficit != 0`. A differential:
    ///         two runs whose LIVE state (supply, backing, layer-1/2/3 capital, the size of the new
    ///         loss) is identical to the wei, differing ONLY in whether `reserveDeficit` is latched.
    ///         The allocation charged to layer 1 must be bit-for-bit the same. This is the property
    ///         the three previous remediation rounds each restated and each left one branch short
    ///         of; it is asserted here directly instead of through any one of its symptoms.
    /// @dev MUTATION: either `S2D-1` (record-only branch) or `S2D-3` (`if (deficitBefore != 0)`
    ///      record-only branch) -> RED here.
    function test_S3_F2c_theCascadeAllocationIsIndifferentToTheLatch() public {
        uint256 charged = _chargeALossOnAHoleOf(true);
        uint256 control = _chargeALossOnAHoleOf(false);
        assertEq(control, 25_000e18, "control: with an UNLATCHED hole of the same size, layer 1 pays in full");
        assertEq(charged, control, "the latch must not change what the cascade charges layer 1");
    }

    /// @dev Builds a 100,000e18 hole in `supply - backing` and then charges an identical
    ///      25,000e18 custody loss against an identical, freshly posted 25,000e18 layer-1 pool.
    ///      `latched == true` makes the hole a LATCHED cascade shortfall (an exhausted custody
    ///      cascade); `latched == false` makes it an UNLATCHED G3 valuation mark. Every other
    ///      observable is equal by construction.
    function _chargeALossOnAHoleOf(bool latched) internal returns (uint256 layer1Charged) {
        uint256 snapshot = vm.snapshotState();
        // Everything is minted BEFORE the hole exists: issuance is closed while under-backed, so a
        // post-hole top-up is impossible and both arms must be funded identically up front.
        _mintUSDfrTo(alice, 200_000e18); // idle USDC to write down; unstaked, so layer 3 is empty
        _mintUSDfrTo(secondCurator, 25_000e18); // the layer-1 capital under test
        uint256 id = _liveFilmFacility(150_000e18); // identical facility in BOTH arms
        vm.prank(admin);
        curator.setCuratorApproved(FILM, secondCurator, true);

        if (latched) {
            // No junior capital is posted yet, so this cascade is offered the loss and absorbs
            // NOTHING: a GENUINE, cascaded-but-unabsorbed shortfall latches.
            _applyCustodyLoss(45, 100_000e18);
            assertEq(reserves.reserveDeficit(), 100_000e18, "fixture: the hole is a LATCHED shortfall");
        } else {
            vm.prank(admin);
            reserves.recognizePrincipalImpairment(id, 100_000e18, keccak256("same-size-hole"));
            assertEq(reserves.reserveDeficit(), 0, "fixture: the hole is an UNLATCHED valuation mark");
            _armReserveLoss(46);
        }
        assertEq(
            controller.totalUSDfr() - controller.backingValue(), 100_000e18, "fixture: both arms have the SAME hole"
        );

        vm.startPrank(secondCurator);
        usdfr.approve(address(curator), 25_000e18);
        curator.postFirstLoss(FILM, 25_000e18);
        vm.stopPrank();
        assertEq(curator.poolBalance(FILM), 25_000e18, "fixture: both arms have the SAME layer-1 capital");

        uint256 poolBefore = curator.poolBalance(FILM);
        _applyCustodyLoss(latched ? 45 : 46, 25_000e18);
        layer1Charged = poolBefore - curator.poolBalance(FILM);
        vm.revertToState(snapshot);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  F-S2-01 (MEDIUM) — the affordability ceiling, re-measured on the
    //                     PRODUCTION shape rather than a one-class fixture.
    // ═════════════════════════════════════════════════════════════════════

    /// @notice THE BINDING AFFORDABILITY TEST. `ConservativeImpairmentMathLiveEquivalence
    ///         ::test_markStaysWellInsideTheImpairmentSourceProbeBudget` measures a fixture with
    ///         ONE impaired class, no past-due cohort, no drawn cohort and no ADR-0027 assessment —
    ///         and `pendingSeniorImpairment`'s loop does `if (d == 0) continue;` BEFORE
    ///         `curator.poolBalance(classId)`, so four of five per-class proxy hops never happen.
    ///         MEASURED PRE-FIX: that fixture 98,909 gas; the production shape 142,465; with a live
    ///         ADR-0027 assessment 166,691; with the permissionless `fundCoverage` top-up ADR-0027
    ///         requires NOT to invalidate an assessment, 187,865 — i.e. 6.1% headroom under the old
    ///         200,000 budget, not the 50% the calculator's NatSpec claimed, and 9,465 OVER the
    ///         133,000 ceiling that was reporting green in CI.
    /// @dev MUTATION: lower `sUSDfr.IMPAIRMENT_SOURCE_PROBE_GAS` back to 200,000 (compiles) -> the
    ///      interlock test below reds. Lower `PRODUCTION_CEILING` to 133,000 -> this test reds.
    function test_FS201_theProductionShapeFitsTheProbeBudgetWithRealHeadroom() public {
        _productionWorkoutShape();

        uint256 base = defaultManager.pendingSeniorImpairment();
        vm.prank(admin);
        assessedImpairmentSource.setAssessment(base / 2, uint64(block.timestamp + 20 days), keccak256("memo"));
        // permissionless, and deliberately NOT assessment-invalidating (ADR-0027)
        _seedCoverage(50_000e18);
        (bytes32 assessedHash, bytes32 liveHash, bool matches) = assessedImpairmentSource.assessmentState();
        assertTrue(assessedHash != liveHash, "the exact hash must have moved, forcing the directional path");
        assertTrue(matches, "the assessment must still be VALID -- that is the point of the directional path");

        assessedImpairmentSource.pendingSeniorImpairment();
        _coolWholeMarkPath();

        uint256 before = gasleft();
        assessedImpairmentSource.pendingSeniorImpairment();
        uint256 used = before - gasleft();
        emit log_named_uint("PRODUCTION SHAPE + ASSESSMENT + PERMISSIONLESS TOP-UP", used);
        emit log_named_uint("pinned ceiling", PRODUCTION_CEILING);
        emit log_named_uint("hard probe cap", HARD_PROBE_CAP);

        assertLt(used, PRODUCTION_CEILING, "F-S2-01: the production shape must fit the PINNED ceiling");
        assertLt(used, HARD_PROBE_CAP, "F-S2-01: and must answer inside sUSDfr's probe budget");
    }

    /// @notice THE CONSEQUENCE, ASSERTED ON THE INTERLOCK ITSELF. The only gas-capped consumer of
    ///         the mark is `sUSDfr.clearUnreadableImpairmentSource()`, which REFUSES while the
    ///         source answers inside `IMPAIRMENT_SOURCE_PROBE_GAS`. Under-budgeting that probe does
    ///         not break redemption pricing — it makes an incident-response lever that permanently
    ///         drops the conservative mark and ratchets the HWM fee-free usable against a HEALTHY
    ///         source. This asserts the interlock still fires in the production workout shape.
    /// @dev MUTATION: lower `IMPAIRMENT_SOURCE_PROBE_GAS` to 150,000 (compiles) -> RED here: the
    ///      healthy source is declared unreadable and the clear succeeds.
    function test_FS201_theStillReadableInterlockFiresInTheProductionWorkoutShape() public {
        _productionWorkoutShape();
        assertEq(vault.impairmentSource(), address(assessedImpairmentSource), "precondition: the source is wired");
        uint256 base = defaultManager.pendingSeniorImpairment();
        vm.prank(admin);
        assessedImpairmentSource.setAssessment(base / 2, uint64(block.timestamp + 20 days), keccak256("memo"));
        _seedCoverage(50_000e18);
        // COLD, exactly as a real `clearUnreadableImpairmentSource()` transaction is. Warm storage
        // makes this read ~3x cheaper and would hide the whole finding: the pre-fix 200,000 budget
        // measured GREEN on a warm one-class fixture while the cold production shape cost 187,865.
        _coolWholeMarkPath();

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IsUSDfrErrors.SUSDfr_ImpairmentSourceStillReadable.selector, address(assessedImpairmentSource)
            )
        );
        vault.clearUnreadableImpairmentSource();
        assertEq(vault.impairmentSource(), address(assessedImpairmentSource), "a healthy source survives the lever");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  CSG-F2 (MEDIUM) — the G2W relief ramp's time bound is now enforced.
    // ═════════════════════════════════════════════════════════════════════

    /// @notice `ConservativeImpairmentMath` states the ramp's safety property as "a senior who
    ///         requests AT or AFTER the mark cannot settle before `requestedAt +
    ///         DEFAULT_REDEEM_COOLDOWN`, by which point the weight is FULL". That is a claim about
    ///         `RedemptionQueue.setRedeemCooldown`, and NOTHING pinned the two together — the
    ///         SEAM-1 shape. MEASURED PRE-FIX: `setRedeemCooldown(7 days)` let a reactor settle
    ///         INSIDE the ramp for 133,360e18 more than the honest full-weight price on a
    ///         2,000,000e18 tranche, and the holder who STAYED lost exactly 133,360e18.
    /// @dev MUTATION: `if (cooldown < Config.DEFAULT_REDEEM_COOLDOWN && cooldown ==
    ///      type(uint64).max || cooldown > Config.MAX_REDEEM_COOLDOWN)` (compiles, both operands
    ///      still read) -> RED here on the shortening leg.
    function test_CSGF2_theQueueCooldownCanNeverFallBelowTheG2WReliefRamp() public {
        assertEq(queue.redeemCooldown(), Config.DEFAULT_REDEEM_COOLDOWN, "precondition: launched at the ramp");
        for (uint256 i = 0; i < 4; ++i) {
            uint64 shortened = [uint64(0), 1 days, 7 days, Config.DEFAULT_REDEEM_COOLDOWN - 1][i];
            vm.expectRevert(IRedemptionQueue.Queue_BadParams.selector);
            vm.prank(admin);
            queue.setRedeemCooldown(shortened);
        }
        // the boundary is inclusive on the ramp itself, and lengthening within the bound is legal
        vm.prank(admin);
        queue.setRedeemCooldown(Config.DEFAULT_REDEEM_COOLDOWN);
        vm.prank(admin);
        queue.setRedeemCooldown(Config.MAX_REDEEM_COOLDOWN);
        assertEq(queue.redeemCooldown(), Config.MAX_REDEEM_COOLDOWN, "the upper bound itself is legal");

        // ...and the fat-finger that permanently freezes every senior exit is refused.
        vm.expectRevert(IRedemptionQueue.Queue_BadParams.selector);
        vm.prank(admin);
        queue.setRedeemCooldown(Config.MAX_REDEEM_COOLDOWN + 1);
        vm.expectRevert(IRedemptionQueue.Queue_BadParams.selector);
        vm.prank(admin);
        queue.setRedeemCooldown(type(uint64).max);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  helpers
    // ═════════════════════════════════════════════════════════════════════

    function _seedCoverage(uint256 amount) internal {
        _mintUSDfrTo(bob, amount);
        vm.startPrank(bob);
        usdfr.approve(address(sGrove), amount);
        sGrove.fundCoverage(amount);
        vm.stopPrank();
    }

    /// @dev Originates and funds a RECEIVABLE facility in ANY of classes 1-4. The shipped
    ///      `_liveFilmFacility` is hard-wired to class 1, which is exactly why the affordability
    ///      fixture only ever impairs ONE class and only ever pays for ONE per-class proxy hop.
    function _liveReceivable(uint256 classId, bytes32 borrowerId, uint256 principal) internal returns (uint256 id) {
        _mintUSDfrTo(alice, principal);
        uint64 maturity = uint64(block.timestamp + 300 days);
        uint256 nextId = bridge.totalOriginated() + 1;
        // P-45: only the film/tax-credit class carries a state key; the other
        // receivable classes must use the zero sentinel.
        bytes32 stateId = classId == Config.CLASS_FILM_TAX_CREDITS ? STATE_GA : bytes32(0);
        ClaimBridge.OriginationTerms memory terms =
            _facilityTerms(classId, borrowerId, stateId, principal, 5000, FILM_RATE_BPS, maturity, FILM_REF);
        _setSatisfied(nextId, IAttestationOracle.AttestationKind.AssignmentExecuted, true);
        _setSatisfied(nextId, IAttestationOracle.AttestationKind.UCCFiled, true);
        _attestCreditTerms(nextId, bridge.creditTermsHash(terms));
        vm.prank(originator);
        id = bridge.originate(custodian, terms);
        _fundFacility(id, principal);
    }

    function _declare(uint256 id) internal {
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
    }

    /// @dev THE SHAPE A WORKOUT IS ACTUALLY IN: all five curator pools impaired (so every per-class
    ///      proxy hop is paid), a live DRAWN cohort (so the PM-R-11 `liveDefaultCapacityFloor` read
    ///      fires) and a live PAST-DUE cohort mid-ramp (so `conservativeSeniorMark` takes its long
    ///      path instead of the `elapsed >= ramp` early return).
    function _productionWorkoutShape() internal {
        _seedCoverage(2_000_000e18);
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            _postFirstLoss(anchorCurator, classId, 10_000e18);
        }
        uint256 film = _liveReceivable(Config.CLASS_FILM_TAX_CREDITS, keccak256("b1"), 300_000e18);
        uint256 energy = _liveReceivable(Config.CLASS_RENEWABLE_ENERGY, keccak256("b2"), 300_000e18);
        uint256 life = _liveReceivable(Config.CLASS_LIFE_SCIENCES, keccak256("b3"), 300_000e18);
        uint256 realEstate = _liveReceivable(Config.CLASS_REAL_ESTATE, keccak256("b4"), 300_000e18);
        uint256 digital = _originateDigital(300_000e18, 1_000_000e18);
        _fundFacility(digital, 300_000e18);
        _declare(film);
        _declare(energy);
        _declare(life);
        _declare(realEstate);
        _declare(digital);
        _realizeLoss(film, 60_000e18, keccak256("sweep2-loss"));
        assertGt(defaultManager.liveDefaultCoverageConsumed(), 0, "the drawn cohort must be live");

        uint256 pastDue = _liveReceivable(Config.CLASS_FILM_TAX_CREDITS, keccak256("b5"), 200_000e18);
        uint64 nextPaymentDue = bridge.facility(pastDue).nextPaymentDue;
        vm.warp(uint256(nextPaymentDue) + uint256(defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS)) + 1);
        vm.prank(carol);
        defaultManager.markPastDue(pastDue);
        assertGt(defaultManager.pastDueExposure(), 0, "the past-due cohort must be live");
        assertLt(
            block.timestamp - defaultManager.pastDueReliefAnchor(),
            Config.DEFAULT_REDEEM_COOLDOWN,
            "the ramp must be mid-flight, not expired"
        );
    }

    function _coolWholeMarkPath() internal {
        vm.cool(address(defaultManager));
        vm.cool(address(assessedImpairmentSource));
        vm.cool(address(defaultManager.impairmentMath()));
        vm.cool(address(curator));
        vm.cool(address(sGrove));
        vm.cool(address(registry));
        vm.cool(address(vault));
        vm.cool(address(usdfr));
    }
}

/// @dev Local alias so the interlock error selector can be named without importing the whole vault
///      interface into this file's namespace.
interface IsUSDfrErrors {
    error SUSDfr_ImpairmentSourceStillReadable(address source);
}
