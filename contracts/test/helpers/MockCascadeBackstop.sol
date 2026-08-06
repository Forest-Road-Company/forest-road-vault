// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {ICascadeBackstop} from "../../src/interfaces/ICascadeBackstop.sol";

/// @dev Test stand-in for the Phase H sGROVE backstop, honoring the ICascadeBackstop
///      contract EXACTLY (covered <= amount; `covered` USDfr transferred to msg.sender
///      within the call) — same pattern as MockAttestationOracle for the Phase D gate.
///      Coverage capacity = its USDfr balance, optionally limited by `coverageCap`.
///
///      AUDIT FIX (PM-R-11). This mock's `coverShortfall` used to IGNORE `eventId` and apply
///      `coverageCap` per CALL. That silently diverged from the real `SGrove` once PM-R-07 made
///      the cap cumulative PER EVENT and snapshotted at the event's first draw — so every
///      mock-based suite (including the whole ADR-0022 conservative-NAV suite) was testing
///      semantics the production contract no longer had, and could not have caught the NAV
///      under-marking bug PM-R-11 fixes. A mock whose observable behaviour differs from the
///      contract it stands in for is a false green by construction, so it now mirrors the real
///      per-event rule: the cap is snapshotted at an event's first draw and consumed cumulatively.
contract MockCascadeBackstop is ICascadeBackstop {
    IERC20 public immutable USDFR;
    uint256 public coverageCap = type(uint256).max;

    mapping(uint256 eventId => uint256) public eventCovered;
    mapping(uint256 eventId => uint256) public eventCapSnapshot;

    constructor(IERC20 usdfr) {
        USDFR = usdfr;
    }

    function setCoverageCap(uint256 cap) external {
        coverageCap = cap;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ICascadeBackstop).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @dev What a FRESH event could draw right now — mirrors `SGrove.coverageCapacity()`.
    function coverageCapacity() external view returns (uint256) {
        uint256 bal = USDFR.balanceOf(address(this));
        return bal < coverageCap ? bal : coverageCap;
    }

    /// @dev Mirrors `SGrove.eventCoverage`.
    function eventCoverage(uint256 eventId) external view returns (uint256 drawn, uint256 cap) {
        return (eventCovered[eventId], eventCapSnapshot[eventId]);
    }

    function coverShortfall(uint256 eventId, uint256 amount) external returns (uint256 covered) {
        uint256 bal = USDFR.balanceOf(address(this));
        // PM-R-07 semantics: snapshot the cap at the event's FIRST draw, then consume it
        // cumulatively. A repeat draw against an exhausted event delivers exactly zero.
        uint256 cap = eventCapSnapshot[eventId];
        if (cap == 0) {
            cap = bal < coverageCap ? bal : coverageCap;
            if (cap != 0) eventCapSnapshot[eventId] = cap;
        }
        uint256 already = eventCovered[eventId];
        uint256 room = cap > already ? cap - already : 0;
        covered = amount < room ? amount : room;
        if (covered > bal) covered = bal; // never over-deliver
        if (covered != 0) {
            eventCovered[eventId] = already + covered;
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

    function coverShortfall(uint256, uint256 amount) external returns (uint256 covered) {
        if (mode == 0) {
            covered = amount; // claims full coverage, transfers nothing
        } else {
            covered = amount + 1; // reports more than was requested
        }
        emit ShortfallCovered(msg.sender, amount, covered);
    }
}
