// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {HandoverOps} from "../../script/Handover.s.sol";
import {PrivilegeAudit} from "../../script/PrivilegeAudit.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title SWEEP-2 — deployment-ceremony enumeration probes
/// @notice Adversarial sweep round 2. Looks for the SEAM-1 SHAPE in places round 1 did not:
///         enumerations that must mirror a source of truth and are pinned by nothing.
contract SweepR2CeremonyEnumerationTest is Test, Deploy, HandoverOps {
    address internal attester2Addr = makeAddr("s2Attester2");
    address internal ops = makeAddr("s2Ops");
    address internal treasury = makeAddr("s2Treasury");
    address internal fees = makeAddr("s2Fees");
    address internal keeper = makeAddr("s2Keeper");
    address internal attester1Addr = makeAddr("s2Attester1");
    address internal currentTreasury;

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

    function _prodCtx() internal view returns (Ctx memory c) {
        c.deployer = address(this);
        c.opsAdmin = ops;
        c.proposalGuardian = attester2Addr;
        c.queueKeeper = keeper;
        c.frTreasury = treasury;
        c.feeRecipient = fees;
        // Independent attester #1, as `DeployMainnet._mainnetContext` requires. Left unset, the
        // testnet default makes the DEPLOYER attester #1 and the "residue" below is that
        // documented Part 11 concession rather than anything new.
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

    // ─────────────────────────────────────────────────────────────────────
    // P1. The authority/operational PARTITION of Roles.sol is unpinned.
    //
    // The generated compiler-AST topology gate pins `PrivilegeAudit.roleSet()` TOTAL over Roles.sol
    // and derives `HandoverOps._authorityRoles()` from the same canonical schema. This regression
    // pins the underlying behavioral partition: every role `roleSet()` scans must be
    // classified into EITHER `_authorityRoles()` or `_operationalRoles()`. A role in neither is
    // SEEN by the receipt and NEVER DROPPED by `_executeHandoverAs`, and is invisible to
    // `_assertNoSurvivingPrivilege` — exactly SEAM-1, one level up from the role identifiers.
    // ─────────────────────────────────────────────────────────────────────
    function test_S2_P1_everyScannedRoleIsClassifiedAsAuthorityOrOperational() public pure {
        (bytes32[] memory ids, string[] memory names) = PrivilegeAudit.roleSet(true);
        bytes32[] memory authority = _authorityRoles();
        bytes32[] memory operational = _operationalRoles();

        uint256 unclassified;
        for (uint256 i = 0; i < ids.length; ++i) {
            if (ids[i] == Roles.ATTESTER_ROLE) continue; // documented Part 11 human gate
            bool found;
            for (uint256 a = 0; a < authority.length; ++a) {
                if (authority[a] == ids[i]) found = true;
            }
            for (uint256 o = 0; o < operational.length; ++o) {
                if (operational[o] == ids[i]) found = true;
            }
            if (!found) {
                console2.log("S2-P1 UNCLASSIFIED (handover will never drop it):", names[i]);
                ++unclassified;
            }
        }
        assertEq(unclassified, 0, "S2-P1: a scanned role is in NEITHER _authorityRoles() nor _operationalRoles()");
    }

    /// @dev The counter-direction: nothing in either drop list may be absent from the scan set,
    ///      or handover drops a role no receipt can report.
    function test_S2_P1b_everyDroppedRoleIsScanned() public pure {
        (bytes32[] memory ids,) = PrivilegeAudit.roleSet(false);
        bytes32[] memory authority = _authorityRoles();
        bytes32[] memory operational = _operationalRoles();
        for (uint256 a = 0; a < authority.length; ++a) {
            assertTrue(_contains(ids, authority[a]), "S2-P1b: an authority role is not in the blocking scan set");
        }
        for (uint256 o = 0; o < operational.length; ++o) {
            assertTrue(_contains(ids, operational[o]), "S2-P1b: an operational role is not in the blocking scan set");
        }
    }

    function _contains(bytes32[] memory set, bytes32 v) private pure returns (bool) {
        for (uint256 i = 0; i < set.length; ++i) {
            if (set[i] == v) return true;
        }
        return false;
    }

    // ─────────────────────────────────────────────────────────────────────
    // P2. Full enumeration of the PRODUCTION-shaped ceremony end state.
    // ─────────────────────────────────────────────────────────────────────
    function test_S2_P2_enumerateProductionShapeResidue() public {
        Ctx memory c = _prodCtx();
        D memory d = _run(c);
        (address[] memory targets, string[] memory names) = PrivilegeAudit.moduleSet(_auditTargets(d));

        string[] memory dep = PrivilegeAudit.scanEverything(targets, names, d.timelock, c.deployer);
        for (uint256 i = 0; i < dep.length; ++i) {
            console2.log("S2-P2 deployer  ->", dep[i]);
        }
        string[] memory opsHeld = PrivilegeAudit.scanEverything(targets, names, d.timelock, c.opsAdmin);
        for (uint256 i = 0; i < opsHeld.length; ++i) {
            console2.log("S2-P2 ops       ->", opsHeld[i]);
        }
        string[] memory keeperHeld = PrivilegeAudit.scanEverything(targets, names, d.timelock, c.queueKeeper);
        for (uint256 i = 0; i < keeperHeld.length; ++i) {
            console2.log("S2-P2 keeper    ->", keeperHeld[i]);
        }
        console2.log("S2-P2 deployer KYC allowlisted:", _isAllowed(d.compliance, c.deployer));
        assertEq(dep.length, 0, "S2-P2: the bootstrap deployer holds something after the production ceremony");
    }

    function _isAllowed(address compliance, address who) private view returns (bool ok) {
        (bool success, bytes memory data) = compliance.staticcall(abi.encodeWithSignature("isAllowed(address)", who));
        require(success, "isAllowed");
        return abi.decode(data, (bool));
    }

    // ─────────────────────────────────────────────────────────────────────
    // P3. The RETAINED (live Sepolia) shape: what the receipt must name.
    // ─────────────────────────────────────────────────────────────────────
    function test_S2_P3_enumerateRetainedShapeResidue() public {
        Ctx memory c = _testnetCtx();
        D memory d = _run(c);
        (address[] memory targets, string[] memory names) = PrivilegeAudit.moduleSet(_auditTargets(d));
        string[] memory dep = PrivilegeAudit.scanEverything(targets, names, d.timelock, c.deployer);
        for (uint256 i = 0; i < dep.length; ++i) {
            console2.log("S2-P3 deployer  ->", dep[i]);
        }
        console2.log("S2-P3 pair count:", dep.length);
        assertGt(dep.length, 0, "S2-P3: the retained shape must enumerate SOMETHING");
    }
}
