// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IReserveManager} from "../interfaces/IReserveManager.sol";
import {ReserveStorageLib} from "./ReserveStorageLib.sol";

/// @title ReserveBasketLib - the record-capped exit, the pro-rata basket, and the escrows
/// @notice The protocol pays reserve value IN KIND. A redeemer is paid, first, their OWN RECORDED
///         ASSETS at one to one, capped by the units they themselves deposited; everything beyond
///         that record is paid as a pro-rata basket over every payable asset.
///
///         THERE IS STILL NO FREE ELECTION OF A LEG, and the warning this replaces is rewritten
///         rather than deleted (Forest Road direction 2026-09-07). The old text said the door does
///         not exist because handing a holder the choice of leg reopens the free option. The door
///         now exists in exactly one narrow form and the reasoning is unchanged: the CAP is what
///         closes the option. A redeemer can only take back the asset they put in, up to the amount
///         they put in, so they cannot convert an impaired asset into a sound one at the expense of
///         the holders who stay. The remainder pays the basket, which involves no choice and
///         therefore shifts no currency risk, and a recorded asset the reserve cannot fund becomes
///         a deferred claim ON THAT ASSET rather than a basket payment, because paying the basket
///         there would reopen precisely the transfer the cap closes.
///
///         Any swap to one asset still happens in a separate, non-upgradeable periphery router, in
///         the redeemer's own transaction, on tokens already in the redeemer's wallet.
/// @dev EIP-170: `release` and `claimLeg` are `public` library functions, so they are deployed
///      separately and reached by `delegatecall`. Role checks, `nonReentrant` and `whenNotPaused`
///      stay in the PROXY-SIDE function and are never relied upon here.
library ReserveBasketLib {
    using SafeERC20 for IERC20;

    /// @dev Gas held back so the release can finish its bookkeeping, emit its events and return
    ///      after the last leg's delivery attempt.
    uint256 private constant FINALISE_RESERVE = 60_000;
    /// @dev Floor on the per-leg delivery budget. Below this a well-behaved ERC-20 transfer could
    ///      fail for lack of gas and be misrecorded as a deferred leg, so the whole call refuses.
    uint256 private constant MIN_LEG_GAS = 30_000;

    /// @notice Allocates and delivers a pro-rata basket worth `usdfrValue` to `to`.
    /// @dev Returns arrays of the FULL registry length, positionally aligned with `assetList`, so a
    ///      consumer can pair legs with assets by index and the allocation is replayable from
    ///      events. `usdfrValue - valuePaid` is sub-unit dust the caller must leave with the
    ///      holder, exactly as the controller's redeem quote already leaves USDfr dust.
    /// @param $ The reserve's ERC-7201 storage.
    /// @param to The recipient of every leg.
    /// @param usdfrValue The 18-decimal reserve value to pay.
    /// @return legAssets The registry, in listing order.
    /// @return legAmounts Native units allocated per leg, zero where a leg did not participate.
    /// @return valuePaid The 18-decimal value actually settled.
    function release(ReserveStorageLib.ReserveStorage storage $, address to, uint256 usdfrValue)
        public
        returns (address[] memory legAssets, uint256[] memory legAmounts, uint256 valuePaid)
    {
        // -- preconditions --
        if (to == address(0)) revert IReserveManager.ReserveManager_ZeroAddress();
        if (to == address(this)) revert IReserveManager.ReserveManager_SelfDeployment();
        if (usdfrValue == 0) revert IReserveManager.ReserveManager_ZeroAmount();
        legAssets = $.assetList;
        if (legAssets.length == 0) revert IReserveManager.ReserveManager_NoAssetsListed();
        // R4-01: nobody exits at par while an adjudicated custody loss is unallocated.
        ReserveStorageLib.requireCustodied($);
        address reviewedAsset = _pendingReview($, legAssets);
        if (reviewedAsset != address(0)) revert IReserveManager.ReserveManager_AssetAdjudicationPending(reviewedAsset);
        uint256[] memory avail = _available($, legAssets);
        uint256 total = _totalOf($, legAssets, avail);
        if (usdfrValue > total) {
            revert IReserveManager.ReserveManager_InsufficientPayableValue(usdfrValue, total);
        }

        legAmounts = new uint256[](legAssets.length);
        uint256 legCount;
        (valuePaid, legCount) = _allocate($, legAssets, legAmounts, avail, usdfrValue, total);
        _settle($, to, legAssets, legAmounts, legCount);
        emit IReserveManager.BasketReleased(to, usdfrValue, valuePaid, legCount);
    }

    /// @notice Executes either existing basket path and encodes its unchanged external result.
    /// @dev The reserve retains authorization, pause and reentrancy checks. Encoding the arrays
    ///      here avoids decoding and re-encoding them in its size-constrained implementation.
    function releaseData(address to, uint256 usdfrValue, bool recorded) public returns (bytes memory) {
        ReserveStorageLib.ReserveStorage storage s = ReserveStorageLib.layout();
        (address[] memory assets, uint256[] memory amounts, uint256 valuePaid) =
            recorded ? releaseRecorded(s, to, usdfrValue) : release(s, to, usdfrValue);
        return abi.encode(assets, amounts, valuePaid);
    }

    /// @notice Pays `usdfrValue` by drawing `to`'s OWN recorded assets first, then the basket.
    /// @dev THE RECORD CAP IS THE SECURITY PROPERTY (Forest Road direction 2026-09-07). A redeemer
    ///      receives the assets they themselves deposited, one unit of value per USDfr of value, up
    ///      to the units their record still carries. They may not name an asset, and the record does
    ///      not move when USDfr is transferred, so buying USDfr on a market confers no record and no
    ///      claim on anybody else's deposit.
    ///
    ///      Three passes, in this order and for these reasons:
    ///        R1  THE RECORD, allocated PRO RATA ACROSS THE HOLDER'S OWN RECORDED ASSETS. Pro rata
    ///            rather than in listing order deliberately: a fixed order would let a holder with
    ///            two recorded assets take the sound one first on a partial exit and leave the
    ///            impaired one recorded, which is the very transfer the cap exists to close, in
    ///            miniature. Pro rata involves no choice.
    ///        R2  THE UNFUNDED RESIDUE of R1 becomes a PENDING CLAIM ON THAT SAME ASSET, never a
    ///            basket payment. Its value leaves backing here, because the USDfr is burned here.
    ///        R3  THE REMAINDER, meaning value beyond the record, pays the ordinary PRO-RATA BASKET.
    ///            Yield and protocol-fee USDfr are minted with no deposit record at all, so this is
    ///            the normal path for those holders and it must work well.
    ///
    ///      Every rounding is DOWN, exactly as the basket's own allocator rounds, so over-allocation
    ///      stays unrepresentable rather than merely checked.
    /// @param $ The reserve's ERC-7201 storage.
    /// @param to The redeemer, and the owner of the record drawn.
    /// @param usdfrValue The 18-decimal reserve value to settle.
    /// @return legAssets The registry, in listing order, at full length.
    /// @return legAmounts Native units DELIVERED (or escrowed as an undeliverable leg) per asset.
    ///         Promised units are NOT in here: nothing moved for them.
    /// @return valuePaid Total 18-decimal value settled, cash plus promises.
    /// @dev While a currency is under review, all of this holder's participating records must be
    ///      healthy and cover the full value. Any remainder refuses the transaction. Existing
    ///      pending claims remain owned by their holders and follow their existing claim paths.
    function releaseRecorded(ReserveStorageLib.ReserveStorage storage $, address to, uint256 usdfrValue)
        public
        returns (address[] memory legAssets, uint256[] memory legAmounts, uint256 valuePaid)
    {
        // -- preconditions, identical to `release` --
        if (to == address(0)) revert IReserveManager.ReserveManager_ZeroAddress();
        if (to == address(this)) revert IReserveManager.ReserveManager_SelfDeployment();
        if (usdfrValue == 0) revert IReserveManager.ReserveManager_ZeroAmount();
        legAssets = $.assetList;
        uint256 n = legAssets.length;
        if (n == 0) revert IReserveManager.ReserveManager_NoAssetsListed();
        // R4-01: nobody exits at par while an adjudicated custody loss is unallocated.
        ReserveStorageLib.requireCustodied($);

        bool recordedOnly = _requireReviewRecord($, to, legAssets, usdfrValue);
        legAmounts = new uint256[](n);
        uint256[] memory avail = _available($, legAssets);

        // R1 and R2. `claimValue` is the part of the record that could not be funded from the tally.
        // It is NOT returned: the caller derives it as `valuePaid - sum legAmounts * scale` from its
        // OWN cached scales, which is a measurement rather than a restatement of this library's
        // word, and is therefore the figure that survives a hostile reserve.
        (uint256 recordedValue, uint256 claimValue) = _drawRecord($, to, legAssets, legAmounts, avail, usdfrValue);

        // R3. `avail` now excludes both the reserved claims and everything R1 just took, so the
        // basket cannot re-allocate a unit this holder has already been given or promised.
        uint256 remainder = usdfrValue - recordedValue;
        uint256 basketValue;
        if (remainder != 0) {
            if (recordedOnly) {
                revert IReserveManager.ReserveManager_InsufficientRecordedValue(usdfrValue, recordedValue);
            }
            uint256 total = _totalOf($, legAssets, avail);
            if (remainder > total) {
                revert IReserveManager.ReserveManager_InsufficientRecordedValue(usdfrValue, recordedValue + total);
            }
            (basketValue,) = _allocate($, legAssets, legAmounts, avail, remainder, total);
        }

        _settle($, to, legAssets, legAmounts, _countLegs(legAmounts));
        valuePaid = recordedValue + basketValue;
        emit IReserveManager.RecordedExitReleased(to, usdfrValue, recordedValue, basketValue, claimValue, valuePaid);
    }

    /// @dev Under a pending review, every record participating in a new exit must be healthy.
    ///      The whole requested payout is record-covered; no general basket remainder is allowed.
    ///      This check runs again at settlement, after any controller-side admission or token hook.
    function _requireReviewRecord(
        ReserveStorageLib.ReserveStorage storage $,
        address holder,
        address[] memory assets,
        uint256 requested
    ) private view returns (bool) {
        if (_pendingReview($, assets) == address(0)) return false;
        uint256 recorded;
        for (uint256 i; i < assets.length; ++i) {
            address asset = assets[i];
            uint256 units = $.depositRecord[holder][asset];
            if (units == 0) continue;
            if (ReserveStorageLib.adjudicationPending($, asset)) {
                revert IReserveManager.ReserveManager_AssetAdjudicationPending(asset);
            }
            if ($.assets[asset].frozenRedeem) revert IReserveManager.ReserveManager_AssetRedeemFrozen(asset);
            recorded += units * $.assets[asset].scale;
        }
        if (recorded < requested) revert IReserveManager.ReserveManager_InsufficientRecordedValue(requested, recorded);
        return true;
    }

    /// @dev Finds a pending review from storage, without consulting any token contract.
    function _pendingReview(ReserveStorageLib.ReserveStorage storage $, address[] memory assets)
        private
        view
        returns (address)
    {
        if ($.openArmCount == 0) return address(0);
        for (uint256 i; i < assets.length; ++i) {
            if (ReserveStorageLib.adjudicationPending($, assets[i])) return assets[i];
        }
        return address(0);
    }

    /// @dev R1 and R2 of `releaseRecorded`: the holder's own record, drawn pro rata, with the
    ///      unfunded residue escrowed as a claim on the same asset.
    ///
    ///      THE CLAIM'S VALUE LEAVES BACKING HERE, and that is not optional. The redeemer's USDfr is
    ///      burned in the same transaction while the promised units are still sitting in the tally
    ///      (they are deployed, or the asset is redeem-frozen). Without this subtraction backing per
    ///      remaining USDfr would rise by the promise and then fall again when the promise settled,
    ///      so the second leg would push the remaining holders under-backed for a promise they never
    ///      benefited from. `claimPending` reverses both halves together, so the pair conserves
    ///      value exactly.
    /// @return recordedValue The 18-decimal value settled out of the record, funded plus promised.
    /// @return claimValue The 18-decimal part of `recordedValue` that was promised, not funded.
    function _drawRecord(
        ReserveStorageLib.ReserveStorage storage $,
        address to,
        address[] memory legAssets,
        uint256[] memory legAmounts,
        uint256[] memory avail,
        uint256 usdfrValue
    ) private returns (uint256 recordedValue, uint256 claimValue) {
        uint256 n = legAssets.length;
        uint256[] memory want = new uint256[](n);
        uint256[] memory scales = new uint256[](n);
        uint256 recordValue = _recordValue($, to, legAssets, want, scales);
        if (recordValue == 0) return (0, 0);
        uint256 drawValue = usdfrValue < recordValue ? usdfrValue : recordValue;
        // Turn the record (held in `want` as units) into this draw's target, floored per leg, then
        // place the floored-away residue in the same fixed index order the basket's dust rule uses,
        // bounded by each leg's own record so the cap can never be exceeded by the placement.
        recordedValue = shareRecord(scales, want, recordValue, drawValue);
        if (recordedValue != 0) claimValue = _placeDraw($, to, legAssets, legAmounts, avail, want);
    }

    /// @dev The write half of R1/R2: the record falls by the whole draw, the funded part joins the
    ///      delivery legs, and the unfunded part becomes a claim on the SAME asset.
    ///      Split from `_drawRecord` purely for stack depth; it takes no decision of its own.
    function _placeDraw(
        ReserveStorageLib.ReserveStorage storage $,
        address to,
        address[] memory legAssets,
        uint256[] memory legAmounts,
        uint256[] memory avail,
        uint256[] memory want
    ) private returns (uint256 claimValue) {
        for (uint256 i; i < legAssets.length; ++i) {
            uint256 units = want[i];
            if (units == 0) continue;
            address asset = legAssets[i];
            {
                // The record falls by the FULL draw, funded or not: a promise is a drawdown, and
                // leaving the record standing on the promised part would let it be drawn twice.
                uint256 remainingRecord = $.depositRecord[to][asset] - units;
                $.depositRecord[to][asset] = remainingRecord;
                emit IReserveManager.DepositRecordDrawn(to, asset, units, remainingRecord);
            }
            uint256 funded = units < avail[i] ? units : avail[i];
            if (funded != 0) {
                legAmounts[i] = funded;
                avail[i] -= funded;
            }
            if (units != funded) claimValue += _escrowClaim($, to, asset, units - funded);
        }
    }

    /// @dev Writes one pending claim and removes its par value from backing. Both halves are
    ///      reversed together by `claimPending`, so the pair conserves value exactly.
    function _escrowClaim(ReserveStorageLib.ReserveStorage storage $, address to, address asset, uint256 promised)
        private
        returns (uint256 value)
    {
        value = promised * $.assets[asset].scale;
        $.pendingClaimUnits[to][asset] += promised;
        $.claimedUnits[asset] += promised;
        $.totalClaimValue += value;
        emit IReserveManager.PendingClaimEscrowed(to, asset, promised, value);
    }

    /// @dev Reads the holder's record into `want` and returns its 18-decimal value.
    function _recordValue(
        ReserveStorageLib.ReserveStorage storage $,
        address to,
        address[] memory legAssets,
        uint256[] memory want,
        uint256[] memory scales
    ) private view returns (uint256 recordValue) {
        for (uint256 i; i < legAssets.length; ++i) {
            address asset = legAssets[i];
            uint256 units = $.depositRecord[to][asset];
            if (units == 0) continue;
            want[i] = units;
            scales[i] = $.assets[asset].scale;
            recordValue += units * scales[i];
        }
    }

    /// @dev Rewrites `want` from "the whole record" to "this draw's pro-rata share of it", floored
    ///      to whole native units, then places the floored-away residue deterministically. The
    ///      per-leg cap is the leg's own record, so no placement can draw more than was deposited.
    /// @param scales Native-unit normalization for each record, in registry order.
    /// @param want Remaining record units, rewritten in memory to this draw's allocation.
    /// @param recordValue Total normalized value of the supplied records.
    /// @param drawValue Requested value, bounded by recordValue by the caller.
    /// @return drawn Representable value assigned to those records, including deterministic dust.
    function shareRecord(uint256[] memory scales, uint256[] memory want, uint256 recordValue, uint256 drawValue)
        internal
        pure
        returns (uint256 drawn)
    {
        uint256 n = want.length;
        uint256[] memory cap = new uint256[](n);
        uint256 minScale = type(uint256).max;
        for (uint256 i; i < n; ++i) {
            uint256 recorded = want[i];
            if (recorded == 0) continue;
            uint256 scale = scales[i];
            if (scale < minScale) minScale = scale;
            cap[i] = recorded;
            uint256 units = Math.mulDiv(drawValue, recorded * scale, recordValue) / scale;
            if (units > recorded) units = recorded;
            want[i] = units;
            drawn += units * scale;
        }
        uint256 dust = drawValue - drawn;
        for (uint256 i; i < n && dust >= minScale; ++i) {
            uint256 recorded = cap[i];
            if (recorded == 0) continue;
            uint256 scale = scales[i];
            if (dust < scale) continue;
            uint256 extra = dust / scale;
            uint256 headroom = recorded - want[i];
            if (extra > headroom) extra = headroom;
            if (extra == 0) continue;
            want[i] += extra;
            uint256 placed = extra * scale;
            dust -= placed;
            drawn += placed;
        }
    }

    /// @notice Pulls units against a pending claim once the asset's units are back in the tally.
    /// @dev The holder's own transaction, the holder's own failure: a revert here reverts only the
    ///      claimer's call. NOT gated on the custody-loss interlock and NOT pausable, for the same
    ///      reason `claimLeg` is neither: the claim's value was already removed from backing when it
    ///      was written, so these units are the holder's property in the ledger already, and a pause
    ///      must not strand them.
    ///
    ///      BACKING DOES NOT MOVE HERE. The tally falls by `amount * scale` and the claim liability
    ///      falls by exactly the same figure, so the two cancel. That is the second half of the pair
    ///      opened in `_drawRecord`, and it is why the promise could be written against backing at
    ///      all.
    ///
    ///      Claimants share the asset's returning units first come, first served. There is no
    ///      queue: every claim is the same instrument on the same asset, and a queue would add an
    ///      ordering surface with nothing to order.
    /// @param $ The reserve's ERC-7201 storage.
    /// @param holder The claim owner and the recipient.
    /// @param asset The promised asset.
    /// @return amount Native units delivered.
    function claimPending(ReserveStorageLib.ReserveStorage storage $, address holder, address asset)
        public
        returns (uint256 amount)
    {
        uint256 owed = $.pendingClaimUnits[holder][asset];
        if (owed == 0) revert IReserveManager.ReserveManager_NoPendingClaim(asset);
        ReserveStorageLib.ReserveAsset storage r = ReserveStorageLib.requireListed($, asset);
        if (r.frozenRedeem) revert IReserveManager.ReserveManager_AssetRedeemFrozen(asset);
        uint256 held = ReserveStorageLib.idleAfterCustodyLoss(r);
        amount = owed < held ? owed : held;
        if (amount == 0) revert IReserveManager.ReserveManager_PendingClaimUnfunded(asset, owed);

        uint256 remaining = owed - amount;
        $.pendingClaimUnits[holder][asset] = remaining;
        $.claimedUnits[asset] -= amount;
        $.totalClaimValue -= amount * r.scale;
        // The tally falls BEFORE any token moves, through the single writer.
        ReserveStorageLib.writeAsset($, r, r.units - amount, r.cap, r.recognizedCapLoss, r.frozenRedeem);
        IERC20(asset).safeTransfer(holder, amount);
        emit IReserveManager.PendingClaimSettled(holder, asset, amount, remaining);
    }

    /// @dev Allocatable native units per leg: redeem freeze and reserved claims already netted out.
    function _available(ReserveStorageLib.ReserveStorage storage $, address[] memory legAssets)
        private
        view
        returns (uint256[] memory avail)
    {
        uint256 n = legAssets.length;
        avail = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            avail[i] = ReserveStorageLib.availableUnits($, legAssets[i]);
        }
    }

    /// @dev The 18-decimal value of an `avail` vector. Recomputed rather than read from the O(1)
    ///      payable cache because that cache is GROSS: it knows nothing about units already
    ///      reserved against a pending claim, and allocating those would pay one holder's promise
    ///      to another. The loop is bounded by `MAX_RESERVE_ASSETS` and is storage-only.
    function _totalOf(ReserveStorageLib.ReserveStorage storage $, address[] memory legAssets, uint256[] memory avail)
        private
        view
        returns (uint256 total)
    {
        for (uint256 i; i < legAssets.length; ++i) {
            total += avail[i] * $.assets[legAssets[i]].scale;
        }
    }

    /// @dev Number of legs that will actually move a token, for `_settle`'s gas budgeting.
    function _countLegs(uint256[] memory legAmounts) private pure returns (uint256 legCount) {
        for (uint256 i; i < legAmounts.length; ++i) {
            if (legAmounts[i] != 0) ++legCount;
        }
    }

    /// @dev Passes one and two: the proportional floor and the deterministic dust placement.
    ///
    ///      ROUNDING DIRECTION: floor, always, on both steps. The sum of tallies is exactly
    ///      `total`, so the sum of floored shares can never exceed `usdfrValue`: over-allocation is
    ///      made UNREPRESENTABLE rather than merely checked. Rounding any single leg up can make
    ///      its share exceed its own tally when that tally is exactly its pro-rata share, which
    ///      would underflow that leg's units and pay the exiting holder out of the staying holders'
    ///      assets. The second floor is the per-asset analogue of "redemption rounds down to whole
    ///      units" and is a no-op at scale 1.
    ///
    ///      DUST BOUND: the residual is strictly below the smallest payable scale, so with every
    ///      listed asset 18-decimal (scale 1) it is ALWAYS ZERO and pass two is inert. It becomes
    ///      live the day a sub-18-decimal asset is listed. Placement walks the same fixed index
    ///      order, which is the same "integer dust deterministically in the lowest numbered pools
    ///      with headroom" rule the curator pools already use, so there is one dust doctrine.
    function _allocate(
        ReserveStorageLib.ReserveStorage storage $,
        address[] memory legAssets,
        uint256[] memory legAmounts,
        uint256[] memory avail,
        uint256 usdfrValue,
        uint256 total
    ) private view returns (uint256 valuePaid, uint256 legCount) {
        uint256 paid;
        uint256 minScale;
        (paid, minScale, legCount) = _proRata($, legAssets, legAmounts, avail, usdfrValue, total);
        uint256 dust = usdfrValue - paid;
        if (dust >= minScale) {
            uint256 extraLegs;
            (dust, extraLegs) = _placeDust($, legAssets, legAmounts, avail, dust, minScale);
            legCount += extraLegs;
        }
        valuePaid = usdfrValue - dust;
    }

    /// @dev Pass one: each payable leg's floored pro-rata share, re-derived as the EXACT value of
    ///      the whole native units that will move.
    function _proRata(
        ReserveStorageLib.ReserveStorage storage $,
        address[] memory legAssets,
        uint256[] memory legAmounts,
        uint256[] memory avail,
        uint256 usdfrValue,
        uint256 total
    ) private view returns (uint256 paid, uint256 minScale, uint256 legCount) {
        minScale = type(uint256).max;
        for (uint256 i; i < legAssets.length; ++i) {
            uint256 units = avail[i];
            if (units == 0) continue;
            uint256 scale = $.assets[legAssets[i]].scale;
            if (scale < minScale) minScale = scale;
            uint256 amount = Math.mulDiv(usdfrValue, units * scale, total) / scale;
            if (amount == 0) continue;
            // `legAmounts[i]` may already carry a recorded draw, so this ACCUMULATES rather than
            // assigns, and `avail` falls in step so the dust pass cannot spend the same unit twice.
            if (legAmounts[i] == 0) ++legCount;
            legAmounts[i] += amount;
            avail[i] = units - amount;
            paid += amount * scale;
        }
    }

    /// @dev Pass two: the sub-unit residual, placed deterministically in the lowest numbered legs
    ///      with headroom.
    function _placeDust(
        ReserveStorageLib.ReserveStorage storage $,
        address[] memory legAssets,
        uint256[] memory legAmounts,
        uint256[] memory avail,
        uint256 dust,
        uint256 minScale
    ) private view returns (uint256, uint256) {
        uint256 extraLegs;
        for (uint256 i; i < legAssets.length && dust >= minScale; ++i) {
            uint256 headroom = avail[i];
            if (headroom == 0) continue;
            uint256 scale = $.assets[legAssets[i]].scale;
            if (dust < scale) continue;
            uint256 extra = dust / scale;
            if (extra > headroom) extra = headroom;
            if (extra == 0) continue;
            if (legAmounts[i] == 0) ++extraLegs;
            legAmounts[i] += extra;
            avail[i] = headroom - extra;
            dust -= extra * scale;
        }
        return (dust, extraLegs);
    }

    /// @dev Pass three: settlement, per leg, checks-effects-interactions.
    ///
    ///      A reverting, paused, frozen or gas-bombing token degrades to a deferred leg for THAT
    ///      asset only. This is the mechanism that satisfies the binding rule that such a token
    ///      must never freeze delivery of the others; a whole-basket revert would have violated it.
    ///      The gas budget scales with the caller's own `gasleft()` rather than being a fixed
    ///      stipend, so "unreadable" cannot be made to mean "heavy".
    function _settle(
        ReserveStorageLib.ReserveStorage storage $,
        address to,
        address[] memory legAssets,
        uint256[] memory legAmounts,
        uint256 legCount
    ) private {
        uint256 remaining = legCount;
        uint256 n = legAssets.length;
        for (uint256 i; i < n; ++i) {
            uint256 amount = legAmounts[i];
            if (amount == 0) continue;
            address asset = legAssets[i];
            ReserveStorageLib.ReserveAsset storage r = $.assets[asset];
            uint256 value = amount * r.scale;
            // The tally falls BEFORE any token moves.
            ReserveStorageLib.writeAsset($, r, r.units - amount, r.cap, r.recognizedCapLoss, r.frozenRedeem);

            uint256 available = gasleft();
            if (available <= FINALISE_RESERVE) revert IReserveManager.ReserveManager_InsufficientGasForBasket();
            uint256 perLeg = (available - FINALISE_RESERVE) / remaining;
            if (perLeg < MIN_LEG_GAS) revert IReserveManager.ReserveManager_InsufficientGasForBasket();
            --remaining;

            if (_deliver(asset, to, amount, perLeg)) {
                emit IReserveManager.BasketLegPaid(to, asset, amount, value);
            } else {
                r.deferredUnits += amount;
                $.deferredLegs[to][asset] += amount;
                emit IReserveManager.BasketLegDeferred(to, asset, amount, value);
            }
        }
    }

    /// @notice Pulls a basket leg that could not be delivered when it was allocated.
    /// @dev The holder's own transaction, the holder's own failure: a revert here reverts only the
    ///      claimer's call. The tally was already debited when the leg was allocated, so this moves
    ///      escrowed tokens and never touches backing. The payment must fit recorded physical
    ///      custody net of known losses. Returned tokens beyond that book first need the existing
    ///      cure or arm-recovery step; a claim cannot silently erase a loss ledger.
    /// @param $ The reserve's ERC-7201 storage.
    /// @param holder The escrow owner and the recipient.
    /// @param asset The escrowed asset.
    /// @return amount Native units delivered.
    function claimLeg(ReserveStorageLib.ReserveStorage storage $, address holder, address asset)
        public
        returns (uint256 amount)
    {
        amount = $.deferredLegs[holder][asset];
        if (amount == 0) revert IReserveManager.ReserveManager_NoDeferredLeg(asset);
        $.deferredLegs[holder][asset] = 0;
        ReserveStorageLib.ReserveAsset storage r = $.assets[asset];
        uint256 custodied = ReserveStorageLib.custodiedUnits(r);
        if (amount > custodied) {
            revert IReserveManager.ReserveManager_DeferredLegUnfunded(asset, amount, custodied);
        }
        r.deferredUnits -= amount;
        IERC20(asset).safeTransfer(holder, amount);
        emit IReserveManager.DeferredLegClaimed(holder, asset, amount);
    }

    /// @dev Bounded delivery attempt, decoded exactly as SafeERC20 decodes: success with empty
    ///      returndata from an address that has code, or success with a 32-byte `true`. Any other
    ///      outcome - revert, out-of-gas inside the bounded call, a non-standard return - is a
    ///      failure that the caller defers rather than propagates. The result is read with a plain
    ///      word load rather than `abi.decode` so that a malformed return cannot itself revert.
    ///
    ///      THE COPY IS BOUNDED TO ONE WORD, AND THAT BOUND IS LOAD-BEARING (fixed 2026-09-08).
    ///      This was `(bool success, bytes memory ret) = asset.call{gas: gasBudget}(...)`. The gas
    ///      cap bounds what the CALLEE spends; assigning to `bytes memory` then made the CALLER pay,
    ///      AFTER the call and OUTSIDE that cap, to expand memory by `returndatasize()` and
    ///      `returndatacopy` the lot. Both costs are quadratic in size and the caller's memory is
    ///      already the larger, so a leg that spent its whole budget building a buffer made this
    ///      frame spend MORE than the budget it had been capped at - straight out of the gas
    ///      `_settle` had reserved for the remaining legs.
    ///
    ///      MEASURED, NOT REASONED. `CustodyIsolationInvariants.test_ISO5b_*` drove a listed token
    ///      returning buffers across four orders of magnitude under an 8,000,000 gas stipend. At
    ///      about 43,000 to 56,000 words - roughly 1.4 to 1.8 MB - the OUTER frame ran out of gas
    ///      and the ENTIRE redemption reverted with empty returndata, leaving the sound leg unpaid.
    ///      Below that band the caller absorbed the cost; above it the callee ran out first and the
    ///      leg degraded to an ordinary deferral, which is the safe outcome. So the attacker simply
    ///      picked a size in the band. That defeated the binding rule this whole file is built
    ///      around: a reverting, paused, frozen or gas-bombing token must never freeze delivery of
    ///      the others.
    ///
    ///      `call`'s own output window copies `min(returndatasize(), 32)` bytes and charges nothing
    ///      for the remainder, so the size a hostile token returns is now free to this frame. Only
    ///      the first word is ever inspected, so nothing is lost by refusing to look at the rest.
    ///      DO NOT REVERT THIS TO A `bytes memory` RETURN.
    function _deliver(address asset, address to, uint256 amount, uint256 gasBudget) private returns (bool) {
        bytes memory payload = abi.encodeCall(IERC20.transfer, (to, amount));
        bool success;
        uint256 size;
        uint256 word;
        assembly ("memory-safe") {
            success := call(gasBudget, asset, 0, add(payload, 0x20), mload(payload), 0x00, 0x20)
            size := returndatasize()
            word := mload(0x00)
        }
        if (!success) return false;
        if (size == 0) return asset.code.length != 0;
        // `word` is read only past this point, so a short return that left scratch partly stale is
        // rejected before it can be mistaken for a value.
        if (size < 32) return false;
        return word == 1;
    }
}
