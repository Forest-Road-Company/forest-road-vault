// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {MintRedeemController} from "../../src/MintRedeemController.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {ControllerReserveDouble} from "../helpers/ControllerReserveDouble.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {ReentrantUSDfrDouble} from "../helpers/ReentrantUSDfrDouble.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

/// @title AUDIT ROUND R17 — MintRedeemController: exit price, recognition basis, and the guards
///        R16 shipped but could not falsify
///
/// @notice R16 did two things to this contract and finished neither. It made the exit price a live
///         function of state, and it introduced a second solvency basis. The adversarial round that
///         followed found the consequences, and they group into four root causes:
///
///  ROOT CAUSE A — THE WRONG BASIS ON THE TWO SURFACES THAT MATTER MOST. `mintableHeadroom()` sizes
///  every yield mint `WaterfallEngine._routeInterest` makes, and `previewRedeem` is the number the
///  frontend shows a holder. Both read the RECORDED ledger, which an unreconciled custody shortfall
///  has already falsified — the exact state R4-01 built machinery to recognise. Consequence one:
///  under a custody hole the whole interest leg was minted out as yield, the protocol fee was taken
///  on the GROSS out of an open hole, and the hole was not repaired by a wei, while every user was
///  frozen out of `mint` and `redeem`. Consequence two: `previewRedeem` published a PAR quote over
///  a hole it could see, for a call that would revert. Both now read `recognizedBackingValue()`.
///  `mintYield` — the one supply-EXPANDING path with no custody precondition — additionally
///  asserts the non-worsening rule on that basis.
///
///  ROOT CAUSE B — A VARIABLE PRICE WITH NO FLOOR. `redeem(uint256)` was designed around a constant
///  1:1 price. R16 made the price move and did not change the signature, so a holder signed for
///  "redeem 100" and received whatever the ratio happened to be at inclusion — with several
///  NON-timelocked paths able to move it down in the same block. There is now
///  `redeem(uint256,uint256)`, and the one-argument form carries the PAR floor.
///
///  ROOT CAUSE C — A REVERSIBLE MARK MADE PERMANENT FOR ONE SIDE ONLY. Sub-par exits are priced off
///  `recognizePrincipalImpairment`, which `releasePrincipalImpairment` exists to reverse. The
///  exiter's loss is not reversible, and on release the recovered value became `mintableHeadroom()`
///  and was minted to the `sUSDfr` vault as yield. `seniorSubParShortfall()` now records the
///  crystallised haircut and the headroom nets it out.
///
///  ROOT CAUSE D — GUARDS THAT NO TEST COULD RED. R16's own rule is that "a guard no test can red
///  is not protection; it is a comment that an auditor will read as protection", and it deleted
///  three guards on that basis — while shipping several it could not falsify, and declining to
///  write one on the false premise that it was untestable. This file supplies the falsifying case
///  for every survivor, and deletes the one that was genuinely redundant.
///
/// @dev EVERY GUARD ADDED OR RETAINED IN R17 HAS A NAMED DELETION MUTATION HERE. Where the shipped
///      `ReserveManager` cannot produce the state, the falsifying case comes from
///      `ControllerReserveDouble` (five new modes) or `ReentrantUSDfrDouble`.
contract Fix_R17_ControllerTokenLayer is TokenLayerFixture {
    address internal sink = makeAddr("r17-sink");

    /// @dev A custody loss: USDC leaves the reserve with NO ledger entry behind it. Deliberately
    ///      not a protocol path — the point is an out-of-band gap the ledger does not know about
    ///      but the balance does. Same mechanism `Fix_R4-01-par-exit-on-short-reserve.t.sol` uses.
    function _drainCustody(uint256 units) internal {
        vm.prank(address(reserves));
        usdc.transfer(sink, units);
    }

    /// @dev Drives the protocol to a known coverage ratio with the production G3 input: a
    ///      governance conservative mark on deployed principal. Custody stays intact.
    function _makeUnderBacked(uint256 usdcIn, uint256 markValue) internal {
        _mintUSDfr(alice, usdcIn);
        vm.startPrank(creditModule);
        reserves.recordDeployment(1, borrower, usdcIn / 2);
        reserves.recordPrincipalWritedown(1, markValue);
        vm.stopPrank();
    }

    /// @dev A controller wired to a misbehaving reserve double. Mirrors the R16 helper.
    function _doubleWiredController(ControllerReserveDouble double) internal returns (MintRedeemController c) {
        c = MintRedeemController(
            address(
                new ERC1967Proxy(
                    address(new MintRedeemController()),
                    abi.encodeCall(
                        MintRedeemController.initialize,
                        (admin, guardian, admin, address(usdfr), address(compliance), address(double))
                    )
                )
            )
        );
        vm.prank(admin);
        usdfr.grantRole(Roles.MINTER_ROLE, address(c));
    }

    // =====================================================================
    //  B — the exit price is now refusable
    // =====================================================================

    /// @notice R17 CORE (findings "redeem has no minimum-out", "R16 made the exit price
    ///         state-dependent and added no slippage floor"). Before R16 the exit was the constant
    ///         1:1, so `redeem(uint256)` needed no floor and has none. R16 made the payout a live
    ///         function of `backing/supply`, published `previewRedeem` to quote it, and left the
    ///         signature alone — so the quote was advisory and the burn irreversible. The
    ///         one-argument form now supplies the par floor.
    function test_R17_B06_theOneArgumentRedeemSettlesAtParOrReverts() public {
        _makeUnderBacked(100e6, 10e18); // 90 backing against 100 supply => 90 cents
        (uint256 quoted,) = controller.previewRedeem(10e18);
        assertEq(quoted, 9e6, "the scenario must really be sub-par");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_SlippageExceeded.selector, 9e6, 10e6));
        controller.redeem(10e18);
        assertEq(usdfr.balanceOf(alice), 100e18, "THE BURN HAPPENED ANYWAY");

        // and the informed holder can still exit, by naming the price they accept
        vm.prank(alice);
        assertEq(controller.redeem(10e18, quoted), 9e6, "an explicit sub-par exit was refused");
        assertEq(usdfr.balanceOf(alice), 90e18);
    }

    /// @notice R17 (the same finding, from the direction that actually loses money). The price is
    ///         moved DOWN between the quote and the settlement by an ordinary, NON-timelocked
    ///         protocol call — `recordPrincipalWritedown` needs only `CREDIT_ROLE`, held by a
    ///         keeper-driven module. Without a floor the holder simply takes it; the burn is
    ///         already executed and cannot be retried at the old price.
    function test_R17_B06_aPriceThatMovesBetweenQuoteAndSettlementIsRefused() public {
        _makeUnderBacked(1000e6, 100e18); // 900 backing / 1000 supply => 90 cents
        (uint256 quoted,) = controller.previewRedeem(100e18);
        assertEq(quoted, 90e6);

        // an ordinary mark-down orders ahead of the redemption
        vm.prank(creditModule);
        reserves.recordPrincipalWritedown(1, 400e18);
        (uint256 nowQuoted,) = controller.previewRedeem(100e18);
        assertEq(nowQuoted, 50e6, "the setup must actually move the price");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_SlippageExceeded.selector, 50e6, 90e6));
        controller.redeem(100e18, quoted);
        assertEq(usdfr.balanceOf(alice), 1000e18, "the holder was burned at a price they refused");
    }

    /// @notice R17. A zero floor is a deliberate, documented opt-out and must keep working — a
    ///         guard that cannot be waived by an informed caller would be a freeze by another name
    ///         (finding M3). This is the negative control for the two tests above.
    function test_R17_B06_aZeroFloorAcceptsAnyPriceDeliberately() public {
        _makeUnderBacked(100e6, 50e18); // 50 cents
        vm.prank(alice);
        assertEq(controller.redeem(10e18, 0), 5e6, "an explicit zero floor must still settle");
    }

    // =====================================================================
    //  C — the crystallised haircut is no longer recycled as yield
    // =====================================================================

    /// @notice R17 CORE, THE HIGH. `recognizePrincipalImpairment` is a REVERSIBLE governance
    ///         valuation act — `releasePrincipalImpairment` exists precisely so governance is
    ///         willing to mark conservatively. R16 made that reversible number price-effective for
    ///         exits the instant it landed. A holder who exited crystallised a PERMANENT loss
    ///         against a TEMPORARY mark; when the mark was released, the recovered value reappeared
    ///         as `mintableHeadroom()` — the exact quantity `WaterfallEngine._routeInterest` uses to
    ///         size yield to the `sUSDfr` vault — and the senior's haircut became the yield layer's
    ///         income, ahead of the §1.3 cascade's first two layers.
    function test_R17_A1_aReleasedMarkDoesNotBecomeDistributableYield() public {
        _mintUSDfr(alice, 500e6);
        _mintUSDfr(bob, 500e6);
        vm.startPrank(creditModule);
        reserves.recordDeployment(1, borrower, 600e6);
        vm.stopPrank();
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(1, 200e18, keccak256("R17-conservative-mark"));

        assertEq(controller.totalUSDfr(), 1000e18);
        assertEq(controller.backingValue(), 800e18);
        assertEq(controller.backingDeficit(), 200e18, "an unallocated MARK, not a realised loss");
        assertEq(controller.seniorSubParShortfall(), 0);

        // alice exits at the marked ratio, explicitly
        (uint256 quoted,) = controller.previewRedeem(200e18);
        assertEq(quoted, 160e6, "a 20% haircut");
        vm.prank(alice);
        controller.redeem(200e18, quoted);
        // 200e18 of claim burned, 160e18 of value paid: 40e18 crystallised out of the senior layer
        assertEq(controller.seniorSubParShortfall(), 40e18, "THE HAIRCUT WAS NOT RECORDED");

        // governance releases the mark in full — the recovery the mark was conservative about
        vm.prank(admin);
        reserves.releasePrincipalImpairment(1, 200e18, keccak256("R17-recovery"));

        // bob, identically placed, is made whole: that is correct and is not the finding
        (uint256 bobQuote,) = controller.previewRedeem(500e18);
        assertEq(bobQuote, 500e6, "the stayer must be made whole by the release");

        // THE FINDING: alice's 40 USDfr of value must NOT be distributable as yield.
        assertEq(controller.mintableHeadroom(), 0, "THE SENIOR HOLDER'S HAIRCUT BECAME DISTRIBUTABLE YIELD");
        // and the mint that would have paid it away is refused outright — the retention is
        // ENFORCED at the mint, not merely advertised by the view, because `WaterfallEngine.fund`'s
        // origination-fee mint is not sized off that view.
        vm.prank(creditModule);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_SeniorRetentionBreached.selector, 40e18, 0)
        );
        controller.mintYield(address(vault), 40e18);
    }

    /// @notice R17. The retention is BOUNDED and one-off, not a permanent yield suppression: once
    ///         backing exceeds supply plus the crystallised total, headroom reappears and yield
    ///         flows normally. Stating this is part of the fix — an auditor must be able to see
    ///         that the mitigation cannot brick the yield path.
    function test_R17_A1_theRetentionIsBoundedAndYieldResumesAboveIt() public {
        _makeUnderBacked(100e6, 50e18); // 50 backing / 100 supply
        vm.prank(alice);
        controller.redeem(10e18, 0); // pays 5e6; crystallises 5e18
        assertEq(controller.seniorSubParShortfall(), 5e18);
        assertEq(controller.mintableHeadroom(), 0);

        // repair the book past par, but not past par + the crystallised total
        usdc.mint(creditModule, 52e6);
        vm.startPrank(creditModule);
        usdc.approve(address(reserves), 52e6);
        reserves.depositUSDC(creditModule, 52e6);
        vm.stopPrank();
        assertEq(controller.backingDeficit(), 0, "the book must be whole again");
        assertEq(controller.mintableHeadroom(), 2e18, "headroom must be net of the crystallised haircut");

        // and past it, yield flows exactly as it always did
        usdc.mint(creditModule, 10e6);
        vm.startPrank(creditModule);
        usdc.approve(address(reserves), 10e6);
        reserves.depositUSDC(creditModule, 10e6);
        controller.mintYield(address(vault), 12e18);
        vm.stopPrank();
        assertEq(usdfr.balanceOf(address(vault)), 12e18, "yield did not resume above the retention");
    }

    // =====================================================================
    //  A — the recognition basis on the view surface
    // =====================================================================

    /// @notice R17 (findings B-03 / C1 / D5), AMENDED BY R18 (finding B-2) — READ THE AMENDMENT
    ///         BEFORE CHANGING THIS TEST. `previewRedeem` is the number the NatSpec directs
    ///         frontends to, and R16 priced it off the RECORDED ledger with no custody check — so
    ///         in the one state where the recorded ledger is known to be false it published a PAR
    ///         quote against cash the reserve does not hold, for a call that cannot execute. That
    ///         is R4-01 verbatim, reopened on a newer surface.
    ///
    ///         R17 FIXED WHICH NUMBER WAS PUBLISHED AND NOT WHETHER ONE WAS. This test used to
    ///         assert that the view quotes `7.5e6` here — the RECOGNISED value over the hole — and
    ///         that the call it quotes for reverts. Those two assertions contradict each other:
    ///         the view's own NatSpec says it exists "so the frontend can state the floor instead
    ///         of surfacing a revert", and passing the quoted number straight back in as
    ///         `minUsdcOut`, as both NatSpecs direct, REVERTED. The honest answer in a state where
    ///         redemption is CLOSED is `(0, 0)` — already this view's documented way of saying
    ///         nothing is payable — so R18 made it answer that, and this test now pins the
    ///         AGREEMENT of the two surfaces rather than their disagreement. It is strictly
    ///         stronger: it asserts the view is zero AND that the call refuses AND that the
    ///         recognised basis is still visible on the surface that publishes it.
    function test_R17_V01_previewRedeemQuotesTheRecognisedValueOverAKnownHole() public {
        _mintUSDfr(alice, 100e6);
        _drainCustody(25e6);

        assertEq(reserves.idleCustodyShortfall(), 25e18, "the reserve can see it is short");
        assertFalse(controller.backingInvariantHolds(), "and the protocol already publishes it");
        assertEq(controller.recognizedBackingValue(), 75e18, "the recognised basis is the honest one");

        (uint256 out, uint256 burned) = controller.previewRedeem(10e18);
        assertEq(out, 0, "PREVIEWREDEEM QUOTED A SETTLEABLE PRICE FOR A CALL THAT CANNOT EXECUTE (R18 B-2)");
        assertEq(burned, 0, "BOTH COMPONENTS OF THE (0,0) CONTRACT MUST HOLD");

        // the call it quotes for still, correctly, refuses: recognition comes before pricing —
        // and the view now says so instead of contradicting it.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_ReserveCustodyShortfall.selector, 25e18, 75e18)
        );
        controller.redeem(10e18, 0);

        // AND THE VIEW COMES BACK THE MOMENT THE CALL DOES. Restoring custody reopens both in the
        // same block with no governance action, so the gate is a state read and not a latch.
        vm.prank(sink);
        usdc.transfer(address(reserves), 25e6);
        assertEq(reserves.idleCustodyShortfall(), 0, "custody restored");
        (out, burned) = controller.previewRedeem(10e18);
        assertEq(out, 10e6, "the quote did not reopen with the call");
        assertEq(burned, 10e18);
        vm.prank(alice);
        assertEq(controller.redeem(10e18, out), out, "the reopened quote and the settlement diverged");
    }

    /// @notice R17. Wherever `redeem` is REACHABLE the two bases are equal by construction
    ///         (`_requireCustodiedReserve` guarantees it), so moving the view to the recognised
    ///         basis cannot make the quote disagree with the settlement. This is the property that
    ///         makes the change safe, and it is asserted rather than argued.
    function test_R17_V01_quoteAndSettlementStillAgreeWhereRedeemIsReachable() public {
        _makeUnderBacked(100e6, 10e18);
        (uint256 quoted,) = controller.previewRedeem(10e18);
        vm.prank(alice);
        assertEq(controller.redeem(10e18, quoted), quoted, "the quote and the settlement diverged");
    }

    /// @notice R17. On a freshly initialised controller `backing >= supply` is `0 >= 0`, so R16
    ///         quoted PAR for supply that does not exist. The explicit `supply == 0` guard also
    ///         carries the division safety R16 argued for in prose.
    function test_R17_V02_anEmptyProtocolQuotesNothingRatherThanPar() public view {
        assertEq(controller.totalUSDfr(), 0);
        assertEq(controller.backingValue(), 0);
        (uint256 out, uint256 burned) = controller.previewRedeem(1000e18);
        assertEq(out, 0, "AN EMPTY PROTOCOL QUOTED PAR FOR SUPPLY THAT DOES NOT EXIST");
        assertEq(burned, 0);
    }

    /// @notice R17. A protocol whose backing has fallen to zero used to answer
    ///         `Controller_AmountTooSmall` — an error meaning "your amount is too small" when the
    ///         truth is "the protocol is worth nothing". Two very different things for a frontend
    ///         to render and for an integrator to retry against.
    function test_R17_V03_zeroBackingHasItsOwnErrorRatherThanBlamingTheAmount() public {
        _mintUSDfr(alice, 100e6);
        vm.startPrank(creditModule);
        reserves.recordDeployment(1, borrower, 100e6);
        reserves.recordPrincipalWritedown(1, 100e18);
        vm.stopPrank();
        assertEq(controller.backingValue(), 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NoRedeemableBacking.selector, 100e18));
        controller.redeem(50e18, 0);
    }

    // =====================================================================
    //  A — the recognition basis on the credit mint
    // =====================================================================

    /// @notice R17 CORE (finding B-02). `mintYield` was the ONE supply-affecting path R4-01
    ///         recognition did not close. `mint` and `redeem` both shut the instant
    ///         `idleCustodyShortfall() != 0`; `mintYield` did not, and it was measured against the
    ///         recorded ledger the missing cash had falsified. So the credit layer could EXPAND
    ///         USDfr supply in the very block the controller publishes `backingInvariantHolds()
    ///         == false` and refuses every user — R4-01's "sells a new claim on a hole", reached
    ///         through the credit door.
    function test_R17_B02_mintYieldRefusesToExpandSupplyIntoARecognisedCustodyHole() public {
        _mintUSDfr(alice, 100e6);
        // genuine, custodied interest arrives: recorded headroom exists
        usdc.mint(creditModule, 20e6);
        vm.startPrank(creditModule);
        usdc.approve(address(reserves), 20e6);
        reserves.depositUSDC(creditModule, 20e6);
        vm.stopPrank();

        _drainCustody(30e6);
        assertEq(reserves.idleCustodyShortfall(), 30e18);
        assertFalse(controller.backingInvariantHolds());
        assertEq(controller.backingDeficit(), 0, "the RECORDED basis still reports the protocol whole");

        // both user paths are frozen
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_ReserveCustodyShortfall.selector, 30e18, 90e18)
        );
        controller.redeem(1e18, 0);

        // and so, now, is the credit mint
        vm.prank(creditModule);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_RecognizedDeficitWorsened.selector, 10e18, 30e18)
        );
        controller.mintYield(address(vault), 20e18);
        assertEq(usdfr.totalSupply(), 100e18, "SUPPLY EXPANDED INTO A RECOGNISED HOLE");
    }

    /// @notice R17, THE PAIRED NEGATIVE — AND IT IS LOAD-BEARING. `burnLoss` must NOT be closed
    ///         alongside `mintYield`. The C-01 cascade's own absorption runs while a custody
    ///         shortfall is standing (`ReserveManager.reconcileIdleUSDC` allocates the loss and
    ///         burns supply BEFORE it lowers the idle ledger), so a recognition-aware assertion
    ///         there would brick custody-loss absorption entirely. The asymmetry is deliberate and
    ///         this test is the pin that keeps it deliberate.
    function test_R17_B02_burnLossStaysOpenUnderARecognisedShortfall() public {
        _mintUSDfr(alice, 100e6);
        vm.prank(alice);
        usdfr.transfer(address(vault), 40e18);
        _drainCustody(30e6);
        assertFalse(controller.backingInvariantHolds());

        vm.prank(creditModule);
        controller.burnLoss(address(vault), 10e18);
        assertEq(usdfr.totalSupply(), 90e18, "ABSORPTION WAS OBSTRUCTED BY THE RECOGNITION GATE");
    }

    /// @notice R17. The recognition-aware headroom is a STRICT TIGHTENING: while custody is whole
    ///         the two bases are identical and behaviour is bit-for-bit unchanged. This is the
    ///         negative control for the whole basis change.
    function test_R17_B01_headroomIsUnchangedWhileCustodyIsWhole() public {
        _mintUSDfr(alice, 100e6);
        usdc.mint(creditModule, 20e6);
        vm.startPrank(creditModule);
        usdc.approve(address(reserves), 20e6);
        reserves.depositUSDC(creditModule, 20e6);
        vm.stopPrank();
        assertEq(reserves.idleCustodyShortfall(), 0);
        assertEq(controller.mintableHeadroom(), 20e18, "the healthy path must be untouched");
        vm.prank(creditModule);
        controller.mintYield(address(vault), 20e18);
        assertEq(controller.mintableHeadroom(), 0);
    }

    /// @notice R17 (finding B-01 / D2). The headroom must see the custody hole, because it is what
    ///         `WaterfallEngine._routeInterest` distributes against.
    function test_R17_B01_headroomIsZeroWhileACustodyHoleStands() public {
        _mintUSDfr(alice, 100e6);
        usdc.mint(creditModule, 20e6);
        vm.startPrank(creditModule);
        usdc.approve(address(reserves), 20e6);
        reserves.depositUSDC(creditModule, 20e6);
        vm.stopPrank();
        assertEq(controller.mintableHeadroom(), 20e18);

        _drainCustody(30e6);
        assertEq(controller.backingValue() - controller.totalUSDfr(), 20e18, "the RECORDED basis still says 20");
        assertEq(controller.mintableHeadroom(), 0, "THE CURE WAS BLIND TO THE HOLE IT WAS WRITTEN FOR");
    }

    /// @notice R17 (finding D3). R16 put `whenNotPaused` on `mintYield` for a sound reason — a
    ///         pause must never leave supply expansion available — and thereby made a single
    ///         un-timelocked GUARDIAN key able to revert every borrower repayment, because
    ///         `WaterfallEngine.distribute` is atomic and calls `mintYield` on any payment carrying
    ///         interest. The modifier stays; the coupling is removed by making the headroom read
    ///         zero while paused, so the engine WITHHOLDS instead of reverting.
    function test_R17_D3_aPauseWithholdsYieldRatherThanStoppingRepayment() public {
        _mintUSDfr(alice, 100e6);
        usdc.mint(creditModule, 20e6);
        vm.startPrank(creditModule);
        usdc.approve(address(reserves), 20e6);
        reserves.depositUSDC(creditModule, 20e6);
        vm.stopPrank();
        assertEq(controller.mintableHeadroom(), 20e18);

        vm.prank(guardian);
        controller.pause();
        assertEq(controller.mintableHeadroom(), 0, "A PAUSED CONTROLLER STILL ADVERTISED MINTABLE HEADROOM");

        // the absolute rule is untouched: issuance is still closed under a pause
        vm.prank(creditModule);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        controller.mintYield(address(vault), 1e18);

        vm.prank(guardian);
        controller.unpause();
        assertEq(controller.mintableHeadroom(), 20e18, "the headroom did not come back");
    }

    // =====================================================================
    //  D — the guards R16 could not red, and the one it should not have kept
    // =====================================================================

    /// @notice R17 (finding "three lines can be deleted in full"). `mint`'s underflow clamp had no
    ///         reachable state and no test double that made the reserve's balance FALL across
    ///         `depositUSDC`, so it survived a full-suite deletion mutation. Here is the state:
    ///         a reserve that takes the charge and forwards MORE than it took. Without the clamp
    ///         this is an arithmetic panic instead of a named protocol error.
    function test_R17_G11_aReserveWhoseBalanceFallsAcrossTheDepositIsNamedNotPanicked() public {
        ControllerReserveDouble double = new ControllerReserveDouble(usdc, sink);
        MintRedeemController c = _doubleWiredController(double);
        usdc.mint(address(double), 1e6); // so it can over-forward

        double.setMode(ControllerReserveDouble.Mode.Honest);
        vm.startPrank(alice);
        usdc.approve(address(c), 100e6);
        assertEq(c.mint(100e6), 100e18, "POSITIVE CONTROL: the honest path must work");

        double.setMode(ControllerReserveDouble.Mode.DrainOnDeposit);
        usdc.approve(address(c), 100e6);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_DepositNotCustodied.selector, 100e6, 0, 100e18)
        );
        c.mint(100e6);
        vm.stopPrank();
    }

    /// @notice R17 (finding C3). R16 declined to add a residual-allowance guard on the express
    ///         ground that it would be "code no test could ever red", and argued the controller
    ///         "holds ZERO USDC at rest". Both claims assume the reserve the guard three lines
    ///         above exists to distrust. A reserve that sources the deposit from a third party
    ///         satisfies the delivery equality with the user's cash still on the controller and a
    ///         live allowance against it — and that standing allowance can then be swept with a
    ///         bare `transferFrom` and no user call at all. The mint now fails CLOSED.
    function test_R17_L2b_aReserveThatSourcesTheDepositElsewhereIsRefused() public {
        ControllerReserveDouble double = new ControllerReserveDouble(usdc, sink);
        MintRedeemController c = _doubleWiredController(double);
        address funder = makeAddr("r17-funder");
        usdc.mint(funder, 500e6);
        vm.prank(funder);
        usdc.approve(address(double), type(uint256).max);
        double.setFunder(funder);

        double.setMode(ControllerReserveDouble.Mode.DepositFromThirdParty);
        vm.startPrank(alice);
        usdc.approve(address(c), 100e6);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_CashStrandedOnController.selector, 0, 100e6)
        );
        c.mint(100e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(c)), 0, "THE CONTROLLER HELD CASH AT REST");
    }

    /// @notice R17, THE REGRESSION THIS GUARD MUST NOT CAUSE — AND IT IS NOT HYPOTHETICAL, IT IS
    ///         THE FIRST DRAFT OF THIS VERY FIX. Written as `balanceOf(this) != 0` the check is an
    ///         absolute balance, and USDC can be sent to this contract by anyone at any time
    ///         (finding L4), so ONE WEI of donated USDC would have bricked `mint` for every user,
    ///         permanently and for free — a strictly worse defect than the residual allowance it
    ///         closes. It is measured as a DELTA across the call instead.
    function test_R17_L2b_aDonationDoesNotBrickMintForEveryone() public {
        usdc.mint(address(controller), 1); // the griefing transaction: one wei, no permissions
        assertEq(usdc.balanceOf(address(controller)), 1);

        assertEq(_mintUSDfr(alice, 100e6), 100e18, "ONE WEI OF DONATED USDC BRICKED MINT");
        vm.prank(alice);
        assertEq(controller.redeem(40e18), 40e6, "and the exit still works too");
        assertEq(usdc.balanceOf(address(controller)), 1, "the donation is untouched, as L4 says");
    }

    /// @notice R17 (findings C2 / D1). The R16-L2 independent measurement was installed on the
    ///         INFLOW leg only. `redeem` burned the holder's USDfr, called `releaseUSDC`, and then
    ///         asserted the deficit rule using the SAME reserve's own tally of that same release —
    ///         verbatim the L2 defect, on the leg where the loss is irreversible. Both legs now
    ///         carry the measurement, and this test runs both against ONE reserve.
    function test_R17_D1_bothLegsCarryTheDeliveryMeasurement() public {
        ControllerReserveDouble double = new ControllerReserveDouble(usdc, sink);
        MintRedeemController c = _doubleWiredController(double);

        double.setMode(ControllerReserveDouble.Mode.Honest);
        vm.startPrank(alice);
        usdc.approve(address(c), 200e6);
        assertEq(c.mint(200e6), 200e18, "POSITIVE CONTROL: mint");
        assertEq(c.redeem(10e18), 10e6, "POSITIVE CONTROL: redeem");

        // LEG 1, the inflow: refused by name, exactly as R16 shipped it
        double.setMode(ControllerReserveDouble.Mode.SkimDeposit);
        usdc.approve(address(c), 100e6);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_DepositNotCustodied.selector, 100e6, 50e6, 100e18)
        );
        c.mint(100e6);

        // LEG 2, the outflow: the ledger moves by exactly the right value — so
        // `_assertDeficitNotWorsened` is perfectly satisfied — and half the cash never arrives.
        double.setMode(ControllerReserveDouble.Mode.SkimRelease);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_RedemptionNotSettled.selector, 100e6, 50e6, 100e18)
        );
        c.redeem(100e18);
        vm.stopPrank();
        assertEq(usdfr.balanceOf(alice), 190e18, "THE BURN STOOD WHILE THE CASH DID NOT ARRIVE");
    }

    /// @notice R17. `redeem`'s underflow clamp, falsified. A reserve that DEBITS the redeemer on a
    ///         standing approval instead of paying them makes the payee's balance FALL across the
    ///         call. Without the clamp that is an arithmetic panic rather than a named error, and
    ///         a redeemer who is simultaneously debited elsewhere must fail CLOSED.
    function test_R17_D1_aReserveThatDebitsTheRedeemerIsNamedNotPanicked() public {
        ControllerReserveDouble double = new ControllerReserveDouble(usdc, sink);
        MintRedeemController c = _doubleWiredController(double);

        double.setMode(ControllerReserveDouble.Mode.Honest);
        vm.startPrank(alice);
        usdc.approve(address(c), 200e6);
        c.mint(200e6);
        usdc.approve(address(double), type(uint256).max); // a standing approval to the reserve
        double.setMode(ControllerReserveDouble.Mode.ClawbackRelease);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_RedemptionNotSettled.selector, 10e6, 0, 10e18)
        );
        c.redeem(10e18);
        vm.stopPrank();
    }

    /// @notice R17. `mint`'s `nonReentrant`, falsified. An adversarial guard-deletion campaign
    ///         removed this modifier with the entire deterministic AND invariant suite green,
    ///         which by R16's own rule makes it a comment rather than a guard. The vector is the
    ///         same untrusted-reserve model every other guard on this function assumes.
    function test_R17_G04_mintIsReentrancyLocked() public {
        ControllerReserveDouble double = new ControllerReserveDouble(usdc, sink);
        MintRedeemController c = _doubleWiredController(double);
        double.setReentrancyTarget(address(c), 10e6);

        double.setMode(ControllerReserveDouble.Mode.Honest);
        vm.startPrank(alice);
        usdc.approve(address(c), 500e6);
        assertEq(c.mint(100e6), 100e18, "POSITIVE CONTROL: the same double must mint normally");

        double.setMode(ControllerReserveDouble.Mode.ReenterMint);
        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        c.mint(100e6);
        vm.stopPrank();
    }

    /// @notice R17. `mintYield`'s `nonReentrant`, falsified. Its only non-view external call is
    ///         `usdfr.mint`, so the falsifying case is a USDfr that re-enters — the same "botched
    ///         upgrade behind the timelock" model `mint`'s R16-L2 measurement was written for.
    ///         Without the lock the inner mint completes inside the outer call's before/after
    ///         solvency readings, so two mints are authorised against one headroom measurement.
    function test_R17_G20_mintYieldIsReentrancyLocked() public {
        ReentrantUSDfrDouble fake = new ReentrantUSDfrDouble();
        ControllerReserveDouble double = new ControllerReserveDouble(usdc, sink);
        double.seedBacking(1_000e18);
        MintRedeemController c = MintRedeemController(
            address(
                new ERC1967Proxy(
                    address(new MintRedeemController()),
                    abi.encodeCall(
                        MintRedeemController.initialize,
                        (admin, guardian, admin, address(fake), address(compliance), address(double))
                    )
                )
            )
        );
        vm.startPrank(admin);
        c.grantRole(Roles.CREDIT_ROLE, creditModule);
        // The re-entrant call arrives AS THE TOKEN, so the token must hold the role too — otherwise
        // the test would pass on an access-control revert and prove nothing about the lock.
        c.grantRole(Roles.CREDIT_ROLE, address(fake));
        c.setYieldSink(address(vault), true);
        vm.stopPrank();

        // POSITIVE CONTROL: the same double, callback disarmed, must mint normally.
        fake.arm(address(0), address(vault), 0);
        vm.prank(creditModule);
        c.mintYield(address(vault), 10e18);
        assertEq(fake.totalSupply(), 10e18);

        fake.arm(address(c), address(vault), 10e18);
        vm.prank(creditModule);
        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        c.mintYield(address(vault), 10e18);
    }

    /// @notice R17. The OTHER half of the R16-L2 delivery check — "the books agree with what the
    ///         user was charged" — falsified independently. A reserve that really does take and
    ///         custody the cash, so the balance measurement is satisfied, but MISREPORTS the value
    ///         it credited. Without this half, the controller would mint whatever the reserve said.
    ///         (This mutation SURVIVED the full non-fork suite before this test existed.)
    function test_R17_L2c_aReserveThatMisreportsWhatItCreditedIsRefused() public {
        ControllerReserveDouble double = new ControllerReserveDouble(usdc, sink);
        MintRedeemController c = _doubleWiredController(double);

        double.setMode(ControllerReserveDouble.Mode.Honest);
        vm.startPrank(alice);
        usdc.approve(address(c), 200e6);
        assertEq(c.mint(100e6), 100e18, "POSITIVE CONTROL: the honest path must work");

        double.setMode(ControllerReserveDouble.Mode.MisreportCredit);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_DepositNotCustodied.selector, 100e6, 100e6, 100e18 - 1
            )
        );
        c.mint(100e6);
        vm.stopPrank();
    }

    /// @notice R17. `redeem(uint256)`'s `nonReentrant`, falsified. The vector is a reserve whose
    ///         `releaseUSDC` calls back into the controller before paying — the same untrusted
    ///         reserve every other guard on this function assumes. (SURVIVED the full non-fork
    ///         suite before this test existed.)
    function test_R17_G15_redeemOneArgIsReentrancyLocked() public {
        ControllerReserveDouble double = new ControllerReserveDouble(usdc, sink);
        MintRedeemController c = _doubleWiredController(double);
        double.setReentrancyTarget(address(c), 1e18);
        double.setReenterTwoArgRedeem(false);

        double.setMode(ControllerReserveDouble.Mode.Honest);
        vm.startPrank(alice);
        usdc.approve(address(c), 200e6);
        c.mint(200e6);
        assertEq(c.redeem(10e18), 10e6, "POSITIVE CONTROL: the honest redemption must work");

        double.setMode(ControllerReserveDouble.Mode.ReenterRedeem);
        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        c.redeem(10e18);
        vm.stopPrank();
    }

    /// @notice R17. The SAME lock on the two-argument overload, falsified separately rather than
    ///         inferred from the one-argument form — they are distinct functions with distinct
    ///         modifiers, and R17 is the round that added the second one.
    function test_R17_G18_redeemTwoArgIsReentrancyLocked() public {
        ControllerReserveDouble double = new ControllerReserveDouble(usdc, sink);
        MintRedeemController c = _doubleWiredController(double);
        double.setReentrancyTarget(address(c), 1e18);
        double.setReenterTwoArgRedeem(true);

        double.setMode(ControllerReserveDouble.Mode.Honest);
        vm.startPrank(alice);
        usdc.approve(address(c), 200e6);
        c.mint(200e6);
        assertEq(c.redeem(10e18, 10e6), 10e6, "POSITIVE CONTROL: the honest redemption must work");

        double.setMode(ControllerReserveDouble.Mode.ReenterRedeem);
        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        c.redeem(10e18, 0);
        vm.stopPrank();
    }

    /// @notice R17. The two-argument `redeem` must obey the guardian pause exactly as the
    ///         one-argument form does. R16's pause test only exercised the old signature, so the
    ///         new overload's `whenNotPaused` was a modifier no test could red.
    function test_R17_G19_theTwoArgumentRedeemObeysThePause() public {
        _mintUSDfr(alice, 100e6);
        vm.prank(guardian);
        controller.pause();
        vm.prank(alice);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        controller.redeem(10e18, 0);
    }

    /// @notice R17. `burnLoss`'s `nonReentrant`, falsified. Its only external call is
    ///         `usdfr.burn`, so the vector is the same "botched USDfr upgrade behind the timelock"
    ///         model as `mintYield`'s. This matters more here than anywhere else on the contract:
    ///         `burnLoss` carries NO solvency assertion at all (finding M6) and is deliberately
    ///         not pausable, so the reentrancy lock is the only thing serialising it.
    ///         (SURVIVED the full non-fork suite before this test existed.)
    function test_R17_G39_burnLossIsReentrancyLocked() public {
        ReentrantUSDfrDouble fake = new ReentrantUSDfrDouble();
        ControllerReserveDouble double = new ControllerReserveDouble(usdc, sink);
        MintRedeemController c = MintRedeemController(
            address(
                new ERC1967Proxy(
                    address(new MintRedeemController()),
                    abi.encodeCall(
                        MintRedeemController.initialize,
                        (admin, guardian, admin, address(fake), address(compliance), address(double))
                    )
                )
            )
        );
        vm.startPrank(admin);
        c.grantRole(Roles.LOSS_BURNER_ROLE, creditModule);
        // the re-entrant call arrives AS THE TOKEN, so the token needs the role too — otherwise
        // the test would pass on an access-control revert and prove nothing about the lock
        c.grantRole(Roles.LOSS_BURNER_ROLE, address(fake));
        c.setLossSource(address(vault), true);
        vm.stopPrank();

        // POSITIVE CONTROL: callback disarmed, the same double must burn normally.
        fake.mint(address(vault), 100e18);
        fake.armBurn(address(0), address(0));
        vm.prank(creditModule);
        c.burnLoss(address(vault), 10e18);
        assertEq(fake.totalSupply(), 90e18);

        fake.armBurn(address(c), address(vault));
        vm.prank(creditModule);
        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        c.burnLoss(address(vault), 10e18);
    }

    // =====================================================================
    //  M2, re-closed at the setter
    // =====================================================================

    /// @notice R17 (findings B-04 / C6). `burnLoss`'s NatSpec claimed as a property of the CODE
    ///         that "the only reachable burns are the cascade's own". That was a property of the
    ///         WIRING: `setLossSource` accepted any non-zero address including a bare EOA, so
    ///         finding M2 — a forced, non-pro-rata seizure of one named holder, with no allowance,
    ///         no backing assertion and no pausability — was one routine-looking timelock
    ///         transaction away. The sibling setters on `ReserveManager` already refuse a codeless
    ///         address; this applies the same constraint.
    function test_R17_C6_anEOACannotBeNamedALossSource() public {
        _mintUSDfr(alice, 100e6);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_LossSourceNotContract.selector, alice));
        controller.setLossSource(alice, true);

        assertFalse(controller.isLossSource(alice));
        vm.prank(creditModule);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotLossSource.selector, alice));
        controller.burnLoss(alice, 100e18);
        assertEq(usdfr.balanceOf(alice), 100e18, "A NAMED HOLDER WAS SEIZED");
    }

    /// @notice R17. The constraint is on AUTHORIZATION only. A governance kill-switch that a
    ///         self-destructed endpoint could disable would be a worse defect than the one this
    ///         closes, so revocation must never be blocked by the state of the account revoked.
    ///         The fee-recipient half (`setYieldSink`) is deliberately NOT constrained: it credits
    ///         an address, it does not seize one, and the Forest Road treasury may be an EOA.
    function test_R17_C6_revocationIsUnconstrainedAndYieldSinksMayBeEOAs() public {
        vm.startPrank(admin);
        controller.setLossSource(alice, false); // revoking a never-listed EOA must not revert
        controller.setYieldSink(bob, true); // an EOA fee recipient is legitimate
        vm.stopPrank();
        assertFalse(controller.isLossSource(alice));
        assertTrue(controller.isYieldSink(bob));
    }
}

/// @notice The credit-layer half, driven through the real `WaterfallEngine` and `ReserveManager`
///         rather than a stand-in: the M5 "protocol-native cure" measured on the basis that can
///         actually see an R4-01 custody hole.
contract Fix_R17_ControllerCreditLayer is CreditLayerFixture {
    bytes32 internal constant EVIDENCE = keccak256("R17-workout-memorandum");
    address internal custodySink = makeAddr("r17-credit-sink");

    function _stakeVault(address who, uint256 amount) internal {
        _mintUSDfrTo(who, amount);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _drainCustody(uint256 units) internal {
        vm.prank(address(reserves));
        usdc.transfer(custodySink, units);
    }

    /// @notice R17 CORE (findings B-01 / D2, the second High). `mintableHeadroom()` decides how
    ///         much interest `_routeInterest` may distribute. Measured on the RECORDED ledger it
    ///         could not see a custody shortfall by construction, so under the exact state R4-01
    ///         exists to recognise — users frozen, `backingInvariantHolds()` publishing FALSE — the
    ///         full interest leg was minted out as yield to the vault and the fee recipient, the
    ///         withholding clamp withheld ZERO, and the hole was not repaired by a wei. The
    ///         protocol fee was therefore taken on the GROSS, out of an open hole, contradicting
    ///         `_routeInterest`'s own "Forest Road does not collect a performance fee out of a
    ///         shortfall".
    function test_R17_B01_interestIsWithheldWhileAnUnreconciledCustodyHoleStands() public {
        uint256 id = _liveFilmFacility(300_000e18);
        _stakeVault(alice, 50_000e18);

        _drainCustody(20_000e6);
        assertEq(controller.backingDeficit(), 0, "the RECORDED basis reports the protocol whole");
        assertEq(controller.recognizedDeficit(), 20_000e18, "the RECOGNISED basis sees the hole");
        assertFalse(controller.backingInvariantHolds());
        assertEq(controller.mintableHeadroom(), 0, "THE CURE WAS BLIND TO THE HOLE");

        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        uint256 feeBefore = usdfr.balanceOf(feeRecipient);
        uint256 supplyBefore = usdfr.totalSupply();
        uint256 recognizedBefore = controller.recognizedDeficit();

        IWaterfallEngine.Payment memory p = _preparePayment(id, 10_000e18, 0);
        vm.expectEmit(false, false, false, true, address(waterfall));
        emit IWaterfallEngine.InterestWithheldForBackingRepair(10_000e18, 10_000e18);
        vm.prank(servicer);
        waterfall.distribute(p);

        assertEq(usdfr.balanceOf(address(vault)), vaultBefore, "SENIOR YIELD WAS PAID OUT OF A KNOWN HOLE");
        assertEq(usdfr.balanceOf(feeRecipient), feeBefore, "THE PROTOCOL FEE WAS TAKEN OUT OF A KNOWN HOLE");
        assertEq(usdfr.totalSupply(), supplyBefore, "SUPPLY EXPANDED WHILE UNDER-BACKED");
        assertEq(
            controller.recognizedDeficit(),
            recognizedBefore - 10_000e18,
            "THE WITHHELD INTEREST DID NOT REPAIR THE HOLE"
        );
    }

    /// @notice R17 (finding D3). The pause coupling, end to end through the real engine. A
    ///         controller pause must not stop a borrower paying: the cash still lands in the
    ///         reserve as backing and only the YIELD is suspended.
    function test_R17_D3_aControllerPauseDoesNotStopBorrowerRepayment() public {
        uint256 id = _liveFilmFacility(300_000e18);
        _stakeVault(alice, 50_000e18);

        IWaterfallEngine.Payment memory p = _preparePayment(id, 10_000e18, 20_000e18);
        vm.prank(guardian);
        controller.pause();

        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        vm.expectEmit(false, false, false, true, address(waterfall));
        emit IWaterfallEngine.InterestWithheldForBackingRepair(10_000e18, 0);
        vm.prank(servicer);
        waterfall.distribute(p);

        assertEq(reserves.deployedTo(id), 280_000e18, "THE PRINCIPAL LEG WAS COLLATERAL DAMAGE OF A PAUSE");
        assertEq(usdfr.balanceOf(address(vault)), vaultBefore, "a paused controller still paid yield");
    }

    /// @notice R17. The positive control the basis change must not break: a RECORDED G3 mark of the
    ///         same size still triggers the M5 withholding exactly as R16 shipped it, and the event
    ///         now reports the recognised remainder (which equals the recorded one here, because
    ///         custody is intact).
    function test_R17_B01_controlARecordedMarkStillTriggersTheCure() public {
        uint256 id = _liveFilmFacility(300_000e18);
        _stakeVault(alice, 50_000e18);
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(id, 30_000e18, EVIDENCE);
        assertEq(controller.backingDeficit(), 30_000e18);

        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        IWaterfallEngine.Payment memory p = _preparePayment(id, 10_000e18, 0);
        vm.expectEmit(false, false, false, true, address(waterfall));
        emit IWaterfallEngine.InterestWithheldForBackingRepair(10_000e18, 20_000e18);
        vm.prank(servicer);
        waterfall.distribute(p);

        assertEq(controller.backingDeficit(), 20_000e18, "interest did not repair the hole");
        assertEq(usdfr.balanceOf(address(vault)), vaultBefore, "yield leaked out of a short protocol");
    }
}
