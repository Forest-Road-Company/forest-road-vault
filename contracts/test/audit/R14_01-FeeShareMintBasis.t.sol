// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IImpairmentSource} from "../../src/interfaces/IImpairmentSource.sol";
import {Config} from "../../src/libraries/Config.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

/// @dev A source that reports the two impairment views INDEPENDENTLY. The production
///      `DefaultManager` derives them from the same book, but the vault only requires
///      `performanceFeeImpairment() >= pendingSeniorImpairment()` — see
///      `sUSDfr._performanceFeeTotalAssets`. This mock reports them equal, which is the
///      production state whenever curator and backstop capacity for a class are exhausted
///      (`DefaultManager.pendingSeniorImpairment` returns the gross residual).
contract SplitBaseImpairment is IImpairmentSource {
    uint256 internal pending;
    uint256 internal performance;

    function set(uint256 pending_, uint256 performance_) external {
        pending = pending_;
        performance = performance_;
    }

    function pendingSeniorImpairment() external view returns (uint256) {
        return pending;
    }

    function performanceFeeImpairment() external view returns (uint256) {
        return performance;
    }
}

/// @title R14-01 — the performance-fee mint is denominated in the wrong NAV base
/// @notice OPEN FINDING (round 14). These tests DOCUMENT current behaviour; they are
///         characterization tests, not regressions of a fix. If the finding is resolved by
///         re-denominating the mint, `test_openFinding_*` will fail and must be inverted.
///
/// @dev THE DEFECT. `_calculateFees` measures profit on `_performanceFeeTotalAssets()`
///      (realized assets less the GROSS mark) but sizes the settling share mint against
///      `redemptionTotalAssets()` (realized assets less the NETTED mark) — see the
///      `markedAssets` argument threaded into `_feeSharesForAssets`. The shares, once
///      minted, dilute the REALIZED base that `currentExchangeRate()` and
///      `_convertToAssets` read. Three bases, and the mint sits on the middle one.
///
///      CONSEQUENCE. Issuing shares at the depressed exit price buys the fee recipient more
///      shares per unit of fee than the realized price would. The reported exchange rate can
///      therefore FALL on a purely positive repayment, with no realized loss and with the
///      management fee at its 0 bps launch value. Closed form, with `f` the performance-fee
///      rate and `y` the payment:
///
///        rate_after / rate_before = ((A+y+1)/(A+1)) * ((R+y+1-f*y)/(R+y+1))
///
///      Writing `a = A+1` and `r = R+1`, this is below 1 exactly when BOTH `r < f*a` — i.e.
///      at the 1,000 bps launch rate the conservative base is under ~10% of realized assets —
///      AND `y < (f*a - r)/(1 - f)`. The fall therefore has a PAYMENT-SIZE THRESHOLD; the
///      `1 - f` bound is an asymptote as the base tends to zero, not a practical magnitude.
///
///      WHY EXISTING ASSURANCE CANNOT SEE IT. `CreditInvariants.invariant_exchangeRate_
///      neverFallsWithoutLossOrFee` permits a fall to `(1 - performanceFeeBps/BPS)` of its
///      floor whenever a performance fee is due — which is precisely this mechanism's
///      asymptote — and `CreditHandler._acceptAccruedFeeDilution` rebases that floor on any
///      fee-recipient balance increase. No run count falsifies it.
///
///      SCOPE OF THIS PROOF. This pins the VAULT-level arithmetic and its reachability given
///      a source reporting the stated values. It does NOT prove the credit layer can reach
///      `pendingSeniorImpairment() == performanceFeeImpairment() == 95%` of the vault; that
///      requires a class whose curator and backstop capacity are exhausted, and is argued in
///      the round-14 report rather than executed here.
contract R14_01FeeShareMintBasisTest is TokenLayerFixture {
    SplitBaseImpairment internal source;

    /// @dev Builds the at-the-money, deeply-marked state: realized 1,000e18, both marks
    ///      950e18, so redemption == performance == 50e18 and the hurdle sits exactly on
    ///      the performance base. Reached WITHOUT a profitable checkpoint, so the stored
    ///      high-water mark is still the genesis par rate.
    function _atTheMoneyDeeplyMarked() internal {
        _stake(alice, 50e18);

        source = new SplitBaseImpairment();
        vm.prank(admin);
        vault.setImpairmentSource(address(source));

        // Mark first, THEN deliver, so no checkpoint ever sees the delivery as profit.
        source.set(950e18, 950e18);
        _addRecognizedYield(950e18);

        // Pin the constructed state before asserting anything about it.
        assertEq(vault.totalAssets(), 1_000e18, "realized base");
        assertEq(vault.redemptionTotalAssets(), 50e18, "conservative exit base");
        assertEq(vault.highWaterMark(), 1e18, "hurdle still at the genesis par rate");

        (, uint256 performanceShares) = vault.accrueFees();
        assertEq(performanceShares, 0, "the constructed state must be at the money, not above it");
    }

    function _stake(address user, uint256 assets) internal returns (uint256 shares) {
        _mintUSDfr(user, assets / 1e12);
        vm.startPrank(user);
        usdfr.approve(address(vault), assets);
        shares = vault.deposit(assets, user);
        vm.stopPrank();
    }

    function _addRecognizedYield(uint256 assets) internal {
        _receiveYield(address(vault), assets / 1e12);
    }

    // ── The finding ──────────────────────────────────────────────────────

    /// @notice OPEN FINDING. A purely positive repayment lowers the reported exchange rate,
    ///         with no realized loss and no management fee.
    function test_openFinding_positiveRepaymentLowersTheReportedExchangeRate() public {
        _atTheMoneyDeeplyMarked();
        assertEq(vault.managementFeeBps(), 0, "launch management fee must be zero for this to be unambiguous");

        uint256 rateBefore = vault.currentExchangeRate();

        // A single ordinary interest leg. Nothing is lost; the vault strictly gains 10e18.
        _addRecognizedYield(10e18);

        // The reported rate is fee-net by construction (`_feeAdjustedSupply` simulates the
        // pending mint), so the fall is visible BEFORE anyone crystallizes.
        uint256 rateSimulated = vault.currentExchangeRate();
        assertLt(rateSimulated, rateBefore, "OPEN FINDING R14-01: positive yield lowered the reported rate");

        // Crystallizing must not move it again (no second price jump), so the realized fall
        // equals the simulated one.
        vault.accrueFees();
        assertApproxEqAbs(vault.currentExchangeRate(), rateSimulated, 2, "crystallization created a second jump");

        // The loss to holders is bounded by the fee rate, as the closed form predicts.
        uint256 floor = Math.mulDiv(rateBefore, Config.BPS - vault.performanceFeeBps(), Config.BPS);
        assertGt(rateSimulated, floor, "fall must stay inside the 1 - performanceFeeBps bound");
    }

    /// @notice The fall is bounded by a PAYMENT-SIZE THRESHOLD, not universal. Solving
    ///         `(a+y)(r+y(1-f)) < a(r+y)` for `y`, with `a = A+1` and `r = R+1`, gives
    ///
    ///             y  <  (f*a - r) / (1 - f)
    ///
    ///         so a deeply-marked vault falls on SMALL legs and rises on large ones. In this
    ///         state (A = 1,000e18, R = 50e18, f = 1,000 bps) the threshold is ~55.6e18.
    ///
    ///         This test exists because the finding was originally reported as independent of
    ///         payment size. It is not — this suite falsified that claim, and the corrected
    ///         predicate is the pair `r < f*a` AND `y < (f*a - r)/(1 - f)`.
    function test_openFinding_theFallHasAPaymentSizeThreshold() public {
        uint256 snapshot = vm.snapshotState();

        // Below the threshold: falls.
        _atTheMoneyDeeplyMarked();
        uint256 beforeSmall = vault.currentExchangeRate();
        _addRecognizedYield(10e18);
        assertLt(vault.currentExchangeRate(), beforeSmall, "a leg below the threshold must fall");

        vm.revertToState(snapshot);

        // Just above the threshold: rises again.
        _atTheMoneyDeeplyMarked();
        uint256 beforeLarge = vault.currentExchangeRate();
        _addRecognizedYield(60e18);
        assertGt(vault.currentExchangeRate(), beforeLarge, "a leg above the threshold must rise");
    }

    /// @notice The magnitude is far smaller than the `1 - f` asymptote at any realistic mark
    ///         depth. The worst case over all payment sizes is ~0.92% at a 5%-of-realized
    ///         redemption base, and only approaches the fee rate as the base tends to zero —
    ///         a vault that is already a governance event on its own terms.
    function test_openFinding_worstCaseMagnitudeIsUnderOnePercentAtThisDepth() public {
        _atTheMoneyDeeplyMarked();

        uint256 rateBefore = vault.currentExchangeRate();
        // ~22.6e18 is the minimising leg for this state; see the round-14 report.
        _addRecognizedYield(22e18);
        uint256 rateAfter = vault.currentExchangeRate();

        assertLt(rateAfter, rateBefore, "the minimising leg must fall");
        // Strictly better than a 1% fall, i.e. nowhere near the 10% fee-rate asymptote.
        assertGt(rateAfter, Math.mulDiv(rateBefore, 99, 100), "worst-case fall at this depth is under 1%");
    }

    // ── The control: the same flow is a strict RISE outside the regime ────

    /// @notice CONTROL. With no mark at all — redemption base == realized base — the identical
    ///         repayment raises the rate. This isolates the base mismatch as the cause and
    ///         proves the test is not merely observing fee dilution.
    function test_control_unmarkedVaultRisesOnTheSameRepayment() public {
        _stake(alice, 1_000e18);

        source = new SplitBaseImpairment();
        vm.prank(admin);
        vault.setImpairmentSource(address(source));
        source.set(0, 0);

        vault.accrueFees();
        uint256 rateBefore = vault.currentExchangeRate();

        _addRecognizedYield(10e18);

        assertGt(vault.currentExchangeRate(), rateBefore, "an unmarked vault must rise on positive yield");
    }

    /// @notice CONTROL. Just inside the predicate the rate still rises, so the boundary is
    ///         the stated one rather than "any mark at all".
    function test_control_shallowMarkStillRises() public {
        _stake(alice, 1_000e18);

        source = new SplitBaseImpairment();
        vm.prank(admin);
        vault.setImpairmentSource(address(source));
        // R = 800e18 against A = 1000e18: far above f*(A+1) = ~100e18, so outside the regime.
        source.set(200e18, 200e18);

        vault.accrueFees();
        uint256 rateBefore = vault.currentExchangeRate();

        _addRecognizedYield(10e18);

        assertGt(vault.currentExchangeRate(), rateBefore, "a shallow mark must still rise");
    }
}
