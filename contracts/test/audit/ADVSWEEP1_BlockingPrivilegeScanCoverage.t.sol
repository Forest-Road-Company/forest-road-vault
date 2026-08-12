// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {HandoverOps} from "../../script/Handover.s.sol";
import {PrivilegeAudit} from "../../script/PrivilegeAudit.sol";
import {Validate} from "../../script/Validate.s.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title ADVSWEEP1 — the BLOCKING privilege scan (`includeAttester == false`) had no coverage
/// @notice ADVERSARIAL SWEEP ROUND 1 FINDING (deployment-ceremony group).
///
///         `PrivilegeAudit.roleSet(bool includeAttester)` serves two DIFFERENT consumers:
///
///           * `includeAttester == true`  -> the operator-facing RECEIPT
///             (`scanEverything`, printed by `Validate._printPosture`, written to the manifest
///              as `retainedPrivileges_deployer` / `_opsAdmin` / `_queueKeeper`).
///           * `includeAttester == false` -> the BLOCKING / CERTIFYING predicate:
///               - `Deploy._writeManifest`      -> `deployerCleanExceptAttester`
///               - `Handover._refreshManifestReceipt` -> `clean`
///               - `Validate._reportPrivilegePosture` -> the `hasManifestClaim` cross-check AND
///                 the production-shape `"deployer privilege survived the handover"` require.
///
///         EVERY predecessor SEAM-1 pin read the RECEIPT arm. The deleted regex checker matched
///         `Roles.X` anywhere in the `roleSet(` body and could not distinguish an unconditional
///         entry from one nested inside `if (includeAttester)`. The three named SEAM-1 tests in
///         `ADVSEAM_LossBurnerEscapesPrivilegeAudit.t.sol` call `roleSet(true)` and
///         `scan(..., true)`. `Fix_C01-deploy-tooling.t.sol` calls `scan(..., false)` but only
///         asserts it is EMPTY, which a shrinking role set satisfies more easily, not less.
///
///         MEASURED SURVIVOR (sweep round 1). Moving `LOSS_BURNER_ROLE` into the
///         `if (includeAttester)` block and dropping the non-attester length 13 -> 12 left
///         the obsolete checker printing OK and all 63 green tests across
///         `ADVSEAM_*`, `Fix_C01-deploy-tooling`, `ProdDeploy` and
///         `DeepSecurityDeploymentAuthorization` still green — while the durable manifest
///         receipt would stamp `deployerCleanExceptAttester = true` over a hot key holding
///         `MintRedeemController.burnLoss` on a stack where `Deploy._wire` registers the sUSDfr
///         vault as a loss source. That is SEAM-1 reopened for every consumer that BLOCKS on it,
///         with the SEAM-1 gate itself reporting green.
///
///         DO NOT DELETE THESE TESTS. Arm 1 is the structural pin the gate cannot express in
///         a regex; arm 2 is its executed consequence on a real deployment.
contract Advsweep1BlockingPrivilegeScanCoverageTest is Test, Deploy, HandoverOps {
    address internal attester2Addr = makeAddr("advsweep1Attester2");
    address internal rogue = makeAddr("advsweep1RogueKey");

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

    // ── arm 1: the structural pin ────────────────────────────────────────

    /// @notice The BLOCKING scan set must be the RECEIPT scan set minus exactly
    ///         `ATTESTER_ROLE` — same roles, same order, same names.
    /// @dev WHY THIS EXISTS. `roleSet`'s `includeAttester` parameter is documented as gating
    ///      ONE role: "the production-shape *assertion* excludes it while the operator-facing
    ///      *receipt* includes it". Nothing enforced that. Any other role nested inside the
    ///      `if (includeAttester)` block silently disappears from `deployerCleanExceptAttester`,
    ///      from `Handover`'s `clean` flag and from `Validate`'s production-shape
    ///      "deployer privilege survived the handover" assertion, while remaining visible to
    ///      the receipt and to the obsolete regex checker, which could not see the branch.
    ///
    ///      DO NOT WEAKEN THIS TO A LENGTH CHECK OR A SET-MEMBERSHIP CHECK. The index alignment
    ///      between `ids` and `names` is what makes the manifest entry `"<module>.<ROLE>"`
    ///      truthful; a role that scans under the wrong NAME is a receipt that lies.
    function test_SWEEP1_blockingScanSetIsTheReceiptSetMinusOnlyAttester() public pure {
        (bytes32[] memory recvIds, string[] memory recvNames) = PrivilegeAudit.roleSet(true);
        (bytes32[] memory blockIds, string[] memory blockNames) = PrivilegeAudit.roleSet(false);

        assertEq(
            blockIds.length,
            recvIds.length - 1,
            "SWEEP1: the blocking scan set must differ from the receipt set by exactly one role"
        );
        assertEq(blockNames.length, blockIds.length, "SWEEP1: blocking ids/names length mismatch");
        assertEq(recvNames.length, recvIds.length, "SWEEP1: receipt ids/names length mismatch");

        for (uint256 i = 0; i < blockIds.length; ++i) {
            assertEq(blockIds[i], recvIds[i], "SWEEP1: a role vanished from the BLOCKING privilege scan");
            assertEq(blockNames[i], recvNames[i], "SWEEP1: blocking/receipt role NAMES diverged at the same index");
            assertTrue(
                blockIds[i] != Roles.ATTESTER_ROLE, "SWEEP1: ATTESTER_ROLE must not appear in the blocking scan set"
            );
        }
        assertEq(
            recvIds[recvIds.length - 1],
            Roles.ATTESTER_ROLE,
            "SWEEP1: the one role the receipt adds must be ATTESTER_ROLE and nothing else"
        );
    }

    // ── arm 2: the executed consequence ──────────────────────────────────

    /// @notice The executed consequence on a real deployment: a key holding
    ///         `LOSS_BURNER_ROLE` must be flagged by the BLOCKING predicate, not merely by the
    ///         printed receipt.
    /// @dev The expression asserted here is character-for-character the one
    ///      `Deploy._writeManifest` serialises as `deployerCleanExceptAttester` and
    ///      `Handover._refreshManifestReceipt` stores as `clean`. `Validate` then REQUIRES the
    ///      manifest claim to match it, so a blind scan makes all three agree on a false
    ///      "decommissioned" certificate — the C-01 failure mode in the artifact layer.
    ///
    ///      `Deploy._wire` calls `setLossSource(d.vault, true)`, so a `LOSS_BURNER_ROLE` holder
    ///      can burn senior principal straight out of the sUSDfr vault: no cascade, no
    ///      incident, no evidence hash. DELETING THIS TEST RESTORES THE SILENT PATH.
    function test_SWEEP1_aLossBurnerKeyIsFlaggedByTheBLOCKINGScanNotJustTheReceipt() public {
        Ctx memory c = _testnetCtx();
        D memory d = _run(c);

        IAccessControl(d.controller).grantRole(Roles.LOSS_BURNER_ROLE, rogue);
        assertTrue(
            IAccessControl(d.controller).hasRole(Roles.LOSS_BURNER_ROLE, rogue), "the rogue key must actually hold it"
        );

        (address[] memory targets, string[] memory names) = PrivilegeAudit.moduleSet(_auditTargets(d));

        // CONTROL: the RECEIPT arm sees it. This is what every pre-existing SEAM-1 pin asserts,
        // and it stays green under the mutation this test exists to catch — which is precisely
        // why it is a control and not the assertion.
        assertEq(
            PrivilegeAudit.scan(targets, names, rogue, true).length,
            1,
            "CONTROL: the receipt scan must flag a LOSS_BURNER holder"
        );

        // THE ASSERTION: the BLOCKING arm must see it too.
        assertEq(
            PrivilegeAudit.scan(targets, names, rogue, false).length,
            1,
            "SWEEP1: the BLOCKING privilege scan is blind to a LOSS_BURNER holder -- "
            "deployerCleanExceptAttester would certify this key as decommissioned"
        );
    }

    /// @notice `PrivilegeAudit.authorityRoleSet()` and `HandoverOps._authorityRoles()` must agree
    ///         as SETS — the mirror `authorityRoleSet`'s own NatSpec has always claimed.
    /// @dev SWEEP-1. They did NOT agree: `_authorityRoles()` has carried `FEE_ACCOUNTING_ROLE`
    ///      since AUDIT R15-05 and `authorityRoleSet()` never did, so handover DROPPED a role that
    ///      `Validate`'s production-shape "authority survived the handover" assertion could not
    ///      DETECT. That is the SEAM-1 shape exactly: present in the drop list, absent from the
    ///      detect list. The only compensating check was a hand-written pair of `require`s in
    ///      `Validate._validateWiring` covering the sUSDfr vault alone.
    ///
    ///      SETS, NOT SEQUENCES, and the order difference is deliberate on both sides:
    ///      `_authorityRoles()` drops `DEFAULT_ADMIN_ROLE` LAST because dropping it ends the
    ///      ability to revoke anything else; `authorityRoleSet()` scans it FIRST because it is the
    ///      most dangerous holding to report. Do not "fix" this test by reordering either list.
    function test_SWEEP1_theAuthorityDropListAndTheAuthorityDetectListAreTheSameSet() public pure {
        bytes32[] memory dropList = _authorityRoles();
        (bytes32[] memory detectIds, string[] memory detectNames) = PrivilegeAudit.authorityRoleSet();

        assertEq(detectNames.length, detectIds.length, "SWEEP1: authorityRoleSet ids/names length mismatch");
        assertEq(
            detectIds.length,
            dropList.length,
            "SWEEP1: the authority DROP list and DETECT list no longer have the same size"
        );

        for (uint256 i = 0; i < dropList.length; ++i) {
            bool seen;
            for (uint256 r = 0; r < detectIds.length; ++r) {
                if (detectIds[r] == dropList[i]) seen = true;
            }
            assertTrue(seen, "SWEEP1: handover DROPS an authority role that authorityRoleSet cannot DETECT");
        }
        for (uint256 i = 0; i < detectIds.length; ++i) {
            bool seen;
            for (uint256 r = 0; r < dropList.length; ++r) {
                if (dropList[r] == detectIds[i]) seen = true;
            }
            assertTrue(seen, "SWEEP1: authorityRoleSet DETECTS an authority role that handover never DROPS");
        }
    }

    /// @notice Every AUTHORITY role that `HandoverOps._authorityRoles()` strips from an EOA must
    ///         also be visible to the BLOCKING scan that certifies the EOA is clean.
    /// @dev THE MIRROR THIS PINS. `_authorityRoles()` is the DROP list; `roleSet(false)` is the
    ///      DETECT list. If handover drops a role the certifying scan cannot see, then a
    ///      handover that silently failed to drop it (a revert path, a partial re-run, a role
    ///      regranted afterwards) still certifies clean. SEAM-1 was exactly one entry missing
    ///      from one of these lists; this asserts the containment rather than re-listing the
    ///      roles by hand a fourth time.
    ///
    ///      `DEFAULT_ADMIN_ROLE` (bytes32(0)) is in both and is checked like any other.
    function test_SWEEP1_everyRoleHandoverDropsIsVisibleToTheBlockingScan() public pure {
        bytes32[] memory dropped = _authorityRoles();
        (bytes32[] memory blockIds,) = PrivilegeAudit.roleSet(false);

        for (uint256 i = 0; i < dropped.length; ++i) {
            bool seen;
            for (uint256 r = 0; r < blockIds.length; ++r) {
                if (blockIds[r] == dropped[i]) seen = true;
            }
            assertTrue(
                seen,
                "SWEEP1: handover DROPS an authority role that the BLOCKING privilege scan cannot DETECT -- "
                "a failed or partial drop would certify clean"
            );
        }
    }

    // ── arm 4: the compensating control that nothing pinned ──────────────

    /// @notice `Validate` must REFUSE a deployment in which an EOA holds `FEE_ACCOUNTING_ROLE` on
    ///         the sUSDfr vault, in the RETAINED posture as well as the production one.
    /// @dev SWEEP-1. Before this test, the only thing standing between an EOA holding
    ///      `FEE_ACCOUNTING_ROLE` and a green validation was a hand-written pair of `require`s in
    ///      `Validate._validateWiring` ("deployer / ops must NOT synchronize fee accounting"), and
    ///      NO TEST IN THE REPO REFERENCED EITHER REVERT STRING — verified by grep. Both were
    ///      deletable with the suite green. `authorityRoleSet()` now carries the role too, but that
    ///      arm only runs in the production shape (`keepOpsAdmin == false`); the RETAINED shape
    ///      asserted here — the owner's actual prod-test posture — is covered by these two
    ///      `require`s and nothing else.
    ///
    ///      WHY IT MATTERS: `FEE_ACCOUNTING_ROLE` gates `sUSDfr.beginFeeNeutralMarkedNavChange`,
    ///      which opens a fee bracket with no obligation to close it in the same transaction. A
    ///      holder that opens one and stops leaves `feeOperationKind != NONE`, and every
    ///      `feeCheckpointEntry` path — `accrueFees`, the waterfall's `beginYieldNotification`
    ///      hand-off, deposit, redeem — reverts until governance revokes the role through the
    ///      2-day timelock. DELETING THE `require` PAIR REDS THIS TEST.
    function test_SWEEP1_validationRefusesAnEoaHoldingTheVaultFeeAccountingRole() public {
        Ctx memory c = _testnetCtx();
        D memory d = _run(c);

        Validate v = new Validate();

        // CONTROL: the very same stack and the very same argument set validate GREEN untouched, so
        // the revert below is attributable to the grant and to nothing else.
        v.validateDeployment(_retainedArgs(d, c));

        IAccessControl(d.vault).grantRole(Roles.FEE_ACCOUNTING_ROLE, c.deployer);
        vm.expectRevert(bytes("deployer must NOT synchronize fee accounting"));
        v.validateDeployment(_retainedArgs(d, c));
    }

    function _retainedArgs(D memory d, Ctx memory c) internal pure returns (Validate.M memory a) {
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
        a.keepOpsAdmin = true; // the RETAINED posture: only the hand-written pair covers it
        a.attesterQuorumIndependent = true;
    }
}
