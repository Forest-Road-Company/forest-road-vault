// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {Config} from "../../src/libraries/Config.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @dev ADVERSARIAL PROBES against WaterfallEngine.distribute's non-worsening closing gate
///      and the ADR-0034 cascade order. These began as OBSERVATIONAL probes.
///
///      P1, P6 and P7 ARE NO LONGER OBSERVATIONAL: their finding (ADV-1 — the R16-M5 withholding
///      clamp is blind to `DefaultManager.pendingSeniorImpairment()`, so it withholds nothing in
///      exactly the state it was written for) was FIXED on 2026-08-08, and the three tests have had
///      their assertions INVERTED rather than deleted or relaxed. They now pin the fix. Each says so
///      at its own docstring; read those before changing a constant here.
///
///      P2, P4, P5, P8 and P9 REMAIN OBSERVATIONAL and their findings REMAIN OPEN — in particular
///      P8 (the ORIGINATION fee leg is still blind, MRC residualRisk 5) and P2 (a par exit against a
///      marked-down book, ADR-0034). Do not read this file as "all green means all clear".
contract ADV_GateAndCascade is CreditLayerFixture {
    bytes32 internal constant EV = keccak256("adv-gate");
    address internal sink = makeAddr("adv-sink");

    function _recognisedDeficit() internal view returns (uint256) {
        uint256 s = controller.totalUSDfr();
        uint256 b = controller.recognizedBackingValue();
        return s > b ? s - b : 0;
    }

    // ── P1: fee + yield paid out while a senior impairment stands unabsorbed ──
    /// @dev INVERTED, LOUDLY (audit ADV-1, 2026-08-08). THIS TEST USED TO ASSERT THE DEFECT AS IF
    ///      IT WERE A SAFETY PROPERTY. Its closing line was
    ///      `assertGt(usdfr.balanceOf(feeRecipient) - feeBefore, 0, "P1: no protocol fee was taken")`
    ///      — i.e. it went RED if the protocol correctly declined to take a performance fee out of
    ///      an unabsorbed senior shortfall. It was written as an OBSERVATIONAL probe (see the
    ///      contract header) and its finding is now FIXED, so the assertion is inverted rather than
    ///      deleted: the scenario it reaches is exactly the one the fix must hold in, and keeping it
    ///      pins the fix. DO NOT "RESTORE" THE `assertGt` — that reinstates ADV-1.
    ///      Falsifies `WaterfallEngine._withholdFeeForSeniorImpairment`.
    function test_P1_protocolFeeIsPaidWhileSeniorImpairmentStands() public {
        // Facility A: will default. Facility B: performing, pays interest.
        uint256 a = _liveFilmFacility(300_000e18);
        _mintUSDfrTo(alice, 400_000e18);
        uint256 b = _originateFilm(BORROWER_2, STATE_GA, 200_000e18);
        _fundFacility(b, 200_000e18);

        // stake so the vault exists as a sink
        _attestDefault(a);
        vm.prank(servicer);
        defaultManager.declareDefault(a, FILM_REF);

        uint256 pending = defaultManager.pendingSeniorImpairment();
        emit log_named_uint("pendingSeniorImpairment", pending);
        emit log_named_uint("curator pool film", curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS));
        emit log_named_uint("backstop capacity", backstopMock.coverageCapacity());
        emit log_named_uint("recognisedDeficit", _recognisedDeficit());
        emit log_named_uint("mintableHeadroom", controller.mintableHeadroom());

        uint256 feeBefore = usdfr.balanceOf(feeRecipient);
        uint256 vaultBefore = usdfr.balanceOf(address(vault));

        _repay(b, 10_000e18, 0);

        emit log_named_uint("feeRecipient USDfr delta", usdfr.balanceOf(feeRecipient) - feeBefore);
        emit log_named_uint("vault USDfr delta", usdfr.balanceOf(address(vault)) - vaultBefore);
        emit log_named_uint("pendingSeniorImpairment after", defaultManager.pendingSeniorImpairment());

        assertGt(pending, 0, "P1 precondition: a senior impairment must stand");
        assertEq(curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS), 0, "P1 precondition: layer 1 empty");
        assertEq(backstopMock.coverageCapacity(), 0, "P1 precondition: layer 2 empty");
        // AUDIT FIX (ADV-1). The fee recipient is OUTSIDE the §1.3 cascade and `realizeLoss` can
        // never reach it (test_P7/test_P9), so a performance fee taken here would be senior to all
        // three layers. It must be ZERO — not merely smaller.
        assertEq(
            usdfr.balanceOf(feeRecipient) - feeBefore,
            0,
            "ADV-1 REGRESSED: a protocol fee was taken out of an unabsorbed senior shortfall"
        );
        // ...and the senior leg is deliberately UNTOUCHED. See the ADV-1 block on
        // `WaterfallEngine._routeInterest` for the four reasons. If this line goes red, someone
        // extended the withholding to the vault without the Forest Road economics decision.
        assertEq(usdfr.balanceOf(address(vault)) - vaultBefore, 9_000e18, "ADV-1: the senior leg must be unchanged");
    }

    // ── P2: unstaked USDfr redeems at PAR while the same book is marked down ──
    function test_P2_unstakedRedeemsAtParWhileSeniorMarkedDown() public {
        uint256 a = _liveFilmFacility(300_000e18);
        _mintUSDfrTo(alice, 100_000e18);
        _attestDefault(a);
        vm.prank(servicer);
        defaultManager.declareDefault(a, FILM_REF);

        uint256 pending = defaultManager.pendingSeniorImpairment();
        (uint256 outUnits,) = controller.previewRedeem(1_000e18);
        emit log_named_uint("pendingSeniorImpairment", pending);
        emit log_named_uint("previewRedeem usdcOut for 1000e18", outUnits);
        assertGt(pending, 0, "P2 precondition");
    }

    // ── P3: liveness — full cash recovery on a defaulted facility must settle ──
    function test_P3_fullRecoveryOnDefaultedFacilitySettles() public {
        uint256 a = _liveFilmFacility(300_000e18);
        _mintUSDfrTo(alice, 100_000e18);
        _attestDefault(a);
        vm.prank(servicer);
        defaultManager.declareDefault(a, FILM_REF);

        _repay(a, 0, 300_000e18);
        assertEq(reserves.deployedTo(a), 0, "P3: recovery did not settle");
        assertEq(uint8(bridge.facility(a).state), uint8(ClaimBridge.LoanState.Resolved), "P3: state");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "P3: mark not released");
    }

    // ── P4: liveness — interest on a defaulted facility ──
    function test_P4_interestOnDefaultedFacility() public {
        uint256 a = _liveFilmFacility(300_000e18);
        _mintUSDfrTo(alice, 100_000e18);
        _attestDefault(a);
        vm.prank(servicer);
        defaultManager.declareDefault(a, FILM_REF);

        uint256 feeBefore = usdfr.balanceOf(feeRecipient);
        _repay(a, 5_000e18, 0);
        emit log_named_uint("P4 fee on defaulted facility interest", usdfr.balanceOf(feeRecipient) - feeBefore);
    }

    /// @dev The scenario shared by P6/P7: a 300k defaulted facility with BOTH junior layers at
    ///      zero (curator pool 0, sGROVE capacity 0), plus a performing facility that pays
    ///      `interest` in ten instalments. Returns the recognised deficit AFTER governance finally
    ///      performs the G3 intervention (`recognizePrincipalImpairment`) on the whole residual.
    function _runDefaultThenServicing() internal returns (uint256 deficitAfterRecognition) {
        uint256 a = _liveFilmFacility(300_000e18);
        _mintUSDfrTo(alice, 400_000e18);
        uint256 b = _originateFilm(BORROWER_2, STATE_GA, 200_000e18);
        _fundFacility(b, 200_000e18);
        _attestDefault(a);
        vm.prank(servicer);
        defaultManager.declareDefault(a, FILM_REF);

        assertEq(curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS), 0, "layer 1 must be empty");
        assertEq(backstopMock.coverageCapacity(), 0, "layer 2 must be empty");
        assertEq(defaultManager.pendingSeniorImpairment(), 300_000e18, "the whole 300k is senior residual");

        for (uint256 i = 0; i < 10; ++i) {
            _repay(b, 10_000e18, 0);
        }

        // Governance finally performs the DefaultManager-documented G3 intervention.
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(a, 300_000e18, EV);
        deficitAfterRecognition = _recognisedDeficit();
    }

    /// @notice P6. THE FINDING, MEASURED — NOW INVERTED (audit ADV-1, 2026-08-08).
    ///
    ///         WHAT IT MEASURED WHEN IT WAS RED. `_routeInterest`'s R16-M5 withholding clamp is
    ///         sized off `mintableHeadroom()`, which nets the RECORDED impairment, the custody
    ///         shortfall and `seniorSubParShortfall()` — but is blind to
    ///         `DefaultManager.pendingSeniorImpairment()`. A DECLARED default leaves
    ///         `totalDeployedPrincipal` at FACE, so headroom stayed full and the clamp withheld
    ///         NOTHING. 100,000e18 of borrower interest was paid straight out — 10,000e18 as
    ///         protocol fee to a recipient OUTSIDE the §1.3 cascade, 90,000e18 as yield — while a
    ///         300,000e18 senior residual stood with BOTH junior layers at zero. The recognised
    ///         deficit that finally landed was the full 300,000e18.
    ///
    ///         THE ASSERTIONS ARE INVERTED, NOT WEAKENED. The three closing lines used to pin the
    ///         SHIPPED-DEFECT numbers (`20_000e18` extracted, `300_000e18` deficit) and the middle
    ///         one was even labelled "SHIPPED deficit — the clamp withheld nothing". They now pin
    ///         the FIXED numbers and each carries the tighter bound, so this test still fails if
    ///         the defect returns. DO NOT restore the old constants.
    function test_P6_interestIsPaidOutWhileTheSeniorResidualStands() public {
        uint256 feeBefore = usdfr.balanceOf(feeRecipient);
        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        uint256 deficit = _runDefaultThenServicing();
        emit log_named_uint("P6 feeRecipient USDfr extracted", usdfr.balanceOf(feeRecipient) - feeBefore);
        emit log_named_uint("P6 vault USDfr received", usdfr.balanceOf(address(vault)) - vaultBefore);
        emit log_named_uint("P6 recognised deficit after G3 recognition", deficit);
        // AUDIT FIX (ADV-1): the 10,000e18 INTEREST-leg fee is withheld in full. The 10,000e18 that
        // remains is the ORIGINATION fee on facility B, which is knowingly left blind — `fund`'s
        // R18 clamp exists to stop origination FREEZING and tightening it is MRC residualRisk 5.
        // test_P8 pins that residual separately, so it cannot be lost.
        assertEq(
            usdfr.balanceOf(feeRecipient) - feeBefore,
            10_000e18,
            "ADV-1 REGRESSED: the interest-leg fee was extracted out of the senior shortfall"
        );
        // The senior leg is deliberately unchanged; see the ADV-1 block on `_routeInterest`.
        assertEq(usdfr.balanceOf(address(vault)) - vaultBefore, 90_000e18, "P6: the senior leg must be unchanged");
        // 300,000e18 of residual minus the 10,000e18 of interest-leg fee that was never minted and
        // therefore stayed in the reserve as backing. If this reads 300,000e18 again, the clamp
        // withheld nothing and ADV-1 is back.
        assertEq(deficit, 290_000e18, "ADV-1 REGRESSED: the withheld fee did not repair the deficit");
    }

    /// @notice P7. The fee USDfr sitting outside the cascade cannot be reached by `realizeLoss`:
    ///         layer-3 absorption is bounded by the VAULT's assets. So whatever leaves through the
    ///         fee leg is irreversible, not merely mistimed. This is the reason ADV-1's fix targets
    ///         the FEE leg specifically. The precondition constant drops from 20,000e18 to
    ///         10,000e18 because the interest-leg half is now withheld; the remaining 10,000e18 is
    ///         the knowingly-blind ORIGINATION fee, and this test still demonstrates that it is
    ///         out of reach.
    function test_P7_theExtractedFeeIsUnreachableByTheCascade() public {
        _runDefaultThenServicing();
        assertEq(usdfr.balanceOf(feeRecipient), 10_000e18, "P7 precondition: origination fee is out");
        assertEq(curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS), 0, "layer 1 still empty");
        assertEq(backstopMock.coverageCapacity(), 0, "layer 2 still empty");
        emit log_named_uint("P7 vault totalAssets (the whole of layer 3)", vault.totalAssets());
        emit log_named_uint("P7 feeRecipient USDfr (outside every layer)", usdfr.balanceOf(feeRecipient));
        assertLt(vault.totalAssets(), 300_000e18, "P7: layer 3 cannot cover the residual");
    }

    /// @notice P8. The same blindness on the ORIGINATION axis: a brand-new facility can be funded
    ///         and its origination fee minted to the same out-of-cascade recipient while the 300k
    ///         senior residual stands.
    function test_P8_originationFeeIsMintedWhileTheSeniorResidualStands() public {
        uint256 a = _liveFilmFacility(300_000e18);
        _mintUSDfrTo(alice, 400_000e18);
        _attestDefault(a);
        vm.prank(servicer);
        defaultManager.declareDefault(a, FILM_REF);
        assertEq(defaultManager.pendingSeniorImpairment(), 300_000e18, "P8 precondition");

        uint256 feeBefore = usdfr.balanceOf(feeRecipient);
        uint256 b = _originateFilm(BORROWER_2, STATE_GA, 200_000e18);
        _fundFacility(b, 200_000e18);
        emit log_named_uint("P8 origination fee minted", usdfr.balanceOf(feeRecipient) - feeBefore);
        assertGt(usdfr.balanceOf(feeRecipient) - feeBefore, 0, "P8: no origination fee minted");
    }

    /// @notice P9. THE CASCADE-ORDERING STATEMENT, EXECUTED. The 20,000e18 of fee USDfr is senior
    ///         to every layer of the §1.3 cascade: `realizeLoss` burns layer 1 (curator), layer 2
    ///         (sGROVE) and layer 3 (the vault) and never touches it. Here layers 1 and 2 are
    ///         empty, so the loss lands entirely on layer 3 while the out-of-cascade fee recipient
    ///         keeps every wei it was paid out of the same impaired book.
    function test_P9_realizeLossBurnsSeniorAndNeverTheFeeRecipient() public {
        uint256 a = _liveFilmFacility(300_000e18);
        _mintUSDfrTo(alice, 400_000e18);
        uint256 b = _originateFilm(BORROWER_2, STATE_GA, 200_000e18);
        _fundFacility(b, 200_000e18);
        _attestDefault(a);
        vm.prank(servicer);
        defaultManager.declareDefault(a, FILM_REF);
        for (uint256 i = 0; i < 10; ++i) {
            _repay(b, 10_000e18, 0);
        }

        uint256 feeHeld = usdfr.balanceOf(feeRecipient);
        uint256 vaultAssets = vault.totalAssets();
        emit log_named_uint("P9 feeRecipient USDfr before realizeLoss", feeHeld);
        emit log_named_uint("P9 vault totalAssets before realizeLoss", vaultAssets);

        _realizeLoss(a, 90_000e18, EV);

        emit log_named_uint("P9 feeRecipient USDfr after realizeLoss", usdfr.balanceOf(feeRecipient));
        emit log_named_uint("P9 vault totalAssets after realizeLoss", vault.totalAssets());
        assertEq(usdfr.balanceOf(feeRecipient), feeHeld, "P9: the fee recipient bore any of the loss");
        assertEq(vault.totalAssets(), vaultAssets - 90_000e18, "P9: layer 3 did not bear the whole loss");
        assertEq(curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS), 0, "P9: layer 1 empty throughout");
    }

    // ── P5: does the closing gate ever bite? drive a distribution that should widen ──
    function test_P5_gateBitesOnAWideningDistribution() public {
        uint256 a = _liveFilmFacility(300_000e18);
        _mintUSDfrTo(alice, 100_000e18);
        // Recognise a heavy impairment: backing falls below supply.
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(a, 250_000e18, EV);
        emit log_named_uint("recognisedDeficit", _recognisedDeficit());
        emit log_named_uint("mintableHeadroom", controller.mintableHeadroom());
        uint256 d0 = _recognisedDeficit();
        uint256 supply0 = controller.totalUSDfr();
        _repay(a, 9_000e18, 0);
        emit log_named_uint("recognisedDeficit after", _recognisedDeficit());
        assertEq(controller.totalUSDfr(), supply0, "P5: minted into the hole");
        assertEq(_recognisedDeficit(), d0 - 9_000e18, "P5: interest did not repair");
    }
}
