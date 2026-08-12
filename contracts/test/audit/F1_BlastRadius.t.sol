// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {Config} from "../../src/libraries/Config.sol";
import {ProductionCreditFixture} from "../helpers/ProductionCreditFixture.sol";

/// @title F1_BlastRadius — the differential harness for finding F1 (F-S3-01 conservative-NAV clamp)
///
/// @notice ADR-0035 DISPOSITION. The opening finding narrative and the legacy reference-model
///         fields below preserve the capped predecessor's provenance. They are not a description
///         of the current production rule. Active current-tree assertions execute the real SGrove
///         and pin one shared live reserve, which any one event may exhaust.
///
/// @notice WHAT THIS IS. `DefaultManager.pendingSeniorImpairment()` is a single number with FIVE
///         downstream consumers. Finding F1 (HIGH) is that the F-S3-01 clamp pools per-EVENT
///         coverage rooms against POOLED residual principal — it computes
///         `min(SUM p_i, min(SUM r_i, reserve))` where a committed room is only ever deliverable
///         against its OWN facility's remaining principal, so the executable aggregate is
///         `SUM min(p_i, r_i)` clamped at the reserve. The two coincide only when every event's
///         principal dominates its room, which is the shape of every fixture in the acceptance
///         suite.
///
///         When the fix lands the number moves. This file captures, for a FIXED scenario set,
///         the exact value each consumer derives from it, so the post-fix run is a clean textual
///         diff rather than a re-derivation.
///
/// @dev    HOW TO RE-RUN (see `docs/remediation/evidence/F1-blast-radius/README.md`):
///           cd <tree>/contracts && set -a && . ../.env && set +a \
///             && forge test --match-path 'test/audit/F1_BlastRadius.t.sol' -vv \
///             | grep '^  BLAST ' | sed 's/^  //' | sort > run.txt
///           diff baseline.txt run.txt
///
///         OUTPUT FORMAT — one line per captured quantity, deliberately grep/sort/diff stable:
///           BLAST <scenario> <consumer> <quantity> <value>
///         Every value is an unsigned decimal. Booleans are 0/1. A probe that reverted emits its
///         own `*Reverted 1` line rather than being silently omitted — an absent line is a
///         harness change, never a protocol result.
///
///         EVERY SCENARIO RUNS AGAINST THE REAL `SGrove` (`ProductionCreditFixture`), NEVER
///         `MockCascadeBackstop`. This was load-bearing on the capped predecessor because the
///         mock could not reproduce first-draw snapshots; it remains load-bearing under ADR-0035
///         because only the real contract proves the shared reserve is physically transferred and
///         exhausted. `ProductionCreditFixture.setUp` re-points `defaultManager.setBackstop` at the
///         real `SGrove`, replacing `CreditLayerFixture`'s mock.
///
///         WHAT IS EXPECTED TO MOVE, AND WHAT MUST NOT — the whole point of the control set:
///           MOVES  : `asymmetric`, `asymmetricOrderBA`, `zerocross`, `partialdrawn`, `concurrent4`
///           STATIC : `symmetric2`, `symmetric3`, `ateventcap`, `smallreserve`, `zeroreserve`,
///                    `terminalrelease`
///         A post-fix run in which a STATIC scenario moved is a regression in the fix, not a
///         success. A post-fix run in which `asymmetric`'s `SUSDFR previewRedeem` did NOT move is
///         a fix that did not reach the senior exit price.
abstract contract F1BlastRadiusBase is ProductionCreditFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;

    /// @dev Two FIXED absolute assessment amounts probed against `AssessedImpairmentSource`.
    ///      Fixed literals, never a fraction of the live base: the whole point is to detect the
    ///      base moving underneath a governance action whose input did not change.
    uint256 internal constant ASSESSMENT_PROBE_SMALL = 5_000e18;
    uint256 internal constant ASSESSMENT_PROBE_LARGE = 50_000e18;

    /// @dev Interest driven through `WaterfallEngine.distribute` for the fee-withholding probe.
    ///      Sized so `feeGross` (10% of it, `Config.DEFAULT_PROTOCOL_FEE_BPS`) straddles the
    ///      pre-fix residual on the asymmetric cohort: a smaller fee saturates the
    ///      `min(feeGross, residual)` and would measure nothing.
    uint256 internal constant WATERFALL_PROBE_INTEREST = 500_000e18;

    /// @dev USDfr redeemed directly through `MintRedeemController` in the exit-draw probe.
    uint256 internal constant CONTROLLER_PROBE_REDEEM = 50_000e18;

    /// @dev LANE-1 (v2) — the curator first-loss posted by the two FUNDED scenarios. It equals the
    ///      asymmetric cohort's 15,000e18 small-facility residual. Under ADR-0035 there is no room
    ///      to strand: both cohorts must combine that layer-1 delivery with the same live layer-2
    ///      reserve. Holding the amount fixed still makes the pair a comparison of cohort shape.
    uint256 internal constant FUNDED_FIRST_LOSS = 15_000e18;

    /// @dev Evidence hash used ONLY by the executed-oracle exhaustion pass (see `_deliverable`).
    bytes32 internal constant ORACLE_REF = keccak256("F1-blast-oracle-exhaustion");

    /// @dev Live default token ids for the current scenario, in DECLARATION order.
    uint256[] internal evIds;

    // ── emission ─────────────────────────────────────────────────────────

    function _blast(string memory scenario, string memory consumer, string memory quantity, uint256 value)
        internal
        pure
    {
        console2.log(string.concat("BLAST ", scenario, " ", consumer, " ", quantity, " ", Strings.toString(value)));
    }

    function _blastBool(string memory scenario, string memory consumer, string memory quantity, bool value)
        internal
        pure
    {
        _blast(scenario, consumer, quantity, value ? 1 : 0);
    }

    // ── scenario construction primitives ─────────────────────────────────

    /// @dev Concentration limits opened so a scenario can express the cohort SHAPE it needs.
    ///      These are registry origination gates; nothing in `ConservativeImpairmentMath` or
    ///      `CollateralRegistry.conservativeSeniorMark` reads them, so opening them cannot move
    ///      any captured number. Verified: the `asymmetric` scenario reproduces the adjudicator's
    ///      JUDGE_AggregateDeliverability figures (375,000e18 / 200,000e18 / 30,000e18) exactly.
    function _openLimits() internal {
        vm.startPrank(admin);
        ICollateralRegistry.ClassParams memory p = registry.classParams(FILM);
        p.concentrationLimitBps = Config.RAMP_CONCENTRATION_LIMIT_BPS;
        registry.setClass(FILM, p);
        registry.setBorrowerLimit(Config.RAMP_CONCENTRATION_LIMIT_BPS);
        registry.setStateLimit(Config.RAMP_CONCENTRATION_LIMIT_BPS);
        vm.stopPrank();
    }

    function _fundBackstop(uint256 amount) internal {
        _mintUSDfrTo(bob, amount);
        vm.prank(bob);
        usdfr.approve(address(sGrove), amount);
        vm.prank(bob);
        sGrove.fundCoverage(amount);
    }

    function _stakeVault(address who, uint256 amount) internal {
        _mintUSDfrTo(who, amount);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
    }

    /// @dev Originates, funds and DECLARES a film default. Records the token id in `evIds`.
    function _defaulted(bytes32 borrower, uint256 principal) internal returns (uint256 id) {
        _mintUSDfrTo(alice, principal);
        id = _originateFilm(borrower, STATE_GA, principal);
        _fundFacility(id, principal);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        evIds.push(id);
    }

    /// @dev A realization: ordinary SERVICER_ROLE, genuine 2-of-n LossRealized attestation. This
    ///      is what makes an event DRAWN, i.e. what snapshots its per-event ceiling against the
    ///      reserve standing at that instant. No privilege abuse anywhere in this harness.
    function _realize(uint256 tokenId, uint256 loss) internal {
        _attestLoss(tokenId, loss, FILM_REF);
        vm.prank(servicer);
        defaultManager.realizeLoss(tokenId, loss, FILM_REF);
    }

    /// @dev Coverage the backstop still holds open for `eventId`, per SGrove's OWN committed
    ///      ceiling. `DefaultManager` uses the facility's tokenId as the sGROVE event id.
    function _roomAt(uint256 eventId) internal view returns (uint256) {
        (uint256 drawn, uint256 cap) = sGrove.eventCoverage(eventId);
        return cap > drawn ? cap - drawn : 0;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  CONSUMER CAPTURES
    // ══════════════════════════════════════════════════════════════════════

    /// @dev The source itself, plus every input the clamp reads. Not a consumer — this block is
    ///      what makes a moved consumer number ATTRIBUTABLE to the clamp rather than to a
    ///      fixture drift between trees.
    function _captureBook(string memory s) internal view {
        _blast(s, "DM", "pendingSeniorImpairment", defaultManager.pendingSeniorImpairment());
        // CONTROL: gross declared+past-due principal. Reads no backstop and no clamp, so the fix
        // must NOT move it in any scenario.
        _blast(s, "DM", "performanceFeeImpairment", defaultManager.performanceFeeImpairment());
        _blast(s, "DM", "declaredDefaultedPrincipal", defaultManager.declaredDefaultedPrincipal(FILM));
        _blast(s, "DM", "drawnDefaultPrincipal", defaultManager.drawnDefaultPrincipal(FILM));
        _blast(s, "DM", "pastDuePrincipal", defaultManager.pastDuePrincipal(FILM));
        _blast(s, "DM", "liveDefaultCoverageRemaining", defaultManager.liveDefaultCoverageRemaining());
        _blast(s, "DM", "liveDefaultCoverageConsumed", defaultManager.liveDefaultCoverageConsumed());
        _blast(s, "SGROVE", "coverageReserve", sGrove.coverageReserve());
        _blast(s, "SGROVE", "coverageCapacity", sGrove.coverageCapacity());
        _blast(s, "CURATOR", "poolBalance", curator.poolBalance(FILM));
        for (uint256 i = 0; i < evIds.length; ++i) {
            string memory tag = Strings.toString(i);
            _blast(s, "EVENT", string.concat("principal.", tag), defaultManager.defaultedContribution(evIds[i]));
            _blast(s, "EVENT", string.concat("room.", tag), _roomAt(evIds[i]));
            _blast(s, "EVENT", string.concat("committed.", tag), defaultManager.coverageRemainingByDefault(evIds[i]));
        }
    }

    /// @dev CONSUMER 5 — `AssessedImpairmentSource`. The production `IImpairmentSource` the vault
    ///      is actually wired to (`CreditLayerFixture` calls
    ///      `vault.setImpairmentSource(address(assessedImpairmentSource))`), so EVERY number in
    ///      the `SUSDFR` and `QUEUE` blocks below is read THROUGH this contract.
    ///
    ///      Three distinct ways the fix reaches it, none of which any existing test watches:
    ///        (1) the pass-through value;
    ///        (2) `maxSettableAssessment` — `setAssessment` reverts above the live base, so the
    ///            base IS a governance ceiling. A memo that governance can publish today may be
    ///            rejected post-fix, or vice versa. Probed with FIXED absolute amounts.
    ///        (3) `assessedPerformanceFeeImpairment = assessed + (basePerf - base)`. `basePerf`
    ///            does not move, so a moving `base` moves the fee NAV under a STANDING
    ///            assessment — a silent performance-fee repricing.
    function _captureAssessed(string memory s) internal {
        uint256 pending = assessedImpairmentSource.pendingSeniorImpairment();
        uint256 perf = assessedImpairmentSource.performanceFeeImpairment();
        _blast(s, "AIS", "pendingSeniorImpairment", pending);
        _blast(s, "AIS", "performanceFeeImpairment", perf);
        // The junior-capital credit the NAV is handing out. This IS the F1 quantity by another
        // name: gross impairment less what the cascade is credited with absorbing.
        _blast(s, "AIS", "juniorCreditSpread", perf >= pending ? perf - pending : 0);
        (,,, bool active, uint256 zeroRecovery) = assessedImpairmentSource.currentAssessment();
        _blastBool(s, "AIS", "assessmentActive", active);
        _blast(s, "AIS", "zeroRecoveryBase", zeroRecovery);
        // (2)+(3): the governance ceiling and the fee-base snapshot, at two FIXED amounts.
        _blast(s, "AIS", "maxSettableAssessment", zeroRecovery);
        _probeAssessment(s, "small", ASSESSMENT_PROBE_SMALL);
        _probeAssessment(s, "large", ASSESSMENT_PROBE_LARGE);
    }

    function _probeAssessment(string memory s, string memory tag, uint256 amount) private {
        uint256 snap = vm.snapshotState();
        vm.prank(admin);
        try assessedImpairmentSource.setAssessment(amount, uint64(block.timestamp + 7 days), keccak256("F1-blast")) {
            _blast(s, "AIS", string.concat("assess.", tag, ".accepted"), 1);
            _blast(
                s, "AIS", string.concat("assess.", tag, ".pending"), assessedImpairmentSource.pendingSeniorImpairment()
            );
            _blast(
                s,
                "AIS",
                string.concat("assess.", tag, ".perfFeeBase"),
                assessedImpairmentSource.performanceFeeImpairment()
            );
            _blast(s, "AIS", string.concat("assess.", tag, ".vaultRedemptionAssets"), vault.redemptionTotalAssets());
            _blast(
                s, "AIS", string.concat("assess.", tag, ".vaultExitPrice"), vault.previewRedeem(vault.balanceOf(alice))
            );
        } catch {
            _blast(s, "AIS", string.concat("assess.", tag, ".accepted"), 0);
            _blast(s, "AIS", string.concat("assess.", tag, ".pending"), 0);
            _blast(s, "AIS", string.concat("assess.", tag, ".perfFeeBase"), 0);
            _blast(s, "AIS", string.concat("assess.", tag, ".vaultRedemptionAssets"), 0);
            _blast(s, "AIS", string.concat("assess.", tag, ".vaultExitPrice"), 0);
        }
        vm.revertToState(snap);
    }

    /// @dev CONSUMER 1 — `sUSDfr`. `redemptionTotalAssets()` is the ONLY senior exit price, and
    ///      `previewRedeem` / `previewWithdraw` / `convertToSharesAtRedemption` all divide by it.
    ///      `totalAssets()` and `convertToAssets()` are the REALIZED NAV and are CONTROLS: they
    ///      read no impairment source at all and must not move.
    function _captureVault(string memory s) internal view {
        uint256 shares = vault.balanceOf(alice);
        uint256 realized = vault.convertToAssets(shares);
        uint256 exit = vault.previewRedeem(shares);
        _blast(s, "SUSDFR", "totalAssets", vault.totalAssets());
        _blast(s, "SUSDFR", "redemptionTotalAssets", vault.redemptionTotalAssets());
        _blast(s, "SUSDFR", "aliceShares", shares);
        _blast(s, "SUSDFR", "convertToAssets", realized);
        _blast(s, "SUSDFR", "previewRedeem", exit);
        _blast(s, "SUSDFR", "previewWithdraw.1e18", vault.previewWithdraw(1e18));
        _blast(s, "SUSDFR", "convertToSharesAtRedemption.100k", vault.convertToSharesAtRedemption(100_000e18));
        _blast(
            s,
            "SUSDFR",
            "exitHaircutBps",
            realized == 0 ? 0 : ((realized >= exit ? realized - exit : 0) * Config.BPS) / realized
        );
    }

    /// @dev CONSUMER 2 — `RedemptionQueue`. `headValuation()` prices the settlement front off
    ///      `previewRedeem`, and `closeEpoch` sizes every fill off
    ///      `convertToSharesAtRedemption` / `previewRedeem`. Both are captured: the VIEW the
    ///      keeper reads before acting, and the SETTLED number the redeemer actually receives.
    ///      The epoch throttle is opened to 100% inside the snapshot so the captured figure is a
    ///      PRICE, not a liquidity cap.
    function _captureQueue(string memory s) internal {
        uint256 snap = vm.snapshotState();
        uint256 ts = block.timestamp;
        uint256 shares = vault.balanceOf(alice);
        _blast(s, "QUEUE", "availableLiquidityAtDefaultBps", queue.availableLiquidity());
        if (shares == 0) {
            _blast(s, "QUEUE", "noStakeToQueue", 1);
            vm.revertToState(snap);
            vm.warp(ts);
            return;
        }
        vm.prank(admin);
        queue.setEpochLiquidityBps(10_000); // isolate PRICE from the throttle
        vm.startPrank(alice);
        vault.approve(address(queue), shares);
        uint256 reqId = queue.requestRedeem(shares);
        vm.stopPrank();

        (, uint256 headShares, uint256 headValue, uint256 bookValue) = queue.headValuation();
        _blast(s, "QUEUE", "headShares", headShares);
        _blast(s, "QUEUE", "headValue", headValue);
        _blast(s, "QUEUE", "bookValue", bookValue);
        _blast(s, "QUEUE", "settlementBudget", queue.availableLiquidity());

        vm.warp(queue.eligibleToSettleAt(reqId));
        try queue.closeEpoch(20) {
            _blast(s, "QUEUE", "closeEpochReverted", 0);
        } catch {
            _blast(s, "QUEUE", "closeEpochReverted", 1);
        }
        (, uint256 remaining, uint256 claimable,,) = queue.request(reqId);
        _blast(s, "QUEUE", "sharesRemainingAfterSettle", remaining);
        _blast(s, "QUEUE", "assetsClaimable", claimable);
        uint256 balBefore = usdfr.balanceOf(alice);
        if (claimable != 0) {
            vm.prank(alice);
            queue.claim(reqId);
        }
        _blast(s, "QUEUE", "claimedAssets", usdfr.balanceOf(alice) - balBefore);
        vm.revertToState(snap);
        vm.warp(ts);
    }

    /// @dev CONSUMER 4 — `WaterfallEngine._withholdFeeForSeniorImpairment`. The protocol fee on
    ///      every distributed interest payment is withheld up to `min(feeGross, residual)`, where
    ///      `residual` IS `pendingSeniorImpairment()`. The withheld fee is never minted at all,
    ///      so it stays in the reserve as backing. A performing facility is created INSIDE the
    ///      snapshot so the scenario's own cohort is untouched.
    function _captureWaterfall(string memory s) internal {
        uint256 snap = vm.snapshotState();
        _blast(s, "WATERFALL", "residualAtDistribute", defaultManager.pendingSeniorImpairment());
        uint256 performing = _liveFilmFacility(50_000e18);
        _blast(s, "WATERFALL", "mintableHeadroomBefore", controller.mintableHeadroom());
        uint256 feeBefore = usdfr.balanceOf(feeRecipient);
        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        IWaterfallEngine.Payment memory payment = _preparePayment(performing, WATERFALL_PROBE_INTEREST, 0);

        vm.recordLogs();
        vm.prank(servicer);
        try waterfall.distribute(payment) {
            _blast(s, "WATERFALL", "distributeReverted", 0);
        } catch {
            _blast(s, "WATERFALL", "distributeReverted", 1);
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 evWithheld;
        uint256 evResidual;
        uint256 evSeen;
        bytes32 topic = IWaterfallEngine.ProtocolFeeWithheldForSeniorImpairment.selector;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic) {
                (evWithheld, evResidual) = abi.decode(logs[i].data, (uint256, uint256));
                evSeen = 1;
            }
        }
        uint256 feeNet = usdfr.balanceOf(feeRecipient) - feeBefore;
        uint256 toVault = usdfr.balanceOf(address(vault)) - vaultBefore;
        // `toVault = distributable - feeGross` and `feeGross = distributable * 1000 / 10000`, so
        // `feeGross = toVault / 9`. Derived rather than assumed so a headroom clip is visible.
        uint256 feeGross = toVault / 9;
        _blast(s, "WATERFALL", "withholdEventSeen", evSeen);
        _blast(s, "WATERFALL", "withheldFromEvent", evWithheld);
        _blast(s, "WATERFALL", "residualFromEvent", evResidual);
        _blast(s, "WATERFALL", "feeGrossDerived", feeGross);
        _blast(s, "WATERFALL", "feeNetMinted", feeNet);
        _blast(s, "WATERFALL", "toVaultMinted", toVault);
        _blast(s, "WATERFALL", "feeWithheldMeasured", feeGross >= feeNet ? feeGross - feeNet : 0);
        vm.revertToState(snap);
    }

    /// @dev CONSUMER 3 — `MintRedeemController`, the ADR-0034 Y-bis atomic junior exit draw.
    ///
    ///      READ THE HONEST RESULT IN THE README BEFORE TREATING A STATIC LINE HERE AS COVERAGE.
    ///      `_exitDrawTarget` DELIBERATELY does not consult `pendingSeniorImpairment()` — its own
    ///      NatSpec says so, and it sizes the draw off the CUSTODY deficit `supply - backing`.
    ///      So the direct-exit QUOTE is not a consumer of the clamp at all. What IS coupled is
    ///      the other direction: the draw physically removes curator capital and sGROVE reserve,
    ///      which are the clamp's own operands, so `pendingSeniorImpairment()` AFTER a direct
    ///      exit is a genuine downstream value. Both are captured, and the quote is labelled a
    ///      control.
    function _captureController(string memory s) internal {
        uint256 snap = vm.snapshotState();
        try controller.previewRedeem(CONTROLLER_PROBE_REDEEM) returns (uint256 usdcOut, uint256 usdfrIn) {
            _blast(s, "CONTROLLER", "previewRedeem.usdcOut", usdcOut);
            _blast(s, "CONTROLLER", "previewRedeem.usdfrIn", usdfrIn);
            _blast(s, "CONTROLLER", "previewRedeemReverted", 0);
        } catch {
            _blast(s, "CONTROLLER", "previewRedeem.usdcOut", 0);
            _blast(s, "CONTROLLER", "previewRedeem.usdfrIn", 0);
            _blast(s, "CONTROLLER", "previewRedeemReverted", 1);
        }
        _blast(s, "CONTROLLER", "mintableHeadroom", controller.mintableHeadroom());
        _exitProbe(s, "par", false);
        vm.revertToState(snap);

        // SECOND SUB-PROBE: force `backing < supply` with an ADR-0017 §3 governance valuation
        // mark, which lowers backing WITHOUT burning USDfr, so the ADR-0034 Y-bis draw actually
        // fires. Without this the draw target is 0 BY CONSTRUCTION in every scenario here and the
        // block would be vacuous.
        snap = vm.snapshotState();
        _exitProbe(s, "deficit", true);
        vm.revertToState(snap);
    }

    function _exitProbe(string memory s, string memory tag, bool withDeficit) private {
        // The redeemer's USDfr is minted BEFORE the mark: `mint` is closed while under-backed
        // (`Controller_MintClosedWhileUnderBacked`), which is correct protocol behaviour and not
        // something the harness may work around.
        _mintUSDfrTo(bob, 100_000e18);
        uint256 markAmount;
        if (withDeficit) {
            uint256 last = evIds[evIds.length - 1];
            markAmount = reserves.deployedTo(last);
            if (markAmount > 200_000e18) markAmount = 200_000e18;
            if (markAmount != 0) {
                vm.prank(admin);
                reserves.recognizePrincipalImpairment(last, markAmount, keccak256("F1-blast-deficit"));
            }
        }
        _blast(s, "CONTROLLER", string.concat(tag, ".recognizedMark"), markAmount);
        _blast(s, "CONTROLLER", string.concat(tag, ".backingValue"), reserves.totalBackingValue());
        _blast(s, "CONTROLLER", string.concat(tag, ".usdfrTotalSupply"), usdfr.totalSupply());
        {
            uint256 supply = usdfr.totalSupply();
            uint256 backing = reserves.totalBackingValue();
            _blast(s, "CONTROLLER", string.concat(tag, ".exitDeficit"), supply > backing ? supply - backing : 0);
        }
        uint256 sgBefore = usdfr.balanceOf(address(sGrove));
        uint256 curBefore = usdfr.balanceOf(address(curator));
        _blast(s, "CONTROLLER", string.concat(tag, ".impairmentBeforeExit"), defaultManager.pendingSeniorImpairment());
        vm.prank(bob);
        try controller.redeem(CONTROLLER_PROBE_REDEEM, 0) returns (uint256 usdcOut) {
            _blast(s, "CONTROLLER", string.concat(tag, ".redeem.usdcOut"), usdcOut);
            _blast(s, "CONTROLLER", string.concat(tag, ".redeemReverted"), 0);
        } catch {
            _blast(s, "CONTROLLER", string.concat(tag, ".redeem.usdcOut"), 0);
            _blast(s, "CONTROLLER", string.concat(tag, ".redeemReverted"), 1);
        }
        uint256 sgAfter = usdfr.balanceOf(address(sGrove));
        uint256 curAfter = usdfr.balanceOf(address(curator));
        _blast(s, "CONTROLLER", string.concat(tag, ".drawFromBackstop"), sgBefore >= sgAfter ? sgBefore - sgAfter : 0);
        _blast(
            s, "CONTROLLER", string.concat(tag, ".drawFromCurator"), curBefore >= curAfter ? curBefore - curAfter : 0
        );
        _blast(s, "CONTROLLER", string.concat(tag, ".impairmentAfterExit"), defaultManager.pendingSeniorImpairment());
        _blast(s, "CONTROLLER", string.concat(tag, ".coverageReserveAfterExit"), sGrove.coverageReserve());
        _blast(s, "CONTROLLER", string.concat(tag, ".exitPriceAfterExit"), vault.previewRedeem(vault.balanceOf(alice)));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  THE ORACLE — an independent reference model of what the fix must produce
    // ══════════════════════════════════════════════════════════════════════

    /// @dev EXECUTED GROUND TRUTH. Runs the cascade to exhaustion on every live event in this
    ///      block and measures what physically LEAVES the backstop. This number is computed by
    ///      execution, not by re-implementing the clamp, so it cannot be wrong in the same
    ///      direction as the code under test. `forward` runs the events in declaration order;
    ///      `reverse` runs them backwards, which is what makes greedy-allocation order effects
    ///      observable.
    function _deliverable(bool forward) internal returns (uint256 delivered) {
        (, delivered,) = _deliverableJunior(forward);
    }

    /// @dev LANE-1 (v2) — THE SAME EXECUTED PASS, MEASURED ACROSS **BOTH** JUNIOR LAYERS.
    ///
    ///      `_deliverable` measures only what physically leaves `SGrove`. That is the whole of the
    ///      junior delivery ONLY while layer 1 is empty, which is true of every v1 scenario
    ///      (`CURATOR poolBalance 0` in all eleven). The v2 funded-layer-1 scenarios break that
    ///      precondition: `DefaultManager.realizeLoss` consults `curator.absorbLoss` BEFORE
    ///      `_drawLayer2ForLiveDefault`, so a funded pool delivers real capital that never touches
    ///      the backstop balance. Comparing a mark that nets layer 1 against a layer-2-only
    ///      ground truth would be measuring two different things.
    ///
    ///      `_deliverable` is now a projection of this function onto its layer-2 component and runs
    ///      the identical loop, so every v1 `ORACLE deliverableForward/Reverse` value is unchanged
    ///      by construction — verified empirically by `DIFF_v2.md`, in which no pre-existing line
    ///      moved.
    /// @return total Layer 1 + layer 2 actually delivered by this realization order.
    /// @return layerTwo USDfr that physically left `SGrove`.
    /// @return layerOne First-loss the `CuratorModule` pool physically absorbed (FILM class).
    function _deliverableJunior(bool forward) internal returns (uint256 total, uint256 layerTwo, uint256 layerOne) {
        uint256 snap = vm.snapshotState();
        uint256 before = usdfr.balanceOf(address(sGrove));
        uint256 poolBefore = curator.poolBalance(FILM);
        uint256 n = evIds.length;
        for (uint256 k = 0; k < n; ++k) {
            uint256 id = forward ? evIds[k] : evIds[n - 1 - k];
            if (defaultManager.defaultedContribution(id) == 0) continue;
            uint256 amount = reserves.deployedTo(id);
            if (amount == 0) continue;
            // A DISTINCT evidence hash, not `FILM_REF`. The attested `LossRealized` fact is
            // `keccak256(abi.encode(tokenId, loss, evidenceHash))` and is single-use, so a
            // scenario that already realized this exact (id, amount) pair would collide with
            // `Oracle_FactAlreadyRealised` and silently truncate the oracle.
            _attestLoss(id, amount, ORACLE_REF);
            vm.prank(servicer);
            try defaultManager.realizeLoss(id, amount, ORACLE_REF) {}
            catch {
                // NEVER SILENT (CLAUDE.md prime directive 4): a refused realization is emitted so
                // a reader can see the oracle was clipped rather than assuming it ran clean.
                console2.log(string.concat("BLAST-ORACLE-NOTE realizeLoss reverted for id ", Strings.toString(id)));
            }
        }
        uint256 after_ = usdfr.balanceOf(address(sGrove));
        uint256 poolAfter = curator.poolBalance(FILM);
        layerTwo = before >= after_ ? before - after_ : 0;
        layerOne = poolBefore >= poolAfter ? poolBefore - poolAfter : 0;
        total = layerOne + layerTwo;
        vm.revertToState(snap);
    }

    /// @dev THE HONEST AGGREGATE: `SUM min(p_i, r_i)`, read per event out of SGrove's OWN
    ///      committed ceilings. This is the arithmetic F1 says the clamp should be doing.
    function _perEventHonestSum() internal view returns (uint256 sum) {
        for (uint256 i = 0; i < evIds.length; ++i) {
            uint256 p = defaultManager.defaultedContribution(evIds[i]);
            uint256 r = _roomAt(evIds[i]);
            sum += p < r ? p : r;
        }
    }

    /// @dev The reference model's inputs and outputs, in a struct because the flat form is
    ///      `Stack too deep` under the shipped (non-via-IR) compiler settings.
    struct Model {
        uint256 drawnResidual;
        uint256 undrawnResidual;
        /// @dev LANE-1 (v2). Layer-1 first-loss the per-class allocation charged to DRAWN
        ///      principal. Zero in every v1 scenario, so every v1 model value is unchanged.
        uint256 curatorAppliedToDrawn;
        uint256 reserve;
        uint256 capacity;
        uint256 honestClamped;
        uint256 pooledClamped;
        uint256 creditedDrawn;
        uint256 honestDrawn;
        uint256 fresh;
        uint256 modelNow;
        uint256 modelFix;
    }

    /// @dev LANE-1 (v2) — THE EXECUTED GROUND TRUTH, PUBLISHED PER LAYER AND PER ORDER.
    ///
    ///      Split out of `_captureOracle` for two reasons. (1) STACK: `_captureOracle` was already
    ///      at the `Stack too deep` limit under the shipped non-via-IR settings, which is why its
    ///      locals live in a struct. (2) COST: the cascade is driven ONCE per direction and both
    ///      the layer-2 and the layer-1+2 figures come out of the same pass, so the v1
    ///      `deliverableForward` / `deliverableReverse` values are produced by the identical loop
    ///      that produced them before.
    ///
    ///      `juniorDeliverableWorstOrder` is the number a CONSERVATIVE mark has to respect. A
    ///      credit that only the FAVOURABLE order can fund is a credit the protocol may not be
    ///      able to deliver, and the difference is paid to whoever exits first. With two live
    ///      events forward and reverse ENUMERATE THE FULL-REALIZATION ORDERS, so on the two-event
    ///      funded cohorts this is the exact minimum over that family, not a sample of it.
    ///      STATED PRECISELY BECAUSE IT MATTERS: the sweep realizes each event's whole outstanding
    ///      balance in one call, so PARTIAL interleavings (realize half of A, then B, then the rest
    ///      of A) are NOT swept. A partial interleaving cannot deliver MORE than the best full
    ///      order, so the upper bound is safe; it could in principle deliver LESS, which would make
    ///      the worst-order bound below optimistic rather than conservative. Not swept, not
    ///      claimed.
    /// @return forwardLayerTwo Layer-2 delivery in declaration order (the v1 `deliverableForward`).
    function _captureExecuted(string memory s) internal returns (uint256 forwardLayerTwo) {
        uint256 worstJunior;
        {
            (uint256 total, uint256 layerTwo, uint256 layerOne) = _deliverableJunior(true);
            forwardLayerTwo = layerTwo;
            worstJunior = total;
            _blast(s, "ORACLE", "deliverableForward", layerTwo);
            _blast(s, "ORACLE", "layerOneDeliverableForward", layerOne);
            _blast(s, "ORACLE", "juniorDeliverableForward", total);
        }
        {
            (uint256 total, uint256 layerTwo, uint256 layerOne) = _deliverableJunior(false);
            if (total < worstJunior) worstJunior = total;
            _blast(s, "ORACLE", "deliverableReverse", layerTwo);
            _blast(s, "ORACLE", "layerOneDeliverableReverse", layerOne);
            _blast(s, "ORACLE", "juniorDeliverableReverse", total);
        }
        _blast(s, "ORACLE", "juniorDeliverableWorstOrder", worstJunior);
        // The measure the gate asserts on, published so a reader can read the finding straight out
        // of the capture instead of re-deriving it from two other lines.
        uint256 credited = defaultManager.performanceFeeImpairment() - defaultManager.pendingSeniorImpairment();
        _blast(s, "ORACLE", "juniorCreditGranted", credited);
        _blast(s, "ORACLE", "overCreditVsWorstOrder", credited > worstJunior ? credited - worstJunior : 0);
    }

    function _captureOracle(string memory s) internal {
        Model memory m;
        // LANE-1 (v2) — the per-class LAYER-1 SPLIT, transcribed from
        // `ConservativeImpairmentMath.pendingSeniorImpairment`: the pool is offered to UNDRAWN
        // principal first, and only the remainder reaches drawn principal. With an empty pool
        // (`curator.poolBalance == 0`, every v1 scenario) both limbs are zero and this block
        // reduces EXACTLY to the v1 expression `drawnResidual = drawnDefaultPrincipal`,
        // `undrawnResidual = declared - drawn`. Verified, not asserted: no v1 line moved in
        // `DIFF_v2.md`.
        {
            uint256 drawnGross = defaultManager.drawnDefaultPrincipal(FILM);
            uint256 declared = defaultManager.declaredDefaultedPrincipal(FILM);
            uint256 undrawnGross = declared >= drawnGross ? declared - drawnGross : 0;
            uint256 pool = curator.poolBalance(FILM);
            uint256 forUndrawn = pool < undrawnGross ? pool : undrawnGross;
            uint256 poolLeft = pool - forUndrawn;
            uint256 forDrawn = poolLeft < drawnGross ? poolLeft : drawnGross;
            m.drawnResidual = drawnGross - forDrawn;
            m.undrawnResidual = undrawnGross - forUndrawn;
            m.curatorAppliedToDrawn = forDrawn;
            _blast(s, "ORACLE", "curatorAppliedToDrawn", forDrawn);
            _blast(s, "ORACLE", "drawnResidualPostLayerOne", m.drawnResidual);
        }
        m.reserve = sGrove.coverageReserve();
        m.capacity = sGrove.coverageCapacity();

        {
            uint256 honest = _perEventHonestSum();
            uint256 pooled = defaultManager.liveDefaultCoverageRemaining();
            m.honestClamped = honest < m.reserve ? honest : m.reserve;
            m.pooledClamped = pooled < m.reserve ? pooled : m.reserve;
            _blast(s, "ORACLE", "perEventHonestSum", honest);
            _blast(s, "ORACLE", "perEventHonestClamped", m.honestClamped);
            _blast(s, "ORACLE", "pooledRoomsClamped", m.pooledClamped);
        }

        uint256 fwd = _captureExecuted(s);

        // The model below is only well-formed for a SINGLE-CLASS cohort with no past-due marks —
        // every scenario in this file is built that way, and the flag makes the precondition
        // observable rather than assumed.
        //
        // LANE-1 (v2): the `poolBalance == 0` limb was DROPPED, because the layer-1 split above
        // now models a funded pool exactly as the production allocator does. Dropping it cannot
        // change any v1 value — the limb was true in all eleven v1 scenarios, so the flag was
        // already 1 everywhere.
        bool applicable = defaultManager.pastDuePrincipal(FILM) == 0;
        _blastBool(s, "ORACLE", "modelApplicable", applicable);
        if (!applicable) return;

        m.creditedDrawn = m.drawnResidual < m.pooledClamped ? m.drawnResidual : m.pooledClamped;
        {
            // The PREDICTED fix bounds the drawn cohort by the per-event executable aggregate AND
            // refuses to count as layer-2 room the principal layer 1 has already absorbed. With an
            // empty pool the second limb is the identity, so `predictedPostFixImpairment` is
            // unchanged on every v1 scenario.
            uint256 honestCap =
                m.honestClamped > m.curatorAppliedToDrawn ? m.honestClamped - m.curatorAppliedToDrawn : 0;
            m.honestDrawn = m.drawnResidual < honestCap ? m.drawnResidual : honestCap;
        }
        m.fresh = m.capacity < m.reserve ? m.capacity : m.reserve;
        {
            uint256 leftNow = m.fresh > m.creditedDrawn ? m.fresh - m.creditedDrawn : 0;
            uint256 leftFix = m.fresh > m.honestDrawn ? m.fresh - m.honestDrawn : 0;
            uint256 total = m.drawnResidual + m.undrawnResidual;
            m.modelNow = total - m.creditedDrawn - (m.undrawnResidual < leftNow ? m.undrawnResidual : leftNow);
            m.modelFix = total - m.honestDrawn - (m.undrawnResidual < leftFix ? m.undrawnResidual : leftFix);
        }

        _blast(s, "ORACLE", "modelCurrentImpairment", m.modelNow);
        _blast(s, "ORACLE", "predictedPostFixImpairment", m.modelFix);
        _blast(s, "ORACLE", "creditedDrawnCoverage", m.creditedDrawn);
        _blast(s, "ORACLE", "overCreditVsDeliverable", m.creditedDrawn > fwd ? m.creditedDrawn - fwd : 0);
        _blast(s, "ORACLE", "expectedImpairmentDelta", m.modelFix > m.modelNow ? m.modelFix - m.modelNow : 0);

        // THE SELF-CHECK. `modelCurrentImpairment` is an independent re-derivation of the SHIPPED
        // clamp; it must reproduce the live mark exactly on this tree. Emitted as a FLAG rather
        // than asserted here so a semantic change to the clamp still produces a COMPLETE capture
        // to diff (an assertion would abort the sweep at this line and hide every consumer below
        // it). `F1BlastRadiusGateTest.test_model_*` turns the same check red/green.
        _blastBool(s, "ORACLE", "modelMatchesLive", m.modelNow == defaultManager.pendingSeniorImpairment());
    }

    // ── the whole sweep for one scenario ─────────────────────────────────

    function _captureAll(string memory s) internal {
        _captureBook(s);
        _captureAssessed(s);
        _captureVault(s);
        _captureOracle(s);
        _captureQueue(s);
        _captureWaterfall(s);
        _captureController(s);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  SCENARIOS
    // ══════════════════════════════════════════════════════════════════════

    /// @dev THE F1 TRIGGER. A tiny facility draws FIRST, snapshotting a per-event ceiling against
    ///      the largest reserve the deployment ever holds — but against almost no principal of
    ///      its own. A large facility draws SECOND. The pooled sum of the two rooms exceeds what
    ///      either can deliver, and the NAV credits the difference.
    function _sAsymmetric() internal {
        _openLimits();
        _stakeVault(alice, 900_000e18);
        _fundBackstop(400_000e18);
        uint256 a = _defaulted(BORROWER_1, 25_000e18);
        _realize(a, 10_000e18);
        uint256 b = _defaulted(BORROWER_2, 400_000e18);
        _realize(b, 10_000e18);
    }

    /// @dev SAME TWO FACILITIES, OPPOSITE DECLARATION AND DRAW ORDER. The big facility draws
    ///      first. Order changes which ceiling is snapshotted against which principal, so this
    ///      distinguishes an order-independent fix from one that only repairs the observed case.
    function _sAsymmetricOrderBA() internal {
        _openLimits();
        _stakeVault(alice, 900_000e18);
        _fundBackstop(400_000e18);
        uint256 b = _defaulted(BORROWER_2, 400_000e18);
        _realize(b, 10_000e18);
        uint256 a = _defaulted(BORROWER_1, 25_000e18);
        _realize(a, 10_000e18);
    }

    /// @dev CONTROL — a SYMMETRIC two-event cohort. Every event's remaining principal dominates
    ///      its own room, so `SUM min(p_i, r_i) == min(SUM p_i, SUM r_i)` and the buggy and the
    ///      correct clamp agree exactly. NOTHING HERE MAY MOVE WHEN THE FIX LANDS.
    function _sSymmetric2() internal {
        _openLimits();
        _stakeVault(alice, 500_000e18);
        _fundBackstop(400_000e18);
        uint256 a = _defaulted(BORROWER_1, 400_000e18);
        _realize(a, 10_000e18);
        uint256 b = _defaulted(BORROWER_2, 400_000e18);
        _realize(b, 10_000e18);
    }

    /// @dev CONTROL — the adjudicator's three-event symmetric cohort. Same rule, more events.
    function _sSymmetric3() internal {
        _openLimits();
        _stakeVault(alice, 900_000e18);
        _fundBackstop(400_000e18);
        uint256 a = _defaulted(BORROWER_1, 400_000e18);
        _realize(a, 10_000e18);
        uint256 b = _defaulted(BORROWER_2, 400_000e18);
        _realize(b, 10_000e18);
        uint256 c = _defaulted(keccak256("borrower-3"), 400_000e18);
        _realize(c, 10_000e18);
    }

    /// @dev THE BRANCH-CROSSING CASE. Sized so the POOLED credit swallows the entire drawn
    ///      residual and the reported impairment is EXACTLY ZERO today, while the honest
    ///      per-event aggregate does not. Post-fix the mark crosses 0 -> non-zero, which crosses
    ///      three separate `== 0` branches nothing else in this file reaches:
    ///        `WaterfallEngine._withholdFeeForSeniorImpairment`'s `residual == 0` early return;
    ///        `AssessedImpairmentSource.setAssessment`'s ceiling at a zero base;
    ///        `sUSDfr.redemptionTotalAssets`'s `impairment >= assets` clamp side.
    function _sZeroCross() internal {
        _openLimits();
        _stakeVault(alice, 900_000e18);
        _fundBackstop(400_000e18);
        uint256 a = _defaulted(BORROWER_1, 25_000e18);
        _realize(a, 10_000e18);
        uint256 b = _defaulted(BORROWER_2, 200_000e18);
        _realize(b, 10_000e18);
    }

    /// @dev MIXED COHORT — the asymmetric DRAWN pair plus a declared default that has NEVER drawn.
    ///      ADR-0035 makes both limbs claims on the same live reserve; the scenario proves that
    ///      drawn/undrawn classification cannot manufacture or strand layer-2 capacity.
    function _sPartialDrawn() internal {
        _openLimits();
        _stakeVault(alice, 900_000e18);
        _fundBackstop(400_000e18);
        uint256 a = _defaulted(BORROWER_1, 25_000e18);
        _realize(a, 10_000e18);
        uint256 b = _defaulted(BORROWER_2, 400_000e18);
        _realize(b, 10_000e18);
        _defaulted(keccak256("borrower-undrawn"), 100_000e18); // declared, never realized
    }

    /// @dev FOUR CONCURRENT LIVE EVENTS, sized so the honest per-event aggregate stays BELOW the
    ///      shared reserve while the pooled sum of rooms runs far above it. Three tiny facilities
    ///      each snapshot a full-size ceiling against almost no principal; the fourth carries the
    ///      book. This is the realistic multi-workout shape of the F1 defect and it is also a
    ///      SECOND zero-crossing (the mark is exactly 0 today).
    function _sConcurrent4() internal {
        _openLimits();
        _stakeVault(alice, 900_000e18);
        _fundBackstop(400_000e18);
        uint256 a = _defaulted(BORROWER_1, 10_000e18);
        _realize(a, 5_000e18);
        uint256 b = _defaulted(BORROWER_2, 10_000e18);
        _realize(b, 5_000e18);
        uint256 c = _defaulted(keccak256("borrower-3"), 10_000e18);
        _realize(c, 5_000e18);
        uint256 d = _defaulted(keccak256("borrower-4"), 305_000e18);
        _realize(d, 5_000e18);
    }

    /// @dev CONTROL — AN EVENT DRIVEN EXACTLY TO ITS PER-EVENT CAP WHILE STILL CARRYING PRINCIPAL.
    ///      Facility A's committed room is consumed to ZERO but 70,000e18 of its principal remains,
    ///      so it contributes principal and no room. `min(p, r) == 0 == its share of SUM r`, so the
    ///      pooled and per-event aggregates coincide and nothing may move.
    function _sAtEventCap() internal {
        _openLimits();
        _stakeVault(alice, 900_000e18);
        _fundBackstop(100_000e18);
        // cap = 50% of 100,000 = 50,000, against a 120,000 facility: drawn TO the cap, room 0,
        // 70,000 of principal still outstanding.
        uint256 a = _defaulted(BORROWER_1, 120_000e18);
        _realize(a, 50_000e18);
        uint256 b = _defaulted(BORROWER_2, 200_000e18);
        _realize(b, 10_000e18);
    }

    /// @dev A RESERVE SMALLER THAN A SINGLE COMMITTED ROOM. The `min(.., coverageReserve())` limb
    ///      of the clamp is the binding one here rather than the pooled sum.
    function _sSmallReserve() internal {
        _openLimits();
        _stakeVault(alice, 900_000e18);
        _fundBackstop(40_000e18);
        uint256 a = _defaulted(BORROWER_1, 25_000e18);
        _realize(a, 5_000e18);
        uint256 b = _defaulted(BORROWER_2, 400_000e18);
        _realize(b, 5_000e18);
    }

    /// @dev NO BACKSTOP CAPITAL AT ALL. Layer 2 cannot deliver anything, so no clamp shape can
    ///      change the answer. A post-fix move here would mean the fix touched something other
    ///      than the coverage credit.
    function _sZeroReserve() internal {
        _openLimits();
        _stakeVault(alice, 900_000e18);
        _defaulted(BORROWER_1, 25_000e18);
        _defaulted(BORROWER_2, 400_000e18);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  LANE-1 (v2) — FUNDED LAYER 1. THE ONLY SCENARIOS IN THIS FILE THAT
    //  EXERCISE THE CURATOR POOL AT ALL.
    // ══════════════════════════════════════════════════════════════════════

    /// @dev THE FUNDED-LAYER-1 TRIGGER — the HIGH, and the reason v2 exists.
    ///
    ///      WHY V1 COULD NOT SEE THIS. Every v1 scenario runs with `CURATOR poolBalance 0`, so the
    ///      per-class layer-1 allocation in `ConservativeImpairmentMath` is the identity in all
    ///      eleven. An ablation that removed the entire curator repair from the fixed tree
    ///      reproduced the 1,101-value v1 capture BYTE-IDENTICALLY: the repair is a total no-op
    ///      against v1, in BOTH directions, so v1 grades it neither right nor wrong.
    ///
    ///      THE MECHANISM. The curator pool is shared PER CLASS; coverage room is committed PER
    ///      EVENT. The drawn residual the mark nets coverage against is taken NET of the pool,
    ///      while the layer-2 aggregate sums room against GROSS per-event principal. So when the
    ///      pool absorbs the principal of the event whose committed room OUTLIVES that principal,
    ///      the room survives in the aggregate and can never be drawn — it has no principal left
    ///      to be drawn against.
    ///
    ///      THE SHAPE. `_sAsymmetric` leaves facility A with 15,000e18 of principal behind a
    ///      190,000e18 committed room, and facility B with 390,000e18 behind 185,000e18. A
    ///      15,000e18 pool is EXACTLY A's remaining principal. If the cascade sends the pool at A
    ///      (which the forward realization order does), A is extinguished by layer 1 and its
    ///      190,000e18 room delivers nothing.
    ///
    ///      THE FIRST-LOSS IS POSTED **AFTER** BOTH REALIZATIONS, DELIBERATELY. `realizeLoss`
    ///      consults `curator.absorbLoss` BEFORE the backstop, so a pool funded first would have
    ///      eaten the 20,000e18 of construction losses and no per-event ceiling would have been
    ///      snapshotted at all. Posting afterwards leaves the cohort bit-identical to `asymmetric`
    ///      — same ids, same principals, same rooms, same reserve — so the ONLY difference between
    ///      the two captures is layer 1. `postFirstLoss` carries no freeze gate (freezing bars
    ///      WITHDRAWAL, not posting), so this is an ordinary curator action, not privilege abuse.
    function _sFundedAsymmetric() internal {
        _sAsymmetric();
        _postFirstLoss(anchorCurator, FILM, FUNDED_FIRST_LOSS);
    }

    /// @dev THE FUNDED-POOL **CONTROL**, and the reason the trigger above means anything.
    ///
    ///      A funded pool always moves the mark — layer 1 is real capital and absorbs first. The
    ///      question a reader has to be able to answer is whether the pool BIT: whether funding it
    ///      stranded layer-2 room. Here it does not. Both events carry 390,000e18 of principal
    ///      behind rooms of 190,000e18 and 185,000e18, so whichever event the pool is sent at
    ///      still has principal left over to draw its whole room against. Layer-2 delivery is
    ///      IDENTICAL to `symmetric2`'s and the junior credit stays exactly equal to what the
    ///      cascade delivers, in BOTH realization orders.
    ///
    ///      This is what separates "the pool is funded" from "the pool bites". A tree that moves
    ///      this cohort has not fixed the HIGH — it has repriced a state in which no room was ever
    ///      stranded, and the difference is taken from the exiting holder.
    function _sFundedSymmetric() internal {
        _sSymmetric2();
        _postFirstLoss(anchorCurator, FILM, FUNDED_FIRST_LOSS);
    }

    /// @dev THE TERMINAL-RELEASE BOUNDARY. One event is realized to EXHAUSTION, which releases
    ///      its commitment from `liveDefaultCoverageRemaining` entirely; a second live event
    ///      remains. This is the transition at which a per-event ledger has to retire a row, and
    ///      is where a fix that forgets to release will show up.
    function _sTerminalRelease() internal {
        _openLimits();
        _stakeVault(alice, 900_000e18);
        _fundBackstop(400_000e18);
        uint256 a = _defaulted(BORROWER_1, 25_000e18);
        _realize(a, 25_000e18); // fully realized -> contribution 0 -> commitment released
        uint256 b = _defaulted(BORROWER_2, 400_000e18);
        _realize(b, 10_000e18);
    }
}

/// @notice THE MEASUREMENT PASS. Every test here is a pure capture: it builds one scenario and
///         emits the whole consumer sweep. The only assertions are fixture sanity and the
///         reference-model self-check, so a baseline run is GREEN and its stdout is the artifact.
contract F1BlastRadiusHarnessTest is F1BlastRadiusBase {
    function test_blast_asymmetric() public {
        _sAsymmetric();
        _captureAll("asymmetric");
    }

    function test_blast_asymmetricOrderBA() public {
        _sAsymmetricOrderBA();
        _captureAll("asymmetricOrderBA");
    }

    function test_blast_symmetric2() public {
        _sSymmetric2();
        _captureAll("symmetric2");
    }

    function test_blast_symmetric3() public {
        _sSymmetric3();
        _captureAll("symmetric3");
    }

    function test_blast_zerocross() public {
        _sZeroCross();
        _captureAll("zerocross");
    }

    function test_blast_partialdrawn() public {
        _sPartialDrawn();
        _captureAll("partialdrawn");
    }

    function test_blast_concurrent4() public {
        _sConcurrent4();
        _captureAll("concurrent4");
    }

    function test_blast_ateventcap() public {
        _sAtEventCap();
        _captureAll("ateventcap");
    }

    function test_blast_smallreserve() public {
        _sSmallReserve();
        _captureAll("smallreserve");
    }

    function test_blast_zeroreserve() public {
        _sZeroReserve();
        _captureAll("zeroreserve");
    }

    function test_blast_terminalrelease() public {
        _sTerminalRelease();
        _captureAll("terminalrelease");
    }

    // ── LANE-1 (v2): the only two scenarios with a FUNDED layer 1 ────────

    function test_blast_fundedasym() public {
        _sFundedAsymmetric();
        _captureAll("fundedasym");
    }

    function test_blast_fundedcontrol() public {
        _sFundedSymmetric();
        _captureAll("fundedcontrol");
    }
}

/// @notice THE DIFFERENTIAL GATE. The measurement pass produces a diff; this contract turns the
///         two things that MATTER about that diff into red/green.
///
///         `test_control_*` pins the symmetric and degenerate cohorts to baseline LITERALS. They
///         are GREEN on the candidate tree and MUST STAY GREEN once the fix lands — a fix that
///         moves a symmetric cohort has changed the price of a state F1 never touched.
///
///         `test_trigger_*` asserts the F1 PROPERTY itself (credited coverage must not exceed
///         what layer 2 will actually deliver, and an early exit must not be paid above the
///         post-realization price). These are the acceptance criteria: RED today, and the fix is
///         only complete when they are green.
contract F1BlastRadiusGateTest is F1BlastRadiusBase {
    /// @dev THE MEASURE, stated once. `performanceFeeImpairment()` is the GROSS declared +
    ///      past-due principal — it reads no backstop and no clamp — so
    ///      `gross - pendingSeniorImpairment()` is exactly the junior credit the conservative NAV
    ///      hands the senior tranche. With an EMPTY curator pool (every fixture here posts no
    ///      first-loss; `test_fixture_layerOneIsEmptyInEveryScenario` pins that) all of it is
    ///      LAYER 2, which is the quantity F1 inflates. Stated this way it is valid for a mixed
    ///      drawn/undrawn cohort as well as a pure drawn one.
    function _juniorCreditGranted() internal view returns (uint256) {
        return defaultManager.performanceFeeImpairment() - defaultManager.pendingSeniorImpairment();
    }

    /// @dev The MOST layer 2 will hand over under any realization order this harness can drive.
    ///      Taking the MAXIMUM makes every `assertLe` below strictly harder to trip, so a red is
    ///      never an artefact of picking an unlucky greedy order.
    function _maxDeliverable() internal returns (uint256) {
        uint256 fwd = _deliverable(true);
        uint256 rev = _deliverable(false);
        return fwd > rev ? fwd : rev;
    }

    /// @dev The mirror of `_maxDeliverable`, and the reason it exists: ADVERSARY FINDING D1.
    ///      Every `test_trigger_*` originally asserted only `credited <= maxDeliverable`, which is
    ///      ONE-SIDED. Over-crediting under-marks the NAV and overpays an EXITING holder (that is
    ///      F1). UNDER-crediting over-marks it and overpays the STAYERS — the mirror defect, and an
    ///      over-correcting fix passed every trigger and every control: forcing the drawn-cohort
    ///      credit to zero on `asymmetric` produced a 200,000e18 OVER-mark, under-pricing the senior
    ///      exit by 200,000e18, while the whole gate stayed green.
    ///      A defensible credit lies between what the cascade delivers in its WORST realization
    ///      order and its BEST. Below the worst is an over-mark; above the best is an under-mark.
    function _minDeliverable() internal returns (uint256) {
        uint256 fwd = _deliverable(true);
        uint256 rev = _deliverable(false);
        return fwd < rev ? fwd : rev;
    }

    /// @dev LANE-1 (v2). The same two bounds taken over BOTH junior layers. `_juniorCreditGranted`
    ///      is `grossDeclared - pendingSeniorImpairment`, which nets layer 1 as well as layer 2, so
    ///      once the pool is funded the layer-2-only bounds above are no longer the right
    ///      comparison — they would be measuring the mark against a strict subset of what it nets.
    ///      With an empty pool these are numerically identical to the two above (`layerOne == 0`),
    ///      which is why the v1 triggers are left exactly as they were.
    function _maxDeliverableJunior() internal returns (uint256) {
        (uint256 fwd,,) = _deliverableJunior(true);
        (uint256 rev,,) = _deliverableJunior(false);
        return fwd > rev ? fwd : rev;
    }

    /// @dev THE CONSERVATIVE BOUND, and the one the funded trigger turns on.
    ///
    ///      A conservative NAV may not assume the FAVOURABLE realization order. `_maxDeliverable`
    ///      is deliberately generous — it exists so a v1 trigger red can never be an artefact of an
    ///      unlucky greedy order — but that generosity is exactly what a shared per-class pool
    ///      exploits: sending the pool at the small facility strands its room, sending it at the
    ///      large one does not, and the two orders differ by the whole defect. Bounding by the
    ///      MAXIMUM therefore CANNOT see this HIGH, and that is measured, not asserted:
    ///      `test_trigger_fundedLayerOneCreditIsDeliverable` carries the max bound too and it is
    ///      GREEN on the defective tree while the worst-order bound is RED.
    ///
    ///      Forward and reverse ENUMERATE the FULL-REALIZATION orders for a two-event cohort, so on
    ///      `fundedasym` and `fundedcontrol` this is the exact minimum over that family. Partial
    ///      interleavings are not swept — see `_captureExecuted`.
    function _minDeliverableJunior() internal returns (uint256) {
        (uint256 fwd,,) = _deliverableJunior(true);
        (uint256 rev,,) = _deliverableJunior(false);
        return fwd < rev ? fwd : rev;
    }

    /// @dev Dust tolerance for the two-sided exit-price bound. Eleven orders of magnitude below the
    ///      ~1e23 discrepancies this harness exists to detect, so it cannot mask a real defect; it
    ///      only absorbs per-event integer division in `Σ min(p_i, r_i)`.
    uint256 internal constant EXIT_DUST = 1e12;

    // ── fixture sanity: the measure above is only layer 2 if layer 1 is empty ──

    /// @dev ADVERSARY FINDING D2(b): this was named `...InEveryScenario` but drives only the
    ///      asymmetric cohort. Renamed rather than widened — the per-scenario `CURATOR poolBalance`
    ///      lines in the capture already cover the rest, so the substance was fine and only the
    ///      name overstated it.
    function test_fixture_layerOneIsEmptyOnTheAsymmetricCohort() public {
        _sAsymmetric();
        assertEq(curator.poolBalance(FILM), 0, "asymmetric: layer 1 must be empty");
        assertEq(defaultManager.pastDuePrincipal(FILM), 0, "asymmetric: no unattested cohort");
        assertEq(address(defaultManager.backstop()), address(sGrove), "the REAL SGrove must be the backstop");
    }

    /// @dev LANE-1 (v2) FIXTURE SANITY — THE PRECONDITION THE WHOLE LANE RESTS ON.
    ///
    ///      Asserts that the two funded scenarios really do fund layer 1 (the v1 suite's defect was
    ///      precisely that they all pinned `poolBalance == 0`), that the funded cohort is otherwise
    ///      BIT-IDENTICAL to `asymmetric` — same declared principal, same drawn principal, same
    ///      committed rooms, same reserve — and that the pool is the real `CuratorModule` against
    ///      the real `SGrove`. If any of these drift, the trigger below stops being a measurement
    ///      of layer 1 and becomes a measurement of a different cohort.
    function test_fixture_layerOneIsFundedAndTheCohortIsOtherwiseUnchanged() public {
        _sAsymmetric();
        uint256 declaredBefore = defaultManager.declaredDefaultedPrincipal(FILM);
        uint256 drawnBefore = defaultManager.drawnDefaultPrincipal(FILM);
        uint256 reserveBefore = sGrove.coverageReserve();
        uint256 roomABefore = _roomAt(evIds[0]);
        uint256 roomBBefore = _roomAt(evIds[1]);
        assertEq(curator.poolBalance(FILM), 0, "asymmetric: layer 1 must be empty");

        _postFirstLoss(anchorCurator, FILM, FUNDED_FIRST_LOSS);

        assertEq(curator.poolBalance(FILM), FUNDED_FIRST_LOSS, "fundedasym: layer 1 must be FUNDED");
        assertEq(defaultManager.declaredDefaultedPrincipal(FILM), declaredBefore, "fundedasym: declared moved");
        assertEq(defaultManager.drawnDefaultPrincipal(FILM), drawnBefore, "fundedasym: drawn moved");
        assertEq(sGrove.coverageReserve(), reserveBefore, "fundedasym: reserve moved");
        assertEq(_roomAt(evIds[0]), roomABefore, "fundedasym: event A room moved");
        assertEq(_roomAt(evIds[1]), roomBBefore, "fundedasym: event B room moved");
        // The pool is EXACTLY the small facility's remaining principal — that identity is what
        // lets layer 1 extinguish the event whose room outlives it.
        assertEq(
            defaultManager.defaultedContribution(evIds[0]),
            FUNDED_FIRST_LOSS,
            "fundedasym: the pool must equal event A's residual principal"
        );
        assertGt(roomABefore, FUNDED_FIRST_LOSS, "fundedasym: event A's room must OUTLIVE its principal");
        assertEq(address(defaultManager.backstop()), address(sGrove), "the REAL SGrove must be the backstop");
    }

    /// @dev THE REFERENCE-MODEL SELF-CHECK, as red/green. `_captureOracle`'s
    ///      `modelCurrentImpairment` is an independent re-derivation of the SHIPPED clamp from
    ///      SGrove's own per-event ceilings. If it stops reproducing the live mark, the clamp's
    ///      semantics changed and every `predictedPostFixImpairment` line in the baseline is
    ///      stale — which is exactly what the fix landing looks like, so this test is EXPECTED to
    ///      go red on the fixed tree and its message is where the reader is told to re-derive.
    function _assertModelReproducesLive(string memory scenario) internal view {
        uint256 drawn = defaultManager.drawnDefaultPrincipal(FILM);
        uint256 declared = defaultManager.declaredDefaultedPrincipal(FILM);
        uint256 undrawn = declared >= drawn ? declared - drawn : 0;
        // LANE-1 (v2) — the per-class layer-1 split, undrawn first, exactly as the production
        // allocator orders it. Identity when the pool is empty, so every v1 model test is
        // unaffected; without it this re-derivation cannot be pointed at a funded cohort at all.
        {
            uint256 pool = curator.poolBalance(FILM);
            uint256 forUndrawn = pool < undrawn ? pool : undrawn;
            undrawn -= forUndrawn;
            uint256 poolLeft = pool - forUndrawn;
            drawn -= poolLeft < drawn ? poolLeft : drawn;
        }
        uint256 reserve = sGrove.coverageReserve();
        uint256 pooled = defaultManager.liveDefaultCoverageRemaining();
        uint256 pooledClamped = pooled < reserve ? pooled : reserve;
        uint256 creditedDrawn = drawn < pooledClamped ? drawn : pooledClamped;
        uint256 capacity = sGrove.coverageCapacity();
        uint256 fresh = capacity < reserve ? capacity : reserve;
        uint256 left = fresh > creditedDrawn ? fresh - creditedDrawn : 0;
        uint256 model = drawn + undrawn - creditedDrawn - (undrawn < left ? undrawn : left);
        assertEq(
            model,
            defaultManager.pendingSeniorImpairment(),
            string.concat("the shipped-clamp reference model no longer reproduces the live mark: ", scenario)
        );
    }

    function test_model_reproducesTheLiveMarkOnTheAsymmetricCohort() public {
        _sAsymmetric();
        _assertModelReproducesLive("asymmetric");
    }

    function test_model_reproducesTheLiveMarkOnTheSymmetricControl() public {
        _sSymmetric2();
        _assertModelReproducesLive("symmetric2");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  CORRECTION 2026-08-10 (audit stream) — THE TWO STALE REFERENCE CHECKS
    //
    //  The two tests below USED to call `_assertModelReproducesLive`, i.e. the closed-form
    //  transcription of the SHIPPED clamp. On `partialdrawn` and `fundedasym` that transcription
    //  is no longer a reference for anything, and BOTH of its answers are provably wrong in the
    //  OVER-MARK direction. They are replaced by a derivation off the EXECUTED cascade.
    //
    //    OLD (transcribed clamp)                NEW (derived from the executed oracle)
    //    `fundedasym`   190,000e18              205,000e18  = 405,000e18 gross − 200,000e18 worst
    //    `partialdrawn` 305,000e18              [205,000e18, 215,000e18] band; 215,000e18 at the
    //                                          conservative edge = 505,000e18 − 290,000e18 worst
    //
    //  WHY EACH WENT STALE — they are two different failures, not one:
    //    * `fundedasym`'s 190,000e18 is **W1's own mark**. The transcription nets the 15,000e18
    //      curator pool off drawn principal AND separately credits the whole 200,000e18 layer-2
    //      ladder, so it grants 215,000e18 of junior credit against a 405,000e18 gross. The
    //      cascade delivers 200,000e18 in its worst order. The W6 curator repair moved the credit
    //      215,000e18 → 200,000e18 and the model was never moved with it. The model therefore
    //      encodes the very 15,000e18 double-count the HIGH's fix removed.
    //    * `partialdrawn`'s 305,000e18 comes from a DRAWN-LIMB-ONLY model. Its undrawn limb is
    //      `min(undrawnResidual, freshCapacity − creditedDrawn)`, which is 0 here, so it credits
    //      the 100,000e18 undrawn default NOTHING — while the cascade actually delivers 90,000e18
    //      against it (forward) or 100,000e18 (reverse). It under-credits by 90,000e18, i.e.
    //      OVER-marks by 90,000e18. `INPUT1_ACCEPTANCE_BAR_2026-08-10.md` withdrew this target
    //      outright; the harness was never updated to match.
    //
    //  WHY THE NEW NUMBERS ARE NOT FITTED TO THE CANDIDATE. Every figure pinned below is measured
    //  by `_deliverableJunior`, which drives `realizeLoss` to exhaustion in a snapshot and reads
    //  BALANCE DELTAS out of `SGrove` and the `CuratorModule`. Neither limb of that path consults
    //  `pendingSeniorImpairment` — layer 1 is `min(loss, pool.balance)`, layer 2 is
    //  `SGrove.coverShortfall` under its own snapshotted per-event ceiling. Measured, not asserted:
    //  ALL 91 executed-oracle lines (13 scenarios × 7 quantities) are BYTE-IDENTICAL across PREV,
    //  W1, W6 and W7, four trees whose `DM pendingSeniorImpairment` disagrees on 12–14 of them.
    //  **A number that is identical on the tree this gate must RED cannot have been fitted to the
    //  tree it must GREEN.**
    //
    //  WHAT WAS LOST, STATED PLAINLY. These two tests change CLASS: from a TRIPWIRE (green on the
    //  pre-fix tree by construction, red the moment clamp semantics move) to a CRITERION (red on
    //  any tree whose credit is not deliverable). That is unavoidable — no "reproduces the shipped
    //  clamp" check can be green on both PREV and a fixed tree when the two clamps disagree on
    //  these cohorts by construction. The consequence is that they now assert the same property
    //  the corresponding `test_trigger_*` already asserts, so they are a SECOND STATEMENT of it
    //  rather than an independent second derivation. The independent second derivation for these
    //  two cohorts — a per-event ladder reference model in the harness — is open work, not done
    //  here. The other three `test_model_*` scenarios are UNTOUCHED and keep their tripwire role.
    //
    //  NOT TOUCHED BY THIS CORRECTION: `ORACLE predictedPostFixImpairment` is still the old closed
    //  form and still emits 305,000e18 for `partialdrawn`. It is left alone deliberately — editing
    //  it would move the 1,416-value baseline, and CODEX_W7 §1 proves no closed form on those
    //  reads can be right. **Read `ORACLE juniorDeliverableWorstOrder`, not
    //  `predictedPostFixImpairment`, on the mixed and funded cohorts.**
    // ══════════════════════════════════════════════════════════════════════

    /// @dev THE MIXED DRAWN/UNDRAWN COHORT, DERIVED. `partialdrawn` carries 505,000e18 of residual
    ///      principal against 380,000e18 of shared live reserve and no curator pool. ADR-0035 makes
    ///      both exhaustive orders drain the same 380,000e18. The two-sided bound remains: it now
    ///      collapses to a point because physical delivery is order-independent in this cohort.
    function test_model_reproducesTheLiveMarkOnTheMixedCohort() public {
        _sPartialDrawn();
        // (1) THE EXECUTED GROUND TRUTH, PINNED FIRST. Literals, so the message a reader is shown
        //     names WHICH cohort was measured before any relation is evaluated.
        (uint256 fwdTotal,,) = _deliverableJunior(true);
        (uint256 revTotal,,) = _deliverableJunior(false);
        assertEq(fwdTotal, 380_000e18, "partialdrawn: forward junior delivery moved");
        assertEq(revTotal, 380_000e18, "partialdrawn: reverse junior delivery moved");
        uint256 worst = fwdTotal < revTotal ? fwdTotal : revTotal;
        uint256 best = fwdTotal > revTotal ? fwdTotal : revTotal;
        // (2) THE GROSS. `performanceFeeImpairment` is Σ(declared + pastDue) — it reads no
        //     backstop, no curator pool and no clamp, so it cannot be wrong in the same direction
        //     as the code under test.
        uint256 gross = defaultManager.performanceFeeImpairment();
        assertEq(gross, 505_000e18, "partialdrawn: the gross cohort moved");
        // (3) THE DERIVED CRITERION. Junior credit inside the executed band; the mark is its
        //     complement. Below the worst order is an over-mark paid by the exiter (D1); above the
        //     best order is an under-mark paid by the stayers (F1).
        uint256 credited = _juniorCreditGranted();
        assertGe(credited, worst, "D1 MIRROR: mixed cohort credits BELOW the worst executable order");
        assertLe(credited, best, "F1: mixed cohort credits ABOVE the best executable order");
        // RESTATED IN MARK TERMS, AND IT IS ONLY A RESTATEMENT — `_juniorCreditGranted()` is
        // `gross - pendingSeniorImpairment()`, so the two lines below are ALGEBRAICALLY IDENTICAL
        // to the two above and check nothing further. They are kept because the mark, not the
        // credit, is the number the five consumers read, so this is the failure message an
        // operator can act on. Stated as redundancy rather than implied to be a second check.
        assertLe(
            defaultManager.pendingSeniorImpairment(), gross - worst, "partialdrawn: the mark is above the executed band"
        );
        assertGe(
            defaultManager.pendingSeniorImpairment(), gross - best, "partialdrawn: the mark is below the executed band"
        );
    }

    /// @dev LANE-1 (v2), DERIVED. The funded trigger's criterion is a POINT, not a band, and that
    ///      is not a choice made here: `test_trigger_fundedLayerOneCreditIsDeliverable` already
    ///      pins `credited == minDeliverableJunior` two-sidedly, and criterion 1 of the acceptance
    ///      bar grades against it. This test states the same specification as a MARK rather than as
    ///      a credit, because the mark is the number the five consumers actually read.
    ///
    ///      Forward and reverse ENUMERATE the full-realization orders for this two-event cohort, so
    ///      `worst` is the exact minimum over that family, not a sample of it. Partial interleavings
    ///      are not swept — see `_captureExecuted`.
    function test_model_reproducesTheLiveMarkOnTheFundedTrigger() public {
        _sFundedAsymmetric();
        // (1) THE EXECUTED GROUND TRUTH, PINNED FIRST. Layer 1 absorbs 15,000e18 and the remaining
        //     live cohort can exhaust all 380,000e18 of shared layer-2 reserve in either order.
        (uint256 fwdTotal,,) = _deliverableJunior(true);
        (uint256 revTotal,,) = _deliverableJunior(false);
        assertEq(fwdTotal, 395_000e18, "fundedasym: forward junior delivery moved");
        assertEq(revTotal, 395_000e18, "fundedasym: reverse junior delivery moved");
        uint256 worst = fwdTotal < revTotal ? fwdTotal : revTotal;
        uint256 gross = defaultManager.performanceFeeImpairment();
        assertEq(gross, 405_000e18, "fundedasym: the gross cohort moved");
        // (2) THE DERIVED CRITERION. gross − worst-order junior delivery. Nothing on the
        //     right-hand side is read off the implementation being graded.
        assertEq(
            _juniorCreditGranted(), worst, "fundedasym: junior credit must equal the WORST executable junior delivery"
        );
        // RESTATED IN MARK TERMS, AND IT IS ONLY A RESTATEMENT — `_juniorCreditGranted()` is
        // `gross - pendingSeniorImpairment()`, so this line is ALGEBRAICALLY IDENTICAL to the one
        // above and checks nothing further. Kept because the mark is what the five consumers read.
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            gross - worst,
            "fundedasym: the mark must be the gross net of the worst executable junior delivery"
        );
    }

    function test_model_reproducesTheLiveMarkOnTheFundedControl() public {
        _sFundedSymmetric();
        _assertModelReproducesLive("fundedcontrol");
    }

    // ── controls: pinned baseline literals that MUST NOT move ────────────

    function test_control_symmetric2IsExactAndPinned() public {
        _sSymmetric2();
        assertEq(defaultManager.pendingSeniorImpairment(), 400_000e18, "symmetric2 mark moved");
        assertEq(vault.redemptionTotalAssets(), 100_000e18, "symmetric2 exit NAV moved");
        uint256 credited = _juniorCreditGranted();
        assertEq(credited, 380_000e18, "symmetric2 credit moved");
        assertEq(credited, _deliverable(true), "symmetric2: credited must equal delivered");
    }

    function test_control_symmetric3IsExactAndPinned() public {
        _sSymmetric3();
        assertEq(defaultManager.pendingSeniorImpairment(), 800_000e18, "symmetric3 mark moved");
        assertEq(vault.redemptionTotalAssets(), 100_000e18, "symmetric3 exit NAV moved");
        uint256 credited = _juniorCreditGranted();
        assertEq(credited, 370_000e18, "symmetric3 credit moved");
        assertEq(credited, _deliverable(true), "symmetric3: credited must equal delivered");
    }

    function test_control_zeroReserveIsPinned() public {
        _sZeroReserve();
        assertEq(sGrove.coverageReserve(), 0, "zeroreserve: fixture must have no backstop capital");
        assertEq(defaultManager.pendingSeniorImpairment(), 425_000e18, "zeroreserve mark moved");
        assertEq(vault.redemptionTotalAssets(), 475_000e18, "zeroreserve exit NAV moved");
        assertEq(_juniorCreditGranted(), 0, "zeroreserve: no credit is available to grant");
        assertEq(_deliverable(true), 0, "zeroreserve: layer 2 can deliver nothing");
    }

    function test_control_smallReserveIsPinned() public {
        _sSmallReserve();
        assertEq(defaultManager.pendingSeniorImpairment(), 385_000e18, "smallreserve mark moved");
        assertEq(vault.redemptionTotalAssets(), 515_000e18, "smallreserve exit NAV moved");
        uint256 credited = _juniorCreditGranted();
        assertEq(credited, 30_000e18, "smallreserve credit moved");
        assertEq(credited, _deliverable(true), "smallreserve: credited must equal delivered");
    }

    function test_control_terminalReleaseIsPinned() public {
        _sTerminalRelease();
        assertEq(defaultManager.defaultedContribution(evIds[0]), 0, "terminalrelease: event A must be retired");
        assertEq(defaultManager.pendingSeniorImpairment(), 25_000e18, "terminalrelease mark moved");
        assertEq(vault.redemptionTotalAssets(), 875_000e18, "terminalrelease exit NAV moved");
        uint256 credited = _juniorCreditGranted();
        assertEq(credited, 365_000e18, "terminalrelease credit moved");
        assertEq(credited, _deliverable(true), "terminalrelease: credited must equal delivered");
    }

    function test_control_atEventCapIsPinned() public {
        _sAtEventCap();
        assertEq(_roomAt(evIds[0]), 40_000e18, "ateventcap: event A must expose the shared live reserve");
        assertGt(defaultManager.defaultedContribution(evIds[0]), 0, "ateventcap: and must still carry principal");
        assertEq(defaultManager.pendingSeniorImpairment(), 220_000e18, "ateventcap mark moved");
        assertEq(vault.redemptionTotalAssets(), 680_000e18, "ateventcap exit NAV moved");
        uint256 credited = _juniorCreditGranted();
        assertEq(credited, 40_000e18, "ateventcap credit moved");
        assertEq(credited, _deliverable(true), "ateventcap: credited must equal delivered");
    }

    // ── the F1 property: RED on this tree, GREEN is the fix's bar ────────

    function test_trigger_asymmetricCreditIsDeliverable() public {
        _sAsymmetric();
        uint256 credited = _juniorCreditGranted();
        assertLe(credited, _maxDeliverable(), "F1: the NAV credits coverage layer 2 will not deliver");
        assertGe(credited, _minDeliverable(), "D1 MIRROR: the NAV UNDER-credits, over-marking against the exiter");
    }

    function test_trigger_asymmetricOrderBACreditIsDeliverable() public {
        _sAsymmetricOrderBA();
        uint256 credited = _juniorCreditGranted();
        assertLe(credited, _maxDeliverable(), "F1: order-reversed cohort over-credits");
        assertGe(credited, _minDeliverable(), "D1 MIRROR: order-reversed cohort UNDER-credits");
    }

    function test_trigger_zeroCrossCreditIsDeliverable() public {
        _sZeroCross();
        uint256 credited = _juniorCreditGranted();
        assertLe(credited, _maxDeliverable(), "F1: zero-crossing cohort over-credits");
        assertGe(credited, _minDeliverable(), "D1 MIRROR: zero-crossing cohort UNDER-credits");
    }

    function test_trigger_concurrent4CreditIsDeliverable() public {
        _sConcurrent4();
        uint256 credited = _juniorCreditGranted();
        assertLe(credited, _maxDeliverable(), "F1: four-event cohort over-credits");
        assertGe(credited, _minDeliverable(), "D1 MIRROR: four-event cohort UNDER-credits");
    }

    function test_trigger_partialDrawnCreditIsDeliverable() public {
        _sPartialDrawn();
        uint256 credited = _juniorCreditGranted();
        assertLe(credited, _maxDeliverable(), "F1: mixed drawn/undrawn cohort over-credits");
        assertGe(credited, _minDeliverable(), "D1 MIRROR: mixed drawn/undrawn cohort UNDER-credits");
    }

    function test_trigger_asymmetricExitPriceIsNotAboveTheHonestOne() public {
        _sAsymmetric();
        uint256 shares = vault.balanceOf(alice);
        uint256 exitNow = vault.previewRedeem(shares);
        uint256 snap = vm.snapshotState();
        for (uint256 i = 0; i < evIds.length; ++i) {
            uint256 amount = reserves.deployedTo(evIds[i]);
            _attestLoss(evIds[i], amount, ORACLE_REF);
            vm.prank(servicer);
            defaultManager.realizeLoss(evIds[i], amount, ORACLE_REF);
        }
        uint256 exitAfter = vault.previewRedeem(shares);
        vm.revertToState(snap);
        assertLe(exitNow, exitAfter, "F1: the conservative NAV pays an exiting senior ABOVE the honest price");
        // ADVERSARY FINDING D1 — the mirror. Name kept stable because W1_REPORT and the codex briefs
        // cite it, but this test is now TWO-SIDED: an exit price BELOW the realized one transfers
        // value from the exiter to the stayers, which a one-sided bound cannot see.
        assertGe(
            exitNow + EXIT_DUST,
            exitAfter,
            "D1 MIRROR: the conservative NAV pays an exiting senior BELOW the honest price"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  LANE-1 (v2) — THE FUNDED-LAYER-1 GATE
    // ══════════════════════════════════════════════════════════════════════

    /// @dev THE TRIGGER FOR THE HIGH. Three bounds, deliberately, and they do NOT all discriminate:
    ///
    ///      (1) `credited <= maxDeliverableJunior` — the v1 bound, carried here unchanged so the
    ///          reader can SEE that it is green on the defective tree. Sending the shared pool at
    ///          the LARGE facility strands nothing, so the favourable order funds the whole credit
    ///          and a maximum-order bound is blind to this defect by construction.
    ///      (2) `credited >= minDeliverableJunior` — the D1 mirror, unchanged in meaning: a mark
    ///          below the worst reachable delivery is an over-mark paid for by the exiter.
    ///      (3) `credited <= minDeliverableJunior` — THE CONSERVATIVE BOUND, and the one that
    ///          catches the HIGH. The NAV may not credit coverage that only a favourable
    ///          realization order can fund.
    ///
    ///      (2) and (3) together pin `credited == minDeliverableJunior`, which is the correct
    ///      specification for a mark that must hold in every reachable world: no more than the
    ///      worst order can deliver, and no less either. Forward and reverse ENUMERATE the
    ///      full-realization orders for this two-event cohort, so the bound is exact over that
    ///      family and not a sample; partial interleavings are not swept (see `_captureExecuted`).
    function test_trigger_fundedLayerOneCreditIsDeliverable() public {
        _sFundedAsymmetric();
        uint256 credited = _juniorCreditGranted();
        assertLe(credited, _maxDeliverableJunior(), "F1: the NAV credits junior capital no order can deliver");
        assertGe(
            credited, _minDeliverableJunior(), "D1 MIRROR: funded cohort UNDER-credits, over-marking against the exiter"
        );
        assertLe(
            credited,
            _minDeliverableJunior(),
            "HIGH: the NAV credits junior capital the worst executable order cannot deliver"
        );
    }

    /// @dev THE FUNDED-POOL CONTROL. Same pool, same class, same amount. With no event-owned room,
    ///      layer 1 plus the shared live reserve must be fully credited and deliver identically in
    ///      both realization orders.
    ///
    ///      This is the discriminator between "the pool is funded" and "the pool bites". A tree
    ///      that moves this cohort has repriced a state the HIGH never touched, and the delta
    ///      comes out of the exiting holder.
    function test_control_fundedPoolThatDoesNotBiteIsPinned() public {
        _sFundedSymmetric();
        assertEq(curator.poolBalance(FILM), FUNDED_FIRST_LOSS, "fundedcontrol: layer 1 must be FUNDED");
        (uint256 fwdTotal, uint256 fwdLayerTwo,) = _deliverableJunior(true);
        (uint256 revTotal, uint256 revLayerTwo,) = _deliverableJunior(false);
        // PINNED LITERALS FIRST, RELATIONS AFTER — deliberately. An assertion failure aborts the
        // test, so the ORDER decides which statement a reader is shown. The literals are the
        // stronger claim (they say WHICH cohort was measured), so they go first; a mutant that
        // moves executed delivery then reports the moved figure rather than a downstream relation.
        //
        // Layer-2 delivery is the SAME as the unfunded `symmetric2` control's, which is the precise
        // statement that the pool stranded no room.
        assertEq(fwdLayerTwo, 380_000e18, "fundedcontrol: forward layer-2 delivery moved");
        assertEq(revLayerTwo, 380_000e18, "fundedcontrol: reverse layer-2 delivery moved");
        assertEq(fwdTotal, 395_000e18, "fundedcontrol: forward junior delivery moved");
        assertEq(revTotal, 395_000e18, "fundedcontrol: reverse junior delivery moved");
        // Implied by the two pins above; named separately because it is the property the CONTROL
        // exists to state — a pool that strands nothing cannot make delivery order-dependent.
        assertEq(fwdTotal, revTotal, "fundedcontrol: the pool must not make delivery order-dependent");
        uint256 credited = _juniorCreditGranted();
        assertEq(credited, fwdTotal, "fundedcontrol: credited must equal delivered when the pool strands nothing");
    }

    /// @dev THE SENIOR EXIT PRICE ON THE FUNDED TRIGGER — the consumer the HIGH is actually paid
    ///      out of. Two-sided for the same reason as the v1 exit-price trigger (adversary D1): an
    ///      exit above the realized price is paid by the stayers, an exit below it by the exiter.
    ///      The realization pass uses the forward order; ADR-0035 makes both full orders deliver
    ///      the same aggregate in this cohort.
    function test_trigger_fundedLayerOneExitPriceIsNotAboveTheHonestOne() public {
        _sFundedAsymmetric();
        uint256 shares = vault.balanceOf(alice);
        uint256 exitNow = vault.previewRedeem(shares);
        uint256 snap = vm.snapshotState();
        for (uint256 i = 0; i < evIds.length; ++i) {
            uint256 amount = reserves.deployedTo(evIds[i]);
            _attestLoss(evIds[i], amount, ORACLE_REF);
            vm.prank(servicer);
            defaultManager.realizeLoss(evIds[i], amount, ORACLE_REF);
        }
        uint256 exitAfter = vault.previewRedeem(shares);
        vm.revertToState(snap);
        assertLe(
            exitNow, exitAfter + EXIT_DUST, "HIGH: the funded-layer-1 NAV pays an exiting senior ABOVE the honest price"
        );
        assertGe(
            exitNow + EXIT_DUST,
            exitAfter,
            "D1 MIRROR: the funded-layer-1 NAV pays an exiting senior BELOW the honest price"
        );
    }
}
