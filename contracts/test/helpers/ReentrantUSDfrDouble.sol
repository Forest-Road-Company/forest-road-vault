// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @dev The single controller entry point this double calls back into.
interface IReentrantYieldTarget {
    function mintYield(address to, uint256 amount) external;
    function burnLoss(address from, uint256 amount) external;
}

/// @title ReentrantUSDfrDouble
/// @notice A deliberately MISBEHAVING USDfr stand-in whose `mint` re-enters the controller.
///
/// @dev WHY THIS EXISTS (AUDIT FIX R17). An adversarial guard-deletion campaign over every guard
///      in `MintRedeemController` found three that could be removed with the ENTIRE deterministic
///      and invariant suite green — among them `mintYield`'s `nonReentrant`. R16's own stated rule
///      is that "a guard no test can red is not protection; it is a comment that an auditor will
///      read as protection", and the round applied that rule to a guard it declined to write while
///      shipping three it could not falsify. This closes that inconsistency for `mintYield`.
///
///      THE VECTOR IS REAL, NOT DECORATIVE. `mintYield`'s only non-`view` external call is
///      `$.usdfr.mint(to, amount)`. The token is an upgradeable contract behind a timelock, so "a
///      botched upgrade to USDfr" is the same threat model `mint`'s R16-L2 delivery measurement
///      was written for. Without the lock, the inner mint completes first and the OUTER call's
///      before/after solvency readings straddle it, so two mints are authorised against one
///      headroom measurement.
///
///      IT IMPLEMENTS ONLY WHAT THE CONTROLLER CALLS: `mint`, `burn` and `totalSupply`.
contract ReentrantUSDfrDouble {
    uint256 public totalSupply;
    mapping(address account => uint256 balance) public balanceOf;

    address public target;
    address public sink;
    uint256 public amount;
    bool private reentered;

    /// @param target_ The controller to re-enter. Zero disables the callback entirely, which is
    ///        the POSITIVE CONTROL: the same double must be able to mint normally, or a red run
    ///        would prove nothing about the lock.
    function arm(address target_, address sink_, uint256 amount_) external {
        target = target_;
        sink = sink_;
        amount = amount_;
        reentered = false;
    }

    function mint(address to, uint256 value) external {
        if (target != address(0) && !reentered) {
            reentered = true;
            IReentrantYieldTarget(target).mintYield(sink, amount);
        }
        totalSupply += value;
        balanceOf[to] += value;
    }

    address public burnTarget;
    address public burnSource;
    bool private burnReentered;

    /// @dev AUDIT FIX (R17). Arms the BURN leg, which re-enters `burnLoss` — the falsifying case
    ///      for that function's `nonReentrant`, which also survived a full-suite deletion
    ///      mutation. Zero disables the callback (the positive control).
    function armBurn(address target_, address source_) external {
        burnTarget = target_;
        burnSource = source_;
        burnReentered = false;
    }

    function burn(address from, uint256 value) external {
        if (burnTarget != address(0) && !burnReentered) {
            burnReentered = true;
            IReentrantYieldTarget(burnTarget).burnLoss(burnSource, value);
        }
        totalSupply -= value;
        balanceOf[from] -= value;
    }
}
