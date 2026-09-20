// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ReserveManager} from "../ReserveManager.sol";
import {ReserveStorageLib} from "./ReserveStorageLib.sol";
import {IAccrualLifecycle} from "../interfaces/IAccrualLifecycle.sol";
import {AccrualLoans} from "./AccrualLoans.sol";
import {ReserveAccrualStorageLib} from "./ReserveAccrualStorageLib.sol";
/// @notice Typed constant-time debt views for Ethereum's reserve-owned accrual book.

library ReserveAccrualViewsLib {
    using AccrualLoans for AccrualLoans.State;

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
    /// @notice Recorded plus earned unposted native face, without enumerating facilities.

    function deployed(ReserveManager.ReserveStorage storage native, uint256 id, bool total)
        public
        view
        returns (uint256)
    {
        return total
            ? native.totalDeployedPrincipal + ReserveAccrualStorageLib.unposted()
            : native.deployed[id] + ReserveAccrualStorageLib.facilityUnposted(id);
    }

    /// @notice Unposted earned face for one facility, through the coherent portfolio frontier.
    function unpostedLoan(uint256 id) public view returns (uint256) {
        return ReserveAccrualStorageLib.facilityUnposted(id);
    }

    /// @notice Native backing with a coherent delivery snapshot. Only recognition observes custody.
    function backing(ReserveManager.ReserveStorage storage native, bool recognized)
        public
        view
        returns (uint256 value)
    {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        if (s.delivery.active) return recognized ? s.delivery.recognizedBacking : s.delivery.backing;
        value = ReserveStorageLib.backingValue(native);
        if (recognized) {
            uint256 live = native.usdcToken.balanceOf(address(this));
            uint256 shortfall =
                native.idleUSDCUnits > live ? ReserveStorageLib.normalize(native.idleUSDCUnits - live) : 0;
            value = value > shortfall ? value - shortfall : 0;
        }
    }
}
