// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {ComplianceRegistry} from "../../../src/ComplianceRegistry.sol";
import {MintRedeemController} from "../../../src/MintRedeemController.sol";
import {RedemptionQueue} from "../../../src/RedemptionQueue.sol";
import {SUSDfr} from "../../../src/sUSDfr.sol";
import {USDfr} from "../../../src/USDfr.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {GuardProbe} from "./GuardProbe.sol";

/// @title AccessControlSurfaceHandler
/// @notice AUDIT FINDING G11/G12.1 — the handler behind the CLAUDE.md §1.3 ACCESS-CONTROL
///         invariant: "no privileged action is reachable by an unauthorized role IN ANY STATE".
///
///         TWO HALVES, and the second is the one that was missing.
///           * "no privileged action" — the probe table is the ENTIRE `onlyRole` surface,
///             enumerated at run time by `PrivilegedSurface` from `src/` and the compiled
///             artifacts (117 selectors across 17 modules). It cannot fall behind the code.
///           * "in any state" — `churn` walks the protocol through pause/unpause on every
///             pausable module, an empty and a funded vault, an open redemption request, a
///             latched settlement, and arbitrary time. Every probe is fired against whatever
///             state the campaign happens to be in, and the states actually visited are counted
///             so the claim is measured rather than asserted by adjective.
///
/// @dev WHY THE PROBES USE `GuardProbe._fireAtGuard` AND NOT A PRE-FILTERED CALL. Under
///      `fail_on_revert = true` the ordinary way to write this handler is to check first and call
///      only if the call will succeed — which is the shape that produced the vacuous invariants
///      this finding is about. `_fireAtGuard` fires the raw call and turns the REFUSAL into the
///      recorded property. See `GuardProbe`'s header.
///
/// @dev DO NOT replace the unauthorised actor set with `address(this)` or with a fixture actor.
///      The four probing actors deliberately hold NO role on ANY module — that is what makes an
///      admitted call unambiguously a violation rather than a mis-set-up test.
contract AccessControlSurfaceHandler is GuardProbe {
    struct Entry {
        address target;
        bytes4 selector;
        uint16 words;
        string label;
    }

    Entry[] public entries;

    address[4] public outsiders;
    address[] internal pausables;

    MockERC20 internal usdc;
    USDfr internal usdfr;
    SUSDfr internal vault;
    MintRedeemController internal controller;
    RedemptionQueue internal queue;
    ComplianceRegistry internal compliance;
    address internal admin;
    address internal guardian;

    bytes4 internal constant PAUSE_SELECTOR = bytes4(keccak256("pause()"));
    bytes4 internal constant UNPAUSE_SELECTOR = bytes4(keccak256("unpause()"));

    uint256 public callCount;
    uint256 public churnCount;
    uint256 public pauseCount;
    uint256 public unpauseCount;

    // ── "in any state" witnesses (measured, and asserted in `afterInvariant`) ──
    uint256 public probesWhileSomethingPaused;
    uint256 public probesWhileNothingPaused;
    uint256 public probesWithFundedVault;
    uint256 public probesWithQueuedRequest;
    uint256 public probesWhileSettling;

    /// @notice Per-entry admission counter, so a violation names the exact selector.
    mapping(uint256 => uint256) public admittedAt;

    constructor(
        MockERC20 usdc_,
        USDfr usdfr_,
        SUSDfr vault_,
        MintRedeemController controller_,
        RedemptionQueue queue_,
        ComplianceRegistry compliance_,
        address admin_,
        address guardian_,
        address complianceAdmin_,
        address[] memory pausables_
    ) {
        usdc = usdc_;
        usdfr = usdfr_;
        vault = vault_;
        controller = controller_;
        queue = queue_;
        compliance = compliance_;
        admin = admin_;
        guardian = guardian_;
        pausables = pausables_;

        outsiders[0] = makeAddr("aclOutsiderAlpha");
        outsiders[1] = makeAddr("aclOutsiderBravo");
        outsiders[2] = makeAddr("aclOutsiderCharlie");
        outsiders[3] = makeAddr("aclOutsiderDelta");

        // Two of the four are KYC-allowed. A compliance allowlist entry is NOT a role, and an
        // implementation that confused the two would be caught here rather than in production.
        vm.startPrank(complianceAdmin_);
        compliance.setAllowed(outsiders[0], true);
        compliance.setAllowed(outsiders[1], true);
        vm.stopPrank();
    }

    /// @notice Loads one enumerated privileged selector and registers it in the reach ledger.
    /// @dev Called once per entry from the suite's `setUp`. The expected refusal is OZ's
    ///      `AccessControlUnauthorizedAccount` — the exact selector, not "it reverted", per
    ///      CLAUDE.md §1.1.
    function addEntry(address target, bytes4 selector, uint16 words, string memory label) external {
        uint256 idx = entries.length;
        entries.push(Entry({target: target, selector: selector, words: words, label: label}));
        _registerGuard(bytes32(idx), IAccessControl.AccessControlUnauthorizedAccount.selector, label);
    }

    function entryCount() external view returns (uint256) {
        return entries.length;
    }

    // =====================================================================
    //  the probe
    // =====================================================================

    /// @notice Fires ONE enumerated privileged entry point from an actor that holds no role.
    /// @return verdict how the guard answered, so the deterministic sweep can tally it.
    function probe(uint256 entrySeed, uint256 actorSeed) public returns (Verdict verdict) {
        uint256 idx = entrySeed % entries.length;
        Entry memory e = entries[idx];
        _recordStateShape();
        verdict = _fireAtGuard(bytes32(idx), outsiders[actorSeed % 4], e.target, _calldataFor(e));
        if (verdict == Verdict.Admitted) admittedAt[idx]++;
        callCount++;
    }

    function _calldataFor(Entry memory e) private pure returns (bytes memory data) {
        data = abi.encodePacked(e.selector);
        for (uint256 i = 0; i < e.words; ++i) {
            data = abi.encodePacked(data, bytes32(0));
        }
    }

    function _recordStateShape() private {
        bool anyPaused;
        for (uint256 i = 0; i < pausables.length; ++i) {
            if (PausableUpgradeable(pausables[i]).paused()) {
                anyPaused = true;
                break;
            }
        }
        if (anyPaused) probesWhileSomethingPaused++;
        else probesWhileNothingPaused++;
        if (vault.totalSupply() > 0) probesWithFundedVault++;
        if (queue.totalRequests() > queue.head()) probesWithQueuedRequest++;
        if (queue.isSettling()) probesWhileSettling++;
    }

    // =====================================================================
    //  state churn — the "in any state" half of the invariant
    // =====================================================================

    /// @notice Moves the protocol into a different shape so the next probe lands somewhere new.
    /// @dev Every branch is written to be revert-free (`fail_on_revert = true` applies to the
    ///      HANDLER's own legitimate traffic; only the negative probes above go through
    ///      `_fireAtGuard`). Nothing here needs to be adversarial — its only job is to keep the
    ///      probes from all landing on one state.
    function churn(uint256 seed) public {
        uint256 pick = seed % 7;
        if (pick == 0) {
            // Read `paused()` and build the calldata BEFORE the prank. `vm.prank` applies to the
            // very next call the handler makes — including a staticcall — so evaluating
            // `PausableUpgradeable(...).paused()` inside the pranked statement silently consumed
            // the prank and left the pause/unpause to be attempted by the handler itself, which
            // has no role. The result was a campaign in which NO module was ever paused and the
            // "in any state" half of the invariant quietly covered one state. DO NOT inline these
            // reads back into the pranked statement.
            uint256 i = (seed / 7) % pausables.length;
            bool isPaused = PausableUpgradeable(pausables[i]).paused();
            bytes memory data = abi.encodeWithSelector(isPaused ? UNPAUSE_SELECTOR : PAUSE_SELECTOR);
            // Every module in this set gates both pause and unpause on GUARDIAN_ROLE today, but
            // admin is tried as a fallback so a future module that puts unpause behind governance
            // cannot leave the campaign permanently stuck in a paused state (which would silently
            // stop the value-moving churn below and shrink the state space the probes see).
            vm.prank(guardian);
            (bool ok,) = pausables[i].call(data);
            if (!ok) {
                vm.prank(admin);
                (ok,) = pausables[i].call(data);
            }
            if (ok) {
                if (isPaused) unpauseCount++;
                else pauseCount++;
            }
        } else if (pick == 1) {
            vm.warp(block.timestamp + 1 + (seed % 7 days));
        } else if (pick == 2) {
            _mintAndStake(seed);
        } else if (pick == 3) {
            _queueARequest(seed);
        } else if (pick == 4) {
            _addIdleLiquidity(seed);
        } else if (pick == 5) {
            vm.roll(block.number + 1 + (seed % 32));
        }
        churnCount++;
        callCount++;
    }

    /// @dev The value-moving churn branches are gated on NOTHING being paused, deliberately
    ///      over-conservatively. `whenNotPaused` sits on modules these paths touch transitively
    ///      (a `controller.mint` reaches `ReserveManager`), and under `fail_on_revert = true` a
    ///      missed one is a campaign-killing revert rather than a skipped call. Being generous
    ///      here costs nothing: pausing is itself one of the churn actions, so the probes still
    ///      run against paused modules — which is the state coverage the invariant needs.
    function _anythingPaused() private view returns (bool) {
        for (uint256 i = 0; i < pausables.length; ++i) {
            if (PausableUpgradeable(pausables[i]).paused()) return true;
        }
        return false;
    }

    function _mintAndStake(uint256 seed) private {
        address who = outsiders[seed % 2]; // only the KYC-allowed two can hold USDfr
        uint256 amount = _bounded(seed, 1e6, 250_000e6);
        if (_anythingPaused()) return;
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(controller), amount);
        controller.mint(amount);
        usdfr.approve(address(vault), amount * 1e12);
        vault.deposit(amount * 1e12, who);
        vm.stopPrank();
    }

    function _addIdleLiquidity(uint256 seed) private {
        address who = outsiders[seed % 2];
        if (_anythingPaused()) return;
        uint256 amount = _bounded(seed, 1e6, 500_000e6);
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(controller), amount);
        controller.mint(amount);
        vm.stopPrank();
    }

    function _queueARequest(uint256 seed) private {
        address who = outsiders[seed % 2];
        uint256 shares = vault.balanceOf(who);
        if (shares == 0 || _anythingPaused()) return;
        uint256 minShares = vault.previewWithdraw(queue.minRedemptionValue());
        if (minShares == 0) minShares = 1;
        if (shares < minShares) return;
        shares = _bounded(seed, minShares, shares);
        vm.startPrank(who);
        vault.approve(address(queue), shares);
        queue.requestRedeem(shares);
        vm.stopPrank();
    }

    function _bounded(uint256 seed, uint256 lo, uint256 hi) private pure returns (uint256) {
        return lo + (uint256(keccak256(abi.encode(seed))) % (hi - lo + 1));
    }
}
