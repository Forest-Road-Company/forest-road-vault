// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {IPointsModule} from "../../src/interfaces/IPointsModule.sol";

/// @title HostilePointsModule
/// @notice AUDIT FIX (R18). The falsifying observer for the two findings that live inside USDfr's
///         DELIBERATELY FAIL-OPEN participation-points hook.
///
/// @dev WHY THIS HELPER HAS TO EXIST. `USDfr._update` wraps `onUSDfrTransfer` in `try/catch` under
///      an explicit protocol-wide rule — "a points-module failure must never block a USDfr
///      transfer, mint, or burn" (finding C4-USDFR-01) — and `setPointsModule` refuses a codeless
///      module for the same reason. That makes this hook the ONLY place in the tree where a
///      governance-set contract receives control INSIDE a supply change, after `super._update` has
///      already moved the balance. Two R18 findings live in exactly that frame and neither is
///      reachable without a module that acts there:
///
///      MODE `MoveCash` — the DoS. `MintRedeemController._redeem` used to open its outflow
///      measurement window BEFORE the burn, so one wei of USDC moved to the redeemer from here
///      broke the settlement equality and reverted the redemption — from OUTSIDE the token's
///      `try/catch`, so the token's fail-open guarantee held for transfers and not for redemptions.
///
///      MODE `ReadViews` — the read-only reentrancy. Supply is already down and backing is not yet
///      down, so from here the composite views published the opposite of the truth: the whole
///      realised loss of a cascade as mintable headroom, TRUE on a short book, PAR on a sub-par one.
///
///      IT SWALLOWS NOTHING. Every observation is written to storage, and a revert observed here is
///      recorded rather than propagated, because the token's `catch` would erase it either way. A
///      test therefore reads what the module SAW, not what the transaction returned.
contract HostilePointsModule is IPointsModule {
    enum Mode {
        /// @dev Inert. The positive control: with this mode the redemption must settle normally, or
        ///      a red run in another mode proves nothing.
        Idle,
        /// @dev Moves `cashAmount` of USDC to the account whose balance changed. One wei is enough.
        MoveCash,
        /// @dev Reads the controller's composite views and records what they answered.
        ReadViews,
        /// @dev AUDIT FIX (R18). Executes an arbitrary pre-loaded call from inside the balance
        ///      change — the falsifier for `mint`'s closing `_assertDeficitNotWorsened`. `mint`'s
        ///      delta checks all run BEFORE `$.usdfr.mint(...)`, so a module that LOWERS BACKING
        ///      from inside the mint's own `_update` is invisible to every one of them and is
        ///      caught only by the closing solvency rule. That is not a hypothetical shape: it is
        ///      the same "a governance-set module does something in a callback" threat model
        ///      `ControllerReserveDouble` and `ReentrantUSDfrDouble` were written for.
        ExecuteCall
    }

    Mode public mode;
    address public callTarget;
    bytes public callData;
    IERC20 public immutable usdc;
    IMintRedeemController public immutable controller;
    uint256 public cashAmount;

    // ── what the module SAW from inside the window ───────────────────────
    bool public sawHeadroomRevert;
    bool public sawInvariantRevert;
    bool public sawPreviewRevert;
    bool public sawDeficitRevert;
    bool public sawBackingDeficitRevert;
    uint256 public observedHeadroom;
    bool public observedInvariant;
    uint256 public observedPreviewOut;
    bool public ran;

    constructor(IERC20 usdc_, IMintRedeemController controller_) {
        usdc = usdc_;
        controller = controller_;
        cashAmount = 1;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setCashAmount(uint256 amount) external {
        cashAmount = amount;
    }

    /// @dev AUDIT FIX (R18). Arms `Mode.ExecuteCall`. Deliberately generic: the point is that ANY
    ///      state change reachable from inside the hook lands after `mint`'s delta measurements.
    function setCall(address target, bytes calldata data) external {
        callTarget = target;
        callData = data;
    }

    function onUSDfrTransfer(address from, address to, uint256) external override {
        if (mode == Mode.MoveCash) {
            address payee = from == address(0) ? to : from;
            usdc.transfer(payee, cashAmount);
            return;
        }
        if (mode == Mode.ExecuteCall) {
            ran = true;
            (bool ok,) = callTarget.call(callData);
            require(ok, "hostile call failed");
            return;
        }
        if (mode == Mode.ReadViews) {
            ran = true;
            try controller.mintableHeadroom() returns (uint256 h) {
                observedHeadroom = h;
            } catch {
                sawHeadroomRevert = true;
            }
            try controller.backingInvariantHolds() returns (bool ok) {
                observedInvariant = ok;
            } catch {
                sawInvariantRevert = true;
            }
            try controller.previewRedeem(1e18) returns (uint256 out, uint256) {
                observedPreviewOut = out;
            } catch {
                sawPreviewRevert = true;
            }
            try controller.recognizedDeficit() returns (uint256) {}
            catch {
                sawDeficitRevert = true;
            }
            try controller.backingDeficit() returns (uint256) {}
            catch {
                sawBackingDeficitRevert = true;
            }
        }
    }

    function onSharesTransfer(address, address, uint256) external override {}
    function onCuratorStakeChange(address, uint256, uint256) external override {}
    function onCuratorLoss(uint256, uint256, uint256) external override {}
}
