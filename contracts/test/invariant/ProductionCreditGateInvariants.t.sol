// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {RealOracleFixture} from "../helpers/RealOracleFixture.sol";
import {CreditGateAuthorisationHandler} from "./CreditGateAuthorisationHandler.sol";

/// @title INV_CreditGateAndAuthorisation
/// @notice PHASE D INVARIANT SUITE — the credit gate, authorisation and liveness family of
///         the audit's Phase B model (`audit/SYSTEM_MODEL.md` section 6):
///
///           INV-15  mint gate            a facility NFT cannot mint unless every attestation
///                                        kind required for its class is satisfied AND the
///                                        quorum commits to exactly the minted terms AND all
///                                        on-chain conditions hold. Also CLAUDE.md section 1.3
///                                        ("NFT mint gate"), so it carries a named test.
///           INV-16  concentration        no origination may push per-class, per-borrower or
///                                        per-state exposure above its limit.
///           INV-17  attestation one-use  a digest is consumable exactly once, and valuation
///                                        marks are strictly newer than the per-facility
///                                        high-watermark.
///           INV-18  authorisation        no privileged action is reachable by an unauthorised
///                                        caller IN ANY STATE.
///           INV-19  upgrade authority    baseline role topology is restored after every
///                                        governance role-rotation action.
///           INV-20  mint authority       baseline minter topology is restored after every
///                                        governance role-rotation action.
///           INV-21  liveness             no PERMISSIONLESS action by an external actor may
///                                        permanently disable mint, redeem, queue settlement
///                                        or the cascade. Governance pausing is out of scope
///                                        (it belongs in the centralisation inventory).
///
/// @dev WHAT THIS ADDS OVER THE REPO'S EXISTING EIGHT SUITES. `CollateralInvariants` already
///      covers the mint gate and concentration, but against `MockAttestationOracle` and with
///      the concentration floor pinned once in its handler's constructor. This suite runs the
///      same gate against the REAL `AttestationOracle` (genuine EIP-712 m-of-n bundles, real
///      digest consumption, real H-02 watermark) and moves every concentration limit through
///      governance DURING the campaign, so the binding regime is entered and left repeatedly.
///      `OracleInvariants` checks ghost parity but never attempts a replay or a rollback;
///      this suite makes both attacks and asserts they are refused, with the specific error.
///      And `grep -rn "hasRole" test/invariant/` returns nothing in this repo, so INV-18,
///      INV-19 and INV-20 have no invariant-level coverage anywhere before this file.
///
/// @dev HOW THE GHOSTS STAY INDEPENDENT. The handler predicts every origination outcome from
///      state IT maintains: its own mirror of which attestation bits it caused to stand, its
///      own mirror of the standing `CreditIssued` payload, its own class/borrower/state/total
///      exposure ledger, and its own copy of every concentration limit it moved through
///      governance. Nothing in the prediction is read back out of `CollateralRegistry` or
///      `ClaimBridge`, so a bug in their accounting cannot make the check agree with itself.
///
/// @dev Reserve-loss writes belong to the atomic loss-absorption family. This handler retains
///      the unauthorised write probe while keeping its authorised state transitions focused on
///      credit-gate, role-boundary and permissionless-liveness properties.
contract INV_CreditGateAndAuthorisation is RealOracleFixture {
    CreditGateAuthorisationHandler internal handler;

    /// @dev The modules whose UPGRADER_ROLE is checked by INV-19. Kept as addresses so the
    ///      invariant can sweep them with a single `hasRole` ABI.
    address[] internal upgradeableModules;
    /// @dev Addresses that must NEVER hold `UPGRADER_ROLE`. `admin` plays the governance
    ///      timelock in this fixture and is deliberately absent.
    address[] internal nonTimelockActors;
    /// @dev Addresses that must NEVER hold `MINTER_ROLE` on USDfr.
    address[] internal nonMinters;
    /// @dev Exactly the selector set handed to `targetSelector`, so the deterministic wiring
    ///      test checks the same array the campaign runs on rather than a second copy.
    bytes4[] internal registeredSelectors;

    /// @dev AUDIT G11/G12.3 raised this from 17 to 18 by adding
    ///      `probeEscrowReleaseWithoutNft`. It is a MANUAL guard: nothing else catches a new
    ///      handler action that was never added to the `targetSelector` array, so bump it
    ///      deliberately whenever you register one.
    uint256 internal constant SELECTOR_COUNT = 18;

    function setUp() public override {
        super.setUp();

        handler = new CreditGateAuthorisationHandler(
            CreditGateAuthorisationHandler.Wiring({
                bridge: bridge,
                registry: registry,
                oracle: realOracle,
                controller: controller,
                reserves: reserves,
                vault: vault,
                queue: queue,
                waterfall: waterfall,
                defaultManager: defaultManager,
                curator: curator,
                usdfr: usdfr,
                compliance: compliance,
                usdc: usdc
            }),
            CreditGateAuthorisationHandler.Actors({
                admin: admin,
                guardian: guardian,
                complianceAdmin: complianceAdmin,
                originator: originator,
                servicer: servicer,
                custodian: custodian,
                curatorAddr: anchorCurator,
                user: alice,
                outsider: carol,
                borrower: borrower,
                backstop: address(backstopMock),
                pk1: attesterPk1,
                pk2: attesterPk2
            })
        );
        // D7-01: permissionless callers remain part of the authorization probes, while the
        // handler itself is the modeled keeper for the liveness probe that must reach settlement.
        vm.prank(admin);
        queue.grantRole(Roles.SETTLEMENT_KEEPER_ROLE, address(handler));

        // Deterministic anti-vacuity floor: one of every shape the campaign claims to reach
        // exists before the first fuzzed call, so `afterInvariant`'s assertions are
        // guarantees about the state each run started from rather than a bet on fuzzer luck.
        handler.seedShapes();

        upgradeableModules = [
            address(bridge),
            address(registry),
            address(realOracle),
            address(controller),
            address(reserves),
            address(vault),
            address(queue),
            address(waterfall),
            address(defaultManager),
            address(curator),
            address(usdfr)
        ];
        nonTimelockActors = [handler.roleSinkAddress(), carol, servicer, guardian];
        nonMinters = [
            handler.roleSinkAddress(),
            carol,
            admin,
            servicer,
            guardian,
            address(vault),
            address(waterfall),
            address(defaultManager)
        ];

        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](SELECTOR_COUNT);
        sel[0] = CreditGateAuthorisationHandler.planFacility.selector;
        sel[1] = CreditGateAuthorisationHandler.attestGateFact.selector;
        sel[2] = CreditGateAuthorisationHandler.revokeGateFact.selector;
        sel[3] = CreditGateAuthorisationHandler.tryOriginate.selector;
        sel[4] = CreditGateAuthorisationHandler.cancelPendingFacility.selector;
        sel[5] = CreditGateAuthorisationHandler.retuneLimits.selector;
        sel[6] = CreditGateAuthorisationHandler.replayUsedDigest.selector;
        sel[7] = CreditGateAuthorisationHandler.replayStaleValuation.selector;
        sel[8] = CreditGateAuthorisationHandler.unauthorisedProbe.selector;
        sel[9] = CreditGateAuthorisationHandler.authorisedControl.selector;
        sel[10] = CreditGateAuthorisationHandler.grantRoleFromAdmin.selector;
        sel[11] = CreditGateAuthorisationHandler.revokeGrantedRole.selector;
        sel[12] = CreditGateAuthorisationHandler.setPausedModule.selector;
        sel[13] = CreditGateAuthorisationHandler.userFlow.selector;
        sel[14] = CreditGateAuthorisationHandler.fundOrDefault.selector;
        sel[15] = CreditGateAuthorisationHandler.permissionlessAndProbeLiveness.selector;
        sel[16] = CreditGateAuthorisationHandler.warp.selector;
        // AUDIT G11/G12.3: the UNFILTERED funding probe. `fundOrDefault` only ever calls `fund`
        // on a facility its own ghost already says is `Pending`, so without this selector the
        // §1.3 clause "escrow cannot release without the NFT" is never executed by the campaign.
        sel[17] = CreditGateAuthorisationHandler.probeEscrowReleaseWithoutNft.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        registeredSelectors = sel; // same array the deterministic wiring test checks
    }

    // =====================================================================
    //  INV-15 — the synchronized mint gate (CLAUDE.md section 1.3)
    // =====================================================================

    /// @notice CLAUDE.md section 1.3 NFT MINT GATE / audit INV-15, direction 1: nothing gets
    ///         through that should not.
    /// @dev Two independent statements. (a) Every NFT that exists was minted into a state
    ///      where the handler's OWN record of the attestation bits, the standing
    ///      `CreditIssued` payload and the marked-to-market freshness/value bound all held.
    ///      (b) The differential counter: the contract never admitted an origination the
    ///      reference model said it must refuse.
    function invariant_INV15_mintGateNeverBypassed() public view {
        uint256 n = handler.mintedCount();
        for (uint256 i = 0; i < n; ++i) {
            uint256 id = handler.mintedAt(i);
            assertTrue(handler.gateSatisfiedAtMint(id), "INV-15: NFT EXISTS WITHOUT A SATISFIED GATE");
            assertTrue(handler.termsBoundAtMint(id), "INV-15: NFT EXISTS WITHOUT TERMS BOUND TO THE QUORUM");
        }
        assertEq(handler.ghostGateBypasses(), 0, "INV-15: GATE BYPASSED (model said refuse, contract admitted)");
    }

    /// @notice Audit INV-15, direction 2: a gate that never lets anything through is also
    ///         broken. An origination satisfying every condition must be admitted, and a
    ///         refused one must be refused for the reason the model predicted.
    function invariant_INV15_gateAdmitsEveryValidOrigination() public view {
        assertEq(
            handler.ghostUnexpectedRejections(),
            0,
            "INV-15: A FULLY SATISFIED ORIGINATION WAS REFUSED (see ghostLastActualSelector)"
        );
        assertEq(
            handler.ghostWrongReason(), 0, "INV-15: REFUSED FOR THE WRONG REASON (see ghostLastExpected/ActualSelector)"
        );
    }

    /// @notice CLAUDE.md §1.3 MINT GATE, SECOND CLAUSE: "escrow cannot release without the NFT."
    ///         AUDIT FINDING G11/G12.3 — this clause had no invariant, and its guards were never
    ///         entered by the invariant tier at all.
    /// @dev `WaterfallEngine.fund` is the on-chain escrow release: the only path that moves
    ///      stablecoins out of `ReserveManager` custody to a borrower account. The handler now
    ///      presents it with ids it has NOT verified — never minted, zero, burned by
    ///      `cancelPending`, already funded, defaulted — from the AUTHORISED servicer, so the
    ///      access-control check cannot answer first and mask the mint gate.
    ///
    ///      TWO STATEMENTS, and the second is the one that would catch a partial release:
    ///        * `guardAdmissions == 0` — no such call ever SUCCEEDED, and
    ///        * `escrowLeaks == 0` — no such call moved idle reserves or created deployed
    ///          principal. A release followed by a later revert is the actual catastrophe here,
    ///          and "it reverted" alone would not detect it.
    ///
    ///      WHY THIS IS NOT REDUNDANT WITH `invariant_INV15_mintGateNeverBypassed`. That one
    ///      checks facilities that WERE minted were properly gated. This one checks that a
    ///      facility which was NOT minted — or whose NFT no longer exists — cannot move money.
    ///      `ClaimBridge.LoanState.Pending` is enum value ZERO, so a default-initialised
    ///      `Facility` struct reads as fundable; `ClaimBridge._facility`'s
    ///      `tokenId == 0 || tokenId >= nextId` rejection is the whole defence. DO NOT delete it.
    function invariant_INV15_escrowNeverReleasesWithoutTheNFT() public view {
        assertEq(
            handler.guardAdmissions(),
            0,
            string.concat("ESCROW RELEASED WITHOUT A LIVE NFT: ", handler.guardLabel(handler.lastAdmittedGuard()))
        );
        assertEq(handler.escrowLeaks(), 0, "ESCROW LEAKED RESERVES ON A REFUSED FUNDING");
    }

    // =====================================================================
    //  INV-16 — concentration admission
    // =====================================================================

    /// @notice Audit INV-16 / CLAUDE.md section 1.3 CONCENTRATION LIMITS: no origination may
    ///         push per-class, per-borrower or per-state exposure above its limit.
    /// @dev The exposures and the limits are both handler-owned ghosts. The limits are moved
    ///      through governance during the campaign precisely because the live testnet
    ///      configuration leaves several of them at 100%, which would make this property
    ///      trivially true. `afterInvariant` asserts the binding regime was actually reached.
    function invariant_INV16_concentrationNeverExceededByAnOrigination() public view {
        assertEq(handler.ghostLimitBypasses(), 0, "INV-16: AN ORIGINATION WAS ADMITTED ABOVE A DIMENSION'S CAP");
        uint256 n = handler.mintedCount();
        for (uint256 i = 0; i < n; ++i) {
            assertTrue(
                handler.limitsRespectedAtMint(handler.mintedAt(i)),
                "INV-16: A MINTED FACILITY BREACHED A CONCENTRATION LIMIT AT MINT"
            );
        }
    }

    // =====================================================================
    //  INV-17 — attestation single use and mark monotonicity
    // =====================================================================

    /// @notice Audit INV-17, half 1: an attestation digest is consumable exactly once.
    /// @dev The handler replays previously accepted bundles byte-for-byte. Every bundle it
    ///      signs carries `expiry = type(uint64).max`, so a replay can never be refused for
    ///      the uninteresting reason and mask a working replay.
    function invariant_INV17_digestConsumableExactlyOnce() public view {
        assertEq(handler.ghostReplayAccepted(), 0, "INV-17: A CONSUMED ATTESTATION DIGEST WAS ACCEPTED AGAIN");
        uint256 n = handler.acceptedDigestCount();
        for (uint256 i = 0; i < n; ++i) {
            assertTrue(realOracle.digestUsed(handler.acceptedDigestAt(i)), "INV-17: ACCEPTED DIGEST NOT MARKED USED");
        }
    }

    /// @notice Audit INV-17, half 2: valuation marks are strictly newer than the per-facility
    ///         high-watermark, and the watermark matches an independent ghost across attest,
    ///         revoke and adversarial rollback attempts.
    function invariant_INV17_valuationMarksAreStrictlyNewer() public view {
        assertEq(handler.ghostStaleValuationAccepted(), 0, "INV-17: A MARK AT OR BELOW THE WATERMARK WAS ACCEPTED");
        uint256 upper = bridge.totalOriginated() + 2;
        for (uint256 id = 1; id <= upper; ++id) {
            assertEq(
                realOracle.valuationWatermark(id),
                handler.gWatermark(id),
                "INV-17: VALUATION WATERMARK DIVERGED FROM THE INDEPENDENT GHOST"
            );
        }
    }

    // =====================================================================
    //  INV-18 — no unauthorised state change, in any state
    // =====================================================================

    /// @notice Audit INV-18 / CLAUDE.md section 1.3 ACCESS CONTROL: no privileged action is
    ///         reachable by an unauthorised caller in any state.
    /// @dev The critical words are "in any state". The campaign fires the probes while the
    ///      system is paused and unpaused, with and without a live default, mid-epoch and
    ///      mid-settlement, with a funded and an empty vault; `afterInvariant` asserts those
    ///      shapes were actually visited rather than merely hoped for.
    function invariant_INV18_noUnauthorisedStateChange() public view {
        assertEq(
            handler.ghostProbeSuccesses(),
            0,
            "INV-18: AN UNAUTHORISED CALLER REACHED A PRIVILEGED ACTION (see ghostLastBypassProbe)"
        );
    }

    // =====================================================================
    //  INV-19 / INV-20 — upgrade and mint authority
    // =====================================================================

    /// @notice INV-19: the production upgrader topology is restored at every invariant boundary.
    /// @dev Governance role rotation is exercised grant-and-revoke inside one handler action;
    ///      unauthorised grants are independently classified by INV-18.
    function invariant_INV19_upgradeAuthorityIsTimelockOnly() public view {
        for (uint256 m = 0; m < upgradeableModules.length; ++m) {
            for (uint256 i = 0; i < nonTimelockActors.length; ++i) {
                assertFalse(
                    IRoleReader(upgradeableModules[m]).hasRole(Roles.UPGRADER_ROLE, nonTimelockActors[i]),
                    "INV-19: UPGRADER_ROLE HELD BY A NON-TIMELOCK ADDRESS"
                );
            }
        }
    }

    /// @notice INV-20: the production minter topology is restored at every invariant boundary.
    function invariant_INV20_mintAuthorityIsControllerOnly() public view {
        for (uint256 i = 0; i < nonMinters.length; ++i) {
            assertFalse(
                usdfr.hasRole(Roles.MINTER_ROLE, nonMinters[i]), "INV-20: MINTER_ROLE HELD BY A NON-CONTROLLER ADDRESS"
            );
        }
        assertTrue(usdfr.hasRole(Roles.MINTER_ROLE, address(controller)), "INV-20: THE CONTROLLER LOST MINTER_ROLE");
    }

    // =====================================================================
    //  INV-21 — no permanent freeze without governance
    // =====================================================================

    /// @notice Audit INV-21: after any sequence of purely permissionless calls by an external
    ///         actor, each of mint, redeem, queue settlement and the cascade must still be
    ///         reachable by SOME legal transition.
    /// @dev The handler proves reachability by actually performing each operation inside a
    ///      state snapshot and rolling it back, rather than by re-deriving the contracts'
    ///      own preconditions. It is allowed to bring capital and to let time pass, because
    ///      INV-21 is about PERMANENT disablement, not about an instantaneous liquidity or
    ///      cooldown condition. Governance pausing is excluded by the invariant's own
    ///      wording, so a paused module skips its probe instead of reporting a violation.
    function invariant_INV21_corePathsRemainReachable() public view {
        assertEq(handler.ghostMintBlocked(), 0, "INV-21: MINT PERMANENTLY BLOCKED AFTER A PERMISSIONLESS ACTION");
        assertEq(handler.ghostRedeemBlocked(), 0, "INV-21: REDEEM PERMANENTLY BLOCKED AFTER A PERMISSIONLESS ACTION");
        assertEq(handler.ghostSettleBlocked(), 0, "INV-21: QUEUE SETTLEMENT BLOCKED AFTER A PERMISSIONLESS ACTION");
        assertEq(handler.ghostCascadeBlocked(), 0, "INV-21: THE CASCADE BLOCKED AFTER A PERMISSIONLESS ACTION");
    }

    // =====================================================================
    //  DETERMINISTIC COMPANIONS
    // =====================================================================

    /// @notice INV-18, EXHAUSTIVELY and deterministically: every one of the handler's
    ///         privileged entry points, attempted by every unauthorised actor, is refused.
    /// @dev The stateful campaign checks `ghostProbeSuccesses == 0` after every one of its
    ///      32,768 calls, so across a campaign it does reach all 29 probes — but each RUN fires
    ///      only about seven of them, so no per-run anti-vacuity floor can claim full coverage.
    ///      This test supplies that claim deterministically; the `ghostProbeCoverage` assertion
    ///      is what makes it exhaustive rather than approximate.
    function test_INV18_everyPrivilegedEntryPointIsRefusedForEveryUnauthorisedActor() public {
        uint256 n = handler.probeCount();
        uint256 successesBefore = handler.ghostProbeSuccesses();
        uint256 byRoleBefore = handler.ghostProbeRejectedByRole();
        for (uint256 idx = 0; idx < n; ++idx) {
            for (uint256 actor = 0; actor < 4; ++actor) {
                handler.unauthorisedProbe(idx, actor);
            }
        }
        assertEq(
            handler.ghostProbeSuccesses(), successesBefore, "INV-18: AN UNAUTHORISED CALLER REACHED A PRIVILEGED ACTION"
        );
        assertEq(handler.ghostProbeCoverage(), (1 << n) - 1, "NOT EXHAUSTIVE: a probe never fired");
        assertGt(
            handler.ghostProbeRejectedByRole(),
            byRoleBefore,
            "NO TEETH: not one refusal came from the access-control check"
        );
    }

    /// @notice DETERMINISTIC WIRING TOOTH. Every selector handed to `targetSelector` is a
    ///         live handler entry point that runs without reverting.
    /// @dev This exists because the usual anti-vacuity tooth -- a fuzz-only delta read in
    ///      `afterInvariant` -- is not a usable CI gate here: `afterInvariant` runs after EVERY
    ///      run, so the delta is really a per-run statement, and with 17 selectors a single run
    ///      misses any given one often enough to flake ~10% of campaigns (see
    ///      `CreditGateAuthorisationHandler.campaignObserved` for the measurement). This test is
    ///      seed-independent, catches a dead or mis-registered action, and doubles as the
    ///      `fail_on_revert = true` contract check: a handler entry point that reverts here
    ///      would revert in a campaign.
    /// @dev HONEST LIMIT: this checks the array the suite actually registers, so it catches a
    ///      selector that names nothing, a duplicate, and an action that reverts. It cannot
    ///      catch a NEW handler action that was never added to the array at all; `SELECTOR_COUNT`
    ///      is the manual guard for that and must be bumped deliberately.
    function test_handler_everyRegisteredSelectorIsLiveAndRevertFree() public {
        assertEq(registeredSelectors.length, SELECTOR_COUNT, "selector array length drifted");
        for (uint256 i = 0; i < registeredSelectors.length; ++i) {
            assertTrue(registeredSelectors[i] != bytes4(0), "a registered selector is empty");
            for (uint256 j = i + 1; j < registeredSelectors.length; ++j) {
                assertTrue(registeredSelectors[i] != registeredSelectors[j], "duplicate registered selector");
            }
            // every action takes one or two uint256 seeds; the extra word is harmless padding
            // for the single-argument ones and is what the fuzzer supplies anyway.
            (bool ok,) = address(handler).call(abi.encodeWithSelector(registeredSelectors[i], uint256(7), uint256(3)));
            assertTrue(ok, "a registered handler action reverted or does not exist");
        }
    }

    /// @notice AUDIT G11/G12.3, DETERMINISTIC AND SEED-INDEPENDENT: every illegal shape of
    ///         `WaterfallEngine.fund` is refused, with the exact error, and none of them moves a
    ///         single unit of stablecoin. This is the reachability proof for
    ///         `invariant_INV15_escrowNeverReleasesWithoutTheNFT` — the campaign's own counters
    ///         are reported by `_reportCoverage`, but a per-run floor on them would be flaky.
    function test_INV15_escrowCannotReleaseWithoutTheNFT() public {
        uint256 idleBefore = reserves.idleUSDC();
        uint256 deployedBefore = reserves.deployedPrincipal();
        assertGt(idleBefore, 0, "precondition: reserves must hold stablecoins, else refusal proves nothing");
        // POSITIVE CONTROL, established by `handler.seedShapes()` in `setUp`: a LEGAL funding of a
        // gated Pending facility DOES release escrow in this fixture. Without it, every refusal
        // below could be explained by funding simply being broken.
        assertGt(deployedBefore, 0, "POSITIVE CONTROL: no legal funding ever released escrow here");

        uint256 unminted = bridge.totalOriginated() + 1;
        uint256 amount = 10_000e6;

        // (a) a token id that was never minted
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_UnknownToken.selector, unminted));
        waterfall.fund(unminted, amount);

        // (b) token id zero — the default-struct case. `LoanState.Pending` is enum 0, so without
        //     the explicit id rejection this would read as a fundable facility whose principal is
        //     0, and `usdcAmount == 0` would satisfy the principal-match check.
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_UnknownToken.selector, 0));
        waterfall.fund(0, amount);
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_UnknownToken.selector, 0));
        waterfall.fund(0, 0);

        // (c) a facility whose NFT was BURNED by `cancelPending` — "no NFT" with real history
        uint256 pending = _findPendingFacility();
        vm.prank(originator);
        bridge.cancelPending(pending);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, pending));
        bridge.ownerOf(pending); // the NFT really is gone
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_NotFundable.selector, pending));
        waterfall.fund(pending, amount);

        // (d) a facility that is no longer Pending (already funded / defaulted), asked for its
        //     EXACT principal so that `Waterfall_PrincipalMismatch` cannot answer first. This is
        //     the only shape in which a missing state gate would actually release escrow, and it
        //     is how the mutation proof for this finding bites.
        uint256 funded = _findNonPendingFacility();
        uint256 exactPrincipalUSDC = bridge.facility(funded).principal / 1e12;
        assertGt(reserves.idleUSDC(), exactPrincipalUSDC, "precondition: reserves must be able to fund it again");
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_NotFundable.selector, funded));
        waterfall.fund(funded, exactPrincipalUSDC);

        // NOT ONE UNIT MOVED across every refusal
        assertEq(reserves.idleUSDC(), idleBefore, "ESCROW LEAKED: idle reserves moved on a refused funding");
        assertEq(reserves.deployedPrincipal(), deployedBefore, "ESCROW LEAKED: principal was deployed on a refusal");
    }

    function _findPendingFacility() private view returns (uint256) {
        for (uint256 i = 0; i < handler.mintedCount(); ++i) {
            uint256 id = handler.mintedAt(i);
            if (bridge.facility(id).state == ClaimBridge.LoanState.Pending) return id;
        }
        revert("precondition: the seeded fixture must leave a Pending facility to cancel");
    }

    function _findNonPendingFacility() private view returns (uint256) {
        for (uint256 i = 0; i < handler.mintedCount(); ++i) {
            uint256 id = handler.mintedAt(i);
            ClaimBridge.LoanState s = bridge.facility(id).state;
            if (s != ClaimBridge.LoanState.Pending && s != ClaimBridge.LoanState.Cancelled) return id;
        }
        revert("precondition: the seeded fixture must leave a funded or defaulted facility");
    }

    /// @notice Positive control: governance can intentionally rotate upgrade authority.
    function test_governanceCanRotateUpgradeAuthority() public {
        address sink = handler.roleSinkAddress();
        assertFalse(bridge.hasRole(Roles.UPGRADER_ROLE, sink), "precondition: the sink starts with no upgrade rights");
        assertEq(bridge.getRoleAdmin(Roles.UPGRADER_ROLE), bytes32(0), "UPGRADER_ROLE is administered by DEFAULT_ADMIN");

        vm.prank(admin);
        bridge.grantRole(Roles.UPGRADER_ROLE, sink);
        assertTrue(bridge.hasRole(Roles.UPGRADER_ROLE, sink), "governance grant did not take effect");
        vm.prank(admin);
        bridge.revokeRole(Roles.UPGRADER_ROLE, sink);
        assertFalse(bridge.hasRole(Roles.UPGRADER_ROLE, sink), "governance revoke did not restore baseline");
    }

    /// @notice Positive control: governance can intentionally rotate mint authority.
    function test_governanceCanRotateMintAuthority() public {
        address sink = handler.roleSinkAddress();
        assertFalse(usdfr.hasRole(Roles.MINTER_ROLE, sink), "precondition: the sink starts with no mint rights");
        assertEq(usdfr.getRoleAdmin(Roles.MINTER_ROLE), bytes32(0), "MINTER_ROLE is administered by DEFAULT_ADMIN");

        vm.prank(admin);
        usdfr.grantRole(Roles.MINTER_ROLE, sink);
        assertTrue(usdfr.hasRole(Roles.MINTER_ROLE, sink), "governance grant did not take effect");
        vm.prank(admin);
        usdfr.revokeRole(Roles.MINTER_ROLE, sink);
        assertFalse(usdfr.hasRole(Roles.MINTER_ROLE, sink), "governance revoke did not restore baseline");
    }

    // =====================================================================
    //  ANTI-VACUITY
    // =====================================================================

    /// @notice ANTI-VACUITY. A campaign that never reached the interesting states and
    ///         reported green is worse than no campaign, so this asserts the states were
    ///         reached rather than merely reporting the counters.
    /// @dev TWO BASES, and one honest correction to the pattern this repo introduced in
    ///      `CollateralInvariants`.
    ///
    ///      (1) SEED-BACKED RAW ABSOLUTES for every individual shape, asserted here. These are
    ///      real guarantees, not decoration: `afterInvariant` runs after EVERY run and each run
    ///      restarts from the post-`setUp` state, so asserting them here proves every run was
    ///      evaluated against a state in which a satisfied mint gate, a refused gate, a refused
    ///      terms binding, a bound concentration limit, a refused replay, a refused stale mark,
    ///      an unauthorised probe refused ON ACCESS CONTROL, an authorised control that
    ///      SUCCEEDED, a live default, a paused system, an unpaused system and all four
    ///      liveness probes actually existed.
    ///
    ///      (2) THE FUZZ-ONLY DELTA IS REPORTED, NOT ASSERTED — and this is a deliberate
    ///      departure from `CollateralInvariants`, which asserts it. Measured in forge
    ///      1.3.2-stable: `afterInvariant` runs per RUN, so a fuzz-only delta assertion is an
    ///      assertion about ONE 128-call run. With 17 registered selectors a single run misses
    ///      any given one with probability `(16/17)^128 ~ 4e-4`, which over 256 runs is `~10%`
    ///      per campaign. Reproduced: `--fuzz-seed 22` fails the delta assertion, and the same
    ///      campaign passes with the assertion removed while reporting 6 fuzz-only origination
    ///      attempts on its final run. A ~10% flake is not a CI gate. The wiring guarantee the
    ///      delta was supposed to give is carried instead by
    ///      `test_handler_everyRegisteredSelectorIsLiveAndRevertFree`, which is seed-independent
    ///      and asserts every registered selector is a live, revert-free handler entry point —
    ///      and by reading the call table, where each of the 17 selectors fires ~1,900 times per
    ///      32,768-call campaign.
    function afterInvariant() public view {
        _reportCoverage(); // printed FIRST so a failing assertion below still leaves evidence

        // INV-15 — both directions actually exercised
        assertGt(handler.ghostOriginateSuccesses(), 0, "VACUOUS: NOTHING WAS EVER ORIGINATED");
        assertGt(handler.ghostRejectGate(), 0, "VACUOUS: THE MINT GATE NEVER REFUSED AN UNATTESTED ORIGINATION");
        assertGt(handler.ghostRejectTerms(), 0, "VACUOUS: THE TERMS BINDING NEVER REFUSED A DIVERGENT ORIGINATION");

        // INV-16 — the binding regime was genuinely reached, not assumed
        assertGt(
            handler.ghostRejectClassConc() + handler.ghostRejectBorrowerConc() + handler.ghostRejectStateConc(),
            0,
            "VACUOUS: NO CONCENTRATION LIMIT EVER BOUND"
        );
        assertGt(
            handler.ghostAttemptsInBindingRegime(),
            0,
            "VACUOUS: NO ORIGINATION WAS ATTEMPTED WITH THE BOOTSTRAP FLOOR BELOW THE BOOK"
        );

        // INV-17 — the adversary actually ran, and was refused for the RIGHT reason
        assertGt(handler.ghostAttestAccepted(), 0, "VACUOUS: NO ATTESTATION WAS EVER ACCEPTED");
        assertGt(handler.ghostReplayAttempts(), 0, "VACUOUS: NO DIGEST REPLAY WAS EVER ATTEMPTED");
        assertGt(handler.ghostReplayRejected(), 0, "VACUOUS: NO DIGEST REPLAY WAS EVER REFUSED");
        assertEq(
            handler.ghostLastReplaySelector(),
            IAttestationOracle.Oracle_DigestAlreadyUsed.selector,
            "REPLAY WAS REFUSED FOR THE WRONG REASON (not the consumed digest)"
        );
        assertGt(handler.ghostStaleValuationAttempts(), 0, "VACUOUS: NO STALE-MARK ROLLBACK WAS ATTEMPTED");
        assertGt(handler.ghostStaleValuationRejected(), 0, "VACUOUS: NO STALE-MARK ROLLBACK WAS REFUSED");
        assertEq(
            handler.ghostLastStaleSelector(),
            IAttestationOracle.Oracle_StaleValuation.selector,
            "STALE MARK WAS REFUSED FOR THE WRONG REASON (not the watermark)"
        );

        // INV-18 — probes fired, were refused ON ACCESS CONTROL, and the same class of call
        // demonstrably succeeds for its authorised holder (otherwise the property is empty)
        assertGt(handler.ghostProbeAttempts(), 0, "VACUOUS: NO UNAUTHORISED PROBE WAS ATTEMPTED");
        assertGt(handler.ghostProbeRejectedByRole(), 0, "VACUOUS: NO PROBE WAS REFUSED ON ACCESS CONTROL");
        assertGt(
            handler.ghostAuthorisedControlSuccesses(),
            0,
            "NO TEETH: THE AUTHORISED CALLER NEVER SUCCEEDED, SO REFUSAL PROVES NOTHING"
        );
        assertEq(handler.ghostAuthorisedControlFailures(), 0, "AN AUTHORISED PRIVILEGED CALL FAILED");
        // "in any state" is a measured claim here
        assertGt(handler.ghostProbesWhileUnpaused(), 0, "VACUOUS: NO PROBE RAN AGAINST AN UNPAUSED SYSTEM");
        assertGt(handler.ghostProbesWhilePaused(), 0, "VACUOUS: NO PROBE RAN AGAINST A PAUSED SYSTEM");
        assertGt(handler.ghostProbesWithLiveDefault(), 0, "VACUOUS: NO PROBE RAN WITH A LIVE DEFAULT");
        assertGt(handler.ghostProbesWithFundedVault(), 0, "VACUOUS: NO PROBE RAN AGAINST A FUNDED VAULT");
        assertGt(handler.ghostProbesWithQueuedRequests(), 0, "VACUOUS: NO PROBE RAN WITH A QUEUED REDEMPTION");

        // INV-19 / INV-20 — role rotation was live and the baseline was restored.
        assertGt(handler.ghostRoleGrants(), 0, "VACUOUS: NO ROLE WAS EVER GRANTED");
        assertGt(handler.ghostUpgraderGrants(), 0, "VACUOUS: UPGRADER_ROLE WAS NEVER GRANTED TO A NON-TIMELOCK");
        assertGt(handler.ghostMinterGrants(), 0, "VACUOUS: MINTER_ROLE WAS NEVER GRANTED TO A NON-CONTROLLER");

        // INV-21 — every core path was actually probed at least once
        assertGt(handler.ghostLivenessProbes(), 0, "VACUOUS: LIVENESS WAS NEVER PROBED");
        assertGt(handler.ghostMintProbedOk(), 0, "VACUOUS: MINT REACHABILITY WAS NEVER DEMONSTRATED");
        assertGt(handler.ghostRedeemProbedOk(), 0, "VACUOUS: REDEEM REACHABILITY WAS NEVER DEMONSTRATED");
        assertGt(handler.ghostSettleProbedOk(), 0, "VACUOUS: QUEUE SETTLEMENT REACHABILITY WAS NEVER DEMONSTRATED");
        assertGt(handler.ghostCascadeProbedOk(), 0, "VACUOUS: CASCADE REACHABILITY WAS NEVER DEMONSTRATED");
    }

    /// @dev Measured readout for the reviewer (visible at `-vv`). Reported, never asserted:
    ///      these are the numbers that let a reader judge whether the campaign was thin.
    function _reportCoverage() private view {
        (uint256 fa, uint256 fs, uint256 fg, uint256 ft, uint256 fc, uint256 fp) = handler.fuzzOnlyCounts();
        console2.log("-- INV-authz campaign coverage (terminating run, fuzz-only delta) --");
        console2.log("handler calls seen / seed floor ", handler.callCount(), handler.seedCallCount());
        console2.log(
            "raw originate attempts/successes", handler.ghostOriginateAttempts(), handler.ghostOriginateSuccesses()
        );
        console2.log("raw unauthorised probe attempts ", handler.ghostProbeAttempts());
        console2.log("originate attempts / successes ", fa, fs);
        console2.log("gate / terms / concentration   ", fg, ft, fc);
        console2.log("unauthorised probes            ", fp);
        (uint256 ba, uint256 br, uint256 fba, uint256 fbr) = handler.bindingRegimeCounts();
        console2.log("concentration BINDING regime raw attempts / rejections ", ba, br);
        console2.log("concentration BINDING regime fuzz attempts / rejections", fba, fbr);
        console2.log("probe table coverage bitmap (29 bits)", handler.ghostProbeCoverage());
        console2.log(
            "probes paused / unpaused      ", handler.ghostProbesWhilePaused(), handler.ghostProbesWhileUnpaused()
        );
        console2.log(
            "probes live-default / settling", handler.ghostProbesWithLiveDefault(), handler.ghostProbesWhileSettling()
        );
        console2.log(
            "probes queued / funded vault  ",
            handler.ghostProbesWithQueuedRequests(),
            handler.ghostProbesWithFundedVault()
        );
        console2.log("replays attempted / refused   ", handler.ghostReplayAttempts(), handler.ghostReplayRejected());
        console2.log(
            "stale marks attempted/refused ",
            handler.ghostStaleValuationAttempts(),
            handler.ghostStaleValuationRejected()
        );
        console2.log(
            "role grants / upgrader / minter",
            handler.ghostRoleGrants(),
            handler.ghostUpgraderGrants(),
            handler.ghostMinterGrants()
        );
        console2.log("escrow probes / LEAKS         ", handler.escrowProbeAttempts(), handler.escrowLeaks());
        handler.reachReport(); // AUDIT G11/G12: per-guard reached / NOT-REACHED table
        console2.log("liveness probes               ", handler.ghostLivenessProbes());
        console2.log("mint ok / redeem ok           ", handler.ghostMintProbedOk(), handler.ghostRedeemProbedOk());
        console2.log(
            "settle ok / cascade ok / n-a  ",
            handler.ghostSettleProbedOk(),
            handler.ghostCascadeProbedOk(),
            handler.ghostCascadeNotApplicable()
        );
    }
}

/// @dev Minimal `hasRole` view so INV-19 can sweep heterogeneous module types by address.
interface IRoleReader {
    function hasRole(bytes32 role, address account) external view returns (bool);
}
