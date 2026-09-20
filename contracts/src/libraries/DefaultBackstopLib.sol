// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {DefaultManager} from "../DefaultManager.sol";
import {ICascadeBackstop} from "../interfaces/ICascadeBackstop.sol";
import {IDefaultManager} from "../interfaces/IDefaultManager.sol";
import {IsUSDfr} from "../interfaces/IsUSDfr.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {DefaultLossLib} from "./DefaultLossLib.sol";
import {DefaultAccrualLib} from "./DefaultAccrualLib.sol";

/// @notice Ethereum backstop validation and fee-neutral wiring, executed in the manager context.
/// @dev Host retains governance, source-idle admission and reentrancy guards. Native storage is
///      supplied by its sole original getter; this library has no independent storage authority.
library DefaultBackstopLib {
    /// @dev Fixed bound for all backstop capability probes; native loss delivery uses the same bound.
    uint256 internal constant BACKSTOP_PROBE_GAS = 200_000;

    /// @notice Installs a backstop before binding; after binding only the existing route is accepted.
    function set(DefaultManager.DefaultStorage storage $, address backstop_) public {
        if (address($.accrualReserve) != address(0) && backstop_ != address($.backstop)) {
            revert DefaultAccrualLib.DefaultAccrual_WrongModules();
        }
        _validateBackstop(backstop_);
        address oldBackstop = address($.backstop);
        if (oldBackstop != backstop_) {
            // Bill elapsed management fees against the outgoing NAV whenever it remains
            // readable. Before continuous binding, a broken route can be replaced first to
            // retain the existing repair path. The guard above prevents any bound-route change.
            bool oldReadable = oldBackstop == address(0) || _isBackstopReadable(oldBackstop);
            if (oldReadable) IsUSDfr($.vault).beginFeeNeutralMarkedNavChange();
            $.backstop = ICascadeBackstop(backstop_);
            DefaultLossLib.advanceImpairmentRevision($);
            if (!oldReadable) IsUSDfr($.vault).beginFeeNeutralMarkedNavChange();
            IsUSDfr($.vault).endFeeNeutralMarkedNavChange();
        }
        emit IDefaultManager.BackstopSet(backstop_);
    }

    function _validateBackstop(address backstop_) private view {
        if (backstop_ == address(0)) return; // removal is permitted only before continuous binding
        if (!_declaresBackstopInterface(backstop_)) revert IDefaultManager.DefaultManager_InvalidBackstop(backstop_);
        if (!_isBackstopReadable(backstop_)) revert IDefaultManager.DefaultManager_InvalidBackstop(backstop_);
    }

    function _declaresBackstopInterface(address backstop_) private view returns (bool declares) {
        bytes memory interfaceCall = abi.encodeCall(IERC165.supportsInterface, (type(ICascadeBackstop).interfaceId));
        assembly ("memory-safe") {
            mstore(0x00, 0)
            let success :=
                staticcall(BACKSTOP_PROBE_GAS, backstop_, add(interfaceCall, 0x20), mload(interfaceCall), 0x00, 0x20)
            declares := and(and(success, iszero(lt(returndatasize(), 0x20))), eq(mload(0x00), 1))
        }
    }

    function _isBackstopReadable(address backstop_) private view returns (bool readable) {
        return _probeBackstopWords(backstop_, ICascadeBackstop.coverageCapacity.selector, false, 1)
            && _probeBackstopWords(backstop_, ICascadeBackstop.coverageCapacityAt.selector, true, 1)
            && _probeBackstopWords(backstop_, ICascadeBackstop.coverageCapParameters.selector, false, 2)
            && _probeBackstopWords(backstop_, ICascadeBackstop.coverageReserve.selector, false, 1)
            && _probeBackstopWords(backstop_, ICascadeBackstop.remainingCoverage.selector, true, 1);
    }

    function _probeBackstopWords(address target, bytes4 selector, bool withArgument, uint256 returnWords)
        private
        view
        returns (bool ok)
    {
        assembly ("memory-safe") {
            // `bytes4` values are ABI-left-aligned in a stack word.
            mstore(0x00, selector)
            if withArgument { mstore(0x04, 0) }
            let size := add(4, mul(32, withArgument))
            let success := staticcall(BACKSTOP_PROBE_GAS, target, 0x00, size, 0x00, 0x20)
            ok := and(success, iszero(lt(returndatasize(), mul(returnWords, 0x20))))
        }
    }
}
