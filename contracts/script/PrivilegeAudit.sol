// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {Roles} from "../src/libraries/Roles.sol";

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
        // AUDIT R15-05: FEE_ACCOUNTING_ROLE gates sUSDfr's cross-module fee lock and was absent
        // here, so the durable handover receipt could not name who held it at genesis.
        uint256 n = includeAttester ? 12 : 11;
        ids = new bytes32[](n);
        names = new string[](n);
        ids[0] = bytes32(0);
        names[0] = "DEFAULT_ADMIN_ROLE";
        ids[1] = Roles.UPGRADER_ROLE;
        names[1] = "UPGRADER_ROLE";
        ids[2] = Roles.GUARDIAN_ROLE;
        names[2] = "GUARDIAN_ROLE";
        ids[3] = Roles.MINTER_ROLE;
        names[3] = "MINTER_ROLE";
        ids[4] = Roles.CONTROLLER_ROLE;
        names[4] = "CONTROLLER_ROLE";
        ids[5] = Roles.CREDIT_ROLE;
        names[5] = "CREDIT_ROLE";
        ids[6] = Roles.COMPLIANCE_ADMIN_ROLE;
        names[6] = "COMPLIANCE_ADMIN_ROLE";
        ids[7] = Roles.RESERVE_ADMIN_ROLE;
        names[7] = "RESERVE_ADMIN_ROLE";
        ids[8] = Roles.ORIGINATOR_ROLE;
        names[8] = "ORIGINATOR_ROLE";
        ids[9] = Roles.SERVICER_ROLE;
        names[9] = "SERVICER_ROLE";
        ids[10] = Roles.FEE_ACCOUNTING_ROLE;
        names[10] = "FEE_ACCOUNTING_ROLE";
        if (includeAttester) {
            ids[11] = Roles.ATTESTER_ROLE;
            names[11] = "ATTESTER_ROLE";
        }
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
        ids = new bytes32[](6);
        names = new string[](6);
        ids[0] = bytes32(0);
        names[0] = "DEFAULT_ADMIN_ROLE";
        ids[1] = Roles.UPGRADER_ROLE;
        names[1] = "UPGRADER_ROLE";
        ids[2] = Roles.MINTER_ROLE;
        names[2] = "MINTER_ROLE";
        ids[3] = Roles.CONTROLLER_ROLE;
        names[3] = "CONTROLLER_ROLE";
        ids[4] = Roles.CREDIT_ROLE;
        names[4] = "CREDIT_ROLE";
        ids[5] = Roles.RESERVE_ADMIN_ROLE;
        names[5] = "RESERVE_ADMIN_ROLE";
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
    /// @return ids The timelock role identifiers, in scan order.
    /// @return names The human-readable role names, index-aligned with `ids`.
    function timelockRoleSet() internal pure returns (bytes32[] memory ids, string[] memory names) {
        ids = new bytes32[](3);
        names = new string[](3);
        ids[0] = keccak256("PROPOSER_ROLE");
        names[0] = "TIMELOCK_PROPOSER_ROLE";
        ids[1] = keccak256("CANCELLER_ROLE");
        names[1] = "TIMELOCK_CANCELLER_ROLE";
        ids[2] = keccak256("EXECUTOR_ROLE");
        names[2] = "TIMELOCK_EXECUTOR_ROLE";
    }

    /// @notice The DANGEROUS subset of the timelock's own roles: the ones that confer
    ///         DEFAULT_ADMIN-equivalent power given the open-executor topology.
    /// @dev `EXECUTOR_ROLE` is deliberately excluded — it is granted to `address(0)` by
    ///      design, so an EOA additionally holding it confers nothing it does not already
    ///      have. `PROPOSER` + `CANCELLER` are the ones that must never sit on a hot key.
    /// @return ids The role identifiers, in scan order.
    /// @return names The human-readable role names, index-aligned with `ids`.
    function timelockAuthorityRoleSet() internal pure returns (bytes32[] memory ids, string[] memory names) {
        ids = new bytes32[](2);
        names = new string[](2);
        ids[0] = keccak256("PROPOSER_ROLE");
        names[0] = "TIMELOCK_PROPOSER_ROLE";
        ids[1] = keccak256("CANCELLER_ROLE");
        names[1] = "TIMELOCK_CANCELLER_ROLE";
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
        (bytes32[] memory ids, string[] memory names) = dangerousOnly ? timelockAuthorityRoleSet() : timelockRoleSet();
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
    ///         included) PLUS the timelock's own PROPOSER/CANCELLER/EXECUTOR roles.
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
    /// @param m The 17 module addresses, in the order documented by `NAMES`.
    /// @return targets The addresses (a copy of `m`).
    /// @return names The index-aligned module names.
    function moduleSet(address[17] memory m) internal pure returns (address[] memory targets, string[] memory names) {
        string[17] memory n = [
            "compliance",
            "usdfr",
            "reserves",
            "controller",
            "vault",
            "points",
            "registry",
            "oracle",
            "bridge",
            "curator",
            "waterfall",
            "defaultManager",
            "assessedImpairmentSource",
            "queue",
            "sGrove",
            "grove",
            "timelock"
        ];
        targets = new address[](17);
        names = new string[](17);
        for (uint256 i = 0; i < 17; ++i) {
            targets[i] = m[i];
            names[i] = n[i];
        }
    }
}
