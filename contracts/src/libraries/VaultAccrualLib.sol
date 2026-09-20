// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IContinuousAccrual, IAccrualToken} from "../interfaces/IContinuousAccrual.sol";
import {IImpairmentSource} from "../interfaces/IImpairmentSource.sol";
import {IsUSDfr} from "../interfaces/IsUSDfr.sol";
import {IMintRedeemController} from "../interfaces/IMintRedeemController.sol";

/// @title VaultAccrualLib
/// @notice Linked vault support for virtual assets and coherent callback prices.
/// @dev Runs in the vault's context. The vault retains all role and reentrancy checks.
library VaultAccrualLib {
    /// @custom:storage-location erc7201:forestroad.storage.VaultAccrual
    struct State {
        IContinuousAccrual reserve;
        IContinuousAccrual.PricingState pricing;
        bool cached;
        bool materializationRequested;
        uint256 grossShares;
    }

    bytes32 private constant VAULT_ACCRUAL_STORAGE_LOCATION =
        0x0a3fe45ec0c706c92dec0dc11a11f80ca1f2f84db6d7d4d4986a86500415b200;

    /// @notice Accrual accounting has already been bound to this vault.
    error VaultAccrual_AlreadyBound();
    /// @notice Module identities must describe this same vault and its underlying token.
    error VaultAccrual_WrongModules();
    /// @notice Price-changing operations cannot overlap a callback snapshot.
    error VaultAccrual_OperationInProgress();
    /// @notice The internal price-field selector is outside its defined range.
    error VaultAccrual_InvalidPriceKind();

    /// @notice This vault has bound its permanent continuous accounting source.
    event VaultAccrualBound(address indexed reserve);

    /// @notice Reserve storage within the vault, independent of its historical namespace.
    function state() internal pure returns (State storage $) {
        assembly {
            $.slot := VAULT_ACCRUAL_STORAGE_LOCATION
        }
    }

    /// @notice Validates and binds one reserve after the token's permanent binding.
    /// @dev The host authenticates governance. Both controller and token must identify the same
    ///      reserve before this irreversible binding; malformed fixed-ABI replies fail by name.
    function bind(address reserve, address token) public {
        State storage s = state();
        if (address(s.reserve) != address(0)) revert VaultAccrual_AlreadyBound();
        if (reserve.code.length == 0) revert VaultAccrual_WrongModules();
        (bool ok, bytes memory data) = reserve.staticcall(abi.encodeCall(IContinuousAccrual.accrualModules, ()));
        if (!ok || data.length != 224) revert VaultAccrual_WrongModules();
        uint256[7] memory words = abi.decode(data, (uint256[7]));
        for (uint256 i; i < 7; ++i) {
            if (words[i] > type(uint160).max) revert VaultAccrual_WrongModules();
        }
        IContinuousAccrual.Modules memory m = abi.decode(data, (IContinuousAccrual.Modules));
        if (m.vault != address(this) || m.token != token || m.controller.code.length == 0) {
            revert VaultAccrual_WrongModules();
        }
        (ok, data) = token.staticcall(abi.encodeCall(IAccrualToken.accrualReserve, ()));
        if (!ok || data.length != 32 || abi.decode(data, (uint256)) != uint256(uint160(reserve))) {
            revert VaultAccrual_WrongModules();
        }
        (ok, data) = m.controller.staticcall(abi.encodeCall(IMintRedeemController.modules, ()));
        if (!ok || data.length != 96) revert VaultAccrual_WrongModules();
        uint256[3] memory controllerWords = abi.decode(data, (uint256[3]));
        if (
            controllerWords[0] != uint256(uint160(token)) || controllerWords[1] > type(uint160).max
                || controllerWords[2] != uint256(uint160(reserve))
        ) revert VaultAccrual_WrongModules();
        s.reserve = IContinuousAccrual(reserve);
        emit VaultAccrualBound(reserve);
    }

    /// @notice Reads a local share-operation or reserve-delivery price snapshot.
    /// @param kind Assets=0, entry assets=1, redemption assets=2, performance assets=3, shares=4.
    function cachedPrice(uint8 kind) public view returns (bool active, uint256 value) {
        State storage s = state();
        IContinuousAccrual.PricingState memory p;
        if (s.cached) {
            p = s.pricing;
            active = true;
        } else if (address(s.reserve) != address(0)) {
            IContinuousAccrual.Delivery memory d = s.reserve.accrualDelivery();
            if (d.active) {
                p = d.pricing;
                active = true;
            }
        }
        if (!active) return (false, 0);
        if (kind == 0) value = p.assets;
        else if (kind == 1) value = p.entryAssets;
        else if (kind == 2) value = p.redemptionAssets;
        else if (kind == 3) value = p.performanceAssets;
        else if (kind == 4) value = p.feeAdjustedShares;
        else revert VaultAccrual_InvalidPriceKind();
    }

    /// @notice All vault-owned physical and virtual assets, including an aliased fee recipient.
    function entryAssets(address token) public view returns (uint256 assets) {
        (bool active, uint256 value) = cachedPrice(1);
        if (active) return value;
        assets = IERC20(token).balanceOf(address(this));
        IContinuousAccrual reserve = state().reserve;
        if (address(reserve) != address(0)) {
            IContinuousAccrual.Snapshot memory s = reserve.accrualSnapshot();
            assets += s.seniorUnissued;
            if (s.feeRecipient == address(this)) assets += s.feeUnissued;
        }
    }

    /// @notice Ordinary, redemption or performance assets on the same coherent price snapshot.
    /// @param kind Ordinary assets=0, redemption assets=2, performance assets=3.
    /// @dev Performance removes the full fee-neutral impairment; redemption removes only the
    ///      senior portion. This preserves the original vault's saturating mark arithmetic.
    function pricedAssets(address token, uint256 unvested, address impairment, uint8 kind)
        public
        view
        returns (uint256 assets)
    {
        if (kind != 0 && kind != 2 && kind != 3) revert VaultAccrual_InvalidPriceKind();
        (bool active, uint256 value) = cachedPrice(kind);
        if (active) return value;
        uint256 held = entryAssets(token);
        assets = held > unvested ? held - unvested : 0;
        if (kind == 0 || impairment == address(0)) return assets;
        uint256 mark = IImpairmentSource(impairment).pendingSeniorImpairment();
        if (kind == 3) {
            uint256 performance = IImpairmentSource(impairment).performanceFeeImpairment();
            if (performance < mark) revert IsUSDfr.SUSDfr_InvalidPerformanceFeeImpairment(mark, performance);
            mark = performance;
        }
        return mark >= assets ? 0 : assets - mark;
    }

    /// @notice Refuses stale or overlapping price-changing operations.
    function requireFresh() public view {
        requireIdle();
        IContinuousAccrual reserve = state().reserve;
        if (address(reserve) != address(0)) reserve.requireAccrualFresh();
    }

    /// @notice Rejects an overlapping callback operation without requiring a current loan clock.
    function requireIdle() public view {
        State storage s = state();
        if (s.cached) revert VaultAccrual_OperationInProgress();
        if (address(s.reserve) != address(0) && s.reserve.accrualDelivery().active) {
            revert VaultAccrual_OperationInProgress();
        }
    }

    /// @notice Whether public capacity views can advertise a current executable price.
    function available() public view returns (bool) {
        State storage s = state();
        if (s.cached) return false;
        if (address(s.reserve) == address(0)) return true;
        try s.reserve.requireAccrualFresh() {
            return !s.reserve.accrualDelivery().active;
        } catch {
            return false;
        }
    }

    /// @notice Gross share supply for the fee-rate view, separate from pending fee-adjusted shares.
    /// @dev Reserve token delivery leaves vault supply unchanged. A local share operation must
    ///      retain its complete pre-flow supply, or its projected post-fee-mint supply.
    function feeSupply(uint256 currentSupply) internal view returns (uint256) {
        State storage s = state();
        return s.cached ? s.grossShares : currentSupply;
    }

    /// @notice Captures all pricing bases in one linked call, preserving the source's two marks.
    /// @dev A bound vault has no unvested yield. The explicit input also keeps the public view
    ///      correct before binding. During a snapshot every price stays at that snapshot, and
    ///      another materialization is refused. A source's full admission gate governs readiness.
    function capture(address token, uint256 unvested, address impairment, uint256 shares, bool allowed)
        public
        view
        returns (IContinuousAccrual.PricingState memory p)
    {
        State storage s = state();
        if (s.cached) {
            p = s.pricing;
        } else if (address(s.reserve) != address(0) && s.reserve.accrualDelivery().active) {
            p = s.reserve.accrualDelivery().pricing;
        } else {
            p.entryAssets = entryAssets(token);
            p.assets = p.entryAssets > unvested ? p.entryAssets - unvested : 0;
            p.redemptionAssets = p.assets;
            p.performanceAssets = p.assets;
            if (impairment != address(0)) {
                uint256 senior = IImpairmentSource(impairment).pendingSeniorImpairment();
                uint256 performance = IImpairmentSource(impairment).performanceFeeImpairment();
                if (performance < senior) revert IsUSDfr.SUSDfr_InvalidPerformanceFeeImpairment(senior, performance);
                p.redemptionAssets = senior >= p.assets ? 0 : p.assets - senior;
                p.performanceAssets = performance >= p.assets ? 0 : p.assets - performance;
            }
            p.feeAdjustedShares = shares;
        }
        p.materializationAllowed = allowed && address(s.reserve) != address(0) && available();
    }

    /// @notice Freezes a complete price ratio around a share/asset accounting operation.
    function begin(IContinuousAccrual.PricingState memory pricing, uint256 grossShares) public {
        State storage s = state();
        if (s.cached) revert VaultAccrual_OperationInProgress();
        s.pricing = pricing;
        s.grossShares = grossShares;
        s.cached = true;
    }

    /// @notice Ends the host's local callback-price snapshot after all balance effects.
    function end() public {
        state().cached = false;
    }

    /// @notice Requests delivery from an already guarded withdrawal, without a vault write callback.
    function materialize() public {
        State storage s = state();
        IContinuousAccrual reserve = s.reserve;
        if (address(reserve) == address(0)) return;
        IContinuousAccrual.Snapshot memory book = reserve.accrualSnapshot();
        uint8 legs = book.feeRecipient == address(this) ? 3 : 1;
        uint256 owned = book.seniorUnissued + (legs == 3 ? book.feeUnissued : 0);
        if (owned == 0) return;
        s.materializationRequested = true;
        reserve.materializeAccrued(legs);
        s.materializationRequested = false;
    }

    /// @notice Validates both historical impairment-source selectors before governed wiring.
    /// @dev The bounded first-word probe and ordering check are unchanged from SUSDfr.
    function validateImpairmentSource(address source) public view {
        if (source == address(0)) return;
        (bool readable,) = _probeImpairmentSource(source, gasleft());
        if (!readable) revert IsUSDfr.SUSDfr_InvalidImpairmentSource(source);
    }

    /// @notice Proves a failed impairment read before the host may clear its current source.
    /// @dev Each selector receives 1,000,000 gas, including cold reads through the native
    ///      accrual and assessment dependency closure. Check inside the linked frame so
    ///      delegation cannot consume the allowance. The extra 150,000 covers call overhead,
    ///      EIP-150 forwarding and return to the host even if both probes exhaust their caps.
    ///      Future changes to an admitted source must retain the fresh-read regression margin.
    function impairmentRecoveryFailure(address source) public view returns (bytes32 failureHash) {
        if (source == address(0)) revert IsUSDfr.SUSDfr_NoImpairmentSource();
        uint256 availableGas = gasleft();
        uint256 requiredGas = 2_150_000;
        if (availableGas < requiredGas) {
            revert IsUSDfr.SUSDfr_InsufficientImpairmentRecoveryGas(availableGas, requiredGas);
        }
        bool readable;
        (readable, failureHash) = _probeImpairmentSource(source, 1_000_000);
        if (readable) revert IsUSDfr.SUSDfr_ImpairmentSourceStillReadable(source);
    }

    /// @dev Bounded ABI-shape probe; copy only one word to contain return-data bombs.
    function _probeImpairmentSource(address source, uint256 gasLimit)
        private
        view
        returns (bool readable, bytes32 failureHash)
    {
        if (source.code.length == 0) return (false, keccak256(abi.encode(uint256(0), bytes32(0))));
        bytes4 pendingSelector = IImpairmentSource.pendingSeniorImpairment.selector;
        uint256 pendingImpairment;
        (readable, failureHash, pendingImpairment) = _probeUint256(source, pendingSelector, gasLimit);
        if (!readable) return (false, keccak256(abi.encode(pendingSelector, failureHash)));
        bytes4 performanceSelector = IImpairmentSource.performanceFeeImpairment.selector;
        uint256 performanceImpairment;
        (readable, failureHash, performanceImpairment) = _probeUint256(source, performanceSelector, gasLimit);
        if (!readable) return (false, keccak256(abi.encode(performanceSelector, failureHash)));
        if (performanceImpairment < pendingImpairment) {
            return (
                false,
                keccak256(
                    abi.encode(
                        IsUSDfr.SUSDfr_InvalidPerformanceFeeImpairment.selector,
                        pendingImpairment,
                        performanceImpairment
                    )
                )
            );
        }
    }

    function _probeUint256(address source, bytes4 selector, uint256 gasLimit)
        private
        view
        returns (bool readable, bytes32 failureHash, uint256 value)
    {
        bytes memory callData = abi.encodeWithSelector(selector);
        assembly ("memory-safe") {
            mstore(0x00, 0)
            let success := staticcall(gasLimit, source, add(callData, 0x20), mload(callData), 0x00, 0x20)
            let returnSize := returndatasize()
            readable := and(success, iszero(lt(returnSize, 0x20)))
            value := mload(0x00)
            if iszero(readable) {
                mstore(0x00, returnSize)
                mstore(0x20, value)
                failureHash := keccak256(0x00, 0x40)
            }
        }
    }
}
