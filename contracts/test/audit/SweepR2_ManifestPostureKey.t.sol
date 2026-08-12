// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {Handover, HandoverOps} from "../../script/Handover.s.sol";
import {Validate} from "../../script/Validate.s.sol";

contract SweepR2HandoverExposed is Handover {
    function refreshManifestReceipt(string memory path, Targets memory t, address deployer, address opsAdmin)
        external
    {
        _refreshManifestReceipt(path, t, deployer, opsAdmin);
    }
}

/// @dev `Validate._load()` is `internal view` and reads `_manifestPath()`. This exposes the exact
///      posture-resolution expression from `_load` against an arbitrary manifest string, so the
///      test measures the SHIPPED precedence rule and not a paraphrase of it.
contract SweepR2PostureReader is Validate {
    function posture(string memory manifest) external view returns (bool keepOpsAdmin) {
        // VERBATIM from Validate._load():
        //   a.keepOpsAdmin = vm.keyExistsJson(manifest, ".keepOpsAdmin")
        //       ? vm.parseJsonBool(manifest, ".keepOpsAdmin")
        //       : vm.parseJsonBool(manifest, ".TESTNET_keepOpsAdmin");
        return vm.keyExistsJson(manifest, ".keepOpsAdmin")
            ? vm.parseJsonBool(manifest, ".keepOpsAdmin")
            : vm.parseJsonBool(manifest, ".TESTNET_keepOpsAdmin");
    }
}

/// @title SWEEP-2 — the handover refreshes the posture key `Validate` does NOT read
/// @notice TWO KEYS THAT MUST MIRROR AND DO NOT.
///
///         `Deploy._writeManifest` writes BOTH `keepOpsAdmin` (unconditionally) and
///         `TESTNET_keepOpsAdmin` (on the non-production profile). `Validate._load` resolves the
///         posture by PREFERRING `.keepOpsAdmin`. `Handover._refreshManifestReceipt` rewrites
///         ONLY `.TESTNET_keepOpsAdmin`, and its own fail-loudly self-check
///         (`require(!vm.parseJsonBool(written, ".TESTNET_keepOpsAdmin"), "manifest posture not
///         updated")`) verifies only that same non-preferred key.
///
///         BEFORE THE FIX: the live `deployments/11155111.json` carries BOTH keys, both `true`,
///         so after the advertised one-command exit a later `forge script script/Validate.s.sol` — the
///         CLAUDE.md §2.1 post-deploy validation — resolves `keepOpsAdmin = true`, takes the
///         RETAINED branch, SKIPS every production-shape assertion in
///         `_reportPrivilegePosture`, and prints "This deployment did NOT hand over. Privileged
///         keys are still held." over a stack that DID hand over.
///
///         WHY THE EXISTING REGRESSION TEST CANNOT SEE IT:
///         `Fix_C01-deploy-tooling.t.sol::test_round2_handoverRefreshesTheDurableManifestReceipt`
///         builds its fixture manifest with `TESTNET_keepOpsAdmin` ONLY — a shape `Deploy` has
///         never produced — so the preferred key is absent and the fallback silently gives the
///         right answer. The gate is green on a manifest shape that does not exist.
contract SweepR2ManifestPostureKeyTest is Test, Deploy, HandoverOps {
    address internal attester2Addr = makeAddr("s2mAttester2");
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

    function _run(Ctx memory c) internal returns (D memory d) {
        currentTreasury = c.frTreasury;
        d = _deployAll(c);
        _wire(d, c);
        _seed(d, c);
        _handover(d, c);
    }

    function _targets(D memory d) internal view returns (Targets memory t) {
        t = Targets({
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
            timelock: d.timelock,
            governor: d.governor,
            votesAggregator: d.votesAggregator,
            frTreasury: currentTreasury
        });
    }

    /// @notice PRECONDITION, measured not assumed: the LIVE Sepolia manifest — the artifact the
    ///         one-command exit is documented to run against — carries BOTH posture keys.
    function test_S2_F3_theLiveManifestCarriesBothPostureKeys() public view {
        string memory live = vm.readFile("deployments/11155111.json");
        assertTrue(vm.keyExistsJson(live, ".keepOpsAdmin"), "live manifest has .keepOpsAdmin");
        assertTrue(vm.keyExistsJson(live, ".TESTNET_keepOpsAdmin"), "live manifest has .TESTNET_keepOpsAdmin");
        assertTrue(vm.parseJsonBool(live, ".keepOpsAdmin"), "live .keepOpsAdmin is true (retained posture)");
        assertTrue(vm.parseJsonBool(live, ".TESTNET_keepOpsAdmin"), "live .TESTNET_keepOpsAdmin is true");
    }

    /// @notice THE FINDING, executed on a `Deploy`-SHAPED manifest (both keys, as `Deploy`
    ///         actually writes them).
    function test_S2_F3_handoverRefreshesThePostureKeyValidateActuallyReads() public {
        Ctx memory c = _testnetCtx();
        D memory d = _run(c);
        _executeHandover(_targets(d), address(this), address(this));

        string memory path = "deployments/_sweepR2_posture.json";
        {
            string memory j = "s2Posture";
            vm.serializeAddress(j, "deployer", address(this));
            vm.serializeAddress(j, "opsAdmin", address(this));
            vm.serializeAddress(j, "proposalGuardian", c.proposalGuardian);
            vm.serializeBool(j, "TESTNET_keepOpsAdmin", true);
            // THE DIFFERENCE FROM THE EXISTING REGRESSION FIXTURE: `Deploy._writeManifest`
            // ALWAYS writes this key, and the live Sepolia artifact has it.
            string memory out = vm.serializeBool(j, "keepOpsAdmin", true);
            vm.writeJson(out, path);
        }

        SweepR2HandoverExposed h = new SweepR2HandoverExposed();
        h.refreshManifestReceipt(path, _targets(d), address(this), address(this));

        string memory written = vm.readFile(path);
        // The handover's own self-check passes: it verifies the key it wrote.
        assertFalse(vm.parseJsonBool(written, ".TESTNET_keepOpsAdmin"), "the non-preferred key WAS updated");

        SweepR2PostureReader reader = new SweepR2PostureReader();
        bool resolved = reader.posture(written);
        console2.log("S2-F3 .keepOpsAdmin after handover:", vm.parseJsonBool(written, ".keepOpsAdmin"));
        console2.log("S2-F3 .TESTNET_keepOpsAdmin after handover:", vm.parseJsonBool(written, ".TESTNET_keepOpsAdmin"));
        console2.log("S2-F3 posture Validate._load would resolve:", resolved);
        vm.removeFile(path);

        // ═══════════════════════════════════════════════════════════════════════════════════
        // INVERTED — DO NOT RESTORE THE ORIGINAL ASSERTION.
        //
        // This assertion was written as `assertTrue(resolved, ...)` and it PASSED on the tree as
        // received, with the measured log:
        //     S2-F3 .keepOpsAdmin after handover: true
        //     S2-F3 .TESTNET_keepOpsAdmin after handover: false
        //     S2-F3 posture Validate._load would resolve: true
        // i.e. a COMPLETED one-command exit left the durable artifact resolving the RETAINED
        // posture, so a later `forge script script/Validate.s.sol` skipped every production-shape
        // assertion and printed "This deployment did NOT hand over." Leaving the test asserting
        // `true` would have pinned that as intended behaviour.
        // ═══════════════════════════════════════════════════════════════════════════════════
        assertFalse(
            resolved,
            "S2-F3: Validate._load must resolve the PRODUCTION posture after a completed handover "
            "-- otherwise every production-shape assertion in _reportPrivilegePosture is skipped"
        );
    }

    /// @notice DISCRIMINATING CONTROL. On the fixture shape the EXISTING regression test uses
    ///         (`TESTNET_keepOpsAdmin` only, a shape `Deploy` never writes), the refresh looks
    ///         correct — which is exactly why the shipped gate is green.
    function test_S2_F3_control_theExistingFixtureShapeHidesIt() public {
        Ctx memory c = _testnetCtx();
        D memory d = _run(c);
        _executeHandover(_targets(d), address(this), address(this));

        string memory path = "deployments/_sweepR2_posture_legacy.json";
        {
            string memory j = "s2PostureLegacy";
            vm.serializeAddress(j, "deployer", address(this));
            vm.serializeAddress(j, "opsAdmin", address(this));
            vm.serializeAddress(j, "proposalGuardian", c.proposalGuardian);
            string memory out = vm.serializeBool(j, "TESTNET_keepOpsAdmin", true);
            vm.writeJson(out, path);
        }
        SweepR2HandoverExposed h = new SweepR2HandoverExposed();
        h.refreshManifestReceipt(path, _targets(d), address(this), address(this));

        string memory written = vm.readFile(path);
        SweepR2PostureReader reader = new SweepR2PostureReader();
        bool resolved = reader.posture(written);
        vm.removeFile(path);
        assertFalse(resolved, "control: with only the legacy key present the fallback resolves correctly");
    }
}
