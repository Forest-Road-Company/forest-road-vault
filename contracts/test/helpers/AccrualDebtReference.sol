// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @notice Test-only contractual debt model using bounded, direct integer arithmetic.
/// @dev No production accrual code, segment planner, heap, index or clock is imported.
///      Coupons are visited on their signed dates. Observations within an unchanged
///      epoch subtract its previously observed cumulative entitlement, preserving dust.
library AccrualDebtReference {
    struct Note {
        uint256 original;
        uint256 principal;
        uint256 interest;
        uint256 paid;
        uint256 earned;
        uint256 frozenBasis;
        uint256 ceiling;
        uint256 scale;
        uint256 year;
        uint256 epochCap;
        uint256 epochEarned;
        uint256 epochBasis;
        uint16 rate;
        uint64 epochStart;
        uint64 epochEnd;
        uint64 due;
        uint64 interval;
        uint64 maturity;
        bool pik;
        bool active;
        bool stopped;
    }

    function open(Note memory n, uint64 at) internal pure {
        n.original = n.principal;
        n.frozenBasis = n.principal;
        n.active = true;
        restart(n, at);
    }

    function advance(Note memory n, uint64 at) internal pure {
        if (!n.active) return;
        uint64 through = at < n.maturity ? at : n.maturity;
        if (n.pik) {
            while (n.due != 0 && n.due <= through) {
                uint64 couponAt = n.due;
                observe(n, couponAt);
                n.principal += n.interest;
                n.interest = 0;
                n.frozenBasis = n.principal;
                n.due = uint256(couponAt) + n.interval <= n.maturity ? couponAt + n.interval : 0;
                restart(n, couponAt);
            }
        }
        observe(n, through);
        if (at >= n.maturity) n.active = false;
    }

    function pay(Note memory n, uint256 principalLeg, uint256 interestLeg, uint64 at) internal pure {
        advance(n, at);
        bool capReached = n.epochEarned == n.epochCap / n.scale * n.scale;
        uint256 total = principalLeg + interestLeg;
        if (n.pik) {
            uint256 principalPaid = principalLeg < n.principal ? principalLeg : n.principal;
            n.principal -= principalPaid;
            n.interest -= principalLeg - principalPaid;
        } else {
            n.principal -= principalLeg;
            n.interest -= interestLeg;
        }
        n.paid += total;
        if (n.principal + n.interest == 0) {
            n.active = false;
            n.stopped = true;
        } else if (n.active) {
            if (capReached || (!n.pik && principalLeg != 0) || at >= n.epochEnd) {
                restart(n, at);
            } else {
                n.epochCap += total;
            }
        }
    }

    function amend(Note memory n, uint16 rate, uint256 ceiling, uint256 year, uint64 due, uint64 at) internal pure {
        advance(n, at);
        n.rate = rate;
        n.ceiling = ceiling;
        n.year = year;
        n.due = due;
        n.maturity = due + 3 * n.interval;
        n.active = true;
        restart(n, at);
    }

    function stop(Note memory n, uint64 at) internal pure {
        advance(n, at);
        n.active = false;
        n.stopped = true;
    }

    function restart(Note memory n, uint64 at) internal pure {
        n.epochStart = at;
        n.epochEnd = n.pik && n.due != 0 ? n.due : n.maturity;
        n.epochBasis = n.pik ? n.frozenBasis : n.principal;
        uint256 debt = n.principal + n.interest;
        n.epochCap = n.ceiling > debt ? n.ceiling - debt : 0;
        n.epochEarned = 0;
    }

    function observe(Note memory n, uint64 at) private pure {
        uint256 accrued = n.epochBasis * n.rate * (at - n.epochStart) / (10_000 * n.year);
        if (accrued > n.epochCap) accrued = n.epochCap;
        accrued = accrued / n.scale * n.scale;
        uint256 increment = accrued - n.epochEarned;
        n.earned += increment;
        n.interest += increment;
        n.epochEarned = accrued;
    }
}
