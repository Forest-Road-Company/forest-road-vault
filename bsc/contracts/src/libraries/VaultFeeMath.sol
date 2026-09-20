// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Config} from "./Config.sol";

/// @title VaultFeeMath
/// @notice Existing vault management-fee arithmetic, linked to preserve deployment-size headroom.
/// @dev This is the unchanged fractional-year retention formula from SUSDfr. The vault validates
///      the configured fee bound and computes elapsed time; no financial rule changes here.
library VaultFeeMath {
    /// @notice Original sequential management/performance accounting inputs.
    struct Inputs {
        uint256 supply;
        uint256 markedAssets;
        uint256 performanceMarkedAssets;
        uint256 highWaterMark;
        uint256 elapsed;
        uint256 virtualShares;
        uint256 shareUnit;
        uint16 managementFeeBps;
        uint16 performanceFeeBps;
    }

    /// @notice Asset and share attribution used by the vault's existing fee events.
    struct Calculation {
        uint256 elapsed;
        uint256 managementAssets;
        uint256 managementShares;
        uint256 profitAssets;
        uint256 performanceAssets;
        uint256 performanceShares;
    }

    /// @notice Unchanged sequential fee calculation from SUSDfr, with no external reads.
    /// @dev Management uses redemption NAV. Performance excludes junior-capital credit and
    ///      uses the original-supply hurdle after management dilution. Combined shares ensure
    ///      that fees paid to the same recipient do not dilute one another.
    function calculate(Inputs memory p) public pure returns (Calculation memory calc) {
        calc.elapsed = p.elapsed;
        if (p.supply == 0) return calc;
        uint256 baseEffectiveSupply = p.supply + p.virtualShares;
        if (p.managementFeeBps != 0 && p.elapsed != 0 && p.markedAssets != 0) {
            calc.managementAssets = managementFeeAssets(p.markedAssets, p.managementFeeBps, p.elapsed);
            calc.managementShares = _feeSharesForAssets(calc.managementAssets, p.markedAssets, baseEffectiveSupply);
        }
        if (p.highWaterMark == 0) return calc;
        uint256 supplyAfterManagement = baseEffectiveSupply + calc.managementShares;
        uint256 netPerformanceAssets =
            Math.mulDiv(p.performanceMarkedAssets + 1, baseEffectiveSupply, supplyAfterManagement, Math.Rounding.Floor);
        uint256 hurdleAssets = Math.mulDiv(p.highWaterMark, baseEffectiveSupply, p.shareUnit, Math.Rounding.Ceil);
        if (netPerformanceAssets <= hurdleAssets) return calc;
        calc.profitAssets = netPerformanceAssets - hurdleAssets;
        calc.performanceAssets = Math.mulDiv(calc.profitAssets, p.performanceFeeBps, Config.BPS, Math.Rounding.Floor);
        uint256 totalFeeShares =
            _feeSharesForAssets(calc.managementAssets + calc.performanceAssets, p.markedAssets, baseEffectiveSupply);
        calc.performanceShares = totalFeeShares - calc.managementShares;
    }

    /// @notice Asset-denominated management fee on the conservative AUM base for elapsed seconds.
    /// @dev Raising annual retention to fractional years makes checkpoints frequency neutral,
    ///      apart from the existing fixed-point approximation and integer rounding.
    function managementFeeAssets(uint256 assets, uint16 feeBps, uint256 elapsed) public pure returns (uint256) {
        uint256 wad = 1e18;
        uint256 annualFeeWad = Math.mulDiv(feeBps, wad, Config.BPS, Math.Rounding.Floor);
        uint256 annualRetentionWad = wad - annualFeeWad;
        uint256 elapsedYearsWad = Math.mulDiv(elapsed, wad, Config.MANAGEMENT_FEE_YEAR, Math.Rounding.Floor);
        uint256 retentionWad = uint256(FixedPointMathLib.powWad(int256(annualRetentionWad), int256(elapsedYearsWad)));
        return Math.mulDiv(assets, wad - retentionWad, wad, Math.Rounding.Floor);
    }

    /// @dev Virtual asset/share conversion, rounded down to the configured asset-denominated fee.
    function _feeSharesForAssets(uint256 feeAssets, uint256 markedAssets, uint256 effectiveSupply)
        private
        pure
        returns (uint256)
    {
        return Math.mulDiv(feeAssets, effectiveSupply, markedAssets + 1 - feeAssets, Math.Rounding.Floor);
    }
}
