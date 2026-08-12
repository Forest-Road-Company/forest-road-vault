// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {Config} from "../../src/libraries/Config.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @title ADV-1 — the senior-impairment protocol-fee withholding
/// @notice FALSIFIES `WaterfallEngine._withholdFeeForSeniorImpairment` and the two order-critical
///         lines above its call site in `_routeInterest`. Every test here is named in that
///         function's NatSpec as the test that catches a specific mutation; if you delete or
///         weaken one, the corresponding guard becomes silently deletable.
///
/// @dev THE FINDING. `_routeInterest`'s R16-M5 withholding clamp is sized off
///      `MintRedeemController.mintableHeadroom()`, which nets the RECORDED impairment mark, the
///      R4-01 custody shortfall and `seniorSubParShortfall()` — and NOTHING from the CREDIT layer.
///      `DefaultManager.declareDefault` never touches `ReserveManager`, so a declared default
///      leaves the facility at FACE: `recognizedDeficit()` reads 0, headroom is full, and the clamp
///      withholds NOTHING IN EXACTLY THE STATE IT WAS WRITTEN FOR. That falsified two sentences of
///      that function's own NatSpec verbatim ("Forest Road does not collect a performance fee out
///      of a shortfall"; "SENIORS BEAR THE WITHHOLDING, AND THAT IS THE CORRECT ORDER"), and it is
///      ADR-0034 cascade ordering inverted on the YIELD path: the fee recipient holds plain USDfr,
///      is not a layer of the §1.3 cascade, and `realizeLoss` can never reach it.
///
///      THE STOCK/FLOW RULE UNDER TEST. `pendingSeniorImpairment()` is a CUMULATIVE STOCK in units
///      of declared/past-due principal. The gross fee is a PER-TRANSACTION FLOW. The stock is used
///      ONLY AS A CEILING ON the flow — `withheld = min(feeGross, residual)` — and is NEVER
///      subtracted from the flow's BASIS (`distributable`). Netting the stock off
///      `mintableHeadroom()`, which IS the basis, is the shape that broke the previous attempt at
///      this fix (~20 differential reference-model assertions plus an invariant). `test_ADV1_G04`
///      pins the ceiling shape specifically; `test_ADV1_G02` pins the untouched basis.
contract FixADV1SeniorImpairmentFeeWithholding is CreditLayerFixture {
    bytes32 internal constant EV = keccak256("adv1");

    /// @dev MERGE 2026-08-08 (ADV-1 x G2W). Puts real senior capital in the vault. Needed because
    ///      OWNER DECISION 2026-08-07 clamps the UNATTESTED past-due cohort to
    ///      `IsUSDfr(vault).totalAssets()` — the amount `realizeLoss` could actually burn — so a
    ///      past-due mark against an empty vault now correctly marks at ZERO and any test about
    ///      past-due griefing has to stake first or it is testing nothing.
    function _stakeSenior(address who, uint256 amount) internal {
        _mintUSDfrTo(who, amount);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
    }

    /// @dev A 300,000e18 declared default with BOTH junior layers empty, plus a live performing
    ///      facility `b` that can pay interest. Returns `b`.
    function _defaultWithEmptyJuniorLayers() internal returns (uint256 b) {
        uint256 a = _liveFilmFacility(300_000e18);
        _mintUSDfrTo(alice, 400_000e18);
        b = _originateFilm(BORROWER_2, STATE_GA, 200_000e18);
        _fundFacility(b, 200_000e18);
        _attestDefault(a);
        vm.prank(servicer);
        defaultManager.declareDefault(a, FILM_REF);
        assertEq(curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS), 0, "layer 1 must be empty");
        assertEq(backstopMock.coverageCapacity(), 0, "layer 2 must be empty");
        assertEq(defaultManager.pendingSeniorImpairment(), 300_000e18, "the whole 300k is senior residual");
        assertEq(controller.recognizedDeficit(), 0, "the whole point: the RECORDED book reads whole");
    }

    // ── G01: the guard itself ────────────────────────────────────────────

    /// @notice G01. THE DELETION MUTATION FOR `_withholdFeeForSeniorImpairment`. Remove the
    ///         `fee = _withholdFeeForSeniorImpairment($, fee);` line from `_routeInterest` — or make
    ///         the helper `return feeGross` unconditionally — and this goes RED with the shipped
    ///         defect's exact number, 1,000e18 extracted out of an open 300,000e18 senior hole.
    function test_ADV1_G01_theInterestFeeIsWithheldWhileAnUnabsorbedSeniorResidualStands() public {
        uint256 b = _defaultWithEmptyJuniorLayers();

        uint256 feeBefore = usdfr.balanceOf(feeRecipient);
        _repay(b, 10_000e18, 0);

        assertEq(
            usdfr.balanceOf(feeRecipient) - feeBefore,
            0,
            "ADV-1: a performance fee was taken out of an unabsorbed senior shortfall"
        );
        // The mark is a CREDIT-layer stock and nothing here reduces it. Stated so the
        // "it self-cures like R16-M5" misreading cannot take hold.
        assertEq(defaultManager.pendingSeniorImpairment(), 300_000e18, "the residual is a stock and does not fall");
    }

    // ── G02: retained, not redirected ────────────────────────────────────

    /// @notice G02. THE ORDER MUTATION. `toVault` is computed off the GROSS fee, on the line BEFORE
    ///         the withholding. Swap those two statements in `_routeInterest` and the withheld fee
    ///         is REDIRECTED to the `sUSDfr` vault instead of retained: the vault delta becomes
    ///         10,000e18, total minted returns to `distributable`, backing stops improving and the
    ///         senior exchange rate jumps by the withheld amount. This test pins all three legs at
    ///         once — the fee, the vault, and the supply — so no single reordering survives it.
    ///
    ///         IT IS ALSO THE STOCK/FLOW WITNESS. `toVault` here is bit-for-bit what it was before
    ///         ADV-1, which is the property that keeps the differential reference model
    ///         (`CreditHandler.repay`) and every `sUSDfr` fee/HWM/vesting path untouched.
    function test_ADV1_G02_theWithheldFeeIsRetainedAsBackingAndNotRedirectedToTheVault() public {
        uint256 b = _defaultWithEmptyJuniorLayers();

        uint256 feeBefore = usdfr.balanceOf(feeRecipient);
        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        uint256 supplyBefore = usdfr.totalSupply();
        uint256 backingBefore = controller.recognizedBackingValue();

        _repay(b, 10_000e18, 0);

        assertEq(usdfr.balanceOf(feeRecipient) - feeBefore, 0, "G02: the fee leg must be zero");
        assertEq(usdfr.balanceOf(address(vault)) - vaultBefore, 9_000e18, "G02: the withheld fee was REDIRECTED");
        assertEq(usdfr.totalSupply() - supplyBefore, 9_000e18, "G02: total minted must exclude the withheld fee");
        // 10,000e18 of cash landed; 9,000e18 of USDfr was minted against it. The 1,000e18 gap is the
        // withholding, standing as unencumbered backing — the cure the R16-M5 paragraph advertises,
        // now actually running on the credit-layer basis.
        assertEq(controller.recognizedBackingValue() - backingBefore, 10_000e18, "G02: the cash must all land");
        assertEq(
            (controller.recognizedBackingValue() - backingBefore) - (usdfr.totalSupply() - supplyBefore),
            1_000e18,
            "G02: the withholding did not become over-collateralisation"
        );
    }

    // ── G03: cascade awareness ───────────────────────────────────────────

    /// @notice G03. THE BASIS MUTATION. The ceiling is `pendingSeniorImpairment()`, which ALREADY
    ///         nets curator first-loss (layer 1) and the sGROVE backstop (layer 2). Replace it with
    ///         any gross measure — `performanceFeeImpairment()`, a sum of
    ///         `declaredDefaultedPrincipal`, or a bare "is any facility defaulted" flag — and this
    ///         goes RED, because here junior capital covers the WHOLE default and there is no
    ///         senior shortfall for Forest Road's fee to be taken out of.
    ///
    ///         This is the liveness half of the fix: a default that the cascade absorbs must NOT
    ///         suspend protocol revenue. Without it the clamp would be an indefinite, permissionless
    ///         revenue freeze on any book that ever had a default.
    function test_ADV1_G03_curatorFirstLossAbsorbingTheDefaultLeavesTheFeePayable() public {
        uint256 a = _liveFilmFacility(300_000e18);
        _mintUSDfrTo(alice, 400_000e18);
        uint256 b = _originateFilm(BORROWER_2, STATE_GA, 200_000e18);
        _fundFacility(b, 200_000e18);
        // Layer 1 fully covers the coming default.
        _postFirstLoss(anchorCurator, Config.CLASS_FILM_TAX_CREDITS, 300_000e18);
        _attestDefault(a);
        vm.prank(servicer);
        defaultManager.declareDefault(a, FILM_REF);

        assertGt(defaultManager.performanceFeeImpairment(), 0, "G03: the GROSS impairment is non-zero");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "G03: junior capital absorbs the whole of it");

        uint256 feeBefore = usdfr.balanceOf(feeRecipient);
        _repay(b, 10_000e18, 0);
        assertEq(
            usdfr.balanceOf(feeRecipient) - feeBefore,
            1_000e18,
            "G03: the fee was withheld even though the cascade absorbs the whole default"
        );
    }

    // ── G04: a ceiling, not a cliff ──────────────────────────────────────

    /// @notice G04. THE BINARY MUTATION, AND THE STOCK/FLOW SHAPE. `withheld = min(feeGross,
    ///         residual)`. Replace it with `withheld = feeGross` (a binary "any residual ⇒ no fee"
    ///         gate) and this goes RED. Here layer 1 absorbs 299,000e18 of a 300,000e18 default, so
    ///         the residual is 1,000e18 while the gross fee on a 100,000e18 receipt is 10,000e18:
    ///         exactly 1,000e18 is withheld and the 9,000e18 excess remains payable.
    ///
    ///         WHY A CEILING RATHER THAN A CLIFF. `DefaultManager.markPastDue` is PERMISSIONLESS, so
    ///         a cliff at one wei of residual would hand any address a switch on all Forest Road
    ///         revenue. A ceiling degrades continuously and is the honest statement of the rule:
    ///         you may not take a fee OUT OF the hole; if your fee exceeds the hole you may keep the
    ///         excess.
    function test_ADV1_G04_theResidualIsACeilingOnTheFeeNotABinaryGate() public {
        uint256 a = _liveFilmFacility(300_000e18);
        _mintUSDfrTo(alice, 400_000e18);
        uint256 b = _originateFilm(BORROWER_2, STATE_GA, 200_000e18);
        _fundFacility(b, 200_000e18);
        _postFirstLoss(anchorCurator, Config.CLASS_FILM_TAX_CREDITS, 299_000e18);
        _attestDefault(a);
        vm.prank(servicer);
        defaultManager.declareDefault(a, FILM_REF);
        assertEq(defaultManager.pendingSeniorImpairment(), 1_000e18, "G04: residual must sit BELOW the gross fee");

        uint256 feeBefore = usdfr.balanceOf(feeRecipient);
        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        _repay(b, 100_000e18, 0);

        // gross fee 10,000e18, ceiling 1,000e18 => 9,000e18 payable.
        assertEq(usdfr.balanceOf(feeRecipient) - feeBefore, 9_000e18, "G04: the ceiling is not min(fee, residual)");
        assertEq(usdfr.balanceOf(address(vault)) - vaultBefore, 90_000e18, "G04: the senior leg must be unchanged");
    }

    // ── G05: the log reconstructs the split ──────────────────────────────

    /// @notice G05. CLAUDE.md §3.1 — the register must be reconstructable from events alone. The
    ///         `Distributed` event's `fee` is now the NET minted amount, so the gross skim is only
    ///         recoverable as `fee + withheld`. Delete the
    ///         `ProtocolFeeWithheldForSeniorImpairment` emit and this goes RED. It also pins the
    ///         SECOND parameter: publishing the residual is what lets an indexer tell this cause
    ///         apart from `InterestWithheldForBackingRepair`, whose `deficitRemaining` is ZERO in
    ///         exactly this state.
    function test_ADV1_G05_theWithholdingEventReconstructsTheGrossFee() public {
        uint256 b = _defaultWithEmptyJuniorLayers();
        IWaterfallEngine.Payment memory payment = _preparePayment(b, 10_000e18, 0);

        vm.expectEmit(false, false, false, true, address(waterfall));
        emit IWaterfallEngine.ProtocolFeeWithheldForSeniorImpairment(1_000e18, 300_000e18);
        vm.expectEmit(true, true, true, true, address(waterfall));
        emit IWaterfallEngine.Distributed(payment.tokenId, payment.paymentId, payment.payer, 10_000e18, 0, 0, 9_000e18);
        vm.prank(servicer);
        waterfall.distribute(payment);
    }

    // ── G06: the tolerated unwired state ─────────────────────────────────

    /// @notice G06. The zero-manager branch, which exists only because `Deploy.s.sol` and the
    ///         fixtures construct the DefaultManager AFTER the engine. Unwired withholds nothing
    ///         and behaves exactly as the pre-ADV-1 code did. Pinned so the branch is covered and
    ///         so the tolerated state is a documented, tested one rather than an accident —
    ///         `Validate.s.sol` asserts the production wiring separately.
    function test_ADV1_G06_anUnwiredDefaultManagerWithholdsNothing() public {
        uint256 b = _defaultWithEmptyJuniorLayers();
        vm.prank(admin);
        waterfall.setDefaultManager(address(0));

        uint256 feeBefore = usdfr.balanceOf(feeRecipient);
        _repay(b, 10_000e18, 0);
        assertEq(usdfr.balanceOf(feeRecipient) - feeBefore, 1_000e18, "G06: unwired must be exactly the old path");
    }

    // ── G07: the griefing analysis, executed ─────────────────────────────

    /// @notice G07. THE REASON THE VAULT LEG IS DELIBERATELY LEFT ALONE, EXECUTED RATHER THAN
    ///         ASSERTED IN PROSE. `markPastDue` is PERMISSIONLESS and marks a facility's WHOLE
    ///         principal. An arbitrary address therefore moves `pendingSeniorImpairment()` from 0 to
    ///         300,000e18 with no role at all. Under the shipped fix that zeroes Forest Road's own
    ///         fee — Forest Road sets the marking policy, so it is the right party to bear a
    ///         conservative rule it controls — and leaves third-party senior yield fully intact.
    ///
    ///         IF SOMEONE EXTENDS THE WITHHOLDING TO THE VAULT LEG, THIS TEST GOES RED AND THAT IS
    ///         THE POINT: it would mean any unpermissioned caller can destroy 100% of protocol-wide
    ///         senior income for the whole window one facility sits overdue, and withheld value is
    ///         forgone, not deferred. That is a Forest Road economics decision (brief Part 4), not
    ///         an implementation detail. Do not delete this test to make such a change pass.
    function test_ADV1_G07_aPermissionlessPastDueMarkWithholdsTheFeeButNeverTheSeniorYield() public {
        uint256 a = _liveFilmFacility(300_000e18);
        _mintUSDfrTo(alice, 400_000e18);
        uint256 b = _originateFilm(BORROWER_2, STATE_GA, 200_000e18);
        _fundFacility(b, 200_000e18);
        // MERGE 2026-08-08 (ADV-1 x G2W). Senior capital has to actually be at risk for this test
        // to be about anything. It used to run with NOTHING staked, where the pre-G2W mark still
        // read the past-due pool's full 300,000e18 face. OWNER DECISION 2026-08-07 clamps the
        // unattested cohort to what `realizeLoss` could actually burn out of the vault, which on an
        // empty vault is ZERO — so the old precondition asserted a griefing scenario that the
        // merged build makes unreachable, and it went red for the RIGHT reason. Staking restores
        // the scenario the test is about instead of relaxing the number it asserts.
        _stakeSenior(bob, 400_000e18);

        // No role, no attestation, no governance act — just the maturity clock and any address.
        vm.warp(block.timestamp + 400 days);
        vm.prank(makeAddr("any-passer-by"));
        defaultManager.markPastDue(a);
        // 300,000e18 of past-due principal, clamped to the 400,000e18 the vault could burn (not
        // binding) and then charged at the launch relief weight because the mark just landed:
        // 300,000e18 * 5,000bps = 150,000e18. Recomputed here from the G2W literals rather than
        // read back from the contract, so a mutation of either the clamp or the weight reds here.
        assertEq(defaultManager.pendingSeniorImpairment(), 150_000e18, "G07 precondition: the mark landed");

        uint256 feeBefore = usdfr.balanceOf(feeRecipient);
        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        _repay(b, 10_000e18, 0);

        assertEq(usdfr.balanceOf(feeRecipient) - feeBefore, 0, "G07: Forest Road's fee bears the mark");
        assertEq(
            usdfr.balanceOf(address(vault)) - vaultBefore,
            9_000e18,
            "G07: senior yield must NOT be destructible by an unpermissioned call"
        );
    }

    // ── G08: it composes with the R16-M5 clamp rather than fighting it ───

    /// @notice G08. The two clamps compose AS A FLOOR: R16-M5 shrinks the BASIS (`distributable`),
    ///         ADV-1 caps the FEE drawn off that basis. Here BOTH are live — a recognised mark opens
    ///         a real deficit while a declared default leaves an unabsorbed residual — and the
    ///         result is the harder of the two, with neither able to push a mint negative. If a
    ///         later change makes these two subtract from one another instead of composing, the fee
    ///         goes negative-then-reverts or the vault leg drifts, and this test catches it.
    function test_ADV1_G08_theTwoClampsComposeAsAFloorAndNeitherUnderflows() public {
        uint256 a = _liveFilmFacility(300_000e18);
        _mintUSDfrTo(alice, 400_000e18);
        uint256 b = _originateFilm(BORROWER_2, STATE_GA, 200_000e18);
        _fundFacility(b, 200_000e18);
        _attestDefault(a);
        vm.prank(servicer);
        defaultManager.declareDefault(a, FILM_REF);
        // Governance also recognises a 5,000e18 conservative mark, so the RECORDED book is short too.
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(a, 5_000e18, EV);
        assertEq(controller.recognizedDeficit(), 5_000e18, "G08 precondition: R16-M5 has something to bite on");
        assertGt(defaultManager.pendingSeniorImpairment(), 0, "G08 precondition: ADV-1 has something to bite on");

        uint256 feeBefore = usdfr.balanceOf(feeRecipient);
        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        _repay(b, 10_000e18, 0);

        // Basis: 10,000e18 cash landed against a 5,000e18 hole => headroom 5,000e18, so
        // `distributable == 5,000e18`. Gross fee 500e18, fully withheld by the ADV-1 ceiling.
        assertEq(usdfr.balanceOf(feeRecipient) - feeBefore, 0, "G08: fee must be zero under both clamps");
        assertEq(usdfr.balanceOf(address(vault)) - vaultBefore, 4_500e18, "G08: the R16-M5 basis must still govern");
        // 10,000e18 in, 4,500e18 minted => the deficit closes by 5,500e18, not 5,000e18: the extra
        // 500e18 is the ADV-1 withholding doing the same repair on top of the R16-M5 one.
        assertEq(controller.recognizedDeficit(), 0, "G08: the receipt must repair the recognised hole");
    }

    // ── G09: the MERGE seam between ADV-1 and G2W ────────────────────────

    /// @notice G09. WRITTEN AT THE THREE-WAY MERGE, 2026-08-08, BECAUSE NEITHER PARENT TREE COULD
    ///         CONTAIN IT. ADV-1's fee ceiling is `pendingSeniorImpairment()`. OWNER DECISION
    ///         2026-08-07 (G2W) changed what that number MEANS for the unattested cohort: it is now
    ///         clamped to the vault's absorption capacity and then discounted by the ramped weight.
    ///         The two fixes therefore meet on one value, and the correct composition is that the
    ///         ADV-1 ceiling is the POST-G2W number — Forest Road forgoes fee only up to the charge
    ///         the cascade could genuinely execute, not up to the unattested pool's gross face.
    ///
    ///         THE SIZING IS DELIBERATE AND IS THE WHOLE TEST. The past-due pool is 300,000e18 —
    ///         three hundred times the gross fee — while the vault holds only 1,000e18, so the G2W
    ///         clamp binds hard and the relief weight halves what is left: the ceiling is 500e18,
    ///         strictly BETWEEN zero and the 1,000e18 gross fee. So:
    ///           - a build that took the GROSS past-due pool as the ceiling pays a fee of ZERO;
    ///           - a build that dropped the G2W weight pays ZERO (clamp alone gives 1,000e18);
    ///           - a build that dropped the ADV-1 withholding pays the full 1,000e18;
    ///           - only the correctly composed build pays exactly 500e18.
    ///         Four distinguishable outcomes on one assertion. DO NOT round the numbers off.
    function test_ADV1_G09_theFeeCeilingIsTheG2WWeightedMarkNotTheGrossPastDuePool() public {
        uint256 a = _liveFilmFacility(300_000e18);
        _mintUSDfrTo(alice, 400_000e18);
        uint256 b = _originateFilm(BORROWER_2, STATE_GA, 200_000e18);
        _fundFacility(b, 200_000e18);
        // A deliberately thin senior book: the G2W executable clamp is what binds, not the pool.
        _stakeSenior(bob, 1_000e18);

        vm.warp(block.timestamp + 400 days);
        vm.prank(makeAddr("any-passer-by"));
        defaultManager.markPastDue(a);
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            500e18,
            "G09 precondition: clamped to the vault (1,000e18) then halved by the launch relief weight"
        );

        uint256 feeBefore = usdfr.balanceOf(feeRecipient);
        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        _repay(b, 10_000e18, 0);

        // Gross fee 1,000e18; ceiling 500e18; so exactly half of Forest Road's fee is withheld.
        assertEq(
            usdfr.balanceOf(feeRecipient) - feeBefore,
            500e18,
            "G09: the ADV-1 ceiling must be the G2W-weighted mark, not the gross past-due pool"
        );
        // And the vault leg is still sized off the GROSS fee — the ADV-1 stock/flow rule survives
        // the merge untouched.
        assertEq(usdfr.balanceOf(address(vault)) - vaultBefore, 9_000e18, "G09: the senior leg must not move");
    }
}
