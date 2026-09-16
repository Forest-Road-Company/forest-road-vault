// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {PrivilegeTopology} from "./generated/PrivilegeTopology.sol";

/// @title PrivilegeAudit
/// @notice Enumerates which privileged (module, role) pairs a given EOA still holds across
///         the deployed stack.
/// @dev AUDIT FIX (C-01). The deployer EOA holding `DEFAULT_ADMIN_ROLE` is a posture the
///      owner deliberately retains during testing and the hands-on prod-test window — that
///      is NOT the defect. The defect was that a deploy which retained a hot admin key and a
///      deploy that handed over cleanly produced IDENTICAL green validation output, so the
///      operator had no receipt of which posture they were actually in.
///
///      This library is the shared enumeration used by BOTH `Deploy.s.sol` (which writes the
///      result into the deployment manifest, making it a durable artifact) and
///      `Validate.s.sol` (which prints it as an unmissable `RETAINED PRIVILEGE` block).
///      Because both read the same code path, the manifest and the console can never
///      disagree about what the EOA holds.
library PrivilegeAudit {
    /// @notice The canonical privileged role set scanned on every module.
    /// @dev Mirrors `src/libraries/Roles.sol` plus `DEFAULT_ADMIN_ROLE` (0x00). `hasRole`
    ///      returns false for a role a given module never defines, so one flat list is safe
    ///      to apply to every AccessControl module in the stack.
    /// @param includeAttester Whether to include `ATTESTER_ROLE`. The attester set is a
    ///        Part 11 human gate (real attester keys are not known at deploy time), so the
    ///        production-shape *assertion* excludes it while the operator-facing *receipt*
    ///        includes it.
    /// @return ids The role identifiers, in scan order.
    /// @return names The human-readable role names, index-aligned with `ids`.
    function roleSet(bool includeAttester) internal pure returns (bytes32[] memory ids, string[] memory names) {
        return PrivilegeTopology.roleSet(includeAttester);
    }

    /// @notice The AUTHORITY subset: protocol-level power over value, upgrades, or the role
    ///         graph itself. Must be held only by the governance timelock in the production
    ///         shape. Mirrors `HandoverOps._authorityRoles()`.
    /// @dev Deliberately excludes the OPERATIONAL roles (GUARDIAN / COMPLIANCE_ADMIN /
    ///      ORIGINATOR / SERVICER), which the ops EOA legitimately keeps after handover —
    ///      `Validate.s.sol` positively REQUIRES ops to hold SERVICER and ORIGINATOR — and
    ///      `ATTESTER_ROLE`, a Part 11 human gate.
    /// @return ids The role identifiers, in scan order.
    /// @return names The human-readable role names, index-aligned with `ids`.
    function authorityRoleSet() internal pure returns (bytes32[] memory ids, string[] memory names) {
        return PrivilegeTopology.authorityRoleSet();
    }

    /// @notice `TimelockController`'s OWN role graph.
    /// @dev AUDIT FIX (C-01 round 2). `roleSet`/`authorityRoleSet` enumerate only the
    ///      identifiers in `src/libraries/Roles.sol`, so the three roles that govern the
    ///      timelock itself were invisible to every receipt and every assertion — on the very
    ///      target this library singles out as "the single most dangerous key in the system".
    ///      `Deploy` grants `EXECUTOR_ROLE` to `address(0)` (open executor), so ANY holder of
    ///      `PROPOSER_ROLE` can schedule an arbitrary call and self-execute it after
    ///      `minDelay` — that is DEFAULT_ADMIN-equivalent authority over every module, merely
    ///      delayed. `CANCELLER_ROLE` is a governance-liveness weapon (it can veto every
    ///      proposal). Both must be enumerated and, in the production shape, asserted absent
    ///      from both EOAs.
    /// @dev ── AUDIT FIX (SWEEP-3 S3-01) — THIS IS NOW THE SOLE DEFINITION. DO NOT RE-DUPLICATE. ──
    ///
    ///      WHAT WAS WRONG. Every MODULE role in this repo is referenced through
    ///      `src/libraries/Roles.sol`, and the generated `PrivilegeTopology` pins the audit's
    ///      enumeration to the canonical JSON schema. The TIMELOCK's three roles had no such library:
    ///      `timelockRoleSet`, `timelockAuthorityRoleSet` and `HandoverOps._timelockRoles` each
    ///      rebuilt them from `keccak256("...")` STRING LITERALS — EIGHT literals across two files
    ///      — while `Validate._validateGovernance` reads the same roles from the contract's own
    ///      `tl.PROPOSER_ROLE()` / `tl.EXECUTOR_ROLE()` getters two hundred lines away. Two
    ///      enumerations of one quantity, and nothing compared them to each other or to the getters.
    ///
    ///      WHY A TYPO WAS INVISIBLE. A mistyped literal makes `scanTimelock` return the EMPTY SET
    ///      for that role, which SILENTLY SATISFIES every consumer, because all four assert
    ///      `... .length == 0`. A shrinking role set satisfies a `== 0` assertion MORE easily,
    ///      never less. MEASURED (sweep round 3): typing `keccak256("CANCELER_ROLE")` here left the
    ///      whole 1,435-test audit+integration+unit set green, and the same typo in
    ///      `HandoverOps._timelockRoles` — the list the one-command exit actually DROPS and then
    ///      asserts none survived — left the entire 121-test deployment-ceremony set green.
    ///
    ///      The generated topology reads this set from the deployed Timelock getters, so no
    ///      consumer can silently drift from the live role graph.
    /// @return ids The timelock role identifiers, in scan order.
    /// @return names The human-readable role names, index-aligned with `ids`.
    function timelockRoleSet(address timelock) internal view returns (bytes32[] memory ids, string[] memory names) {
        return PrivilegeTopology.timelockRoleSet(timelock);
    }

    /// @notice The DANGEROUS subset of the timelock's own roles: the ones that confer
    ///         DEFAULT_ADMIN-equivalent power given the open-executor topology.
    /// @dev `EXECUTOR_ROLE` is deliberately excluded — it is granted to `address(0)` by
    ///      design, so an EOA additionally holding it confers nothing it does not already
    ///      have. `PROPOSER` + `CANCELLER` are the ones that must never sit on a hot key.
    /// @dev The generated topology owns this dangerous subset alongside the complete timelock set.
    /// @return ids The role identifiers, in scan order.
    /// @return names The human-readable role names, index-aligned with `ids`.
    function timelockAuthorityRoleSet(address timelock)
        internal
        view
        returns (bytes32[] memory ids, string[] memory names)
    {
        return PrivilegeTopology.timelockAuthorityRoleSet(timelock);
    }

    /// @notice Scan the timelock's own role graph for what `subject` holds on it.
    /// @param timelock The TimelockController address.
    /// @param subject The EOA being enumerated.
    /// @param dangerousOnly When true, scan only PROPOSER/CANCELLER (see
    ///        `timelockAuthorityRoleSet`); when false, include EXECUTOR too.
    /// @return entries `"timelock.<ROLE>"` for each held pair.
    function scanTimelock(address timelock, address subject, bool dangerousOnly)
        internal
        view
        returns (string[] memory entries)
    {
        (bytes32[] memory ids, string[] memory names) =
            dangerousOnly ? timelockAuthorityRoleSet(timelock) : timelockRoleSet(timelock);
        address[] memory targets = new address[](1);
        string[] memory targetNames = new string[](1);
        targets[0] = timelock;
        targetNames[0] = "timelock";
        return scanRoles(targets, targetNames, ids, names, subject);
    }

    /// @notice Scan every (module, role) pair and return the ones `subject` holds.
    /// @dev Two passes (count, then fill) so the returned array is exactly sized and can be
    ///      serialized straight into the manifest JSON. Every target MUST implement
    ///      `IAccessControl` — a non-AccessControl target reverts here rather than being
    ///      silently skipped (CLAUDE.md §0.4, fail loudly).
    /// @param targets Module addresses to scan.
    /// @param targetNames Human-readable module names, index-aligned with `targets`.
    /// @param subject The EOA whose retained privilege is being enumerated.
    /// @param includeAttester See `roleSet`.
    /// @return entries `"<module>.<ROLE>"` for each held pair; empty when the subject is clean.
    function scan(address[] memory targets, string[] memory targetNames, address subject, bool includeAttester)
        internal
        view
        returns (string[] memory entries)
    {
        (bytes32[] memory ids, string[] memory roleNames) = roleSet(includeAttester);
        return scanRoles(targets, targetNames, ids, roleNames, subject);
    }

    /// @notice Scan an explicit role set and return the (module, role) pairs `subject` holds.
    /// @param targets Module addresses to scan.
    /// @param targetNames Human-readable module names, index-aligned with `targets`.
    /// @param ids The role identifiers to scan.
    /// @param roleNames Human-readable role names, index-aligned with `ids`.
    /// @param subject The EOA whose retained privilege is being enumerated.
    /// @return entries `"<module>.<ROLE>"` for each held pair; empty when the subject is clean.
    function scanRoles(
        address[] memory targets,
        string[] memory targetNames,
        bytes32[] memory ids,
        string[] memory roleNames,
        address subject
    ) internal view returns (string[] memory entries) {
        require(targets.length == targetNames.length, "PrivilegeAudit: name/target length mismatch");
        require(ids.length == roleNames.length, "PrivilegeAudit: role/name length mismatch");

        uint256 count;
        for (uint256 i = 0; i < targets.length; ++i) {
            for (uint256 r = 0; r < ids.length; ++r) {
                if (IAccessControl(targets[i]).hasRole(ids[r], subject)) ++count;
            }
        }

        entries = new string[](count);
        uint256 k;
        for (uint256 i = 0; i < targets.length; ++i) {
            for (uint256 r = 0; r < ids.length; ++r) {
                if (IAccessControl(targets[i]).hasRole(ids[r], subject)) {
                    entries[k] = string.concat(targetNames[i], ".", roleNames[r]);
                    ++k;
                }
            }
        }
    }

    /// @notice The COMPLETE privilege receipt for `subject`: every module role (attester
    ///         included) and the timelock's own PROPOSER/CANCELLER/EXECUTOR roles.
    /// @dev AUDIT FIX (C-01 round 2). This is what an operator-facing receipt must print. A
    ///      receipt that omits a role class is the C-01 failure mode (green, detail-free
    ///      output over a dangerous posture) reproduced one layer up.
    /// @param targets Module addresses to scan.
    /// @param targetNames Human-readable module names, index-aligned with `targets`.
    /// @param timelock The TimelockController address (scanned for its own role graph).
    /// @param subject The EOA whose privilege is being enumerated.
    /// @return entries `"<module>.<ROLE>"` for every held pair.
    function scanEverything(address[] memory targets, string[] memory targetNames, address timelock, address subject)
        internal
        view
        returns (string[] memory entries)
    {
        string[] memory modulePairs = scan(targets, targetNames, subject, true);
        string[] memory timelockPairs = scanTimelock(timelock, subject, false);
        entries = new string[](modulePairs.length + timelockPairs.length);
        for (uint256 i = 0; i < modulePairs.length; ++i) {
            entries[i] = modulePairs[i];
        }
        for (uint256 i = 0; i < timelockPairs.length; ++i) {
            entries[modulePairs.length + i] = timelockPairs[i];
        }
    }

    /// @notice The canonical AccessControl-bearing module set, as (address, name) lists.
    /// @dev `FRGovernor` is deliberately excluded: it is `Governor`-gated, not AccessControl,
    ///      so `hasRole` would revert. The `TimelockController` IS included — its
    ///      `DEFAULT_ADMIN_ROLE` is the single most dangerous key in the system.
    /// @param m The named module addresses from the canonical privilege schema.
    /// @return targets The addresses in generated order.
    /// @return names The index-aligned generated module names.
    function moduleSet(PrivilegeTopology.ModuleAddresses memory m)
        internal
        pure
        returns (address[] memory targets, string[] memory names)
    {
        (targets, names) = PrivilegeTopology.moduleSet(m);
        requireDistinctModules(targets);
    }

    /// @notice Fail LOUDLY if a module list contains a zero address or the same address twice.
    /// @dev ── AUDIT FIX (SWEEP-3 S3-02) — LOAD-BEARING, DO NOT DELETE. ──────────────────────────
    ///
    ///      WHAT WAS WRONG. `moduleSet` supplies the NAMES POSITIONALLY, and the caller supplies a
    ///      FIXED-LENGTH `address[17]` literal — one each in `Deploy._auditTargets`,
    ///      `Handover._refreshManifestReceipt` and `Validate._reportPrivilegePosture`. A duplicated
    ///      or reordered entry therefore both REMOVES a module from every blocking scan AND
    ///      mislabels the durable receipt, with NO COMPILE ERROR, because the length is unchanged.
    ///
    ///      MEASURED (sweep round 3): replacing `a.usdfr` with a duplicate `a.vault` in
    ///      `Validate._reportPrivilegePosture` let an OPS KEY HOLDING `MINTER_ROLE` ON USDfr —
    ///      unbacked mint, straight past `MintRedeemController._assertBacking` — pass BOTH
    ///      `validateDeployment` and `validateHandover` green (`_validateWiring` spells out
    ///      `!hasRole(MINTER_ROLE, deployer)` and has no ops equivalent, so the authority scan is
    ///      the SOLE detector). The identical edit in `Handover._refreshManifestReceipt` reddened
    ///      NOTHING AT ALL — that literal is unreachable from any test.
    ///
    ///      WHY THE CHECK LIVES HERE. The three literals are built from three different structs, so
    ///      they cannot share one expression — but they all funnel through THIS function, so one
    ///      check covers all three and any future fourth. Every module in the set is a distinct
    ///      deployed contract, so a duplicate or a zero is unambiguously a mis-copied literal.
    ///      Pinned by `test_S3_C_theAuditModuleListAndTheHandoverModuleListAgree` and by the
    ///      end-to-end `test_S3_C_e2e_opsHoldingUsdfrMinterIsRefusedByProductionValidation`.
    /// @param targets The module addresses to check.
    function requireDistinctModules(address[] memory targets) internal pure {
        for (uint256 i = 0; i < targets.length; ++i) {
            require(targets[i] != address(0), "PrivilegeAudit: module list has a ZERO address");
            for (uint256 j = 0; j < i; ++j) {
                require(targets[i] != targets[j], "PrivilegeAudit: module list has a DUPLICATE entry");
            }
        }
    }
}
