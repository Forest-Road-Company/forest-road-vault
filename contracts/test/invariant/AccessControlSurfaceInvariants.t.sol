// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {console2} from "forge-std/console2.sol";

import {PointsModule} from "../../src/PointsModule.sol";
import {RecoveryTopUpDistributor} from "../../src/RecoveryTopUpDistributor.sol";
import {GroveToken} from "../../src/GroveToken.sol";
import {SGrove} from "../../src/SGrove.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {PrivilegedSurface} from "../helpers/PrivilegedSurface.sol";
import {RealOracleFixture} from "../helpers/RealOracleFixture.sol";
import {AccessControlSurfaceHandler} from "./handlers/AccessControlSurfaceHandler.sol";
import {GuardProbe} from "./handlers/GuardProbe.sol";

/// @title INV_AccessControlSurface
/// @notice CLAUDE.md §1.3, ACCESS CONTROL: "no privileged action is reachable by an unauthorized
///         role in any state." AUDIT FINDING G11/G12.1 — before this suite that clause had no
///         exhaustive test.
///
///         WHAT WAS ACTUALLY THERE, AND WHY IT WAS NOT ENOUGH. The finding as written says no
///         access-control invariant exists; that is not quite right and the correction matters.
///         `INV_CreditGateAndAuthorisation.invariant_INV18_noUnauthorisedStateChange` does exist
///         and is a good test. But its probe table
///         (`CreditGateAuthorisationHandler._probe`) is 29 hand-written calldata blobs naming 25
///         distinct privileged functions, while `src/` carries 136 role guards — 119 of them on
///         externally callable functions. So the §1.3 property was established for about a fifth
///         of the privileged surface; 92 selectors, including `ReserveManager.recordDeployment`
///         (the reserve-release path facility funding uses), had no invariant-level probe at all.
///         And nothing tied the table to the code: a privileged function added tomorrow would
///         never be probed and INV-18 would stay green. A hand-maintained table of a growing
///         surface is a decaying assurance, and it decays silently.
///
///         WHAT THIS SUITE ASSERTS. Every one of the 119 externally reachable role-guarded entry
///         points, enumerated at run time from `src/` plus the compiled artifacts
///         (`PrivilegedSurface`), refuses a caller holding no role — with OZ's exact
///         `AccessControlUnauthorizedAccount` selector, not merely "it reverted" (CLAUDE.md §1.1)
///         — across every state the campaign reaches: paused and unpaused, empty and funded
///         vault, with and without a queued redemption, mid-settlement, at arbitrary times.
///
/// @dev NON-VACUITY IS THE POINT OF THIS FILE, so it is proven three ways and not asserted by
///      adjective:
///        1. `test_acl_everyPrivilegedSelectorRefusesEveryUnauthorisedActor` sweeps all 119 × 4
///           deterministically and asserts that the number REFUSED BY THE ROLE CHECK equals the
///           full surface. Not "≥ 1", not "most" — every single one. If a guard is deleted, a
///           role is misconfigured onto an outsider, or a modifier is reordered behind a check
///           that reverts first, that entry stops being role-refused and the count is short.
///        2. `test_acl_surfaceEnumerationIsExhaustiveAndDriftProof` pins the per-module guard
///           counts. Deleting an `onlyRole` no longer merely removes a probe silently; it fails.
///        3. `test_acl_everyPrivilegedSelectorRefusesInEveryProtocolState` re-sweeps the whole
///           surface in four CONSTRUCTED shapes — unpaused/empty, funded vault, queued
///           redemption, fully paused — so "in any state" is demonstrated rather than left to
///           whichever states a fuzz run happened to visit. `afterInvariant` REPORTS the
///           campaign's own state-shape counters but does not assert them; see the note there
///           for why a per-run assertion on those would be a flaky gate.
///
/// @dev DO NOT convert this back into a static table, and do not delete the `fs_permissions`
///      entries in `foundry.toml` that let it read `src/` and `out/`. The static table is the
///      defect this suite exists to retire.
/// @dev FIXTURE CHOICE, AND A TRAP THIS SUITE ALREADY CAUGHT. The base is `RealOracleFixture`, so
///      `oracle` is the PRODUCTION `AttestationOracle`. The first run of this suite was written
///      against `GovernanceFixture`, whose oracle is `MockAttestationOracle`, and it reported
///      eight access-control bypasses on
///      `AttestationOracle.pause/unpause/consume/revoke/setThreshold` — the mock has no access
///      control at all. That is the correct failure for a probe that calls whatever is deployed
///      at the address, and it is why this assertion earns its place: the previous 29-entry hand
///      table never touched the oracle's admin surface, so nothing in the invariant tier would
///      have noticed either way. DO NOT re-base this suite on a fixture that mocks a module whose
///      privileged surface it enumerates — the suite would go green against the mock.
///      GROVE and sGROVE are deployed here (rather than by inheriting `GovernanceFixture`) only
///      because inheriting both fixtures is a diamond; the eight guards they carry are part of
///      the enumerated surface and must be probed against the real contracts.
contract INV_AccessControlSurface is RealOracleFixture, PrivilegedSurface {
    AccessControlSurfaceHandler internal handler;

    PointsModule internal points;
    RecoveryTopUpDistributor internal recovery;
    GroveToken internal grove;
    SGrove internal sGrove;
    address internal frTreasury = makeAddr("aclForestRoadTreasury");

    /// @dev The measured size of the privileged surface at the time this suite was written.
    ///      Pinned so that a change to the protocol's privileged surface is a DELIBERATE
    ///      re-baseline with a fresh reading of the table, never a silent drift in either
    ///      direction. Raise it when you add a privileged function; lower it only alongside a
    ///      note saying which guard was intentionally removed and why.
    // AUDIT NOTE (merge, 2026-08-07): re-pinned 117 -> 119 because the G3 conservative-marks fix
    // adds `ReserveManager.recognizePrincipalImpairment` and `releasePrincipalImpairment`, both
    // `onlyRole(DEFAULT_ADMIN_ROLE)`. The drift gate firing on that is the gate WORKING — it is
    // pinned deliberately so a surface change cannot land silently. Re-pin only alongside a
    // reviewed change, never to make a red suite green.
    // AUDIT NOTE (R6-CF1, 2026-08-07): re-pinned 119 -> 123 because the reserve-CUSTODY arm of the
    // curator withdrawal freeze adds four privileged entry points to `CuratorModule`:
    // `setReserveManager` and `setGovernor` and `cancelCustodyPreArm` (all DEFAULT_ADMIN_ROLE) and
    // `preArmCustodyFreeze` (GUARDIAN_ROLE). The gate firing on that is the gate WORKING. All four
    // are probed automatically by this suite's runtime enumeration, so the added surface arrives
    // with unauthorised-caller coverage rather than needing hand-written tests.
    // AUDIT NOTE (F3-PA-a, 2026-08-07): re-pinned 123 -> 124 because closing the guardian pre-arm
    // budget trap adds `CuratorModule.replenishCustodyPreArmBudget` (DEFAULT_ADMIN_ROLE) — the
    // lever that returns the guardian's budget WITHOUT clearing the standing pre-arm.
    // `cancelCustodyPreArm` was previously the only replenishment path and it zeroes
    // `custodyPreArmExpiry`, so regaining budget destroyed the active protection. This gate firing
    // on the addition is the gate WORKING; it is re-pinned deliberately, alongside the reviewed
    // change, and the new entry point picks up unauthorised-caller coverage automatically from
    // this suite's runtime enumeration.
    // AUDIT NOTE (R17-01, 2026-08-07): re-pinned 124 -> 125 because the recapitalisation path adds
    // exactly ONE privileged entry point, `ReserveManager.creditUnrecordedUSDC`
    // (RESERVE_ADMIN_ROLE) -- the role-gated credit for USDC ALREADY sitting unrecorded in the
    // contract. Crediting a pre-existing surplus is a VALUATION act (a governance write-down
    // deliberately leaves `live > recorded`), so it is authenticated. The other two functions added
    // by the same fix are deliberately NOT privileged and correctly do not move this number:
    // `recapitalize` is permissionless (a deadlock cure must not itself need a role) and
    // `unrecordedUSDC` is a view. This gate firing on the addition is the gate WORKING; it is
    // re-pinned deliberately, alongside the reviewed change, and the new entry point picks up
    // unauthorised-caller coverage automatically from this suite's runtime enumeration.
    // AUDIT NOTE (R18 merge adjudication, 2026-08-08): re-pinned 125 -> 127 because the
    // controller least-privilege work adds exactly two DEFAULT_ADMIN_ROLE entry points:
    // `MintRedeemController.setYieldSink` and `MintRedeemController.setLossSource`. Both are
    // present in the runtime probe table and exercised against unauthorised callers.
    // AUDIT NOTE (G2W, OWNER DECISION 2026-08-07): re-pinned 127 -> 128 because the unattested
    // past-due forward weight adds `CollateralRegistry.setPastDueWeight` (DEFAULT_ADMIN_ROLE) --
    // the timelocked lever that sets how much forward weight a permissionless, unattested
    // `markPastDue` carries relative to an attested `declareDefault`. Its bounds (reject 0, reject
    // >= BPS) are what stop governance re-opening H-5 or restoring the defect by transaction, so
    // it MUST be role-gated. The two other functions the same fix adds are deliberately NOT
    // privileged and correctly do not move this number: `conservativeSeniorMark` and
    // `pastDueRampWeightBps` are views. This gate firing on the addition is the gate WORKING; it is
    // re-pinned deliberately, alongside the reviewed change, and the new entry point picks up
    // unauthorised-caller coverage automatically from this suite's runtime enumeration.
    // AUDIT NOTE (W6-B3, 2026-08-10): re-pinned 128 -> 129 because the governed
    // `DefaultManager.initializeCommitmentLedger` migration entry point is a new
    // DEFAULT_ADMIN_ROLE selector. It is intentionally enumerated and exercised
    // by this runtime surface; this records the reviewed addition rather than
    // weakening the exhaustive count.
    // AUDIT NOTE (four-input merge, 2026-08-10): re-pinned 129 -> 133 after mechanically diffing
    // the live surface against frozen W7. The arm-bound ReserveManager composition adds
    // `setReserveLossModules`, `armReserveLossFreeze`, `cancelAndDisable`,
    // `setGuardianReserveLossArmsEnabled`, and `finalizeAndDisable`; the Curator composition adds
    // `governanceUnpause`. The selected merge also removes the obsolete
    // `creditUnrecordedUSDC` and `writeDownIdleUSDC` role-gated selectors: +6 - 2 = +4 net.
    // Runtime enumeration loaded all 133 entries, and the deterministic four-state sweep refused
    // every entry on access control before this pin was moved. This is therefore a reviewed union,
    // not a count changed merely to turn a red test green.
    // AUDIT NOTE (ADR-0035, 2026-08-11): re-pinned 133 -> 132 because the owner decision retires
    // `SGrove.setPerEventCap` together with the per-event ceiling it governed. Runtime enumeration
    // removed exactly that selector; no surviving privileged selector was removed from the probe.
    uint256 internal constant EXPECTED_SURFACE = 132;
    /// @dev Distinct role-guarded function NAMES in `src/`, counting BOTH guard styles the
    ///      repository uses (`onlyRole` modifiers, 148 distinct names, plus `USDfr.burn`'s inline
    ///      `_checkRole`) and INCLUDING internal ones such as `_authorizeUpgrade` that carry no
    ///      selector of their own. 149 - 132 = 17 internal.
    // AUDIT NOTE (F3-PA-a): +1 for `replenishCustodyPreArmBudget`, see the note above.
    // AUDIT NOTE (R17-01): +1 for `creditUnrecordedUSDC`, see the note above. `recapitalize` and
    // `unrecordedUSDC` carry no role guard and correctly do not count here.
    // AUDIT NOTE (R18 merge adjudication): +2 for `setYieldSink` and `setLossSource`, matching
    // the selector-surface re-pin above.
    // AUDIT NOTE (G2W): +1 for `CollateralRegistry.setPastDueWeight`, see the note above.
    // AUDIT NOTE (W6-B3): +1 for `DefaultManager.initializeCommitmentLedger`, see the note above.
    // AUDIT NOTE (four-input merge): +4 net guarded names, matching the selector accounting above.
    // AUDIT NOTE (ADR-0035): -1 for the retired `SGrove.setPerEventCap`, matching the selector
    // accounting above.
    uint256 internal constant EXPECTED_GUARDED_NAMES = 149;
    /// @dev AST-confirmed `src/` functions guarded by an inline caller/address comparison.
    ///      This is deliberately a second runtime pin rather than folding custom-error trusted
    ///      callers into the OZ-onlyRole probe. It includes all four CommitmentLedger functions
    ///      protected by `onlyManager`. Add/remove an inline guard and this test must red before a
    ///      reviewed re-baseline; A4 demonstrated that the old onlyRole-only count stayed green.
    // OWNER DECISION (G1c, 2026-08-14): removing the proposal-guardian veto deletes the
    // bespoke `_msgSender() == proposalGuardian` cancellation branch. The remaining thirteen
    // inline caller guards are unchanged and continue to be enumerated at runtime.
    uint256 internal constant EXPECTED_INLINE_CALLER_GUARDED_NAMES = 13;

    function setUp() public override {
        super.setUp();

        // Two modules carry privileged functions but are not part of the credit/governance
        // fixtures. They are deployed here so the enumeration is over the WHOLE of `src/` — a
        // surface that stops at "whatever the fixture happened to deploy" is the sampling
        // problem again, one level up.
        points = PointsModule(
            address(
                new ERC1967Proxy(
                    address(new PointsModule()),
                    abi.encodeCall(
                        PointsModule.initialize, (admin, admin, address(compliance), address(vault), address(usdfr))
                    )
                )
            )
        );
        recovery = RecoveryTopUpDistributor(
            address(
                new ERC1967Proxy(
                    address(new RecoveryTopUpDistributor()),
                    abi.encodeCall(RecoveryTopUpDistributor.initialize, (admin, guardian, admin, address(usdfr)))
                )
            )
        );
        grove = GroveToken(
            address(
                new ERC1967Proxy(
                    address(new GroveToken()), abi.encodeCall(GroveToken.initialize, (admin, admin, frTreasury))
                )
            )
        );
        sGrove = SGrove(
            address(
                new ERC1967Proxy(
                    address(new SGrove()),
                    abi.encodeCall(
                        SGrove.initialize, (admin, guardian, admin, address(grove), address(usdfr), address(vault))
                    )
                )
            )
        );
        // production topology, so the probes run against the real role wiring
        vm.startPrank(admin);
        sGrove.grantRole(Roles.CREDIT_ROLE, address(defaultManager));
        vault.grantRole(Roles.FEE_ACCOUNTING_ROLE, address(sGrove));
        vm.stopPrank();

        // source file base name, artifact/contract name, deployed address
        _registerModule("AssessedImpairmentSource", "AssessedImpairmentSource", address(assessedImpairmentSource));
        _registerModule("AttestationOracle", "AttestationOracle", address(oracle));
        _registerModule("ClaimBridge", "ClaimBridge", address(bridge));
        _registerModule("CollateralRegistry", "CollateralRegistry", address(registry));
        _registerModule("ComplianceRegistry", "ComplianceRegistry", address(compliance));
        _registerModule("CuratorModule", "CuratorModule", address(curator));
        _registerModule("DefaultManager", "DefaultManager", address(defaultManager));
        _registerModule("GroveToken", "GroveToken", address(grove));
        _registerModule("MintRedeemController", "MintRedeemController", address(controller));
        _registerModule("PointsModule", "PointsModule", address(points));
        _registerModule("RecoveryTopUpDistributor", "RecoveryTopUpDistributor", address(recovery));
        _registerModule("RedemptionQueue", "RedemptionQueue", address(queue));
        _registerModule("ReserveManager", "ReserveManager", address(reserves));
        _registerModule("SGrove", "SGrove", address(sGrove));
        _registerModule("USDfr", "USDfr", address(usdfr));
        _registerModule("WaterfallEngine", "WaterfallEngine", address(waterfall));
        _registerModule("sUSDfr", "SUSDfr", address(vault));

        _buildPrivilegedSurface();

        address[] memory pausables = new address[](7);
        pausables[0] = address(usdfr);
        pausables[1] = address(vault);
        pausables[2] = address(controller);
        pausables[3] = address(queue);
        pausables[4] = address(reserves);
        pausables[5] = address(bridge);
        pausables[6] = address(waterfall);

        handler = new AccessControlSurfaceHandler(
            usdc, usdfr, vault, controller, queue, compliance, admin, guardian, complianceAdmin, pausables
        );
        for (uint256 i = 0; i < surface.length; ++i) {
            Entry memory e = surface[i];
            handler.addEntry(e.target, e.selector, e.words, string.concat(e.module, ".", e.signature));
        }

        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](2);
        sel[0] = AccessControlSurfaceHandler.probe.selector;
        sel[1] = AccessControlSurfaceHandler.churn.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    // =====================================================================
    //  the invariant
    // =====================================================================

    /// @notice INVARIANT (CLAUDE.md §1.3 ACCESS CONTROL). No privileged action anywhere in `src/`
    ///         is reachable by a caller holding no role, in any state the campaign reaches.
    /// @dev `guardAdmissions` is written AFTER the probe's state rollback precisely so that a
    ///      bypass is still visible here — see `GuardProbe`. DO NOT "simplify" this to a check on
    ///      live protocol state: the bypass has been rolled back by design, and this counter is
    ///      the only surviving evidence of it.
    function invariant_acl_noPrivilegedActionReachableByAnUnauthorisedRole() public view {
        assertEq(
            handler.guardAdmissions(),
            0,
            string.concat(
                "ACCESS CONTROL BYPASSED: an actor with no role reached ",
                handler.guardLabel(handler.lastAdmittedGuard())
            )
        );
    }

    /// @notice ANTI-VACUITY, asserted at every invariant boundary rather than only at the end:
    ///         the probe table is the whole enumerated surface. A campaign that quietly probed an
    ///         empty table would satisfy the invariant above trivially.
    function invariant_acl_probeTableIsTheWholeEnumeratedSurface() public view {
        assertEq(handler.entryCount(), EXPECTED_SURFACE, "PROBE TABLE IS NOT THE FULL PRIVILEGED SURFACE");
        assertEq(handler.guardCount(), EXPECTED_SURFACE, "REACH LEDGER LOST ENTRIES");
    }

    /// @notice ANTI-VACUITY (campaign level), plus the per-guard reach table finding G11/G12 asks
    ///         for.
    /// @dev WHAT IS ASSERTED HERE AND WHAT IS ONLY REPORTED, and why the split is deliberate.
    ///      `afterInvariant` runs after EVERY run and each run restarts from the post-`setUp`
    ///      state, so an assertion here is a statement about ONE ~128-call run, not about the
    ///      campaign. "At least one probe fired" survives that (with two registered selectors the
    ///      probability a run fires none is 2^-128). The state-shape counters do NOT: a single run
    ///      can legitimately spend all its churn calls on one shape, and asserting them here was
    ///      measured to fail on some seeds and pass on others — a flaky gate, which is worse than
    ///      no gate because it teaches people to re-run until green. This repo already learned
    ///      that lesson once, in `INV_CreditGateAndAuthorisation`'s `afterInvariant` note.
    ///      The state-shape claim is therefore made DETERMINISTICALLY instead, in
    ///      `test_acl_everyPrivilegedSelectorRefusesInEveryProtocolState`, which puts the protocol
    ///      into each shape by construction and sweeps the whole surface in it. That is a stronger
    ///      statement than any counter, and it is seed-independent.
    /// @dev The log lines below come from Foundry's REPLAY of the shrunk sequence when a run
    ///      fails, so their numbers are smaller than the ones the assertions actually saw. Read
    ///      the assertion message, not the log, when diagnosing.
    function afterInvariant() public view {
        handler.reachReport();
        console2.log("-- ACL surface campaign (terminating run) --");
        console2.log("handler calls / churns  ", handler.callCount(), handler.churnCount());
        console2.log("probes fired            ", handler.guardProbeAttempts());
        console2.log("pauses / unpauses       ", handler.pauseCount(), handler.unpauseCount());
        console2.log(
            "probes paused / unpaused", handler.probesWhileSomethingPaused(), handler.probesWhileNothingPaused()
        );
        console2.log("probes funded / queued  ", handler.probesWithFundedVault(), handler.probesWithQueuedRequest());

        assertGt(handler.guardProbeAttempts(), 0, "VACUOUS: NO PRIVILEGED ENTRY POINT WAS EVER PROBED");
    }

    // =====================================================================
    //  deterministic companions — the teeth
    // =====================================================================

    /// @notice EXHAUSTIVE AND DETERMINISTIC: all 132 privileged selectors × 4 role-less actors.
    /// @dev The assertion that gives this teeth is `refusedByRole == surface`, not
    ///      `admitted == 0`. "Nothing was admitted" is satisfiable by a probe that never reaches
    ///      the guard at all (a decode failure, a `whenNotPaused` ordered first, a wrong
    ///      selector) — which is exactly how a probe table rots into decoration. Requiring that
    ///      EVERY entry was refused BY THE ROLE CHECK means each of the 132 guards is
    ///      individually demonstrated live on every run.
    function test_acl_everyPrivilegedSelectorRefusesEveryUnauthorisedActor() public {
        uint256 n = handler.entryCount();
        assertEq(n, EXPECTED_SURFACE, "surface size drifted");

        // EVERY (entry, actor) PAIR, not "the entry was refused for at least one actor". The
        // per-entry version was written first and is too weak: granting exactly one of the four
        // actors a real role left it green, because the other three still refused. A single
        // misconfigured key is precisely the deployment mistake this suite exists to catch, so
        // the count is over pairs. DO NOT relax this back to a per-entry flag.
        uint256 refusedByRole;
        for (uint256 i = 0; i < n; ++i) {
            for (uint256 a = 0; a < 4; ++a) {
                if (handler.probe(i, a) == GuardProbe.Verdict.RefusedAsSpecified) {
                    refusedByRole++;
                } else {
                    console2.log("NOT ROLE-REFUSED:", surface[i].module, surface[i].signature);
                }
            }
        }

        assertEq(handler.guardAdmissions(), 0, "AN UNAUTHORISED ACTOR REACHED A PRIVILEGED ACTION");
        assertEq(
            refusedByRole,
            n * 4,
            "A PRIVILEGED ENTRY POINT DID NOT REFUSE ON ACCESS CONTROL (see the NOT ROLE-REFUSED log lines)"
        );
    }

    /// @notice The DRIFT GATE, stated as an assertion instead of a hope.
    /// @dev `_buildPrivilegedSurface` already reverts if a `src/` module with `onlyRole` guards
    ///      has no registered address. This pins the two counts as well, so REMOVING a guard is
    ///      as loud as adding one — without it, deleting `onlyRole` from a function would simply
    ///      remove it from the enumeration and every assertion above would still pass.
    function test_acl_surfaceEnumerationIsExhaustiveAndDriftProof() public view {
        assertEq(surface.length, EXPECTED_SURFACE, "PRIVILEGED SURFACE CHANGED: re-baseline deliberately");
        uint256 totalGuardedNames;
        for (uint256 i = 0; i < scannedModules.length; ++i) {
            totalGuardedNames += guardedNameCount[scannedModules[i]];
        }
        assertEq(scannedModules.length, 17, "A MODULE GAINED OR LOST ITS ENTIRE PRIVILEGED SURFACE");
        assertEq(totalGuardedNames, EXPECTED_GUARDED_NAMES, "AN onlyRole GUARD WAS ADDED OR REMOVED IN src/");
        assertEq(
            totalInlineCallerGuardedNames,
            EXPECTED_INLINE_CALLER_GUARDED_NAMES,
            "AN INLINE CALLER GUARD WAS ADDED OR REMOVED IN src/"
        );
    }

    /// @notice POSITIVE CONTROL. Refusal only proves something if the same call SUCCEEDS for the
    ///         role holder — otherwise every entry could be refused for an unrelated reason and
    ///         the suite would still be green.
    function test_acl_theAuthorisedHolderIsNotRefused() public {
        // guardian may pause the vault; an outsider may not (that edge is entry-probed above)
        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused(), "the authorised guardian could not pause");
        vm.prank(guardian);
        vault.unpause();
        assertFalse(vault.paused(), "the authorised guardian could not unpause");

        uint256 newFloor = queue.minRedemptionValue() + 1e18;
        vm.prank(admin);
        queue.setMinRedemptionValue(newFloor);
        assertEq(queue.minRedemptionValue(), newFloor, "the authorised admin could not set a queue parameter");

        address outsider = handler.outsiders(0);
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, bytes32(0))
        );
        queue.setMinRedemptionValue(newFloor);
    }

    /// @notice "IN ANY STATE", DETERMINISTICALLY. The whole 132-entry surface is swept in each of
    ///         four constructed protocol shapes, so the §1.3 clause is demonstrated rather than
    ///         left to whichever states a fuzz run happened to visit.
    /// @dev This is the assertion that replaces a per-run state-shape counter in `afterInvariant`
    ///      (see the note there). Each shape asserts BOTH directions: nothing was admitted, and
    ///      every entry was refused specifically by the role check — so a state in which some
    ///      other guard starts short-circuiting the role check would show up as a shortfall
    ///      rather than passing as "well, it reverted".
    function test_acl_everyPrivilegedSelectorRefusesInEveryProtocolState() public {
        _sweepAllEntries("unpaused, empty vault");

        // funded vault + idle reserves
        address who = handler.outsiders(0);
        usdc.mint(who, 1_000_000e6);
        vm.startPrank(who);
        usdc.approve(address(controller), 1_000_000e6);
        controller.mint(1_000_000e6);
        usdfr.approve(address(vault), 500_000e18);
        vault.deposit(500_000e18, who);
        vm.stopPrank();
        assertGt(vault.totalSupply(), 0, "precondition: the vault must be funded");
        _sweepAllEntries("funded vault");

        // open redemption request in the queue
        uint256 shares = vault.balanceOf(who) / 2;
        vm.startPrank(who);
        vault.approve(address(queue), shares);
        queue.requestRedeem(shares);
        vm.stopPrank();
        assertGt(queue.totalRequests(), queue.head(), "precondition: a request must be queued");
        _sweepAllEntries("queued redemption");

        // every pausable module paused
        vm.startPrank(guardian);
        usdfr.pause();
        vault.pause();
        controller.pause();
        queue.pause();
        reserves.pause();
        bridge.pause();
        waterfall.pause();
        vm.stopPrank();
        assertTrue(vault.paused(), "precondition: the system must be paused");
        _sweepAllEntries("fully paused");
    }

    function _sweepAllEntries(string memory shape) private {
        uint256 n = handler.entryCount();
        uint256 admissionsBefore = handler.guardAdmissions();
        uint256 refusedByRole;
        for (uint256 i = 0; i < n; ++i) {
            if (handler.probe(i, i) == GuardProbe.Verdict.RefusedAsSpecified) {
                refusedByRole++;
            } else {
                console2.log("NOT ROLE-REFUSED in state:", shape, surface[i].signature);
            }
        }
        assertEq(
            handler.guardAdmissions(), admissionsBefore, string.concat("ACCESS CONTROL BYPASSED IN STATE: ", shape)
        );
        assertEq(refusedByRole, n, string.concat("A GUARD STOPPED REFUSING ON ACCESS CONTROL IN STATE: ", shape));
    }
}
