// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {console2} from "forge-std/console2.sol";

import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {StubLossAbsorber, StubLossController} from "../helpers/LossWiringStubs.sol";
import {CustodyFreezePredicateHandler} from "./handlers/CustodyFreezePredicateHandler.sol";
import {CuratorModule} from "../../src/CuratorModule.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title INV_CustodyFreezePredicate — stateful coverage for EVERY limb of the R6-CF1 curator
///        custody freeze, and for every guardian pre-arm path
///
/// @notice AUDIT FIX (F3-FREEZE-01). THE FINDING, verbatim: "two limbs of the freeze predicate are
///         deletable with every test in the repository green", plus "the merged invariant tier is
///         structurally blind to THREE of the four limbs of the R6-CF1 freeze predicate and to the
///         guardian pre-arm entirely".
///
///         WHY A SEPARATE SUITE RATHER THAN MORE ACTIONS ON `INV_CascadeSeniority`. That campaign
///         is a SOLVENT-REGIME campaign by construction and says so: it "never latches a reserve
///         deficit, never leaves a live USDC shortfall at rest, and asserts
///         `totalUSDfr() == backingValue()` at every custody loss". Those are the exact conditions
///         "limb 2 is never true", "limb 3 is never true", "limb 4 is never true". Its custody
///         model is `mCustodyIncidentOpen` — limb 1 alone — so
///         `invariant_INV5_custodyFreezeMatchesIndependentModel` would agree with a one-limb
///         predicate forever. Widening that campaign to latch deficits and induce shortfalls would
///         wreck the very regime its INV-5/6/7 reference model depends on. The right answer is a
///         campaign whose SUBJECT is the predicate, which is this one.
///
///         WHAT THIS SUITE ASSERTS, in one sentence: in every reachable state, moving EXACTLY ONE
///         limb of the freeze predicate into its illegal region freezes curator layer-1 capital,
///         and moving it back out releases it.
///
/// @dev THE ANTI-VACUITY POSTURE IS THE POINT, and it is asserted rather than logged.
///      `afterInvariant` fails the campaign if ANY registered guard was never entered, or if any
///      probe at a guard was refused by something OTHER than the guard under test. A green campaign
///      that never reached a limb is worse than no campaign, and this suite exists because exactly
///      that happened to three of these four limbs.
///
/// @dev `fail_on_revert = true` (repo default) is load-bearing and is NOT relaxed here.
contract INV_CustodyFreezePredicate is CreditLayerFixture {
    CustodyFreezePredicateHandler internal handler;

    /// @dev Pays USDC into the treasury WITHOUT minting matching USDfr. That is what a third-party
    ///      recapitalisation is, and it is the ONLY way backing can be restored while a latched
    ///      deficit stands — which is what isolates limb 2 from limb 4. `depositUSDC` is
    ///      CREDIT_ROLE-gated, so governance grants the role to a dedicated agent rather than the
    ///      handler reusing a protocol module's authority.
    address internal recapAgent = makeAddr("f3RecapitalisationAgent");
    /// @dev Where custodied USDC goes when limb 3's shortfall is induced. A plain address with no
    ///      role anywhere, so an induced shortfall cannot be mistaken for a protocol flow.
    address internal custodySink = makeAddr("f3CustodySink");
    address internal probeMinter = makeAddr("f3SupplyMinter");

    function setUp() public override {
        super.setUp();

        // A funded facility gives limb 4 real face principal to mark down. Class 1, so class 5 —
        // where the probe stake lives — keeps zero exposure and therefore full headroom.
        uint256 impairFacilityId = _liveFilmFacility(200_000e18);

        // Two SPARE reserve managers, each miswired on exactly one leg. Both legs of the
        // fail-closed branch must be probed SEPARATELY: with both unset either leg alone still
        // answers `true`, so a single both-unset probe stays green when one leg is deleted. That is
        // the same shadowing that made limb 2 deletable in the first place.
        ReserveManager spareNoController = _spareReserveManager();
        ReserveManager spareNoAbsorber = _spareReserveManager();
        StubLossAbsorber absorberStub = new StubLossAbsorber(address(spareNoController));
        StubLossController controllerStub = new StubLossController(address(spareNoAbsorber), address(usdfr));

        vm.startPrank(admin);
        spareNoController.setLossAbsorber(address(absorberStub));
        spareNoAbsorber.setLossController(address(controllerStub));
        reserves.grantRole(Roles.CREDIT_ROLE, recapAgent);
        vm.stopPrank();

        // Production refuses to rebind the live Curator away from a reserve that reports frozen.
        // Give each wiring-leg probe its own permanently bound Curator instead of bypassing that
        // guard during invariant cleanup.
        CuratorModule curatorNoController = _probeCurator(address(spareNoController));
        CuratorModule curatorNoAbsorber = _probeCurator(address(spareNoAbsorber));
        _mintUSDfrTo(anchorCurator, 20_000e18);
        vm.startPrank(anchorCurator);
        usdfr.approve(address(curatorNoController), 10_000e18);
        curatorNoController.postFirstLoss(Config.CLASS_DIGITAL_ASSETS, 10_000e18);
        usdfr.approve(address(curatorNoAbsorber), 10_000e18);
        curatorNoAbsorber.postFirstLoss(Config.CLASS_DIGITAL_ASSETS, 10_000e18);
        vm.stopPrank();

        vm.startPrank(complianceAdmin);
        compliance.setAllowed(probeMinter, true);
        vm.stopPrank();

        handler = new CustodyFreezePredicateHandler(
            CustodyFreezePredicateHandler.Wiring({
                usdc: address(usdc),
                usdfr: address(usdfr),
                reserves: address(reserves),
                controller: address(controller),
                vault: address(vault),
                curator: address(curator),
                backstop: address(backstopMock),
                admin: admin,
                guardian: guardian,
                curatorActor: anchorCurator,
                minter: probeMinter,
                recapAgent: recapAgent,
                custodySink: custodySink,
                curatorNoController: address(curatorNoController),
                curatorNoAbsorber: address(curatorNoAbsorber),
                impairFacilityId: impairFacilityId
            })
        );

        // DETERMINISTIC FLOOR. Every guard is entered once before every run, so the per-guard
        // `afterInvariant` floors below cannot flake on fuzz luck — and so a deleted limb reds this
        // campaign at `--invariant-runs 1 --invariant-depth 1`, with no fuzz luck involved.
        handler.seedEveryLimb();

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = CustodyFreezePredicateHandler.probeClearState.selector;
        selectors[1] = CustodyFreezePredicateHandler.probeLimb1OpenIncident.selector;
        selectors[2] = CustodyFreezePredicateHandler.probeLimb2LatchedDeficit.selector;
        selectors[3] = CustodyFreezePredicateHandler.probeLimb3LiveShortfall.selector;
        selectors[4] = CustodyFreezePredicateHandler.probeLimb4UnderBacking.selector;
        selectors[5] = CustodyFreezePredicateHandler.probeMiswiredController.selector;
        selectors[6] = CustodyFreezePredicateHandler.probeMiswiredAbsorber.selector;
        selectors[7] = CustodyFreezePredicateHandler.probeUnwiredReserve.selector;
        selectors[8] = CustodyFreezePredicateHandler.probePreArm.selector;
        selectors[9] = CustodyFreezePredicateHandler.probePreArmBudgetAndExpiry.selector;
        selectors[10] = CustodyFreezePredicateHandler.postFirstLossNoise.selector;
        selectors[11] = CustodyFreezePredicateHandler.mintSupply.selector;
        selectors[12] = CustodyFreezePredicateHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        excludeSender(address(handler));
    }

    function _probeCurator(address reserve) internal returns (CuratorModule probe) {
        probe = CuratorModule(
            address(
                new ERC1967Proxy(
                    address(new CuratorModule()),
                    abi.encodeCall(
                        CuratorModule.initialize,
                        (admin, guardian, admin, address(usdfr), address(registry), address(vault))
                    )
                )
            )
        );
        vm.startPrank(admin);
        probe.setCuratorApproved(Config.CLASS_DIGITAL_ASSETS, anchorCurator, true);
        probe.setReserveManager(reserve);
        vault.grantRole(Roles.FEE_ACCOUNTING_ROLE, address(probe));
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────
    //  SELECTOR-REGISTRATION GUARD (deterministic; not an invariant)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Every action the handler exposes MUST be in the `targetSelector` whitelist.
    /// @dev Adding a handler function does nothing when the suite has a selector whitelist and the
    ///      new selector was not registered — it becomes dead code that READS as extra coverage,
    ///      which is the failure mode this whole engagement keeps re-finding. `afterInvariant`
    ///      cannot catch it reliably (a per-selector "this fired" counter flakes), so this test is
    ///      the deterministic replacement: it fails immediately and every time.
    function test_wiring_everyHandlerActionIsRegistered() public view {
        FuzzSelector[] memory targeted = targetSelectors();
        assertEq(targeted.length, 1, "expected exactly one targeted selector set");
        assertEq(targeted[0].addr, address(handler), "selector set is not bound to the handler");

        bytes4[13] memory expected = [
            CustodyFreezePredicateHandler.probeClearState.selector,
            CustodyFreezePredicateHandler.probeLimb1OpenIncident.selector,
            CustodyFreezePredicateHandler.probeLimb2LatchedDeficit.selector,
            CustodyFreezePredicateHandler.probeLimb3LiveShortfall.selector,
            CustodyFreezePredicateHandler.probeLimb4UnderBacking.selector,
            CustodyFreezePredicateHandler.probeMiswiredController.selector,
            CustodyFreezePredicateHandler.probeMiswiredAbsorber.selector,
            CustodyFreezePredicateHandler.probeUnwiredReserve.selector,
            CustodyFreezePredicateHandler.probePreArm.selector,
            CustodyFreezePredicateHandler.probePreArmBudgetAndExpiry.selector,
            CustodyFreezePredicateHandler.postFirstLossNoise.selector,
            CustodyFreezePredicateHandler.mintSupply.selector,
            CustodyFreezePredicateHandler.warp.selector
        ];
        assertEq(targeted[0].selectors.length, expected.length, "registered selector count != action count");
        for (uint256 i = 0; i < expected.length; ++i) {
            bool found;
            for (uint256 j = 0; j < targeted[0].selectors.length; ++j) {
                if (targeted[0].selectors[j] == expected[i]) found = true;
            }
            assertTrue(found, "a handler action is missing from the targetSelector whitelist");
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  THE INVARIANTS
    // ─────────────────────────────────────────────────────────────────────

    /// @notice THE FINDING, as a standing property. No probe driven into any limb's illegal region
    ///         was ever ADMITTED — not the four reserve limbs, not either leg of the miswired
    ///         fail-closed branch, not the unwired branch, not the guardian pre-arm.
    /// @dev `guardAdmissions` is what carries a bypass out of the handler: when a guard holds, the
    ///      probe reverts and the EVM has already rolled the attempt back, so there is no state left
    ///      to assert on. Delete ANY limb and its probe's withdrawal really completes, the counter
    ///      increments, and this fails on the next evaluation.
    function invariant_freezePredicateAdmitsNoBypass() public view {
        assertEq(
            handler.guardAdmissions(),
            0,
            string.concat("F3: a curator exit escaped the custody freeze at guard: ", handler.lastAdmittedGuardLabel())
        );
    }

    /// @notice The freeze is a FREEZE, not a brick. Every probe restores the state it moved, so at
    ///         every invariant evaluation the predicate must read FALSE.
    /// @dev This is the standing form of the positive control. Without it, a predicate that simply
    ///      returned `true` would satisfy every negative probe in the suite — nineteen guards, all
    ///      green, against a protocol in which curator capital could never be recycled.
    function invariant_atRestTheFreezeIsReleased() public view {
        assertTrue(handler.atRest(), "F3: the campaign left a limb live between calls");
        assertFalse(curator.custodyFreezeActive(), "F3: the freeze is standing with every limb off");
        assertFalse(reserves.custodyLossUnabsorbed(), "F3: the reserve predicate is standing with every limb off");
    }

    /// @notice Every probe found the system at rest when it started, i.e. no probe leaked state
    ///         into the next one.
    /// @dev Isolation is the whole basis on which a red is attributed to ONE limb. If a probe ever
    ///      started from a state that already had a limb live, the attribution would be wrong and
    ///      the suite would be quietly weaker than it reads.
    function invariant_everyProbeRanInIsolation() public view {
        assertEq(handler.ghostNotAtRest(), 0, "F3: a probe started from, or left, a non-resting state");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  ANTI-VACUITY — asserted, and it is the whole point
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Fails the campaign if any guard's region was never entered, or if any probe bounced
    ///         off an UNRELATED revert before reaching the guard under test.
    /// @dev TWO BASES, following the house pattern:
    ///
    ///      (1) THE WIRING TOOTH — `fuzzEntries` increments at the top of the registered selectors
    ///          only; the deterministic seed never touches it. If the handler is not the target
    ///          contract, or the selector list is broken, it is exactly zero and this fails even
    ///          though every guard counter is non-zero from the seed.
    ///
    ///      (2) PER-GUARD FLOORS — every registered guard must have been ATTEMPTED, and every
    ///          attempt must have been refused AS SPECIFIED. The second half is what stops the
    ///          floor being satisfiable by a probe that never reached the guard: a withdrawal
    ///          refused for lack of stake, or a view that reverted because a fail-closed branch was
    ///          deleted, counts as `RefusedOtherwise` and fails here.
    function afterInvariant() public view {
        handler.reachReport();
        console2.log("-- INV_CustodyFreezePredicate reach ---------------------");
        console2.log("fuzz selector entries      ", handler.fuzzEntries());
        console2.log("handler actions completed  ", handler.callCount());
        console2.log("probes skipped (unreachable)", handler.ghostSkipped());
        console2.log("deficits latched           ", handler.ghostDeficitsLatched());
        console2.log("live shortfalls induced    ", handler.ghostShortfallsInduced());
        console2.log("impairments recognised     ", handler.ghostImpairmentsRecognised());
        console2.log("guardian pre-arms          ", handler.ghostPreArms());
        console2.log("exits completed at rest    ", handler.ghostExitsAtRest());

        assertGt(handler.fuzzEntries(), 0, "NO FUZZ ACTION EXECUTED (targetSelector wiring broken)");
        assertGt(handler.callCount(), 0, "NO HANDLER ACTION COMPLETED");

        uint256 n = handler.guardCount();
        assertEq(n, 19, "the registered guard set changed - update the anti-vacuity floor deliberately");
        for (uint256 i = 0; i < n; ++i) {
            bytes32 id = handler.guardIdAt(i);
            assertGt(handler.guardAttempts(id), 0, "A REGISTERED GUARD WAS NEVER ENTERED (ITS PROPERTY IS VACUOUS)");
            assertEq(
                handler.guardRefusedAsSpecified(id),
                handler.guardAttempts(id),
                "A PROBE WAS REFUSED BY SOMETHING OTHER THAN THE GUARD UNDER TEST"
            );
        }

        // The three states that are expensive to reach and easy to lose silently.
        assertGt(handler.ghostDeficitsLatched(), 0, "NO RESERVE DEFICIT WAS EVER LATCHED (LIMB 2 IS VACUOUS)");
        assertGt(handler.ghostShortfallsInduced(), 0, "NO LIVE CUSTODY SHORTFALL WAS EVER INDUCED (LIMB 3 IS VACUOUS)");
        assertGt(
            handler.ghostImpairmentsRecognised(), 0, "NO CONSERVATIVE MARK WAS EVER RECOGNISED (LIMB 4 IS VACUOUS)"
        );
        assertGt(handler.ghostPreArms(), 0, "THE GUARDIAN PRE-ARM WAS NEVER ARMED");
        assertGt(handler.ghostExitsAtRest(), 0, "NO EXIT EVER COMPLETED AT REST (THE POSITIVE CONTROL IS VACUOUS)");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  helpers
    // ─────────────────────────────────────────────────────────────────────

    function _spareReserveManager() internal returns (ReserveManager spare) {
        spare = ReserveManager(
            address(
                new ERC1967Proxy(
                    address(new ReserveManager()),
                    abi.encodeCall(ReserveManager.initialize, (admin, admin, guardian, admin, address(usdc)))
                )
            )
        );
    }
}
