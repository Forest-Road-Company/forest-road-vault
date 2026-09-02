// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockControllerUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AttestationOracle} from "../src/AttestationOracle.sol";
import {AssessedImpairmentSource} from "../src/AssessedImpairmentSource.sol";
import {ClaimBridge} from "../src/ClaimBridge.sol";
import {CollateralRegistry} from "../src/CollateralRegistry.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {CuratorModule} from "../src/CuratorModule.sol";
import {DefaultManager} from "../src/DefaultManager.sol";
import {FRGovernor} from "../src/FRGovernor.sol";
import {GroveToken} from "../src/GroveToken.sol";
import {GroveVotesAggregator} from "../src/GroveVotesAggregator.sol";
import {MintRedeemController} from "../src/MintRedeemController.sol";
import {MtmAtomicExecutor} from "../src/MtmAtomicExecutor.sol";
import {PointsModule} from "../src/PointsModule.sol";
import {RedemptionQueue} from "../src/RedemptionQueue.sol";
import {ReserveManager} from "../src/ReserveManager.sol";
import {SGrove} from "../src/SGrove.sol";
import {SUSDfr} from "../src/sUSDfr.sol";
import {USDfr} from "../src/USDfr.sol";
import {WaterfallEngine} from "../src/WaterfallEngine.sol";
import {IAttestationOracle} from "../src/interfaces/IAttestationOracle.sol";
import {ICollateralRegistry} from "../src/interfaces/ICollateralRegistry.sol";
import {Config} from "../src/libraries/Config.sol";
import {Roles} from "../src/libraries/Roles.sol";
import {MockERC20} from "../test/helpers/MockERC20.sol";
import {PrivilegeAudit} from "./PrivilegeAudit.sol";
import {PrivilegeTopology} from "./generated/PrivilegeTopology.sol";

/// @notice TESTNET deployment of the full Forest Road Vault stack (CLAUDE.md §2.1:
///         reproducible, env-parameterized). Mirrors the tested fixture topology
///         (`GovernanceFixture`) exactly: bootstrap with the deployer as temporary
///         admin, wire everything, hand DEFAULT_ADMIN to the timelock, then drop the
///         bootstrap privileges. On a fresh REAL broadcast (`--broadcast`) it writes the
///         machine-readable manifest to `deployments/<chainid>.json`, including both proxy and
///         implementation addresses; a dry run deliberately writes NOTHING, so a simulation can
///         never overwrite the record of the live stack. `Validate.s.sol` re-checks the live
///         wiring.
///
///         TESTNET-ONLY concessions (surfaced in the manifest, re-checked by Validate):
///         - OPS_ADMIN (default: deployer) keeps DEFAULT_ADMIN alongside the timelock
///           while KEEP_OPS_ADMIN=true (default), so QA can turn parameters without
///           governance proposals. Set false for the production-shaped rehearsal.
///         - A mock 6-decimal "tUSDC" stands in for the single USDC asset.
///         - Attester #2's key is derived from the deployer key (the real attester
///           set is a Part 11 gate-6 item).

/// @title ForestRoadTimelock
/// @notice The timelock implementation, wrapped ONLY to lock its initializer.
/// @dev AUDIT FIX (A-01). `TimelockControllerUpgradeable` is the one implementation in this
///      deployment sourced from an upstream library rather than written in-repo, and it declares
///      NO constructor at all — so it never received the house convention that every other
///      implementation follows (`constructor() { _disableInitializers(); }`, 18/18 in
///      `contracts/src`). Deployed raw, its ERC-7201 `Initializable` slot stays at 0, meaning
///      "never initialised, initialiser still open": anyone may call `initialize(...)` directly on
///      the implementation, take `DEFAULT_ADMIN_ROLE` on it, and self-grant PROPOSER/EXECUTOR/
///      CANCELLER. Proven against the live Sepolia implementation
///      (`0x0565042651f9c217dCCE7A27b21800e8D444D8c1`, initSlot `0x…0000` where all 18 others read
///      `0x…ffffffffffffffff`).
///
///      Blast radius is bounded and this is NOT a fund-loss bug on the protocol: every protocol
///      role is held by the timelock PROXY, whose storage is initialised and untouched, and this
///      contract is not UUPS so there is no `upgradeToAndCall` to escalate through. What the fix
///      removes is (a) seizure of any value misdirected to the implementation address — it has
///      `receive() external payable` and the ERC-721/1155 holder hooks — and (b) a forgeable source
///      of `RoleGranted`/`CallScheduled`/`CallExecuted` events at an address publicly labelled as
///      Forest Road governance.
///
///      WHY THIS LIVES IN `script/` AND NOT `src/`: it adds no runtime LOGIC. A constructor does not
///      appear in runtime code, so the deployed implementation's executable bytes are identical to
///      `TimelockControllerUpgradeable` and the runtime is the same length — MEASURED at 7,930 bytes
///      for both, with the two differing only in the trailing CBOR metadata hash, which necessarily
///      differs because the compilation unit differs. (Stated precisely because an earlier draft of
///      this comment claimed "byte-identical", and the verification test at `test/a01check` failed
///      on exactly that word.) It therefore carries nothing for Slither, the size gate or coverage
///      to act on, so classifying it as a 20th production contract would churn every gate that
///      enumerates `src/` — the production count, scope hashes, the Slither baseline, coverage
///      denominators — while buying nothing. It sits immediately above its single call site so an
///      auditor enumerating the deployed set finds it without hunting.
///      **If this contract ever gains a function or a state variable, move it to `src/` in the same
///      change** — the justification above holds only while it is a bare initializer lock.
///
///      This fixes FUTURE deployments only. The already-deployed Sepolia implementation remains
///      seizable and A-01 stays open against it until that stack is redeployed.
/// @custom:oz-upgrades-unsafe-allow constructor
contract ForestRoadTimelock is TimelockControllerUpgradeable {
    constructor() {
        _disableInitializers();
    }
}

contract Deploy is Script {
    /// @notice The authority handover would leave governance unable to meet its launch quorum.
    /// @param grove The GROVE proxy.
    /// @param treasury The genesis treasury whose wallet/staked delegations were measured.
    /// @param votingPower Current voting power reachable through those delegations.
    /// @param requiredVotingPower Minimum power required to meet the configured quorum.
    error DeployGovernanceDeadOnArrival(
        address grove, address treasury, uint256 votingPower, uint256 requiredVotingPower
    );

    /// @notice The configured Governor cannot drive the timelock that is about to become admin.
    /// @param timelock The timelock proxy.
    error DeployTimelockNotLive(address timelock);

    struct D {
        address compliance;
        address usdfr;
        address reserves;
        address controller;
        address vault;
        address points;
        address registry;
        address oracle;
        address bridge;
        address curator;
        address waterfall;
        address defaultManager;
        address mtmExecutor;
        address assessedImpairmentSource;
        address queue;
        address grove;
        address sGrove;
        address timelock;
        address governor;
        address votesAggregator; // ADR-0026 (L-02): the Governor's IVotes source
        address stable;
    }

    struct Ctx {
        address deployer;
        address opsAdmin;
        /// @dev AUDIT FIX (D7-01): holder of SETTLEMENT_KEEPER_ROLE on the queue — the only
        ///      party that may drive `closeEpoch`. Defaults to `opsAdmin` so local/fork runs
        ///      work unattended; MainnetConfig requires it explicitly and fails closed.
        address queueKeeper;
        address frTreasury;
        address feeRecipient;
        address anchorCurator;
        address attester1;
        address attester2;
        bool keepOpsAdmin;
        bool attester2Derived;
    }

    /// @notice A UUPS proxy and the implementation it was deployed behind.
    /// @dev AUDIT FIX (deploy tooling, item 7b). Only proxy addresses were recorded, so
    ///      Etherscan verification and any future `upgradeToAndCall` had to rediscover the
    ///      implementations by reading the ERC-1967 slot of every proxy by hand.
    struct Impl {
        string name;
        address addr;
    }

    /// @dev Implementations recorded in construction order by `_proxy`, serialized into the
    ///      manifest as `impl_<name>` keys. Script-contract state only; never broadcast.
    Impl[] internal impls;

    /// @notice Deploy an ERC-1967 proxy over `implementation` and record the implementation.
    /// @param name Manifest key suffix; must match the proxy's own manifest key.
    /// @param implementation The freshly-deployed logic contract.
    /// @param initData ABI-encoded initializer call.
    /// @return proxy The deployed proxy address.
    function _proxy(string memory name, address implementation, bytes memory initData)
        internal
        returns (address proxy)
    {
        proxy = address(new ERC1967Proxy(implementation, initData));
        impls.push(Impl({name: name, addr: implementation}));
    }

    // ── broadcast decision (AUDIT FIX, deploy tooling round 2) ───────────
    //
    // WHY THESE ARE SEPARATE, VIRTUAL/PURE FUNCTIONS RATHER THAN INLINE IN `run()`.
    // Round 1 of this fix inlined `vm.isContext(...)` at the guard site. `vm.isContext` can
    // never report `ScriptBroadcast` under `forge test` (the context there is always `Test`),
    // so BOTH new branches — the DS-7 guard and the manifest write — became unreachable from
    // the test suite, and the one regression test that covered DS-7
    // (`test/fork/DeployValidateHandoverFork.t.sol`) turned red without anyone noticing.
    // Splitting the cheatcode read (`_isBroadcasting`, overridable) from the DECISION
    // (`_manifestGuardTrips`, pure) makes both testable: tests unit-test the predicate over all
    // four input combinations, and a `Deploy` subclass that overrides `_isBroadcasting()` to
    // return true drives the real `run()` down the broadcasting branch.

    /// @notice Whether this invocation is an ACTUAL broadcast (`--broadcast` or `--resume`).
    /// @dev Overridable ONLY so tests can drive the broadcasting branch of `run()`; production
    ///      behaviour is this single cheatcode read and nothing else.
    /// @return broadcasting True when `forge script` will really send transactions.
    function _isBroadcasting() internal view virtual returns (bool broadcasting) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
    }

    /// @notice Whether Forge is replaying a prior script transaction ledger through `--resume`.
    /// @dev Resume is categorically unsafe for this CREATE-address deployment: its nonce base has
    ///      already moved, so replay can recompute a parallel address set and write it over the
    ///      live manifest before Forge reports the nonce mismatch. This seam exists solely so the
    ///      refusal can be executed under `forge test`, where ScriptResume cannot occur naturally.
    function _isResuming() internal view virtual returns (bool resuming) {
        return vm.isContext(VmSafe.ForgeContext.ScriptResume);
    }

    /// @notice The `FORCE_REDEPLOY` opt-in.
    /// @dev A seam, for the same reason as `_isBroadcasting`: `run()`'s guard branches must be
    ///      drivable from `forge test` without a test mutating a PROCESS-GLOBAL env var, which
    ///      forge's parallel test execution turns into a cross-test race.
    /// @return force True when the operator has explicitly opted in to replacing the manifest.
    function _forceRedeploy() internal view virtual returns (bool force) {
        return vm.envOr("FORCE_REDEPLOY", false);
    }

    /// @notice The bootstrap deployer key.
    /// @dev A seam, same reason as `_forceRedeploy`. Production behaviour is the env read.
    /// @return pk The deployer private key.
    function _deployerKey() internal view virtual returns (uint256 pk) {
        return vm.envUint("TESTNET_DEPLOYER_PRIVATE_KEY");
    }

    /// @notice The DS-7 decision, isolated from any cheatcode so it can be unit-tested.
    /// @dev Trips only when a REAL broadcast would overwrite an existing manifest without the
    ///      explicit `FORCE_REDEPLOY` opt-in. A dry run deploys nothing on chain and therefore
    ///      cannot orphan a live stack, so it is deliberately allowed through — and is
    ///      separately prevented from WRITING the manifest at the end of `run()`.
    /// @param broadcasting Result of `_isBroadcasting()`.
    /// @param manifestExists Whether `deployments/<chainid>.json` is already present.
    /// @param force The `FORCE_REDEPLOY` opt-in.
    /// @return trips True when `run()` must refuse to proceed.
    function _manifestGuardTrips(bool broadcasting, bool manifestExists, bool force)
        internal
        pure
        returns (bool trips)
    {
        return broadcasting && manifestExists && !force;
    }

    function run() external virtual {
        require(block.chainid != 1, "MAINNET FORBIDDEN (CLAUDE.md prime directive 1)");

        // A deployment is one nonce-anchored ceremony. Never replay it. This must remain before
        // `_manifestPath`, every env read and `vm.startBroadcast`, so a failed resume cannot
        // repoint the durable manifest to CREATE addresses that were never deployed.
        if (_isResuming()) revert("Deploy: --resume forbidden; restart from a reviewed fresh deployment plan");

        // AUDIT FIX (deploy tooling, item 7b): the DS-7 guard and the manifest write are both
        // scoped to a REAL broadcast. `forge script` without `--broadcast` deploys nothing on
        // chain, so a dry run neither orphans a live stack nor has any address worth recording.
        // Before this, the runbook's step-2 dry rehearsal could not execute at all (the guard
        // fired on the existing manifest) and the only way to run it was to pass the
        // DESTRUCTIVE `FORCE_REDEPLOY=true` — which then let a simulation overwrite the live
        // manifest with addresses that were never deployed. See `_writeManifest`.
        bool broadcasting = _isBroadcasting();

        // AUDIT FIX (DS-7): refuse to overwrite an existing manifest — a re-run builds a
        // full parallel stack at new addresses and would orphan the live one, silently
        // repointing Validate/frontend. Set FORCE_REDEPLOY=true to intentionally replace.
        string memory manifestPath = _manifestPath();
        if (_manifestGuardTrips(broadcasting, vm.exists(manifestPath), _forceRedeploy())) {
            revert("manifest exists for this chain; set FORCE_REDEPLOY=true to replace (orphans the prior stack)");
        }

        uint256 pk = _deployerKey();
        Ctx memory c = _resolveCtx(pk);

        console2.log("deployer/bootstrap:", c.deployer);
        console2.log("opsAdmin:", c.opsAdmin);
        console2.log("chainid:", block.chainid);

        vm.startBroadcast(pk);
        D memory d = _deployAll(c);
        _wire(d, c);
        _seed(d, c);
        _handover(d, c);
        vm.stopBroadcast();

        if (broadcasting) {
            _writeManifest(d, c);
            console2.log("deployment complete; manifest at deployments/%s.json", vm.toString(block.chainid));
        } else {
            console2.log("DRY RUN (no --broadcast): nothing was deployed on chain.");
            console2.log("The manifest was deliberately NOT written -- simulated addresses are not real.");
            console2.log("Re-run with --broadcast (and FORCE_REDEPLOY=true if a manifest exists) to deploy.");
        }
    }

    /// @notice Resolves every principal from the environment. Extracted verbatim from `run()` so
    ///         the phased entrypoints below resolve principals identically, from one site.
    function _resolveCtx(uint256 pk) internal virtual returns (Ctx memory c) {
        c.deployer = vm.addr(pk);
        c.opsAdmin = vm.envAddress("OPS_ADMIN");
        require(c.opsAdmin != c.deployer, "Deploy: OPS_ADMIN must not be the deployer");
        c.frTreasury = vm.envOr("FR_TREASURY", c.opsAdmin);
        c.queueKeeper = vm.envOr("QUEUE_KEEPER", c.opsAdmin);
        c.feeRecipient = vm.envOr("FEE_RECIPIENT", c.frTreasury);
        c.anchorCurator = c.opsAdmin;
        c.attester1 = c.deployer;
        c.keepOpsAdmin = _resolveKeepOpsAdmin();
        // AUDIT FIX (C-01 round 2, reviewer issue A1). attester2's key was ALWAYS derived
        // from the deployer's own key, and `_wire` grants ATTESTER_ROLE to both, so one
        // secret satisfied the entire 2-of-n attestation quorum -- which feeds
        // `ReserveManager.totalBackingValue()`, the right-hand side of
        // `MintRedeemController._assertBacking`. The derived key stays the TESTNET default
        // (unchanged behaviour, per the binding owner decision), but a real independent
        // attester can now be supplied, and which one was used is RECORDED in the manifest so
        // production-shape validation can refuse to call a single-key quorum clean.
        address attester2Env = vm.envOr("ATTESTER_2", address(0));
        c.attester2Derived = attester2Env == address(0);
        c.attester2 =
            c.attester2Derived ? vm.addr(uint256(keccak256(abi.encode(pk, "fr-testnet-attester-2")))) : attester2Env;
    }

    // ── phased ceremony (2026-08-14) ─────────────────────────────────────
    //
    // WHY THIS EXISTS. `run()` performs deploy -> wire -> seed -> handover inside ONE broadcast,
    // so every transaction shares one `--gas-estimate-multiplier`. The seed is the only part that
    // moves tokens, and both of its transactions cross the USDfr/sUSDfr points hook, which
    // enforces an ABSOLUTE floor of `PointsHookGas.MINIMUM_GAS` (500,000) plus a retained
    // `POST_HOOK_RESERVE` (100,000). `forge script` sizes each transaction as
    // (simulated consumption x multiplier), and under simulation `gasleft()` is enormous, so the
    // floor never binds and the recorded consumption excludes it. The seed therefore needs a
    // multiplier far above what its own consumption implies, while the largest CREATE at that
    // multiplier exceeds the provider's per-transaction gas cap (measured on the Sepolia
    // endpoint: exactly 2**24 = 16,777,216 gas; 16,777,216 accepted, 18,000,000 rejected).
    //
    // Those two requirements leave at best a few percentage points of overlap, which is not a
    // ceremony design. Splitting gives each half its own budget. Phase 1 contains NO points-hook
    // transaction, so it runs at a low multiplier well clear of the cap; phase 2's largest
    // transaction is ~387k raw, so a high multiplier there stays an order of magnitude under it.
    //
    // Phase selection is deliberately `--sig`, NOT an environment variable. An env var exported
    // for one half of a copy-paste ceremony survives into the other half; `--sig` cannot be
    // inherited, and it leaves `run()`'s dispatch untouched so single-shot behaviour is
    // unchanged as a fact rather than as an argument.

    /// @notice Phase 1: deploy and wire only. Moves no tokens; crosses no points hook.
    /// @dev Writes the manifest so phase 2 can resolve addresses. The stack is NOT usable until
    ///      `runSeedAndHandoverPhase()` completes: bootstrap privileges are still held and the
    ///      vault is unseeded.
    function runBootstrapPhase() external virtual {
        require(block.chainid != 1, "MAINNET FORBIDDEN (CLAUDE.md prime directive 1)");
        if (_isResuming()) revert("Deploy: --resume forbidden; restart from a reviewed fresh deployment plan");

        bool broadcasting = _isBroadcasting();
        string memory manifestPath = _manifestPath();
        if (_manifestGuardTrips(broadcasting, vm.exists(manifestPath), _forceRedeploy())) {
            revert("manifest exists for this chain; set FORCE_REDEPLOY=true to replace (orphans the prior stack)");
        }

        uint256 pk = _deployerKey();
        Ctx memory c = _resolveCtx(pk);

        console2.log("PHASE 1 of 2 (bootstrap): deploy + wire. No seed, no handover.");
        console2.log("deployer/bootstrap:", c.deployer);
        console2.log("opsAdmin:", c.opsAdmin);
        console2.log("chainid:", block.chainid);

        vm.startBroadcast(pk);
        D memory d = _deployAll(c);
        _wire(d, c);
        vm.stopBroadcast();

        if (broadcasting) {
            _writeManifest(d, c);
            console2.log("PHASE 1 COMPLETE; manifest at deployments/%s.json", vm.toString(block.chainid));
            console2.log("The stack is NOT usable yet: the vault is unseeded and bootstrap privileges are held.");
            console2.log(
                "Run phase 2 next: forge script script/Deploy.s.sol --tc Deploy --sig 'runSeedAndHandoverPhase()'"
            );
        } else {
            console2.log("DRY RUN (no --broadcast): nothing was deployed on chain.");
        }
    }

    /// @notice Phase 2: seed the vault, then hand bootstrap authority to the timelock.
    /// @dev Reads the phase-1 manifest rather than deploying. Deliberately does NOT rewrite the
    ///      manifest: in a separate process `impls` is empty, and `_writeManifest` ends in a
    ///      whole-file `vm.writeJson`, so a rewrite would delete every `impl_*` record and
    ///      overwrite `deployedAtBlock` -- which `tools/reconcile-mainnet-deployment.mjs`
    ///      requires to equal (first receipt block - 1) from the PHASE 1 broadcast.
    function runSeedAndHandoverPhase() external virtual {
        require(block.chainid != 1, "MAINNET FORBIDDEN (CLAUDE.md prime directive 1)");
        if (_isResuming()) revert("Deploy: --resume forbidden; restart from a reviewed fresh deployment plan");

        string memory manifestPath = _manifestPath();
        require(vm.exists(manifestPath), "Deploy: no manifest; run runBootstrapPhase() first");

        uint256 pk = _deployerKey();
        Ctx memory c = _resolveCtx(pk);
        D memory d = _loadBootstrapped(manifestPath);

        // FAIL CLOSED. Seeding twice would mint a second permanent floor, and handing over twice
        // is not reachable (the roles are gone), so both are refused explicitly rather than left
        // to revert somewhere less legible.
        require(SUSDfr(d.vault).balanceOf(SEED_SINK) == 0, "Deploy: already seeded; phase 2 is not repeatable");
        require(
            ComplianceRegistry(d.compliance).hasRole(0x00, c.deployer),
            "Deploy: bootstrap authority already handed over; phase 2 cannot run"
        );

        console2.log("PHASE 2 of 2 (seed + handover). Manifest:", manifestPath);
        console2.log("deployer/bootstrap:", c.deployer);
        console2.log("chainid:", block.chainid);

        vm.startBroadcast(pk);
        _seed(d, c);
        _handover(d, c);
        vm.stopBroadcast();

        // Only the privilege-receipt fields are refreshed; every impl_* record and
        // deployedAtBlock from phase 1 survive. See `_refreshPrivilegeReceipt`.
        _refreshPrivilegeReceipt(d, c, manifestPath);
        console2.log("PHASE 2 COMPLETE. Seed placed, authority handed over, privilege receipt refreshed.");
    }

    /// @notice Refreshes ONLY the privilege-receipt fields after a phased handover.
    /// @dev Phase 1 writes the manifest BEFORE `_handover` runs, so `deployerCleanExceptAttester`
    ///      and the three `retainedPrivileges_*` enumerations record the PRE-handover posture and
    ///      then contradict on-chain state. `Validate.s.sol` rejects exactly that contradiction
    ///      ("manifest deployerCleanExceptAttester contradicts on-chain state"), which is how this
    ///      was caught. The object is rebuilt SEEDED FROM THE EXISTING FILE -- the pattern
    ///      `Handover.s.sol` uses -- so every `impl_*` record and `deployedAtBlock` survive
    ///      untouched; `_writeManifest` cannot be reused here because its `impls` array is empty in
    ///      a separate process. The write is then verified by re-reading, because a silently
    ///      dropped key would leave the manifest asserting a posture the chain contradicts.
    function _refreshPrivilegeReceipt(D memory d, Ctx memory c, string memory path) internal {
        (address[] memory targets, string[] memory names) = PrivilegeAudit.moduleSet(_auditTargets(d));
        bool clean = PrivilegeAudit.scan(targets, names, c.deployer, false).length == 0
            && PrivilegeAudit.scanTimelock(d.timelock, c.deployer, false).length == 0;

        string memory j = "phasedPrivilegeReceipt";
        vm.serializeJson(j, vm.readFile(path)); // seed with every existing field
        vm.serializeString(
            j, "retainedPrivileges_deployer", PrivilegeAudit.scanEverything(targets, names, d.timelock, c.deployer)
        );
        vm.serializeString(
            j, "retainedPrivileges_opsAdmin", PrivilegeAudit.scanEverything(targets, names, d.timelock, c.opsAdmin)
        );
        vm.serializeString(
            j,
            "retainedPrivileges_queueKeeper",
            PrivilegeAudit.scanEverything(targets, names, d.timelock, c.queueKeeper)
        );
        string memory out = vm.serializeBool(j, "deployerCleanExceptAttester", clean);
        vm.writeJson(out, path);

        string memory written = vm.readFile(path);
        require(
            vm.parseJsonBool(written, ".deployerCleanExceptAttester") == clean,
            "Deploy: privilege receipt refresh did not persist"
        );
        require(
            vm.parseJsonAddress(written, ".vault") == d.vault,
            "Deploy: privilege receipt refresh corrupted the manifest"
        );
    }

    /// @dev Resolves the phase-1 addresses the seed and handover need. Only the fields those two
    ///      steps read are loaded; anything absent would fail loudly at `vm.parseJsonAddress`.
    function _loadBootstrapped(string memory manifestPath) internal view returns (D memory d) {
        string memory m = vm.readFile(manifestPath);
        d.compliance = vm.parseJsonAddress(m, ".compliance");
        d.usdfr = vm.parseJsonAddress(m, ".usdfr");
        d.reserves = vm.parseJsonAddress(m, ".reserves");
        d.controller = vm.parseJsonAddress(m, ".controller");
        d.vault = vm.parseJsonAddress(m, ".vault");
        d.stable = vm.parseJsonAddress(m, ".stable");
        d.registry = vm.parseJsonAddress(m, ".registry");
        d.oracle = vm.parseJsonAddress(m, ".oracle");
        d.curator = vm.parseJsonAddress(m, ".curator");
        d.defaultManager = vm.parseJsonAddress(m, ".defaultManager");
        d.queue = vm.parseJsonAddress(m, ".queue");
        d.grove = vm.parseJsonAddress(m, ".grove");
        d.sGrove = vm.parseJsonAddress(m, ".sGrove");
        d.timelock = vm.parseJsonAddress(m, ".timelock");
        d.governor = vm.parseJsonAddress(m, ".governor");
        d.votesAggregator = vm.parseJsonAddress(m, ".votesAggregator");
        d.points = vm.parseJsonAddress(m, ".points");
        d.bridge = vm.parseJsonAddress(m, ".bridge");
        d.waterfall = vm.parseJsonAddress(m, ".waterfall");
        d.assessedImpairmentSource = vm.parseJsonAddress(m, ".assessedImpairmentSource");
        d.mtmExecutor = vm.parseJsonAddress(m, ".mtmExecutor");
    }

    // ── posture resolution (AUDIT FIX C-01) ──────────────────────────────

    /// @notice Chain-ids this repo treats as a testnet, where `KEEP_OPS_ADMIN` may default.
    /// @dev Sepolia (the live testnet per `deployments/11155111.json` and `QA.s.sol`) and the
    ///      local anvil/forge chain-id. Nothing else. Chain-id 1 is separately hard-reverted
    ///      in `run()` (CLAUDE.md prime directive 1) and that guard is unchanged.
    /// @param chainId The chain-id to classify.
    /// @return isTestnet True when the permissive default is allowed to apply.
    function _isKnownTestnet(uint256 chainId) internal pure returns (bool isTestnet) {
        return chainId == 11155111 // Ethereum Sepolia (the live testnet for this repo)
            || chainId == 31337 // anvil / forge
            || chainId == 17000 // Holesky
            || chainId == 84532 // Base Sepolia
            || chainId == 11155420 // OP Sepolia
            || chainId == 421614; // Arbitrum Sepolia
    }

    /// @notice Resolve the `keepOpsAdmin` posture, refusing to INHERIT it off a known testnet.
    /// @dev AUDIT FIX (C-01). `vm.envOr("KEEP_OPS_ADMIN", true)` made the permissive posture —
    ///      the deployer EOA keeping `DEFAULT_ADMIN_ROLE`, and therefore the ability to
    ///      `grantRole(MINTER_ROLE, self)` and mint unbacked USDfr — the DEFAULT on every
    ///      chain. The owner deliberately retains that posture on testnet and intends to
    ///      retain it during a hands-on prod-test window, so testnet behaviour is UNCHANGED:
    ///      the default still applies on Sepolia and anvil. Off a known testnet the variable
    ///      becomes MANDATORY (`vm.envBool` reverts when unset), so the permissive posture can
    ///      only ever be explicitly CHOSEN, never silently inherited. The owner can still
    ///      choose it by setting `KEEP_OPS_ADMIN=true`.
    /// @return keepOpsAdmin Whether the deployer/ops EOA retains `DEFAULT_ADMIN_ROLE`.
    function _resolveKeepOpsAdmin() internal view virtual returns (bool keepOpsAdmin) {
        if (_isKnownTestnet(block.chainid)) return vm.envOr("KEEP_OPS_ADMIN", true);
        // Reverts with a clear cheatcode error if unset — deliberate: no silent default here.
        return vm.envBool("KEEP_OPS_ADMIN");
    }

    // ── deployment ───────────────────────────────────────────────────────

    function _deployAll(Ctx memory c) internal returns (D memory d) {
        // governance skeleton first: modules take the timelock as UPGRADER at init
        address[] memory none = new address[](0);
        d.timelock = _proxy(
            "timelock",
            // AUDIT FIX (A-01): wrapped so the initialiser is locked on the implementation.
            address(new ForestRoadTimelock()),
            abi.encodeCall(
                TimelockControllerUpgradeable.initialize, (Config.TIMELOCK_MIN_DELAY, none, none, c.deployer)
            )
        );
        d.grove = _proxy(
            "grove",
            address(new GroveToken()),
            abi.encodeCall(GroveToken.initialize, (d.timelock, d.timelock, c.frTreasury))
        );
        // NOTE (ADR-0026, L-02): the Governor is deliberately NOT constructed here, even
        // though it belongs to the "governance skeleton". Its `IVotes` source is now the
        // GroveVotesAggregator, which needs `sGrove` — deployed far below — and
        // `GovernorVotes` fixes its token at `initialize` with NO setter. So the governor
        // moves to the end of this function, after sGrove. Nothing between here and there
        // reads `d.governor`; `_wire`/`_seed`/`_handover` all run after `_deployAll`.

        // Local/Sepolia harness asset. Production deployment must supply canonical USDC
        // to the same USDC-specific initializer; no generic stable registry exists.
        d.stable = _deployUSDC();

        // token layer (deployer = bootstrap admin; ops guardian; timelock upgrader)
        d.compliance = _proxy(
            "compliance",
            address(new ComplianceRegistry()),
            abi.encodeCall(ComplianceRegistry.initialize, (c.deployer, c.opsAdmin, d.timelock, c.feeRecipient))
        );
        d.usdfr = _proxy(
            "usdfr",
            address(new USDfr()),
            // minter placeholder = deployer; replaced by the controller grant in _wire
            abi.encodeCall(USDfr.initialize, (c.deployer, c.deployer, c.opsAdmin, d.timelock))
        );
        d.reserves = _proxy(
            "reserves",
            address(new ReserveManager()),
            abi.encodeCall(ReserveManager.initialize, (c.deployer, c.opsAdmin, c.opsAdmin, d.timelock, d.stable))
        );
        d.controller = _proxy(
            "controller",
            address(new MintRedeemController()),
            abi.encodeCall(
                MintRedeemController.initialize, (c.deployer, c.opsAdmin, d.timelock, d.usdfr, d.compliance, d.reserves)
            )
        );
        d.vault = _proxy(
            "vault",
            address(new SUSDfr()),
            abi.encodeCall(
                SUSDfr.initialize, (c.deployer, c.opsAdmin, d.timelock, d.usdfr, d.compliance, c.feeRecipient)
            )
        );
        d.points = _proxy(
            "points",
            address(new PointsModule()),
            abi.encodeCall(PointsModule.initialize, (c.deployer, d.timelock, d.compliance, d.vault, d.usdfr))
        );

        // collateral + attestation
        d.registry = _proxy(
            "registry",
            address(new CollateralRegistry()),
            abi.encodeCall(CollateralRegistry.initialize, (c.deployer, d.timelock))
        );
        d.oracle = _proxy(
            "oracle",
            address(new AttestationOracle()),
            abi.encodeCall(AttestationOracle.initialize, (c.deployer, c.opsAdmin, d.timelock))
        );
        d.bridge = _proxy(
            "bridge",
            address(new ClaimBridge()),
            abi.encodeCall(ClaimBridge.initialize, (c.deployer, c.opsAdmin, d.timelock, d.registry, d.oracle))
        );

        // credit + liquidity + backstop
        d.curator = _proxy(
            "curator",
            address(new CuratorModule()),
            abi.encodeCall(CuratorModule.initialize, (c.deployer, c.opsAdmin, d.timelock, d.usdfr, d.registry, d.vault))
        );
        d.waterfall = _proxy(
            "waterfall",
            address(new WaterfallEngine()),
            abi.encodeCall(
                WaterfallEngine.initialize,
                (
                    c.deployer,
                    c.opsAdmin,
                    d.timelock,
                    WaterfallEngine.InitModules({
                        bridge: d.bridge,
                        registry: d.registry,
                        reserves: d.reserves,
                        controller: d.controller,
                        vault: d.vault,
                        feeRecipient: c.feeRecipient,
                        oracle: d.oracle
                    })
                )
            )
        );
        d.defaultManager = _proxy(
            "defaultManager",
            address(new DefaultManager()),
            abi.encodeCall(
                DefaultManager.initialize,
                (
                    c.deployer,
                    c.opsAdmin,
                    d.timelock,
                    DefaultManager.InitModules({
                        bridge: d.bridge,
                        registry: d.registry,
                        reserves: d.reserves,
                        controller: d.controller,
                        curator: d.curator,
                        oracle: d.oracle,
                        usdfr: d.usdfr,
                        vault: d.vault
                    })
                )
            )
        );
        d.assessedImpairmentSource = _proxy(
            "assessedImpairmentSource",
            address(new AssessedImpairmentSource()),
            abi.encodeCall(AssessedImpairmentSource.initialize, (c.deployer, d.timelock, d.defaultManager))
        );
        d.queue = _proxy(
            "queue",
            address(new RedemptionQueue()),
            abi.encodeCall(
                RedemptionQueue.initialize, (c.deployer, c.opsAdmin, d.timelock, d.vault, d.usdfr, d.reserves)
            )
        );
        d.sGrove = _proxy(
            "sGrove",
            address(new SGrove()),
            abi.encodeCall(SGrove.initialize, (c.deployer, c.opsAdmin, d.timelock, d.grove, d.usdfr, d.vault))
        );

        // governance vote source + governor (ADR-0026, L-02) — LAST, because the
        // aggregator needs both vote sources and the governor's token is immutable.
        // The aggregator is a plain immutable contract, NOT a proxy: it holds no roles
        // and no state, and freezing it freezes the composition rule the Governor's
        // trust base rests on (sum for votes, GROVE-only for the quorum denominator).
        // Its constructor reverts unless BOTH sources report "mode=timestamp".
        d.votesAggregator = address(new GroveVotesAggregator(d.grove, d.sGrove));
        d.governor = _proxy(
            "governor",
            address(new FRGovernor()),
            abi.encodeCall(
                FRGovernor.initialize, (IVotes(d.votesAggregator), TimelockControllerUpgradeable(payable(d.timelock)))
            )
        );

        // Roleless, immutable MTM transaction boundary. Kept LAST so adding the executor does
        // not perturb any pre-existing module CREATE address; the mainnet receipt validates its
        // one additional CREATE immediately after the governor proxy.
        d.mtmExecutor = address(new MtmAtomicExecutor(d.oracle, d.defaultManager));
    }

    // ── wiring (mirrors GovernanceFixture; validated post-deploy) ────────

    function _wire(D memory d, Ctx memory c) internal {
        // timelock: governor proposes/cancels; execution is open
        TimelockControllerUpgradeable tl = TimelockControllerUpgradeable(payable(d.timelock));
        tl.grantRole(tl.PROPOSER_ROLE(), d.governor);
        tl.grantRole(tl.CANCELLER_ROLE(), d.governor);
        tl.grantRole(tl.EXECUTOR_ROLE(), address(0));

        // token layer
        USDfr(d.usdfr).grantRole(Roles.MINTER_ROLE, d.controller);
        USDfr(d.usdfr).renounceRole(Roles.MINTER_ROLE, c.deployer); // drop the placeholder
        ReserveManager(d.reserves).grantRole(Roles.CONTROLLER_ROLE, d.controller);
        ReserveManager(d.reserves).grantRole(Roles.RESERVE_ADMIN_ROLE, c.deployer);
        SUSDfr(d.vault).setRedemptionQueue(d.queue);
        SUSDfr(d.vault).setPointsModule(d.points);
        USDfr(d.usdfr).setPointsModule(d.points); // USDfr holders accrue points in lieu of yield (ADR-0016)
        // AUDIT FIX (pre-redeploy): wire the compliance module into USDfr so the SANCTIONS
        // freeze in USDfr._update is actually enforced. Since the 2026-07-14 directive made
        // canTransfer the SOLE on-chain USDfr transfer gate, an unwired module (address(0))
        // would skip the sanctions check entirely and leave USDfr transfers ungated.
        USDfr(d.usdfr).setComplianceModule(d.compliance);
        // P-01: curator first-loss capital accrues points at the curator multiple. Wire the
        // two-way link (points learns its curator caller; curator learns the hook).
        PointsModule(d.points).setCuratorModule(d.curator);
        CuratorModule(d.curator).setPointsModule(d.points);

        // Genesis classes. The testnet implementation below returns the deliberately
        // permissive ramp posture. DeployMainnet overrides the parameter hooks with the
        // reviewed production tuple, so the production path can never inherit testnet's
        // 100% concentration settings.
        CollateralRegistry reg = CollateralRegistry(d.registry);
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            reg.setClass(classId, _classParams(classId));
        }

        // RAMP POSTURE (Forest Road, 2026-07-21): the borrower and state dimensions are opened
        // too. Leaving them at 1500/2500 while the class limits are 100% would just move the
        // binding constraint rather than remove it -- a single-borrower vertical would still be
        // capped at 15% of the book. See `Config.RAMP_CONCENTRATION_LIMIT_BPS` for the two
        // consequences (telemetry goes dark; ratcheting down later is a cliff).
        reg.setBorrowerLimit(_borrowerLimitBps());
        reg.setStateLimit(_stateLimitBps());
        reg.setConcentrationFloor(_concentrationFloor());

        // mint gates per class
        ClaimBridge br = ClaimBridge(d.bridge);
        uint256 bitAssignment = 1 << uint256(IAttestationOracle.AttestationKind.AssignmentExecuted);
        uint256 bitUcc = 1 << uint256(IAttestationOracle.AttestationKind.UCCFiled);
        uint256 bitCredit = 1 << uint256(IAttestationOracle.AttestationKind.CreditIssued);
        uint256 bitValuation = 1 << uint256(IAttestationOracle.AttestationKind.Valuation);
        br.setRequiredMintAttestations(Config.CLASS_FILM_TAX_CREDITS, bitAssignment | bitUcc | bitCredit);
        br.setRequiredMintAttestations(Config.CLASS_RENEWABLE_ENERGY, bitAssignment | bitUcc | bitCredit);
        br.setRequiredMintAttestations(Config.CLASS_LIFE_SCIENCES, bitAssignment | bitUcc | bitCredit);
        br.setRequiredMintAttestations(Config.CLASS_REAL_ESTATE, bitAssignment | bitUcc | bitCredit);
        // AUDIT FIX (H-4): CreditIssued is the TERMS quorum (the payload the mint gate binds
        // the facility's obligor/class/amount/tenor/lien to) and is mandatory on every gate.
        br.setRequiredMintAttestations(Config.CLASS_DIGITAL_ASSETS, bitAssignment | bitValuation | bitCredit);

        // production role topology (see CreditLayerFixture — the tested spec)
        br.grantRole(Roles.ORIGINATOR_ROLE, c.opsAdmin);
        br.grantRole(Roles.CREDIT_ROLE, d.waterfall);
        br.grantRole(Roles.CREDIT_ROLE, d.defaultManager);
        reg.grantRole(Roles.CREDIT_ROLE, d.bridge);
        reg.grantRole(Roles.CREDIT_ROLE, d.waterfall);
        reg.grantRole(Roles.CREDIT_ROLE, d.defaultManager);
        ReserveManager(d.reserves).grantRole(Roles.CREDIT_ROLE, d.waterfall);
        ReserveManager(d.reserves).grantRole(Roles.CREDIT_ROLE, d.defaultManager);
        // AUDIT FIX (R16-M1) — LEAST PRIVILEGE ON THE CONTROLLER'S SUPPLY POWERS. This block used
        // to grant CREDIT_ROLE (which then gated BOTH `mintYield` and `burnLoss`) to the engine
        // AND the default manager, so each held both halves of the burn-then-mint composition
        // that is arbitrary confiscation. `burnLoss` now sits behind `LOSS_BURNER_ROLE`, and the
        // grants are exactly what each module actually calls: the engine only ever calls
        // `mintYield`; the default manager burns credit-layer losses, while ReserveManager burns
        // the arm-bound custody cascade. Neither module receives CREDIT_ROLE here.
        MintRedeemController(d.controller).grantRole(Roles.CREDIT_ROLE, d.waterfall); // mintYield only
        MintRedeemController(d.controller).grantRole(Roles.LOSS_BURNER_ROLE, d.defaultManager); // burnLoss only
        MintRedeemController(d.controller).grantRole(Roles.LOSS_BURNER_ROLE, d.reserves); // custody cascade only
        // AUDIT FIX (R16-M1). The credit layer may only move supply between these named
        // endpoints. `mintYield` destinations: the senior vault (interest) and the fee recipient
        // (protocol and origination fees). `burnLoss` sources: the default manager, which burns
        // junior capital it has already RECEIVED into itself, and the vault (cascade layer 3,
        // pro-rata by construction). Nothing else — in particular no user address — is reachable.
        MintRedeemController(d.controller).setYieldSink(d.vault, true);
        MintRedeemController(d.controller).setYieldSink(c.feeRecipient, true);
        MintRedeemController(d.controller).setLossSource(d.defaultManager, true);
        MintRedeemController(d.controller).setLossSource(d.reserves, true);
        MintRedeemController(d.controller).setLossSource(d.vault, true);
        CuratorModule(d.curator).grantRole(Roles.CREDIT_ROLE, d.defaultManager);
        CuratorModule(d.curator).grantRole(Roles.CREDIT_ROLE, d.reserves);
        AttestationOracle(d.oracle).grantRole(Roles.CREDIT_ROLE, d.waterfall);
        AttestationOracle(d.oracle).grantRole(Roles.CREDIT_ROLE, d.defaultManager);
        AttestationOracle(d.oracle).grantRole(Roles.CREDIT_ROLE, d.bridge);
        SGrove(d.sGrove).grantRole(Roles.CREDIT_ROLE, d.defaultManager);
        SGrove(d.sGrove).grantRole(Roles.CREDIT_ROLE, d.reserves);
        // AUDIT FIX (D7-01): `closeEpoch` is keeper-gated. Grant TWO holders — the hot keeper
        // and `opsAdmin` as a manual backstop — so a keeper outage degrades to manual operation
        // rather than freezing the protocol's only senior exit. See Roles.SETTLEMENT_KEEPER_ROLE.
        // AUDIT FIX (D7-01 round 5, BLOCKING): fail closed on EVERY path. `_mainnetContext` once
        // omitted `queueKeeper` entirely, so this granted the role to address(0) and the deploy
        // still validated green over a senior exit with one usable holder. The guard lives here,
        // not only in the mainnet validator, because Deploy is reached by the testnet path and by
        // every fork rehearsal too — all of which rehearsed the defective topology.
        require(c.queueKeeper != address(0), "Deploy: zero settlement keeper");
        RedemptionQueue(d.queue).grantRole(Roles.SETTLEMENT_KEEPER_ROLE, c.queueKeeper);
        RedemptionQueue(d.queue).grantRole(Roles.SETTLEMENT_KEEPER_ROLE, c.opsAdmin);
        SUSDfr(d.vault).grantRole(Roles.FEE_ACCOUNTING_ROLE, d.curator);
        SUSDfr(d.vault).grantRole(Roles.FEE_ACCOUNTING_ROLE, d.sGrove);
        SUSDfr(d.vault).grantRole(Roles.FEE_ACCOUNTING_ROLE, d.defaultManager);
        WaterfallEngine(d.waterfall).grantRole(Roles.SERVICER_ROLE, c.opsAdmin);
        DefaultManager(d.defaultManager).grantRole(Roles.SERVICER_ROLE, c.opsAdmin);
        ReserveManager(d.reserves).setLossController(d.controller);
        ReserveManager(d.reserves).setLossAbsorber(d.defaultManager);
        // ── AUDIT FIX (R6-CF1): the reserve-CUSTODY arm of the curator withdrawal freeze ──
        // MANDATORY WIRING, validated post-deploy. `CuratorModule.custodyFreezeActive()` reads as
        // TRUE while no ReserveManager is wired, so omitting this does not open a hole — it bricks
        // curator withdrawals instead. `setGovernor` is what keeps the guardian pre-arm longer
        // than the LIVE governance path after governance retunes any of votingDelay /
        // votingPeriod / timelock minDelay; without it the Config launch constants stand as the
        // floor, which goes stale silently.
        CuratorModule(d.curator).setReserveManager(d.reserves);
        ReserveManager(d.reserves).setReserveLossModules(d.curator, d.sGrove, d.vault, d.governor, d.timelock);
        DefaultManager(d.defaultManager).setBackstop(d.sGrove);
        CuratorModule(d.curator).setGovernor(d.governor);
        // ── ADR-0022 Option Y + ADR-0023 (senior-side wiring) ─────────────
        // The engine clears a facility's unrealized-impairment mark when a defaulted loan
        // recovers in full (onDefaultResolved), and notifies the vault when yield lands.
        // At launch notifyYield recognizes and checkpoints it immediately; governance can
        // enable optional ADR-0023 smoothing later. Both calls are CREDIT_ROLE-gated.
        // Admin SETTERS rather than init args, because the DefaultManager is constructed
        // AFTER the engine and the vault -- an init arg would force a circular ordering.
        DefaultManager(d.defaultManager).grantRole(Roles.CREDIT_ROLE, d.waterfall); // onDefaultResolved
        SUSDfr(d.vault).grantRole(Roles.CREDIT_ROLE, d.waterfall); // notifyYield (ADR-0023)
        WaterfallEngine(d.waterfall).setDefaultManager(d.defaultManager); // ADR-0022 resolve hook
        SUSDfr(d.vault).setImpairmentSource(d.assessedImpairmentSource); // ADR-0027 assessed recovery NAV

        // Attestation layer. Testnet defaults attester #1 to the deployer; the dedicated
        // mainnet path requires two independent signer addresses and never grants the
        // bootstrap deployer this role.
        AttestationOracle(d.oracle).grantRole(Roles.ATTESTER_ROLE, _attester1(c));
        AttestationOracle(d.oracle).grantRole(Roles.ATTESTER_ROLE, c.attester2);

        // anchor curator approved on all five classes (ADR-0004)
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            CuratorModule(d.curator).setCuratorApproved(classId, _anchorCurator(c), true);
        }

        // AUDIT FIX (F1/F2): mark every internal-value-moving protocol address as
        // compliance-exempt, so the compliance capability (once wired into USDfr) can
        // never brick the never-pausable cascade / redemption / reward-and-coverage
        // delivery / fee routing by blocking a module.
        ComplianceRegistry cr = ComplianceRegistry(d.compliance);
        cr.setProtocolExempt(d.vault, true);
        cr.setProtocolExempt(d.queue, true);
        cr.setProtocolExempt(d.reserves, true);
        cr.setProtocolExempt(d.controller, true);
        cr.setProtocolExempt(d.curator, true);
        cr.setProtocolExempt(d.sGrove, true);
        cr.setProtocolExempt(d.defaultManager, true);
        cr.setProtocolExempt(d.waterfall, true);
        cr.setProtocolExempt(SEED_SINK, true); // nominal dead seed never earns points
    }

    // ── seed (ADR-0005: blunt vault inflation attacks with a PERMANENT floor) ──

    /// @dev AUDIT FIX (DS-6): the anti-inflation seed shares are deposited to a
    ///      permanently-uncontrolled dead address (KYC'd only so `_deposit` accepts it),
    ///      so the first-loss floor can never be withdrawn — unlike seeding to the
    ///      deployer, which left the floor removable. The deployer's bootstrap KYC (only
    ///      needed to mint the seed) is revoked in `_handover` on the prod-shaped run.
    address internal constant SEED_SINK = 0x000000000000000000000000000000000000dEaD;

    function _seed(D memory d, Ctx memory c) internal {
        ComplianceRegistry cr = ComplianceRegistry(d.compliance);
        // AUDIT FIX (R5 H-1): the seed is broadcast from the deployer, but `setAllowed`
        // is COMPLIANCE_ADMIN-gated and init grants that role to `opsAdmin`. On a
        // prod-shaped deploy (opsAdmin != deployer) the deployer lacks it and `_seed`
        // reverted — the production deploy path could never execute. The deployer holds
        // DEFAULT_ADMIN (init `admin`), so grant itself the role temporarily to seed;
        // `_handover` renounces it. Idempotent when opsAdmin == deployer (testnet).
        cr.grantRole(Roles.COMPLIANCE_ADMIN_ROLE, c.deployer);
        cr.setAllowed(c.deployer, true); // bootstrap KYC to mint the seed
        cr.setAllowed(SEED_SINK, true); // KYC the sink so the vault accepts the deposit
        uint256 seedUSDCUnits = _seedUSDCUnits();
        _fundSeedUSDC(d.stable, c.deployer, seedUSDCUnits);
        IERC20(d.stable).approve(d.controller, seedUSDCUnits);
        uint256 seedUSDfr = MintRedeemController(d.controller).mint(seedUSDCUnits);
        IERC20(d.usdfr).approve(d.vault, seedUSDfr);
        SUSDfr(d.vault).deposit(seedUSDfr, SEED_SINK); // nominal permanently locked floor

        // GroveToken.initialize self-delegates the genesis treasury before any handover can
        // occur. `_assertGovernanceLive` independently verifies the effective wallet/staked
        // voting power immediately before bootstrap authority is surrendered.
    }

    /// @dev Local deployments mint their mock USDC. Fork fixtures override this hook to fund
    ///      canonical USDC without assuming the live token implements a faucet.
    function _fundSeedUSDC(address asset, address recipient, uint256 amount) internal virtual {
        MockERC20(asset).mint(recipient, amount);
    }

    function _seedUSDCUnits() internal pure virtual returns (uint256) {
        return 10e6;
    }

    // ── handover (bootstrap privileges dropped; timelock rules) ─────────

    function _handover(D memory d, Ctx memory c) internal {
        // This MUST remain the first operation. A failed liveness check must leave every
        // bootstrap privilege intact so the deployment can be corrected or abandoned safely.
        _assertGovernanceLive(d, c);

        // RESERVE_ADMIN can recognize a USDC custody write-down, a governance-level loss
        // decision. Move it to the timelock BEFORE the DEFAULT_ADMIN handover below (this
        // grant needs the deployer's DEFAULT_ADMIN on reserves, which _handoverOne renounces on
        // the prod shape). On prod, drop both EOAs (deployer's _wire self-grant and the ops
        // EOA's init grant) so no EOA can approve a backing stable. On a retained-ops testnet,
        // retain only the nominated ops EOA: a distinct bootstrap deployer is not an operator
        // and must not keep `_wire`'s temporary grant.
        {
            ReserveManager rm = ReserveManager(d.reserves);
            rm.grantRole(Roles.RESERVE_ADMIN_ROLE, d.timelock);
            bool deployerIsRetainedOps = c.keepOpsAdmin && c.opsAdmin == c.deployer;
            if (!deployerIsRetainedOps && rm.hasRole(Roles.RESERVE_ADMIN_ROLE, c.deployer)) {
                rm.renounceRole(Roles.RESERVE_ADMIN_ROLE, c.deployer);
            }
            if (!c.keepOpsAdmin && c.opsAdmin != c.deployer && rm.hasRole(Roles.RESERVE_ADMIN_ROLE, c.opsAdmin)) {
                rm.revokeRole(Roles.RESERVE_ADMIN_ROLE, c.opsAdmin);
            }
        }
        address[] memory modules_ = PrivilegeTopology.deployHandoverTargets(_auditTargets(d));
        for (uint256 i = 0; i < modules_.length; ++i) {
            _handoverOne(modules_[i], d.timelock, c);
        }
        // AUDIT FIX (DS-6 + R5 H-1): on the production-shaped handover, revoke the deployer's
        // bootstrap KYC (only needed to mint the locked seed) and, WHEN THE DEPLOYER IS NOT
        // ALSO THE RETAINED OPS ADMIN, renounce the temporary COMPLIANCE_ADMIN role `_seed`
        // self-granted. A split-key testnet keeps the nominated ops EOA, not the bootstrap
        // deployer. The ops admin keeps COMPLIANCE_ADMIN by design (it is the operational KYC
        // role, granted at `initialize`); see the M-6 note below for why the renounce cannot be
        // unconditional when both identities are the same address.
        if (!c.keepOpsAdmin || c.opsAdmin != c.deployer) {
            ComplianceRegistry cr = ComplianceRegistry(d.compliance);
            // DELIBERATE DIVERGENCE from `Handover._executeHandoverAs` (Handover.s.sol), which
            // SKIPS this revoke when `opsAdmin == deployer` because "that address stays an
            // operator". Here it is unconditional, and that is the stricter, correct side of
            // the divergence: this allowlist entry was granted seconds earlier by `_seed`
            // purely to mint the locked genesis seed (DS-6), so a fresh deployment must never
            // finish with the bootstrap key holding KYC it was only ever lent. The cost when
            // ops == deployer is that the sole operator must re-allowlist ITSELF before it can
            // mint — which it can, because the M-6 guard below leaves it holding
            // COMPLIANCE_ADMIN. `Handover` runs against an ALREADY-LIVE stack where the same
            // address may have been legitimately allowlisted as an operator since genesis, so
            // it cannot assume the entry is bootstrap residue. Both are pinned by tests
            // (`ProdDeploy.t.sol` asserts `!isAllowed(deployer)` here).
            cr.setAllowed(c.deployer, false);
            // AUDIT FIX (M-6). The renounce is guarded on `opsAdmin != deployer`. When
            // `OPS_ADMIN` is unset it DEFAULTS to the deployer, so `initialize`'s
            // COMPLIANCE_ADMIN grant to `opsAdmin` and `_seed`'s temporary self-grant to
            // `deployer` are the SAME grant to the SAME address. Renouncing it on the
            // production-shaped rehearsal therefore left the ComplianceRegistry with NO
            // COMPLIANCE_ADMIN holder at all: nobody could ever be KYC'd, so the stack could
            // not mint, stake or redeem, and no `setAllowed`/`setSanctioned` was reachable
            // without a governance proposal to re-grant the role. `Validate` printed PASSED
            // over it. With ops == deployer that address IS the compliance operator, and it
            // keeps the role exactly as a separate ops EOA would; only the deployer's
            // bootstrap KYC (above) is revoked either way.
            if (c.opsAdmin != c.deployer && cr.hasRole(Roles.COMPLIANCE_ADMIN_ROLE, c.deployer)) {
                cr.renounceRole(Roles.COMPLIANCE_ADMIN_ROLE, c.deployer);
            }
        }
        // finally: the deployer's temporary timelock admin goes away
        TimelockControllerUpgradeable tl = TimelockControllerUpgradeable(payable(d.timelock));
        tl.renounceRole(tl.DEFAULT_ADMIN_ROLE(), c.deployer);
    }

    /// @dev Refuses to make the timelock sole authority unless the Governor can schedule and
    ///      cancel pre-execution operations, execution is live, and the treasury's active
    ///      wallet/staked delegation can meet the configured launch quorum. This is intentionally
    ///      independent of GroveToken's
    ///      initializer self-delegation so a later deployment refactor cannot silently restore
    ///      the governance-dead handover.
    function _assertGovernanceLive(D memory d, Ctx memory c) internal view {
        TimelockControllerUpgradeable tl = TimelockControllerUpgradeable(payable(d.timelock));
        if (!tl.hasRole(tl.PROPOSER_ROLE(), d.governor)) revert DeployTimelockNotLive(d.timelock);
        if (!tl.hasRole(tl.CANCELLER_ROLE(), d.governor)) revert DeployTimelockNotLive(d.timelock);
        if (!tl.hasRole(tl.EXECUTOR_ROLE(), address(0)) && !tl.hasRole(tl.EXECUTOR_ROLE(), d.governor)) {
            revert DeployTimelockNotLive(d.timelock);
        }

        address groveDelegatee = IVotes(d.grove).delegates(c.frTreasury);
        address sGroveDelegatee = IVotes(d.sGrove).delegates(c.frTreasury);
        uint256 votingPower = IVotes(d.votesAggregator).getVotes(groveDelegatee);
        if (sGroveDelegatee != groveDelegatee) {
            votingPower += IVotes(d.votesAggregator).getVotes(sGroveDelegatee);
        }

        uint256 quorumPower = Config.GROVE_INITIAL_SUPPLY * Config.GOV_QUORUM_FRACTION / 100;
        uint256 requiredVotingPower = FRGovernor(payable(d.governor)).proposalThreshold();
        if (quorumPower > requiredVotingPower) requiredVotingPower = quorumPower;
        if (votingPower < requiredVotingPower) {
            revert DeployGovernanceDeadOnArrival(d.grove, c.frTreasury, votingPower, requiredVotingPower);
        }
    }

    function _handoverOne(address module_, address timelock, Ctx memory c) internal {
        ComplianceRegistry m = ComplianceRegistry(module_); // any AccessControl works
        m.grantRole(bytes32(0), timelock);

        bool separateOps = c.opsAdmin != c.deployer;
        if (c.keepOpsAdmin && separateOps) m.grantRole(bytes32(0), c.opsAdmin);

        // SEAM-1: enumeration is also the drop policy. Before this, `_handoverOne` moved only
        // DEFAULT_ADMIN, so an enumerated authority role granted before handover survived even
        // though the post-deploy audit knew its name. Do not rely on the generated set's order:
        // non-admin authority is removed first and DEFAULT_ADMIN is handled explicitly below.
        (bytes32[] memory authority,) = PrivilegeTopology.authorityRoleSet();
        if (!c.keepOpsAdmin && separateOps) {
            _dropNonAdminRoles(m, authority, c.opsAdmin, false);
            if (m.hasRole(bytes32(0), c.opsAdmin)) m.revokeRole(bytes32(0), c.opsAdmin);
        }
        if (!c.keepOpsAdmin || separateOps) {
            _dropNonAdminRoles(m, authority, c.deployer, true);
            m.renounceRole(bytes32(0), c.deployer);
        }
        // when opsAdmin == deployer and keepOpsAdmin=true, the deployer keeps admin (TESTNET
        // concession, manifest-flagged) so QA can operate without proposals.
    }

    /// @dev Drop every role except DEFAULT_ADMIN, whose ordering is handled explicitly by
    ///      `_handoverOne`. `authorityRoleSet` is a set, so correctness must not depend on where
    ///      its admin entry happens to appear.
    function _dropNonAdminRoles(ComplianceRegistry m, bytes32[] memory roles, address holder, bool renounce) internal {
        for (uint256 i = 0; i < roles.length; ++i) {
            bytes32 role = roles[i];
            if (role == bytes32(0) || !m.hasRole(role, holder)) continue;
            if (renounce) m.renounceRole(role, holder);
            else m.revokeRole(role, holder);
        }
    }

    // ── manifest ─────────────────────────────────────────────────────────

    function _writeManifest(D memory d, Ctx memory c) internal virtual {
        string memory j = "manifest";
        vm.serializeUint(j, "chainId", block.chainid);
        vm.serializeUint(j, "deployedAtBlock", block.number);
        vm.serializeAddress(j, "deployer", c.deployer);
        vm.serializeAddress(j, "opsAdmin", c.opsAdmin);
        vm.serializeAddress(j, "queueKeeper", c.queueKeeper);
        vm.serializeAddress(j, "frTreasury", c.frTreasury);
        vm.serializeAddress(j, "feeRecipient", c.feeRecipient);
        vm.serializeAddress(j, "anchorCurator", _anchorCurator(c));
        vm.serializeAddress(j, "attester1", _attester1(c));
        vm.serializeAddress(j, "attester2", c.attester2);
        vm.serializeBool(j, "keepOpsAdmin", c.keepOpsAdmin);
        if (!_isProductionProfile()) {
            vm.serializeBool(j, "TESTNET_keepOpsAdmin", c.keepOpsAdmin);
        }
        // AUDIT FIX (C-01 round 2): record whether attester2's key is derived from the
        // deployer's, so validation can tell a real 2-of-n quorum from a single-key one.
        vm.serializeBool(j, "attester2_DERIVED_FROM_DEPLOYER_KEY", c.attester2Derived);
        // AUDIT FIX (C-01): a durable, machine-readable receipt of the deploy's actual
        // privilege posture. Without this, a manifest from a retained-hot-key deploy was
        // indistinguishable from one produced by a clean handover. Enumerated with the same
        // library `Validate.s.sol` prints, so console and manifest can never disagree.
        (address[] memory targets, string[] memory names) = PrivilegeAudit.moduleSet(_auditTargets(d));
        string[] memory deployerHeld = PrivilegeAudit.scanEverything(targets, names, d.timelock, c.deployer);
        string[] memory opsHeld = PrivilegeAudit.scanEverything(targets, names, d.timelock, c.opsAdmin);
        string[] memory queueKeeperHeld = PrivilegeAudit.scanEverything(targets, names, d.timelock, c.queueKeeper);
        vm.serializeString(j, "retainedPrivileges_deployer", deployerHeld);
        vm.serializeString(j, "retainedPrivileges_opsAdmin", opsHeld);
        vm.serializeString(j, "retainedPrivileges_queueKeeper", queueKeeperHeld);
        // The attester set is a Part 11 human gate, not something a deploy/handover can
        // rotate, so it is the one documented exception to "deployer holds nothing".
        vm.serializeBool(
            j,
            "deployerCleanExceptAttester",
            PrivilegeAudit.scan(targets, names, c.deployer, false).length == 0
                && PrivilegeAudit.scanTimelock(d.timelock, c.deployer, false).length == 0
        );
        vm.serializeAddress(j, "compliance", d.compliance);
        vm.serializeAddress(j, "usdfr", d.usdfr);
        vm.serializeAddress(j, "reserves", d.reserves);
        vm.serializeAddress(j, "controller", d.controller);
        vm.serializeAddress(j, "vault", d.vault);
        vm.serializeAddress(j, "points", d.points);
        vm.serializeAddress(j, "registry", d.registry);
        vm.serializeAddress(j, "oracle", d.oracle);
        vm.serializeAddress(j, "bridge", d.bridge);
        vm.serializeAddress(j, "curator", d.curator);
        vm.serializeAddress(j, "waterfall", d.waterfall);
        vm.serializeAddress(j, "defaultManager", d.defaultManager);
        vm.serializeAddress(j, "mtmExecutor", d.mtmExecutor);
        vm.serializeAddress(j, "assessedImpairmentSource", d.assessedImpairmentSource);
        vm.serializeAddress(j, "queue", d.queue);
        vm.serializeAddress(j, "grove", d.grove);
        vm.serializeAddress(j, "sGrove", d.sGrove);
        vm.serializeAddress(j, "timelock", d.timelock);
        vm.serializeAddress(j, "governor", d.governor);
        vm.serializeAddress(j, "votesAggregator", d.votesAggregator);
        // AUDIT FIX (C-01 round 2, reviewer issue A5): write a shape-independent `.stable`
        // key alongside the historical one, so consumers (Validate, Handover) never
        // hard-depend on a key that only exists because this deploy mocks the stablecoin.
        if (!_isProductionProfile()) {
            vm.serializeAddress(j, "stable_TESTNET_MOCK", d.stable);
        }
        // AUDIT FIX (deploy tooling, item 7b): record the IMPLEMENTATION behind every proxy.
        // Only proxies were written, so Etherscan verification and any future upgrade had to
        // rediscover the logic contracts by reading each proxy's ERC-1967 slot by hand.
        // Flat `impl_<name>` keys (not a nested object) so a consumer reading `.impl_usdfr`
        // cannot be broken by JSON-nesting behaviour.
        for (uint256 i = 0; i < impls.length; ++i) {
            vm.serializeAddress(j, string.concat("impl_", impls[i].name), impls[i].addr);
        }
        string memory out = vm.serializeAddress(j, "stable", d.stable);
        vm.writeJson(out, _manifestPath());
    }

    /// @notice The AccessControl-bearing modules scanned for retained privilege, in the
    ///         order `PrivilegeAudit.moduleSet` names them.
    /// @dev Shared shape with `Validate.s.sol` so the manifest receipt and the console
    ///      `RETAINED PRIVILEGE` block enumerate exactly the same surface.
    /// @param d The deployed addresses.
    /// @return targets The named module addresses in canonical order.
    function _auditTargets(D memory d) internal pure returns (PrivilegeTopology.ModuleAddresses memory targets) {
        return PrivilegeTopology.ModuleAddresses({
            compliance: d.compliance,
            usdfr: d.usdfr,
            reserves: d.reserves,
            controller: d.controller,
            vault: d.vault,
            points: d.points,
            registry: d.registry,
            oracle: d.oracle,
            bridge: d.bridge,
            curator: d.curator,
            waterfall: d.waterfall,
            defaultManager: d.defaultManager,
            assessedImpairmentSource: d.assessedImpairmentSource,
            queue: d.queue,
            sGrove: d.sGrove,
            grove: d.grove,
            timelock: d.timelock
        });
    }

    function _receivable(string memory name, uint16 maxLtv, uint64 maxMaturity, uint16 concLimit)
        internal
        pure
        returns (ICollateralRegistry.ClassParams memory)
    {
        return ICollateralRegistry.ClassParams({
            name: name,
            model: ICollateralRegistry.CollateralModel.Receivable,
            active: true,
            maxLtvBps: maxLtv,
            maxMaturity: maxMaturity,
            concentrationLimitBps: concLimit,
            marginCallLtvBps: 0,
            liquidationLtvBps: 0,
            maxMarkAge: 0
        });
    }

    /// @dev Testnet class tuple. The production deployer overrides this hook with the
    ///      constrained mainnet-v1 tuple used throughout the audited fixtures.
    function _classParams(uint256 classId) internal view virtual returns (ICollateralRegistry.ClassParams memory) {
        if (classId == Config.CLASS_FILM_TAX_CREDITS) {
            return _receivable("Film & TV Tax Credits", 8000, 730 days, Config.RAMP_CONCENTRATION_LIMIT_BPS);
        }
        if (classId == Config.CLASS_RENEWABLE_ENERGY) {
            return _receivable("Renewable Energy", 7500, 1825 days, Config.RAMP_CONCENTRATION_LIMIT_BPS);
        }
        if (classId == Config.CLASS_LIFE_SCIENCES) {
            return _receivable("Life Sciences", 6000, 2555 days, Config.RAMP_CONCENTRATION_LIMIT_BPS);
        }
        if (classId == Config.CLASS_REAL_ESTATE) {
            return _receivable("Real Estate", 7000, 3650 days, Config.RAMP_CONCENTRATION_LIMIT_BPS);
        }
        if (classId == Config.CLASS_DIGITAL_ASSETS) {
            return ICollateralRegistry.ClassParams({
                name: "Digital Assets",
                model: ICollateralRegistry.CollateralModel.MarkedToMarket,
                active: true,
                maxLtvBps: 5000,
                maxMaturity: 365 days,
                concentrationLimitBps: Config.RAMP_CONCENTRATION_LIMIT_BPS,
                marginCallLtvBps: 6500,
                liquidationLtvBps: 8000,
                maxMarkAge: 1 days
            });
        }
        revert("unknown collateral class");
    }

    function _borrowerLimitBps() internal view virtual returns (uint16) {
        return Config.RAMP_CONCENTRATION_LIMIT_BPS;
    }

    function _stateLimitBps() internal view virtual returns (uint16) {
        return Config.RAMP_CONCENTRATION_LIMIT_BPS;
    }

    function _concentrationFloor() internal view virtual returns (uint256) {
        return 25_000_000e18;
    }

    function _attester1(Ctx memory c) internal pure returns (address) {
        return c.attester1 == address(0) ? c.deployer : c.attester1;
    }

    function _anchorCurator(Ctx memory c) internal pure returns (address) {
        return c.anchorCurator == address(0) ? c.opsAdmin : c.anchorCurator;
    }

    function _isProductionProfile() internal pure virtual returns (bool) {
        return false;
    }

    function _manifestPath() internal view virtual returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), ".json");
    }

    /// @dev Test harnesses override this with the canonical chain USDC address.
    function _deployUSDC() internal virtual returns (address) {
        return address(new MockERC20("Testnet USD Coin", "tUSDC", 6));
    }
}
