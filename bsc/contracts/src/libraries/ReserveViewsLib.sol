// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IReserveManager} from "../interfaces/IReserveManager.sol";
import {IMintRedeemController} from "../interfaces/IMintRedeemController.sol";
import {ReserveStorageLib} from "./ReserveStorageLib.sol";
import {ReserveAccrualStorageLib} from "./ReserveAccrualStorageLib.sol";
import {LossEventIds} from "./LossEventIds.sol";
import {IAccrualLifecycle} from "../interfaces/IAccrualLifecycle.sol";
import {AccrualLoans} from "./AccrualLoans.sol";

/// @title ReserveViewsLib
/// @notice Existing reserve disclosure and exit-latch views, extracted to preserve EIP-170 room.
/// @dev Public library calls retain the reserve's storage context. The asset and price views remain
///      separate. Aggregate backing does not call this library or gain an external token read.
library ReserveViewsLib {
    /// @notice Only an unratified arm adds the per-asset direct-exit restriction.
    function adjudicationPending(address asset) public view returns (bool) {
        return ReserveStorageLib.adjudicationPending(ReserveStorageLib.layout(), asset);
    }

    using ReserveStorageLib for ReserveStorageLib.ReserveStorage;
    using AccrualLoans for AccrualLoans.State;

    /// @notice Compiler-encoded existing deposit record, pending units and aggregate claim ledgers.
    function recordData(address holder, address asset) public view returns (bytes memory) {
        ReserveStorageLib.ReserveStorage storage s = ReserveStorageLib.layout();
        return abi.encode(
            s.depositRecord[holder][asset], s.pendingClaimUnits[holder][asset], s.claimedUnits[asset], s.totalClaimValue
        );
    }

    /// @notice Existing payable idle budget after outstanding basket claims, floored at zero.
    function idleReserve() public view returns (uint256) {
        ReserveStorageLib.ReserveStorage storage s = ReserveStorageLib.layout();
        uint256 payable_ = s.totalPayableIdleValue;
        uint256 owed = s.totalClaimValue;
        return payable_ > owed ? payable_ - owed : 0;
    }

    /// @notice Current canonical contractual debt; unknown or disabled entries return known=false.
    function debt(uint256 id) public view returns (bytes memory) {
        IAccrualLifecycle.Debt memory d;
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        if (!s.enabled || !s.identities[id].known) return abi.encode(d);
        AccrualLoans.Loan storage loan = s.loans.loans[id];
        (d.principal, d.interest, d.accruedThrough) = s.loans.loanFace(id, ReserveAccrualStorageLib.now64());
        d.balanceCeiling = loan.balanceCeiling;
        d.nextCapitalization = loan.nextCapitalization;
        d.maturity = loan.legalMaturity;
        d.pik = loan.pik;
        d.active = loan.active;
        d.known = true;
        return abi.encode(d);
    }

    /// @notice Compiler-encoded immutable-order list of admitted reserve assets.
    function assetsData() public view returns (bytes memory) {
        return abi.encode(ReserveStorageLib.layout().assetList);
    }

    /// @notice Existing per-asset payable value, without a token or price read.
    function payableValue(address asset) public view returns (uint256) {
        return ReserveStorageLib.payableValue(ReserveStorageLib.layout().assets[asset]);
    }

    /// @notice Existing latched custody-shortfall value for one asset, using its storage scale.
    function custodyShortfall(address asset) public view returns (uint256) {
        ReserveStorageLib.ReserveAsset storage r = ReserveStorageLib.layout().assets[asset];
        return r.custodyShortfallUnits * r.scale;
    }

    /// @notice Exact native normalization or denormalization using the admitted storage scale.
    function convertUnits(address asset, uint256 value, bool toNative) public view returns (uint256) {
        uint256 scale = ReserveStorageLib.layout().requireListed(asset).scale;
        if (!toNative) return value * scale;
        uint256 amount = value / scale;
        if (amount * scale != value) revert IReserveManager.ReserveManager_ValueNotExact(asset, value);
        return amount;
    }

    /// @notice Compiler-encoded existing custody-arm identity and state for one reserve asset.
    function armData(address asset) public view returns (bytes memory) {
        ReserveStorageLib.ReserveStorage storage s = ReserveStorageLib.layout();
        uint256 armId = s.activeArmOf[asset];
        ReserveStorageLib.LossArm storage arm = s.arms[armId];
        uint256 incidentId = armId == 0 ? 0 : LossEventIds.custodyEventId(armId);
        return abi.encode(armId, incidentId, arm.evidenceHash, arm.state, s.guardianReserveLossArmsEnabled);
    }
    /// @notice Effective native plus unposted receivable, for one facility or the complete book.

    function deployed(uint256 id, bool total) public view returns (uint256) {
        ReserveStorageLib.ReserveStorage storage native = ReserveStorageLib.layout();
        return total
            ? native.totalDeployedPrincipal + ReserveAccrualStorageLib.unposted()
            : native.deployed[id] + ReserveAccrualStorageLib.facilityUnposted(id);
    }

    /// @notice One facility's unposted receivable through the portfolio's coherent frontier.
    function unpostedLoan(uint256 id) public view returns (uint256) {
        return ReserveAccrualStorageLib.facilityUnposted(id);
    }
    /// @notice Aggregate backing from this reserve's own storage, with its coherent delivery cache.
    /// @dev No token or oracle read occurs here, including the recognition-aware shortfall deduction.

    function backing(bool recognized) public view returns (uint256 value) {
        ReserveAccrualStorageLib.State storage accrual = ReserveAccrualStorageLib.state();
        if (accrual.delivery.active) {
            return recognized ? accrual.delivery.recognizedBacking : accrual.delivery.backing;
        }
        ReserveStorageLib.ReserveStorage storage native = ReserveStorageLib.layout();
        value = ReserveStorageLib.backingValue(native);
        if (recognized) {
            uint256 shortfall = native.totalCustodyShortfallValue;
            value = value > shortfall ? value - shortfall : 0;
        }
    }
    /// @notice Existing live-token monitoring surface; never consumed by aggregate backing.

    function observeIdleUnits(address asset) public view returns (bytes memory) {
        ReserveStorageLib.ReserveAsset storage r = ReserveStorageLib.layout().assets[asset];
        uint256 recorded = r.units;
        uint256 deferred = r.deferredUnits;
        uint256 latched = r.custodyShortfallUnits;
        uint256 live = IERC20(asset).balanceOf(address(this));
        uint256 owed = ReserveStorageLib.custodiedUnits(r);
        uint256 liveShortfall = owed > live ? owed - live : 0;
        return abi.encode(recorded, live, deferred, latched, liveShortfall);
    }

    /// @notice Existing live-token monitoring surface; never consumed by aggregate backing.
    function unrecordedUnits(address asset) public view returns (uint256) {
        ReserveStorageLib.ReserveAsset storage r = ReserveStorageLib.layout().assets[asset];
        uint256 owed = ReserveStorageLib.custodiedUnits(r);
        uint256 live = IERC20(asset).balanceOf(address(this));
        return live > owed ? live - owed : 0;
    }

    /// @notice One asset's unchanged storage-ledger disclosure.
    function assetRecord(address asset) public view returns (bytes memory) {
        return abi.encode(_asset(ReserveStorageLib.layout(), asset));
    }

    /// @notice The bounded, append-only reserve asset registry with unchanged field meanings.
    function assetRecords() public view returns (bytes memory) {
        ReserveStorageLib.ReserveStorage storage s = ReserveStorageLib.layout();
        uint256 n = s.assetList.length;
        IReserveManager.ReserveAssetView[] memory records = new IReserveManager.ReserveAssetView[](n);
        for (uint256 i; i < n; ++i) {
            records[i] = _asset(s, s.assetList[i]);
        }
        return abi.encode(records);
    }

    /// @notice Existing storage-only mint price quote and reason for unavailable mint admission.
    function mintPriceQuote(address asset) public view returns (bytes memory) {
        ReserveStorageLib.ReserveStorage storage s = ReserveStorageLib.layout();
        (uint256 effective, uint8 reason) = ReserveStorageLib.effectiveMintPrice(s, asset);
        bool live = reason == 0;
        ReserveStorageLib.AssetPrice storage p = s.assetPrices[asset];
        return abi.encode(effective, live, reason, p.price, p.asOf, p.floor);
    }

    /// @notice Existing fail-closed loss-window predicate for both senior and curator exits.
    function exitsLocked() public view returns (bool) {
        if (ReserveAccrualStorageLib.state().busy) return true;
        ReserveStorageLib.ReserveStorage storage s = ReserveStorageLib.layout();
        if (
            s.openArmCount != 0 || s.recognizedSupplyReduction != 0 || s.reserveDeficit != 0
                || s.totalCustodyShortfallValue != 0
        ) return true;
        IMintRedeemController controller = s.lossController;
        if (address(controller) == address(0) || address(s.lossAbsorber) == address(0)) return true;
        uint256 supply;
        uint256 backingValue;
        try controller.totalUSDfr() returns (uint256 value) {
            supply = value;
        } catch {
            return true;
        }
        try controller.backingValue() returns (uint256 value) {
            backingValue = value;
        } catch {
            return true;
        }
        return supply > backingValue;
    }

    /// @notice Existing outstanding custody-loss condition, including the live economic deficit.
    function custodyLossUnabsorbed() public view returns (bool) {
        ReserveStorageLib.ReserveStorage storage s = ReserveStorageLib.layout();
        if (s.openArmCount != 0 || s.totalCustodyShortfallValue != 0) return true;
        if (s.reserveDeficit != 0 || s.recognizedSupplyReduction != 0 || s.totalPrincipalImpairment != 0) return true;
        IMintRedeemController controller = s.lossController;
        if (address(controller) == address(0) || address(s.lossAbsorber) == address(0)) return true;
        return controller.totalUSDfr() > controller.backingValue();
    }

    function _asset(ReserveStorageLib.ReserveStorage storage s, address asset)
        private
        view
        returns (IReserveManager.ReserveAssetView memory v)
    {
        ReserveStorageLib.ReserveAsset storage r = s.assets[asset];
        v.asset = asset;
        v.decimals = r.decimals;
        v.listed = r.listed;
        v.frozenMint = r.frozenMint;
        v.frozenRedeem = r.frozenRedeem;
        v.mintFeeBps = r.mintFeeBps;
        v.listedAt = r.listedAt;
        v.scale = r.scale;
        v.units = r.units;
        v.cap = r.cap;
        v.recognizedCapLoss = r.recognizedCapLoss;
        v.custodyShortfallUnits = r.custodyShortfallUnits;
        v.deferredUnits = r.deferredUnits;
        v.payableValue = ReserveStorageLib.payableValue(r);
        v.backingContribution = ReserveStorageLib.contribution(r);
    }
}
