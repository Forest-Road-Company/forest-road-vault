// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IContinuousAccrual, IAccrualToken} from "../interfaces/IContinuousAccrual.sol";
import {IMintRedeemController} from "../interfaces/IMintRedeemController.sol";
import {IReserveManager} from "../interfaces/IReserveManager.sol";

/// @title BridgeAccrualLib
/// @notice Fixed-ABI validation of the bridge's permanent continuous-accounting source.
/// @dev Linked calls execute in the bridge's context. The host authenticates governance and
///      writes its append-only reserve slot only after every read-only identity check succeeds.
library BridgeAccrualLib {
    /// @notice A proposed source does not identify the bridge's existing native module routes.
    error BridgeAccrual_InvalidReserve(address reserve);

    /// @notice Validates the token-first binding and both controller and native waterfall routes.
    /// @param reserve The candidate accounting reserve proxy.
    /// @param registry The bridge's already configured collateral registry.
    /// @param oracle The bridge's already configured attestation oracle.
    function validate(address reserve, address registry, address oracle) public view {
        if (reserve.code.length == 0) revert BridgeAccrual_InvalidReserve(reserve);
        bytes memory data = _reply(reserve, abi.encodeCall(IContinuousAccrual.accrualModules, ()), 224, reserve);
        uint256[7] memory words = abi.decode(data, (uint256[7]));
        for (uint256 i; i < 7; ++i) {
            if (words[i] > type(uint160).max || address(uint160(words[i])).code.length == 0) {
                revert BridgeAccrual_InvalidReserve(reserve);
            }
        }
        IContinuousAccrual.Modules memory m = abi.decode(data, (IContinuousAccrual.Modules));
        if (m.bridge != address(this) || m.registry != registry) revert BridgeAccrual_InvalidReserve(reserve);
        data = _reply(m.token, abi.encodeCall(IAccrualToken.accrualReserve, ()), 32, reserve);
        if (abi.decode(data, (uint256)) != uint256(uint160(reserve))) revert BridgeAccrual_InvalidReserve(reserve);
        data = _reply(m.controller, abi.encodeCall(IMintRedeemController.modules, ()), 96, reserve);
        uint256[3] memory controller = abi.decode(data, (uint256[3]));
        if (
            controller[0] != uint256(uint160(m.token)) || controller[1] > type(uint160).max
                || controller[2] != uint256(uint160(reserve))
        ) revert BridgeAccrual_InvalidReserve(reserve);
        data = _reply(m.waterfall, abi.encodeWithSignature("modules()"), 192, reserve);
        uint256[6] memory waterfall = abi.decode(data, (uint256[6]));
        if (
            waterfall[0] != uint256(uint160(address(this))) || waterfall[1] != uint256(uint160(registry))
                || waterfall[2] != uint256(uint160(reserve)) || waterfall[3] != uint256(uint160(m.controller))
                || waterfall[4] != uint256(uint160(m.vault)) || waterfall[5] != uint256(uint160(oracle))
        ) revert BridgeAccrual_InvalidReserve(reserve);
        data = _reply(reserve, abi.encodeCall(IReserveManager.lossController, ()), 32, reserve);
        if (abi.decode(data, (uint256)) != uint256(uint160(m.controller))) revert BridgeAccrual_InvalidReserve(reserve);
    }

    /// @dev Reject failed or malformed probes before decoding; no unchecked external result remains.
    function _reply(address target, bytes memory request, uint256 length, address reserve)
        private
        view
        returns (bytes memory data)
    {
        bool ok;
        (ok, data) = target.staticcall(request);
        if (!ok || data.length != length) revert BridgeAccrual_InvalidReserve(reserve);
    }
}
