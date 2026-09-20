// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ReserveManager} from "../ReserveManager.sol";
import {IReserveManager} from "../interfaces/IReserveManager.sol";
import {IReserveLossAbsorber} from "../interfaces/IReserveLossAbsorber.sol";
import {IMintRedeemController} from "../interfaces/IMintRedeemController.sol";
import {ICuratorModule} from "../interfaces/ICuratorModule.sol";
import {ICascadeBackstop} from "../interfaces/ICascadeBackstop.sol";
import {IsUSDfr} from "../interfaces/IsUSDfr.sol";
import {IReserveLossGovernor, IReserveLossTimelock} from "../interfaces/IReserveLossGovernance.sol";
import {ReserveAccrualStorageLib} from "./ReserveAccrualStorageLib.sol";
import {ReserveAccrualLib} from "./ReserveAccrualLib.sol";
/// @notice Native Ethereum module binding with the unchanged reserve storage pointer.
/// @dev The host retains roles and callback exclusion. Continuous configuration freezes all routes.

library ReserveWiringLib {
    /// @notice Binds native counterparties under the host's existing governance authority.
    function bindAbsorber(ReserveManager.ReserveStorage storage $, address absorber) public {
        _requireModuleRebindAllowed($);
        (bool readable, address source) = _readStaticAddress(absorber, IReserveLossAbsorber.reserveLossSource.selector);
        if (!readable || source != address(this)) {
            revert IReserveManager.ReserveManager_InvalidLossAbsorber(absorber);
        }
        address previous = address($.lossAbsorber);
        $.lossAbsorber = IReserveLossAbsorber(absorber);
        emit IReserveManager.LossAbsorberSet(previous, absorber);
    }

    /// @notice Binds native counterparties under the host's existing governance authority.
    function bindController(ReserveManager.ReserveStorage storage $, address controller_) public {
        _requireModuleRebindAllowed($);
        if (controller_ == address(0) || controller_.code.length == 0) {
            revert IReserveManager.ReserveManager_InvalidLossController(controller_);
        }
        address boundReserves;
        address usdfr_;
        try IMintRedeemController(controller_).modules() returns (address usdfr__, address, address reserves_) {
            usdfr_ = usdfr__;
            boundReserves = reserves_;
        } catch {
            revert IReserveManager.ReserveManager_InvalidLossController(controller_);
        }
        if (boundReserves != address(this) || usdfr_ == address(0) || usdfr_.code.length == 0) {
            revert IReserveManager.ReserveManager_InvalidLossController(controller_);
        }
        address previous = address($.lossController);
        $.lossController = IMintRedeemController(controller_);
        $.lossUSDfr = IERC20(usdfr_);
        emit IReserveManager.LossControllerSet(previous, controller_);
    }

    /// @notice Binds native counterparties under the host's existing governance authority.
    function bindModules(
        ReserveManager.ReserveStorage storage $,
        address curator,
        address backstop,
        address vault,
        address governor,
        address timelock
    ) public {
        _requireModuleRebindAllowed($);
        if (address($.lossController) == address(0)) {
            revert IReserveManager.ReserveManager_InvalidLossController(address(0));
        }
        if (curator == address(0) || curator.code.length == 0) {
            revert IReserveManager.ReserveManager_InvalidLossAbsorber(curator);
        }
        if (backstop == address(0) || backstop.code.length == 0) {
            revert IReserveManager.ReserveManager_InvalidLossAbsorber(backstop);
        }
        if (vault == address(0) || vault.code.length == 0) {
            revert IReserveManager.ReserveManager_InvalidLossAbsorber(vault);
        }

        {
            address curatorUSDfr;
            address curatorVault;
            try ICuratorModule(curator).modules() returns (address usdfr_, address, address vault_) {
                curatorUSDfr = usdfr_;
                curatorVault = vault_;
            } catch {
                revert IReserveManager.ReserveManager_InvalidLossAbsorber(curator);
            }
            (bool curatorReserveReadable, address curatorReserve) =
                _readStaticAddress(curator, ICuratorModule.reserveManager.selector);
            if (!curatorReserveReadable) revert IReserveManager.ReserveManager_InvalidLossAbsorber(curator);
            (bool vaultAssetReadable, address vaultAsset) = _readStaticAddress(vault, IERC4626.asset.selector);
            if (!vaultAssetReadable) revert IReserveManager.ReserveManager_InvalidLossAbsorber(vault);
            if (
                curatorUSDfr != address($.lossUSDfr) || curatorVault != vault || curatorReserve != address(this)
                    || vaultAsset != address($.lossUSDfr)
            ) revert IReserveManager.ReserveManager_InvalidLossAbsorber(curator);
        }
        {
            bool supported;
            try IERC165(backstop).supportsInterface(type(ICascadeBackstop).interfaceId) returns (bool ok) {
                supported = ok;
            } catch {
                supported = false;
            }
            if (!supported) revert IReserveManager.ReserveManager_InvalidLossAbsorber(backstop);
        }

        if (!_governanceTimingValid(governor, timelock)) {
            revert IReserveManager.ReserveManager_InvalidGovernanceTiming(governor, timelock);
        }
        $.lossCurator = ICuratorModule(curator);
        $.lossBackstop = ICascadeBackstop(backstop);
        $.lossVault = IsUSDfr(vault);
        $.lossGovernor = governor;
        $.lossTimelock = timelock;
        emit IReserveManager.ReserveLossModulesSet(curator, backstop, vault, governor, timelock);
    }

    function _requireModuleRebindAllowed(ReserveManager.ReserveStorage storage $) private view {
        if (ReserveAccrualStorageLib.state().modules.token != address(0)) {
            revert ReserveAccrualLib.ReserveAccrual_AlreadyConfigured();
        }
        if (
            $.activeReserveLossArmId != 0 || $.activeReserveLossIncidentId != 0 || $.recognizedSupplyReduction != 0
                || $.reserveDeficit != 0 || _liveShortfallUnits($) != 0
        ) revert IReserveManager.ReserveManager_ModuleRebindForbidden();
        IMintRedeemController controller = $.lossController;
        if (address(controller) != address(0) && controller.totalUSDfr() > controller.backingValue()) {
            revert IReserveManager.ReserveManager_ModuleRebindForbidden();
        }
    }

    function _governanceTimingValid(address governor, address timelock) private view returns (bool) {
        (bool ok, uint256 word) = _readStaticWord(governor, IReserveLossGovernor.timelock.selector);
        if (!ok || address(uint160(word)) != timelock) return false;
        (ok, word) = _readStaticWord(governor, IReserveLossGovernor.clock.selector);
        if (!ok || word != block.timestamp) return false;

        (bool modeOk, bytes memory modeData) =
            governor.staticcall(abi.encodeWithSelector(IReserveLossGovernor.CLOCK_MODE.selector));
        if (!modeOk || keccak256(modeData) != keccak256(abi.encode("mode=timestamp"))) return false;

        (ok,) = _readStaticWord(governor, IReserveLossGovernor.votingDelay.selector);
        if (!ok) return false;
        (ok,) = _readStaticWord(governor, IReserveLossGovernor.votingPeriod.selector);
        if (!ok) return false;
        (ok,) = _readStaticWord(timelock, IReserveLossTimelock.getMinDelay.selector);
        return ok;
    }

    function _readStaticWord(address target, bytes4 selector) private view returns (bool ok, uint256 word) {
        if (target == address(0) || target.code.length == 0) return (false, 0);
        bytes memory data;
        (ok, data) = target.staticcall(abi.encodeWithSelector(selector));
        if (!ok || data.length < 32) return (false, 0);
        assembly ("memory-safe") {
            word := mload(add(data, 0x20))
        }
    }

    function _readStaticAddress(address target, bytes4 selector) private view returns (bool ok, address value) {
        uint256 word;
        (ok, word) = _readStaticWord(target, selector);
        if (!ok || word > type(uint160).max) return (false, address(0));
        value = address(uint160(word));
    }

    function _liveShortfallUnits(ReserveManager.ReserveStorage storage $) private view returns (uint256) {
        uint256 live = $.usdcToken.balanceOf(address(this));
        return $.idleUSDCUnits > live ? $.idleUSDCUnits - live : 0;
    }
}
