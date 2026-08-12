// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {Handover, HandoverOps} from "../../script/Handover.s.sol";
import {Validate} from "../../script/Validate.s.sol";
import {PrivilegeAudit} from "../../script/PrivilegeAudit.sol";
import {GroveToken} from "../../src/GroveToken.sol";
import {MintRedeemController} from "../../src/MintRedeemController.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title ADVSEAM — LOSS_BURNER_ROLE escapes the C-01 residual-privilege audit
/// @notice MERGE-SEAM FINDING. R16 (MRC lineage) split `MintRedeemController.burnLoss` off
///         `CREDIT_ROLE` onto a NEW `Roles.LOSS_BURNER_ROLE` for least privilege. The three
///         role enumerations that the C-01 deployer-privilege gate is built on live in the
///         round-3 / C-01 lineage (`script/PrivilegeAudit.sol`, `script/Handover.s.sol`) and
///         were never updated: the merged tree's `script/` is byte-identical to MRC-R3's, and
///         MRC-R3 never touched those enumerations. The power therefore moved OUT of an
///         audited role and INTO an unaudited one.
///
///         This is the SAME defect class that AUDIT R15-05 already found once and fixed for
///         `FEE_ACCOUNTING_ROLE` — its own comment in `HandoverOps._authorityRoles()` says
///         "a deployer key that held it would have survived the gate silently".

// ═══════════════════════════════════════════════════════════════════════════════════════════
// INVERTED 2026-08-08 — DO NOT RESTORE THE ORIGINAL ASSERTIONS.
//
// This suite was written by an adversarial reviewer against RC3, where all four tests PASSED
// because the defect was present: `Roles.LOSS_BURNER_ROLE` was absent from `roleSet`,
// `authorityRoleSet` and `HandoverOps._authorityRoles`, so a deployer key holding it passed
// the residual-privilege gate silently and survived handover. `Deploy._wire` registers the
// sUSDfr vault as a loss source, so that key could burn senior principal out of the vault with
// no cascade, no incident and no evidence hash.
//
// SEAM-1 added the role to all three enumerations. These tests are now inverted to assert the
// FIX rather than the defect: each one reds again the moment the role is dropped from any of
// the three lists. Leaving them asserting absence would have pinned the vulnerability as if it
// were intended behaviour — the failure mode this engagement has hit three times.
// ═══════════════════════════════════════════════════════════════════════════════════════════
contract AdvseamLossBurnerEscapesPrivilegeAuditTest is Test, Deploy, HandoverOps {
    address internal attester2Addr = makeAddr("advseamAttester2");
    address internal rogue = makeAddr("advseamRogueKey");
    address internal stranger = makeAddr("advseamStranger");
    address internal ops = makeAddr("advseamOps");
    address internal treasury = makeAddr("advseamTreasury");
    address internal fees = makeAddr("advseamFees");

    address internal currentTreasury;

    function treasuryOf(D memory) internal view returns (address) {
        return currentTreasury;
    }

    function _testnetCtx() internal view returns (Ctx memory c) {
        c.deployer = address(this);
        c.opsAdmin = address(this);
        c.proposalGuardian = attester2Addr;
        c.queueKeeper = address(this);
        c.frTreasury = address(this);
        c.feeRecipient = address(this);
        c.attester2 = attester2Addr;
        c.keepOpsAdmin = true;
    }

    function _run(Ctx memory c) internal returns (D memory d) {
        currentTreasury = c.frTreasury;
        d = _deployAll(c);
        _wire(d, c);
        _seed(d, c);
        _handover(d, c);
    }

    function _auditSet(D memory d) internal pure returns (address[] memory targets, string[] memory names) {
        return PrivilegeAudit.moduleSet(_auditTargets(d));
    }

    // ── 1. the enumerations themselves ───────────────────────────────────

    /// @notice SEAM-1 REGRESSION PIN. `PrivilegeAudit.roleSet` claims in its own NatSpec to
    ///         "mirror `src/libraries/Roles.sol`", and after SEAM-1 it does. Before the fix
    ///         `LOSS_BURNER_ROLE` was absent from the full scan set AND from the AUTHORITY subset,
    ///         so a deployer key holding it read CLEAN. Delete either entry and this reds.
    function test_SEAM1_lossBurnerRoleIsScannedByEveryPrivilegeEnumeration() public pure {
        bool seenInRoleSet;
        bool seenInAuthoritySet;
        (bytes32[] memory ids,) = PrivilegeAudit.roleSet(true);
        for (uint256 i = 0; i < ids.length; ++i) {
            if (ids[i] == Roles.LOSS_BURNER_ROLE) seenInRoleSet = true;
        }

        (bytes32[] memory authIds,) = PrivilegeAudit.authorityRoleSet();
        for (uint256 i = 0; i < authIds.length; ++i) {
            if (authIds[i] == Roles.LOSS_BURNER_ROLE) seenInAuthoritySet = true;
        }
        assertTrue(seenInRoleSet, "SEAM-1 REGRESSED: roleSet no longer scans LOSS_BURNER_ROLE");
        assertTrue(seenInAuthoritySet, "SEAM-1 REGRESSED: authorityRoleSet no longer scans LOSS_BURNER_ROLE");
    }

    /// @notice SEAM-1 REGRESSION PIN. `HandoverOps._authorityRoles()` is the list the handover
    ///         DROPS from an EOA. `LOSS_BURNER_ROLE` was absent, so a burn key survived handover.
    ///         It is now listed BEFORE `DEFAULT_ADMIN_ROLE`, per that function's own documented
    ///         ordering (admin last, because dropping it ends the ability to revoke anything else).
    function test_SEAM1_handoverAuthorityRolesStripsLossBurner() public pure {
        bool dropped;
        bytes32[] memory authority = _authorityRoles();
        for (uint256 i = 0; i < authority.length; ++i) {
            if (authority[i] == Roles.LOSS_BURNER_ROLE) dropped = true;
        }
        assertTrue(dropped, "SEAM-1 REGRESSED: handover no longer drops LOSS_BURNER_ROLE");
    }

    // ── 2. the consequence, on a real deployment ─────────────────────────

    /// @notice SEAM-1 REGRESSION PIN, the executed consequence. A key holding
    ///         `LOSS_BURNER_ROLE` authorises burning senior principal out of the `sUSDfr` vault —
    ///         cascade layer 3. Before SEAM-1 every arm of the C-01 residual-privilege audit
    ///         reported such a key CLEAN. All three arms must now flag it. Drop the role from
    ///         `roleSet` and arms 1-2 red; drop it from `authorityRoleSet` and arm 3 reds.
    function test_SEAM1_aRogueLossBurnerKeyIsCaughtByTheResidualPrivilegeGate() public {
        Ctx memory c = _testnetCtx();
        D memory d = _run(c);

        // The deployer still holds DEFAULT_ADMIN in the testnet shape, so it can do this; in the
        // production shape any pre-renounce step or a compromised deploy can do the same.
        IAccessControl(d.controller).grantRole(Roles.LOSS_BURNER_ROLE, rogue);
        assertTrue(
            IAccessControl(d.controller).hasRole(Roles.LOSS_BURNER_ROLE, rogue), "the rogue key must actually hold it"
        );

        (address[] memory targets, string[] memory names) = _auditSet(d);

        // Arm 1: the full residual-privilege receipt (`Deploy`/`Handover` print this).
        assertEq(
            PrivilegeAudit.scanEverything(targets, names, d.timelock, rogue).length,
            1,
            "SEAM-1 REGRESSED: the residual-privilege receipt no longer flags a LOSS_BURNER holder"
        );
        // Arm 2: the blocking `scan` used by `Deploy._auditPrivilege` and `Handover`.
        assertEq(
            PrivilegeAudit.scan(targets, names, rogue, true).length,
            1,
            "SEAM-1 REGRESSED: the blocking privilege scan no longer flags a LOSS_BURNER holder"
        );
        // Arm 3: the AUTHORITY assertion `Validate.s.sol` runs against deployer and opsAdmin.
        (bytes32[] memory authIds, string[] memory authNames) = PrivilegeAudit.authorityRoleSet();
        assertEq(
            PrivilegeAudit.scanRoles(targets, names, authIds, authNames, rogue).length,
            1,
            "SEAM-1 REGRESSED: the authority-role assertion no longer flags a LOSS_BURNER holder"
        );

        // And the role is not decoration: it is the sole gate on `burnLoss`.
        assertTrue(
            IAccessControl(d.controller).hasRole(Roles.LOSS_BURNER_ROLE, rogue),
            "the role survived the whole audit untouched"
        );

        // DIFFERENTIAL PROOF that the rogue is past the authorisation gate: a NON-holder is
        // refused by AccessControl; the rogue reaches `burnLoss`'s own body and is refused only
        // by the amount check. `d.vault` is a registered loss source (`Deploy._wire`), so with a
        // non-zero amount this call destroys senior principal directly — no cascade, no
        // incident, no evidence hash.
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", stranger, Roles.LOSS_BURNER_ROLE
            )
        );
        MintRedeemController(d.controller).burnLoss(d.vault, 0);

        vm.prank(rogue);
        vm.expectRevert(IMintRedeemController.Controller_ZeroAmount.selector);
        MintRedeemController(d.controller).burnLoss(d.vault, 0);
    }

    /// @notice SEAM-1 REGRESSION PIN, production shape — the one that matters. The rogue grant
    ///         happens BEFORE handover, while the deployer still legitimately holds DEFAULT_ADMIN.
    ///         Before SEAM-1, `HandoverOps._authorityRoles()` did not list `LOSS_BURNER_ROLE` so
    ///         handover never stripped it, and `PrivilegeAudit.authorityRoleSet()` did not list it
    ///         so `Validate`'s "authority survived the handover" assertion never saw it — the
    ///         deployment validated GREEN with a hot key able to burn senior principal out of the
    ///         vault. Handover must now strip it from BOTH keys.
    function test_SEAM1_handoverStripsAHotLossBurnerKeyFromBothDeployerAndOps() public {
        Ctx memory c;
        c.deployer = address(this);
        c.opsAdmin = ops;
        c.proposalGuardian = attester2Addr;
        c.queueKeeper = ops;
        c.frTreasury = treasury;
        c.feeRecipient = fees;
        c.attester2 = attester2Addr;
        c.keepOpsAdmin = false;

        currentTreasury = c.frTreasury;
        D memory d = _deployAll(c);
        _wire(d, c);
        _seed(d, c);

        // THE PRINCIPALS THE HANDOVER AND `Validate` ACTUALLY SCAN — the deployer key itself and
        // the ops key. Using these, and not a third-party address, is what makes this test
        // DISCRIMINATING: every other authority role granted to these two IS stripped by
        // `HandoverOps._dropRoles` and IS asserted absent by `Validate`. Only LOSS_BURNER_ROLE
        // survives, and only because it is missing from both enumerations.
        IAccessControl(d.controller).grantRole(Roles.LOSS_BURNER_ROLE, c.deployer);
        IAccessControl(d.controller).grantRole(Roles.LOSS_BURNER_ROLE, c.opsAdmin);

        _handover(d, c);

        vm.prank(treasury);
        GroveToken(d.grove).delegate(treasury);

        // The handover must now strip both. Before SEAM-1 both of these survived.
        assertFalse(
            IAccessControl(d.controller).hasRole(Roles.LOSS_BURNER_ROLE, c.deployer),
            "SEAM-1 REGRESSED: handover left LOSS_BURNER_ROLE on the DEPLOYER key"
        );
        assertFalse(
            IAccessControl(d.controller).hasRole(Roles.LOSS_BURNER_ROLE, c.opsAdmin),
            "SEAM-1 REGRESSED: handover left LOSS_BURNER_ROLE on the OPS key"
        );
        // CONTROL: an authority role that IS enumerated is stripped from the same key by the same
        // handover, so the survival above is attributable to the omission and nothing else.
        IAccessControl(d.controller).hasRole(Roles.CREDIT_ROLE, c.deployer);
        assertFalse(
            IAccessControl(d.controller).hasRole(Roles.CREDIT_ROLE, c.deployer),
            "CONTROL: an enumerated authority role must not survive"
        );

        // And production-shape validation is GREEN over it.
        Validate validator = new Validate();
        validator.validateDeployment(_args(d, c));
        validator.validateHandover(_args(d, c));
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
        a.attester2 = c.attester2;
        a.frTreasury = c.frTreasury;
        a.feeRecipient = c.feeRecipient;
        a.stable = d.stable;
        a.keepOpsAdmin = false;
        a.attesterQuorumIndependent = true;
    }
}
