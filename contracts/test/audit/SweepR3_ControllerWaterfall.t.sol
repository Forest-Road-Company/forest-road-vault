// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {IPointsModule} from "../../src/interfaces/IPointsModule.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

/// @dev SWEEP-3. The observer for finding S3-F1. It is deliberately NARROWER than
///      `HostilePointsModule`: it reads the ONE composite view R18's `_requireSettledState`
///      enumeration missed, plus `backingInvariantHolds()` as the discriminating control, and
///      records the ANSWER rather than propagating it (the token's `catch` would erase it).
contract SettledStateProbeModule is IPointsModule {
    IMintRedeemController public immutable controller;

    bool public ran;
    bool public creditServicingAnswered;
    bool public creditServicingSaid;
    bool public invariantAnswered;
    bool public invariantSaid;

    constructor(IMintRedeemController controller_) {
        controller = controller_;
    }

    function onUSDfrTransfer(address, address, uint256) external override {
        ran = true;
        try controller.creditServicingBackingHolds() returns (bool ok) {
            creditServicingAnswered = true;
            creditServicingSaid = ok;
        } catch {}
        try controller.backingInvariantHolds() returns (bool ok) {
            invariantAnswered = true;
            invariantSaid = ok;
        } catch {}
    }

    function onSharesTransfer(address, address, uint256) external override {}
    function onCuratorStakeChange(address, uint256, uint256) external override {}
    function onCuratorLoss(uint256, uint256, uint256) external override {}
}

/// @title SWEEP ROUND 3 — MintRedeemController + WaterfallEngine
/// @notice Probes only. This file changes no production source.
contract SweepR3_ControllerTokenLayer is TokenLayerFixture {
    // ─────────────────────────────────────────────────────────────────────
    //  S3-F1 — the R18 read-only-reentrancy enumeration is one view short
    // ─────────────────────────────────────────────────────────────────────

    /// @notice S3-F1. `_requireSettledState`'s own NatSpec states the rule it implements:
    ///         "THE RAW DELEGATING VIEWS (`backingValue`, `recognizedBackingValue`, `totalUSDfr`)
    ///         ARE DELIBERATELY NOT GATED. Each is a single live read of one module ... What is
    ///         false mid-transition is the COMPOSITION of a supply reading with a backing reading
    ///         taken at different points of the same state change, so it is exactly the composites
    ///         that are gated."
    ///
    ///         `creditServicingBackingHolds()` IS such a composite — `totalUSDfr() <=
    ///         backingValue()` — and it is NOT gated. R18's own falsifier
    ///         (`Fix_R18 ... ::test_R18_E_theCompositeViewsRefuseFromInsideTheBurnWindow`)
    ///         enumerates five views by hand and this is the sixth, so the enumeration is
    ///         decorative on this surface.
    ///
    ///         MEASURED HERE: inside `_redeem`'s burn window the view answers TRUE — "supply is
    ///         within backing" — on a book that is SHORT both before and after the transaction,
    ///         while `backingInvariantHolds()`, the identical composition one basis over,
    ///         correctly REFUSES from the same frame.
    function test_S3_F1_creditServicingBackingHoldsAnswersFromInsideTheBurnWindow() public {
        // A genuinely sub-par book: 1,000e18 supply against 900e18 backing.
        _mintUSDfr(alice, 1_000e6);
        vm.prank(creditModule);
        reserves.recordDeployment(1, borrower, 400e6);
        vm.prank(creditModule);
        reserves.recordPrincipalWritedown(1, 100e18);

        assertEq(controller.totalUSDfr(), 1_000e18, "setup supply");
        assertEq(controller.backingValue(), 900e18, "setup backing");
        assertFalse(controller.creditServicingBackingHolds(), "SETUP: the book must start SHORT");

        SettledStateProbeModule probe = new SettledStateProbeModule(IMintRedeemController(address(controller)));
        vm.prank(admin);
        usdfr.setPointsModule(address(probe));

        vm.prank(alice);
        uint256 out = controller.redeem(400e18, 0);
        emit log_named_uint("settled USDC out", out);

        assertTrue(probe.ran(), "THE HOOK NEVER RAN - THIS TEST WOULD ASSERT NOTHING");

        // The control. The identical composition on the recognition-aware basis refuses.
        assertFalse(probe.invariantAnswered(), "CONTROL BROKEN: backingInvariantHolds() must refuse mid-burn");

        emit log_named_uint("creditServicing answered (1=yes)", probe.creditServicingAnswered() ? 1 : 0);
        emit log_named_uint("creditServicing said (1=TRUE)", probe.creditServicingSaid() ? 1 : 0);
        emit log_named_uint("settled supply", controller.totalUSDfr());
        emit log_named_uint("settled backing", controller.backingValue());
        assertFalse(
            controller.creditServicingBackingHolds(), "the SETTLED book is still short - so the mid-burn TRUE is a lie"
        );

        assertFalse(
            probe.creditServicingAnswered(),
            "S3-F1: creditServicingBackingHolds() ANSWERED FROM INSIDE THE BURN WINDOW -- it is a composite and is not gated"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    //  S3-F3 — previewRedeem quotes a settleable price for a paused redeem
    // ─────────────────────────────────────────────────────────────────────

    /// @notice S3-F3. R18's stated standard for `previewRedeem` is that a quote must not be
    ///         published for a call that cannot execute: "It now answers `(0, 0)`, which is
    ///         already this view's documented way of saying 'nothing is payable', and THE TWO
    ///         SURFACES AGREE IN EVERY STATE." They do not agree under a pause. `mintableHeadroom()`
    ///         reads BOTH pauses and answers 0; `previewRedeem` reads neither and publishes a full
    ///         par quote for a `redeem` that reverts `EnforcedPause`.
    function test_S3_F3_previewRedeemQuotesAFullPriceWhileRedemptionIsPaused() public {
        _mintUSDfr(alice, 1_000e6);

        (uint256 openQuote,) = controller.previewRedeem(400e18);
        assertEq(openQuote, 400e6, "setup: the open book quotes par");

        vm.prank(guardian);
        controller.pause();

        assertEq(controller.mintableHeadroom(), 0, "control: the headroom view DOES read the pause");

        (uint256 pausedQuote, uint256 pausedIn) = controller.previewRedeem(400e18);
        emit log_named_uint("previewRedeem usdcOut while paused", pausedQuote);
        emit log_named_uint("previewRedeem usdfrIn while paused", pausedIn);

        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        controller.redeem(400e18, pausedQuote);

        assertEq(
            pausedQuote, 0, "S3-F3: previewRedeem published a settleable quote for a redemption that cannot execute"
        );
    }

    /// @notice S3-F3, second surface. The same disagreement through the USDfr token pause, which
    ///         `mintableHeadroom()` was specifically taught to read in R18 for this exact reason.
    function test_S3_F3b_previewRedeemQuotesAFullPriceWhileTheTokenPauseClosesTheBurn() public {
        _mintUSDfr(alice, 1_000e6);

        vm.prank(guardian);
        usdfr.pause();

        assertEq(controller.mintableHeadroom(), 0, "control: the headroom view DOES read the token pause");

        (uint256 pausedQuote,) = controller.previewRedeem(400e18);
        emit log_named_uint("previewRedeem usdcOut while USDfr paused", pausedQuote);

        vm.prank(alice);
        vm.expectRevert();
        controller.redeem(400e18, pausedQuote);

        assertEq(pausedQuote, 0, "S3-F3b: previewRedeem published a settleable quote under a token pause");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  CLEAN NEGATIVES (recorded as results, not as decoration)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice S3-F2, THE DISCRIMINATING CONTROL, on a stack with NO junior draw source wired
    ///         (`exitPrepaidAbsorption() == 0` throughout), so the refusal below is attributable to
    ///         the SIBLING retention term and to nothing else.
    ///
    ///         The SIBLING term IS enforced: `mintYield` refuses one wei past the headroom with
    ///         `Controller_SeniorRetentionBreached`. That is what makes S3-F2 an ENFORCEMENT
    ///         ASYMMETRY between the two terms of one published formula, rather than a general
    ///         property of `mintYield`.
    function test_S3_F2_control_theSubParRetentionIsEnforcedOnTheSameCall() public {
        _mintUSDfr(alice, 1_000e6);
        vm.prank(creditModule);
        reserves.recordDeployment(1, borrower, 400e6);
        vm.prank(creditModule);
        reserves.recordPrincipalWritedown(1, 100e18);

        vm.prank(alice);
        controller.redeem(400e18, 0);

        uint256 crystallised = controller.seniorSubParShortfall();
        assertGt(crystallised, 0, "setup: the sub-par exit must crystallise a haircut");
        assertEq(reserves.exitPrepaidAbsorption(), 0, "setup: NO junior draw happened on this stack");

        // Attested cash landing as backing with no matching supply, until a surplus stands.
        uint256 supply = controller.totalUSDfr();
        uint256 backing = controller.recognizedBackingValue();
        uint256 topUp = (supply - backing + crystallised) / 1e12 + 10;
        usdc.mint(bob, topUp);
        vm.startPrank(bob);
        usdc.approve(address(reserves), topUp);
        reserves.recapitalize(topUp);
        vm.stopPrank();

        uint256 surplus = controller.recognizedBackingValue() - controller.totalUSDfr();
        emit log_named_uint("crystallised senior haircut", crystallised);
        emit log_named_uint("surplus", surplus);
        emit log_named_uint("mintableHeadroom()", controller.mintableHeadroom());
        assertEq(controller.mintableHeadroom(), surplus - crystallised, "the view and the level agree here");

        // One wei past the headroom: post-mint surplus would be `crystallised - 1`.
        uint256 amount = surplus - crystallised + 1;
        vm.prank(creditModule);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_SeniorRetentionBreached.selector, crystallised, crystallised - 1
            )
        );
        controller.mintYield(address(vault), amount);

        // and exactly the headroom is accepted
        vm.prank(creditModule);
        controller.mintYield(address(vault), amount - 1);
    }

    /// @notice CLEAN NEGATIVE. I tried to make `mint`'s R18 recognition delta and the
    ///         `Controller_MintClosedWhileUnderBacked` level check disagree by carrying a standing
    ///         surplus. They do not: the mint window is closed on the RECORDED basis and the
    ///         recognition equality is a delta no surplus can pay for.
    function test_S3_N1_mintStaysClosedUnderBackedEvenWithAStandingSurplus() public {
        _mintUSDfr(alice, 1_000e6);
        vm.prank(creditModule);
        reserves.recordDeployment(1, borrower, 400e6);
        vm.prank(creditModule);
        reserves.recordPrincipalWritedown(1, 1);

        vm.startPrank(bob);
        usdc.mint(bob, 100e6);
        usdc.approve(address(controller), 100e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_MintClosedWhileUnderBacked.selector, 1_000e18, 1_000e18 - 1
            )
        );
        controller.mint(100e6);
        vm.stopPrank();
    }
}

/// @title SWEEP ROUND 3 — the ADR-0034 Y-bis retention, on the credit layer
contract SweepR3_ControllerCreditLayer is CreditLayerFixture {
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
        _postFirstLoss(anchorCurator, FILM, FIRST_LOSS);
        facility = _originateFilm(BORROWER_1, STATE_GA, PRINCIPAL);
        _fundFacility(facility, PRINCIPAL);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  S3-F2 — the Y-bis retention is ADVERTISED but NOT ENFORCED
    // ─────────────────────────────────────────────────────────────────────

    /// @notice S3-F2. `mintYield`'s own NatSpec states the rule the retention rests on:
    ///         "The retention that `mintableHeadroom()` advertises has to be ENFORCED here as well
    ///         as advertised, or it is advisory only: a caller that does not size itself off the
    ///         headroom would otherwise spend it."
    ///
    ///         R17 implemented that for `seniorSubParShortfall()`
    ///         (`Controller_SeniorRetentionBreached`). ADR-0034 Y-bis then added a SECOND retention
    ///         term to the same view — `ReserveManager.exitPrepaidAbsorption()` — and did NOT add
    ///         it to the enforcement. Two enumerations of the same quantity that do not agree.
    ///
    ///         MEASURED: after a par exit funded entirely by a junior draw and a full release of
    ///         the conservative mark, `mintableHeadroom()` reads 0 and `seniorSubParShortfall()`
    ///         reads 0, while the book carries a surplus of exactly the junior capital that was
    ///         crystallised — and `mintYield` mints ALL of it to the `sUSDfr` vault without
    ///         reverting. That is precisely the leak the term was added to close ("the curator's
    ///         crystallised loss becomes the senior's income"), reached through the enforcement
    ///         gap rather than through the view.
    function test_S3_F2_theExitPrepaymentRetentionIsAdvertisedButNotEnforcedByMintYield() public {
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(facility, MARK, keccak256("conservative-mark"));

        uint256 poolBefore = curator.poolBalance(FILM);
        vm.prank(alice);
        uint256 out = controller.redeem(EXIT, EXIT / 1e12, block.timestamp);
        assertEq(out, EXIT / 1e12, "setup: the exit must settle at PAR out of junior capital");

        uint256 drawn = poolBefore - curator.poolBalance(FILM);
        assertGt(drawn, 0, "setup: layer 1 must actually have paid");
        assertEq(reserves.exitPrepaidAbsorption(), drawn, "setup: the prepayment ledger records the draw");
        assertEq(controller.seniorSubParShortfall(), 0, "setup: a PAR exit crystallises no senior haircut");

        // The conservative mark is REVERSIBLE and is now released in full. Backing returns; supply
        // is already permanently lower by `drawn`.
        vm.prank(admin);
        reserves.releasePrincipalImpairment(facility, MARK, keccak256("released"));

        uint256 supply = controller.totalUSDfr();
        uint256 backing = controller.recognizedBackingValue();
        uint256 surplus = backing - supply;
        emit log_named_uint("drawn (junior capital crystallised)", drawn);
        emit log_named_uint("surplus after the release", surplus);
        emit log_named_uint("mintableHeadroom()", controller.mintableHeadroom());
        emit log_named_uint("seniorSubParShortfall()", controller.seniorSubParShortfall());
        emit log_named_uint("exitPrepaidAbsorption()", reserves.exitPrepaidAbsorption());

        assertEq(surplus, drawn, "the surplus IS the crystallised junior capital");
        assertEq(controller.mintableHeadroom(), 0, "the VIEW correctly says nothing may be minted");

        // A CREDIT_ROLE caller that does not clamp itself off the view. Both shipped callers DO
        // clamp, which is why this is defence-in-depth and not a live theft — but the enforcement
        // that exists for the sibling retention term is simply absent for this one.
        assertTrue(
            controller.hasRole(Roles.CREDIT_ROLE, address(waterfall)), "precondition: the engine holds CREDIT_ROLE"
        );
        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        vm.prank(address(waterfall));
        (bool accepted,) = address(controller).call(
            abi.encodeWithSelector(IMintRedeemController.mintYield.selector, address(vault), surplus)
        );

        emit log_named_uint("mintYield accepted (1 = yes)", accepted ? 1 : 0);
        emit log_named_uint("USDfr minted to the senior vault", usdfr.balanceOf(address(vault)) - vaultBefore);
        assertFalse(
            accepted,
            "S3-F2: mintYield spent the ADR-0034 Y-bis retention -- the enforcement omits exitPrepaidAbsorption()"
        );
        assertEq(usdfr.balanceOf(address(vault)) - vaultBefore, 0, "S3-F2: junior capital became senior yield");
    }
}
