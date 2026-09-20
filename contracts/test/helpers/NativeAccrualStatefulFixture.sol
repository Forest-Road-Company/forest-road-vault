// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {NativeAccrualFixture, NativeAccrualCoverageFunding} from "./NativeAccrualFixture.sol";
import {AccrualDebtReference} from "./AccrualDebtReference.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @dev One outstanding note at a time, with repeated originations in the same native book.
///      Action counters count completed operations. Ineligible draws return without a count.
abstract contract NativeAccrualStatefulFixture is NativeAccrualFixture {
    using AccrualDebtReference for AccrualDebtReference.Note;

    struct Observation {
        uint256 curator;
        uint256 coverage;
        uint256 rate;
        uint256 seniorLoss;
        uint256 grossRisk;
        uint256 grossIncome;
        uint256 shares;
        uint256 markedAssets;
    }

    uint256[11] public nativeActions;
    uint256 public nativeClosedEarned;
    uint256 public nativeRoundingLoss;
    uint256 public nativeSeniorLoss;
    uint256 public nativeOriginationFees;
    uint256 public nativeMaximumBookDrift;
    uint256 public nativeLastRate;
    uint256 public nativeCapitalizations;

    function setUp() public virtual override {
        super.setUp();
        nativeLastRate = vault.currentExchangeRate();
        // One early default can traverse all available junior capital and reach senior.
        _fundNextNativeNote(20_000e18);
    }

    function actFund(uint256 seed) public {
        if (_hasDebt()) return;
        _fundNextNativeNote((seed % 901 + 100) * 1e18);
    }

    function _fundNextNativeNote(uint256 principal) private {
        uint256 required = principal / 5;
        uint256 available = curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS);
        if (available < required) {
            uint256 scale = _nativeScale();
            _postFirstLoss(
                anchorCurator, Config.CLASS_FILM_TAX_CREDITS, (required - available + scale - 1) / scale * scale
            );
        }
        Observation memory before_ = _begin();
        nativeClosedEarned += nativeReference.earned;
        nativeStart = uint64(block.timestamp);
        nativeWrittenOff = 0;
        _nativeFund(principal);
        nativeOriginationFees += principal / _nativeScale() * waterfall.originationFeeBps(Config.CLASS_FILM_TAX_CREDITS)
            / 10_000 * _nativeScale();
        _after(before_, 0);
    }

    function actTime(uint256 seed) public {
        if (nativeId == 0) return;
        Observation memory before_ = _begin();
        uint64 at = uint64(block.timestamp + seed % 120 days + 1);
        uint256 principalBefore = nativeReference.principal;
        if (_pikFacilities() && _performing() && _hasDebt()) {
            AccrualDebtReference.Note memory n = nativeReference;
            n.advance(at);
            nativeReference = n;
            vm.warp(at);
            waterfall.capitalizePik(nativeId);
            _assertNativeDebt();
            if (n.principal > principalBefore) ++nativeCapitalizations;
        } else {
            _nativeAdvance(at);
        }
        _after(before_, 1);
    }

    function actReceipt(uint256 seed) public {
        if (!_hasDebt()) return;
        Observation memory before_ = _begin();
        ClaimBridge.Facility memory f = bridge.facility(nativeId);
        if (seed % 4 == 0 || block.timestamp >= f.maturity || f.nextPaymentDue == f.maturity) {
            _nativePayAll();
        } else {
            uint256 divisor = seed % 5 + 2;
            uint256 scale = _nativeScale();
            uint256 principal = nativeReference.principal;
            uint256 interest = nativeReference.interest;
            if (_pikFacilities()) {
                principal = (principal + interest) / divisor / scale * scale;
                interest = 0;
            } else {
                principal = principal / divisor / scale * scale;
                interest = interest / divisor / scale * scale;
            }
            if (principal + interest == 0) _nativePayAll();
            else _nativeReceipt(principal, interest);
        }
        _after(before_, 2);
    }

    function actAmend(uint256 seed) public {
        if (!_performing() || !_hasDebt() || block.timestamp >= nativeReference.maturity) return;
        // This action preserves the signed due date; a past date is not a valid amendment.
        if (bridge.facility(nativeId).nextPaymentDue <= block.timestamp) return;
        Observation memory before_ = _begin();
        _nativeAmendRate(uint16(seed % 3000 + 1));
        _after(before_, 3);
    }

    function actMark(uint256) public {
        if (!_performing() || !_hasDebt() || defaultManager.pastDueContribution(nativeId) != 0) return;
        uint64 due = bridge.facility(nativeId).nextPaymentDue;
        if (_pikFacilities()) due = nativeReference.maturity;
        uint256 eligible = uint256(due) + defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS) + 1;
        // A PIK coupon is settled through maintenance; only its unpaid maturity balloon
        // is made past due here. Time actions run the actual waterfall capitalization path.
        while (block.timestamp < eligible) {
            uint256 elapsed = eligible - block.timestamp;
            if (elapsed > 120 days) elapsed = 120 days;
            actTime(elapsed - 1);
        }
        Observation memory before_ = _begin();
        defaultManager.markPastDue(nativeId);
        assertEq(
            defaultManager.pastDueContribution(nativeId), reserves.deployedTo(nativeId), "native mark omitted face"
        );
        _after(before_, 4);
    }

    function actCure(uint256) public {
        if (nativeId == 0 || defaultManager.pastDueContribution(nativeId) == 0) return;
        Observation memory before_ = _begin();
        _clearPastDue(nativeId, keccak256(abi.encode("native-stateful-cure", nativeId, ++receiptSequence)));
        assertEq(defaultManager.pastDueContribution(nativeId), 0, "native cure retained face");
        _after(before_, 5);
    }

    function actDeclare(uint256) public {
        if (!_performing() || !_hasDebt()) return;
        Observation memory before_ = _begin();
        _nativeDeclare();
        _after(before_, 6);
    }

    function actLoss(uint256 seed) public {
        if (!_hasDebt() || _performing()) return;
        Observation memory before_ = _begin();
        uint256 face = nativeReference.principal + nativeReference.interest;
        uint256 amount = seed % 3 == 0 ? face : face / (seed % 4 + 2) / _nativeScale() * _nativeScale();
        if (amount == 0) amount = face;
        uint256 first = amount < before_.curator ? amount : before_.curator;
        uint256 second = amount - first < before_.coverage ? amount - first : before_.coverage;
        nativeSeniorLoss += amount - first - second;
        _nativeLoss(amount);
        _after(before_, 7);
    }

    function actMaterialize(uint256 seed) public {
        Observation memory before_ = _begin();
        IContinuousAccrual.Snapshot memory claims = reserves.accrualSnapshot();
        uint8 legs = uint8(seed % 3 + 1);
        (uint256 senior, uint256 fee) = reserves.materializeAccrued(legs);
        assertEq(senior, legs & 1 == 0 ? 0 : claims.seniorUnissued, "wrong senior claim delivered");
        assertEq(fee, legs & 2 == 0 ? 0 : claims.feeUnissued, "wrong protocol claim delivered");
        assertEq(reserves.accrualSnapshot().unissued, claims.unissued - senior - fee, "claim issuance conservation");
        _after(before_, 8);
    }

    function actPost(uint256) public {
        if (!_hasDebt()) return;
        Observation memory before_ = _begin();
        uint256 face = reserves.deployedTo(nativeId);
        uint256 unposted = reserves.unpostedAccruedLoan(nativeId);
        assertEq(reserves.postAccruedLoan(nativeId), unposted, "posting must consume all virtual face");
        assertEq(reserves.unpostedAccruedLoan(nativeId), 0, "posting left virtual face");
        assertEq(reserves.deployedTo(nativeId), face, "posting changed effective face");
        _after(before_, 9);
    }

    function actCancel(uint256 seed) public {
        Observation memory before_ = _begin();
        uint256 exposure = registry.totalBookExposure();
        uint256 gross = reserves.accrualSnapshot().gross;
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, (seed % 100 + 1) * 1e18);
        vm.prank(originator);
        bridge.cancelPending(id);
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Cancelled), "cancellation state");
        assertFalse(reserves.accruedDebt(id).known, "unfunded cancellation entered accrual book");
        assertEq(registry.totalBookExposure(), exposure, "cancellation did not reverse pending exposure");
        assertEq(reserves.accrualSnapshot().gross, gross, "cancellation changed earned income");
        _after(before_, 10);
    }

    function assertNativeStatefulAccounting() public view {
        _assertNativeBacking();
        _assertNativeDebt();
        IContinuousAccrual.Snapshot memory claims = reserves.accrualSnapshot();
        uint256 expected = nativeClosedEarned + nativeReference.earned + nativeRoundingLoss;
        uint256 drift = claims.gross > expected ? claims.gross - expected : expected - claims.gross;
        if (!nativeReference.active) assertEq(drift, 0, "closed native book drift");
        else assertLe(drift, _nativeScale() + 365 days, "open native book drift exceeded interpolation bound");
        assertEq(
            vault.totalAssets(),
            SENIOR_CAPITAL + claims.gross - claims.gross / 10 - nativeSeniorLoss,
            "native senior income or loss conservation"
        );
        assertEq(
            usdfr.balanceOf(feeRecipient) + claims.feeUnissued,
            nativeOriginationFees + claims.gross / 10,
            "protocol fee ownership changed through receipts or losses"
        );
        assertEq(registry.totalBookExposure(), reserves.deployedTo(nativeId), "native exposure drift");
        assertEq(
            defaultManager.pastDuePrincipal(Config.CLASS_FILM_TAX_CREDITS),
            defaultManager.pastDueContribution(nativeId),
            "class cohort differs from its only outstanding facility"
        );
        assertEq(defaultManager.pastDueExposure(), defaultManager.pastDueContribution(nativeId), "global cohort drift");
        assertEq(vault.yieldVestingPeriod(), 0, "vesting became active");
    }

    function _begin() private returns (Observation memory before_) {
        _nativeFeeCheckpoint();
        before_.curator = curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS);
        before_.coverage =
            _nativeBackstop() == address(0) ? 0 : NativeAccrualCoverageFunding(_nativeBackstop()).coverageReserve();
        before_.rate = vault.currentExchangeRate();
        before_.seniorLoss = nativeSeniorLoss;
        before_.grossRisk = _grossNativeRisk();
        before_.grossIncome = reserves.accrualSnapshot().gross;
        before_.shares = vault.totalSupply();
        before_.markedAssets = vault.redemptionTotalAssets();
        vm.recordLogs();
    }

    function _after(Observation memory before_, uint256 action) private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(reserves) || logs[i].topics.length == 0) continue;
            bool ethereum = logs[i].topics[0]
                == keccak256(
                    "AccrualRoundingAllocated(uint256,uint64,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
                );
            bool bsc = logs[i].topics[0]
                == keccak256("AccrualRoundingAllocated(uint256,uint64,uint256,uint256,uint256,uint256,uint256,uint256)");
            if (!ethereum && !bsc) continue;
            uint256[7] memory values;
            if (ethereum) {
                values = abi.decode(logs[i].data, (uint256[7]));
            } else {
                uint256[6] memory raw = abi.decode(logs[i].data, (uint256[6]));
                values = [raw[0], raw[1], raw[2], uint256(0), raw[3], raw[4], raw[5]];
            }
            uint256 first = values[0] < before_.curator ? values[0] : before_.curator;
            uint256 second = values[0] - first < before_.coverage ? values[0] - first : before_.coverage;
            assertGt(values[0], 0, "empty rounding allocation");
            assertLt(values[0], _nativeScale(), "rounding exceeded native unit");
            assertEq(values[1], 0, "fixture has no prepaid mark");
            assertEq(values[2], first, "rounding curator ordering");
            assertEq(values[3], second, "rounding shared reserve ordering");
            assertEq(values[4], values[0] - first - second, "rounding senior ordering");
            assertEq(values[5], 0, "fixture has sufficient senior capital");
            before_.curator -= first;
            before_.coverage -= second;
            nativeRoundingLoss += values[0];
            nativeSeniorLoss += values[4];
        }
        _nativeFeeCheckpoint();
        _assertNativeRate(before_);
        ++nativeActions[action];
        uint256 gross = reserves.accrualSnapshot().gross;
        uint256 expected = nativeClosedEarned + nativeReference.earned + nativeRoundingLoss;
        uint256 drift = gross > expected ? gross - expected : expected - gross;
        if (drift > nativeMaximumBookDrift) nativeMaximumBookDrift = drift;
        assertNativeStatefulAccounting();
    }

    function _assertNativeRate(Observation memory before_) private {
        nativeLastRate = vault.currentExchangeRate();
        uint256 risk = _grossNativeRisk();
        if (nativeSeniorLoss == before_.seniorLoss && risk >= before_.grossRisk) {
            assertGe(nativeLastRate, before_.rate, "yield alone reduced fee-net senior rate");
        }
        // Risk release can make previously impaired income eligible for its deferred fee.
        // Since the initial checkpoint cleared all fees then due, new fee assets cannot
        // exceed ten percent of newly earned senior income plus released gross risk.
        uint256 gain = reserves.accrualSnapshot().gross - before_.grossIncome;
        uint256 released = before_.grossRisk > risk ? before_.grossRisk - risk : 0;
        uint256 feeAssetsBound = (gain - gain / 10 + released) / 10;
        uint256 marked = vault.redemptionTotalAssets();
        if (before_.markedAssets < marked) marked = before_.markedAssets;
        uint256 virtualShares = 10 ** (vault.decimals() - usdfr.decimals());
        uint256 sharesBound = feeAssetsBound * (before_.shares + virtualShares) / (marked + 1 - feeAssetsBound);
        assertLe(vault.totalSupply() - before_.shares, sharesBound, "fee dilution exceeded earned or released income");
        assertEq(
            nativeLastRate,
            10 ** vault.decimals() * (vault.totalAssets() + 1) / (vault.totalSupply() + virtualShares),
            "fee-net exchange rate does not reconcile with owned assets and issued shares"
        );
    }

    function _grossNativeRisk() private view returns (uint256) {
        if (nativeId == 0) return 0;
        if (!_performing() || defaultManager.pastDueContribution(nativeId) != 0) return reserves.deployedTo(nativeId);
        return 0;
    }

    function _nativeFeeCheckpoint() private {
        (uint256 expectedShares, uint256 expectedHwm) = _expectedNativeFees();
        uint256 supply = vault.totalSupply();
        uint256 recipientShares = vault.balanceOf(vault.feeRecipient());
        (uint256 management, uint256 performance) = vault.accrueFees();
        assertEq(management, 0, "fixture management fee changed");
        assertEq(performance, expectedShares, "independent accrued performance fee");
        assertEq(vault.totalSupply(), supply + expectedShares, "fee share issuance conservation");
        assertEq(vault.balanceOf(vault.feeRecipient()), recipientShares + expectedShares, "fee share recipient");
        assertEq(vault.highWaterMark(), expectedHwm, "independent fee hurdle after crystallization");
    }

    /// @dev Direct bounded arithmetic, without importing the production fee calculator.
    ///      This fixture has zero management fees, a ten-percent performance fee and one note.
    function _expectedNativeFees() private view returns (uint256 shares, uint256 hwm) {
        uint256 effectiveSupply = vault.totalSupply() + 10 ** (vault.decimals() - usdfr.decimals());
        uint256 unit = 10 ** vault.decimals();
        uint256 assets = vault.totalAssets();
        uint256 risk = _grossNativeRisk();
        uint256 performanceBase = assets > risk ? assets - risk : 0;
        hwm = vault.highWaterMark();
        uint256 hurdle = (hwm * effectiveSupply + unit - 1) / unit;
        if (performanceBase + 1 <= hurdle) return (0, hwm);
        uint256 feeAssets = (performanceBase + 1 - hurdle) / 10;
        shares = feeAssets * effectiveSupply / (vault.redemptionTotalAssets() + 1 - feeAssets);
        hwm = ((performanceBase + 1) * unit + effectiveSupply + shares - 1) / (effectiveSupply + shares);
    }

    function _hasDebt() internal view returns (bool) {
        return nativeReference.principal + nativeReference.interest != 0;
    }

    function _performing() internal view returns (bool) {
        if (nativeId == 0) return false;
        ClaimBridge.LoanState state = bridge.facility(nativeId).state;
        return state == ClaimBridge.LoanState.Active || state == ClaimBridge.LoanState.Amortizing;
    }
}
