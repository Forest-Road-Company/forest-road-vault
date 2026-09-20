// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IContinuousAccrual, IAccrualToken} from "../interfaces/IContinuousAccrual.sol";
import {IMintRedeemController} from "../interfaces/IMintRedeemController.sol";
import {IReserveManager} from "../interfaces/IReserveManager.sol";
import {IAccrualExposure} from "../interfaces/IAccrualExposure.sol";
import {IAccrualLifecycle, IAccrualServicing} from "../interfaces/IAccrualLifecycle.sol";
import {IWaterfallEngine} from "../interfaces/IWaterfallEngine.sol";
import {ClaimBridge} from "../ClaimBridge.sol";
import {WaterfallEngine} from "../WaterfallEngine.sol";
import {AccrualMath} from "./AccrualMath.sol";
import {Config} from "./Config.sol";
import {ICollateralRegistry} from "../interfaces/ICollateralRegistry.sol";

/// @title WaterfallAccrualLib
/// @notice Validates the servicing engine's permanent reserve-local accounting route.
/// @dev Linked calls execute in the waterfall proxy's context. The caller supplies its existing
///      native identities, never replacement modules, and authenticates the governed binding.
library WaterfallAccrualLib {
    uint256 private constant _ACTUAL360_YEAR = 360 days;
    uint256 private constant _MAX_PIK_EXPOSURE = type(uint256).max / Config.BPS;

    /// @notice The source does not identify the waterfall's existing native module routes.
    error WaterfallAccrual_InvalidReserve(address reserve);

    /// @notice Checks all seven identities and the token-first, native-controller binding.
    /// @param reserve The waterfall's already configured native reserve.
    /// @param native The existing native routes; token is discovered from the checked controller.
    function validate(address reserve, IContinuousAccrual.Modules memory native, address oracle) public view {
        if (reserve.code.length == 0) revert WaterfallAccrual_InvalidReserve(reserve);
        bytes memory data = _reply(reserve, abi.encodeCall(IContinuousAccrual.accrualModules, ()), 224, reserve);
        uint256[7] memory words = abi.decode(data, (uint256[7]));
        for (uint256 i; i < 7; ++i) {
            if (words[i] > type(uint160).max || address(uint160(words[i])).code.length == 0) {
                revert WaterfallAccrual_InvalidReserve(reserve);
            }
        }
        IContinuousAccrual.Modules memory m = abi.decode(data, (IContinuousAccrual.Modules));
        if (
            m.waterfall != address(this) || m.bridge != native.bridge || m.registry != native.registry
                || m.controller != native.controller || m.vault != native.vault || m.defaultManager != native.defaultManager
        ) revert WaterfallAccrual_InvalidReserve(reserve);
        data = _reply(m.token, abi.encodeCall(IAccrualToken.accrualReserve, ()), 32, reserve);
        if (abi.decode(data, (uint256)) != uint256(uint160(reserve))) {
            revert WaterfallAccrual_InvalidReserve(reserve);
        }
        data = _reply(m.controller, abi.encodeCall(IMintRedeemController.modules, ()), 96, reserve);
        uint256[3] memory controller = abi.decode(data, (uint256[3]));
        if (
            controller[0] != uint256(uint160(m.token)) || controller[1] > type(uint160).max
                || controller[2] != uint256(uint160(reserve))
        ) revert WaterfallAccrual_InvalidReserve(reserve);
        data = _reply(reserve, abi.encodeCall(IReserveManager.lossController, ()), 32, reserve);
        if (abi.decode(data, (uint256)) != uint256(uint160(m.controller))) {
            revert WaterfallAccrual_InvalidReserve(reserve);
        }
        data = _reply(m.bridge, abi.encodeCall(ClaimBridge.modules, ()), 64, reserve);
        uint256[2] memory bridge = abi.decode(data, (uint256[2]));
        if (bridge[0] != uint256(uint160(m.registry)) || bridge[1] != uint256(uint160(oracle))) {
            revert WaterfallAccrual_InvalidReserve(reserve);
        }
    }

    /// @notice Runs bounded chronological maintenance, then services the selected dormant clock.
    /// @dev Capitalization changes the debt's classification only. Its return is the selected
    ///      canonical principal increase; a dormant projection already visible before servicing
    ///      can therefore return zero. Earlier facilities can consume the entire batch.
    function checkpoint(address reserve, address bridge, uint256 tokenId)
        public
        returns (uint256 capitalized, uint256 processed, bool fresh)
    {
        IAccrualExposure(reserve).requireAccrualIdle();
        ClaimBridge.Facility memory f = ClaimBridge(bridge).facility(tokenId);
        if (!f.pik) revert IWaterfallEngine.Waterfall_PikNotDesignated(tokenId);
        if (f.state != ClaimBridge.LoanState.Active && f.state != ClaimBridge.LoanState.Amortizing) {
            revert IWaterfallEngine.Waterfall_PikNotPerforming(tokenId, uint8(f.state));
        }
        IAccrualLifecycle.Debt memory before_ = IAccrualLifecycle(reserve).accruedDebt(tokenId);
        if (!before_.known) revert IWaterfallEngine.Waterfall_PikNotFunded(tokenId);
        if (before_.principal == 0 && before_.interest == 0) {
            revert IWaterfallEngine.Waterfall_PikNothingOutstanding(tokenId);
        }
        (processed, fresh) = IAccrualLifecycle(reserve).checkpointAccrual(32);
        if (fresh && !IAccrualServicing(reserve).accrualLoanScheduled(tokenId)) {
            IAccrualServicing(reserve).serviceAccruedLoan(tokenId);
        }
        capitalized = IAccrualLifecycle(reserve).accruedDebt(tokenId).principal - before_.principal;
    }

    /// @notice Reports the selected signed PIK clock using the source's actual queued/dormant state.
    /// @dev A queued due loan can require more than one global batch. A dormant due loan is ready
    ///      only once the shared frontier is fresh. No next capitalization means no crank is due;
    ///      its cash balloon remains owed at legal maturity. Neither view changes that maturity.
    function status(address reserve, address bridge, uint256 tokenId) public view returns (bool due, bool blocked) {
        ClaimBridge.Facility memory f = ClaimBridge(bridge).facility(tokenId);
        if (!f.pik) return (false, false);
        if (f.state != ClaimBridge.LoanState.Active && f.state != ClaimBridge.LoanState.Amortizing) {
            return (false, false);
        }
        IAccrualLifecycle.Debt memory d = IAccrualLifecycle(reserve).accruedDebt(tokenId);
        if (!d.known) return (false, true);
        if (
            !d.active || d.nextCapitalization == 0 || d.nextCapitalization > block.timestamp
                || d.nextCapitalization > d.maturity || (d.principal == 0 && d.interest == 0)
        ) return (false, false);
        try IAccrualExposure(reserve).requireAccrualIdle() {}
        catch {
            return (false, true);
        }
        if (!IAccrualServicing(reserve).accrualLoanScheduled(tokenId)) {
            bool fresh = IContinuousAccrual(reserve).accrualSnapshot().fresh;
            return (fresh, !fresh);
        }
        return (true, false);
    }

    /// @notice Calculates one signed legacy PIK coupon and its next frozen basis.
    /// @dev Preserves the host planner's gates, asset rounding, numerical capacity and backlog
    ///      behavior. The completed coupon uses its own frozen rate and basis. Live terms and
    ///      principal are adopted only after the entire elapsed backlog has been settled.
    /// @param $ The waterfall's existing storage.
    /// @param tokenId The performing PIK loan to service.
    /// @return plan The exact coupon, accounting values and next cursor selected by its terms.
    function planLegacyPik(WaterfallEngine.WaterfallStorage storage $, uint256 tokenId)
        public
        view
        returns (WaterfallEngine.PikPlan memory plan)
    {
        ClaimBridge.Facility memory f = $.bridge.facility(tokenId);
        if (!f.pik) revert IWaterfallEngine.Waterfall_PikNotDesignated(tokenId);
        if (f.state != ClaimBridge.LoanState.Active && f.state != ClaimBridge.LoanState.Amortizing) {
            revert IWaterfallEngine.Waterfall_PikNotPerforming(tokenId, uint8(f.state));
        }
        if ($.registry.classParams(f.classId).model != ICollateralRegistry.CollateralModel.Receivable) {
            revert IWaterfallEngine.Waterfall_PikClassNotReceivable(tokenId, f.classId);
        }
        if (
            address($.defaultManager) != address(0) && $.defaultManager.pastDueContribution(tokenId) != 0
                && msg.sender != address($.defaultManager)
        ) {
            revert IWaterfallEngine.Waterfall_PikPastDue(tokenId);
        }
        // The manager alone can service marked PIK during attested default preparation. It
        // raises the existing risk contribution before calling the paired issuance path.
        if (f.rateType != ClaimBridge.RateType.Fixed) revert IWaterfallEngine.Waterfall_PikRateTypeUnsupported(tokenId);
        if (f.dayCountConvention != ClaimBridge.DayCountConvention.Actual360) {
            revert IWaterfallEngine.Waterfall_PikDayCountUnsupported(tokenId);
        }
        WaterfallEngine.PikCursor memory cur = $.pikCursor[tokenId];
        if (cur.lastAt == 0) revert IWaterfallEngine.Waterfall_PikNotFunded(tokenId);
        if (cur.interval == 0) revert IWaterfallEngine.Waterfall_PikNotFunded(tokenId);
        plan.dueAt = cur.lastAt + cur.interval;
        if (block.timestamp < plan.dueAt) revert IWaterfallEngine.Waterfall_PikIntervalNotElapsed(tokenId, plan.dueAt);
        if (plan.dueAt > f.maturity) revert IWaterfallEngine.Waterfall_PikPastMaturity(tokenId, f.maturity);
        uint256 outstanding = $.reserves.deployedTo(tokenId);
        if (outstanding == 0) revert IWaterfallEngine.Waterfall_PikNothingOutstanding(tokenId);
        uint64 accrualFrom = cur.lastAt;
        if (cur.fundedAt > accrualFrom) accrualFrom = cur.fundedAt;
        if (accrualFrom >= plan.dueAt) revert IWaterfallEngine.Waterfall_PikNotFunded(tokenId);
        uint256 accrualWindow = uint256(plan.dueAt) - uint256(accrualFrom);
        plan.amount = AccrualMath.earnedInterest(cur.basis, cur.rateBps, uint64(accrualWindow), _ACTUAL360_YEAR);
        plan.asset = $.reserves.facilityAssetOf(tokenId);
        uint256 scale = $.reserves.assetRecord(plan.asset).scale;
        plan.amount = (plan.amount / scale) * scale;
        if (plan.amount == 0) revert IWaterfallEngine.Waterfall_PikBelowScaleGrid(tokenId, scale);
        if (outstanding > _MAX_PIK_EXPOSURE || plan.amount > _MAX_PIK_EXPOSURE - outstanding) {
            revert IWaterfallEngine.Waterfall_PikExposureCapacity(tokenId);
        }
        plan.periodRateBps = cur.rateBps;
        bool caughtUp = plan.dueAt + cur.interval > block.timestamp;
        plan.nextRateBps = caughtUp ? f.interestRateBps : cur.rateBps;
        plan.nextInterval = caughtUp ? f.paymentInterval : cur.interval;
        plan.interval = plan.nextInterval;
        plan.previousDue = f.nextPaymentDue;
        plan.maturity = f.maturity;
        plan.classId = f.classId;
        plan.borrowerId = f.borrowerId;
        plan.stateId = f.stateId;
        plan.balanceAfter = outstanding + plan.amount;
        plan.nextBasis = caughtUp ? plan.balanceAfter : cur.basis + plan.amount;
        if (plan.nextBasis > type(uint176).max) revert IWaterfallEngine.Waterfall_PikExposureCapacity(tokenId);
    }

    /// @notice Returns the boundary of a payable, elapsed legacy PIK coupon, or zero.
    /// @dev Used by full legacy PIK repayment and default preparation. Read the frozen cursor,
    ///      not deployed principal, which the receipt has already reduced to zero. A blocked
    ///      planner is not evidence that no interest is owed. Rounding follows the funded asset's
    ///      grid; a coupon below that grid is zero. Recovery after declared default and native
    ///      accrual use their existing settlement paths and do not enter this guard.
    /// @param $ The waterfall's existing storage.
    /// @param tokenId The loan being closed.
    /// @param maturity Its signed maturity; no coupon can be capitalized after that boundary.
    /// @return dueAt The pending coupon boundary; zero means there is no payable elapsed coupon.
    function pendingLegacyPik(WaterfallEngine.WaterfallStorage storage $, uint256 tokenId, uint64 maturity)
        public
        view
        returns (uint64 dueAt)
    {
        WaterfallEngine.PikCursor memory cur = $.pikCursor[tokenId];
        if (cur.lastAt == 0 || cur.interval == 0) revert IWaterfallEngine.Waterfall_PikNotFunded(tokenId);
        dueAt = cur.lastAt + cur.interval;
        if (dueAt > block.timestamp || dueAt > maturity) return 0;
        uint64 from = cur.lastAt > cur.fundedAt ? cur.lastAt : cur.fundedAt;
        if (from >= dueAt) revert IWaterfallEngine.Waterfall_PikNotFunded(tokenId);
        uint256 coupon = AccrualMath.earnedInterest(cur.basis, cur.rateBps, dueAt - from, 360 days);
        uint256 scale = $.reserves.assetRecord($.reserves.facilityAssetOf(tokenId)).scale;
        if (coupon < scale) return 0;
    }

    /// @dev Rejects malformed or failed static probes before any decoding or source binding.
    function _reply(address target, bytes memory request, uint256 length, address reserve)
        private
        view
        returns (bytes memory data)
    {
        bool ok;
        (ok, data) = target.staticcall(request);
        if (!ok || data.length != length) revert WaterfallAccrual_InvalidReserve(reserve);
    }
}
