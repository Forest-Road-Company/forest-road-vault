// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ControllerReserveDouble
/// @notice A deliberately MISBEHAVING ReserveManager stand-in, used to falsify the two guards in
///         `MintRedeemController.mint`/`redeem` that the SHIPPED ReserveManager cannot violate.
///
/// @dev WHY THIS EXISTS, stated plainly for the auditor. Round R16 adopted the rule that a guard
///      no test can turn RED by deleting it is a defect, not protection — finding M6 was exactly
///      that: `Controller_LossBurnDeficitMismatch` could be deleted in full with the entire
///      deterministic and invariant suite green. Two of the controller's guards are in that
///      shape when measured only against the real `ReserveManager`:
///        - `Controller_DepositNotCustodied` (finding L2) cannot fire, because the real reserve's
///          own `ReserveManager_UnexpectedUSDCReceipt` check already refuses a short delivery;
///        - `_assertDeficitNotWorsened` on `mint`/`redeem` cannot fire, because the real reserve
///          moves its ledger by exactly the value the controller mints or burns.
///      That is precisely the L2 finding restated: `mint` derived BOTH sides of its safety check
///      from the same trusted module. The guards defend against a ReserveManager that reports one
///      thing and does another — a botched upgrade, a fee-on-transfer or blocklisting USDC, a
///      skimming implementation — so the falsifying case must come from a different reserve. It
///      is a TEST DOUBLE, not a hypothetical: the mutation runs recorded for this round delete
///      each guard and show the corresponding test go red against it.
///
///      IT IMPLEMENTS ONLY THE SIX FUNCTIONS THE CONTROLLER CALLS. `MintRedeemController` holds
///      its reserve as an `IReserveManager` and calls `usdc()`, `idleCustodyShortfall()`,
///      `recognizedBackingValue()`, `totalBackingValue()`, `depositUSDC` and `releaseUSDC`.
///      Nothing else is reachable from the controller, so implementing the other ~28 members of
///      that interface would add surface with no assertion strength.
contract ControllerReserveDouble {
    enum Mode {
        /// @dev Behaves like the real reserve. The positive control: every guard must PASS here,
        ///      or a red run below would prove nothing.
        Honest,
        /// @dev Takes the full charge but forwards half of it straight out again. The ledger is
        ///      credited in full. Custody never received what the user paid.
        SkimDeposit,
        /// @dev Takes and keeps the full charge and reports it as credited, but never recognises
        ///      it as backing. The cash arrived; the books do not know it did.
        DepositWithoutCrediting,
        /// @dev Pays the redeemer correctly but writes its backing down by TWICE the cash paid,
        ///      so the redemption leaves holders worse off than the burn justifies.
        OverReleaseBacking,
        /// @dev AUDIT FIX (R17). Takes the charge and forwards MORE than it took, so the reserve's
        ///      own balance FALLS across `depositUSDC`. This is the state R16's underflow clamp
        ///      was written for and which no test could previously produce — the reason that clamp
        ///      survived a full-suite deletion mutation. Requires the double to be pre-funded.
        DrainOnDeposit,
        /// @dev AUDIT FIX (R17). Books the release correctly — its backing tally moves by exactly
        ///      the right value, so `_assertDeficitNotWorsened` is perfectly satisfied — but
        ///      forwards only HALF the cash to the redeemer and sends the rest to `sink`. The
        ///      outflow twin of `SkimDeposit`, on the leg where the USDfr is already burned.
        SkimRelease,
        /// @dev AUDIT FIX (R17). Books the release correctly and, instead of paying, DEBITS the
        ///      redeemer on a standing approval. The redeemer's balance FALLS across the call,
        ///      which is what falsifies `redeem`'s underflow clamp.
        ClawbackRelease,
        /// @dev AUDIT FIX (R17). Sources the deposit from a third party instead of spending the
        ///      controller's allowance, so its balance rises by exactly `amount` and the delivery
        ///      equality holds — while the user's cash stays on the controller with a live
        ///      approval against it. Requires `setFunder`.
        DepositFromThirdParty,
        /// @dev AUDIT FIX (R17). Re-enters `MintRedeemController.mint` from inside `depositUSDC`.
        ///      The falsifying case for `mint`'s `nonReentrant`, which also survived a full-suite
        ///      deletion mutation. Requires `setReentrancyTarget`.
        ReenterMint,
        /// @dev AUDIT FIX (R17). Delivers the cash and credits backing correctly, but MISREPORTS
        ///      the value it credited by one wei. The delivery measurement is satisfied — the
        ///      money really did move — so this falsifies the OTHER half of the same check, the
        ///      one that says the books agree with what the user was charged.
        MisreportCredit,
        /// @dev AUDIT FIX (R17). Re-enters `MintRedeemController.redeem` from inside
        ///      `releaseUSDC`, then pays normally. The falsifying case for BOTH `redeem`
        ///      overloads' `nonReentrant`, which survived a full-suite deletion mutation.
        ///      `setReentrancyTarget` names the controller; `setReenterTwoArgRedeem` picks which
        ///      overload is re-entered.
        ReenterRedeem
    }

    IERC20 public immutable token;
    address public immutable sink;
    Mode public mode;
    uint256 private backing;
    address public funder;
    address public reentrancyTarget;
    uint256 public reentrancyAmount;
    bool public reenterTwoArg;
    bool private reentered;
    address private lossAbsorber_;
    uint256 public overReleaseDelta;
    uint256 public exitPrepaidAbsorption_;

    constructor(IERC20 token_, address sink_) {
        token = token_;
        sink = sink_;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    /// @dev Seeds recorded backing without moving cash, so a scenario can start at par.
    function seedBacking(uint256 value) external {
        backing = value;
    }

    /// @dev ADR-0034 Y-bis. The junior-draw source `MintRedeemController._drawJuniorForExit`
    ///      DERIVES from the reserve. Zero (the default) means "unwired", which is the state every
    ///      pre-existing scenario in this file expects: no draw is attempted and the exit prices
    ///      exactly as it did before the ADR.
    function setLossAbsorber(address absorber) external {
        lossAbsorber_ = absorber;
    }

    /// @dev ADR-0034 Y-bis. Over-releases RECORDED backing by this much on top of the cash paid,
    ///      WITHOUT touching the cash. `OverReleaseBacking` doubles the write-down, which is far
    ///      too coarse to separate the two possible anchors of `_assertDeficitNotWorsened`; this
    ///      knob is deliberately fine-grained so a delta SMALLER than the junior draw can be
    ///      injected. That is the only state in which the post-draw anchor and the pre-draw anchor
    ///      disagree, and it is what falsifies the re-anchor.
    function setOverReleaseDelta(uint256 delta) external {
        overReleaseDelta = delta;
    }

    /// @dev AUDIT FIX (R17). The third party `DepositFromThirdParty` pulls the deposit from.
    function setFunder(address funder_) external {
        funder = funder_;
    }

    /// @dev AUDIT FIX (R17). The controller `ReenterMint`/`ReenterRedeem` calls back into, and
    ///      the amount it re-enters with.
    function setReentrancyTarget(address target, uint256 amount) external {
        reentrancyTarget = target;
        reentrancyAmount = amount;
    }

    /// @dev AUDIT FIX (R17). Selects which `redeem` overload `ReenterRedeem` calls back into, so
    ///      the lock on each is falsified separately rather than by inference from the other.
    function setReenterTwoArgRedeem(bool twoArg) external {
        reenterTwoArg = twoArg;
    }

    // ── the six members `MintRedeemController` actually calls ────────────

    function usdc() external view returns (address) {
        return address(token);
    }

    function idleCustodyShortfall() external pure returns (uint256) {
        return 0;
    }

    /// @dev ADR-0034 Y-bis — part of the surface `MintRedeemController` now calls.
    function lossAbsorber() external view returns (address) {
        return lossAbsorber_;
    }

    function exitPrepaidAbsorption() external view returns (uint256) {
        return exitPrepaidAbsorption_;
    }

    function recordExitPrepayment(uint256 amount) external {
        exitPrepaidAbsorption_ += amount;
    }

    function recognizedBackingValue() external view returns (uint256) {
        return backing;
    }

    function totalBackingValue() external view returns (uint256) {
        return backing;
    }

    function depositUSDC(address from, uint256 amount) external returns (uint256 credited) {
        credited = amount * 1e12;
        if (mode == Mode.DepositFromThirdParty) {
            // The controller's allowance is deliberately NOT spent. The books and the balance both
            // move by exactly the right amount, so the delivery equality is satisfied — which is
            // the whole point: the equality constrains how much the balance ROSE, never WHERE the
            // rise came from.
            token.transferFrom(funder, address(this), amount);
            backing += credited;
            return credited;
        }
        if (mode == Mode.ReenterMint && !reentered) {
            reentered = true;
            IReentrantMintTarget(reentrancyTarget).mint(reentrancyAmount);
        }
        token.transferFrom(from, address(this), amount);
        if (mode == Mode.SkimDeposit) {
            token.transfer(sink, amount / 2);
            backing += credited;
        } else if (mode == Mode.DrainOnDeposit) {
            // Forwards MORE than it took: the reserve's own balance falls across the call.
            token.transfer(sink, amount + 1);
            backing += credited;
        } else if (mode == Mode.DepositWithoutCrediting) {
            // cash kept, books untouched
        } else if (mode == Mode.MisreportCredit) {
            backing += credited;
            credited -= 1; // the cash is all here; the REPORT is a wei short
        } else {
            backing += credited;
        }
    }

    function releaseUSDC(address to, uint256 amount) external {
        uint256 value = amount * 1e12;
        backing -= (mode == Mode.OverReleaseBacking ? value * 2 : value) + overReleaseDelta;
        if (mode == Mode.SkimRelease) {
            // Ledger moved by exactly `value`; only half the cash reaches the redeemer.
            token.transfer(to, amount / 2);
            token.transfer(sink, amount - amount / 2);
            return;
        }
        if (mode == Mode.ReenterRedeem && !reentered) {
            reentered = true;
            if (reenterTwoArg) {
                IReentrantRedeemTarget(reentrancyTarget).redeem(reentrancyAmount, 0);
            } else {
                IReentrantRedeemTarget(reentrancyTarget).redeem(reentrancyAmount);
            }
        }
        if (mode == Mode.ClawbackRelease) {
            // Pays nothing and DEBITS the redeemer on a standing approval, so their balance falls.
            token.transferFrom(to, sink, amount);
            return;
        }
        token.transfer(to, amount);
    }
}

/// @dev AUDIT FIX (R17). The single controller entry point `Mode.ReenterMint` calls back into.
interface IReentrantMintTarget {
    function mint(uint256 usdcAmount) external returns (uint256);
}

/// @dev AUDIT FIX (R17). Both `redeem` overloads, so `Mode.ReenterRedeem` can falsify each lock.
interface IReentrantRedeemTarget {
    function redeem(uint256 usdfrAmount) external returns (uint256);
    function redeem(uint256 usdfrAmount, uint256 minUsdcOut) external returns (uint256);
}
