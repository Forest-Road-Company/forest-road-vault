// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IReserveManager} from "../interfaces/IReserveManager.sol";
import {ReserveManager} from "../ReserveManager.sol";
import {ReserveAccrualStorageLib} from "./ReserveAccrualStorageLib.sol";

/// @title ReserveStorageLib — the ReserveManager's namespaced storage and its shared primitives
///
/// @notice EXTRACTED 2026-09-09 FOR EIP-170. `ReserveManager` shipped with 9 bytes of margin and
///         went 184 bytes over the moment PIK capitalisation was added, which froze the live
///         mainnet implementation against any new function at all. Forest Road directed the same
///         library extraction BSC used (decision 10). This library holds the pieces the extracted
///         bodies need in common.
///
/// @dev THE STORAGE STRUCT IS NOT HERE, AND THAT IS DELIBERATE. An earlier draft of this file did
///      hold `ReserveStorage`, and this comment described that. It was wrong to keep either. The
///      struct, its ERC-7201 storage-location annotation and the single `$.slot` assignment all
///      stay in `ReserveManager.sol`; this library takes `ReserveManager.ReserveStorage storage`
///      and is HANDED the pointer.
///
///      The reason is the gates. Moving the struct into a library is layout-identical, but
///      `check-storage-layout` keys on the DECLARING FILE and reads the move as a struct REMOVAL,
///      which it will only baseline under `--allow-removals`, a flag whose own message means "this
///      proxy is being freshly redeployed". ReserveManager is a live mainnet proxy and is not. It
///      also requires exactly one `$.slot` assignment in the declaring file, so moving the struct
///      without moving that assignment fails outright. Leaving the declaration where it is makes
///      the extraction layout-neutral BY CONSTRUCTION: both storage baselines were untouched by the
///      commit that introduced this library, which is the strongest evidence available that nothing
///      moved. DO NOT "tidy" the struct into this file.
///
/// @dev EVERY FUNCTION HERE IS `internal`, DELIBERATELY. An `internal` library function is inlined
///      into its caller and saves no bytecode; the size relief comes from `ReserveCreditLib`, whose
///      functions are `public` and therefore deployed separately and reached by delegatecall. These
///      must stay `internal` for a second reason: a library calling ANOTHER library's `public`
///      function leaves a placeholder that halmos cannot link, and every symbolic proof then fails
///      while `forge test` and the size gate stay green.
library ReserveStorageLib {
    /// @dev 1e18 value units per 1e6 USDC unit.
    uint256 internal constant USDC_SCALE = 1e12;

    /// @notice Storage-only native backing, including earned unposted receivables before marks.
    function backingValue(ReserveManager.ReserveStorage storage native) internal view returns (uint256) {
        return normalize(native.idleUSDCUnits) + native.totalDeployedPrincipal + ReserveAccrualStorageLib.unposted()
            - native.totalPrincipalImpairment;
    }

    function normalize(uint256 amount) internal pure returns (uint256) {
        return amount * USDC_SCALE;
    }

    function denormalize(uint256 value) internal pure returns (uint256) {
        return value / USDC_SCALE;
    }

    /// @dev Shared fail-closed predicate for every USDC out-door. Restoring custody or completing
    ///      the arm-bound write-down clears the objective condition without a separate latch.
    function requireIdleFullyCustodied(ReserveManager.ReserveStorage storage $) internal view {
        uint256 recorded = $.idleUSDCUnits;
        uint256 live = $.usdcToken.balanceOf(address(this));
        if (recorded > live) revert IReserveManager.ReserveManager_IdleCustodyShortfall(recorded, live);
    }

    /// @dev A write-down is the realization of loss, so the mark already carried against that loss
    ///      must be consumed to avoid counting the same dollar twice.
    function realizeImpairmentOnWriteDown(
        ReserveManager.ReserveStorage storage $,
        uint256 facilityId,
        uint256 writeDown
    ) internal {
        uint256 recognized = $.principalImpairment[facilityId];
        if (recognized == 0) return;
        uint256 consumed = writeDown < recognized ? writeDown : recognized;
        consumeImpairment($, facilityId, recognized, consumed);
    }

    /// @dev Cash repayment is not evidence that a particular impairment recovered. It may only
    ///      release the portion that would otherwise exceed the facility's remaining face.
    function clampImpairmentToRemainingFace(
        ReserveManager.ReserveStorage storage $,
        uint256 facilityId,
        uint256 remainingFace
    ) internal {
        uint256 recognized = $.principalImpairment[facilityId];
        if (recognized <= remainingFace) return;
        consumeImpairment($, facilityId, recognized, recognized - remainingFace);
    }

    function consumeImpairment(
        ReserveManager.ReserveStorage storage $,
        uint256 facilityId,
        uint256 recognized,
        uint256 consumed
    ) internal {
        uint256 facilityImpairment = recognized - consumed;
        $.principalImpairment[facilityId] = facilityImpairment;
        uint256 total = $.totalPrincipalImpairment - consumed;
        $.totalPrincipalImpairment = total;
        emit IReserveManager.PrincipalImpairmentRealized(facilityId, consumed, facilityImpairment, total);
    }
}
