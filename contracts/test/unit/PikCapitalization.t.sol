// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {Config} from "../../src/libraries/Config.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {MockAttestationOracle} from "../helpers/MockAttestationOracle.sol";

/// @title PikCapitalization - the PIK interest capitalisation path
///
/// @notice PORTED FROM THE BSC INSTANCE 2026-09-09. The Ethereum tree had NO PIK test of any kind,
///         which is why the two defects `b354a90` fixed on BSC shipped here unnoticed in `6845eee`.
///         The spec is `docs/SPEC_INTEREST_ACCRUAL.md` in the BSC repository.
///
/// @dev SINGLE-ASSET ADAPTATIONS from the BSC original: no asset parameter on any reserve call, the
///      scale grid is `reserves.normalizeUSDC(1)` rather than a per-asset record, and
///      `_repayPrincipal` delegates to the fixture's own `_repay`.
///
/// @notice THE PROPERTY THAT MATTERS MOST IS SURPLUS-NEUTRALITY, and it has its own test. Every
///         other assertion here guards a bound; that one guards the loss cascade. Capitalisation
///         raises backing on a promise, and `ReserveCascadeLib._recognize` absorbs a ratified loss
///         out of `backing - supply` BEFORE the cascade runs. A capitalisation that moved backing
///         without moving supply by the same amount would let losses skip the curator draw
///         entirely, which is the exact defect proved and fixed in this tree on 2026-09-08.
///
/// @dev THE FIXTURE'S FACILITY IS Fixed / Actual360 / 30-day interval / 1400 bps / 365-day maturity.
///      One interval on principal P is `P * 1400 * 30 / (10000 * 360)`, i.e. 7/600 of P.
contract PikCapitalizationTest is CreditLayerFixture {
    uint256 internal constant P = 1_000_000e18;
    bytes32 internal constant BORROWER = keccak256("pik-borrower");
    bytes32 internal constant STATE = keccak256("pik-state");

    uint256 internal tokenId;

    /// @dev Every facility this suite originates is a PIK facility. Without the designation
    ///      `capitalizePik` refuses, which is the whole point of it.
    function _pikFacilities() internal view virtual override returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();
        _mintUSDfrTo(alice, 10_000_000e18);
        tokenId = _originateFilm(BORROWER, STATE, P);
        _fundFacility(tokenId, P);
    }

    /// @dev One interval of Actual/360 at the fixture's rate, on an arbitrary balance, ROUNDED DOWN
    ///      TO THE USDC GRID exactly as `_planPik` does.
    ///
    ///      THIS IS THE ONE REFERENCE-MODEL DIFFERENCE FROM THE BSC ORIGINAL, and it is a property
    ///      of the asset rather than of the arithmetic. BSC's fixture asset carries 18 decimals, so
    ///      its scale is 1 and the grid step is invisible there. Ethereum settles in 6-decimal USDC,
    ///      so `normalizeUSDC(1)` is 1e12 and a value the currency cannot express is truncated. The
    ///      contract rounds down so the protocol never recognises a wei it cannot be repaid; the
    ///      model must round the same way or it is not a model of this chain.
    function _oneInterval(uint256 balance) internal view returns (uint256) {
        uint256 raw = (balance * 1400 * 30 days) / (uint256(Config.BPS) * 360 days);
        uint256 scale = reserves.normalizeUSDC(1);
        return (raw / scale) * scale;
    }

    /// @dev The same Actual/360 arithmetic over an ARBITRARY window, for the first period, which
    ///      accrues from FUNDING rather than from the schedule anchor (Forest Road, 2026-09-10).
    function _window(uint256 balance, uint256 seconds_) internal view returns (uint256) {
        uint256 raw = (balance * 1400 * seconds_) / (uint256(Config.BPS) * 360 days);
        uint256 scale = reserves.normalizeUSDC(1);
        return (raw / scale) * scale;
    }

    /// @dev Truncate to the USDC grid, for expectations computed at a rate other than the
    ///      fixture's. Same reason as `_oneInterval`: the contract cannot recognise a sub-grid wei.
    function _toGrid(uint256 v) internal view returns (uint256) {
        uint256 scale = reserves.normalizeUSDC(1);
        return (v / scale) * scale;
    }

    function _surplus() internal view returns (uint256) {
        uint256 backing = reserves.totalBackingValue();
        uint256 supply = usdfr.totalSupply();
        return backing > supply ? backing - supply : 0;
    }

    // ---------------------------------------------------------------------
    //  The load-bearing property
    // ---------------------------------------------------------------------

    /// @notice CAPITALISATION IS SURPLUS-NEUTRAL. Backing and supply move by the SAME amount, so
    ///         `backing - supply` is untouched and no phantom surplus is created.
    /// @dev If this fails, the loss cascade can be skipped: `_recognize` absorbs a ratified loss out
    ///      of the surplus before any curator capital is drawn. Do not "fix" this by adjusting the
    ///      tolerance; the equality is the point.
    function test_PIK_capitalisationIsSurplusNeutral() public {
        uint256 surplusBefore = _surplus();
        uint256 backingBefore = reserves.totalBackingValue();
        uint256 supplyBefore = usdfr.totalSupply();

        vm.warp(block.timestamp + 30 days);
        uint256 amount = waterfall.capitalizePik(tokenId);

        assertGt(amount, 0, "nothing capitalised");
        assertEq(reserves.totalBackingValue(), backingBefore + amount, "backing did not rise by the amount");
        assertEq(usdfr.totalSupply(), supplyBefore + amount, "supply did not rise by the amount");
        assertEq(_surplus(), surplusBefore, "SURPLUS MOVED: the cascade can now be skipped");
    }

    /// @notice The senior vault is where the value lands, so the exchange rate reflects it.
    function test_PIK_theValueSplitsBetweenSeniorVaultAndProtocol() public {
        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        uint256 protocolBefore = usdfr.balanceOf(feeRecipient);
        uint256 supplyBefore = usdfr.totalSupply();
        vm.warp(block.timestamp + 30 days);
        uint256 amount = waterfall.capitalizePik(tokenId);
        uint256 fee = amount * waterfall.protocolFeeBps() / Config.BPS;
        assertEq(usdfr.balanceOf(address(vault)) - vaultBefore, amount - fee, "senior income after protocol fee");
        assertEq(usdfr.balanceOf(feeRecipient) - protocolBefore, fee, "protocol interest fee");
        assertEq(usdfr.totalSupply() - supplyBefore, amount, "complete interest allocation conserves value");
    }

    // ---------------------------------------------------------------------
    //  The arithmetic
    // ---------------------------------------------------------------------

    function test_PIK_oneIntervalOfActual360() public {
        vm.warp(block.timestamp + 30 days);
        uint256 amount = waterfall.capitalizePik(tokenId);
        assertEq(amount, _oneInterval(P), "not one Actual/360 interval");
        assertEq(reserves.deployedTo(tokenId), P + amount, "deployed did not absorb it");
    }

    /// @notice IT COMPOUNDS, which is what PIK means: the second interval is larger than the first.
    function test_PIK_compoundsOnTheGrownBalance() public {
        vm.warp(block.timestamp + 30 days);
        uint256 first = waterfall.capitalizePik(tokenId);
        vm.warp(block.timestamp + 30 days);
        uint256 second = waterfall.capitalizePik(tokenId);
        assertEq(second, _oneInterval(P + first), "the second interval did not compound on the new balance");
        assertGt(second, first, "PIK did not compound");
    }

    /// @notice THE FREQUENCY MANIPULATION IS CLOSED. Cranking is permissionless, and capitalisation
    ///         compounds, so "time since last call" would let a caller compound continuously and
    ///         extract more than the contract owes. Fixing the quantum at one `paymentInterval`
    ///         makes the total path-independent.
    /// @dev Two facilities, identical terms. One is cranked at every opportunity, the other is left
    ///      alone and caught up at the end. Same elapsed time, same balance, to the wei.
    function test_PIK_totalIsIndependentOfHowOftenItIsCranked() public {
        uint256 lazy = _originateFilm(keccak256("lazy-borrower"), STATE, P);
        _fundFacility(lazy, P);

        for (uint256 i; i < 6; ++i) {
            vm.warp(block.timestamp + 30 days);
            waterfall.capitalizePik(tokenId); // eager: crank every interval
        }
        for (uint256 i; i < 6; ++i) {
            waterfall.capitalizePik(lazy); // lazy: six intervals elapsed, caught up in one go
        }

        assertEq(
            reserves.deployedTo(lazy), reserves.deployedTo(tokenId), "crank frequency changed what the borrower owes"
        );
    }

    /// @notice Rounded DOWN to the asset's scale grid, so the protocol never recognises a wei it
    ///         cannot express in the facility's own currency.
    function test_PIK_roundsDownToTheAssetScaleGrid() public {
        vm.warp(block.timestamp + 30 days);
        uint256 amount = waterfall.capitalizePik(tokenId);
        uint256 scale = reserves.normalizeUSDC(1);
        assertEq((amount / scale) * scale, amount, "not on the grid");
    }

    // ---------------------------------------------------------------------
    //  The interval rule
    // ---------------------------------------------------------------------

    function test_PIK_refusesBeforeTheIntervalElapses() public {
        vm.warp(block.timestamp + 30 days - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWaterfallEngine.Waterfall_PikIntervalNotElapsed.selector, tokenId, uint64(block.timestamp + 1)
            )
        );
        waterfall.capitalizePik(tokenId);
    }

    /// @notice A facility left uncranked catches up ONE interval per call, and the schedule does not
    ///         drift: `lastAt` advances by the interval, never to `block.timestamp`.
    function test_PIK_catchesUpOneIntervalPerCallWithoutDrift() public {
        uint64 fundedAt = uint64(block.timestamp);
        vm.warp(block.timestamp + 95 days); // three intervals and a bit

        waterfall.capitalizePik(tokenId);
        (uint64 lastAt,) = waterfall.pikCursorOf(tokenId);
        assertEq(lastAt, fundedAt + 30 days, "the cursor jumped to now instead of advancing one interval");

        waterfall.capitalizePik(tokenId);
        waterfall.capitalizePik(tokenId);
        (lastAt,) = waterfall.pikCursorOf(tokenId);
        assertEq(lastAt, fundedAt + 90 days, "the schedule drifted");

        // The fourth interval is not due until day 120.
        vm.expectRevert(
            abi.encodeWithSelector(
                IWaterfallEngine.Waterfall_PikIntervalNotElapsed.selector, tokenId, fundedAt + 120 days
            )
        );
        waterfall.capitalizePik(tokenId);
    }

    /// @notice PERMISSIONLESS. The amount is a pure function of signed terms and the interval, so
    ///         the caller can choose nothing and there is no reason to gate it.
    function test_PIK_anyoneMayCrank() public {
        vm.warp(block.timestamp + 30 days);
        vm.prank(makeAddr("passer-by"));
        uint256 amount = waterfall.capitalizePik(tokenId);
        assertEq(amount, _oneInterval(P), "a bystander crank produced a different figure");
    }

    /// @notice A rejected legacy schedule change leaves all elapsed coupons at their signed rate.
    function test_FIXED_PIK_anAmendmentDoesNotRepriceABacklog() public {
        vm.warp(block.timestamp + 90 days); // three intervals pending, uncranked
        _amendRate(tokenId, 9000, true); // The attempted due-date move must be refused.

        uint256 i1 = waterfall.capitalizePik(tokenId);
        uint256 i2 = waterfall.capitalizePik(tokenId);
        uint256 i3 = waterfall.capitalizePik(tokenId);

        assertEq(i1, _oneInterval(P), "interval 1 was repriced");
        assertEq(i2, _oneInterval(P + i1), "interval 2 was repriced at the amended rate");
        assertEq(i3, _oneInterval(P + i1 + i2), "interval 3 was repriced at the amended rate");

        // The rejected amendment cannot become effective when the backlog is cleared.
        (, uint16 rate) = waterfall.pikCursorOf(tokenId);
        assertEq(rate, 1400, "a rejected amendment changed the contractual rate");
    }

    /// @notice An unsupported legacy interval change reverts and preserves every elapsed coupon.
    function test_FIXED_PIK_anIntervalAmendmentDoesNotRepriceAnElapsedBacklog() public {
        vm.warp(block.timestamp + 90 days); // three whole 30-day intervals stand

        uint256 snap = vm.snapshotState();
        uint256 cleanTotal;
        for (uint256 i; i < 3; ++i) {
            cleanTotal += waterfall.capitalizePik(tokenId);
        }
        vm.revertToState(snap);

        // Refuse doubling the interval after the three periods have already elapsed.
        _rejectIntervalAmendment(tokenId, 60 days);
        uint256 afterAmend;
        for (uint256 i; i < 3; ++i) {
            try waterfall.capitalizePik(tokenId) returns (uint256 got) {
                afterAmend += got;
            } catch {
                break;
            }
        }
        assertEq(
            afterAmend,
            cleanTotal,
            "AN AMENDMENT REPRICED ELAPSED PERIODS: the interval is not snapshotted the way the rate is"
        );
    }

    /// @notice A STANDING BACKING DEFICIT MUST NOT FREEZE THE CRANK.
    /// @dev THIS TEST WAS A PINNED DEFECT FOR PART OF 2026-09-09 AND IS NOW A PROPERTY. It used to
    ///      assert the revert, under the name `test_OPEN_DEFECT_...`, because a single one-USDC
    ///      conservative mark on an UNRELATED facility froze every PIK capitalisation in the book.
    ///
    ///      `capitalizePik` raises backing and then supply by the identical amount, so the deficit
    ///      changes by exactly zero. `mintYield` snapshotted supply and backing ITSELF, after
    ///      backing had already risen, so for a standing deficit D it read deficitBefore as
    ///      max(0, D - a) against a deficitAfter of D and called that neutral pair a worsening.
    ///      The rule was right; the measurement point was wrong. `beginPairedYield` records the
    ///      TRUE pre-operation state and `mintYield` asserts against it, so a pair that is genuinely
    ///      deficit-neutral is admitted and one that is not still fails.
    ///
    ///      It matters beyond the failed call: `nextPaymentDue` only ever advances inside the
    ///      crank, so a frozen crank turned borrowers performing exactly as contracted into
    ///      permissionless past-due marks, and through `pastDueExposure` into senior impairment.
    function test_FIXED_PIK_aStandingDeficitDoesNotFreezeTheCrank() public {
        uint256 other = _originateFilm(keccak256("other-borrower"), STATE, P);
        _fundFacility(other, P);
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(other, 1e12, keccak256("mark-evidence"));
        uint256 deficitBefore = controller.recognizedDeficit();
        assertGt(deficitBefore, 0, "fixture must actually create a deficit");

        vm.warp(block.timestamp + 30 days);
        uint256 amount = waterfall.capitalizePik(tokenId);
        assertGt(amount, 0, "a standing deficit froze a surplus-neutral capitalisation");
        assertEq(controller.recognizedDeficit(), deficitBefore, "the capitalisation moved the deficit");
    }

    /// @notice A PIK FACILITY MUST NEVER SETTLE A PERIOD IN CASH AND IN KIND BOTH.
    /// @dev `distribute` never read `f.pik`, so a PIK facility could take an attested interest leg:
    ///      the leg routed to the senior vault as cash yield and advanced `nextPaymentDue`, while
    ///      `pikCursor` was left untouched. The permissionless crank then still saw the period
    ///      unsettled and capitalised it, growing `deployed` by a full period of interest the
    ///      borrower had ALREADY PAID and minting that same amount to the vault a second time. The
    ///      residue is a receivable nobody owes, which is exactly what the designation gate's own
    ///      NatSpec claims to have closed. That gate was one-directional: it stopped a cash-pay loan
    ///      capitalising, and nothing stopped a PIK loan paying cash.
    ///
    ///      Refusal is the right answer rather than "settle the cursor too", because the designation
    ///      cannot be amended and decision 7 of the spec settles where PIK interest returns: it
    ///      compounds into principal and comes back as `payment.principal`. A non-zero interest leg
    ///      on a PIK facility is therefore always a servicing error.
    function test_FIXED_PIK_aPikFacilityCannotSettleAPeriodInCash() public {
        vm.warp(block.timestamp + 30 days);
        uint256 interest = _oneInterval(P);

        IWaterfallEngine.Payment memory payment = _preparePayment(tokenId, interest, 0);
        vm.prank(servicer);
        vm.expectRevert(
            abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikCashInterestNotPermitted.selector, tokenId)
        );
        waterfall.distribute(payment);
    }

    /// @notice The principal-only receipt a PIK facility DOES use must keep working.
    function test_PIK_aPrincipalOnlyReceiptIsStillAccepted() public {
        vm.warp(block.timestamp + 30 days);
        waterfall.capitalizePik(tokenId);
        uint256 before = reserves.deployedTo(tokenId);
        _repayPrincipal(tokenId, P / 10);
        assertEq(reserves.deployedTo(tokenId), before - P / 10, "a principal-only repayment must still settle");
    }

    /// @notice THE SAME PROPERTY ACROSS A BACKLOG, WHICH IS WHERE THE FIRST FIX DID NOT REACH.
    /// @dev `cur.basis` made ONE elapsed period order-independent. The period after it was still
    ///      seeded from the CRANK-TIME balance (`plan.balanceAfter = outstanding + plan.amount`), so
    ///      with three intervals standing, a repayment landing before the catch-up still erased
    ///      interest on periods two and three: every one of those periods had already fully elapsed
    ///      at the old balance, and none of them can be retired by a later payment. The crank is
    ///      permissionless and unscheduled, so "repay, then someone cranks" is the ordinary
    ///      operational order and the losing one.
    function test_FIXED_PIK_aBacklogIsUnaffectedByRepaymentOrdering() public {
        vm.warp(block.timestamp + 90 days); // three whole intervals stand

        // Baseline: catch the backlog up with no repayment at all.
        uint256 snap = vm.snapshotState();
        uint256 cleanTotal;
        for (uint256 i; i < 3; ++i) {
            cleanTotal += waterfall.capitalizePik(tokenId);
        }
        vm.revertToState(snap);

        // Same three ELAPSED periods, but a 90% principal repayment lands first.
        _repayPrincipal(tokenId, (P * 9) / 10);
        uint256 afterRepay;
        for (uint256 i; i < 3; ++i) {
            afterRepay += waterfall.capitalizePik(tokenId);
        }
        assertEq(
            afterRepay,
            cleanTotal,
            "ORDER DEPENDENCE ACROSS A BACKLOG: a repayment erased interest on periods that had already run"
        );
    }

    function test_FIXED_PIK_anElapsedIntervalIsUnaffectedByRepaymentOrdering() public {
        vm.warp(block.timestamp + 30 days);
        uint256 full = _oneInterval(P);

        // Crank the elapsed interval with no repayment.
        uint256 snap = vm.snapshotState();
        assertEq(waterfall.capitalizePik(tokenId), full, "baseline: one interval on the period's basis");
        vm.revertToState(snap);

        // Repay a quarter of principal first, then crank the SAME elapsed interval.
        _repayPrincipal(tokenId, P / 4);
        assertEq(
            waterfall.capitalizePik(tokenId),
            full,
            "ORDER DEPENDENCE: a repayment retroactively changed interest on an elapsed period"
        );
    }

    /// @notice And the repayment IS picked up, for the NEXT period.
    /// @dev The other half of the property: the elapsed period is untouched, but the reduced balance
    ///      is what the following interval accrues on. Without this the fix would simply ignore
    ///      repayments forever.
    function test_PIK_aRepaymentLowersTheFollowingIntervalNotTheElapsedOne() public {
        vm.warp(block.timestamp + 30 days);
        _repayPrincipal(tokenId, P / 4);
        uint256 elapsed = waterfall.capitalizePik(tokenId);
        assertEq(elapsed, _oneInterval(P), "the elapsed period moved");

        vm.warp(block.timestamp + 30 days);
        uint256 next = waterfall.capitalizePik(tokenId);
        assertEq(next, _oneInterval(P - P / 4 + elapsed), "the next period did not pick the repayment up");
        assertLt(next, elapsed, "the following interval should be smaller after a 25% repayment");
    }

    /// @notice REGRESSION: a funding lag does not leave a PIK facility permanently frozen.
    /// @dev FOUND BY ADVERSARIAL REVIEW, and it was deterministic. The PIK cursor was anchored at
    ///      the FUNDING block while `nextPaymentDue` is set at ORIGINATION, and `checkFundable`
    ///      permits up to a whole interval between them. So a facility funded late passed its
    ///      payment date before its first interval elapsed, any passer-by could `markPastDue` a
    ///      borrower who had done nothing wrong, and the past-due gate then blocked capitalisation
    ///      for the rest of its life - the mark is only cleared by a servicer cure, a default, or
    ///      full repayment. Measured: originate at t0 with a 30-day interval, fund at t0+25d, and
    ///      the facility never capitalised once. The cursor is now anchored at
    ///      `nextPaymentDue - paymentInterval`, so the two clocks agree by construction.
    function test_FIXED_PIK_aFundingLagDoesNotFreezeTheFacility() public {
        uint256 late = _originateFilm(keccak256("late-funded"), STATE, P);
        uint64 due = bridge.facility(late).nextPaymentDue;

        // Fund 25 days into a 30-day first period: legal, and previously fatal.
        vm.warp(block.timestamp + 25 days);
        _fundFacility(late, P);

        (uint64 lastAt,) = waterfall.pikCursorOf(late);
        assertEq(lastAt, due - 30 days, "the cursor was not anchored to the payment schedule");

        // The first capitalisation is due exactly when the first payment is, not 30 days later.
        //
        // AND IT CHARGES FIVE DAYS, NOT THIRTY. RESTATED 2026-09-10 on Forest Road direction. This
        // assertion used to read `_oneInterval(P)`, which is what the defect looked like from inside
        // the test that was written to prove the cursor anchoring worked: the anchoring is right, and
        // the ACCRUAL over it was wrong. Funding 25 days into a 30-day period means 25 days on which
        // no principal was drawn, and charging them minted a receivable the borrower does not owe.
        vm.warp(uint256(due));
        uint256 amount = waterfall.capitalizePik(late);
        assertEq(amount, _window(P, 5 days), "the first period must accrue from FUNDING, not the anchor");
        assertLt(amount, _oneInterval(P), "a 5-day window cannot cost a 30-day interval");
        assertGt(bridge.facility(late).nextPaymentDue, due, "the schedule did not advance");

        // AND THE SCHEDULE IS UNSHORTENED: the second period is a FULL contractual interval, from
        // the first payment date. A shortened first accrual must not shorten the signed schedule.
        assertEq(
            bridge.facility(late).nextPaymentDue, due + 30 days, "the schedule advanced by other than one interval"
        );
        vm.warp(uint256(due) + 30 days);
        uint256 second = waterfall.capitalizePik(late);
        assertEq(second, _oneInterval(P + amount), "the SECOND period must be a full interval on the grown balance");
    }

    /// @notice THE FIRST PIK PERIOD ACCRUES FROM FUNDING, AND NOTHING ELSE DOES.
    ///
    /// @dev FOREST ROAD DECISION, 2026-09-10, taken after an adversarial round reproduced the
    ///      over-charge and two independent verifiers confirmed it at medium. The question was a
    ///      financial mechanic, not an arithmetic bug - does the first period accrue from the SIGNED
    ///      SCHEDULE ANCHOR or from FUNDING? Both are real commercial conventions, the attesters sign
    ///      `nextPaymentDue` and `paymentInterval`, and guessing it would have been a directive-5
    ///      stop. The answer was FUNDING.
    ///
    ///      WHAT WAS WRONG. `fund` anchors `pikCursor.lastAt` at `nextPaymentDue - paymentInterval`
    ///      so the payment clock and the crank clock agree by construction - that anchoring is round
    ///      four's own fix and it is correct. But `checkFundable` permits funding any time strictly
    ///      before `nextPaymentDue`, so the anchor can precede funding by almost a whole interval,
    ///      and the accrual charged `cur.interval` FLAT. The first crank therefore capitalised
    ///      interest for days on which no principal had been drawn and minted the difference to the
    ///      senior vault as yield: a receivable the borrower does not owe, which is the same phantom
    ///      shape the PIK designation gate exists to prevent.
    ///
    ///      IT IS THE FIRST PERIOD ONLY, BY CONSTRUCTION RATHER THAN BY A FLAG. The window is
    ///      `dueAt - max(lastAt, fundedAt)`; after the first crank `lastAt` is the previous `dueAt`,
    ///      always later than `fundedAt`, so the `max` selects `lastAt` and every later period is a
    ///      full interval again. This test measures all three: the short first period, the full
    ///      second, and the total against an independent model.
    function test_FIXED_PIK_theFirstPeriodAccruesFromFunding() public {
        uint256 id = _originateFilm(keccak256("funded-late"), STATE, P);
        uint64 due = bridge.facility(id).nextPaymentDue;

        // Fund with exactly 7 days of the first period left to run.
        vm.warp(uint256(due) - 7 days);
        _fundFacility(id, P);

        vm.warp(uint256(due));
        uint256 first = waterfall.capitalizePik(id);
        assertEq(first, _window(P, 7 days), "the first period must bill 7 days");

        // THE MEASURED OVER-CHARGE THIS CLOSES: 23 days of interest on undrawn principal.
        uint256 overcharge = _oneInterval(P) - first;
        assertEq(overcharge, _window(P, 30 days) - _window(P, 7 days), "the avoided over-charge is the 23-day tail");
        assertGt(overcharge, 0, "a zero over-charge would make this test vacuous");

        // SECOND PERIOD: a full interval, and the TOTAL matches an independent model.
        vm.warp(uint256(due) + 30 days);
        uint256 second = waterfall.capitalizePik(id);
        assertEq(second, _oneInterval(P + first), "the second period must be a full interval");
        assertEq(reserves.deployedTo(id), P + first + second, "deployed did not absorb exactly both periods");
    }

    /// @notice A FACILITY FUNDED AT THE SAME INSTANT IT IS ORIGINATED IS UNCHANGED.
    /// @dev The anti-regression control. The fixture funds in the origination block, so
    ///      `fundedAt == lastAt`, the `max` selects either, and the first period is a full interval.
    ///      If this ever reds, the change leaked out of the first-period case it is scoped to.
    function test_PIK_aFacilityFundedAtOriginationStillBillsAFullFirstInterval() public {
        uint256 id = _originateFilm(keccak256("funded-at-once"), STATE, P);
        uint64 due = bridge.facility(id).nextPaymentDue;
        _fundFacility(id, P); // same block as origination

        vm.warp(uint256(due));
        assertEq(waterfall.capitalizePik(id), _oneInterval(P), "an unlagged first period must be a full interval");
    }

    /// @notice FUNDING SO LATE THAT THE FIRST PERIOD WOULD ROUND TO NOTHING IS REFUSED AT `fund`.
    ///
    /// @dev A CONSEQUENCE OF THE DECISION, AND IT FAILS CLOSED. Once the first period accrues over
    ///      elapsed time, a short enough window rounds to zero on the USDC grid, and `_planPik`
    ///      reverts `Waterfall_PikBelowScaleGrid` at zero. Because `nextPaymentDue` advances ONLY
    ///      inside `capitalizePik`, such a facility would be frozen for life by its own first crank -
    ///      the exact shape this whole family of fixes exists to prevent. So `fund` refuses it before
    ///      any value moves, and the remedy is the operator's: amend the schedule, or fund sooner.
    ///
    ///      UNREACHABLE AT MAINNET SCALE, which is why it is a guard and not a redesign: a
    ///      1,000,000e18 facility at 1,400 bps needs a sub-millisecond window to round to nothing.
    ///      This test reaches it with a small principal and a one-second window.
    function test_FIXED_PIK_fundingTooLateInTheFirstPeriodIsRefused() public {
        uint256 small = 100e18;
        uint256 id = _originateFilm(keccak256("funded-far-too-late"), STATE, small);
        uint64 due = bridge.facility(id).nextPaymentDue;

        // One second of the first period left: 100e18 at 1,400 bps for 1s is below the USDC grid.
        vm.warp(uint256(due) - 1);
        assertEq(_window(small, 1), 0, "precondition: this window must round to nothing, or the guard is untested");

        vm.expectRevert(
            abi.encodeWithSelector(
                IWaterfallEngine.Waterfall_PikFirstPeriodBelowScaleGrid.selector, id, 1, reserves.normalizeUSDC(1)
            )
        );
        _fundFacility(id, small);
    }

    /// @notice AND THE SAME FACILITY FUNDS PERFECTLY WELL A LITTLE EARLIER.
    /// @dev Anti-vacuity for the guard: it must refuse the unservicable window and nothing more.
    function test_PIK_theSameSmallFacilityFundsWithAServicableWindow() public {
        uint256 small = 100e18;
        uint256 id = _originateFilm(keccak256("funded-just-in-time"), STATE, small);
        uint64 due = bridge.facility(id).nextPaymentDue;

        vm.warp(uint256(due) - 30 days + 1);
        _fundFacility(id, small);
        vm.warp(uint256(due));
        assertGt(waterfall.capitalizePik(id), 0, "a servicable window must fund and crank");
    }

    /// @notice REGRESSION: capitalisation advances the payment schedule, because for a PIK facility
    ///         the capitalisation IS the payment.
    /// @dev FOUND BY ADVERSARIAL REVIEW, and it made PIK unusable. A PIK facility never pays cash on
    ///      its interest date, so without advancing `nextPaymentDue` every one of them sails past it
    ///      and becomes permanently markable by any passer-by through `markPastDue` - which then
    ///      blocks capitalisation for good and marks the book down for a borrower performing exactly
    ///      as contracted.
    function test_FIXED_PIK_capitalisationAdvancesThePaymentSchedule() public {
        uint64 dueBefore = bridge.facility(tokenId).nextPaymentDue;
        vm.warp(block.timestamp + 30 days);
        waterfall.capitalizePik(tokenId);
        uint64 dueAfter = bridge.facility(tokenId).nextPaymentDue;
        assertGt(dueAfter, dueBefore, "the payment schedule did not advance");

        // And the facility is therefore NOT markable past due right after a capitalisation.
        vm.warp(uint256(dueBefore) + 1);
        vm.expectRevert();
        defaultManager.markPastDue(tokenId);
    }

    /// @dev A partial principal repayment through the ordinary waterfall path. The Ethereum
    ///      fixture's `_repay` already mints, approves, attests and distributes, so unlike BSC this
    ///      needs no per-asset unit conversion.
    function _repayPrincipal(uint256 id, uint256 principal) internal {
        _repay(id, 0, principal);
    }

    // ---------------------------------------------------------------------
    //  The bounds
    // ---------------------------------------------------------------------

    /// @notice Every signed coupon through maturity is recorded exactly.
    function test_PIK_allMaturedContractualCouponsAreRecorded() public {
        uint256 expected = P;
        for (uint256 i; i < 12; ++i) {
            vm.warp(block.timestamp + 30 days);
            uint256 coupon = _oneInterval(expected);
            assertEq(waterfall.capitalizePik(tokenId), coupon);
            expected += coupon;
            assertEq(reserves.deployedTo(tokenId), expected);
        }
        assertEq(waterfall.pikCapitalisedTotalOf(tokenId), expected - P);
    }

    /// @notice Signed renewals preserve full interest beyond the former principal multiple.
    function test_PIK_signedRenewalsRecognizeFullInterestBeyondThreeTimesPrincipal() public {
        _amendRateAndRoll(tokenId, 10_000);
        _amendRateAndRoll(tokenId, 10_000);
        uint256 expected = P;
        uint64 start = uint64(block.timestamp);
        for (uint256 i; i < 36; ++i) {
            if (i != 0 && i % 12 == 0) _amendRateAndRoll(tokenId, 10_000);
            vm.warp(uint256(start) + (i + 1) * 30 days);
            uint256 rate = i == 0 ? 1400 : 10_000;
            uint256 coupon = expected * rate / 120_000 / 1e12 * 1e12;
            assertEq(waterfall.capitalizePik(tokenId), coupon);
            expected += coupon;
            assertEq(reserves.deployedTo(tokenId), expected);
            assertEq(registry.classExposure(Config.CLASS_FILM_TAX_CREDITS), expected);
        }
        assertGt(expected, 3 * P);
        assertEq(waterfall.pikCapitalisedTotalOf(tokenId), expected - P);
    }

    /// @dev Amends the rate and rolls maturity to the class maximum. THE ROLL NEEDS TWO STEPS on a
    ///      facility that was not originated renewable: `amendTerms` refuses
    ///      `a.maturity > f.maturity && !f.renewable`, so the first amendment can only flip
    ///      `renewable` (which requires a matching `renewalTermsHash`), and extension is available
    ///      from the second onwards. That is the real path an originator has, and it is the one this
    ///      test drives.
    function _amendRateAndRoll(uint256 id, uint16 newRateBps) internal {
        ClaimBridge.Facility memory f = bridge.facility(id);
        uint64 rolled =
            f.renewable ? uint64(block.timestamp) + uint64(registry.classParams(f.classId).maxMaturity) - 1 : f.maturity;
        ClaimBridge.Amendment memory a = ClaimBridge.Amendment({
            interestRateBps: newRateBps,
            maturity: rolled,
            paymentInterval: f.paymentInterval,
            nextPaymentDue: uint64(block.timestamp) + f.paymentInterval,
            rateType: f.rateType,
            dayCountConvention: f.dayCountConvention,
            renewable: true,
            paymentScheduleHash: f.paymentScheduleHash,
            rateIndexRef: f.rateIndexRef,
            renewalTermsHash: keccak256("pik-renewal-terms")
        });
        bytes32 amendmentId = keccak256(abi.encode("pik-roll", id, newRateBps, block.timestamp, rolled));
        MockAttestationOracle(address(oracle)).setPayload(
            id,
            IAttestationOracle.AttestationKind.TermsAmended,
            keccak256(abi.encode(amendmentId, id, a)),
            uint64(block.timestamp),
            true
        );
        vm.prank(originator);
        bridge.amendTerms(id, amendmentId, a);
    }

    /// @notice Legacy capitalization rejects a past-due flag while the facility remains Active.
    /// @dev The engine stays wired. A pause prevents settlement until the grace windows expire;
    ///      resuming the engine leaves the recorded mark in place for the refusal check.
    function test_FIXED_PIK_refusesAPastDueFacilityThatIsStillActive() public {
        ClaimBridge.Facility memory f = bridge.facility(tokenId);
        // A paused crank fails its actual settlement attempt. Once the grace windows have
        // expired, a bystander can record the mark; resuming the engine does not clear it.
        vm.prank(guardian);
        waterfall.pause();
        vm.warp(uint256(f.maturity) + 2 * uint256(defaultManager.graceWindow(f.classId)) + 1);
        vm.prank(makeAddr("bystander"));
        defaultManager.markPastDue(tokenId);
        vm.prank(guardian);
        waterfall.unpause();

        assertEq(
            uint8(bridge.facility(tokenId).state),
            uint8(ClaimBridge.LoanState.Active),
            "precondition: a past-due facility is STILL Active, which is the whole trap"
        );
        assertGt(defaultManager.pastDueContribution(tokenId), 0, "precondition: it is flagged");

        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikPastDue.selector, tokenId));
        waterfall.capitalizePik(tokenId);
    }

    function test_PIK_refusesANonPerformingFacility() public {
        vm.warp(block.timestamp + 30 days);
        vm.prank(address(waterfall)); // CREDIT_ROLE holder; the lifecycle path is tested elsewhere
        bridge.transitionState(tokenId, ClaimBridge.LoanState.Defaulted);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWaterfallEngine.Waterfall_PikNotPerforming.selector, tokenId, uint8(ClaimBridge.LoanState.Defaulted)
            )
        );
        waterfall.capitalizePik(tokenId);
    }

    /// @notice An unfunded facility is `Pending`, so the PERFORMING gate catches it first. That
    ///         ordering is deliberate: the state check is the cheaper and more informative refusal.
    /// @dev `Waterfall_PikNotFunded` is therefore unreachable through the ordinary lifecycle, and it
    ///      is NOT dead code. It is the MIGRATION guard: a facility originated and funded BEFORE
    ///      this feature existed is `Active` with a zero cursor, and must refuse rather than
    ///      capitalise from the epoch. That case is unreachable on this instance, where nothing is
    ///      deployed, and is exactly the case that matters for the live Ethereum instance's upgrade.
    ///      `test_PIK_aPreExistingFacilityWithNoCursorRefuses` covers it directly.
    function test_PIK_anUnfundedFacilityIsCaughtByTheStateGate() public {
        uint256 unfunded = _originateFilm(keccak256("unfunded-borrower"), STATE, P);
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWaterfallEngine.Waterfall_PikNotPerforming.selector, unfunded, uint8(ClaimBridge.LoanState.Pending)
            )
        );
        waterfall.capitalizePik(unfunded);
    }

    /// @notice THE MIGRATION CASE, which is the one that matters for the live Ethereum instance: a
    ///         facility that is performing but has never had a PIK cursor written must REFUSE, not
    ///         capitalise from the unix epoch.
    /// @dev Simulated by zeroing the cursor on a funded, Active facility. Without the `lastAt == 0`
    ///      guard this would capitalise roughly fifty-six years of interest in one call, limited
    ///      by the retained numerical capacity checks, on the first crank after an implementation replacement.
    function test_PIK_aPreExistingFacilityWithNoCursorRefuses() public {
        // A real, funded, ACTIVE facility whose cursor is then zeroed: exactly the shape a facility
        // originated before this feature has after the implementation is upgraded underneath it.
        // `pikCursor` is the tenth field of `WaterfallStorage` (five contract/address slots, one
        // packed feeRecipient+protocolFeeBps slot, then originationFeeBps, oracle, defaultManager).
        bytes32 base = bytes32(uint256(_WATERFALL_STORAGE_LOCATION) + 9);
        bytes32 slot = keccak256(abi.encode(tokenId, base));
        vm.store(address(waterfall), slot, bytes32(0));

        (uint64 lastAt,) = waterfall.pikCursorOf(tokenId);
        assertEq(lastAt, 0, "precondition: the cursor must read as never written");
        assertEq(
            uint8(bridge.facility(tokenId).state), uint8(ClaimBridge.LoanState.Active), "precondition: still Active"
        );

        vm.warp(block.timestamp + 3650 days);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikNotFunded.selector, tokenId));
        waterfall.capitalizePik(tokenId);
    }

    /// @dev `keccak256(abi.encode(uint256(keccak256("forestroad.storage.WaterfallEngine")) - 1)) & ~bytes32(uint256(0xff))`
    bytes32 internal constant _WATERFALL_STORAGE_LOCATION =
        0xcf0c34fc0be88a30eafd83d03dde401c38c60299c8a6f87d9915e05fa29cdd00;

    /// @notice Never past maturity: at that point the balance is due, not compounding.
    function test_PIK_refusesPastMaturity() public {
        ClaimBridge.Facility memory f = bridge.facility(tokenId);
        // Walk to the last interval that still ends on or before maturity.
        uint256 guard;
        while (guard < 24) {
            (uint64 lastAt,) = waterfall.pikCursorOf(tokenId);
            if (lastAt + 30 days > f.maturity) break;
            vm.warp(lastAt + 30 days);
            waterfall.capitalizePik(tokenId);
            ++guard;
        }
        vm.warp(uint256(f.maturity) + 60 days);
        vm.expectRevert(
            abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikPastMaturity.selector, tokenId, f.maturity)
        );
        waterfall.capitalizePik(tokenId);
    }

    // ---------------------------------------------------------------------
    //  The reason the exposure increase is there
    // ---------------------------------------------------------------------

    /// @notice REGISTRY EXPOSURE TRACKS THE CAPITALISED BALANCE, and that is what keeps the facility
    ///         writeable off.
    /// @dev `DefaultManager.realizeLoss` pairs its write-down with
    ///      `CollateralRegistry.recordExposureDecrease`, which reverts `Registry_ExposureUnderflow`
    ///      when class exposure lags the amount. A capitalisation that raised `deployed` WITHOUT
    ///      raising exposure would therefore make the facility impossible to write off: `deployedTo`
    ///      could never reach zero, the `Resolved` transition would never fire, and the senior NAV
    ///      would be depressed forever. That was the blocker that killed the parallel-ledger design.
    function test_PIK_registryExposureTracksTheCapitalisedBalance() public {
        uint256 expBefore = registry.classExposure(Config.CLASS_FILM_TAX_CREDITS);
        vm.warp(block.timestamp + 30 days);
        uint256 amount = waterfall.capitalizePik(tokenId);
        assertEq(
            registry.classExposure(Config.CLASS_FILM_TAX_CREDITS) - expBefore,
            amount,
            "class exposure did not follow the capitalisation"
        );
        assertEq(reserves.deployedTo(tokenId), registry.borrowerExposure(BORROWER), "deployed and exposure diverged");
    }

    /// @notice A rate-only amendment before the coupon date preserves the running coupon and changes the next.
    function test_PIK_aRateRiseDoesNotMintRetroactively() public {
        vm.warp(block.timestamp + 29 days);
        _amendRate(tokenId, 9000, false); // Keep the existing due date.
        vm.warp(block.timestamp + 1 days);

        uint256 amount = waterfall.capitalizePik(tokenId);
        assertEq(amount, _oneInterval(P), "the elapsed interval was repriced at the amended rate");

        (, uint16 rateAfter) = waterfall.pikCursorOf(tokenId);
        assertEq(rateAfter, 9000, "the cursor did not pick up the new rate for the NEXT interval");

        vm.warp(block.timestamp + 30 days);
        uint256 next = waterfall.capitalizePik(tokenId);
        uint256 expected = _toGrid(((P + amount) * 9000 * 30 days) / (uint256(Config.BPS) * 360 days));
        assertEq(next, expected, "the next interval did not use the amended rate");
    }

    function _amendRate(uint256 id, uint16 newRateBps, bool moveDue) internal {
        ClaimBridge.Facility memory f = bridge.facility(id);
        ClaimBridge.Amendment memory a = ClaimBridge.Amendment({
            interestRateBps: newRateBps,
            maturity: f.maturity,
            paymentInterval: f.paymentInterval,
            nextPaymentDue: moveDue ? uint64(block.timestamp + f.paymentInterval) : f.nextPaymentDue,
            rateType: f.rateType,
            dayCountConvention: f.dayCountConvention,
            renewable: f.renewable,
            paymentScheduleHash: f.paymentScheduleHash,
            rateIndexRef: f.rateIndexRef,
            renewalTermsHash: f.renewalTermsHash
        });
        bytes32 amendmentId = keccak256(abi.encode("pik-amendment", id, newRateBps));
        MockAttestationOracle(address(oracle)).setPayload(
            id,
            IAttestationOracle.AttestationKind.TermsAmended,
            keccak256(abi.encode(amendmentId, id, a)),
            uint64(block.timestamp),
            true
        );
        if (moveDue) {
            vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_LegacyPikScheduleRequiresMigration.selector, id));
        }
        vm.prank(originator);
        bridge.amendTerms(id, amendmentId, a);
    }

    function _rejectIntervalAmendment(uint256 id, uint64 newInterval) internal {
        ClaimBridge.Facility memory f = bridge.facility(id);
        ClaimBridge.Amendment memory a = ClaimBridge.Amendment({
            interestRateBps: f.interestRateBps,
            maturity: f.maturity,
            paymentInterval: newInterval,
            nextPaymentDue: uint64(block.timestamp + f.paymentInterval),
            rateType: f.rateType,
            dayCountConvention: f.dayCountConvention,
            renewable: f.renewable,
            paymentScheduleHash: f.paymentScheduleHash,
            rateIndexRef: f.rateIndexRef,
            renewalTermsHash: f.renewalTermsHash
        });
        bytes32 amendmentId = keccak256(abi.encode("pik-amendment-interval", id, newInterval));
        MockAttestationOracle(address(oracle)).setPayload(
            id,
            IAttestationOracle.AttestationKind.TermsAmended,
            keccak256(abi.encode(amendmentId, id, a)),
            uint64(block.timestamp),
            true
        );
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_LegacyPikScheduleRequiresMigration.selector, id));
        vm.prank(originator);
        bridge.amendTerms(id, amendmentId, a);
    }
}

/// @title PikCashPayRefusal - the critical guard: a cash-pay facility must NEVER capitalise.
/// @notice Its own contract because it must NOT override `_pikFacilities`, so every facility it
///         originates is an ordinary cash-pay loan.
/// @dev THE DEFECT THIS PINS, found by adversarial review and reproduced with exact figures. Before
///      `ClaimBridge.Facility.pik` existed, `capitalizePik` gated only on rate type, day count and
///      lifecycle state, so it applied to EVERY performing Fixed/Actual360 facility. Any address
///      could capitalise a month of interest into an ordinary cash-pay loan's principal AND the
///      borrower would then pay that same interest in cash through `distribute`. Measured on the
///      fixture facility: the vault received 22,166.67e18 for one month of interest that was
///      11,666.67e18, and after the borrower repaid 100% of principal plus contractual interest a
///      residue of 11,666.67e18 still stood in `deployedTo` with the facility pinned in
///      `Amortizing`, never closing. That residue is an asset nobody owes, and its only exit is
///      `realizeLoss`, a real charge against curator first-loss and then senior principal.
contract PikCashPayRefusalTest is CreditLayerFixture {
    function test_FIXED_PIK_aCashPayFacilityCanNeverCapitalise() public {
        _mintUSDfrTo(alice, 5_000_000e18);
        uint256 id = _originateFilm(keccak256("cash-pay-borrower"), keccak256("cash-pay-state"), 1_000_000e18);
        _fundFacility(id, 1_000_000e18);

        assertFalse(bridge.facility(id).pik, "precondition: the fixture originates cash-pay facilities");

        vm.warp(block.timestamp + 30 days);
        vm.prank(makeAddr("bystander"));
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikNotDesignated.selector, id));
        waterfall.capitalizePik(id);

        assertEq(reserves.deployedTo(id), 1_000_000e18, "the balance moved on a cash-pay facility");
    }
}
