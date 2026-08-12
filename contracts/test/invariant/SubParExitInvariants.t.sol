// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";
import {SubParExitHandler} from "./handlers/SubParExitHandler.sol";

/// @title AUDIT FIX (R18) — the sub-par exit and senior-retention accounting, stateful campaign
///
/// @notice THE GAP THIS CLOSES. R16-M3 introduced sub-par redemption and R17 extended it with a
///         par floor, an append-only `subParShortfall` field, its crystallisation arithmetic,
///         `Controller_SeniorRetentionBreached` and two new events — and NONE of it had any
///         stateful-fuzz coverage, contrary to CLAUDE.md §1.3's requirement that value and
///         accounting logic carry invariants.
///
///         AND IT WAS UNREACHABLE, NOT MERELY UNTESTED, WHICH IS THE SHARPER POINT. Four campaigns
///         assert the ABSOLUTE backing invariant `totalUSDfr() <= backingValue()`
///         (`TokenLayerInvariants`, `BackingFocusedInvariants`, `CreditInvariants`,
///         `RedemptionQueueInvariants`) and a fifth asserts `backingInvariantHolds()`. All five are
///         green in the baseline, so no campaign in the tree ever ENTERS a sub-par state. Every
///         handler that redeems calls the ONE-ARGUMENT form, which after R17 reverts under any
///         deficit, with `fail_on_revert = true`. The domain was closed twice over.
///
///         This campaign's backing property is therefore the NON-WORSENING rule — the rule
///         `MintRedeemController._assertDeficitNotWorsened` actually enforces — rather than the
///         absolute one. That is the only way to hold a property while standing in the region the
///         other campaigns exclude. Their fully-backed assumption is left intact and unweakened.
///
/// @dev ANTI-VACUITY IS PROVED BY CONSTRUCTION, NOT BY LUCK. R18 also found that
///      `ProductionQueueInvariants`'s `afterInvariant` vacuity assertions are SEED-DEPENDENT: they
///      assert after the fact that fuzzing happened to reach a witness, so an unlucky seed turns
///      the suite red under a message naming a `view` with no assertions in it. This file does not
///      repeat that mistake. `test_R18_antiVacuity_theSubParDomainIsDeterministicallyReachable`
///      below drives the handler's OWN actions in a fixed sequence and asserts each witness
///      directly, so the reachability claim holds regardless of seed, and the random campaign is
///      pure additional exploration rather than the sole evidence.
///
/// @dev WHAT IS NOT ENCODED HERE, AND WHERE IT NOW LIVES — R18's TEXT HERE IS CORRECTED, NOT
///      WEAKENED. R18 wrote that ADR-0034 decision Z's ordering property "cannot be asserted
///      against this code because decision Y ... is not implemented: the property is FALSE of the
///      shipped contract by construction, and an invariant written to pass against it would be an
///      invariant written to accept the defect". That was right at the time and it is now
///      OBSOLETE: ADR-0034 Y-bis (the ATOMIC JUNIOR DRAW) is implemented, and decision Z's
///      property is encoded as a stateful campaign in
///      `test/invariant/CascadeOrderedExitInvariants.t.sol`, on the FULL credit stack, with a
///      falsification test that reds it against a draw source that draws nothing.
///
///      IT IS NOT ENCODED *HERE* FOR A STRUCTURAL REASON, NOT AN EDITORIAL ONE. This campaign
///      stands on `TokenLayerFixture`, which has no `CuratorModule` and no backstop — there is no
///      junior capital in this fixture to be "unexhausted", so the property is not expressible
///      against it. What this campaign supplies remains the REACH: `yieldMint` mints yield in the
///      sub-par and retention domain, the custody x credit-layer seam ADR-0034 Z names as
///      unexercised across the whole suite.
contract SubParExitInvariants is TokenLayerFixture {
    SubParExitHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new SubParExitHandler(
            address(usdc),
            address(usdfr),
            address(reserves),
            address(controller),
            admin,
            creditModule,
            borrower,
            address(vault),
            [alice, bob]
        );
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = SubParExitHandler.mintPar.selector;
        selectors[1] = SubParExitHandler.deployPrincipal.selector;
        selectors[2] = SubParExitHandler.markDown.selector;
        selectors[3] = SubParExitHandler.releaseMark.selector;
        selectors[4] = SubParExitHandler.subParExit.selector;
        selectors[5] = SubParExitHandler.yieldMint.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice INVARIANT (CLAUDE.md §1.3, backing). The rule the contract actually enforces: no
    ///         operation WIDENS `deficit = max(0, totalSupply - backingValue)`. The absolute form
    ///         cannot be asserted in this domain — the campaign deliberately stands inside it —
    ///         and asserting the absolute form is precisely why the other five campaigns could
    ///         never reach any of this code.
    function invariant_R18_noOperationWidensTheDeficit() public view {
        assertEq(handler.gDeficitWorsened(), 0, "AN EXIT WIDENED THE BACKING DEFICIT");
    }

    /// @notice INVARIANT (R16-M3, the property `_quoteRedeem`'s NatSpec promises and the ONLY one
    ///         it promises). Every rounding in the quote is DOWN, so the instantaneous coverage
    ///         ratio left behind for the holders who did NOT redeem is unchanged or better across
    ///         every exit. Previously this was a single deterministic fuzz test
    ///         (`testFuzz_M3_aSubParExitNeverWorsensTheRatioForTheHoldersWhoStayed`); §1.3 requires
    ///         it as a stateful property.
    function invariant_R18_aSubParExitNeverWorsensTheRatioForTheHoldersWhoStayed() public view {
        assertEq(handler.gRatioWorsenedForStayers(), 0, "AN EXIT LOWERED THE COVERAGE RATIO FOR THE STAYERS");
    }

    /// @notice INVARIANT (R17). `seniorSubParShortfall()` is MONOTONICALLY NON-DECREASING. It has
    ///         no setter on purpose — "a governance lever that could lower it would restore the
    ///         leak in one transaction" — so this is the property that a future setter, or an
    ///         off-by-one in the crystallisation arithmetic, would break.
    function invariant_R18_theSeniorRetentionIsMonotonic() public view {
        assertEq(handler.gRetentionWentBackwards(), 0, "seniorSubParShortfall() WENT BACKWARDS");
        assertGe(
            controller.seniorSubParShortfall(),
            handler.gMaxRetentionSeen(),
            "seniorSubParShortfall() FELL BELOW A VALUE IT HAD ALREADY PUBLISHED"
        );
    }

    /// @notice INVARIANT (CLAUDE.md §3.1 — the on-chain register must be reconstructable purely
    ///         from events). The handler recomputes each crystallisation independently, from
    ///         `usdfrBurned - usdcOut * 1e12` measured across the call, exactly as an indexer
    ///         reading `SeniorShortfallCrystallised` would. The running sum must equal the storage
    ///         field to the wei.
    function invariant_R18_theCrystallisedSumReconstructsTheRetention() public view {
        assertEq(
            controller.seniorSubParShortfall(),
            handler.gCrystallisedSum(),
            "THE RETENTION CANNOT BE RECONSTRUCTED FROM THE CRYSTALLISATION EVENTS"
        );
    }

    /// @notice INVARIANT (R17, `Controller_SlippageExceeded`). A haircut is an ELECTION, never a
    ///         silent impairment: no settlement is ever below the floor the caller named. The
    ///         handler tries floors from zero to the full quote on every exit.
    function invariant_R18_noHolderIsEverSilentlyHaircut() public view {
        assertEq(handler.gSilentHaircuts(), 0, "A REDEMPTION SETTLED BELOW THE FLOOR THE HOLDER NAMED");
    }

    /// @notice INVARIANT (R17 / R18). `mintableHeadroom()` never exceeds the surplus net of the
    ///         retention. This is what `WaterfallEngine._routeInterest` and, since R18,
    ///         `WaterfallEngine.fund` both size themselves off, so an over-statement here is paid
    ///         out of the reserve and cannot be recovered.
    function invariant_R18_headroomNeverExceedsSurplusNetOfRetention() public view {
        uint256 backing = controller.recognizedBackingValue();
        uint256 claimed = controller.totalUSDfr() + controller.seniorSubParShortfall();
        uint256 permitted = backing > claimed ? backing - claimed : 0;
        assertLe(controller.mintableHeadroom(), permitted, "THE HEADROOM OVER-STATED WHAT MAY BE MINTED");
    }

    // =====================================================================
    //  Anti-vacuity — deterministic, by construction, and not seed-dependent
    // =====================================================================

    /// @notice Every witness the campaign above needs, reached by driving the handler's OWN actions
    ///         in a fixed sequence. If a future change makes the sub-par domain unreachable — which
    ///         is exactly how it came to have no coverage in the first place — this goes RED with a
    ///         named reason, rather than the campaign silently asserting over an empty domain.
    function test_R18_antiVacuity_theSubParDomainIsDeterministicallyReachable() public {
        handler.mintPar(0, 200_000e6);
        assertGt(usdfr.totalSupply(), 0, "VACUOUS: no supply was ever minted");

        handler.deployPrincipal(50_000e6);
        assertGt(reserves.deployedTo(1), 0, "VACUOUS: no principal was ever deployed");

        handler.markDown(20_000e18);
        assertGt(handler.gMarks(), 0, "VACUOUS: no conservative mark ever landed");
        assertGt(controller.backingDeficit(), 0, "VACUOUS: the protocol never went sub-par");

        handler.subParExit(0, 10_000e18, 10_000);
        assertGt(handler.gSubParExits(), 0, "VACUOUS: no sub-par exit ever settled");
        assertGt(controller.seniorSubParShortfall(), 0, "VACUOUS: no haircut was ever crystallised");
        assertEq(
            controller.seniorSubParShortfall(),
            handler.gCrystallisedSum(),
            "the independent reconstruction disagreed with the contract on the very first exit"
        );

        // The retention must actually BIND something, or the campaign's headroom invariant is
        // asserting over a quantity that is never non-zero.
        handler.releaseMark(type(uint256).max);
        handler.yieldMint(30_000e6, true);
        assertGt(handler.gRetentionRefusals() + handler.gYieldMints(), 0, "VACUOUS: the yield seam was never reached");
        assertEq(handler.gRetentionWentBackwards(), 0);
        assertEq(handler.gSilentHaircuts(), 0);
        assertEq(handler.gRatioWorsenedForStayers(), 0);
        assertEq(handler.gDeficitWorsened(), 0);
    }
}
