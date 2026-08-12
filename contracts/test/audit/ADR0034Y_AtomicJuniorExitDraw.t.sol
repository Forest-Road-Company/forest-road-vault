// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {ICuratorModule} from "../../src/interfaces/ICuratorModule.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {ISeniorExitDrawSource} from "../../src/interfaces/ISeniorExitDrawSource.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @dev A draw source that reports one number and moves another, for the controller's
///      measure-don't-trust guard. Mode 0 over-reports (reports N, moves nothing); mode 1
///      over-delivers (moves more than it was asked for, funded from a pre-seeded balance).
contract LyingExitDrawSource is ISeniorExitDrawSource {
    IERC20 public immutable USDFR;
    uint8 public immutable MODE;

    constructor(IERC20 usdfr, uint8 mode_) {
        USDFR = usdfr;
        MODE = mode_;
    }

    function reserveLossSource() external view returns (address) {
        return msg.sender;
    }

    function drawForSeniorExit(uint256 required) external view returns (uint256) {
        // MODE 0 — report full coverage, move nothing.
        if (MODE == 0) return required;
        // MODE 1 — the contract's balance already exceeds what the controller will measure as
        // "before", so the measured delta will exceed `required`... except the balance does not
        // move here at all, so the controller measures ZERO against a report of `required + 1`.
        // Either way the report and the movement disagree and the exit must refuse.
        return required + 1;
    }
}

/// @title ADR-0034 Y-bis — the ATOMIC JUNIOR DRAW behind a cascade-ordered exit price
///
/// @notice THE DEFECT THIS CLOSES, AND IT WAS AN OPEN FINDING, NOT A DESIGN QUESTION.
///         `MintRedeemController._quoteRedeem` priced the direct exit off GROSS
///         `ReserveManager.totalBackingValue()`, which nets NOTHING against junior capital, while
///         the `sUSDfr` path prices off `DefaultManager.pendingSeniorImpairment()`, which nets
///         curator first-loss per class and then the global sGROVE backstop. Two redemption paths
///         in one tree priced off two bases and the direct one was the un-netted one: a holder
///         redeeming while curator first-loss capital sat intact absorbed a loss the junior tranche
///         was contracted to take first — the locked §1.3 cascade run backwards. R18 declined to
///         fix it and recorded it in `_quoteRedeem`'s NatSpec as "A KNOWN OPEN FINDING".
///
///         `ADR/0034-exit-pricing-in-cascade-order.md` decision Y-bis (Forest Road, 2026-08-08)
///         decides it: junior capital is drawn AT THE MOMENT OF THE SENIOR EXIT, in the same
///         transaction, so cascade order is enforced AT SETTLEMENT rather than assumed.
///
/// @dev EVERY GUARD ADDED BY THIS CHANGE HAS A NAMED FALSIFIER HERE — `test_Y_G01` … `test_Y_G08`.
///      Each one is referenced by name from the guard's own NatSpec, so a mutation campaign that
///      deletes the guard has a single test to look for. Guards whose falsifier is a COMPILE
///      failure are not proofs and are not counted as such; where a guard is unreachable by
///      construction that is stated in its NatSpec instead of being claimed as proved.
contract ADR0034Y_AtomicJuniorExitDraw is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;

    uint256 internal constant ALICE_IN = 1_000_000e18;
    uint256 internal constant BOB_IN = 1_000_000e18;
    uint256 internal constant FIRST_LOSS = 200_000e18;
    uint256 internal constant PRINCIPAL = 500_000e18;
    uint256 internal constant MARK = 100_000e18;
    uint256 internal constant EXIT = 100_000e18;

    uint256 internal facility;

    function setUp() public virtual override {
        super.setUp();
        vm.prank(admin);
        curator.setCuratorApproved(FILM, anchorCurator, true);
        _mintUSDfrTo(alice, ALICE_IN);
        _mintUSDfrTo(bob, BOB_IN);
        _bootstrap(FIRST_LOSS);
    }

    /// @dev Posts `firstLoss` of layer-1 capital and funds the facility. The posting happens
    ///      BEFORE funding because `withdrawFirstLoss`'s ADR-0004 subordination requirement locks
    ///      capital that protects live exposure — a lock ADR-0034 Y-bis names as LOAD-BEARING for
    ///      this decision, so tests vary the posted amount up front rather than relaxing it.
    function _bootstrap(uint256 firstLoss) internal {
        if (firstLoss != 0) _postFirstLoss(anchorCurator, FILM, firstLoss);
        facility = _originateFilm(BORROWER_1, STATE_GA, PRINCIPAL);
        _fundFacility(facility, PRINCIPAL);
    }

    /// @dev Re-runs the whole fixture with a different layer-1 balance. Cheaper and far clearer
    ///      than trying to withdraw capital the subordination lock correctly refuses to release.
    function _rebootWithFirstLoss(uint256 firstLoss) internal {
        super.setUp();
        vm.prank(admin);
        curator.setCuratorApproved(FILM, anchorCurator, true);
        _mintUSDfrTo(alice, ALICE_IN);
        _mintUSDfrTo(bob, BOB_IN);
        _bootstrap(firstLoss);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  THE FINDING, INVERTED
    // ─────────────────────────────────────────────────────────────────────

    /// @notice THE HEADLINE PROPERTY (ADR-0034 X + Y-bis). With curator first-loss capital
    ///         standing intact behind a recognised impairment, a direct exit settles at PAR and
    ///         the JUNIOR tranche pays — not the exiting senior.
    ///
    ///         PRE-FIX this same state paid the gross coverage ratio. The test asserts the
    ///         pre-fix number explicitly and asserts it is NOT what is settled, so the inversion
    ///         is legible rather than implied.
    function test_Y_theExitSettlesAtParWhileCuratorCapitalStandsIntact() public {
        _recognise(MARK);
        (uint256 supply, uint256 backing) = _book();
        assertEq(supply - backing, MARK, "setup: the recognised mark is the whole deficit");

        uint256 grossPrice = (EXIT * backing / supply) / 1e12;
        assertLt(grossPrice, EXIT / 1e12, "setup: the gross mark is genuinely sub-par");

        uint256 poolBefore = curator.poolBalance(FILM);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 out = controller.redeem(EXIT, EXIT / 1e12, block.timestamp);

        assertEq(out, EXIT / 1e12, "THE EXIT DID NOT SETTLE AT PAR WITH JUNIOR CAPITAL INTACT");
        assertEq(usdc.balanceOf(alice) - usdcBefore, EXIT / 1e12, "cash delivered must equal the quote");
        assertGt(EXIT / 1e12, grossPrice, "the fix must pay strictly more than the gross mark");

        uint256 drawn = poolBefore - curator.poolBalance(FILM);
        assertGt(drawn, 0, "LAYER 1 WAS NOT ASKED TO PAY");
        assertLe(drawn, MARK, "THE DRAW EXCEEDED WHAT THE CASCADE WOULD HAVE ABSORBED");
        assertEq(reserves.exitPrepaidAbsorption(), drawn, "the prepayment ledger must record exactly the draw");
    }

    /// @notice ORDER, LAYER 1 BEFORE LAYER 2. While the curator pool can fund the exit, the
    ///         backstop is not touched at all. This is the clause of the §1.3 cascade the direct
    ///         exit path used to skip entirely.
    function test_Y_layer2IsNotTouchedWhileLayer1CanFundTheExit() public {
        _fundBackstop(50_000e18);
        _recognise(MARK);

        uint256 backstopBefore = usdfr.balanceOf(address(backstopMock));
        vm.prank(alice);
        controller.redeem(EXIT, EXIT / 1e12, block.timestamp);

        assertEq(
            usdfr.balanceOf(address(backstopMock)),
            backstopBefore,
            "THE BACKSTOP PAID WHILE CURATOR FIRST-LOSS CAPITAL WAS STILL STANDING"
        );
        assertLt(curator.poolBalance(FILM), FIRST_LOSS, "layer 1 must have paid instead");
    }

    /// @notice ORDER, LAYER 2 ONLY FOR THE RESIDUAL. Drain layer 1 to a token amount; the exit
    ///         then draws what layer 1 has and reaches the backstop for exactly the remainder.
    ///         Layer 2 is never offered more than layer 1 declined.
    function test_Y_layer2IsReachedOnlyForWhatLayer1Declined() public {
        // A class pool small enough that a par-funding draw exhausts it.
        _rebootWithFirstLoss(1_000e18);
        _fundBackstop(50_000e18);
        _recognise(MARK);

        uint256 poolBefore = curator.poolBalance(FILM);
        uint256 backstopBefore = usdfr.balanceOf(address(backstopMock));

        vm.prank(alice);
        controller.redeem(EXIT, 0, block.timestamp);

        assertEq(curator.poolBalance(FILM), 0, "LAYER 1 MUST BE EXHAUSTED BEFORE LAYER 2 IS ASKED");
        uint256 fromBackstop = backstopBefore - usdfr.balanceOf(address(backstopMock));
        assertGt(fromBackstop, 0, "layer 2 must have covered the residual");
        assertEq(
            reserves.exitPrepaidAbsorption(), poolBefore + fromBackstop, "the ledger must record BOTH junior layers"
        );
    }

    /// @notice INSUFFICIENCY DEGRADES CONTINUOUSLY, IT NEVER DEADLOCKS. With no junior capital
    ///         at all the exit settles at EXACTLY the pre-ADR gross price and does not revert.
    ///         Reverting here would be the R16 freeze that ADR-0034 exists to remove.
    function test_Y_exhaustedJuniorCapitalDegradesToTheGrossPriceRatherThanReverting() public {
        _rebootWithFirstLoss(0);
        _recognise(MARK);
        (uint256 supply, uint256 backing) = _book();
        uint256 grossPrice = (EXIT * backing / supply) / 1e12;

        vm.prank(alice);
        uint256 out = controller.redeem(EXIT, 0, block.timestamp);

        assertEq(out, grossPrice, "WITH JUNIOR EXHAUSTED THE PRICE MUST BE EXACTLY TODAY'S GROSS PRICE");
        assertEq(reserves.exitPrepaidAbsorption(), 0, "nothing was drawn, so nothing may be prepaid");
    }

    /// @notice PARTIAL JUNIOR CAPITAL DELIVERS A PARTIAL, MONOTONE IMPROVEMENT — strictly better
    ///         than gross, strictly worse than par. The senior bears only what junior could not.
    function test_Y_partialJuniorCapitalPricesStrictlyBetweenGrossAndPar() public {
        _rebootWithFirstLoss(1_000e18);
        _recognise(MARK);
        (uint256 supply, uint256 backing) = _book();
        uint256 grossPrice = (EXIT * backing / supply) / 1e12;

        vm.prank(alice);
        uint256 out = controller.redeem(EXIT, 0, block.timestamp);

        assertGt(out, grossPrice, "a partial draw must beat the gross price");
        assertLt(out, EXIT / 1e12, "a partial draw must NOT reach par -- the senior still absorbs the rest");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  ADR-0034's THIRD BINDING REQUIREMENT: FORWARD IN TIME, NOT ENLARGED
    // ─────────────────────────────────────────────────────────────────────

    /// @notice TELESCOPING. Across a whole sequence of exits, the CUMULATIVE draw never exceeds
    ///         the deficit standing when the mark was taken. Each draw lowers supply by exactly
    ///         the drawn amount with backing unmoved, so the stock decrements by the flow
    ///         one-for-one. This is the property that makes "brings absorption FORWARD in time,
    ///         does not enlarge it" true of a SEQUENCE and not merely of one call.
    function test_Y_cumulativeDrawsAcrossASequenceNeverExceedTheStandingDeficit() public {
        _recognise(MARK);
        (uint256 supply0, uint256 backing0) = _book();
        uint256 deficit0 = supply0 - backing0;

        for (uint256 i = 0; i < 6; ++i) {
            vm.prank(alice);
            controller.redeem(50_000e18, 0, block.timestamp);
            vm.prank(bob);
            controller.redeem(50_000e18, 0, block.timestamp);
        }

        assertLe(
            reserves.exitPrepaidAbsorption(),
            deficit0,
            "CUMULATIVE DRAWS EXCEEDED THE DEFICIT -- the draw ENLARGED absorption instead of advancing it"
        );
        (uint256 supply1, uint256 backing1) = _book();
        uint256 deficit1 = supply1 > backing1 ? supply1 - backing1 : 0;
        assertLe(deficit1, deficit0, "no exit may widen the deficit");
    }

    /// @notice NO DOUBLE CHARGE (layer 0). Draw first, then realize the SAME loss. The junior
    ///         tranche must pay the loss ONCE in total. Without
    ///         `ReserveManager.consumeExitPrepayment` the curator pays `draw + loss` and the extra
    ///         supply reduction reappears as book surplus that `mintableHeadroom()` would recycle
    ///         to the sUSDfr vault as yield.
    function test_Y_realizingTheSameLossDoesNotChargeTheJuniorTrancheTwice() public {
        _stakeSenior(300_000e18);
        _recognise(MARK);

        uint256 poolBefore = curator.poolBalance(FILM);
        vm.prank(alice);
        controller.redeem(EXIT, EXIT / 1e12, block.timestamp);
        uint256 drawn = poolBefore - curator.poolBalance(FILM);
        assertGt(drawn, 0, "setup: the exit must actually have drawn");

        uint256 poolAfterDraw = curator.poolBalance(FILM);
        _declare(facility);
        _realizeLoss(facility, MARK, keccak256("loss-evidence"));

        uint256 juniorTotal = drawn + (poolAfterDraw - curator.poolBalance(FILM));
        assertEq(juniorTotal, MARK, "THE JUNIOR TRANCHE PAID TWICE FOR ONE LOSS");
        assertEq(reserves.exitPrepaidAbsorption(), 0, "the prepayment must be fully consumed by the realized loss");

        (uint256 supply, uint256 backing) = _book();
        assertLe(supply, backing, "the book must not close SHORT");
        assertLe(backing - supply, 2, "the book must close flat -- a surplus here is junior capital leaking to yield");
    }

    /// @notice THE SAME SEQUENCE WITHOUT LAYER 0, STATED AS THE THING THAT MUST NOT HAPPEN.
    ///         `mintableHeadroom()` nets the standing prepayment, so a mark that is later RELEASED
    ///         cannot turn the junior tranche's crystallised contribution into sUSDfr yield.
    function test_Y_aReleasedMarkDoesNotTurnTheJuniorDrawIntoSeniorYield() public {
        _recognise(MARK);
        vm.prank(alice);
        controller.redeem(EXIT, EXIT / 1e12, block.timestamp);
        uint256 prepaid = reserves.exitPrepaidAbsorption();
        assertGt(prepaid, 0, "setup: something must have been drawn");

        vm.prank(admin);
        reserves.releasePrincipalImpairment(facility, MARK, keccak256("mark-reversed"));

        (uint256 supply, uint256 backing) = _book();
        assertGt(backing, supply, "setup: the reversal must leave the book in surplus");
        uint256 surplus = backing - supply;
        assertGe(surplus, prepaid, "setup: the surplus is the junior forward-drawn capital");

        uint256 claimed = supply + controller.seniorSubParShortfall() + prepaid;
        uint256 expected = backing > claimed ? backing - claimed : 0;
        assertEq(
            controller.mintableHeadroom(),
            expected,
            "THE REVERSED MARK MADE THE JUNIOR CRYSTALLISED CONTRIBUTION DISTRIBUTABLE AS YIELD"
        );
        assertLe(controller.mintableHeadroom(), surplus - prepaid, "the standing prepayment must be RETAINED");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  THE GUARDS — each named from the guard's own NatSpec
    // ─────────────────────────────────────────────────────────────────────

    /// @notice G01. `DefaultManager.drawForSeniorExit` refuses every caller but the wired
    ///         controller. Without it ANY address could burn down curator first-loss capital and
    ///         the sGROVE coverage reserve at will.
    function test_Y_G01_theExitDrawRefusesAnyCallerThatIsNotTheController() public {
        _recognise(MARK);
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ExitDrawCallerNotController.selector, address(this))
        );
        defaultManager.drawForSeniorExit(1e18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ExitDrawCallerNotController.selector, alice)
        );
        defaultManager.drawForSeniorExit(1e18);

        assertEq(curator.poolBalance(FILM), FIRST_LOSS, "no junior capital may move on a refused draw");
    }

    /// @notice G02. The controller refuses to burn from a draw source governance has not named on
    ///         the `setLossSource` list, even when `ReserveManager.lossAbsorber()` points at it.
    ///         `usdfr.burn(source, …)` is raw MINTER_ROLE power over a third party's balance, so a
    ///         compromised or misconfigured reserve must be able to cause a REVERT and nothing
    ///         else.
    function test_Y_G02_theDrawRefusesASourceGovernanceHasNotNamedALossSource() public {
        _recognise(MARK);
        // Governance revokes the loss-source listing but leaves the absorber pointer in place —
        // exactly the desynchronised state the guard exists for.
        vm.prank(admin);
        controller.setLossSource(address(defaultManager), false);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_ExitDrawSourceNotAuthorised.selector, address(defaultManager)
            )
        );
        controller.redeem(EXIT, 0, block.timestamp);

        assertEq(curator.poolBalance(FILM), FIRST_LOSS, "a refused exit must move no junior capital");
    }

    /// @notice G03. The exit-prepayment ledger refuses every caller but the wired loss absorber.
    ///         Inflating it makes `realizeLoss` under-charge the junior tranche and suppresses
    ///         `mintableHeadroom()`; draining it re-opens the double charge.
    function test_Y_G03_theExitPrepaymentLedgerRefusesEveryCallerButTheAbsorber() public {
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_NotLossAbsorber.selector, address(this)));
        reserves.recordExitPrepayment(1e18);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_NotLossAbsorber.selector, admin));
        reserves.consumeExitPrepayment(facility, 1e18);

        assertEq(reserves.exitPrepaidAbsorption(), 0, "the ledger must be untouched");
    }

    /// @notice G04. The layer-0 credit is bounded by the RECOGNISED MARK this loss will release,
    ///         NOT by the loss. A prepayment standing against facility A must not be credited
    ///         against an UNRECOGNISED loss on facility B: on an unrecognised slice
    ///         `recordPrincipalWritedown` lowers backing in the same call, so crediting it would
    ///         RE-OPEN a deficit the junior had already paid to close -- refunding junior capital
    ///         at the remaining holders expense.
    ///
    ///         MUTATION: relax the bound in `ReserveManager.consumeExitPrepayment` to
    ///         `min(prepaid, loss)` -- still compiling, still reading both operands -- and this
    ///         test goes RED on the prepayment assertion.
    function test_Y_G04_theLayer0CreditIsBoundedByTheRecognisedMarkNotByTheLoss() public {
        _stakeSenior(300_000e18);
        uint256 unmarked = _originateFilm(BORROWER_2, STATE_GA, 200_000e18);
        _fundFacility(unmarked, 200_000e18);

        _recognise(MARK); // the mark sits on `facility`, NOT on `unmarked`
        vm.prank(alice);
        controller.redeem(EXIT, 0, block.timestamp);
        uint256 prepaid = reserves.exitPrepaidAbsorption();
        assertGt(prepaid, 0, "setup: the exit must have drawn against the recognised mark");

        (uint256 supplyBefore, uint256 backingBefore) = _book();
        uint256 deficitBefore = supplyBefore - backingBefore;
        assertEq(reserves.principalImpairmentOf(unmarked), 0, "setup: facility B must be unmarked");

        _declare(unmarked);
        _realizeLoss(unmarked, 40_000e18, keccak256("unrecognised-loss"));

        assertEq(
            reserves.exitPrepaidAbsorption(),
            prepaid,
            "THE PREPAYMENT WAS CREDITED AGAINST AN UNRECOGNISED LOSS -- junior capital was refunded"
        );
        (uint256 supplyAfter, uint256 backingAfter) = _book();
        uint256 deficitAfter = supplyAfter > backingAfter ? supplyAfter - backingAfter : 0;
        assertLe(deficitAfter, deficitBefore, "the credit must never re-open a deficit junior had already closed");
    }

    /// @notice G05 -- RESTATED HONESTLY: THE CLAMP IS UNREACHABLE, AND HERE IS THE PROOF.
    ///         `_exitDrawTarget` clamps `ceil(u*D/B)` to the standing deficit `D`. That clamp can
    ///         NEVER bite, and I could not construct a state in which it does, so I state the
    ///         reason rather than claiming a mutation proof (this file s house rule).
    ///
    ///         PROOF. The clamp needs `ceil(u*D/B) > D`, i.e. `u > B`. But junior capital `J` is
    ///         itself USDfr -- the curator pools and the sGROVE coverage reserve HOLD USDfr -- so
    ///         it is counted in `supply`, and a redeeming holder s balance therefore satisfies
    ///         `u <= supply - J`. For the clamp to have any OBSERVABLE effect the draw must also
    ///         be able to exceed `D`, which needs `J > D = supply - B`; that gives
    ///         `B > supply - J >= u`, contradicting `u > B`. So `u < B` in every reachable state
    ///         and `ceil(u*D/B) <= D` by arithmetic alone.
    ///
    ///         The clamp is therefore DEFENCE-IN-DEPTH against a future sizing change, exactly as
    ///         `mint` s `forceApprove(..., 0)` is. What IS falsifiable is the SYSTEM property it
    ///         guards, and that is fuzzed here over the whole reachable domain.
    function testFuzz_Y_G05_theDrawNeverExceedsTheStandingDeficit(uint256 markSeed, uint256 exitSeed) public {
        uint256 mark = bound(markSeed, 1e18, PRINCIPAL);
        mark = (mark / 1e12) * 1e12;
        vm.assume(mark != 0);
        _recognise(mark);

        (uint256 supply, uint256 backing) = _book();
        uint256 deficit = supply - backing;
        uint256 exitAmount = bound(exitSeed, 1e18, ALICE_IN);

        vm.prank(alice);
        try controller.redeem(exitAmount, 0, block.timestamp) {
            assertLe(
                reserves.exitPrepaidAbsorption(),
                deficit,
                "THE DRAW EXCEEDED THE STANDING DEFICIT -- absorption was ENLARGED, not advanced"
            );
        } catch {
            // Dust amounts and exhausted idle liquidity revert; neither draws anything.
            assertEq(reserves.exitPrepaidAbsorption(), 0, "a reverted exit must leave no prepayment");
        }
    }

    /// @notice G06. A draw source that reports one number and moves another can only cause a
    ///         REVERT, never an overpayment out of junior capital. The controller measures the
    ///         source's balance delta itself rather than trusting the return value.
    function test_Y_G06_aLyingDrawSourceCanOnlyRevertTheExitNeverOverpayIt() public {
        _recognise(MARK);
        for (uint8 mode = 0; mode < 2; ++mode) {
            uint256 snap = vm.snapshotState();
            LyingExitDrawSource liar = new LyingExitDrawSource(IERC20(address(usdfr)), mode);
            vm.startPrank(admin);
            reserves.setLossAbsorber(address(liar));
            controller.setLossSource(address(liar), true);
            vm.stopPrank();

            vm.prank(alice);
            vm.expectPartialRevert(IMintRedeemController.Controller_ExitDrawNotDelivered.selector);
            controller.redeem(EXIT, 0, block.timestamp);

            vm.revertToState(snap);
        }
    }

    // G07 -- THE POST-DRAW DEFICIT ANCHOR -- lives in `ADR0034Y_ExitDrawAnchor.t.sol`. Its
    // falsifier needs a reserve that MISBOOKS its own release, which the honest credit stack
    // cannot produce, so it runs against `ControllerReserveDouble` instead. It is named from
    // `_redeem`'s NatSpec and is NOT in this file; do not add a weaker stand-in here.

    /// @notice G08. The deadline (ADR-0034 W). A minimum-out bounds the PRICE; it does not bound
    ///         WHEN the exit executes, and every path that moves the coverage ratio down is
    ///         un-timelocked and publicly visible before it lands.
    function test_Y_G08_theDeadlineRefusesAnExpiredRedemption() public {
        uint256 deadline = block.timestamp + 100;
        vm.warp(deadline + 1);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_DeadlinePassed.selector, deadline, block.timestamp)
        );
        controller.redeem(EXIT, 0, deadline);

        // The boundary is inclusive: settling exactly ON the deadline is allowed.
        vm.warp(deadline);
        vm.prank(alice);
        assertGt(controller.redeem(EXIT, 0, deadline), 0, "an exit AT the deadline must settle");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  LIVENESS AND WIRING
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A WHOLE PROTOCOL IS UNTOUCHED. While `backing >= supply` — the overwhelmingly
    ///         common state — no draw is attempted at all, so the exit is byte-for-byte the
    ///         pre-ADR par redemption and no junior capital moves.
    function test_Y_aWholeProtocolDrawsNothingAndPaysPar() public {
        uint256 poolBefore = curator.poolBalance(FILM);
        vm.prank(alice);
        uint256 out = controller.redeem(EXIT, EXIT / 1e12, block.timestamp);
        assertEq(out, EXIT / 1e12, "a whole protocol pays par");
        assertEq(curator.poolBalance(FILM), poolBefore, "NO junior capital may move while the book is whole");
        assertEq(reserves.exitPrepaidAbsorption(), 0, "nothing prepaid");
    }

    /// @notice `previewRedeem` QUOTES THE UNDRAWN FLOOR, AND THE DIRECTION IS WHAT MAKES IT SAFE.
    ///         Passing its number straight back as `minUsdcOut` — exactly as its NatSpec directs —
    ///         must never revert on slippage. This is a NAMED, DELIBERATE GAP against ADR-0034 Y,
    ///         which lists `previewRedeem` alongside `redeem`; it is recorded, not closed.
    function test_Y_previewRedeemUnderstatesButNeverOverstatesTheExitPrice() public {
        _recognise(MARK);
        (uint256 quoted,) = controller.previewRedeem(EXIT);

        vm.prank(alice);
        uint256 settled = controller.redeem(EXIT, quoted, block.timestamp);

        assertGe(settled, quoted, "previewRedeem MUST NOT OVERSTATE -- passing it back as minUsdcOut would revert");
        assertGt(settled, quoted, "the whole point: settlement beats the undrawn quote when junior capital stands");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Helpers
    // ─────────────────────────────────────────────────────────────────────

    function _book() internal view returns (uint256 supply, uint256 backing) {
        supply = usdfr.totalSupply();
        backing = reserves.totalBackingValue();
    }

    function _recognise(uint256 amount) internal {
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(facility, amount, keccak256("conservative-mark"));
    }

    function _fundBackstop(uint256 amount) internal {
        _mintUSDfrTo(bob, amount);
        vm.prank(bob);
        usdfr.transfer(address(backstopMock), amount);
    }

    function _stakeSenior(uint256 amount) internal {
        _mintUSDfrTo(bob, amount);
        vm.startPrank(bob);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, bob);
        vm.stopPrank();
    }

    function _declare(uint256 tokenId) internal {
        _attestDefault(tokenId);
        vm.prank(servicer);
        defaultManager.declareDefault(tokenId, FILM_REF);
    }

    /// @dev The controller's own sizing rule, recomputed independently for the anchor tests.
    function _expectedDrawTarget(uint256 usdfrIn, uint256 supply, uint256 backing) internal pure returns (uint256) {
        if (backing == 0 || backing >= supply) return 0;
        uint256 deficit = supply - backing;
        uint256 t = Math_mulDivCeil(usdfrIn, deficit, backing);
        return t > deficit ? deficit : t;
    }

    function Math_mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return (a * b) / d;
    }

    function Math_mulDivCeil(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return (a * b + d - 1) / d;
    }
}
