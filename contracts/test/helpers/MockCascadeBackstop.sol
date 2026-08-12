// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {ICascadeBackstop} from "../../src/interfaces/ICascadeBackstop.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @dev Test stand-in for the Phase H sGROVE backstop, honoring the ICascadeBackstop
///      contract EXACTLY (covered <= amount; `covered` USDfr transferred to msg.sender
///      within the call) — same pattern as MockAttestationOracle for the Phase D gate.
///      ADR-0035 mirror: capacity is exactly its live USDfr balance. `eventId` indexes cumulative
///      observability but never creates a ceiling or snapshot.
contract MockCascadeBackstop is ICascadeBackstop {
    IERC20 public immutable USDFR;

    mapping(uint256 eventId => uint256) public eventCovered;

    constructor(IERC20 usdfr) {
        USDFR = usdfr;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ICascadeBackstop).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @dev Mirrors the whole live reserve published by `SGrove.coverageCapacity()`.
    function coverageCapacity() external view returns (uint256) {
        return USDFR.balanceOf(address(this));
    }

    function coverageCapacityAt(uint256 reserve) external pure returns (uint256) {
        return reserve;
    }

    function coverageCapParameters() external pure returns (uint16 proportionalBps, uint256 absoluteCap) {
        return (uint16(Config.BPS), type(uint256).max);
    }

    function coverageReserve() external view returns (uint256) {
        return USDFR.balanceOf(address(this));
    }

    /// @dev Mirrors `SGrove.eventCoverage`: no stored cap, only current shared reach.
    function eventCoverage(uint256 eventId) external view returns (uint256 drawn, uint256 cap) {
        drawn = eventCovered[eventId];
        return (drawn, drawn + USDFR.balanceOf(address(this)));
    }

    function remainingCoverage(uint256) external view returns (uint256 remaining) {
        return USDFR.balanceOf(address(this));
    }

    function coverShortfall(uint256 eventId, uint256 amount) external returns (uint256 covered) {
        uint256 bal = USDFR.balanceOf(address(this));
        covered = amount < bal ? amount : bal;
        if (covered != 0) {
            eventCovered[eventId] += covered;
            // solhint-disable-next-line
            bool ok = USDFR.transfer(msg.sender, covered);
            require(ok, "MockCascadeBackstop: transfer failed");
        }
        emit ShortfallCovered(msg.sender, amount, covered);
    }
}

/// @dev A backstop that VIOLATES the ICascadeBackstop contract, for negative tests of
///      DefaultManager's enforcement: mode 0 reports coverage without delivering USDfr;
///      mode 1 reports covered > requested.
contract MisbehavingBackstop is ICascadeBackstop {
    IERC20 public immutable USDFR;
    uint8 public mode; // 0 = report-without-delivery, 1 = over-report

    constructor(IERC20 usdfr, uint8 mode_) {
        USDFR = usdfr;
        mode = mode_;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ICascadeBackstop).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function coverageCapacity() external view returns (uint256) {
        return USDFR.balanceOf(address(this));
    }

    function coverageCapacityAt(uint256 reserve) external pure returns (uint256) {
        return reserve;
    }

    function coverageCapParameters() external pure returns (uint16 proportionalBps, uint256 absoluteCap) {
        return (uint16(Config.BPS), type(uint256).max);
    }

    function coverageReserve() external view returns (uint256) {
        return USDFR.balanceOf(address(this));
    }

    /// @dev Reports no reachable room. This stand-in exists to violate the DELIVERY half of the
    ///      contract, and `DefaultManager` reverts before it ever reads the ledger.
    function remainingCoverage(uint256) external pure returns (uint256) {
        return 0;
    }

    function coverShortfall(uint256, uint256 amount) external returns (uint256 covered) {
        if (mode == 0) {
            covered = amount; // claims full coverage, transfers nothing
        } else {
            covered = amount + 1; // reports more than was requested
        }
        emit ShortfallCovered(msg.sender, amount, covered);
    }
}
