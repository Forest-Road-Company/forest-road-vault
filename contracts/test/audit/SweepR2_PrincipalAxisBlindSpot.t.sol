// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockControllerUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {Handover, HandoverOps} from "../../script/Handover.s.sol";
import {Validate} from "../../script/Validate.s.sol";
import {PrivilegeAudit} from "../../script/PrivilegeAudit.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title SWEEP-2 — the residual-privilege audit is complete on the ROLE axis and blind on the
///        PRINCIPAL axis.
/// @notice SEAM-1's shape was "a role in the DROP list, absent from the DETECT list". This is the
///         same shape one axis over: the deployment names EIGHT genesis principals
///         (deployer, opsAdmin, queueKeeper, frTreasury, feeRecipient, anchorCurator,
///         attester1, attester2) and the whole residual-privilege apparatus —
///         `PrivilegeAudit.scan`, `authorityRoleSet`, `scanTimelock`,
///         `Validate._reportPrivilegePosture`, `HandoverOps._assertNoSurvivingPrivilege` —
///         asserts against exactly TWO of them.

// ═══════════════════════════════════════════════════════════════════════════════════════════
// INVERTED — DO NOT RESTORE THE ORIGINAL ASSERTIONS.
//
// Written first as a DEFECT DEMONSTRATION: on the tree as received, all four tests below PASSED,
// because a `UPGRADER_ROLE` / `DEFAULT_ADMIN_ROLE` / timelock-`PROPOSER_ROLE` grant to a named
// genesis principal other than deployer/opsAdmin survived the complete production ceremony and
// BOTH validators returned green. Measured, verbatim, before the fix:
//
//   [PASS] test_S2_F1_anchorCuratorHoldingVaultUpgraderPassesBothValidators()
//   [PASS] test_S2_F1b_settlementKeeperHoldingVaultUpgraderPassesBothValidators()
//   [PASS] test_S2_F1c_treasuryHoldingVaultDefaultAdminPassesBothValidators()
//   [PASS] test_S2_F2_anchorCuratorHoldingTimelockProposerPassesBothValidators()
//   (the four names above are the PRE-INVERSION names; they now end `IsRefusedByBothValidators`)
//
// Leaving them asserting the PASS would have pinned the blind spot as if it were intended —
// the failure mode this engagement has now hit four times. They are inverted to assert the
// guard (`Validate._assertNamedPrincipalsHoldNoAuthority`) instead, and each reds again the
// moment that guard is deleted or its principal list is narrowed.
// ═══════════════════════════════════════════════════════════════════════════════════════════
contract SweepR2ArgsExposed is Handover {
    function validationArgs(string memory manifest, Targets memory t, address deployer, address opsAdmin)
        external
        view
        returns (Validate.M memory)
    {
        return _validationArgs(manifest, t, deployer, opsAdmin);
    }
}

contract SweepR2PrincipalAxisBlindSpotTest is Test, Deploy, HandoverOps {
    address internal attester1Addr = makeAddr("s2pAttester1");
    address internal attester2Addr = makeAddr("s2pAttester2");
    address internal ops = makeAddr("s2pOps");
    address internal treasury = makeAddr("s2pTreasury");
    address internal fees = makeAddr("s2pFees");
    address internal keeper = makeAddr("s2pKeeper");
    address internal anchor = makeAddr("s2pAnchorCurator");

    address internal currentTreasury;

    /// @dev The production shape with a fully independent principal set, exactly as
    ///      `DeployMainnet._mainnetContext` builds it: separate ops, treasury, fee recipient,
    ///      anchor curator, settlement keeper and two independent attesters.
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

    /// @dev The same run, with ONE extra grant injected while the deployer still holds
    ///      DEFAULT_ADMIN — i.e. a wiring line a compromised, mistaken or malicious deployment
    ///      script could carry. `grantee` gets `role` on the sUSDfr vault.
    function _runWithInjectedGrant(Ctx memory c, bytes32 role, address grantee) internal returns (D memory d) {
        currentTreasury = c.frTreasury;
        d = _deployAll(c);
        _wire(d, c);
        IAccessControl(d.vault).grantRole(role, grantee);
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

    // ── control: the unmodified production ceremony validates ────────────

    /// @notice PRECONDITION. Without the injected grant this exact stack and these exact
    ///         arguments validate green in BOTH entry points. Every revert below is therefore
    ///         attributable to the injected grant and nothing else.
    function test_S2_F1_control_theCleanProductionCeremonyValidates() public {
        Ctx memory c = _prodCtx();
        D memory d = _run(c);
        Validate v = new Validate();
        v.validateDeployment(_args(d, c));
        v.validateHandover(_args(d, c));
    }

    // ── F1: an authority role on a named principal is invisible ──────────

    /// @notice THE FINDING. `UPGRADER_ROLE` on the sUSDfr vault is `_authorizeUpgrade` — total
    ///         authority over senior principal. Granted to the ANCHOR CURATOR it survives the
    ///         full production ceremony — the handover only ever acts as/on the two EOAs of
    ///         record — so DETECTION is the whole remedy, and before SWEEP-2 F1 there was none.
    ///
    ///         `Validate._validateGovernance` asserts `!hasRole(UPGRADER_ROLE, ...)` for exactly
    ///         `a.deployer` and `a.opsAdmin`. `_reportPrivilegePosture`'s production branch runs
    ///         `PrivilegeAudit.scanRoles(..., authorityRoleSet(), ...)` for exactly those same
    ///         two. The anchor curator is a principal the mainnet deployer VALIDATES the
    ///         separation of (`DeployMainnet: curator must be separate from deployer/operations`)
    ///         and then never scans.
    function test_S2_F1_anchorCuratorHoldingVaultUpgraderIsRefusedByBothValidators() public {
        Ctx memory c = _prodCtx();
        D memory d = _runWithInjectedGrant(c, Roles.UPGRADER_ROLE, anchor);

        assertTrue(
            IAccessControl(d.vault).hasRole(Roles.UPGRADER_ROLE, anchor),
            "precondition: the anchor curator holds UPGRADER on the senior vault"
        );

        // The durable manifest receipt still cannot name it — it enumerates deployer /
        // opsAdmin / queueKeeper only — which is exactly why DETECTION had to move into the
        // blocking assertion rather than the printed block.
        (address[] memory targets, string[] memory names) = PrivilegeAudit.moduleSet(_auditTargets(d));
        assertEq(
            PrivilegeAudit.scanEverything(targets, names, d.timelock, c.deployer).length,
            0,
            "the deployer receipt is clean, so nothing in the manifest hints at this"
        );
        string[] memory anchorHeld = PrivilegeAudit.scanEverything(targets, names, d.timelock, anchor);
        for (uint256 i = 0; i < anchorHeld.length; ++i) {
            console2.log("S2-F1 anchorCurator holds:", anchorHeld[i]);
        }
        assertEq(anchorHeld.length, 1, "precondition: exactly the injected pair");

        Validate v = new Validate();
        vm.expectRevert(bytes("PRODUCTION SHAPE: a named genesis principal holds a module AUTHORITY role"));
        v.validateDeployment(_args(d, c));
        vm.expectRevert(bytes("PRODUCTION SHAPE: a named genesis principal holds a module AUTHORITY role"));
        v.validateHandover(_args(d, c));
    }

    /// @notice The same hole on the HOT settlement keeper — an EOA that `DeployMainnet`
    ///         hard-requires (`settlement keeper must be an EOA`, `must be an isolated key`).
    ///         `Validate._printPosture` PRINTS the keeper's pairs but nothing ASSERTS them, so
    ///         a hot key able to upgrade the senior vault validates green.
    function test_S2_F1b_settlementKeeperHoldingVaultUpgraderIsRefusedByBothValidators() public {
        Ctx memory c = _prodCtx();
        D memory d = _runWithInjectedGrant(c, Roles.UPGRADER_ROLE, keeper);

        assertTrue(IAccessControl(d.vault).hasRole(Roles.UPGRADER_ROLE, keeper), "precondition");
        Validate v = new Validate();
        vm.expectRevert(bytes("PRODUCTION SHAPE: a named genesis principal holds a module AUTHORITY role"));
        v.validateDeployment(_args(d, c));
        vm.expectRevert(bytes("PRODUCTION SHAPE: a named genesis principal holds a module AUTHORITY role"));
        v.validateHandover(_args(d, c));
    }

    /// @notice And on the treasury, which already holds the entire GROVE supply and therefore
    ///         all governance voting power. DEFAULT_ADMIN on the vault plus the votes is
    ///         unconditional control of the senior vault with no timelock in the path.
    function test_S2_F1c_treasuryHoldingVaultDefaultAdminIsRefusedByBothValidators() public {
        Ctx memory c = _prodCtx();
        D memory d = _runWithInjectedGrant(c, bytes32(0), treasury);

        assertTrue(IAccessControl(d.vault).hasRole(bytes32(0), treasury), "precondition");
        Validate v = new Validate();
        vm.expectRevert(bytes("PRODUCTION SHAPE: a named genesis principal holds a module AUTHORITY role"));
        v.validateDeployment(_args(d, c));
        vm.expectRevert(bytes("PRODUCTION SHAPE: a named genesis principal holds a module AUTHORITY role"));
        v.validateHandover(_args(d, c));
    }

    /// @notice DISCRIMINATING CONTROL. The identical grant to a principal the audit DOES scan
    ///         is caught immediately. This proves the tests above measure the PRINCIPAL axis
    ///         and not some general weakness of the assertion.
    function test_S2_F1_control_theSameGrantOnAScannedPrincipalIsCaught() public {
        Ctx memory c = _prodCtx();
        D memory d = _runWithInjectedGrant(c, Roles.UPGRADER_ROLE, ops);

        Validate v = new Validate();
        vm.expectRevert(bytes("ops must NOT upgrade"));
        v.validateDeployment(_args(d, c));
    }

    // ── F2: the timelock's own PROPOSER graph, same blind spot ───────────

    /// @notice `PrivilegeAudit.timelockAuthorityRoleSet` exists because, with the open executor,
    ///         PROPOSER is DEFAULT_ADMIN-equivalent over every module (merely delayed). It was
    ///         asserted absent on the deployer and on ops ONLY. On the anchor curator — or the
    ///         settlement keeper, treasury, fee recipient or either attester — it was not.
    function test_S2_F2_anchorCuratorHoldingTimelockProposerIsRefusedByBothValidators() public {
        Ctx memory c = _prodCtx();
        currentTreasury = c.frTreasury;
        D memory d = _deployAll(c);
        _wire(d, c);
        TimelockControllerUpgradeable tl = TimelockControllerUpgradeable(payable(d.timelock));
        tl.grantRole(tl.PROPOSER_ROLE(), anchor);
        _seed(d, c);
        _handover(d, c);

        assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), anchor), "precondition: curator can schedule any call");
        assertTrue(tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "precondition: the executor is open");

        Validate v = new Validate();
        vm.expectRevert(bytes("PRODUCTION SHAPE: a named genesis principal holds timelock PROPOSER/CANCELLER"));
        v.validateDeployment(_args(d, c));
        vm.expectRevert(bytes("PRODUCTION SHAPE: a named genesis principal holds timelock PROPOSER/CANCELLER"));
        v.validateHandover(_args(d, c));
    }

    /// @notice DISCRIMINATING CONTROL for F2.
    function test_S2_F2_control_theSameTimelockGrantOnOpsIsCaught() public {
        Ctx memory c = _prodCtx();
        currentTreasury = c.frTreasury;
        D memory d = _deployAll(c);
        _wire(d, c);
        TimelockControllerUpgradeable tl = TimelockControllerUpgradeable(payable(d.timelock));
        tl.grantRole(tl.PROPOSER_ROLE(), ops);
        _seed(d, c);
        _handover(d, c);

        Validate v = new Validate();
        vm.expectRevert(bytes("PRODUCTION SHAPE: ops holds timelock PROPOSER/CANCELLER"));
        v.validateDeployment(_args(d, c));
    }

    // ── F1, the argument-plumbing half ───────────────────────────────────

    /// @notice REGRESSION. `Handover._validationArgs` populates `Validate.M` BY HAND, and must
    ///         mirror `Validate._load`. It already dropped `.queueKeeper` once (D7-01 merge review)
    ///         and `.attester1` once (SWEEP-1 F-2). It also dropped `.anchorCurator`, which was
    ///         harmless until the SWEEP-2 F1 guard started SCANNING that principal — a soft
    ///         default of `address(0)` resolves to the OPS ADMIN, so the guard would have
    ///         re-scanned an already-asserted principal and never looked at the curator multisig.
    ///         MUTATION: delete the `a.anchorCurator = ...` line in `_validationArgs` -> RED here.
    function test_S2_F1_handoverValidationArgsCarryTheAnchorCurator() public {
        SweepR2ArgsExposed h = new SweepR2ArgsExposed();
        Targets memory t; // only the manifest fields are read below
        string memory manifest;
        {
            string memory j = "s2Args";
            vm.serializeAddress(j, "proposalGuardian", attester2Addr);
            vm.serializeAddress(j, "attester2", attester2Addr);
            vm.serializeAddress(j, "feeRecipient", fees);
            vm.serializeAddress(j, "stable", address(0xC0FFEE));
            manifest = vm.serializeAddress(j, "anchorCurator", anchor);
        }
        Validate.M memory a = h.validationArgs(manifest, t, address(this), ops);
        assertEq(a.anchorCurator, anchor, "S2-F1: _validationArgs must carry .anchorCurator from the manifest");
        assertTrue(a.anchorCurator != ops, "and it must NOT silently resolve to the ops admin");
    }

    /// @notice DISCRIMINATING CONTROL: a legacy manifest without the key still soft-defaults,
    ///         matching `Validate._load`. The fix adds a read, it does not add a hard dependency.
    function test_S2_F1_control_legacyManifestWithoutTheKeyStillLoads() public {
        SweepR2ArgsExposed h = new SweepR2ArgsExposed();
        Targets memory t;
        string memory manifest;
        {
            string memory j = "s2ArgsLegacy";
            vm.serializeAddress(j, "proposalGuardian", attester2Addr);
            vm.serializeAddress(j, "attester2", attester2Addr);
            vm.serializeAddress(j, "feeRecipient", fees);
            manifest = vm.serializeAddress(j, "stable", address(0xC0FFEE));
        }
        Validate.M memory a = h.validationArgs(manifest, t, address(this), ops);
        assertEq(a.anchorCurator, address(0), "legacy: absent key soft-defaults, exactly as _load does");
    }
}
