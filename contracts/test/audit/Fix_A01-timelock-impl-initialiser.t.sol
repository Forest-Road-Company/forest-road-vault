// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {TimelockControllerUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";

import {Deploy, ForestRoadTimelock} from "../../script/Deploy.s.sol";
import {MainnetDeploymentReceipt} from "../../script/DeployMainnet.s.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @title Fix_A01-timelock-impl-initialiser
/// @notice Regression suite for audit finding A-01 (the timelock IMPLEMENTATION ships with an
///         open initialiser, so anyone may `initialize` it and take administrative control of
///         the logic contract).
///
///         Root cause was a gap in a house convention, not in custody code.
///         `TimelockControllerUpgradeable` is the ONE implementation in this deployment taken
///         from an upstream library rather than written in `contracts/src`, and it declares no
///         constructor at all — so it never received the `constructor() { _disableInitializers(); }`
///         that all 18 in-repo implementations carry. Deployed raw, its ERC-7201 `Initializable`
///         slot stays at 0 ("never initialised, initialiser still open").
///
///         The fix is `ForestRoadTimelock` in `script/Deploy.s.sol`: a wrapper that adds NO
///         runtime logic and exists solely to run `_disableInitializers()` in its constructor.
///
/// @dev WHY THIS TEST EXISTS AND WHAT IT IS ALLOWED TO ASSERT AGAINST.
///      The fix is one constructor line in a deployment script. Nothing in the suite pinned it,
///      so a refactor could have deleted the wrapper — or reverted the `_deployAll` call site to
///      `new TimelockControllerUpgradeable()` — and every test would have stayed green. This
///      suite therefore refuses to assert against a locally-constructed `ForestRoadTimelock`,
///      which would only re-test the wrapper's own constructor and would NOT notice the call
///      site changing. It runs the REAL script sequence (`_deployAll` → `_wire` → `_seed` →
///      `_handover`, exactly as `Deploy.run()` does between its broadcast bookends) and reads
///      the implementation out of the deployed proxy's ERC-1967 slot. Both refactors above
///      break `test_A01_deployedTimelockImplementation_initialiserIsLocked`.
///
///      The test contract inherits `Deploy` so it can drive those internal steps with ITSELF as
///      the deployer EOA, mirroring `Fix_C01-deploy-tooling.t.sol`. This is required, not
///      stylistic: `_handover` finishes with `renounceRole(DEFAULT_ADMIN_ROLE, deployer)` and
///      `AccessControl.renounceRole` demands `callerConfirmation == _msgSender()`, so the
///      sequence can only be executed by the deployer address itself.
///
///      The finding was explicitly bounded — "the proxy is unaffected" — and the boundary is
///      load-bearing to the severity. `test_A01_proxy_*` pin it, so a future "fix" that locked
///      the implementation by breaking the live governance instance cannot pass.
contract FixA01TimelockImplInitialiserTest is Test, Deploy {
    /// @dev `Initializable`'s ERC-7201 storage location
    ///      (`openzeppelin.storage.Initializable`). Its first 64 bits are `_initialized`:
    ///      0 = never initialised (initialiser OPEN), 1 = initialised to version 1,
    ///      `type(uint64).max` = permanently disabled by `_disableInitializers()`.
    bytes32 internal constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    /// @dev ERC-1967 implementation slot (`bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)`).
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal attacker = makeAddr("a01Attacker");
    address internal attester2Addr = makeAddr("a01Attester2");

    // ── fixtures ──────────────────────────────────────────────────────────

    /// @dev The shape that actually deploys today: ops == deployer, admin retained
    ///      (`KEEP_OPS_ADMIN=true`). A-01 is a property of the implementation BYTECODE, so it is
    ///      independent of this posture; the testnet shape is used because it is the one the
    ///      live stack was deployed with.
    function _ctx() internal view returns (Ctx memory c) {
        c.deployer = address(this);
        c.opsAdmin = address(this);
        c.proposalGuardian = attester2Addr;
        c.queueKeeper = address(this); // AUDIT FIX (D7-01 round 5): SETTLEMENT_KEEPER_ROLE holder; Deploy._wire fails closed on zero
        c.frTreasury = address(this);
        c.feeRecipient = address(this);
        c.attester2 = attester2Addr;
        c.keepOpsAdmin = true;
    }

    /// @dev The real script sequence, minus only the broadcast/manifest bookends (which are
    ///      cheatcode plumbing, not deployment). Same body as `Deploy.run()`'s inner block.
    function _runScript() internal returns (D memory d) {
        Ctx memory c = _ctx();
        d = _deployAll(c);
        _wire(d, c);
        _seed(d, c);
        _handover(d, c);
    }

    /// @dev The implementation the deployed proxy actually delegates to, read from chain state
    ///      rather than from anything the script told us — the point is to pin what was
    ///      DEPLOYED, not what the script intended.
    function _implementationOf(address proxy) internal view returns (address impl) {
        impl = address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));
    }

    /// @dev The `_initialized` counter of a contract's `Initializable` storage.
    function _initializedVersion(address target) internal view returns (uint64 version) {
        version = uint64(uint256(vm.load(target, INITIALIZABLE_STORAGE)));
    }

    // ── THE GUARD: the implementation's initialiser must be spent ─────────

    /// @notice A-01: the timelock implementation behind the deployed proxy has a locked
    ///         initialiser, and an arbitrary caller cannot seize it.
    /// @dev This is the assertion whose absence the audit register recorded. It fails if the
    ///      `_disableInitializers()` call is removed from `ForestRoadTimelock`, AND it fails if
    ///      `_deployAll` is reverted to constructing a raw `TimelockControllerUpgradeable`,
    ///      because it reaches the implementation through the proxy's ERC-1967 slot.
    function test_A01_deployedTimelockImplementation_initialiserIsLocked() public {
        D memory d = _runScript();
        address impl = _implementationOf(d.timelock);

        assertTrue(impl != address(0), "no implementation recorded in the ERC-1967 slot");
        assertTrue(impl != d.timelock, "implementation must not be the proxy itself");
        assertGt(impl.code.length, 0, "implementation has no code");

        // The house convention, asserted on the storage that encodes it.
        assertEq(
            _initializedVersion(impl),
            type(uint64).max,
            "A-01 REGRESSION: timelock implementation initialiser is NOT disabled"
        );

        // And the behaviour that slot buys: the seizure itself reverts, with the specific
        // OpenZeppelin 5.x error (CLAUDE.md §1.1 — assert the selector, not "it reverted").
        address[] memory proposers = new address[](1);
        proposers[0] = attacker;
        address[] memory executors = new address[](1);
        executors[0] = attacker;

        vm.prank(attacker);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        TimelockControllerUpgradeable(payable(impl)).initialize(0, proposers, executors, attacker);

        // No partial takeover: the reverted call left no roles behind.
        TimelockControllerUpgradeable implTl = TimelockControllerUpgradeable(payable(impl));
        assertFalse(implTl.hasRole(implTl.DEFAULT_ADMIN_ROLE(), attacker), "attacker holds admin on the implementation");
        assertFalse(implTl.hasRole(implTl.PROPOSER_ROLE(), attacker), "attacker holds PROPOSER on the implementation");
        assertFalse(implTl.hasRole(implTl.EXECUTOR_ROLE(), attacker), "attacker holds EXECUTOR on the implementation");
        assertFalse(implTl.hasRole(implTl.CANCELLER_ROLE(), attacker), "attacker holds CANCELLER on the implementation");
    }

    /// @notice A-01: the script deploys the LOCKED wrapper, not the raw upstream library.
    /// @dev Complements the guard above along a different axis. The guard proves the deployed
    ///      implementation is locked; this proves it is `ForestRoadTimelock` specifically, so a
    ///      refactor that swapped the call site for some other locked contract is still visible.
    ///      Codehash equality (not just runtime length) is safe here because both sides come
    ///      from the same compilation unit, so even the trailing CBOR metadata matches.
    function test_A01_deployedTimelockImplementation_isTheForestRoadWrapper() public {
        D memory d = _runScript();
        address impl = _implementationOf(d.timelock);

        assertEq(impl.codehash, address(new ForestRoadTimelock()).codehash, "implementation is not ForestRoadTimelock");
        assertTrue(
            impl.codehash != address(new TimelockControllerUpgradeable()).codehash,
            "implementation is the raw upstream library"
        );
    }

    /// @notice The implementation selected by the deployment path must match the implementation
    ///         selected by the mainnet authorization receipt.
    /// @dev This is the cross-binding that was missing when A-01 changed `_deployAll` without
    ///      changing the receipt's explicit artifact enumeration.
    function test_A01_deployedTimelockImplementation_matchesMainnetReceiptArtifact() public {
        D memory d = _runScript();
        address impl = _implementationOf(d.timelock);
        MainnetDeploymentReceipt.ArtifactCodeHashes memory receiptArtifact =
            MainnetDeploymentReceipt.timelockImplementationArtifact();

        assertEq(
            receiptArtifact.creationCodeHash,
            keccak256(type(ForestRoadTimelock).creationCode),
            "receipt creation artifact is not ForestRoadTimelock"
        );
        assertEq(impl.codehash, receiptArtifact.runtimeCodeHash, "deployed timelock and receipt artifact diverge");
    }

    // ── THE BOUNDARY: the proxy must be untouched by the fix ─────────────

    /// @notice A-01 boundary: the timelock PROXY is initialised and its storage is live.
    /// @dev The finding's bounded severity rests on "the proxy is unaffected". Pinned here so a
    ///      future attempt at the fix cannot lock the implementation by disabling the instance
    ///      that actually governs the protocol.
    function test_A01_proxy_remainsInitialisedAndItsStorageIsLive() public {
        D memory d = _runScript();

        assertEq(_initializedVersion(d.timelock), 1, "proxy must be initialised at version 1");

        TimelockControllerUpgradeable tl = TimelockControllerUpgradeable(payable(d.timelock));
        assertEq(tl.getMinDelay(), Config.TIMELOCK_MIN_DELAY, "proxy min delay lost");

        // Initialised means SPENT: the proxy is not re-seizable either.
        address[] memory none = new address[](0);
        vm.prank(attacker);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        tl.initialize(0, none, none, attacker);
        assertEq(tl.getMinDelay(), Config.TIMELOCK_MIN_DELAY, "proxy min delay overwritten by re-initialize attempt");
    }

    /// @notice A-01 boundary: the governance roles the deploy wires onto the PROXY are intact.
    /// @dev Mirrors `_wire`'s timelock block (governor proposes/cancels, execution open) and
    ///      `_handover`'s closing renounce, so a change that broke governance while locking the
    ///      implementation would fail here rather than pass quietly.
    function test_A01_proxy_governanceRolesAreIntact() public {
        D memory d = _runScript();
        TimelockControllerUpgradeable tl = TimelockControllerUpgradeable(payable(d.timelock));

        // self-administration, granted by `__TimelockController_init_unchained`
        assertTrue(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), d.timelock), "timelock lost admin over itself");
        // `_wire`
        assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), d.governor), "governor lost PROPOSER");
        assertTrue(tl.hasRole(tl.CANCELLER_ROLE(), d.governor), "governor lost CANCELLER");
        assertTrue(tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "execution is no longer open");
        // `_handover`: the bootstrap deployer's temporary admin is gone
        assertFalse(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), address(this)), "deployer retained timelock admin");
        // and nobody else drifted in
        assertFalse(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), attacker), "attacker holds admin on the proxy");
        assertFalse(tl.hasRole(tl.PROPOSER_ROLE(), attacker), "attacker holds PROPOSER on the proxy");
    }

    // ── CONTROL: the vulnerable shape, proving the guard is not vacuous ──

    /// @notice The A-01 finding itself, on the unwrapped upstream contract.
    /// @dev A guard that cannot distinguish fixed from unfixed is decoration. This deploys
    ///      `TimelockControllerUpgradeable` the way the pre-fix script did and shows the
    ///      seizure SUCCEEDING: open initialiser, attacker takes `DEFAULT_ADMIN_ROLE` on the
    ///      implementation and self-grants PROPOSER. It also documents, executably, why the
    ///      convention exists — and it is the reason the deployed Sepolia implementation
    ///      remains seizable until that stack is redeployed.
    function test_A01_control_rawUpstreamImplementationIsSeizable() public {
        address raw = address(new TimelockControllerUpgradeable());
        assertEq(_initializedVersion(raw), 0, "control invalid: raw implementation is already locked");

        address[] memory proposers = new address[](1);
        proposers[0] = attacker;
        address[] memory executors = new address[](0);

        vm.prank(attacker);
        TimelockControllerUpgradeable(payable(raw)).initialize(0, proposers, executors, attacker);

        TimelockControllerUpgradeable rawTl = TimelockControllerUpgradeable(payable(raw));
        // Role ids are read into locals BEFORE any prank: each getter is itself an external
        // call, and one placed inside a pranked expression consumes the prank.
        bytes32 adminRole = rawTl.DEFAULT_ADMIN_ROLE();
        bytes32 proposerRole = rawTl.PROPOSER_ROLE();
        bytes32 executorRole = rawTl.EXECUTOR_ROLE();

        assertTrue(rawTl.hasRole(adminRole, attacker), "control invalid: seizure did not grant admin");
        assertTrue(rawTl.hasRole(proposerRole, attacker), "control invalid: seizure did not grant PROPOSER");

        // Having admin, the attacker can hand itself the rest — the forgeable-governance-events
        // half of the finding.
        vm.prank(attacker);
        rawTl.grantRole(executorRole, attacker);
        assertTrue(rawTl.hasRole(executorRole, attacker), "control invalid: admin could not self-grant");

        assertEq(_initializedVersion(raw), 1, "control invalid: raw implementation did not initialise");
    }

    /// @notice The wrapper is what closes the control case above, on an otherwise identical contract.
    /// @dev Same construction, one constructor line apart. Kept alongside the control so the
    ///      delta the fix introduces is a single readable diff.
    function test_A01_wrapperClosesTheControlCase() public {
        address wrapped = address(new ForestRoadTimelock());
        assertEq(_initializedVersion(wrapped), type(uint64).max, "wrapper did not disable its initialiser");

        address[] memory proposers = new address[](1);
        proposers[0] = attacker;
        address[] memory executors = new address[](0);

        vm.prank(attacker);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        TimelockControllerUpgradeable(payable(wrapped)).initialize(0, proposers, executors, attacker);

        TimelockControllerUpgradeable wrappedTl = TimelockControllerUpgradeable(payable(wrapped));
        // Role ids into locals first — see the note in the control test above.
        bytes32 adminRole = wrappedTl.DEFAULT_ADMIN_ROLE();
        bytes32 executorRole = wrappedTl.EXECUTOR_ROLE();
        assertFalse(wrappedTl.hasRole(adminRole, attacker), "wrapper was seized anyway");

        // The wrapper adds no runtime logic, so `grantRole` is still ordinary AccessControl and
        // still refuses an unauthorised caller — the implementation is inert, not broken.
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, adminRole)
        );
        wrappedTl.grantRole(executorRole, attacker);
    }
}
