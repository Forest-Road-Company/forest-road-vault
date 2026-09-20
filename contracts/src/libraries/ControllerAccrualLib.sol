// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {MintRedeemController} from "../MintRedeemController.sol";
import {IMintRedeemController} from "../interfaces/IMintRedeemController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IContinuousAccrual, IAccrualToken} from "../interfaces/IContinuousAccrual.sol";
import {IAccrualRounding} from "../interfaces/IAccrualLifecycle.sol";

/// @title ControllerAccrualLib
/// @notice Linked controller helpers for effective supply and exact accrual delivery.
/// @dev Executes in the controller's context. Its host owns governance and reentrancy guards.
library ControllerAccrualLib {
    /// @dev One pre-issuance snapshot, or the same caller's paired pre-backing snapshot.
    struct YieldBaseline {
        uint256 supply;
        uint256 backing;
        uint256 recognized;
        bool paired;
        uint256 retention;
    }

    /// @notice Issues the complete yield increase before applying the original backing and retention checks.
    /// @dev The host enforces CREDIT_ROLE, pause and nonReentrant. Splitting never rounds either
    ///      recipient to a reserve-token unit: the already recognized total is split in USDfr wei.
    ///      A failed second mint or closing check restores both mints and the paired baseline.
    function mintYield(
        MintRedeemController.ControllerStorage storage $,
        address senior,
        uint256 total,
        address feeRecipient,
        uint256 fee
    ) public {
        if (total == 0) revert IMintRedeemController.Controller_ZeroAmount();
        if (fee > total) revert IMintRedeemController.Controller_InvalidYieldSplit(total, fee);
        if (address($.accrual) != address(0)) $.accrual.requireAccrualFresh();
        uint256 toSenior = total - fee;
        if (toSenior != 0 && !$.yieldSink[senior]) revert IMintRedeemController.Controller_NotYieldSink(senior);
        if (fee != 0 && !$.yieldSink[feeRecipient]) revert IMintRedeemController.Controller_NotYieldSink(feeRecipient);
        YieldBaseline memory before_ = _yieldBaseline($);
        if (fee != 0) $.usdfr.mint(feeRecipient, fee);
        if (toSenior != 0) $.usdfr.mint(senior, toSenior);
        _verifyYield($, before_);
        if (fee != 0) emit IMintRedeemController.YieldMinted(feeRecipient, fee);
        if (toSenior != 0) emit IMintRedeemController.YieldMinted(senior, toSenior);
    }

    function _yieldSupply(MintRedeemController.ControllerStorage storage $) private view returns (uint256) {
        return address($.accrual) == address(0) ? $.usdfr.totalSupply() : supply(address($.accrual), address($.usdfr));
    }

    function _yieldBaseline(MintRedeemController.ControllerStorage storage $)
        private
        returns (YieldBaseline memory before_)
    {
        before_.paired = $.pairedYieldCaller == msg.sender;
        if (before_.paired) {
            before_.supply = $.pairedSupplyBefore;
            before_.backing = $.pairedBackingBefore;
            before_.recognized = $.pairedRecognizedBefore;
            before_.retention = $.pairedRetentionBefore;
            $.pairedYieldCaller = address(0);
            $.pairedSupplyBefore = 0;
            $.pairedBackingBefore = 0;
            $.pairedRecognizedBefore = 0;
            $.pairedRetentionBefore = 0;
        } else {
            before_.supply = _yieldSupply($);
            before_.backing = $.reserves.totalBackingValue();
            before_.recognized = $.reserves.recognizedBackingValue();
        }
    }

    /// @dev Preserves both non-worsening deficit checks and the existing retention rule.
    function _verifyYield(MintRedeemController.ControllerStorage storage $, YieldBaseline memory before_)
        private
        view
    {
        uint256 supplyAfter = _yieldSupply($);
        uint256 backingAfter = $.reserves.totalBackingValue();
        uint256 deficitBefore = before_.supply > before_.backing ? before_.supply - before_.backing : 0;
        uint256 deficitAfter = supplyAfter > backingAfter ? supplyAfter - backingAfter : 0;
        if (deficitAfter > deficitBefore) {
            if (deficitBefore == 0) {
                revert IMintRedeemController.Controller_BackingInvariantViolated(supplyAfter, backingAfter);
            }
            revert IMintRedeemController.Controller_DeficitWorsened(deficitBefore, deficitAfter);
        }
        uint256 recognizedAfter = $.reserves.recognizedBackingValue();
        deficitBefore = before_.supply > before_.recognized ? before_.supply - before_.recognized : 0;
        deficitAfter = supplyAfter > recognizedAfter ? supplyAfter - recognizedAfter : 0;
        if (deficitAfter > deficitBefore) {
            revert IMintRedeemController.Controller_RecognizedDeficitWorsened(deficitBefore, deficitAfter);
        }
        uint256 retention = $.subParShortfall + $.reserves.exitPrepaidAbsorption();
        if (before_.paired && retention != before_.retention) {
            revert IMintRedeemController.Controller_PairedRetentionChanged(before_.retention, retention);
        }
        if (retention != 0) {
            uint256 surplus = recognizedAfter > supplyAfter ? recognizedAfter - supplyAfter : 0;
            if (before_.paired) {
                uint256 previous = before_.recognized > before_.supply ? before_.recognized - before_.supply : 0;
                if (surplus != previous) {
                    revert IMintRedeemController.Controller_SeniorRetentionBreached(previous, surplus);
                }
            } else if (surplus < retention) {
                revert IMintRedeemController.Controller_SeniorRetentionBreached(retention, surplus);
            }
        }
    }

    /// @notice The reserve, token and controller must identify this same instance.
    error ControllerAccrual_WrongModules();
    /// @notice Only the bound reserve can continue its current delivery operation.
    error ControllerAccrual_InvalidDelivery();
    /// @notice Existing yield destination authorization also applies to accrued claims.
    error ControllerAccrual_UnauthorizedRecipient(address recipient);
    /// @notice The token did not physically issue exactly the authorized selected claims.
    error ControllerAccrual_SupplyDeltaMismatch(uint256 expected, uint256 actual);

    /// @notice Validates the configured reserve before the controller opts into its accounting.
    function validate(address reserve, address token) public view {
        if (reserve.code.length == 0) revert ControllerAccrual_WrongModules();
        IContinuousAccrual.Modules memory m = IContinuousAccrual(reserve).accrualModules();
        if (
            m.controller != address(this) || m.token != token || m.vault.code.length == 0
                || IAccrualToken(token).accrualReserve() != reserve
        ) {
            revert ControllerAccrual_WrongModules();
        }
    }

    /// @notice Economic supply includes all earned claims awaiting physical minting.
    /// @dev The operation snapshot hides the temporary debit-before-mint window from callbacks.
    function supply(address reserve, address token) public view returns (uint256) {
        IContinuousAccrual source = IContinuousAccrual(reserve);
        IContinuousAccrual.Delivery memory d = source.accrualDelivery();
        if (d.active) return d.effectiveSupply;
        return IERC20(token).totalSupply() + source.accrualSnapshot().unissued;
    }

    /// @notice Whether a current price-sensitive operation may start.
    function available(address reserve) public view returns (bool) {
        IContinuousAccrual source = IContinuousAccrual(reserve);
        if (!source.accrualSnapshot().fresh || source.accrualDelivery().active) return false;
        // Freshness is necessary but does not imply admission: the host can have another
        // conflicting operation in progress without an active delivery permit.
        try source.requireAccrualFresh() {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice Preserves normal loss admission, or consumes the reserve's exact rounding-burn continuation.
    /// @dev The controller host still enforces LOSS_BURNER_ROLE, the authorized endpoint and its
    ///      nonReentrant guard. The reserve accepts only itself as caller and one armed amount/sink.
    function authorizeLossBurn(address reserve, address from, uint256 amount) public {
        if (reserve == address(0)) return;
        if (!IAccrualRounding(reserve).consumeAccrualLossBurn(msg.sender, from, amount)) {
            IContinuousAccrual(reserve).requireAccrualFresh();
        }
    }

    /// @notice Relays only the current reserve-owned, exactly sized permit to its token.
    /// @dev Pausing expansion does not prevent conversion of an existing economic liability.
    ///      The controller proves the raw supply delta; the reserve independently proves its
    ///      accounting closure and recipient balance deltas before completing delivery.
    function deliver(address reserve, address token, mapping(address => bool) storage sinks, uint256 nonce) public {
        if (reserve == address(0) || msg.sender != reserve) revert ControllerAccrual_InvalidDelivery();
        IContinuousAccrual source = IContinuousAccrual(reserve);
        IContinuousAccrual.Delivery memory d = source.accrualDelivery();
        if (
            !d.active || d.nonce != nonce || d.controller != address(this) || d.accruedThrough != block.timestamp
                || d.legs == 0 || d.legs > 3 || (d.senior == 0 && d.fee == 0) || ((d.legs & 1) == 0 && d.senior != 0)
                || ((d.legs & 2) == 0 && d.fee != 0) || !d.pricing.materializationAllowed
                || IAccrualToken(token).accrualReserve() != reserve
        ) revert ControllerAccrual_InvalidDelivery();
        if (d.senior != 0 && !sinks[d.vault]) revert ControllerAccrual_UnauthorizedRecipient(d.vault);
        if (d.fee != 0 && !sinks[d.feeRecipient]) revert ControllerAccrual_UnauthorizedRecipient(d.feeRecipient);
        if (d.senior > type(uint256).max - d.fee) revert ControllerAccrual_InvalidDelivery();
        uint256 expected = d.senior + d.fee;
        uint256 beforeSupply = IERC20(token).totalSupply();
        IAccrualToken(token).mintAccrued(nonce);
        uint256 afterSupply = IERC20(token).totalSupply();
        uint256 actual = afterSupply < beforeSupply ? 0 : afterSupply - beforeSupply;
        if (actual != expected) revert ControllerAccrual_SupplyDeltaMismatch(expected, actual);
    }
}
