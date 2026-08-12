// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Test.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {MintRedeemController} from "../../src/MintRedeemController.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {ControllerReserveDouble} from "../helpers/ControllerReserveDouble.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

/// @title AUDIT ROUND R16 — MintRedeemController: solvency states and least privilege
/// @notice One file for ten findings on one contract, because eight of them are two root causes.
///
///  ROOT CAUSE A — ONE ABSOLUTE INEQUALITY, NO PARTIAL STATE (findings M3, M4, M5, and M6's
///  shadow). The contract asserted `totalSupply <= backingValue` identically on all four
///  supply-affecting paths. An absolute inequality has two states and both are wrong once a loss
///  is recognised: PRETEND (nothing recognised the loss, so the protocol keeps issuing and
///  honouring par claims against a hole) or FREEZE (the loss is recognised, so `mint`, `redeem`,
///  `mintYield` AND `burnLoss` all revert at once, taking `WaterfallEngine.distribute` with
///  them). A single ordinary conservative mark therefore bricked the protocol, and the freeze
///  disabled `burnLoss` — the very instrument that could have ended it. Replaced by ONE rule on
///  all paths, "an operation may not increase the deficit", plus sub-par redemption so the
///  protocol can say "we are short by X, here is the ratio" instead of choosing between the two
///  wrong answers.
///
///  ROOT CAUSE B — UNCONSTRAINED SUPPLY ENDPOINTS (findings M1, M2). `burnLoss(from)` and
///  `mintYield(to)` constrained their addresses in no way and composed into arbitrary
///  confiscation that the backing invariant could not see BY CONSTRUCTION, because it compared
///  two global aggregates the pair left unchanged. `USDfr.burn` takes no allowance, so `burnLoss`
///  alone was already a forced, non-pro-rata seizure from a named holder. Fixed by least
///  privilege first (the burn power is split off `CREDIT_ROLE`, which `WaterfallEngine` held and
///  never used) and then by naming both endpoints.
///
/// @dev EVERY GUARD THIS ROUND ADDS OR KEEPS HAS A DELETION MUTATION IN THIS FILE OR IN
///      `test/unit/MintRedeemController.t.sol`. Where the shipped `ReserveManager` cannot
///      falsify a guard, the falsifying case comes from `ControllerReserveDouble` — see its
///      NatSpec. A guard nothing can red is treated as a defect this round, which is why
///      `burnLoss` no longer carries a backing assertion at all (finding M6).
contract Fix_R16_ControllerTokenLayer is TokenLayerFixture {
    // =====================================================================
    //  M1 / M2 — the confiscation composition, and least privilege
    // =====================================================================

    /// @notice M1 CORE. The exploit was `burnLoss(victim)` + `mintYield(attacker)`: two calls
    ///         that leave `totalSupply` and `backingValue` both unchanged, so the ADR-0012
    ///         assertion passed on both. Both ENDPOINTS now refuse an arbitrary address.
    /// @dev AUDIT FIX (R17) — RENAMED, because the old name claimed more than this test asserts
    ///      and a test name is read as specification. What is asserted is that an arbitrary victim
    ///      and an arbitrary beneficiary are BOTH refused. The aggregate blindness that made the
    ///      pair invisible to the solvency check is structural and untouched; what remains
    ///      reachable is the two-role form against the `sUSDfr` vault, which is pro-rata. See
    ///      `mintYield`'s NatSpec for the full, honest statement.
    function test_M1_bothEndpointsRefuseAnArbitraryVictimAndAnArbitraryBeneficiary() public {
        _mintUSDfr(alice, 100e6);
        assertEq(usdfr.balanceOf(alice), 100e18);

        // Half one: seizing a named holder.
        vm.prank(creditModule);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotLossSource.selector, alice));
        controller.burnLoss(alice, 100e18);

        // Half two: re-issuing it anywhere the attacker chooses.
        vm.prank(creditModule);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotYieldSink.selector, bob));
        controller.mintYield(bob, 100e18);

        assertEq(usdfr.balanceOf(alice), 100e18, "the victim's balance moved");
        assertEq(usdfr.balanceOf(bob), 0, "the attacker was credited");
    }

    /// @notice M2. `USDfr.burn` takes NO ALLOWANCE, so before this round curing a shortfall out
    ///         of one named holder was capital-free and available to any `CREDIT_ROLE` holder:
    ///         a forced, non-pro-rata seizure while an identically-placed holder paid nothing.
    ///         The only reachable burn is now the vault's, which IS pro-rata by construction
    ///         because it moves the exchange rate for every senior depositor at once.
    function test_M2_twoIdenticallyPlacedHoldersCannotBeTreatedDifferently() public {
        _mintUSDfr(alice, 100e6);
        _mintUSDfr(bob, 100e6);
        assertEq(usdfr.allowance(alice, address(controller)), 0, "no allowance was ever needed: that is the finding");

        vm.prank(creditModule);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotLossSource.selector, alice));
        controller.burnLoss(alice, 50e18);

        assertEq(usdfr.balanceOf(alice), usdfr.balanceOf(bob), "one holder was singled out");
    }

    /// @notice M1, LEAST PRIVILEGE. `burnLoss` sits behind `LOSS_BURNER_ROLE`, so holding
    ///         `CREDIT_ROLE` — which the repayment engine legitimately needs for `mintYield` —
    ///         no longer carries a burn power with it.
    function test_M1_creditRoleAloneCannotBurn() public {
        _mintUSDfr(alice, 100e6);
        vm.prank(alice);
        usdfr.transfer(address(vault), 10e18);

        address yieldOnly = makeAddr("yieldOnlyModule");
        vm.prank(admin);
        controller.grantRole(Roles.CREDIT_ROLE, yieldOnly);

        vm.prank(yieldOnly);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, yieldOnly, Roles.LOSS_BURNER_ROLE
            )
        );
        controller.burnLoss(address(vault), 1e18);
    }

    /// @notice M1. The endpoint lists are the guard, and revoking one closes the path again —
    ///         so this is a live predicate, not a one-time constructor decision.
    function test_M1_endpointAuthorisationIsRevocableAndGovernanceOnly() public {
        _mintUSDfr(alice, 100e6);
        vm.prank(alice);
        usdfr.transfer(address(vault), 10e18);

        vm.prank(creditModule);
        controller.burnLoss(address(vault), 1e18); // listed at fixture time

        vm.expectEmit(true, false, false, true, address(controller));
        emit IMintRedeemController.LossSourceUpdated(address(vault), false);
        vm.prank(admin);
        controller.setLossSource(address(vault), false);

        vm.prank(creditModule);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotLossSource.selector, address(vault)));
        controller.burnLoss(address(vault), 1e18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        controller.setLossSource(alice, true);
    }

    // =====================================================================
    //  M3 — sub-par redemption instead of pretend-or-freeze
    // =====================================================================

    /// @dev Drives the protocol to a KNOWN coverage ratio using the production G3 input: a
    ///      governance conservative mark on deployed principal. Custody is untouched, so the
    ///      R4-01 custody guard is not what is being measured here.
    function _makeUnderBacked(uint256 usdcIn, uint256 markValue) internal returns (uint256 supply) {
        supply = _mintUSDfr(alice, usdcIn);
        vm.startPrank(creditModule);
        reserves.recordDeployment(1, borrower, usdcIn / 2);
        reserves.recordPrincipalWritedown(1, markValue);
        vm.stopPrank();
    }

    /// @notice M3 CORE. Redemption used to be frozen for EVERY holder the moment a shortfall was
    ///         recognised. It now settles at the coverage ratio, and the quote is published.
    function test_M3_redemptionReopensAtTheCoverageRatio() public {
        _makeUnderBacked(100e6, 10e18); // 90 backing against 100 supply => 90 cents
        assertEq(controller.totalUSDfr(), 100e18);
        assertEq(controller.backingValue(), 90e18);
        assertFalse(controller.backingInvariantHolds(), "the scenario must really be short");

        (uint256 quotedOut, uint256 quotedIn) = controller.previewRedeem(10e18);
        assertEq(quotedIn, 10e18);
        assertEq(quotedOut, 9e6, "90 cents on the dollar, not par and not a revert");

        uint256 before = usdc.balanceOf(alice);
        // AUDIT FIX (R17). The one-argument form now carries the PAR floor, so a sub-par exit must
        // be elected explicitly. Pin both halves: the default refuses, and the named floor settles.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_SlippageExceeded.selector, 9e6, 10e6));
        controller.redeem(10e18);

        vm.expectEmit(true, false, false, true, address(controller));
        emit IMintRedeemController.SeniorShortfallCrystallised(alice, 1e18, 1e18);
        vm.expectEmit(true, false, false, true, address(controller));
        emit IMintRedeemController.SubParRedemption(alice, 10e18, 9e6, 100e18, 90e18);
        vm.prank(alice);
        uint256 paid = controller.redeem(10e18, quotedOut);

        assertEq(paid, 9e6, "settlement diverged from the published quote");
        assertEq(usdc.balanceOf(alice) - before, 9e6);
        assertEq(usdfr.balanceOf(alice), 90e18);
    }

    /// @notice M3, THE JUSTIFICATION. A PAR exit out of a short pool is a run — it pays 100 cents
    ///         from a 90-cent pool and pushes the whole shortfall onto whoever arrives last,
    ///         which is why R4-01 closed redemption rather than re-pricing it. A RATIO exit is
    ///         neutral: the coverage left behind is unchanged to the wei-rounding, and every wei
    ///         of that rounding accrues to the holders who stayed.
    function testFuzz_M3_aSubParExitNeverWorsensTheRatioForTheHoldersWhoStayed(uint256 markUnits, uint256 exit)
        public
    {
        markUnits = bound(markUnits, 1, 40e6);
        _makeUnderBacked(100e6, markUnits * 1e12);
        // Bounded by the idle cash the reserve actually holds (half was deployed), so the fuzz
        // measures the PRICING property rather than re-testing the liquidity bound.
        exit = bound(exit, 1e12, 40e18);

        uint256 supply0 = controller.totalUSDfr();
        uint256 backing0 = controller.backingValue();
        (uint256 quotedOut,) = controller.previewRedeem(exit);
        vm.assume(quotedOut != 0);

        // AUDIT FIX (R17): a zero floor is named DELIBERATELY here — this fuzz measures the PRICING
        // property (the ratio left behind), so it must be free to accept any sub-par price.
        vm.prank(alice);
        controller.redeem(exit, 0);

        uint256 supply1 = controller.totalUSDfr();
        uint256 backing1 = controller.backingValue();
        assertGe(backing1 * supply0, backing0 * supply1, "COVERAGE RATIO FELL FOR THE HOLDERS WHO STAYED");
        assertLe(supply1 - backing1, supply0 - backing0, "THE ABSOLUTE DEFICIT GREW");
    }

    /// @notice M3, THE ASYMMETRY. `redeem` reopens; `mint` stays closed, and now says why.
    ///         Minting at par into a short book sells a NEW holder a claim worth less than the
    ///         dollar they paid. This is the R4-01 finding restated for the non-custody case,
    ///         which `_requireCustodiedReserve` cannot see at all.
    function test_M3_parIssuanceStaysClosedWhileShort() public {
        _makeUnderBacked(100e6, 10e18);

        vm.startPrank(bob);
        usdc.approve(address(controller), 10e6);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_MintClosedWhileUnderBacked.selector, 100e18, 90e18)
        );
        controller.mint(10e6);
        vm.stopPrank();
        assertEq(usdfr.balanceOf(bob), 0, "a claim was issued against a short book");
        assertEq(usdc.balanceOf(bob), 1_000_000e6, "the refused deposit was taken anyway");
    }

    /// @notice M3. The sub-par branch must not perturb the healthy path at all — this is the
    ///         state the protocol is in essentially all of the time.
    function test_M3_parRedemptionIsBitForBitUnchangedWhileWhole() public {
        _mintUSDfr(alice, 100e6);
        (uint256 quotedOut, uint256 quotedIn) = controller.previewRedeem(50_500000_000000_000001);
        assertEq(quotedOut, 50_500000);
        assertEq(quotedIn, 50_500000_000000_000000, "sub-USDC dust must still stay in the wallet");

        vm.recordLogs();
        vm.prank(alice);
        assertEq(controller.redeem(50_500000_000000_000001), 50_500000);
        assertEq(usdfr.balanceOf(alice), 100e18 - 50_500000_000000_000000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != IMintRedeemController.SubParRedemption.selector,
                "a whole protocol emitted a sub-par redemption"
            );
        }
    }

    // =====================================================================
    //  M4 — one predicate, not four
    // =====================================================================

    /// @notice M4. The four supply paths now answer to the SAME rule. Under a standing deficit:
    ///         loss absorption runs (it repairs), sub-par redemption runs (it is neutral), yield
    ///         minting refuses (it dilutes), par minting refuses (it mis-sells). Before this
    ///         round all four reverted, including the two that help.
    function test_M4_theFourSupplyPathsAgreeUnderAStandingDeficit() public {
        _makeUnderBacked(100e6, 10e18);
        vm.prank(alice);
        usdfr.transfer(address(vault), 20e18);

        // absorbs: allowed, and it shrinks the deficit
        uint256 deficit0 = controller.backingDeficit();
        vm.prank(creditModule);
        controller.burnLoss(address(vault), 5e18);
        assertEq(controller.backingDeficit(), deficit0 - 5e18, "the cascade could not run under a deficit");

        // dilutes: refused, and it names the deficit rather than the standing condition
        vm.prank(creditModule);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_DeficitWorsened.selector, 5e18, 6e18));
        controller.mintYield(address(vault), 1e18);

        // neutral: allowed. AUDIT FIX (R17) — a sub-par exit is an explicit election, so the
        // holder names the floor they accept; the point being measured is the DEFICIT rule.
        (uint256 ratioQuote,) = controller.previewRedeem(10e18);
        vm.prank(alice);
        controller.redeem(10e18, ratioQuote);
        assertLe(controller.backingDeficit(), 5e18, "a ratio exit widened the deficit");
    }

    /// @notice M4. While the protocol is WHOLE the rule reduces exactly to ADR-0012 — same
    ///         inequality, same error, same arguments. Nothing about the healthy path is relaxed.
    function test_M4_theRuleIsStillADR0012WhileWhole() public {
        _mintUSDfr(alice, 100e6);
        assertEq(controller.backingDeficit(), 0);
        vm.prank(creditModule);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_BackingInvariantViolated.selector, 101e18, 100e18)
        );
        controller.mintYield(address(vault), 1e18);
    }

    // =====================================================================
    //  M5 — the protocol is no longer inert under a residual deficit
    // =====================================================================

    /// @notice M5. Under a latched deficit EVERY path reverted and there was no protocol-native
    ///         cure. This pins that the protocol is now operable in that state, end to end, with
    ///         no governance action of any kind.
    function test_M5_aLatchedDeficitDoesNotFreezeTheProtocol() public {
        _mintUSDfr(alice, 100e6);
        vm.prank(alice);
        usdfr.transfer(address(vault), 30e18);
        vm.startPrank(creditModule);
        reserves.recordDeployment(1, borrower, 50e6);
        reserves.recordPrincipalWritedown(1, 25e18);
        vm.stopPrank();
        assertEq(controller.backingDeficit(), 25e18);

        // the cascade absorbs what it can — this alone was impossible before
        vm.prank(creditModule);
        controller.burnLoss(address(vault), 20e18);
        assertEq(controller.backingDeficit(), 5e18, "residual deficit");

        // and a holder can still get their honest share out
        (uint256 quoted,) = controller.previewRedeem(10e18);
        assertGt(quoted, 0, "the protocol is still inert for holders");
        vm.prank(alice);
        assertEq(controller.redeem(10e18, quoted), quoted); // R17: the quote, passed back as the floor

        // once repaired, everything reopens with no governance action
        usdc.mint(creditModule, 10e6);
        vm.startPrank(creditModule);
        usdc.approve(address(reserves), 10e6);
        reserves.depositUSDC(creditModule, 10e6);
        vm.stopPrank();
        assertEq(controller.backingDeficit(), 0, "cash in did not cure the deficit");

        vm.startPrank(bob);
        usdc.approve(address(controller), 10e6);
        assertEq(controller.mint(10e6), 10e18, "par issuance did not reopen by itself");
        vm.stopPrank();
        assertGt(controller.mintableHeadroom(), 0);
    }

    // =====================================================================
    //  L1 — the pause is no longer a one-way valve
    // =====================================================================

    /// @notice L1. A guardian pause must never leave supply EXPANSION available. It must also
    ///         never stop loss ABSORPTION. The asymmetry is deliberate and mirrors the rule
    ///         `USDfr._update` already enforces on the token itself.
    function test_L1_pauseClosesEveryIssuancePathAndLeavesTheCascadeOpen() public {
        _mintUSDfr(alice, 100e6);
        vm.prank(alice);
        usdfr.transfer(address(vault), 20e18);
        usdc.mint(creditModule, 10e6);
        vm.startPrank(creditModule);
        usdc.approve(address(reserves), 10e6);
        reserves.depositUSDC(creditModule, 10e6);
        vm.stopPrank();

        vm.prank(guardian);
        controller.pause();

        vm.prank(bob);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        controller.mint(1e6);

        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        controller.redeem(1e18);

        vm.prank(creditModule);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        controller.mintYield(address(vault), 1e18);

        // NEVER PAUSABLE: a recognised loss must not sit unallocated for the length of a pause.
        vm.prank(creditModule);
        controller.burnLoss(address(vault), 1e18);
        assertEq(usdfr.balanceOf(address(vault)), 19e18);
    }

    // =====================================================================
    //  L2 — mint no longer derives both sides of its check from one module
    // =====================================================================

    /// @dev A second controller wired to the misbehaving reserve. The real USDfr and compliance
    ///      registry are reused so nothing about the token layer is faked.
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

    /// @notice L2 CORE. The reserve credits its ledger in full but only half the cash reaches
    ///         custody. Both sides of the OLD check came from that same reserve, so it passed.
    ///         The controller now measures the reserve's own token balance across the call.
    function test_L2_aSkimmingReserveIsCaughtByTheDeliveryMeasurement() public {
        ControllerReserveDouble double = new ControllerReserveDouble(usdc, makeAddr("skimSink"));
        MintRedeemController c = _doubleWiredController(double);

        double.setMode(ControllerReserveDouble.Mode.Honest);
        vm.startPrank(alice);
        usdc.approve(address(c), 100e6);
        assertEq(c.mint(100e6), 100e18, "POSITIVE CONTROL: the honest path must work");

        double.setMode(ControllerReserveDouble.Mode.SkimDeposit);
        usdc.approve(address(c), 100e6);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_DepositNotCustodied.selector, 100e6, 50e6, 100e18)
        );
        c.mint(100e6);
        vm.stopPrank();
    }

    /// @notice L2's complement. Cash DOES arrive (so the delivery measurement is satisfied) but
    ///         the reserve never recognises it as backing.
    ///
    ///         R18 AMENDMENT (finding F-1) — THIS USED TO BE CAUGHT BY THE DEFICIT RULE, AND THAT
    ///         WAS NOT GOOD ENOUGH. R16/R17 relied on `_assertDeficitNotWorsened` here, and this
    ///         test passed because the book carried NO surplus. The deficit rule is NON-WORSENING,
    ///         so on a book carrying surplus it catches only the part of the gap EXCEEDING
    ///         `backingValue() - totalUSDfr()` — the standing surplus silently pays for the rest,
    ///         and R17 made the protocol sit on such a surplus permanently by netting
    ///         `seniorSubParShortfall()` out of `mintableHeadroom()`. `mint` now measures the
    ///         BACKING DELTA directly, which no surplus can absorb, so this reserve is refused with
    ///         `Controller_DepositNotRecognized` BEFORE any level check is reached. The name is
    ///         kept so the R16 finding stays traceable; the guard that catches it has changed and
    ///         the surplus case is pinned by
    ///         `test_R18_F1_aStandingSurplusIsNoLongerABudgetForAnUncreditedDeposit`.
    function test_L2_aReserveThatTakesCashWithoutCreditingItIsCaughtByTheDeficitRule() public {
        ControllerReserveDouble double = new ControllerReserveDouble(usdc, makeAddr("skimSink"));
        MintRedeemController c = _doubleWiredController(double);

        double.setMode(ControllerReserveDouble.Mode.DepositWithoutCrediting);
        vm.startPrank(alice);
        usdc.approve(address(c), 100e6);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_DepositNotRecognized.selector, 100e18, 0)
        );
        c.mint(100e6);
        vm.stopPrank();
    }

    /// @notice The deficit rule on `redeem`, falsified. The redeemer is paid correctly but the
    ///         reserve writes backing down by twice the cash — a state the shipped ReserveManager
    ///         cannot reach, which is exactly why the falsifying case needs a double.
    function test_M4_redeemRefusesAReserveThatOverReleasesBacking() public {
        ControllerReserveDouble double = new ControllerReserveDouble(usdc, makeAddr("skimSink"));
        MintRedeemController c = _doubleWiredController(double);

        double.setMode(ControllerReserveDouble.Mode.Honest);
        vm.startPrank(alice);
        usdc.approve(address(c), 100e6);
        c.mint(100e6);
        assertEq(c.redeem(10e18), 10e6, "POSITIVE CONTROL: the honest redemption must work");

        double.setMode(ControllerReserveDouble.Mode.OverReleaseBacking);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_BackingInvariantViolated.selector, 80e18, 70e18)
        );
        c.redeem(10e18);
        vm.stopPrank();
    }

    // =====================================================================
    //  L3 / L4 — the two findings argued as DELIBERATE, made checkable
    // =====================================================================

    /// @notice L3, NOT "FIXED" — MADE VISIBLE, AND THE ARGUMENT IS IN THE CODE. USDfr worth less
    ///         than one whole USDC unit cannot be settled because USDC has six decimals. That is
    ///         a property of the settlement asset, not a lock: the residue is at most 1e-6 USD
    ///         and USDfr is freely transferable, so it aggregates. Rounding UP would pay out cash
    ///         that is not backed; a dust ledger would add storage and a claim mechanism for
    ///         sub-cent amounts. What WAS wrong is that the floor was invisible and, under
    ///         sub-par pricing, is no longer the constant 1e12. `previewRedeem` publishes it.
    function test_L3_theDustFloorIsQuotableRatherThanAHiddenRevert() public {
        _mintUSDfr(alice, 100e6);
        (uint256 out, uint256 burned) = controller.previewRedeem(1e12 - 1);
        assertEq(out, 0);
        assertEq(burned, 0, "a quote of zero must burn nothing");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_AmountTooSmall.selector, 1e12 - 1));
        controller.redeem(1e12 - 1);

        // the dust is not destroyed, and it aggregates: two sub-floor holdings redeem together
        assertEq(usdfr.balanceOf(alice), 100e18);
        (out,) = controller.previewRedeem(1e12);
        assertEq(out, 1, "one whole USDC unit is the floor while the protocol is whole");

        // and under sub-par pricing the floor RISES — which is the part that was invisible
        vm.startPrank(creditModule);
        reserves.recordDeployment(1, borrower, 50e6);
        reserves.recordPrincipalWritedown(1, 50e18);
        vm.stopPrank();
        (out, burned) = controller.previewRedeem(1e12);
        assertEq(out, 0, "at 50 cents one whole unit no longer settles");
        // AUDIT FIX (R17): assert BOTH components of the documented `(0, 0)` contract. R16 asserted
        // only `usdcOut`, which is why the `if (usdcOut == 0) usdfrIn = 0;` clamp in `_quoteRedeem`
        // survived a full-suite deletion mutation — a quote that says "you will be paid nothing"
        // while also saying "and 1e12 of your USDfr will be burned" is the defect it prevents.
        assertEq(burned, 0, "an unsettleable quote must burn nothing");
        (out, burned) = controller.previewRedeem(2e12);
        assertEq(out, 1, "and the published floor is exactly two units");
        assertEq(burned, 2e12, "a settleable quote must name the burn");
    }

    /// @notice L4, ARGUED AS DELIBERATE AND MADE INTO A CHECKED PROPERTY. USDC sent directly to
    ///         the controller is unrecoverable, and no sweep was added. The controller holds ZERO
    ///         USDC at rest — it pulls and forwards inside one call — so the only way to strand
    ///         cash is to send it to an address the protocol never publishes as a deposit
    ///         address. A governance sweep would add a privileged value-moving path to a contract
    ///         that is otherwise value-neutral at rest, and it would need a reentrancy lock whose
    ///         only threat model is a USDC with transfer callbacks, which canonical USDC does not
    ///         have — i.e. an unfalsifiable guard, which this round treats as a defect (M6). The
    ///         remedy of last resort already exists and is timelocked: the controller is UUPS.
    ///         What was missing is evidence for "holds nothing at rest", so here it is.
    function test_L4_theControllerHoldsNoUSDCAtRest() public {
        assertEq(usdc.balanceOf(address(controller)), 0);
        _mintUSDfr(alice, 100e6);
        assertEq(usdc.balanceOf(address(controller)), 0, "mint left cash behind");
        assertEq(
            usdc.allowance(address(controller), address(reserves)),
            0,
            "mint left a residual allowance; the delivery equality is what makes this provable"
        );
        vm.prank(alice);
        controller.redeem(40e18);
        assertEq(usdc.balanceOf(address(controller)), 0, "redeem left cash behind");
    }
}

/// @notice The credit-layer half: findings M1 (least privilege as DEPLOYED), M4 and M5 driven
///         through the real `WaterfallEngine` and `DefaultManager` rather than a stand-in.
contract Fix_R16_ControllerCreditLayer is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    bytes32 internal constant EVIDENCE = keccak256("R16-workout-memorandum");

    function _stakeVault(address who, uint256 amount) internal {
        _mintUSDfrTo(who, amount);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _recognizeMark(uint256 facilityId, uint256 amount) internal {
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(facilityId, amount, EVIDENCE);
    }

    /// @notice M1, LEAST PRIVILEGE AS ACTUALLY WIRED. `Deploy.s.sol` granted `CREDIT_ROLE` on the
    ///         controller to BOTH the engine and the manager, and that role gated `burnLoss` as
    ///         well as `mintYield`. Verified by grep across `src/`: every `burnLoss` call site is
    ///         in `DefaultManager`, passing `address(this)` or `$.vault`; `WaterfallEngine` only
    ///         ever calls `mintYield`. The engine therefore held HALF of the confiscation
    ///         composition for nothing. This fixture mirrors the deploy topology, so it pins the
    ///         wiring and not just the code.
    function test_M1_theWaterfallEngineHoldsNoBurnPowerAtAll() public {
        assertTrue(controller.hasRole(Roles.CREDIT_ROLE, address(waterfall)), "the engine must still mint yield");
        assertFalse(
            controller.hasRole(Roles.LOSS_BURNER_ROLE, address(waterfall)), "THE ENGINE STILL HOLDS A BURN POWER"
        );
        assertTrue(controller.hasRole(Roles.LOSS_BURNER_ROLE, address(defaultManager)), "the cascade must still burn");
        assertFalse(controller.hasRole(Roles.CREDIT_ROLE, address(defaultManager)), "the cascade does not mint yield");

        vm.prank(address(waterfall));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(waterfall), Roles.LOSS_BURNER_ROLE
            )
        );
        controller.burnLoss(address(vault), 1);

        // and the endpoint lists name nothing user-reachable
        assertFalse(controller.isLossSource(alice));
        assertFalse(controller.isYieldSink(alice));
        assertFalse(controller.isLossSource(address(waterfall)));
    }

    /// @notice M4. `distribute` hard-gated on the ABSOLUTE `backingInvariantHolds()`, so once any
    ///         loss was recognised the repayment path shut down entirely — including a
    ///         pure-principal repayment that returns cash and strictly IMPROVES the asset mix. A
    ///         protocol that refuses its borrowers' money because it is short is the opposite of
    ///         solvent. THE PROPERTY M4 SHIPPED FOR IS ACCEPTANCE, AND IT IS UNCHANGED.
    ///
    /// @dev    ═══ ASSERTION NARROWED (SWEEP-1 RMDM-F2, 2026-08-08) — DO NOT RESTORE `assertLt` ═══
    ///         This test used to close with `assertLt(backingDeficit(), deficitBefore)`. That was
    ///         an artefact of the OPTIMISTIC consumption convention in
    ///         `ReserveManager.recordPayment`, which released `min(principal, recognized)` of an
    ///         evidenced governance mark on every ordinary scheduled payment — so a 300,000
    ///         facility marked 120,000 was silently returned to its pre-mark carrying value by two
    ///         60,000 amortisation payments, with no adjudication and no evidence hash. Backing is
    ///         now FLAT across a collection on a marked facility, because the cash simply moves
    ///         from receivable into idle and the mark on what remains is unchanged.
    ///
    ///         WHAT M4 ASSERTS NOW: the repayment LANDS, and the closing gate — which is
    ///         NON-WORSENING since R16-M4/M5 — accepts a flat delta. If this test ever reverts
    ///         instead of settling, the R16 deadlock is back and the SWEEP-1 change must be
    ///         reverted rather than patched around.
    function test_M4_aPrincipalRepaymentIsAcceptedWhileTheProtocolIsShort() public {
        uint256 id = _liveFilmFacility(300_000e18);
        _recognizeMark(id, 200_000e18);
        assertGt(controller.backingDeficit(), 0, "the scenario must be under-backed");

        uint256 deficitBefore = controller.backingDeficit();
        uint256 idleBefore = reserves.idleReserve();
        _repay(id, 0, 60_000e18);

        assertEq(reserves.deployedTo(id), 240_000e18, "the repayment did not land");
        assertEq(reserves.idleReserve(), idleBefore + 60_000e18, "the cash did not reach idle");
        assertEq(controller.backingDeficit(), deficitBefore, "SWEEP-1: an ordinary collection moved the marked deficit");
    }

    /// @notice M5 CORE — THE PROTOCOL-NATIVE CURE THE FINDING SAID DID NOT EXIST. Under a
    ///         standing deficit the interest leg would previously revert (`mintYield` refuses to
    ///         widen the gap) and take the whole repayment down with it. `_routeInterest` now
    ///         clamps the distribution to `mintableHeadroom()` and WITHHOLDS the rest, so the
    ///         cash stays in the reserve and closes the hole. No governance action, no
    ///         recapitalisation, no keeper — and yield resumes by itself.
    function test_M5_withheldInterestCuresTheDeficitAndYieldResumesByItself() public {
        uint256 id = _liveFilmFacility(300_000e18);
        _stakeVault(alice, 50_000e18);
        _recognizeMark(id, 30_000e18);
        assertEq(controller.backingDeficit(), 30_000e18);

        uint256 vaultBefore = usdfr.balanceOf(address(vault));

        // 1. a payment smaller than the hole: nothing is distributed, all of it repairs backing.
        //    `_preparePayment` first, because `vm.expectEmit` binds to the NEXT call and the
        //    preparation emits its own transfers.
        IWaterfallEngine.Payment memory p1 = _preparePayment(id, 10_000e18, 0);
        vm.expectEmit(false, false, false, true, address(waterfall));
        emit IWaterfallEngine.InterestWithheldForBackingRepair(10_000e18, 20_000e18);
        vm.prank(servicer);
        waterfall.distribute(p1);
        assertEq(controller.backingDeficit(), 20_000e18, "interest did not repair the hole");
        assertEq(usdfr.balanceOf(address(vault)), vaultBefore, "yield leaked out of a short protocol");

        // 2. a payment that straddles the hole: the excess is distributed normally
        _repay(id, 30_000e18, 0);
        assertEq(controller.backingDeficit(), 0, "the hole did not close");
        assertGt(usdfr.balanceOf(address(vault)), vaultBefore, "yield did not resume once whole");

        // 3. fully repaired, the engine behaves exactly as it always did
        uint256 vaultMid = usdfr.balanceOf(address(vault));
        _repay(id, 5_000e18, 0);
        assertEq(controller.backingDeficit(), 0);
        assertGt(usdfr.balanceOf(address(vault)) - vaultMid, 0, "normal yield distribution did not resume");
    }

    /// @notice M5. The seniors bear the withholding, and their principal is NOT burned by it —
    ///         the exchange rate stops rising, it does not fall. That is the correct order:
    ///         `sUSDfr` is cascade layer 3 and a standing deficit is already their loss.
    function test_M5_withholdingSuspendsYieldWithoutImpairingSeniorPrincipal() public {
        uint256 id = _liveFilmFacility(300_000e18);
        _stakeVault(alice, 50_000e18);
        _recognizeMark(id, 30_000e18);

        uint256 rateBefore = vault.currentExchangeRate();
        _repay(id, 10_000e18, 0);
        assertEq(vault.currentExchangeRate(), rateBefore, "withholding must not move the senior rate");
    }
}
