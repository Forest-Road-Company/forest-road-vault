// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WaterfallEngine} from "../WaterfallEngine.sol";
import {IDefaultManager} from "../interfaces/IDefaultManager.sol";
import {IsUSDfr} from "../interfaces/IsUSDfr.sol";
import {IWaterfallEngine} from "../interfaces/IWaterfallEngine.sol";
import {Config} from "./Config.sol";

/// @title WaterfallLegacyLib
/// @notice Existing receipt-time interest routing while continuous accounting is disabled.
/// @dev The host retains all receipt authentication and operation guards. Continuous receipts do
///      not enter this library: their interest and both fee claims were already earned.
library WaterfallLegacyLib {
    /// @notice Preserves the native disabled-mode receipt split and its existing fee checkpoint.
    function routeInterest(WaterfallEngine.WaterfallStorage storage $, uint256 interest)
        public
        returns (uint256 fee, uint256 toVault)
    {
        uint256 headroom = $.controller.mintableHeadroom();
        uint256 distributable = interest <= headroom ? interest : headroom;
        if (distributable != interest) {
            // AUDIT FIX (R17): report the RECOGNISED deficit, which is the basis `mintableHeadroom()`
            // is measured on and the basis `distribute`'s closing gate uses. Emitting the RECORDED
            // deficit meant that in the one case R17 added - a withholding caused by an
            // unreconciled custody shortfall - this event published `0` as the remaining hole.
            emit IWaterfallEngine.InterestWithheldForBackingRepair(
                interest - distributable, $.controller.recognizedDeficit()
            );
        }

        fee = Math.mulDiv(distributable, $.protocolFeeBps, Config.BPS);
        // AUDIT FIX (ADV-1) - THESE TWO LINES ARE ORDER-CRITICAL, DO NOT SWAP THEM. `toVault` is
        // computed off the GROSS fee, BEFORE the withholding, so a withheld fee is NEVER MINTED AT
        // ALL and stays in the reserve as backing. Reordering these two statements silently converts
        // the withholding into a REDIRECTION of Forest Road's fee to the `sUSDfr` vault: total
        // minted would go back to `distributable`, nothing would be retained, and the senior
        // exchange rate would jump by the withheld amount. Falsified by
        // `Fix_ADV1-senior-impairment-fee-withholding.t.sol
        // ::test_ADV1_G02_theWithheldFeeIsRetainedAsBackingAndNotRedirectedToTheVault`.
        toVault = distributable - fee;
        fee = _withholdFeeForSeniorImpairment($, fee);

        // Close the prior fee period and acquire the VAULT's persistent operation lock
        // before either mint. WaterfallEngine's own nonReentrant slot cannot protect a
        // different contract from a callback between mintYield and notifyYield.
        if (toVault != 0) {
            IsUSDfr($.vault).beginYieldNotification();
        } else {
            IsUSDfr($.vault).accrueFees();
        }

        // Each mint is asserted against backing by the controller - interest that
        // never physically arrived in the treasury cannot be distributed.
        if (fee != 0) $.controller.mintYield($.feeRecipient, fee);
        if (toVault != 0) {
            $.controller.mintYield($.vault, toVault);
            // The assets are now in the vault. `notifyYield` either recognizes them and
            // checkpoints performance fees immediately (the zero-period launch policy), or
            // starts optional ADR-0023 vesting. The same-transaction vault lock prevents an
            // observer from checkpointing against the delivery window in either mode.
            IsUSDfr($.vault).notifyYield(toVault);
            // Every realized interest payment ends with an explicit fee checkpoint. With
            // the zero-period launch policy this crystallizes performance immediately;
            // under optional streaming it records only the fee classes already due.
            IsUSDfr($.vault).accrueFees();
        }
    }

    /// @notice Preserves the native disabled-mode receipt split and its existing fee checkpoint.
    /// @dev AUDIT FIX (ADV-1) - THE SENIOR-IMPAIRMENT FEE CEILING, LOAD-BEARING, DO NOT DELETE.
    ///      Read the ADV-1 block on `_routeInterest` first: it records WHAT was false, WHY the fee
    ///      leg is the part that is wrong, and why the vault leg is deliberately untouched.
    ///
    ///      THE STOCK/FLOW RULE, STATED EXPLICITLY BECAUSE GETTING IT WRONG BROKE THE PREVIOUS
    ///      ATTEMPT AT THIS FIX. `pendingSeniorImpairment()` is a CUMULATIVE STOCK, in units of
    ///      declared/past-due PRINCIPAL, that persists across transactions and is NOT reduced by
    ///      anything this function does. `feeGross` is a PER-TRANSACTION FLOW derived from this one
    ///      interest receipt. THE STOCK IS USED ONLY AS A CEILING ON THE FLOW, NEVER SUBTRACTED
    ///      FROM THE FLOW'S BASIS:
    ///
    ///          withheld = min(feeGross, residual);   feeNet = feeGross - withheld
    ///
    ///      A ceiling is dimensionally safe. It can only reduce the flow, at worst to zero; it never
    ///      propagates the stock's MAGNITUDE into the flow's arithmetic, so a 300,000e18 residual
    ///      and a 3e18 residual both mean "no fee out of this receipt" rather than producing two
    ///      different answers for the same receipt. THE FAILED ATTEMPT netted this same stock off
    ///      `MintRedeemController.mintableHeadroom()` - which is the BASIS of the flow, because
    ///      `distributable = min(interest, headroom)` - so one cumulative stock annihilated every
    ///      per-transaction flow AND the vault leg with it. ~20 differential reference-model
    ///      assertions ("DIFF: fee split: 0 != N") plus an invariant went red, because the reference
    ///      model computes the split from `interest` and `protocolFeeBps` alone. DO NOT MOVE THIS
    ///      NETTING INTO `mintableHeadroom()`: that view is the basis, and it is also read by
    ///      `fund`, by `mintYield`'s own level check and by the dashboard, none of which are
    ///      per-receipt flows.
    ///
    ///      IT IS THE BASE, NON-ASSESSED MARK, AND THAT IS DELIBERATE. `sUSDfr` reads an
    ///      `IImpairmentSource` that in production is `AssessedImpairmentSource` wrapping this same
    ///      manager (ADR-0027), and an assessment can be REFRESHED, can EXPIRE, and can report a
    ///      DIFFERENT number from the base. Reading the assessed source would make Forest Road's own
    ///      fee ceiling movable by a governance act Forest Road controls, and would make it flap on
    ///      `validUntil`. Reading the base makes the ceiling non-relaxable and stable. THE COST,
    ///      DISCLOSED RATHER THAN FIXED: where an assessment marks MORE conservatively than the
    ///      base, this under-withholds by the excess. Closing that gap means teaching this engine
    ///      the vault's impairment source, which is a second source of truth and a wiring change.
    ///
    ///      THE KNOWN OVER-WITHHOLDING, DISCLOSED RATHER THAN FIXED. The residual does not fall when
    ///      a fee is withheld, so N receipts against a residual smaller than one fee withhold up to
    ///      N times that residual in total. That is over-conservative in Forest Road's own direction
    ///      only, it is bounded by the fee that would otherwise have been paid, and the alternative
    ///      (a consumable per-residual allowance) needs a stored ledger reconciling credit-layer
    ///      principal against fee flows - the non-monotonic shape that
    ///      `MintRedeemController.seniorSubParShortfall` explains it deliberately refuses.
    ///
    ///      UNWIRED IS SAFE AND IS THE ONLY REASON THE ZERO CHECK EXISTS. The DefaultManager is
    ///      constructed AFTER this engine in `Deploy.s.sol` and in the fixtures, so a zero manager
    ///      is a reachable pre-wiring state; it withholds nothing and behaves exactly as before the
    ///      fix. `Validate.s.sol` asserts the production wiring. NOT `try/catch`, deliberately: a
    ///      wired-but-reverting manager must take the distribution down loudly (CLAUDE.md prime
    ///      directive 4) rather than silently resume paying a fee out of a shortfall - the same
    ///      house rule the ADR-0022 resolve hooks in `distribute` state for the same shape.
    ///
    ///      NO REENTRANCY OR LIVENESS SURFACE. `pendingSeniorImpairment()` is a `view` over fixed
    ///      per-class storage plus two unguarded storage-reading views (`CuratorModule.poolBalance`,
    ///      `sGROVE.coverageCapacity`), it is already reached later in this same transaction through
    ///      the vault's fee checkpoint, and this function's only effect is to make a mint SMALLER -
    ///      which can never make `mintYield`, the vault, or `distribute`'s closing non-worsening
    ///      gate revert. Deleting the guard cannot fix a liveness bug because it cannot cause one.
    ///
    ///      THE NAMED TESTS THAT CATCH EACH MUTATION, so no part of this is silently deletable
    ///      (all in `test/audit/Fix_ADV1-senior-impairment-fee-withholding.t.sol`):
    ///        - DELETE the call, or `return feeGross` unconditionally
    ///                                     -> `test_ADV1_G01_theInterestFeeIsWithheldWhileAn...`
    ///        - SWAP the two order-critical lines at the call site (redirect instead of retain)
    ///                                     -> `test_ADV1_G02_theWithheldFeeIsRetainedAsBacking...`
    ///        - SWAP the basis for a GROSS impairment measure (drop the cascade netting)
    ///                                     -> `test_ADV1_G03_curatorFirstLossAbsorbingTheDefault...`
    ///        - REPLACE `min(feeGross, residual)` with a binary `residual != 0 => fee = 0` cliff
    ///                                     -> `test_ADV1_G04_theResidualIsACeilingOnTheFeeNot...`
    ///        - DELETE the event emit
    ///                                     -> `test_ADV1_G05_theWithholdingEventReconstructs...`
    ///        - the tolerated zero-manager branch
    ///                                     -> `test_ADV1_G06_anUnwiredDefaultManagerWithholds...`
    ///        - EXTEND the withholding to the vault leg (the decision reserved to Forest Road)
    ///                                     -> `test_ADV1_G07_aPermissionlessPastDueMarkWithholds...`
    ///        - make this and the R16-M5 clamp SUBTRACT from one another instead of composing
    ///                                     -> `test_ADV1_G08_theTwoClampsComposeAsAFloorAnd...`
    ///      Plus `ADV_GateAndCascade::test_P1/test_P6/test_P7`, the original probes, whose
    ///      assertions were INVERTED when this landed, and the two differential reference models
    ///      (`CreditHandler.repay`, `CascadeSeniorityHandler._distribute`), which recompute the
    ///      ceiling from their own reads of `pendingSeniorImpairment()` and assert the split
    ///      exactly, per call.
    /// @param $ Engine storage.
    /// @param feeGross The protocol fee as split off `distributable`, before any withholding.
    /// @return feeNet The part of `feeGross` that may be minted to the fee recipient.
    function _withholdFeeForSeniorImpairment(WaterfallEngine.WaterfallStorage storage $, uint256 feeGross)
        private
        returns (uint256 feeNet)
    {
        IDefaultManager dm = $.defaultManager;
        if (feeGross == 0 || address(dm) == address(0)) return feeGross;
        uint256 residual = dm.pendingSeniorImpairment();
        if (residual == 0) return feeGross;
        uint256 withheld = feeGross < residual ? feeGross : residual;
        emit IWaterfallEngine.ProtocolFeeWithheldForSeniorImpairment(withheld, residual);
        return feeGross - withheld;
    }
}
