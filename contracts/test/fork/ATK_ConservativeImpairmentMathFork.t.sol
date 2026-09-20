// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {CommitmentLedger} from "../../src/CommitmentLedger.sol";
import {ConservativeImpairmentMath} from "../../src/ConservativeImpairmentMath.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {ICascadeBackstop} from "../../src/interfaces/ICascadeBackstop.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title ATK_ConservativeImpairmentMathFork, adversarial attacks on the ADR-0022 conservative
///        redemption mark against the FULL protocol on a pinned mainnet fork with REAL USDC.
///
/// @notice `ConservativeImpairmentMath` is the stateless calculator behind
///         `DefaultManager.pendingSeniorImpairment()`: it reads `CommitmentLedger.conservativeResiduals()`
///         and routes the result through `CollateralRegistry.conservativeSeniorMark`. Its own code is
///         byte-identical to the deployment commit (`edf525c`): every hunk in its diff is NatSpec. What
///         changed underneath it is `CommitmentLedger.conservativeResiduals()`, which retired the
///         forward/reverse per-event ladder in favour of per-class principal aggregates, and
///         `DefaultManager.pendingSeniorImpairment()`, which now prefers `DefaultAccrualLib.nativeSeniorImpairment`
///         whenever the continuous-accrual reserve is enabled. On a fresh HEAD deployment (this fixture)
///         the native path prices every redemption and the calculator is reachable only as a direct
///         view; on the live mainnet proxy, and on an upgraded proxy before `enableContinuousAccrual`
///         succeeds, the calculator IS the redemption price. Both must therefore agree to the wei in
///         every reachable state, or the migration silently re-prices the senior exit.
///
///         Invariants under attack (CLAUDE.md 1.3):
///           I1. sUSDfr exchange-rate integrity: the conservative mark never overstates what an
///               exiting holder may take; credit losses enter only through the cascade; rounding is
///               against the redeemer.
///           I2. Loss cascade ordering: the mark nets curator first-loss per class, then the one
///               shared sGROVE reserve, then senior principal, never inverting a layer.
///           I3. Redemption queue: a filled request is paid exactly the conservative quote.
///
///         Attacks (each ends in an unambiguous assertion; a blocked attack asserts the exact custom
///         error and the untouched state, a successful one would assert the violated money):
///           A1. ROUNDING DIRECTION. A realized loss that leaves single wei on the senior layer, and a
///               permissionless past-due mark inside the relief ramp: the exit quote is the floor of the
///               exact rational value and the ramped charge is its ceiling, non-decreasing in elapsed
///               time with the exit quote non-increasing, and past the ramp a float below the past-due
///               face reaches the designed zero-exit loud stop. Asserts: the quote and the mark equal
///               the independently computed floor and ceiling to the wei; the three instants are
///               ordered; the exit base is exactly zero past the ramp.
///           A2. MONOTONICITY. Three increasing realized losses on one facility: the mark, the
///               conservative NAV and the exit quote never rise without a repayment, and a loss the mark
///               had already priced does not move the exit base at all. Asserts: non-increasing, and
///               the exit base identical before and after each realization.
///           A3. THE CHANGED LINES. (a) With an attacker-marked past-due cohort standing in front of
///               the declared rows, across declaration, a layer-two draw, a partial recovery, a full
///               write-off, a clean resolve and the cure, in two classes, the class aggregate equals
///               min(forward, reverse) of the retired ladder reconstructed over the live rows, the
///               closed form over the manager's own class books, and the live native mark. (b) Every
///               row-mutation path (`register`, `sync`, `updatePrincipal`, `release`) keeps the new
///               per-class total equal to the sum of its rows and to `declaredDefaultedPrincipal`.
///               Asserts: equality to the wei after every transition.
///           A4. BOUNDARIES. loss == 0, loss == outstanding + 1, loss beyond absorption capacity, a
///               facility of one wei, the smallest fundable facility, the largest principal the
///               concentration limit admits, and a full write-off. Asserts: the exact custom error and
///               untouched mark for each refusal; exact values with no overflow for each admission.
///           A5. EXIT AT THE MARK. A holder queues while an impairment stands, settles after the
///               cooldown and is paid exactly the conservative quote and never the pre-impairment
///               quote; after a full repayment the mark clears and the next redeemer is paid the
///               higher, correct amount. Asserts: paid == quote to the wei, paid <= pre-impairment quote.
///           A6. UNPRIVILEGED MOVEMENT. Every direct route by which an outsider could lower the mark
///               (realize a loss, resolve, recover, rewrite or release a ledger row, fake a curator
///               absorption) is refused with its exact error and the mark is unchanged.
contract ATK_ConservativeImpairmentMathForkTest is ForkLifecycleFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS; // 1
    uint256 internal constant RENEWABLE = Config.CLASS_RENEWABLE_ENERGY; // 2
    uint256 internal constant SHARE_OFFSET = 1e6; // sUSDfr `_decimalsOffset()` == 6

    /// @dev Declared locally so `vm.expectEmit` binds by signature; identical to the emitters'.
    event LossRealized(
        uint256 indexed tokenId,
        uint256 indexed classId,
        uint256 loss,
        uint256 curatorAbsorbed,
        uint256 backstopCovered,
        uint256 depositorLoss
    );
    event CommitmentReleased(uint256 indexed eventId, uint256 releasedDeliverable, uint256 aggregateDeliverable);
    event CommitmentPrincipalUpdated(uint256 indexed eventId, uint256 remainingPrincipal);
    event CommitmentSynced(
        uint256 indexed eventId,
        uint256 remainingCoverage,
        uint256 remainingPrincipal,
        uint256 deliverable,
        uint256 aggregateDeliverable
    );
    event RequestFilled(uint256 indexed requestId, uint256 shares, uint256 assets, uint256 epoch);

    /// @dev One (residual, pastDueSenior) pair, the ledger's return shape.
    struct Residuals {
        uint256 residual;
        uint256 pastDueSenior;
    }

    /// @dev A5 scene state, kept in memory so the two halves stay under the stack limit.
    struct ExitScene {
        uint256 id;
        uint256 sharesA;
        uint256 sharesB;
        uint256 parQuoteA;
        uint256 parQuoteB;
        uint256 markedQuoteA;
        uint256 mark;
        uint256 paidA;
    }

    /// @dev Scratch for the retired forward/reverse ladder reconstruction.
    struct LadderState {
        uint256[5] avail;
        uint256 pastDueGross;
        uint256 pastDueResidual;
        uint256 gross;
        uint256 reserve;
        uint256 pdLayerTwo;
        address backstop;
    }

    // ─────────────────────────────────────────────────────────────────────
    // A1 (I1): rounding is against the redeemer at the mark
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A realized loss that leaves seven wei on the senior layer. The mark falls by exactly
    ///         those seven wei, the exit base does not move (the mark had already priced them), and
    ///         the exit quote for a deliberately non-round share count is the FLOOR of the exact
    ///         rational value, strictly below its ceiling.
    /// @dev Attacks I1. If the quote were the ceiling, every exiting holder would take up to one wei
    ///      per share batch from the holders who stay; across a queue of settlements that is a
    ///      permissionless drain of the senior tranche at the rounding boundary.
    function test_atk_exitQuoteRoundsAgainstTheRedeemerAtTheMark() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        uint256 shares = _stake(alice, 2_999_999e18 + 123_456_789_012_345_678); // not a round number
        _mintFromUSDC(ops, 1_000_000e6);
        _postFirstLoss(FILM, 150_000e18);
        _fundCoverage(ops, 500_000e18);
        uint256 id = _originateAndFund(1_000_000e18);
        _declareDefault(id, keccak256("atk-cim-a1"));
        assertEq(defaultManager.defaultedContribution(id), 1_000_000e18, "precondition: declared at face");

        // The impairment is pure integer arithmetic: 1,000,000 - 150,000 curator - 500,000 reserve.
        ConservativeImpairmentMath calc = defaultManager.impairmentMath();
        vm.prank(carol); // anyone may read the calculator; it holds nothing and chooses no counterparties
        uint256 markBefore = calc.pendingSeniorImpairment(address(defaultManager));
        assertEq(markBefore, 350_000e18, "declared face less both junior layers, exactly");
        assertEq(markBefore, _nativeMark(), "the calculator and the live native mark agree before the loss");
        uint256 assetsBefore = vault.totalAssets();
        uint256 baseBefore = vault.redemptionTotalAssets();
        assertEq(baseBefore, assetsBefore - markBefore, "exit base is realized assets less the mark");
        uint256 quoteBefore = vault.previewRedeem(shares);

        // Realize 650,000 + 7 wei: layer 1 takes 150,000, layer 2 takes 500,000, the senior layer 7 wei.
        _realizeLossExpectingCascade(id, FILM, 650_000e18 + 7, 150_000e18, 500_000e18, 7);

        uint256 mark = _legacyMark();
        assertEq(mark, 350_000e18 - 7, "the mark falls by exactly the seven senior wei realized");
        assertEq(mark, _modelMark(), "the calculator equals the closed form over the class books");
        assertEq(mark, _nativeMark(), "the calculator equals the live native mark after the loss");
        assertEq(vault.totalAssets(), assetsBefore - 7, "the vault burned exactly the seven senior wei");
        assertEq(
            vault.redemptionTotalAssets(),
            baseBefore,
            "a realization the mark already priced does not move the exit base"
        );
        assertEq(vault.previewRedeem(shares), quoteBefore, "nor the exit quote");

        // ROUNDING: the quote is the floor of shares * (base + 1) / (supply + offset), and the case is
        // genuinely inexact so the direction is observable.
        uint256 numerator = vault.redemptionTotalAssets() + 1;
        uint256 denominator = vault.totalSupply() + SHARE_OFFSET; // no fee shares are due below the HWM
        uint256 floorQuote = Math.mulDiv(shares, numerator, denominator);
        uint256 ceilQuote = Math.mulDiv(shares, numerator, denominator, Math.Rounding.Ceil);
        assertGt(ceilQuote, floorQuote, "precondition: the exact quotient has a remainder");
        uint256 quote = vault.previewRedeem(shares);
        assertEq(quote, floorQuote, "the exit quote is the FLOOR of the exact rational value");
        assertLt(quote, ceilQuote, "and strictly below the ceiling: rounding is against the redeemer");
        assertLe(
            quote * denominator, shares * numerator, "quote * supply <= shares * assets: never above the exact value"
        );
        assertGt(
            quote * denominator + denominator,
            shares * numerator,
            "but within one share-unit of it: not under-paid by more than the rounding"
        );
    }

    /// @notice A permissionless past-due mark by the non-KYC attacker. The unattested cohort is
    ///         clamped to the executable senior capacity and then ramp-weighted; the division in the
    ///         ramp rounds UP against the exiting senior, and the mark is monotone in elapsed time:
    ///         non-decreasing from the instant of the mark, through the ramp, to its expiry, with the
    ///         exit quote non-increasing over the same three instants. The attacker's single call
    ///         cannot drive the exit price to zero at the mark or inside the ramp. Past the ramp, with
    ///         a senior float smaller than the past-due face, the clamped charge equals the whole
    ///         float and the exit base is exactly zero: that is the designed loud stop, asserted as
    ///         such rather than as a non-zero exit.
    /// @dev Attacks I1 through the G2W owner decision. Rounding down here would hand every exiting
    ///      senior up to one basis-point unit of the past-due charge; a ramp that decayed instead of
    ///      climbing, or a relief that returned after expiry, would let a holder who waits out part of
    ///      the ramp exit at a higher quote than one who exits at the mark, which is the unrealized
    ///      loss moved from the patient cohort to the impatient one; dropping the clamp would let the
    ///      attacker halt the only senior exit with one role-less call, which is the measured D5-03
    ///      failure this path exists to prevent.
    function test_atk_permissionlessPastDueMarkRoundsUpAndCannotZeroTheExit() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        uint256 shares = _stake(alice, 600_000e18 + 1); // senior float below the facility: the clamp binds
        uint256 id = _originateAndFund(1_000_000e18);

        _warp(60 days); // past the first coupon and the class grace window
        _freshen();
        assertEq(_legacyMark(), 0, "no mark while performing");

        // ATTACK: carol, holding no role and not KYC'd, marks the facility past due.
        vm.prank(carol);
        defaultManager.markPastDue(id);
        uint256 anchor = defaultManager.pastDueReliefAnchor();
        assertEq(anchor, block.timestamp, "the relief clock anchors at the mark");
        assertGe(defaultManager.pastDuePrincipal(FILM), 1_000_000e18, "the whole face entered the past-due pool");

        uint256 markAtMark = _assertRampedMarkRoundsUp(anchor, "at the mark");
        assertGt(vault.redemptionTotalAssets(), 0, "one unattested call did not zero the senior exit");
        uint256 quoteAtMark = vault.previewRedeem(shares);
        assertGt(quoteAtMark, 0, "the senior still has an exit price");

        _warp(1 days + 1);
        _freshen();
        // MONOTONE IN ELAPSED TIME. Read and compared BEFORE the per-instant model so that a ramp
        // that decays is named as the money it moves, not as a model mismatch.
        uint256 markInsideRamp = _legacyMark();
        assertGe(markInsideRamp, markAtMark, "MONOTONE: the mark fell inside the ramp without a repayment");
        uint256 quoteInsideRamp = vault.previewRedeem(shares);
        assertLe(quoteInsideRamp, quoteAtMark, "MONOTONE: the exit quote rose inside the ramp without a repayment");
        assertEq(
            _assertRampedMarkRoundsUp(anchor, "inside the ramp"), markInsideRamp, "the modelled mark is the one read"
        );
        assertGt(vault.redemptionTotalAssets(), 0, "still not zero inside the ramp");

        // Past the ramp: full weight, no division, but the executable clamp never expires.
        _warp(Config.DEFAULT_REDEEM_COOLDOWN);
        _freshen();
        uint256 markPastRamp = _legacyMark();
        assertGe(markPastRamp, markInsideRamp, "MONOTONE: the mark fell when the ramp expired");
        assertLe(vault.previewRedeem(shares), quoteInsideRamp, "MONOTONE: the exit quote rose when the ramp expired");
        Residuals memory r = _modelResiduals();
        (uint256 lr, uint256 lp) = _ledger().conservativeResiduals();
        assertEq(lr, r.residual, "ledger residual past the ramp");
        assertEq(lp, r.pastDueSenior, "ledger past-due senior past the ramp");
        assertEq(lr, lp, "no declared cohort: the residual is the past-due senior alone");
        uint256 vaultAssets = vault.totalAssets();
        uint256 clamped = lp < vaultAssets ? lp : vaultAssets;
        assertLt(clamped, lp, "precondition: the executable clamp is binding");
        assertEq(
            markPastRamp,
            clamped,
            "past the ramp the mark is the past-due charge clamped to what realizeLoss could burn"
        );
        assertEq(markPastRamp, _nativeMark(), "the calculator and the live native mark agree past the ramp");
        assertEq(markPastRamp, _modelMark(), "and match the closed form");
        // The designed loud stop: the clamp bound at the whole float, so the exit base is exactly
        // zero past the ramp. Not a rounding artefact, and not the attacker's single call: the
        // ramp gave every queued senior the full cooldown to settle at a priced exit first.
        assertEq(markPastRamp, vaultAssets, "the charge is the whole senior float");
        assertEq(vault.redemptionTotalAssets(), 0, "the loud stop: exit base exactly zero past the ramp");
        assertEq(vault.previewRedeem(shares), 0, "and the exit quote is zero with it");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A2 (I1, I2): monotone in the impairment inputs
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Three increasing realized losses on one facility, each carrying odd wei: the mark,
    ///         the conservative NAV and the exit quote are non-increasing throughout, and because
    ///         the declaration already priced the whole face net of both junior layers, the exit base
    ///         is IDENTICAL before and after every realization.
    /// @dev Attacks I1 and I2. A rise in the exit base between two realizations without a repayment
    ///      would be value created from nothing for whoever exits in that window; a fall would be a
    ///      loss charged twice. Either is money taken from one senior cohort by another.
    function test_atk_conservativeNavIsMonotoneAcrossIncreasingLosses() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        uint256 shares = _stake(alice, 3_000_000e18);
        _mintFromUSDC(ops, 1_000_000e6);
        _postFirstLoss(FILM, 150_000e18);
        _fundCoverage(ops, 500_000e18);
        uint256 id = _originateAndFund(1_000_000e18);
        _declareDefault(id, keccak256("atk-cim-a2"));

        uint256 base0 = vault.redemptionTotalAssets();
        uint256 prevMark = _legacyMark();
        uint256 prevBase = base0;
        uint256 prevQuote = vault.previewRedeem(shares);
        assertEq(prevMark, 350_000e18, "declared face less both junior layers");

        uint256[3] memory chunks = [uint256(100_000e18), 250_000e18 + 3, 400_000e18 + 5];
        // Expected marks: 900k - 50k - 500k; (650k-3) - 0 - (300k-3); (250k-8) - 0 - 0.
        uint256[3] memory expectedMark = [uint256(350_000e18), 350_000e18, 250_000e18 - 8];
        for (uint256 i = 0; i < 3; ++i) {
            _realizeLoss(id, chunks[i], bytes32(0));
            uint256 mark = _legacyMark();
            assertEq(mark, expectedMark[i], "the mark after this chunk is exact");
            assertEq(mark, _modelMark(), "the calculator equals the closed form");
            assertEq(mark, _nativeMark(), "the calculator equals the live native mark");
            assertLe(mark, prevMark, "INVARIANT: the mark never rises as losses are realized without a repayment");
            uint256 base = vault.redemptionTotalAssets();
            assertLe(base, prevBase, "INVARIANT: the conservative NAV is non-increasing");
            assertEq(base, base0, "a loss the declaration already priced does not move the exit base");
            assertEq(base, vault.totalAssets() - mark, "exit base == realized assets - mark, exactly");
            uint256 quote = vault.previewRedeem(shares);
            assertLe(quote, prevQuote, "INVARIANT: the exit quote is non-increasing");
            prevMark = mark;
            prevBase = base;
            prevQuote = quote;
        }
        assertEq(reserves.deployedTo(id), 250_000e18 - 8, "remaining face after 750,000 + 8 wei realized");
        assertEq(curator.poolBalance(FILM), 0, "layer 1 exhausted");
        assertEq(sGrove.coverageReserve(), 0, "layer 2 exhausted");
        assertEq(
            vault.totalAssets() + 100_000e18 + 8,
            base0 + 350_000e18,
            "the senior layer absorbed exactly 100,000 + 8 wei"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // A3 (I1, I2): the changed lines, executed
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The retired forward/reverse ladder, reconstructed over the live ledger rows, must
    ///         equal the new class aggregate, the closed form over the manager's class books and
    ///         the live native mark, across every row transition in two classes WITH an unattested
    ///         past-due cohort standing in front of the declared rows: three declarations out of
    ///         token order, a layer-two draw (sync), a partial cash recovery (updatePrincipal), a
    ///         full write-off (release of a class's only row), a clean resolve (release with a
    ///         surviving row in the same class) and the servicer's cure of the past-due mark.
    /// @dev Attacks I1 and I2 on the hunk that replaced `_declaredJuniorDelivery`. A class aggregate
    ///      below the ladder would credit junior capital that cannot physically be delivered and
    ///      under-mark the exit by the difference; above it would over-charge every exiting senior.
    ///      A divergence from the native mark is the migration re-pricing the senior exit. The
    ///      past-due cohort is marked by carol, permissionlessly, so the junior capacity it consumes
    ///      ahead of the declared rows is exactly what an outsider can inject into the read.
    function test_atk_changedLines_classAggregateEqualsTheRetiredLadderAcrossALifecycle() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 4_000_000e18);
        _mintFromUSDC(bob, 5_000_000e6); // idle liquidity to fund four facilities
        _mintFromUSDC(ops, 2_000_000e6);
        _postFirstLoss(FILM, 300_000e18);
        _postFirstLoss(RENEWABLE, 50_000e18);
        _fundCoverage(ops, 400_000e18);

        // D is funded first and aged past its grace window; the attacker marks it past due. Its
        // past-due face carries 60 days of accrual and is read live; everything declared below is
        // funded and declared in one block, so those faces are exact.
        uint256 idD = _originateAndFundIn(FILM, keccak256("BW-CIM-D"), 400_000e18);
        _warp(60 days);
        _freshen();
        vm.prank(carol);
        defaultManager.markPastDue(idD);
        uint256 pd = defaultManager.pastDuePrincipal(FILM);
        assertGt(pd, 300_000e18, "precondition: the past-due face exceeds the FILM curator pool");
        assertLt(pd, 700_000e18, "precondition: but not the pool plus the reserve");
        assertEq(defaultManager.pastDueReliefAnchor(), block.timestamp, "the relief clock anchors now");
        _assertCalculatorAgreesEverywhere("past-due cohort only");
        assertEq(_legacyMark(), 0, "the past-due cohort alone is fully covered by junior capital");

        uint256 idA = _originateAndFundIn(FILM, keccak256("BW-CIM-A"), 800_000e18);
        uint256 idB = _originateAndFundIn(RENEWABLE, keccak256("BW-CIM-B"), 600_000e18);
        uint256 idC = _originateAndFundIn(FILM, keccak256("BW-CIM-C"), 1_000_000e18);
        _assertCalculatorAgreesEverywhere("funded, undeclared");

        // Declare out of token order so the ledger's enumeration differs from token ids.
        _declareDefault(idB, keccak256("cim-b"));
        _declareDefault(idC, keccak256("cim-c"));
        _declareDefault(idA, keccak256("cim-a"));
        CommitmentLedger ledger = _ledger();
        assertEq(ledger.eventCount(), 3, "three live rows");
        assertEq(ledger.eventAt(0), idB, "declaration order is preserved");
        assertEq(ledger.eventAt(1), idC, "declaration order is preserved");
        assertEq(ledger.eventAt(2), idA, "declaration order is preserved");
        assertEq(defaultManager.defaultedContribution(idA), 800_000e18, "A declared at face");
        assertEq(defaultManager.defaultedContribution(idB), 600_000e18, "B declared at face");
        assertEq(defaultManager.defaultedContribution(idC), 1_000_000e18, "C declared at face");
        _assertCalculatorAgreesEverywhere("three declarations behind the past-due cohort");
        // Past due takes the whole 300k FILM pool and (pd - 300k) of the reserve, leaving 700k - pd
        // for the declared rows: FILM 1.8M + RENEWABLE (600k - 50k) - (700k - pd).
        assertEq(_legacyMark(), 1_650_000e18 + pd, "exact mark: the cohort in front consumed junior capacity");

        // Layer-two draw on C: 300k curator (the physical pool ignores mark-time priority), 200k
        // reserve. The row is synced (DRAWN flag, principal). The reserve left is 200k, all of it
        // now offered to the past-due cohort first, whose remainder becomes a ramped senior charge.
        _realizeLossExpectingCascade(idC, FILM, 500_000e18, 300_000e18, 200_000e18, 0);
        _assertCalculatorAgreesEverywhere("layer-two draw (sync path)");
        (, bool drawnC,, uint256 principalC) = ledger.eventInfo(idC);
        assertTrue(drawnC, "row C is flagged drawn");
        assertEq(principalC, 500_000e18, "row C carries its remaining face");
        uint256 pds = pd - 200_000e18; // past-due senior after the 200k reserve
        uint256 ramped = (pds * registry.pastDueWeightBps() + Config.BPS - 1) / Config.BPS; // elapsed == 0
        assertEq(
            _legacyMark(),
            1_850_000e18 + ramped,
            "exact mark: declared 1.85M at full weight plus the ramped past-due charge"
        );

        // Partial cash recovery on A: 200k principal comes back, the row re-anchors.
        IWaterfallEngine.Payment memory recoveryA = _prepPrincipalRepayment(idA, 200_000e18);
        vm.expectEmit(true, true, true, true, address(ledger));
        emit CommitmentPrincipalUpdated(idA, 600_000e18);
        vm.prank(ops);
        waterfall.distribute(recoveryA);
        _assertCalculatorAgreesEverywhere("partial recovery (updatePrincipal path)");
        assertEq(_legacyMark(), 1_650_000e18 + ramped, "the recovered cash left the mark");

        // Full write-off of B: 50k curator, the last 200k of the physical reserve, 350k senior. Its
        // class's only row is released. ADR-0035: B's draw exhausts the one shared reserve, so the
        // past-due cohort that was counting on it at mark time now stands entirely on the senior
        // layer, and the whole past-due face becomes the ramped charge.
        _realizeLossExpectingCascade(idB, RENEWABLE, 600_000e18, 50_000e18, 200_000e18, 350_000e18);
        _assertCalculatorAgreesEverywhere("full write-off (release of a class's only row)");
        assertEq(ledger.remainingPrincipalForClass(RENEWABLE), 0, "the written-off class carries no principal");
        assertEq(ledger.eventCount(), 2, "row B released");
        assertEq(sGrove.coverageReserve(), 0, "the shared reserve is exhausted");
        uint256 rampedWhole = (pd * registry.pastDueWeightBps() + Config.BPS - 1) / Config.BPS; // elapsed == 0
        assertGt(
            rampedWhole, ramped, "the past-due charge rose when the reserve it counted on was drawn by another event"
        );
        assertEq(
            _legacyMark(),
            1_100_000e18 + rampedWhole,
            "FILM face with both junior layers exhausted, plus the whole ramped charge"
        );
        assertEq(
            uint256(bridge.facility(idB).state), uint256(ClaimBridge.LoanState.Resolved), "B resolved by the write-off"
        );

        // Clean resolve of A by full repayment: release with C surviving in the same class. Row A
        // was never drawn, so it releases no deliverable; the aggregate that remains is row C's
        // compatibility deliverable, min(coverage, principal) = 500k after its sync.
        IWaterfallEngine.Payment memory resolveA = _prepPrincipalRepayment(idA, 600_000e18);
        vm.expectEmit(true, true, true, true, address(ledger));
        emit CommitmentReleased(idA, 0, 500_000e18);
        vm.prank(ops);
        waterfall.distribute(resolveA);
        _assertCalculatorAgreesEverywhere("clean resolve (release with a surviving row in the class)");
        assertEq(ledger.eventCount(), 1, "only C remains");
        assertEq(ledger.eventAt(0), idC, "the survivor kept its row");
        assertEq(ledger.remainingPrincipalForClass(FILM), 500_000e18, "the class total is exactly the survivor");
        assertEq(_legacyMark(), 500_000e18 + rampedWhole, "the surviving face plus the whole ramped charge");

        // The servicer cures the past-due mark: the ramped charge leaves, the declared row does not.
        _attest(idD, IAttestationOracle.AttestationKind.PastDueCured, keccak256(abi.encode(idD, keccak256("cure"))));
        vm.prank(ops);
        defaultManager.clearPastDue(idD, keccak256("cure"));
        _assertCalculatorAgreesEverywhere("past-due cured");
        assertEq(defaultManager.pastDuePrincipal(FILM), 0, "the cohort is empty");
        assertEq(_legacyMark(), 500_000e18, "the mark is exactly the surviving declared face");
    }

    /// @notice Every path that writes a ledger row's principal (`register`, `sync`, `updatePrincipal`,
    ///         `release`) keeps the appended per-class total equal to the sum of its live rows and to
    ///         the manager's `declaredDefaultedPrincipal`, in the class the row actually belongs to.
    /// @dev Attacks I1 on the `_setPrincipal` hunks. Setting the class metadata after the principal
    ///      (register) or deleting it before the principal (release) books the face under class 0,
    ///      where `conservativeResiduals` never looks: the mark would ignore a declared default and
    ///      the exit would be priced at par against a facility the servicer has attested as lost.
    ///      Three of the four hunks are observable here (register, updatePrincipal, release). The
    ///      `sync` hunk is not, on HEAD: its only caller, `DefaultLossLib.drawLayer2ForLiveDefault`,
    ///      passes the row's current `defaultedContribution`, and every writer of that figure pairs
    ///      with a ledger `register`/`updatePrincipal`/`release`, so `sync` always rewrites the
    ///      principal the row already holds and the write-down that follows a draw reaches the class
    ///      total through `reduceDefaulted -> updatePrincipal`. A mutation of the sync hunk alone is
    ///      therefore an equivalent mutant; the sync transition is still driven and reconciled so a
    ///      future caller that passes a different principal is caught.
    function test_atk_changedLines_perClassPrincipalReconcilesThroughEveryRowMutation() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 3_000_000e18);
        _mintFromUSDC(ops, 1_000_000e6);
        _fundCoverage(ops, 300_000e18);

        uint256 idA = _originateAndFundIn(FILM, keccak256("BW-CIM-P1"), 700_000e18);
        uint256 idB = _originateAndFundIn(FILM, keccak256("BW-CIM-P2"), 500_000e18);
        _assertPerClassPrincipalReconciles("before any row");

        _declareDefault(idA, keccak256("cim-p1")); // register
        _assertPerClassPrincipalReconciles("register A");
        assertEq(_ledger().remainingPrincipalForClass(FILM), 700_000e18, "A's face booked under FILM");
        assertEq(_legacyMark(), 400_000e18, "700k - 300k reserve");

        _declareDefault(idB, keccak256("cim-p2")); // register, second row in the same class
        _assertPerClassPrincipalReconciles("register B");
        assertEq(_ledger().remainingPrincipalForClass(FILM), 1_200_000e18, "both faces booked under FILM");
        assertEq(_legacyMark(), 900_000e18, "1.2M - 300k reserve");

        // sync (draw) then updatePrincipal. The draw syncs the principal the row ALREADY holds
        // (700k, which is what makes the sync hunk unobservable on HEAD); the write-down that
        // follows reaches the class total through `updatePrincipal`. Both events are bound to the
        // one `realizeLoss` call, in order, so a caller that ever passes `sync` a different
        // principal fails here by name.
        bytes32 drawEvidence = _attestLoss(idA, 250_000e18, bytes32(0));
        vm.expectEmit(true, true, true, true, address(_ledger()));
        emit CommitmentSynced(idA, 700_000e18, 700_000e18, 700_000e18, 700_000e18);
        vm.expectEmit(true, true, true, true, address(_ledger()));
        emit CommitmentPrincipalUpdated(idA, 450_000e18);
        vm.prank(ops);
        defaultManager.realizeLoss(idA, 250_000e18, drawEvidence);
        _assertPerClassPrincipalReconciles("sync A");
        assertEq(_ledger().remainingPrincipalForClass(FILM), 950_000e18, "A's draw left the class total");
        assertEq(_legacyMark(), 900_000e18, "the 250k draw was pre-priced: 950k - 50k reserve");

        _repay(idB, 0, 100_000e18); // updatePrincipal through the recovery hook
        _assertPerClassPrincipalReconciles("updatePrincipal B");
        assertEq(_ledger().remainingPrincipalForClass(FILM), 850_000e18, "B's recovery left the class total");
        assertEq(_legacyMark(), 800_000e18, "850k - 50k reserve");

        _realizeLoss(idA, 450_000e18, bytes32(0)); // release A (full write-off), B survives
        _assertPerClassPrincipalReconciles("release A with B surviving");
        assertEq(_ledger().remainingPrincipalForClass(FILM), 400_000e18, "only B's face remains in the class");
        assertEq(_ledger().eventCount(), 1, "A's row is gone");
        assertEq(_legacyMark(), 400_000e18, "B's face with the reserve exhausted");

        _repay(idB, 0, 400_000e18); // release B (clean resolve), class empties
        _assertPerClassPrincipalReconciles("release B, class empty");
        assertEq(_ledger().remainingPrincipalForClass(FILM), 0, "the class total returns to zero");
        assertEq(_ledger().eventCount(), 0, "no live rows");
        assertEq(_legacyMark(), 0, "no mark");
        assertEq(vault.redemptionTotalAssets(), vault.totalAssets(), "the exit base is the realized base again");

        // The class getter refuses an out-of-range class rather than answering zero for it.
        CommitmentLedger ledger = _ledger();
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(CommitmentLedger.CommitmentLedger_InvalidClass.selector, 0));
        ledger.remainingPrincipalForClass(0);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(CommitmentLedger.CommitmentLedger_InvalidClass.selector, 6));
        ledger.remainingPrincipalForClass(Config.NUM_CLASSES + 1);
    }

    // ─────────────────────────────────────────────────────────────────────
    // A4 (I1, I2): boundaries
    // ─────────────────────────────────────────────────────────────────────

    /// @notice loss == 0, loss == outstanding + 1 and a loss beyond the senior layer's absorption
    ///         capacity are each refused with their exact error, and none of them moves the mark.
    ///         With the mark above the vault's assets the exit base is clamped to zero (the loud
    ///         stop), never underflowed.
    /// @dev Attacks I1 and I2. Accepting a loss above the outstanding would write down principal that
    ///      does not exist and net junior capital against it; accepting one beyond capacity would
    ///      impair unstaked USDfr holders, who sit outside the cascade entirely.
    function test_atk_boundaries_zeroOverAndBeyondCapacityLossesAreRefusedExactly() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        uint256 shares = _stake(alice, 500_000e18); // deliberately smaller than the facility
        uint256 id = _originateAndFund(1_000_000e18);
        _declareDefault(id, keccak256("atk-cim-a4a"));

        uint256 mark = _legacyMark();
        assertEq(mark, 1_000_000e18, "no junior layers: the whole face is the mark");
        assertEq(mark, _nativeMark(), "calculator == native");
        assertGt(mark, vault.totalAssets(), "the mark exceeds the senior float");
        assertEq(vault.redemptionTotalAssets(), 0, "LOUD STOP: the exit base clamps to zero, it does not underflow");
        assertEq(vault.previewRedeem(shares), 0, "and the exit quote is zero");

        // loss == 0: refused before any attestation is consulted.
        vm.prank(ops);
        vm.expectRevert(IDefaultManager.DefaultManager_ZeroAmount.selector);
        defaultManager.realizeLoss(id, 0, keccak256("zero"));

        // loss == outstanding + 1: refused before any attestation is consulted.
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_LossExceedsOutstanding.selector, id, 1_000_000e18 + 1, 1_000_000e18
            )
        );
        defaultManager.realizeLoss(id, 1_000_000e18 + 1, keccak256("over"));

        // loss == outstanding, beyond the senior layer's capacity: attested, then fail loudly and
        // roll everything back, the attested fact included.
        uint256 vaultAssets = vault.totalAssets();
        bytes32 fullEvidence = _attestLoss(id, 1_000_000e18, bytes32(0));
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_LossExceedsAbsorptionCapacity.selector, id, 1_000_000e18, vaultAssets
            )
        );
        defaultManager.realizeLoss(id, 1_000_000e18, fullEvidence);

        assertEq(_legacyMark(), mark, "no refused loss moved the mark");
        assertEq(reserves.deployedTo(id), 1_000_000e18, "no refused loss moved the face");
        assertEq(vault.totalAssets(), vaultAssets, "no refused loss burned senior principal");
        assertEq(defaultManager.defaultedContribution(id), 1_000_000e18, "the contribution is untouched");
        assertEq(_ledger().remainingPrincipalForClass(FILM), 1_000_000e18, "the ledger row is untouched");
        (,, bool standing) = oracle.latestPayload(id, IAttestationOracle.AttestationKind.LossRealized);
        assertTrue(standing, "the rolled-back call left its attested fact standing, unconsumed");

        // Governance retires the unspent fact (the oracle refuses a second LossRealized while one
        // stands), then the largest loss that CAN be absorbed, exactly the senior float, goes
        // through and leaves the remainder marked with the exit base still zero.
        oracle.revoke(id, IAttestationOracle.AttestationKind.LossRealized);
        _realizeLossExpectingCascade(id, FILM, vaultAssets, 0, 0, vaultAssets);
        assertEq(vault.totalAssets(), 0, "the senior layer is exhausted to the wei");
        assertEq(_legacyMark(), 1_000_000e18 - vaultAssets, "the unabsorbed remainder stays marked");
        assertEq(_legacyMark(), _nativeMark(), "calculator == native after the maximal loss");
        assertEq(vault.redemptionTotalAssets(), 0, "still nothing to exit into");

        // One more wei is beyond capacity: the exact error names the empty float.
        bytes32 weiEvidence = _attestLoss(id, 1, bytes32(0));
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_LossExceedsAbsorptionCapacity.selector, id, 1, 0)
        );
        defaultManager.realizeLoss(id, 1, weiEvidence);
        assertEq(_legacyMark(), 1_000_000e18 - vaultAssets, "the mark is untouched by the refused wei");
    }

    /// @notice A facility of one wei cannot be funded at all (the stable leg has no wei), so it can
    ///         never enter the mark; the smallest fundable facility (1e12 wei, one USDC unit) marks
    ///         exactly 1e12, a one-wei loss leaves exactly 1e12 - 1, and a full write-off releases
    ///         the row, clears the mark and resolves the facility.
    /// @dev Attacks I1 at the small end. Off-by-one here is a wei, but the same code paths carry the
    ///      largest facility, and a boundary that rounds the wrong way rounds the same way at scale.
    function test_atk_boundaries_oneWeiAndSmallestFundableFacility() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 1_000_000e18);

        // One wei: originates, cannot fund at zero or one stable unit.
        uint256 weiId = _originatePending(1);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PrincipalMismatch.selector, weiId, 1, 0));
        waterfall.fund(weiId, 0);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PrincipalMismatch.selector, weiId, 1, 1e12));
        waterfall.fund(weiId, 1);
        assertEq(reserves.deployedTo(weiId), 0, "a one-wei facility deploys nothing");
        assertEq(_legacyMark(), 0, "and can never be marked");

        // Smallest fundable: 1e12 wei == 1 USDC unit.
        uint256 id = _originateAndFund(1e12);
        assertEq(reserves.deployedTo(id), 1e12, "one stable unit deployed");
        _declareDefault(id, keccak256("atk-cim-a4b"));
        assertEq(_legacyMark(), 1e12, "the smallest facility marks exactly its face");
        assertEq(_nativeMark(), 1e12, "native agrees");
        uint256 baseBefore = vault.redemptionTotalAssets();
        assertEq(baseBefore, vault.totalAssets() - 1e12, "exit base is realized assets less one unit");

        _realizeLoss(id, 1, bytes32(0));
        assertEq(_legacyMark(), 1e12 - 1, "a one-wei loss leaves exactly 1e12 - 1 marked");
        assertEq(_nativeMark(), 1e12 - 1, "native agrees to the wei");
        assertEq(vault.redemptionTotalAssets(), baseBefore, "the pre-priced wei did not move the exit base");

        bytes32 evidence = _attestLoss(id, 1e12 - 1, bytes32(0));
        vm.expectEmit(true, true, true, true, address(_ledger()));
        emit CommitmentReleased(id, 0, 0);
        vm.expectEmit(true, true, true, true, address(defaultManager));
        emit LossRealized(id, FILM, 1e12 - 1, 0, 0, 1e12 - 1);
        vm.prank(ops);
        defaultManager.realizeLoss(id, 1e12 - 1, evidence);
        assertEq(_legacyMark(), 0, "a full write-off clears the mark");
        assertEq(_nativeMark(), 0, "native agrees");
        assertEq(_ledger().eventCount(), 0, "the row is released");
        assertEq(_ledger().remainingPrincipalForClass(FILM), 0, "the class total is zero");
        assertEq(reserves.deployedTo(id), 0, "nothing outstanding");
        assertEq(
            uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Resolved), "resolved by the write-off"
        );
        assertEq(vault.redemptionTotalAssets(), baseBefore, "the exit base is unchanged: the whole unit was pre-priced");
        assertEq(vault.redemptionTotalAssets(), vault.totalAssets(), "and equals the realized base with no mark");
    }

    /// @notice The largest principal the registry admits: on this deployment every relative limit
    ///         is at parity, so the numeric guard binds (`MAX_SAFE_EXPOSURE` less the book and the
    ///         accrual reserve's reserved ceilings). Exactly that much is admitted, one wei more is
    ///         refused with the exact error. Then the largest facility the fixture's real USDC can
    ///         fund (10,000,000) is declared and fully written off: the mark is exact, nothing
    ///         overflows, and the junior layers are netted before the senior float.
    /// @dev Attacks I1 and I2 at the large end. The mark on the largest facility is the largest
    ///      single charge the protocol carries; an off-by-one or an overflow there is the largest
    ///      single mispricing it can produce.
    function test_atk_boundaries_largestAdmissiblePrincipalMarksExactly() public onFork {
        deal(USDC, alice, 10_000_000e6);
        _mintFromUSDC(alice, 10_000_000e6);
        _mintFromUSDC(bob, 5_000_000e6);
        _mintFromUSDC(ops, 5_000_000e6);
        uint256 sharesA = _stake(alice, 8_000_000e18);
        _postFirstLoss(FILM, 1_000_000e18);
        _fundCoverage(ops, 2_000_000e18);

        bytes32 borrowerId = keccak256("FORK_BORROWER");
        bytes32 stateId = keccak256("US-GA");
        (uint16 borrowerLimitBps, uint16 stateLimitBps,) = registry.limits();
        assertEq(borrowerLimitBps, Config.BPS, "precondition: relative borrower limit at parity on this deployment");
        assertEq(stateLimitBps, Config.BPS, "precondition: relative state limit at parity on this deployment");
        uint256 headroom = registry.concentrationHeadroom(FILM, borrowerId, stateId);
        uint256 numeric =
            type(uint256).max / Config.BPS - registry.totalBookExposure() - reserves.accrualReservedExposure();
        assertEq(headroom, numeric, "the numeric guard is the binding limit");

        // Exactly the headroom is admitted, one wei more is refused, before any relative test.
        registry.checkConcentration(FILM, borrowerId, stateId, headroom);
        vm.expectRevert(ICollateralRegistry.Registry_PrincipalTooLarge.selector);
        registry.checkConcentration(FILM, borrowerId, stateId, headroom + 1);

        // The largest facility the fixture's real USDC can fund.
        uint256 principal = 10_000_000e18;
        uint256 id = _originateAndFund(principal);
        assertEq(reserves.deployedTo(id), principal, "the maximal facility is funded at face");
        _declareDefault(id, keccak256("atk-cim-a4c"));

        uint256 mark = _legacyMark();
        assertEq(mark, principal - 1_000_000e18 - 2_000_000e18, "face less both junior layers, exactly, no overflow");
        assertEq(mark, _modelMark(), "calculator == closed form at the ceiling");
        assertEq(mark, _nativeMark(), "calculator == native at the ceiling");
        assertEq(vault.redemptionTotalAssets(), vault.totalAssets() - mark, "exit base at the ceiling");
        assertEq(
            vault.previewRedeem(sharesA),
            Math.mulDiv(sharesA, vault.redemptionTotalAssets() + 1, vault.totalSupply() + SHARE_OFFSET),
            "the exit quote at the ceiling is the floor of the exact value"
        );

        // Full write-off at the ceiling: 1M curator, 2M reserve, 7M senior.
        uint256 assetsBefore = vault.totalAssets();
        _realizeLossExpectingCascade(id, FILM, principal, 1_000_000e18, 2_000_000e18, principal - 3_000_000e18);
        assertEq(
            vault.totalAssets(),
            assetsBefore - (principal - 3_000_000e18),
            "the senior layer absorbed exactly the residual"
        );
        assertEq(_legacyMark(), 0, "no mark after the full write-off");
        assertEq(_nativeMark(), 0, "native agrees");
        assertEq(vault.redemptionTotalAssets(), vault.totalAssets(), "exit base == realized base");
        assertEq(
            vault.redemptionTotalAssets(), assetsBefore - mark, "the exit base is exactly where the mark had put it"
        );
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "backing invariant after the maximal loss");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A5 (I1, I3): exit at the mark through the real queue
    // ─────────────────────────────────────────────────────────────────────

    /// @notice alice queues her whole position while a declared default stands, settles after the
    ///         21-day cooldown and is paid EXACTLY the conservative quote, never the pre-impairment
    ///         quote. The borrower then repays in full, the mark clears, and bob, with an identical
    ///         position, is paid the higher, correct amount at the restored price.
    /// @dev Attacks I1 and I3. Paying alice above the conservative quote transfers value from bob,
    ///      who stays through the workout; paying her less than the quote is the queue keeping senior
    ///      principal. Both are exact to the wei here.
    function test_atk_exitAtTheMarkPaysExactlyTheConservativeQuoteAndNeverMore() public onFork {
        ExitScene memory e;
        _mintFromUSDC(alice, 2_000_000e6);
        _mintFromUSDC(bob, 2_000_000e6);
        e.sharesA = _stake(alice, 1_000_000e18);
        e.sharesB = _stake(bob, 1_000_000e18);
        assertEq(e.sharesA, e.sharesB, "identical positions");
        _mintFromUSDC(ops, 500_000e6);
        _postFirstLoss(FILM, 100_000e18);
        _fundCoverage(ops, 200_000e18);
        e.id = _originateAndFund(1_000_000e18);
        queue.setEpochLiquidityBps(10_000); // ops: whole idle reserve available to settle

        e.parQuoteA = vault.previewRedeem(e.sharesA);
        e.parQuoteB = vault.previewRedeem(e.sharesB);
        assertEq(e.parQuoteA, e.parQuoteB, "same quote for the same position before the default");

        _declareDefault(e.id, keccak256("atk-cim-a5"));
        e.mark = _legacyMark();
        assertEq(e.mark, 700_000e18, "1M less 100k curator less 200k reserve");
        assertEq(e.mark, _nativeMark(), "the calculator's mark is the mark the vault prices with");
        e.markedQuoteA = vault.previewRedeem(e.sharesA);
        assertLt(e.markedQuoteA, e.parQuoteA, "the exit quote fell on declaration");

        _exitAliceAtTheMark(e);
        _exitBobAfterRecovery(e);
    }

    /// @dev A5, first half: alice queues at the mark, settles after the cooldown, is paid the quote.
    function _exitAliceAtTheMark(ExitScene memory e) internal {
        vm.startPrank(alice);
        vault.approve(address(queue), e.sharesA);
        uint256 reqA = queue.requestRedeem(e.sharesA);
        vm.stopPrank();

        _warpToSettleable();
        _freshen();
        assertEq(_legacyMark(), e.mark, "the mark did not drift across the cooldown");
        assertEq(vault.previewRedeem(e.sharesA), e.markedQuoteA, "nor did the quote");
        uint256 supply = vault.totalSupply() + SHARE_OFFSET;
        uint256 assets = vault.totalAssets();
        assertEq(vault.redemptionTotalAssets(), assets - e.mark, "exit base == realized assets - mark at settlement");
        uint256 expectedA = Math.mulDiv(e.sharesA, assets - e.mark + 1, supply);
        assertEq(e.markedQuoteA, expectedA, "the settlement quote is the floor of the exact conservative value");

        vm.expectEmit(true, true, true, true, address(queue));
        emit RequestFilled(reqA, e.sharesA, expectedA, queue.currentEpoch());
        queue.closeEpoch(10);
        (, uint256 remA, uint256 claimableA,,) = queue.request(reqA);
        assertEq(remA, 0, "alice's position filled in full");
        assertEq(claimableA, expectedA, "the fill is EXACTLY the conservative quote");
        assertLe(claimableA, e.parQuoteA, "and never the pre-impairment quote");
        // The haircut is exactly the difference of the two floors over the same supply and assets.
        assertEq(
            e.parQuoteA - claimableA,
            Math.mulDiv(e.sharesA, assets + 1, supply) - expectedA,
            "the haircut is alice's share of the mark, to the wei"
        );

        uint256 aliceBefore = usdfr.balanceOf(alice);
        vm.prank(alice);
        e.paidA = queue.claim(reqA);
        assertEq(e.paidA, claimableA, "claim pays the fill");
        assertEq(usdfr.balanceOf(alice) - aliceBefore, e.paidA, "alice received exactly the fill");
    }

    /// @dev A5, second half: the borrower repays in full, the mark clears, bob exits at the restored price.
    function _exitBobAfterRecovery(ExitScene memory e) internal {
        _repay(e.id, 0, 1_000_000e18);
        assertEq(_legacyMark(), 0, "the mark cleared on the clean resolve");
        assertEq(_nativeMark(), 0, "native agrees");
        assertEq(vault.redemptionTotalAssets(), vault.totalAssets(), "exit base restored to the realized base");
        assertEq(sGrove.coverageReserve(), 200_000e18, "the reserve was never drawn");
        assertEq(curator.poolBalance(FILM), 100_000e18, "the curator pool was never drawn");

        uint256 restoredQuoteB = vault.previewRedeem(e.sharesB);
        assertGt(restoredQuoteB, e.paidA, "the stayer is now quoted more than the exiter was paid");
        assertGe(restoredQuoteB, e.parQuoteB, "the exit at the mark took nothing from the stayer");

        vm.startPrank(bob);
        vault.approve(address(queue), e.sharesB);
        uint256 reqB = queue.requestRedeem(e.sharesB);
        vm.stopPrank();
        _warpToSettleable();
        _freshen();
        uint256 expectedB =
            Math.mulDiv(e.sharesB, vault.redemptionTotalAssets() + 1, vault.totalSupply() + SHARE_OFFSET);
        assertEq(
            vault.previewRedeem(e.sharesB), expectedB, "bob's settlement quote is the floor of the exact restored value"
        );
        queue.closeEpoch(10);
        (, uint256 remB, uint256 claimableB,,) = queue.request(reqB);
        assertEq(remB, 0, "bob's position filled in full");
        assertEq(claimableB, expectedB, "bob is paid EXACTLY the restored quote");
        assertGt(claimableB, e.paidA, "the next redeemer gets the higher, correct amount");
        uint256 bobBefore = usdfr.balanceOf(bob);
        vm.prank(bob);
        uint256 paidB = queue.claim(reqB);
        assertEq(usdfr.balanceOf(bob) - bobBefore, paidB, "bob received exactly his fill");
        assertEq(paidB, claimableB, "claim pays the fill");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A6 (access control): the mark cannot be lowered by an outsider
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Every direct route by which the non-KYC, role-less attacker could LOWER the mark, and
    ///         so raise her own exit price at the stayers' expense, is refused with its exact error
    ///         and leaves the mark, the row and the junior layers untouched.
    /// @dev Attacks the access-control invariant on the value path the calculator reads. The
    ///      calculator itself is a pure view with nothing to seize; the attack surface is its inputs.
    function test_atk_theMarkCannotBeLoweredByAnUnprivilegedCaller() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 2_000_000e18);
        _mintFromUSDC(ops, 500_000e6);
        _postFirstLoss(FILM, 100_000e18);
        _fundCoverage(ops, 200_000e18);
        uint256 id = _originateAndFund(1_000_000e18);
        _declareDefault(id, keccak256("atk-cim-a6"));
        uint256 mark = _legacyMark();
        assertEq(mark, 700_000e18, "precondition: a standing mark");
        CommitmentLedger ledger = _ledger();

        // realizeLoss lowers the declared face: SERVICER_ROLE only.
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.SERVICER_ROLE)
        );
        defaultManager.realizeLoss(id, 1e18, keccak256("carol"));

        // The two credit hooks that clear or re-anchor a contribution: CREDIT_ROLE only.
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.CREDIT_ROLE)
        );
        defaultManager.onDefaultResolved(id);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.CREDIT_ROLE)
        );
        defaultManager.onDefaultRecovery(id);

        // The ledger row: manager only.
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(CommitmentLedger.CommitmentLedger_NotManager.selector, carol));
        ledger.updatePrincipal(id, 0);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(CommitmentLedger.CommitmentLedger_NotManager.selector, carol));
        ledger.release(id);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(CommitmentLedger.CommitmentLedger_NotManager.selector, carol));
        ledger.sync(id, 0, 0, 1);

        // Raising the junior layers lowers the mark legitimately; the attacker cannot fake it and
        // the anchor curator cannot pull frozen first-loss out from under it.
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.CREDIT_ROLE)
        );
        curator.absorbLoss(FILM, 1e18);

        assertEq(_legacyMark(), mark, "no refused call moved the mark");
        assertEq(_nativeMark(), mark, "nor the native mark");
        assertEq(ledger.remainingPrincipalForClass(FILM), 1_000_000e18, "the row is untouched");
        assertEq(curator.poolBalance(FILM), 100_000e18, "layer 1 untouched");
        assertEq(sGrove.coverageReserve(), 200_000e18, "layer 2 untouched");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Independent models (CLAUDE.md 1.5: a reference computed from primitives)
    // ─────────────────────────────────────────────────────────────────────

    /// @dev The calculator under test, read exactly as the deployed proxy would route to it.
    function _legacyMark() internal view returns (uint256) {
        ConservativeImpairmentMath calc = defaultManager.impairmentMath();
        return calc.pendingSeniorImpairment(address(defaultManager));
    }

    /// @dev The mark the vault prices with on this deployment (the native accrual path).
    function _nativeMark() internal view returns (uint256) {
        return defaultManager.pendingSeniorImpairment();
    }

    function _ledger() internal view returns (CommitmentLedger ledger) {
        (,,,,,,, address l) = defaultManager.modules();
        ledger = CommitmentLedger(l);
    }

    function _liveReserve() internal view returns (uint256) {
        address backstop = defaultManager.backstop();
        return backstop == address(0) ? 0 : ICascadeBackstop(backstop).coverageReserve();
    }

    /// @dev Closed form over the MANAGER's class books (`declaredDefaultedPrincipal`,
    ///      `pastDuePrincipal`), the curator pools and the one shared reserve. Independent of the
    ///      ledger's per-class totals and of its rows.
    function _modelResiduals() internal view returns (Residuals memory r) {
        uint256 pastDueResidual;
        uint256 declaredResidual;
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            uint256 pastDue = defaultManager.pastDuePrincipal(c);
            uint256 pool = curator.poolBalance(c);
            uint256 pdCurator = _min(pastDue, pool);
            pastDueResidual += pastDue - pdCurator;
            uint256 declared = defaultManager.declaredDefaultedPrincipal(c);
            declaredResidual += declared - _min(declared, pool - pdCurator);
        }
        uint256 reserve = _liveReserve();
        uint256 pdLayerTwo = _min(pastDueResidual, reserve);
        r.pastDueSenior = pastDueResidual - pdLayerTwo;
        r.residual = r.pastDueSenior + declaredResidual - _min(declaredResidual, reserve - pdLayerTwo);
    }

    /// @dev The registry's governed step, recomputed: executable clamp first, ramped weight second,
    ///      the division rounding UP.
    function _registryModel(Residuals memory r) internal view returns (uint256) {
        uint256 declaredSenior = r.residual - r.pastDueSenior;
        uint256 vaultAssets = vault.totalAssets();
        uint256 executable = vaultAssets > declaredSenior ? vaultAssets - declaredSenior : 0;
        uint256 amount = _min(r.pastDueSenior, executable);
        uint256 elapsed = block.timestamp - defaultManager.pastDueReliefAnchor();
        uint256 ramp = Config.DEFAULT_REDEEM_COOLDOWN;
        if (elapsed >= ramp) return declaredSenior + amount;
        uint256 w0 = registry.pastDueWeightBps();
        uint256 w = w0 + ((Config.BPS - w0) * elapsed) / ramp;
        return declaredSenior + (amount * w + Config.BPS - 1) / Config.BPS;
    }

    function _modelMark() internal view returns (uint256) {
        Residuals memory r = _modelResiduals();
        if (r.residual == 0) return 0;
        return _registryModel(r);
    }

    /// @dev The RETIRED algorithm, reconstructed from the deployment-era `conservativeResiduals` and
    ///      `_declaredJuniorDelivery` over the ledger's live rows in declaration order and in reverse.
    function _retiredLadderResiduals() internal view returns (Residuals memory r) {
        CommitmentLedger ledger = _ledger();
        LadderState memory s;
        for (uint256 i = 0; i < Config.NUM_CLASSES; ++i) {
            uint256 pastDue = defaultManager.pastDuePrincipal(i + 1);
            uint256 pool = curator.poolBalance(i + 1);
            uint256 pdCurator = _min(pastDue, pool);
            s.pastDueGross += pastDue;
            s.pastDueResidual += pastDue - pdCurator;
            s.avail[i] = pool - pdCurator;
        }
        uint256 n = ledger.eventCount();
        for (uint256 k = 0; k < n; ++k) {
            (,,, uint256 principal) = ledger.eventInfo(ledger.eventAt(k));
            s.gross += principal;
        }
        s.gross += s.pastDueGross;
        if (s.gross == 0) return r;
        s.backstop = defaultManager.backstop();
        if (s.backstop != address(0)) {
            s.reserve = ICascadeBackstop(s.backstop).coverageReserve();
            if (s.pastDueResidual != 0 && s.reserve != 0) {
                s.pdLayerTwo = _min(s.pastDueResidual, s.reserve);
                s.reserve -= s.pdLayerTwo;
            }
        }
        uint256 forward = _ladderDelivery(ledger, s, false);
        uint256 reverse = _ladderDelivery(ledger, s, true);
        uint256 declaredJunior = _min(forward, reverse);
        uint256 pastDueJunior = s.pastDueGross - s.pastDueResidual + s.pdLayerTwo;
        r.residual = s.gross - pastDueJunior - declaredJunior;
        r.pastDueSenior = s.pastDueResidual - s.pdLayerTwo;
    }

    function _ladderDelivery(CommitmentLedger ledger, LadderState memory s, bool reverse)
        internal
        view
        returns (uint256 delivered)
    {
        uint256[5] memory avail;
        for (uint256 i = 0; i < 5; ++i) {
            avail[i] = s.avail[i]; // explicit copy: memory arrays assign by reference
        }
        uint256 reserve = s.reserve;
        uint256 n = ledger.eventCount();
        for (uint256 k = 0; k < n; ++k) {
            uint256 eventId = reverse ? ledger.eventAt(n - 1 - k) : ledger.eventAt(k);
            (uint256 classId,,, uint256 principal) = ledger.eventInfo(eventId);
            if (principal == 0) continue;
            uint256 take = _min(principal, avail[classId - 1]);
            if (take != 0) {
                avail[classId - 1] -= take;
                principal -= take;
                delivered += take;
            }
            if (principal == 0 || reserve == 0 || s.backstop == address(0)) continue;
            uint256 layerTwo = _min(principal, reserve);
            delivered += layerTwo;
            reserve -= layerTwo;
        }
    }

    /// @dev The whole equivalence: ledger == closed form == retired ladder; calculator == registry
    ///      model == live native mark; per-class totals == class books; exit base == assets - mark.
    function _assertCalculatorAgreesEverywhere(string memory ctx) internal view {
        (uint256 lr, uint256 lp) = _ledger().conservativeResiduals();
        Residuals memory m = _modelResiduals();
        Residuals memory old = _retiredLadderResiduals();
        assertEq(lr, m.residual, string.concat(ctx, ": ledger residual != closed form over the class books"));
        assertEq(lp, m.pastDueSenior, string.concat(ctx, ": ledger past-due senior != closed form"));
        assertEq(
            lr, old.residual, string.concat(ctx, ": class aggregate != min(forward, reverse) of the retired ladder")
        );
        assertEq(lp, old.pastDueSenior, string.concat(ctx, ": past-due senior != the retired ladder's"));
        assertLe(lp, lr, string.concat(ctx, ": pastDueSenior <= residual, or the registry underflows"));
        uint256 legacy = _legacyMark();
        assertEq(legacy, _modelMark(), string.concat(ctx, ": calculator != registry model"));
        assertEq(
            legacy,
            _nativeMark(),
            string.concat(ctx, ": calculator != live native mark, the migration re-prices the exit")
        );
        _assertPerClassPrincipalReconciles(ctx);
        uint256 assets = vault.totalAssets();
        assertEq(
            vault.redemptionTotalAssets(),
            legacy >= assets ? 0 : assets - legacy,
            string.concat(ctx, ": exit base != realized assets less the mark")
        );
    }

    /// @dev Per class: the appended total == the sum of the live rows in that class == the manager's
    ///      declared book.
    function _assertPerClassPrincipalReconciles(string memory ctx) internal view {
        CommitmentLedger ledger = _ledger();
        uint256 n = ledger.eventCount();
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            uint256 rows;
            for (uint256 k = 0; k < n; ++k) {
                (uint256 classId,,, uint256 principal) = ledger.eventInfo(ledger.eventAt(k));
                if (classId == c) rows += principal;
            }
            uint256 total = ledger.remainingPrincipalForClass(c);
            assertEq(total, rows, string.concat(ctx, ": per-class total != sum of its live rows"));
            assertEq(
                total,
                defaultManager.declaredDefaultedPrincipal(c),
                string.concat(ctx, ": per-class total != declaredDefaultedPrincipal")
            );
        }
    }

    /// @dev Inside the ramp: the ledger pair equals the closed form, the mark equals the calculator,
    ///      the native mark and the registry model, and the weighted charge rounds UP. Returns the
    ///      calculator's mark so the caller can order it against the other instants.
    function _assertRampedMarkRoundsUp(uint256 anchor, string memory ctx) internal view returns (uint256 mark) {
        Residuals memory r = _modelResiduals();
        (uint256 lr, uint256 lp) = _ledger().conservativeResiduals();
        assertEq(lr, r.residual, string.concat(ctx, ": ledger residual"));
        assertEq(lp, r.pastDueSenior, string.concat(ctx, ": ledger past-due senior"));
        uint256 declaredSenior = lr - lp;
        uint256 vaultAssets = vault.totalAssets();
        uint256 executable = vaultAssets > declaredSenior ? vaultAssets - declaredSenior : 0;
        uint256 amount = _min(lp, executable);
        assertLt(amount, lp, string.concat(ctx, ": precondition, the executable clamp binds"));
        uint256 elapsed = block.timestamp - anchor;
        assertLt(elapsed, Config.DEFAULT_REDEEM_COOLDOWN, string.concat(ctx, ": precondition, inside the ramp"));
        uint256 w0 = registry.pastDueWeightBps();
        uint256 w = w0 + ((Config.BPS - w0) * elapsed) / Config.DEFAULT_REDEEM_COOLDOWN;
        assertTrue((amount * w) % Config.BPS != 0, string.concat(ctx, ": precondition, the weighted charge is inexact"));
        mark = _legacyMark();
        assertEq(mark, _nativeMark(), string.concat(ctx, ": calculator != live native mark"));
        assertEq(mark, _registryModel(r), string.concat(ctx, ": calculator != registry model"));
        assertGe(
            mark * Config.BPS,
            declaredSenior * Config.BPS + amount * w,
            string.concat(ctx, ": rounds UP, never below the exact weighted charge")
        );
        assertLt(
            mark * Config.BPS,
            declaredSenior * Config.BPS + amount * w + Config.BPS,
            string.concat(ctx, ": but by less than one unit")
        );
        assertEq(
            mark,
            declaredSenior + (amount * w + Config.BPS - 1) / Config.BPS,
            string.concat(ctx, ": the ceiling, exactly")
        );
        assertLt(w, Config.BPS, string.concat(ctx, ": the ramped weight stays below parity inside the ramp"));
    }

    // ─────────────────────────────────────────────────────────────────────
    // Fixture additions private to this file (the shared fixture is untouched)
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Originate a FILM facility through the real mint gate and stop at Pending.
    function _originatePending(uint256 principal) internal returns (uint256 tokenId) {
        tokenId = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + 365 days);
        _attestFilmGate(
            tokenId, keccak256("FORK_BORROWER"), keccak256("US-GA"), principal, 7500, maturity, keccak256("ucc-ref")
        );
        vm.prank(ops);
        uint256 id = bridge.originate(
            ops,
            _forkTerms(keccak256("FORK_BORROWER"), keccak256("US-GA"), principal, 7500, maturity, keccak256("ucc-ref"))
        );
        require(id == tokenId, "ATK_CIM: tokenId drift");
    }

    /// @dev Originate in an arbitrary receivable class with an arbitrary borrower, then fund.
    function _originateAndFundIn(uint256 classId, bytes32 borrowerId, uint256 principal)
        internal
        returns (uint256 tokenId)
    {
        tokenId = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + 365 days);
        bytes32 ref = keccak256(abi.encode("cim-ref", tokenId));
        bytes32 stateId = classId == FILM ? keccak256("US-GA") : bytes32(0);
        ClaimBridge.OriginationTerms memory terms =
            _forkTermsFor(classId, borrowerId, stateId, principal, 7500, 1000, maturity, ref);
        bytes32 termsHash = bridge.creditTermsHash(terms);
        _attest(tokenId, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash);
        _attest(tokenId, IAttestationOracle.AttestationKind.UCCFiled, termsHash);
        _attest(tokenId, IAttestationOracle.AttestationKind.CreditIssued, termsHash);
        vm.prank(ops);
        uint256 id = bridge.originate(ops, terms);
        require(id == tokenId, "ATK_CIM: tokenId drift");
        vm.prank(ops);
        waterfall.fund(tokenId, principal / 1e12);
    }

    /// @dev Attest a loss, bind the cascade event to the call, then realize it as the servicer.
    ///      Split from the fixture's `_realizeLoss` because `vm.expectEmit` binds to the NEXT
    ///      external call, and the fixture attests (several calls) before it realizes.
    function _realizeLossExpectingCascade(
        uint256 id,
        uint256 classId,
        uint256 loss,
        uint256 absorbed,
        uint256 covered,
        uint256 senior
    ) internal {
        bytes32 evidence = _attestLoss(id, loss, bytes32(0));
        vm.expectEmit(true, true, true, true, address(defaultManager));
        emit LossRealized(id, classId, loss, absorbed, covered, senior);
        vm.prank(ops);
        defaultManager.realizeLoss(id, loss, evidence);
    }

    /// @dev Deliver a principal-only repayment into the treasury and attest it, returning the exact
    ///      `Payment` the servicer must distribute; mirrors the fixture's `_repay` so a test can bind
    ///      an event expectation to the `distribute` call itself.
    function _prepPrincipalRepayment(uint256 id, uint256 principalRepaid)
        internal
        returns (IWaterfallEngine.Payment memory p)
    {
        uint256 stableAmount = principalRepaid / 1e12;
        deal(USDC, borrower, usdcBalance(borrower) + stableAmount);
        vm.prank(borrower);
        IERC20(USDC).approve(address(reserves), stableAmount);
        ClaimBridge.Facility memory f = bridge.facility(id);
        uint64 nextDue = principalRepaid == reserves.deployedTo(id) ? 0 : f.nextPaymentDue + f.paymentInterval;
        bytes32 paymentId = keccak256(abi.encode("cim-payment", id, principalRepaid));
        _attest(
            id,
            IAttestationOracle.AttestationKind.PaymentReceived,
            keccak256(abi.encode(paymentId, id, USDC, borrower, stableAmount, uint256(0), principalRepaid, nextDue))
        );
        p = IWaterfallEngine.Payment({
            tokenId: id,
            paymentId: paymentId,
            payer: borrower,
            interest: 0,
            principal: principalRepaid,
            nextPaymentDue: nextDue
        });
    }

    function usdcBalance(address who) internal view returns (uint256) {
        return IERC20(USDC).balanceOf(who);
    }

    /// @dev Permissionless coverage funding from `who`.
    function _fundCoverage(address who, uint256 amount) internal {
        vm.startPrank(who);
        usdfr.approve(address(sGrove), amount);
        sGrove.fundCoverage(amount);
        vm.stopPrank();
    }

    /// @dev Post curator first-loss for a class as the anchor curator (`ops`).
    function _postFirstLoss(uint256 classId, uint256 amount) internal {
        vm.startPrank(ops);
        usdfr.approve(address(curator), amount);
        curator.postFirstLoss(classId, amount);
        vm.stopPrank();
    }

    /// @dev Permissionless accrual maintenance after a warp, driven by the attacker: any due
    ///      boundary is processed so price-sensitive reads and writes are fresh.
    function _freshen() internal {
        for (uint256 i = 0; i < 8; ++i) {
            vm.prank(carol);
            (, bool fresh) = reserves.checkpointAccrual(32);
            if (fresh) return;
        }
        revert("ATK_CIM: accrual book still stale after eight checkpoints");
    }

    /// @dev Warp to the earliest moment the current head can settle: past the heartbeat AND past
    ///      the head's ADR-0022 forced cooldown.
    function _warpToSettleable() internal {
        uint256 target = uint256(queue.epochEndsAt());
        uint256 h = queue.head();
        if (h < queue.totalRequests()) {
            uint256 eligibleAt = queue.eligibleToSettleAt(h);
            if (eligibleAt > target) target = eligibleAt;
        }
        if (block.timestamp < target) _warp(target - block.timestamp);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
