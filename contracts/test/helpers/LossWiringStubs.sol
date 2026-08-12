// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IReserveLossAbsorber} from "../../src/interfaces/IReserveLossAbsorber.sol";

/// @title LossWiringStubs — minimal counterparties for the ReserveManager loss-wiring setters
/// @notice AUDIT FIX (F3-FREEZE-01). `ReserveManager.custodyLossUnabsorbed()` fails CLOSED when
///         EITHER half of the absorption machinery (`lossController`, `lossAbsorber`) is unset,
///         because `_allocateReserveLoss` reverts in either case and "cannot tell" must never read
///         as "clear".
///
///         Testing those two legs SEPARATELY is what these stubs exist for, and separability is
///         the whole point: with both legs unset, either one alone still returns `true`, so a
///         mutation that deletes one leg stays green. To attribute a red to the correct leg a test
///         must wire the OTHER leg on a reserve manager that is not the fixture's own — and both
///         setters validate their counterparty against `address(this)`, so the real controller and
///         the real DefaultManager (bound to the real ReserveManager) cannot be reused.
///
/// @dev These are SOURCES OF WIRING, not behavioural mocks. Neither is ever expected to absorb a
///      loss or price a redemption; they exist so `setLossController` / `setLossAbsorber` accept
///      them on a spare ReserveManager. Do not grow them into a second implementation of the real
///      modules — a mock whose behaviour drifts from production is a false green by construction
///      (see the PM-R-11 note on `MockCascadeBackstop`).

/// @notice Answers `modules()` with a caller-chosen reserve address, which is the only thing
///         `ReserveManager.setLossController` validates, plus a fixed supply/backing pair.
contract StubLossController {
    address internal boundReserves;
    address internal boundUSDfr;
    /// @notice Reported USDfr supply. Held EQUAL to `backingValue` by default so the freeze
    ///         predicate's limb 4 is provably OFF and cannot mask another limb's deletion.
    uint256 public totalUSDfr;
    /// @notice Reported backing value.
    uint256 public backingValue;

    constructor(address reserves_, address usdfr_) {
        boundReserves = reserves_;
        boundUSDfr = usdfr_;
        totalUSDfr = 1_000e18;
        backingValue = 1_000e18;
    }

    /// @notice Lets a test move the pair, e.g. to make limb 4 fire deliberately.
    function setSupplyAndBacking(uint256 supply_, uint256 backing_) external {
        totalUSDfr = supply_;
        backingValue = backing_;
    }

    function modules() external view returns (address usdfr, address compliance, address reserves) {
        return (boundUSDfr, address(0), boundReserves);
    }

    function recognizedBackingValue() external view returns (uint256) {
        return backingValue;
    }
}

/// @notice Answers `reserveLossSource()` with a caller-chosen reserve address, which is the only
///         thing `ReserveManager.setLossAbsorber` validates.
contract StubLossAbsorber is IReserveLossAbsorber {
    address internal boundReserves;

    constructor(address reserves_) {
        boundReserves = reserves_;
    }

    function reserveLossSource() external view returns (address) {
        return boundReserves;
    }

    /// @dev Never reached by any test that uses this stub: it is wired so the OTHER leg of the
    ///      fail-closed branch can be isolated, never so a loss can be allocated through it.
    /// @dev ADR-0034 Y-bis. This double models NO junior layers, so it correctly draws nothing —
    ///      which is exactly the state in which `_drawJuniorForExit` must degrade to today's gross
    ///      price rather than revert. Present because the controller's draw is FAIL-CLOSED on a
    ///      source that cannot answer at all (see `_drawJuniorForExit`'s NatSpec).
    function drawForSeniorExit(uint256) external pure returns (uint256) {
        return 0;
    }

    function absorbReserveLoss(uint256, uint256) external pure returns (ReserveLossAllocation memory) {
        revert("StubLossAbsorber: not an absorber");
    }

    /// @dev AUDIT FIX (SWEEP-2 CSG-F1). `CuratorModule._requiredFirstLoss` now floors the
    ///      subordination requirement at the layer-1 credit the conservative senior NAV is
    ///      extending, which it reads off the WIRED LOSS ABSORBER — this contract, in the fixtures
    ///      that use it. A stub that cannot answer is treated as UNREADABLE and locks the pool
    ///      (fail-closed), which would silently starve every custody-freeze probe of headroom and
    ///      turn a freeze test into a headroom test. These two getters exist so this stub keeps
    ///      standing in for `DefaultManager` on the axis the module now reads, per this file's own
    ///      rule that "a mock whose behaviour drifts from production is a false green by
    ///      construction". They report ZERO because this stub models no credit book at all; a test
    ///      that needs a non-zero credit must use the real `DefaultManager`.
    function declaredDefaultedPrincipal(uint256) external pure returns (uint256) {
        return 0;
    }

    function pastDuePrincipal(uint256) external pure returns (uint256) {
        return 0;
    }
}
