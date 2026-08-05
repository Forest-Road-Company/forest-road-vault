// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {TimelockControllerUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";

/// @notice ONE-OFF, TESTNET ONLY: permanently neutralise the deployed Sepolia timelock
///         IMPLEMENTATION, closing finding `A-01` against the existing stack.
///
/// @dev WHY. `A-01`: `TimelockControllerUpgradeable` is the only implementation in this system
///      taken from an upstream library rather than written in-repo, and it declares no constructor,
///      so it never received the house convention `constructor() { _disableInitializers(); }` that
///      the other seventeen follow. Deployed raw, its `Initializable` slot stays 0 and ANYONE may
///      call `initialize` on it and take administrative control of the implementation contract.
///
///      The code fix (the `ForestRoadTimelock` wrapper in `Deploy.s.sol`) is PROSPECTIVE: it governs
///      future deployments. The implementation already on Sepolia was created before it and stays
///      seizable until that stack is redeployed. Forest Road has confirmed there will be no Sepolia
///      redeploy before mainnet, so this mitigates the live instance instead.
///
///      Verified on-chain 5 August 2026 across all eighteen deployed implementations: seventeen read
///      `type(uint64).max` (the `_disableInitializers` sentinel); `impl_timelock` alone reads 0.
///
/// @dev WHY NEUTRALISE RATHER THAN SEIZE. Initialising with `admin = address(0)` and empty proposer
///      and executor sets leaves NOBODY in control, including us. Reading the upstream initializer:
///      the admin grant is skipped when admin is zero, the loops grant nothing when the arrays are
///      empty, and the sole unconditional grant is `DEFAULT_ADMIN_ROLE` to the contract itself. The
///      result is deadlocked by construction — the only holder of `DEFAULT_ADMIN_ROLE` is the
///      contract, which can act only through a scheduled operation, which requires a `PROPOSER`,
///      which can only be granted by `DEFAULT_ADMIN_ROLE`. Nothing can ever be scheduled or executed.
///
///      Taking it for ourselves would instead create a custody obligation over a verified contract
///      the explorer labels "timelock", and would read on-chain as a shadow governance contract.
///
///      `minDelay` is set to `type(uint256).max` as defence in depth: even in some unforeseen state
///      where a proposer existed, `schedule` computes `block.timestamp + delay` and would overflow
///      and revert.
///
/// @dev THE PROXY IS UNAFFECTED. The proxy holds its own `Initializable` slot and its own storage,
///      and `delegatecall` reads the proxy's slots — writing the implementation's own storage cannot
///      touch it. This script asserts that explicitly, before and after.
///
///      Hard-reverts chain-id 1 (CLAUDE.md prime directive 1). Idempotent by assertion: it refuses
///      to run if the initialiser has already been spent.
contract NeutralizeSepoliaTimelockImpl is Script {
    /// @dev ERC-7201 namespaced location of OpenZeppelin's `Initializable` storage.
    bytes32 private constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;

    function run() external {
        require(block.chainid != 1, "NEVER MAINNET");
        require(block.chainid == 11155111, "Sepolia only");

        string memory manifest = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        address impl = vm.parseJsonAddress(manifest, ".impl_timelock");
        address proxy = vm.parseJsonAddress(manifest, ".timelock");

        // Guard against ever pointing this at the proxy: initialising through the proxy would be a
        // governance action against the live system, not a mitigation of a stranded implementation.
        require(impl != proxy, "target is the proxy, not the implementation");
        require(impl.code.length > 0, "implementation has no code");

        uint256 pk = vm.envUint("TESTNET_DEPLOYER_PRIVATE_KEY");
        address me = vm.addr(pk);

        TimelockControllerUpgradeable target = TimelockControllerUpgradeable(payable(impl));
        TimelockControllerUpgradeable live = TimelockControllerUpgradeable(payable(proxy));

        // ── pre-state ────────────────────────────────────────────────────────────────
        uint64 initializedBefore = _initializedVersion(impl);
        require(initializedBefore == 0, "implementation initialiser already spent; nothing to do");

        uint256 proxyMinDelayBefore = live.getMinDelay();
        uint64 proxyInitializedBefore = _initializedVersion(proxy);
        require(proxyInitializedBefore != 0, "proxy is not initialised; refusing to proceed");

        console2.log("chain:", block.chainid);
        console2.log("timelock implementation (target):", impl);
        console2.log("timelock proxy (must be untouched):", proxy);
        console2.log("caller:", me);
        console2.log("implementation _initialized before:", initializedBefore);

        // ── neutralise ───────────────────────────────────────────────────────────────
        address[] memory none = new address[](0);

        vm.startBroadcast(pk);
        target.initialize(type(uint256).max, none, none, address(0));
        vm.stopBroadcast();

        // ── post-state: the implementation is spent and inert ────────────────────────
        require(_initializedVersion(impl) == 1, "initialiser was not spent");

        require(target.hasRole(DEFAULT_ADMIN_ROLE, impl), "self-administration missing");
        require(!target.hasRole(DEFAULT_ADMIN_ROLE, me), "caller must hold no admin role");
        require(!target.hasRole(DEFAULT_ADMIN_ROLE, address(0)), "zero address must hold no admin role");
        require(!target.hasRole(target.PROPOSER_ROLE(), me), "caller must hold no proposer role");
        require(!target.hasRole(target.EXECUTOR_ROLE(), me), "caller must hold no executor role");
        require(!target.hasRole(target.CANCELLER_ROLE(), me), "caller must hold no canceller role");
        // Open execution would let anyone run an operation, if one could ever be scheduled.
        require(!target.hasRole(target.EXECUTOR_ROLE(), address(0)), "execution must not be open");

        // ── post-state: the live proxy is exactly as it was ──────────────────────────
        require(_initializedVersion(proxy) == proxyInitializedBefore, "proxy initialised version changed");
        require(live.getMinDelay() == proxyMinDelayBefore, "proxy minDelay changed");

        console2.log("implementation _initialized after:", _initializedVersion(impl));
        console2.log("proxy minDelay unchanged:", proxyMinDelayBefore);
        console2.log("A-01 mitigated: the implementation initialiser is spent and no account controls it.");
    }

    /// @dev Low 64 bits of the `Initializable` storage slot: `_initialized`.
    function _initializedVersion(address account) private view returns (uint64) {
        return uint64(uint256(vm.load(account, INITIALIZABLE_STORAGE)));
    }
}
