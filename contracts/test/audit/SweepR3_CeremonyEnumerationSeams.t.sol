// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockControllerUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";

import {Deploy, ForestRoadTimelock} from "../../script/Deploy.s.sol";
import {HandoverOps} from "../../script/Handover.s.sol";
import {PrivilegeAudit} from "../../script/PrivilegeAudit.sol";
import {PrivilegeTopology} from "../../script/generated/PrivilegeTopology.sol";
import {Validate} from "../../script/Validate.s.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title SWEEP-3 — deployment-ceremony enumeration seams
/// @notice ADVERSARIAL SWEEP ROUND 3 (Deploy / Validate / Handover / PrivilegeAudit / Roles).
///
///         SEAM-1's shape is "two enumerations of the same thing that must mirror, and nothing
///         pins them". Round 1 closed the ROLE axis (`Roles.sol` -> `roleSet` -> `_authorityRoles`),
///         round 2 closed the PRINCIPAL axis (eight named genesis principals, two scanned). This
///         file attacks the two axes still unpinned:
///
///           A. THE TIMELOCK'S OWN ROLE IDENTIFIERS. `PrivilegeAudit.timelockRoleSet()`,
///              `PrivilegeAudit.timelockAuthorityRoleSet()` and `HandoverOps._timelockRoles()`
///              are THREE hand-written lists of `keccak256("...")` STRING LITERALS, in two files,
///              for roles whose source of truth is a getter on the deployed contract
///              (`TimelockController.PROPOSER_ROLE()` / `CANCELLER_ROLE()` / `EXECUTOR_ROLE()`).
///              Nothing compared them to that getter, to each other, or to anything else.
///
///           B. THE IMPLEMENTATION-INITIALISER LOCK (the A-01 class). Nineteen implementations are
///              deployed by `Deploy._deployAll`; exactly TWO carry a falsifier for
///              `constructor() { _disableInitializers(); }`.
///
///           C. THE MODULE AXIS. The privilege audit's DETECT surface is a hand-written
///              seventeen-address list repeated in `Deploy._auditTargets`,
///              `Handover._refreshManifestReceipt` and `Validate._reportPrivilegePosture`, plus a
///              sixteen-address list repeated in `HandoverOps._modules` and
///              `Validate._validateGovernance`. Nothing pins any of them to any other.
/// @dev External harness for the SWEEP-3 S3-02 distinctness guards. `vm.expectRevert` only sees a
///      revert raised at a LOWER call depth, and both guards live in `internal`/library code that
///      runs in the caller's frame — so they must be driven through a real external call or the
///      falsifiers below cannot fire at all.
/// @dev External harness for the SWEEP-3 S3-02 guard inside `Validate._validateGovernance`.
///      `vm.expectRevert` needs a lower call depth, and the check is `internal`.
contract S3ValidateGovernanceProbe is Validate {
    function governance(M memory a) external view {
        _validateGovernance(a);
    }
}

contract S3ModuleSetProbe is HandoverOps {
    function auditModuleSet(PrivilegeTopology.ModuleAddresses memory m) external pure {
        PrivilegeAudit.moduleSet(m);
    }

    function handoverModules(Targets memory t) external pure {
        _modules(t);
    }
}

contract SweepR3CeremonyEnumerationSeamsTest is Test, Deploy, HandoverOps {
    /// @dev ERC-7201 `Initializable` namespace. Low 64 bits are `_initialized`:
    ///      0 = never initialised (INITIALISER OPEN, A-01), `type(uint64).max` = permanently
    ///      disabled by `_disableInitializers()`.
    bytes32 internal constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    address internal attester1Addr = makeAddr("s3Attester1");
    address internal attester2Addr = makeAddr("s3Attester2");
    address internal ops = makeAddr("s3Ops");
    address internal treasury = makeAddr("s3Treasury");
    address internal fees = makeAddr("s3Fees");
    address internal keeper = makeAddr("s3Keeper");
    address internal anchor = makeAddr("s3AnchorCurator");

    address internal currentTreasury;

    /// @dev The production shape exactly as `DeployMainnet._mainnetContext` builds it.
    function _prodCtx() internal view returns (Ctx memory c) {
        c.deployer = address(this);
        c.opsAdmin = ops;
        c.proposalGuardian = attester2Addr;
        c.queueKeeper = keeper;
        c.frTreasury = treasury;
        c.feeRecipient = fees;
        c.anchorCurator = anchor;
        c.attester1 = attester1Addr;
        c.attester2 = attester2Addr;
        c.keepOpsAdmin = false;
    }

    function _run(Ctx memory c) internal returns (D memory d) {
        currentTreasury = c.frTreasury;
        d = _deployAll(c);
        _wire(d, c);
        _seed(d, c);
        _handover(d, c);
    }

    function _args(D memory d, Ctx memory c) internal pure returns (Validate.M memory a) {
        a.compliance = d.compliance;
        a.usdfr = d.usdfr;
        a.reserves = d.reserves;
        a.controller = d.controller;
        a.vault = d.vault;
        a.points = d.points;
        a.registry = d.registry;
        a.oracle = d.oracle;
        a.bridge = d.bridge;
        a.curator = d.curator;
        a.waterfall = d.waterfall;
        a.defaultManager = d.defaultManager;
        a.assessedImpairmentSource = d.assessedImpairmentSource;
        a.mtmExecutor = d.mtmExecutor;
        a.queue = d.queue;
        a.grove = d.grove;
        a.sGrove = d.sGrove;
        a.timelock = d.timelock;
        a.governor = d.governor;
        a.votesAggregator = d.votesAggregator;
        a.deployer = c.deployer;
        a.opsAdmin = c.opsAdmin;
        a.proposalGuardian = c.proposalGuardian;
        a.queueKeeper = c.queueKeeper;
        a.attester1 = c.attester1;
        a.attester2 = c.attester2;
        a.frTreasury = c.frTreasury;
        a.feeRecipient = c.feeRecipient;
        a.anchorCurator = c.anchorCurator;
        a.stable = d.stable;
        a.keepOpsAdmin = false; // PRODUCTION SHAPE — the strict branch
        a.attesterQuorumIndependent = true;
    }

    function _targets(D memory d) internal view returns (Targets memory t) {
        t.compliance = d.compliance;
        t.usdfr = d.usdfr;
        t.reserves = d.reserves;
        t.controller = d.controller;
        t.vault = d.vault;
        t.points = d.points;
        t.registry = d.registry;
        t.oracle = d.oracle;
        t.bridge = d.bridge;
        t.curator = d.curator;
        t.waterfall = d.waterfall;
        t.defaultManager = d.defaultManager;
        t.assessedImpairmentSource = d.assessedImpairmentSource;
        t.queue = d.queue;
        t.sGrove = d.sGrove;
        t.grove = d.grove;
        t.timelock = d.timelock;
        t.governor = d.governor;
        t.votesAggregator = d.votesAggregator;
        t.frTreasury = currentTreasury;
    }

    function _contains(bytes32[] memory set, bytes32 v) private pure returns (bool) {
        for (uint256 i = 0; i < set.length; ++i) {
            if (set[i] == v) return true;
        }
        return false;
    }

    // ═════════════════════════════════════════════════════════════════════
    // A. THE TIMELOCK ROLE IDENTIFIERS — three literal lists, zero pins
    // ═════════════════════════════════════════════════════════════════════

    /// @notice `PrivilegeAudit.timelockRoleSet()` must be exactly the role identifiers the
    ///         deployed `TimelockController` itself publishes.
    /// @dev WHY THIS EXISTS — DO NOT DELETE. Every module role in this repo is referenced through
    ///      `src/libraries/Roles.sol`, and the generated compiler-AST topology gate pins every
    ///      consumer to the canonical schema. The TIMELOCK's three roles have no such library:
    ///      `PrivilegeAudit.timelockRoleSet`, `PrivilegeAudit.timelockAuthorityRoleSet` and
    ///      `HandoverOps._timelockRoles` each rebuild them from `keccak256("...")` STRING
    ///      LITERALS — eight literals across two files — while `Validate._validateGovernance`
    ///      reads the SAME roles from the contract's own `tl.PROPOSER_ROLE()` / `tl.EXECUTOR_ROLE()`
    ///      getters two hundred lines away. Two enumerations of one quantity; nothing compared them.
    ///
    ///      A single mistyped literal makes `scanTimelock` return the empty set for that role,
    ///      which SILENTLY SATISFIES every consumer, because all four consumers assert
    ///      `... .length == 0`:
    ///        * `Deploy._writeManifest`             -> `deployerCleanExceptAttester`
    ///        * `Handover._refreshManifestReceipt`  -> `clean`
    ///        * `Validate._reportPrivilegePosture`  -> the manifest cross-check AND the
    ///          production-shape "deployer/ops holds timelock PROPOSER/CANCELLER" requires
    ///        * `Validate._assertNamedPrincipalsHoldNoAuthority` -> the same, for six more principals
    ///      A shrinking role set satisfies a `== 0` assertion MORE easily, never less. That is the
    ///      SEAM-1 failure mode with the gate reporting green.
    ///
    ///      MEASURED (sweep round 3): typing `keccak256("CANCELER_ROLE")` in ALL THREE lists left
    ///      the entire non-fork suite green.
    function test_S3_A_privilegeAuditTimelockRoleSetMatchesTheContractsOwnIds() public {
        TimelockControllerUpgradeable tl = TimelockControllerUpgradeable(payable(address(new ForestRoadTimelock())));
        (bytes32[] memory ids, string[] memory names) = PrivilegeAudit.timelockRoleSet(address(tl));

        assertEq(names.length, ids.length, "S3-A: timelockRoleSet ids/names length mismatch");
        assertEq(ids.length, 3, "S3-A: the timelock publishes exactly three non-admin roles");
        assertTrue(_contains(ids, tl.PROPOSER_ROLE()), "S3-A: PROPOSER_ROLE is not the id the timelock publishes");
        assertTrue(_contains(ids, tl.CANCELLER_ROLE()), "S3-A: CANCELLER_ROLE is not the id the timelock publishes");
        assertTrue(_contains(ids, tl.EXECUTOR_ROLE()), "S3-A: EXECUTOR_ROLE is not the id the timelock publishes");
    }

    /// @notice `HandoverOps._timelockRoles()` — the list the one-command exit actually DROPS from
    ///         both EOAs and then asserts none survived — must be the same three identifiers.
    /// @dev A typo here is worse than a dead scan: `_executeHandoverAs` would neither revoke nor
    ///      renounce that role, and `_assertNoSurvivingPrivilege` would not look for it, so the
    ///      handover would report success over a hot key that still holds it. DO NOT DELETE.
    function test_S3_A_handoverTimelockDropListMatchesTheContractsOwnIds() public {
        TimelockControllerUpgradeable tl = TimelockControllerUpgradeable(payable(address(new ForestRoadTimelock())));
        bytes32[] memory dropped = _timelockRoles(address(tl));

        assertEq(dropped.length, 3, "S3-A: the handover drop list is no longer the full timelock role graph");
        assertTrue(_contains(dropped, tl.PROPOSER_ROLE()), "S3-A: handover does not drop timelock PROPOSER");
        assertTrue(_contains(dropped, tl.CANCELLER_ROLE()), "S3-A: handover does not drop timelock CANCELLER");
        assertTrue(_contains(dropped, tl.EXECUTOR_ROLE()), "S3-A: handover does not drop timelock EXECUTOR");
    }

    /// @notice The DANGEROUS subset must be exactly {PROPOSER, CANCELLER} and must be drawn from
    ///         the full set — the mirror `timelockAuthorityRoleSet`'s own NatSpec asserts in prose.
    /// @dev `EXECUTOR_ROLE` is deliberately excluded (it is granted to `address(0)` by design).
    ///      Both members are load-bearing and for DIFFERENT reasons, which is why membership is
    ///      asserted individually rather than by length alone: with the open executor PROPOSER is
    ///      DEFAULT_ADMIN-equivalent over every module, merely delayed; CANCELLER can veto every
    ///      proposal, i.e. freeze governance permanently on a stack whose only administrator is
    ///      the timelock.
    function test_S3_A_timelockAuthorityRoleSetIsExactlyProposerAndCanceller() public {
        TimelockControllerUpgradeable tl = TimelockControllerUpgradeable(payable(address(new ForestRoadTimelock())));
        (bytes32[] memory dangerous, string[] memory names) = PrivilegeAudit.timelockAuthorityRoleSet(address(tl));
        (bytes32[] memory all,) = PrivilegeAudit.timelockRoleSet(address(tl));

        assertEq(names.length, dangerous.length, "S3-A: timelockAuthorityRoleSet ids/names length mismatch");
        assertEq(dangerous.length, 2, "S3-A: the dangerous timelock subset is no longer PROPOSER + CANCELLER");
        assertTrue(_contains(dangerous, tl.PROPOSER_ROLE()), "S3-A: the blocking timelock scan lost PROPOSER");
        assertTrue(_contains(dangerous, tl.CANCELLER_ROLE()), "S3-A: the blocking timelock scan lost CANCELLER");
        assertTrue(!_contains(dangerous, tl.EXECUTOR_ROLE()), "S3-A: EXECUTOR must stay out of the blocking subset");
        for (uint256 i = 0; i < dangerous.length; ++i) {
            assertTrue(_contains(all, dangerous[i]), "S3-A: a DANGEROUS timelock role is not in the RECEIPT set");
        }
    }

    /// @notice THE EXECUTED CONSEQUENCE. A deployer left holding the timelock's `CANCELLER_ROLE`
    ///         after a production ceremony must be REFUSED by post-deploy validation.
    /// @dev The `CANCELLER` half of `timelockAuthorityRoleSet` had no executed pin at all:
    ///      `SweepR2_PrincipalAxisBlindSpot` covers PROPOSER (on the anchor curator and on ops)
    ///      and nothing anywhere granted CANCELLER to an EOA. Once every module's DEFAULT_ADMIN
    ///      is the timelock and the Governor is its only proposer, a CANCELLER key can veto every
    ///      proposal forever — there is no other administrator left to remove it. DO NOT DELETE.
    function test_S3_A_e2e_aDeployerHoldingTimelockCancellerIsRefusedByProductionValidation() public {
        Ctx memory c = _prodCtx();
        currentTreasury = c.frTreasury;
        D memory d = _deployAll(c);
        _wire(d, c);
        TimelockControllerUpgradeable tl = TimelockControllerUpgradeable(payable(d.timelock));
        tl.grantRole(tl.CANCELLER_ROLE(), c.deployer);
        _seed(d, c);
        _handover(d, c);

        assertTrue(tl.hasRole(tl.CANCELLER_ROLE(), c.deployer), "precondition: the deployer can veto every proposal");

        Validate v = new Validate();
        vm.expectRevert(bytes("PRODUCTION SHAPE: deployer holds timelock PROPOSER/CANCELLER"));
        v.validateDeployment(_args(d, c));
        vm.expectRevert(bytes("PRODUCTION SHAPE: deployer holds timelock PROPOSER/CANCELLER"));
        v.validateHandover(_args(d, c));
    }

    /// @notice The same key on the DURABLE receipt: `deployerCleanExceptAttester` must be FALSE.
    /// @dev This is the expression `Deploy._writeManifest` serialises and `Validate` then requires
    ///      the manifest to match. If `timelockRoleSet()` loses CANCELLER, this flips to TRUE and
    ///      all three artefacts agree on a false "decommissioned" certificate.
    function test_S3_A_e2e_theDurableReceiptRefusesToCallACancellerKeyClean() public {
        Ctx memory c = _prodCtx();
        currentTreasury = c.frTreasury;
        D memory d = _deployAll(c);
        _wire(d, c);
        TimelockControllerUpgradeable tl = TimelockControllerUpgradeable(payable(d.timelock));
        tl.grantRole(tl.CANCELLER_ROLE(), c.deployer);
        _seed(d, c);
        _handover(d, c);

        (address[] memory targets, string[] memory names) = PrivilegeAudit.moduleSet(_auditTargets(d));
        bool clean = PrivilegeAudit.scan(targets, names, c.deployer, false).length == 0
            && PrivilegeAudit.scanTimelock(d.timelock, c.deployer, false).length == 0;
        string[] memory held = PrivilegeAudit.scanEverything(targets, names, d.timelock, c.deployer);
        for (uint256 i = 0; i < held.length; ++i) {
            console2.log("S3-A deployer holds:", held[i]);
        }
        assertTrue(!clean, "S3-A: deployerCleanExceptAttester certified a timelock CANCELLER key as decommissioned");
    }

    /// @notice DISCRIMINATING CONTROL. The identical ceremony WITHOUT the grant validates green in
    ///         both entry points and stamps the receipt clean, so both reverts above are
    ///         attributable to the CANCELLER grant and to nothing else.
    function test_S3_A_control_theCleanProductionCeremonyValidatesAndStampsClean() public {
        Ctx memory c = _prodCtx();
        D memory d = _run(c);
        Validate v = new Validate();
        v.validateDeployment(_args(d, c));
        v.validateHandover(_args(d, c));

        (address[] memory targets, string[] memory names) = PrivilegeAudit.moduleSet(_auditTargets(d));
        bool clean = PrivilegeAudit.scan(targets, names, c.deployer, false).length == 0
            && PrivilegeAudit.scanTimelock(d.timelock, c.deployer, false).length == 0;
        assertTrue(clean, "CONTROL: the clean production ceremony must stamp the deployer clean");
    }

    // ═════════════════════════════════════════════════════════════════════
    // B. THE IMPLEMENTATION-INITIALISER LOCK (A-01 class), for ALL of them
    // ═════════════════════════════════════════════════════════════════════

    /// @notice EVERY implementation this deployment puts behind a proxy must have a spent
    ///         initialiser.
    /// @dev AUDIT FIX (SWEEP-3 B). `Deploy.s.sol`'s own A-01 NatSpec calls
    ///      `constructor() { _disableInitializers(); }` "the house convention that every other
    ///      implementation follows (18/18 in `contracts/src`)" — and that claim was carried by a
    ///      COMMENT. Exactly two of the nineteen implementations had a falsifier:
    ///      `Fix_A01-timelock-impl-initialiser.t.sol` (the timelock, because it lacked the
    ///      convention) and `Fix_R18…::test_R18_G64_theImplementationInitialiserIsLocked` (the
    ///      controller, added when R18 found the constructor was itself a deletable guard). For the
    ///      other seventeen, deleting the constructor was a full-suite survivor.
    ///
    ///      This walks the ACTUAL deployment: `Deploy._proxy` records every implementation it
    ///      constructs in `impls`, so the list cannot go stale when a module is added — the failure
    ///      mode of every hand-written enumeration in this ceremony. DO NOT REPLACE THIS WITH A
    ///      HARD-CODED LIST.
    function test_S3_B_everyDeployedImplementationHasItsInitialiserLocked() public {
        Ctx memory c = _prodCtx();
        currentTreasury = c.frTreasury;
        _deployAll(c);

        assertGt(impls.length, 15, "S3-B: the implementation register is suspiciously short");
        for (uint256 i = 0; i < impls.length; ++i) {
            uint64 version = uint64(uint256(vm.load(impls[i].addr, INITIALIZABLE_STORAGE)));
            console2.log("S3-B impl", impls[i].name);
            console2.log("        initialised version:", uint256(version));
            assertEq(
                uint256(version),
                uint256(type(uint64).max),
                string.concat(
                    "A-01 CLASS: the deployed implementation of `",
                    impls[i].name,
                    "` has an OPEN initialiser -- anyone may seize it"
                )
            );
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    // C. THE MODULE AXIS
    // ═════════════════════════════════════════════════════════════════════

    /// @notice The 17-module AUDIT list and the 16-module HANDOVER list must describe the same
    ///         surface, differing by the timelock alone.
    /// @dev The privilege audit's DETECT surface is a hand-written seventeen-address literal in
    ///      THREE places (`Deploy._auditTargets`, `Handover._refreshManifestReceipt`,
    ///      `Validate._reportPrivilegePosture`) and a sixteen-address literal in TWO more
    ///      (`HandoverOps._modules`, `Validate._validateGovernance`), and `PrivilegeAudit.moduleSet`
    ///      supplies the NAMES positionally — so a duplicated or reordered entry both removes a
    ///      module from every blocking scan and mislabels the durable receipt, with no compile
    ///      error. Only two of the five lists are reachable from a test; this pins those two.
    ///      The remaining three are covered by the executed consequence below.
    function test_S3_C_theAuditModuleListAndTheHandoverModuleListAgree() public {
        Ctx memory c = _prodCtx();
        currentTreasury = c.frTreasury;
        D memory d = _deployAll(c);

        (address[] memory audited,) = PrivilegeAudit.moduleSet(_auditTargets(d));
        address[] memory handed = _modules(_targets(d));

        assertEq(audited.length, 17, "S3-C: the audit list must cover all generated modules");
        assertEq(handed.length, 16, "S3-C: handover must cover every generated non-timelock module");
        assertEq(audited[audited.length - 1], d.timelock, "S3-C: the audit list must end with the timelock");
        for (uint256 i = 0; i < handed.length; ++i) {
            assertEq(handed[i], audited[i], "S3-C: the handover module list diverged from the audit module list");
        }
        // No entry may repeat: a duplicate is how a module silently leaves the DETECT surface
        // without changing the array length or breaking compilation.
        for (uint256 i = 0; i < audited.length; ++i) {
            assertTrue(audited[i] != address(0), "S3-C: a scanned module address is zero");
            for (uint256 k = i + 1; k < audited.length; ++k) {
                assertTrue(audited[i] != audited[k], "S3-C: the audit module list contains a DUPLICATE entry");
            }
        }
    }

    /// @notice AUDIT FIX FALSIFIER (SWEEP-3 S3-02). `PrivilegeAudit.requireDistinctModules` is the
    ///         single funnel all THREE seventeen-address literals pass through, so it is what makes
    ///         a mis-copied literal fail LOUDLY instead of silently shrinking the DETECT surface.
    /// @dev THIS TEST EXISTS BECAUSE A DEFENSIVE `require` IS UNFALSIFIABLE UNLESS SOMETHING DRIVES
    ///      IT. Deleting the guard with only the tests above in place reds nothing: those assert
    ///      the SHIPPED lists are distinct, which stays true. This one supplies the exact defect the
    ///      finding measured — `a.usdfr` replaced by a duplicate `a.vault` — and requires the
    ///      revert. MUTATION: delete the `requireDistinctModules(targets)` call at the end of
    ///      `PrivilegeAudit.moduleSet` (compiles; `targets` is still built and returned) -> RED here.
    function test_S3_C_theModuleSetRefusesAMisCopiedLiteral() public {
        Ctx memory c = _prodCtx();
        currentTreasury = c.frTreasury;
        D memory d = _deployAll(c);

        S3ModuleSetProbe probe = new S3ModuleSetProbe();
        PrivilegeTopology.ModuleAddresses memory good = _auditTargets(d);
        // Control: the shipped list is accepted.
        probe.auditModuleSet(good);

        // The measured defect: `usdfr` (index 1) replaced by a duplicate of `vault` (index 4).
        PrivilegeTopology.ModuleAddresses memory duplicated = _auditTargets(d);
        duplicated.usdfr = duplicated.vault;
        vm.expectRevert(bytes("PrivilegeAudit: module list has a DUPLICATE entry"));
        probe.auditModuleSet(duplicated);

        // ...and a dropped entry (the other way a positional literal goes wrong) is refused too.
        PrivilegeTopology.ModuleAddresses memory zeroed = _auditTargets(d);
        zeroed.usdfr = address(0);
        vm.expectRevert(bytes("PrivilegeAudit: module list has a ZERO address"));
        probe.auditModuleSet(zeroed);
    }

    /// @notice AUDIT FIX FALSIFIER (SWEEP-3 S3-02), handover side. `HandoverOps._modules` is the
    ///         list the exit actually hands over; a duplicate there means a module's admin and
    ///         upgrader never move to the timelock and the deployer's roles on it are never
    ///         renounced.
    /// @dev MUTATION: delete the distinctness loop in `HandoverOps._modules` (compiles; `mods` is
    ///      still assigned from `_modulesRaw` and returned) -> RED here.
    function test_S3_C_theHandoverModuleListRefusesAMisCopiedLiteral() public {
        Ctx memory c = _prodCtx();
        currentTreasury = c.frTreasury;
        D memory d = _deployAll(c);

        S3ModuleSetProbe probe = new S3ModuleSetProbe();
        Targets memory t = _targets(d);
        probe.handoverModules(t); // control: the shipped list is accepted

        t.usdfr = t.vault;
        vm.expectRevert(bytes("handover module list has a DUPLICATE entry"));
        probe.handoverModules(t);

        t.usdfr = address(0);
        vm.expectRevert(bytes("handover module list has a ZERO address"));
        probe.handoverModules(t);
    }

    /// @notice AUDIT FIX FALSIFIER (SWEEP-3 S3-02), validator side. `Validate._validateGovernance`
    ///         reads its OWN sixteen-address literal; a duplicate there silently drops a module
    ///         from the timelock-admin, timelock-upgrader and no-EOA-upgrader assertions.
    /// @dev MUTATION: delete the distinctness loop added at the top of `_validateGovernance`
    ///      (compiles; `mods` is still built and iterated by the loop below it) -> RED here.
    function test_S3_C_theValidatorGovernedModuleListRefusesAMisCopiedLiteral() public {
        Ctx memory c = _prodCtx();
        currentTreasury = c.frTreasury;
        D memory d = _deployAll(c);
        _wire(d, c);
        _seed(d, c);
        _handover(d, c);

        // Driven through `_validateGovernance` directly, NOT through `validateDeployment`: an M
        // struct with a duplicated address is refused by the WIRING assertions first
        // ("controller wiring"), which would make this test pass for the wrong reason. The defect
        // being modelled is a mis-copied SOURCE literal, so the check must be reached on its own.
        S3ValidateGovernanceProbe probe = new S3ValidateGovernanceProbe();
        Validate.M memory good = _args(d, c);
        probe.governance(good); // control: the shipped list is accepted

        Validate.M memory duplicated = good;
        duplicated.usdfr = duplicated.vault;
        vm.expectRevert(bytes("governed module list has a DUPLICATE entry"));
        probe.governance(duplicated);

        Validate.M memory zeroed = good;
        zeroed.usdfr = address(0);
        vm.expectRevert(bytes("governed module list has a ZERO address"));
        probe.governance(zeroed);
    }

    /// @notice THE EXECUTED CONSEQUENCE for the module axis. An OPS key holding `MINTER_ROLE` on
    ///         USDfr — unbacked mint, straight past `MintRedeemController._assertBacking` — must be
    ///         refused by production validation.
    /// @dev `Validate._validateWiring` spells out `!hasRole(MINTER_ROLE, a.deployer)` and has NO
    ///      ops equivalent, so the ONLY thing that refuses this is
    ///      `_reportPrivilegePosture`'s production authority scan — which reads a hand-written
    ///      seventeen-address literal. MEASURED (sweep round 3): replacing `a.usdfr` with a
    ///      duplicate `a.vault` in that one literal left this exact stack validating GREEN in both
    ///      entry points, with every deployment-ceremony suite still passing. DO NOT DELETE.
    function test_S3_C_e2e_opsHoldingUsdfrMinterIsRefusedByProductionValidation() public {
        Ctx memory c = _prodCtx();
        currentTreasury = c.frTreasury;
        D memory d = _deployAll(c);
        _wire(d, c);
        IAccessControl(d.usdfr).grantRole(Roles.MINTER_ROLE, ops);
        _seed(d, c);
        _handover(d, c);

        assertTrue(IAccessControl(d.usdfr).hasRole(Roles.MINTER_ROLE, ops), "precondition: ops can mint USDfr");

        Validate v = new Validate();
        vm.expectRevert(bytes("PRODUCTION SHAPE: ops authority survived the handover"));
        v.validateDeployment(_args(d, c));
        vm.expectRevert(bytes("PRODUCTION SHAPE: ops authority survived the handover"));
        v.validateHandover(_args(d, c));
    }

    // ═════════════════════════════════════════════════════════════════════
    // D. THE RECEIPT COVERS THREE OF EIGHT NAMED PRINCIPALS
    // ═════════════════════════════════════════════════════════════════════

    /// @notice MEASUREMENT, not a guard. The residual-privilege RECEIPT — the artefact C-01 exists
    ///         to produce — enumerates `deployer`, `opsAdmin` and `queueKeeper`. The other five
    ///         named genesis principals are ASSERTED (authority only, since SWEEP-2 F1) and never
    ///         PRINTED, so an OPERATIONAL role on one of them is invisible in both directions.
    /// @dev `GUARDIAN_ROLE` on the queue and the curator pauses the protocol's only senior exit and
    ///      the loss cascade. Held by the anchor curator it appears in NO receipt.
    ///
    ///      DELIBERATELY NOT PINNED AS EXPECTED BEHAVIOUR. The production gate currently ACCEPTS
    ///      this posture (`GUARDIAN_ROLE` is not in `authorityRoleSet`, by design), and asserting
    ///      that acceptance would write the gap down as a safety property — the failure mode this
    ///      engagement has hit four times. The validator outcome is therefore LOGGED, not asserted;
    ///      what IS asserted is only the receipt-coverage fact, which is the finding.
    function test_S3_D_theResidualReceiptIsSilentAboutFiveOfTheEightNamedPrincipals() public {
        Ctx memory c = _prodCtx();
        currentTreasury = c.frTreasury;
        D memory d = _deployAll(c);
        _wire(d, c);
        IAccessControl(d.queue).grantRole(Roles.GUARDIAN_ROLE, anchor);
        IAccessControl(d.curator).grantRole(Roles.GUARDIAN_ROLE, anchor);
        _seed(d, c);
        _handover(d, c);

        (address[] memory targets, string[] memory names) = PrivilegeAudit.moduleSet(_auditTargets(d));
        string[] memory anchorHeld = PrivilegeAudit.scanEverything(targets, names, d.timelock, anchor);
        for (uint256 i = 0; i < anchorHeld.length; ++i) {
            console2.log("S3-D anchorCurator holds (never printed by any receipt):", anchorHeld[i]);
        }
        assertEq(anchorHeld.length, 2, "S3-D precondition: the anchor curator holds two GUARDIAN pairs");

        // The receipt written to the manifest and printed by `_printPosture` covers three
        // principals; none of them is the anchor curator.
        assertEq(
            PrivilegeAudit.scanEverything(targets, names, d.timelock, c.deployer).length,
            0,
            "S3-D: the deployer receipt is clean"
        );
        assertEq(
            PrivilegeAudit.scanEverything(targets, names, d.timelock, c.queueKeeper).length,
            1,
            "S3-D: the keeper receipt names only its settlement role"
        );

        // And the production gate accepts it: GUARDIAN is not in `authorityRoleSet`.
        Validate v = new Validate();
        v.validateDeployment(_args(d, c));
        v.validateHandover(_args(d, c));
    }
}
