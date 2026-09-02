// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockControllerUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";

import {AttestationOracle} from "../src/AttestationOracle.sol";
import {AssessedImpairmentSource} from "../src/AssessedImpairmentSource.sol";
import {ClaimBridge} from "../src/ClaimBridge.sol";
import {CollateralRegistry} from "../src/CollateralRegistry.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {CuratorModule} from "../src/CuratorModule.sol";
import {PointsModule} from "../src/PointsModule.sol";
import {DefaultManager} from "../src/DefaultManager.sol";
import {FRGovernor} from "../src/FRGovernor.sol";
import {GroveToken} from "../src/GroveToken.sol";
import {GroveVotesAggregator} from "../src/GroveVotesAggregator.sol";
import {MintRedeemController} from "../src/MintRedeemController.sol";
import {MtmAtomicExecutor} from "../src/MtmAtomicExecutor.sol";
import {RedemptionQueue} from "../src/RedemptionQueue.sol";
import {ReserveManager} from "../src/ReserveManager.sol";
import {SGrove} from "../src/SGrove.sol";
import {SUSDfr} from "../src/sUSDfr.sol";
import {USDfr} from "../src/USDfr.sol";
import {WaterfallEngine} from "../src/WaterfallEngine.sol";
import {IAttestationOracle} from "../src/interfaces/IAttestationOracle.sol";
import {ICollateralRegistry} from "../src/interfaces/ICollateralRegistry.sol";
import {Config} from "../src/libraries/Config.sol";
import {Roles} from "../src/libraries/Roles.sol";
import {PrivilegeAudit} from "./PrivilegeAudit.sol";
import {PrivilegeTopology} from "./generated/PrivilegeTopology.sol";

/// @notice POST-DEPLOY VALIDATION (CLAUDE.md §2.1): asserts the LIVE system matches
///         the tested fixture topology — module wiring, role assignments (positive AND
///         negative), genesis parameters, retired bootstrap paths. Reads the manifest
///         written by Deploy.s.sol; view-only, runnable by anyone, no key needed:
///         `forge script script/Validate.s.sol --rpc-url $RPC`.
contract Validate is Script {
    struct M {
        address compliance;
        address usdfr;
        address reserves;
        address controller;
        address vault;
        address points;
        address registry;
        address oracle;
        address bridge;
        address curator;
        address waterfall;
        address defaultManager;
        address mtmExecutor;
        address queue;
        address grove;
        address sGrove;
        address timelock;
        address governor;
        address votesAggregator; // ADR-0026 (L-02)
        address deployer;
        address opsAdmin;
        address attester1;
        address attester2;
        address frTreasury;
        address feeRecipient;
        address anchorCurator;
        /// @dev AUDIT FIX (D7-01 round 5): holder of SETTLEMENT_KEEPER_ROLE. Legacy manifests
        ///      predate the role, so `_load` soft-defaults it to `opsAdmin`; ValidateMainnet
        ///      hard-requires the key so a mainnet manifest can never omit it.
        address queueKeeper;
        address stable;
        address assessedImpairmentSource; // ADR-0027; mandatory in the clean-v1 manifest
        bool keepOpsAdmin;
        /// @dev AUDIT FIX (C-01 round 2, reviewer issue A1). False when `attester2`'s key is
        ///      DERIVED from the deployer's own key (`Deploy` does exactly that unless
        ///      `ATTESTER_2` is supplied), i.e. one secret satisfies the whole 2-of-n
        ///      attestation quorum. That quorum authorizes originations, payments, amendments,
        ///      default/loss evidence, and marked-to-market remedies.
        bool attesterQuorumIndependent;
        /// @dev Whether `manifestClaimsDeployerClean` carries a real manifest value. Only the
        ///      manifest-reading `run()` path sets it.
        bool hasManifestClaim;
        /// @dev The manifest's `deployerCleanExceptAttester` claim, cross-checked against live
        ///      chain state (AUDIT FIX C-01 round 2, reviewer issue B4): a stale or hand-edited
        ///      artifact must be CONTRADICTED by validation, not silently believed.
        bool manifestClaimsDeployerClean;
        bool hasMainnetReceipt;
        bytes32 mainnetConfigHash;
        bytes32 mainnetDeploymentScriptRuntimeHash;
        bytes32 mainnetArtifactSetHash;
        bytes32 mainnetPrincipalSetHash;
        uint256 mainnetApprovedTotalGasLimit;
        uint256 mainnetMaxFeePerGasWei;
        uint256 mainnetPriorityFeePerGasWei;
        uint256 mainnetMinDeployerEthWei;
        bytes32 mainnetGasPolicyHash;
        uint256 mainnetExpectedDeployerNonce;
        bytes32 mainnetDeploymentHash;
        bytes32 mainnetApprovedDeploymentHash;
        bytes32 expectedApprovedDeploymentHash;
    }

    function run() external view virtual {
        _validate(_load());
    }

    /// @notice Run the full validation against an explicitly-supplied address set, without
    ///         reading a manifest file from disk.
    /// @dev AUDIT FIX (C-01/L-04). The validation logic was previously reachable only through
    ///      `run()` -> `_load()`, so no test could ever execute it — which is precisely why a
    ///      silently-fail-open validator survived several audit rounds. This entry point lets
    ///      `Handover.s.sol` re-validate in PRODUCTION shape (`keepOpsAdmin=false`) after a
    ///      handover, and lets the integration test drive Deploy -> Handover -> Validate end
    ///      to end in memory. View-only; identical assertions to `run()`.
    /// @param a The deployed address set and posture flags to validate.
    function validateDeployment(M memory a) external view {
        _validate(a);
    }

    /// @notice The HANDOVER-SCOPED validation: wiring, roles (positive and negative), the
    ///         governance topology, the privilege receipt and the L-04 liveness checks —
    ///         but NOT the genesis-only assertions.
    /// @dev AUDIT FIX (C-01 round 2, reviewer issue A2). `Handover.s.sol` used to call the
    ///      full `validateDeployment`, which asserts GENESIS-ONLY facts such as the untouched
    ///      sUSDfr vault seed and the per-class parameter tuples. An EXERCISED deployment no
    ///      longer satisfies them — and because
    ///      `forge script` simulates the whole of `run()` before broadcasting anything, a
    ///      revert there meant the handover would NEVER EXECUTE on a deployment that had
    ///      actually been exercised. That is exactly the owner's use case: hand over AFTER
    ///      the prod-test window. (This paragraph used to cite
    ///      `grove.balanceOf(frTreasury) == GROVE_INITIAL_SUPPLY` as the blocking equality
    ///      because `QA.s.sol` stakes 1,000e18 GROVE; audit item 8 made that assertion
    ///      staking-neutral, so it is no longer one of the reasons — the others stand.)
    ///      Everything a handover can actually affect is asserted here;
    ///      the genesis set stays in `validateDeployment` for post-deploy use.
    /// @param a The deployed address set and posture flags to validate.
    function validateHandover(M memory a) external view {
        _validateWiring(a);
        _validateGovernance(a);
        console2.log("HANDOVER VALIDATION PASSED: wiring, roles (+/-), governance topology, liveness.");
    }

    function _load() internal view returns (M memory a) {
        string memory manifest = vm.readFile(_manifestPath());
        a.compliance = vm.parseJsonAddress(manifest, ".compliance");
        a.usdfr = vm.parseJsonAddress(manifest, ".usdfr");
        a.reserves = vm.parseJsonAddress(manifest, ".reserves");
        a.controller = vm.parseJsonAddress(manifest, ".controller");
        a.vault = vm.parseJsonAddress(manifest, ".vault");
        a.points = vm.parseJsonAddress(manifest, ".points");
        a.registry = vm.parseJsonAddress(manifest, ".registry");
        a.oracle = vm.parseJsonAddress(manifest, ".oracle");
        a.bridge = vm.parseJsonAddress(manifest, ".bridge");
        a.curator = vm.parseJsonAddress(manifest, ".curator");
        a.waterfall = vm.parseJsonAddress(manifest, ".waterfall");
        a.defaultManager = vm.parseJsonAddress(manifest, ".defaultManager");
        // Legacy Sepolia manifests predate Task D. They remain valid testnet receipts, but
        // mainnet validation below requires this key and every new Deploy writes it.
        a.mtmExecutor =
            vm.keyExistsJson(manifest, ".mtmExecutor") ? vm.parseJsonAddress(manifest, ".mtmExecutor") : address(0);
        a.queue = vm.parseJsonAddress(manifest, ".queue");
        a.grove = vm.parseJsonAddress(manifest, ".grove");
        a.sGrove = vm.parseJsonAddress(manifest, ".sGrove");
        a.timelock = vm.parseJsonAddress(manifest, ".timelock");
        a.governor = vm.parseJsonAddress(manifest, ".governor");
        // ADR-0026 (L-02). Fail LOUD and legibly rather than with a raw cheatcode error:
        // a manifest without this key was written before staked GROVE could vote, and its
        // Governor is permanently bound to GROVE directly (`GovernorVotes._token` has no
        // setter). Such a stack must be REDEPLOYED, never upgraded in place.
        require(
            vm.keyExistsJson(manifest, ".votesAggregator"),
            "manifest predates ADR-0026 (L-02): no .votesAggregator key -- redeploy, do not upgrade"
        );
        a.votesAggregator = vm.parseJsonAddress(manifest, ".votesAggregator");
        a.deployer = vm.parseJsonAddress(manifest, ".deployer");
        a.opsAdmin = vm.parseJsonAddress(manifest, ".opsAdmin");
        a.attester1 =
            vm.keyExistsJson(manifest, ".attester1") ? vm.parseJsonAddress(manifest, ".attester1") : a.deployer;
        a.attester2 = vm.parseJsonAddress(manifest, ".attester2");
        a.frTreasury = vm.parseJsonAddress(manifest, ".frTreasury");
        a.feeRecipient = vm.parseJsonAddress(manifest, ".feeRecipient");
        a.anchorCurator =
            vm.keyExistsJson(manifest, ".anchorCurator") ? vm.parseJsonAddress(manifest, ".anchorCurator") : a.opsAdmin;
        a.queueKeeper =
            vm.keyExistsJson(manifest, ".queueKeeper") ? vm.parseJsonAddress(manifest, ".queueKeeper") : a.opsAdmin;
        // AUDIT FIX (C-01 round 2, reviewer issue A5): `.stable_TESTNET_MOCK` exists only
        // because `Deploy` deploys a MockERC20. A deployment parameterised with canonical
        // USDC writes `.stable` instead, and the hard dependency made validation
        // unrunnable on exactly that shape. Accept either, prefer the generic key.
        a.stable = vm.keyExistsJson(manifest, ".stable")
            ? vm.parseJsonAddress(manifest, ".stable")
            : vm.parseJsonAddress(manifest, ".stable_TESTNET_MOCK");
        a.keepOpsAdmin = vm.keyExistsJson(manifest, ".keepOpsAdmin")
            ? vm.parseJsonBool(manifest, ".keepOpsAdmin")
            : vm.parseJsonBool(manifest, ".TESTNET_keepOpsAdmin");
        a.attesterQuorumIndependent = vm.keyExistsJson(manifest, ".attester2_DERIVED_FROM_DEPLOYER_KEY")
            ? !vm.parseJsonBool(manifest, ".attester2_DERIVED_FROM_DEPLOYER_KEY")
            : false;
        if (vm.keyExistsJson(manifest, ".deployerCleanExceptAttester")) {
            a.hasManifestClaim = true;
            a.manifestClaimsDeployerClean = vm.parseJsonBool(manifest, ".deployerCleanExceptAttester");
        }
        require(
            vm.keyExistsJson(manifest, ".assessedImpairmentSource"),
            "clean-v1 manifest missing .assessedImpairmentSource"
        );
        a.assessedImpairmentSource = vm.parseJsonAddress(manifest, ".assessedImpairmentSource");
        if (vm.keyExistsJson(manifest, ".mainnetDeploymentHash")) {
            require(
                vm.keyExistsJson(manifest, ".mainnetGasPolicyHash"),
                "mainnet manifest predates the gas-policy-bound receipt"
            );
            a.hasMainnetReceipt = true;
            a.mainnetConfigHash = vm.parseJsonBytes32(manifest, ".mainnetConfigHash");
            a.mainnetDeploymentScriptRuntimeHash = vm.parseJsonBytes32(manifest, ".mainnetDeploymentScriptRuntimeHash");
            a.mainnetArtifactSetHash = vm.parseJsonBytes32(manifest, ".mainnetArtifactSetHash");
            a.mainnetPrincipalSetHash = vm.parseJsonBytes32(manifest, ".mainnetPrincipalSetHash");
            a.mainnetApprovedTotalGasLimit = vm.parseUint(vm.parseJsonString(manifest, ".mainnetApprovedTotalGasLimit"));
            a.mainnetMaxFeePerGasWei = vm.parseUint(vm.parseJsonString(manifest, ".mainnetMaxFeePerGasWei"));
            a.mainnetPriorityFeePerGasWei = vm.parseUint(vm.parseJsonString(manifest, ".mainnetPriorityFeePerGasWei"));
            a.mainnetMinDeployerEthWei = vm.parseUint(vm.parseJsonString(manifest, ".mainnetMinDeployerEthWei"));
            a.mainnetGasPolicyHash = vm.parseJsonBytes32(manifest, ".mainnetGasPolicyHash");
            a.mainnetExpectedDeployerNonce = vm.parseJsonUint(manifest, ".mainnetExpectedDeployerNonce");
            a.mainnetDeploymentHash = vm.parseJsonBytes32(manifest, ".mainnetDeploymentHash");
            a.mainnetApprovedDeploymentHash = vm.parseJsonBytes32(manifest, ".mainnetApprovedDeploymentHash");
            a.expectedApprovedDeploymentHash = _expectedApprovedDeploymentHash();
        }
    }

    function _manifestPath() internal view virtual returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), ".json");
    }

    function _expectedApprovedDeploymentHash() internal view virtual returns (bytes32) {
        return vm.envOr("MAINNET_APPROVED_DEPLOYMENT_HASH", bytes32(0));
    }

    function _validate(M memory a) internal view {
        _validateWiring(a);
        _validateGovernance(a);
        _validateGenesis(a);
        console2.log(
            "VALIDATION PASSED: wiring, roles (+/-), genesis params, thresholds, exemptions, value sinks, handover"
        );
    }

    /// @dev Module cross-wiring and the positive/negative role graph. Always true of a live
    ///      system regardless of how much it has been exercised.
    /// @param a The deployed address set and posture flags.
    function _validateWiring(M memory a) internal view {
        // ── module cross-wiring (every modules() view) ─────────────────────
        {
            (address u, address c2, address r) = MintRedeemController(a.controller).modules();
            require(u == a.usdfr && c2 == a.compliance && r == a.reserves, "controller wiring");
        }
        {
            (address r, address o) = ClaimBridge(a.bridge).modules();
            require(r == a.registry && o == a.oracle, "bridge wiring");
        }
        {
            (address u, address r, address v) = CuratorModule(a.curator).modules();
            require(u == a.usdfr && r == a.registry && v == a.vault, "curator wiring");
            // AUDIT FIX (R6-CF1). The reserve-CUSTODY arm of the curator withdrawal freeze. An
            // unwired ReserveManager reads as FROZEN, so a miss here does not open a hole — it
            // bricks curator withdrawals, which is exactly as loud as it should be, and this
            // require makes it visible at validation time instead of at the first withdrawal.
            require(CuratorModule(a.curator).reserveManager() == a.reserves, "curator->reserves (R6-CF1)");
            // The governor supplies the LIVE governance-path length the guardian pre-arm must
            // outlast. Without it the Config launch constants stand as the floor and go stale the
            // day governance retunes votingDelay / votingPeriod / timelock minDelay.
            require(CuratorModule(a.curator).governor() == a.governor, "curator->governor (R6-CF1)");
            // P-49. The check that used to stand here compared `custodyPreArmDuration()` against
            // the `Config` launch path (1 + 7 + 2 = 10 days) and was UNFALSIFIABLE:
            // `_governancePath()` already floors the path at those same 10 days, and
            // `_derivePreArm` multiplies by 3/2, so the duration is >= 15 days for EVERY reachable
            // configuration. It could not fail, and it stood in for a check that can.
            //
            // This is that check. `custodyPreArmCoversLiveGovernancePath()` compares the duration
            // against the UNCAPPED live path, so it is false exactly when the
            // `CUSTODY_PRE_ARM_MAX_PATH` (60 days) cap binds and the derived duration (capped at
            // `CUSTODY_PRE_ARM_MAX_DURATION`, 90 days) no longer outlasts the real governance path
            // — the one regime in which the whole pre-arm mechanism is inverted. Three NatSpec
            // blocks in `CuratorModule` already told the reader this call was made here; until
            // P-49 it was not.
            require(
                CuratorModule(a.curator).custodyPreArmCoversLiveGovernancePath(),
                "curator pre-arm does not outlast the LIVE governance path (R6-CF1 / F3-PA-c)"
            );
        }
        {
            (address b, address r, address rs, address c2, address v, address o) = WaterfallEngine_modules(a.waterfall);
            require(
                b == a.bridge && r == a.registry && rs == a.reserves && c2 == a.controller && v == a.vault
                    && o == a.oracle,
                "waterfall wiring"
            );
        }
        {
            (address b, address r, address rs, address c2, address cu, address o, address v, address ledger) =
                DefaultManager(a.defaultManager).modules();
            require(
                b == a.bridge && r == a.registry && rs == a.reserves && c2 == a.controller && cu == a.curator
                    && o == a.oracle && v == a.vault,
                "defaultManager wiring"
            );
            require(ledger != address(0), "defaultManager commitment ledger unset");
            require(ledger.code.length != 0, "defaultManager commitment ledger has no code");
            // AUDIT FIX (SWEEP-1 VAC-F10) — LOAD-BEARING, DO NOT DELETE. `ConservativeImpairmentMath`
            // is an EIP-170 extraction deployed by `DefaultManager`'s CONSTRUCTOR and held as an
            // immutable, so it lives in the IMPLEMENTATION's runtime code and is not covered by any
            // proxy/wiring check above. The whole redemption-pricing path now hard-depends on it:
            // `pendingSeniorImpairment()` forwards to it, and that feeds `redemptionTotalAssets`,
            // `previewRedeem`, the ADR-0022 queue fill and the ADR-0034 Y-bis exit draw. If the
            // proxy points at a stale or wrong implementation whose immutable is zero or codeless,
            // every one of those reverts — and nothing in `Validate` or `ValidateMainnet` looked.
            // A validator that cannot see the child of the contract it validates is a validator
            // with a hole in it (CLAUDE.md §2.1: "proxies pointing at the right implementations").
            address impairmentMath = address(DefaultManager(a.defaultManager).impairmentMath());
            require(impairmentMath != address(0), "defaultManager impairment math unset");
            require(impairmentMath.code.length != 0, "defaultManager impairment math has no code");
            // Non-vacuous: prove the forwarder actually reaches it rather than merely that an
            // address is populated. On a freshly handed-over deployment this is 0 and must not
            // revert.
            DefaultManager(a.defaultManager).pendingSeniorImpairment();
        }
        if (a.mtmExecutor != address(0)) {
            require(a.mtmExecutor.code.length != 0, "MTM executor has no code");
            MtmAtomicExecutor executor = MtmAtomicExecutor(a.mtmExecutor);
            require(address(executor.oracle()) == a.oracle, "MTM executor->oracle");
            require(address(executor.defaultManager()) == a.defaultManager, "MTM executor->defaultManager");
        } else {
            require(!a.hasMainnetReceipt, "mainnet manifest missing MTM executor");
            console2.log("LEGACY TESTNET: no production MTM atomic executor in this manifest.");
        }
        {
            (address v, address u, address r) = RedemptionQueue(a.queue).modules();
            require(v == a.vault && u == a.usdfr && r == a.reserves, "queue wiring");
        }
        {
            (address g, address u, address v) = SGrove(a.sGrove).modules();
            require(g == a.grove && u == a.usdfr && v == a.vault, "sGrove wiring");
        }
        require(SUSDfr(a.vault).redemptionQueue() == a.queue, "vault->a.queue");
        require(SUSDfr(a.vault).feeRecipient() == a.feeRecipient, "vault fee recipient mismatch");
        require(
            SUSDfr(a.vault).feeRecipient() == WaterfallEngine_feeRecipient(a.waterfall),
            "vault/waterfall fee recipients diverge"
        );

        // ── ADR-0022 Option Y + ADR-0023: senior-side wiring ───────────────
        // All four are OPTIONAL at the contract level (a zero address degrades to the
        // pre-ADR behaviour, which is fail-SAFE to deploy but silently drops the
        // protection). Assert them here so a deploy that forgot cannot pass validation.
        // AUDIT FIX (ADV-1): this wiring now gates TWO things, not one. Besides the ADR-0022
        // resolve hook, `WaterfallEngine._withholdFeeForSeniorImpairment` reads
        // `DefaultManager.pendingSeniorImpairment()` through the same pointer to decide whether a
        // protocol fee may be minted at all. An unwired manager withholds NOTHING, so Forest Road
        // would collect a performance fee out of an unabsorbed senior shortfall — the ADV-1 finding
        // verbatim, and silently, since the contract-level zero check is fail-safe by design.
        require(
            WaterfallEngine(a.waterfall).defaultManager() == a.defaultManager,
            "ADR-0022/ADV-1: engine->defaultManager not wired (a recovered facility would depress "
            "the redemption NAV forever, AND the protocol fee would be paid out of a senior shortfall)"
        );
        AssessedImpairmentSource assessment = AssessedImpairmentSource(a.assessedImpairmentSource);
        require(
            SUSDfr(a.vault).impairmentSource() == a.assessedImpairmentSource,
            "ADR-0027: vault assessment source not wired"
        );
        require(assessment.baseSource() == a.defaultManager, "ADR-0027: assessment base is not DefaultManager");
        {
            uint256 assessedRedemptionImpairment = assessment.pendingSeniorImpairment();
            uint256 assessedFeeImpairment = assessment.performanceFeeImpairment();
            uint256 baseRedemptionImpairment = DefaultManager(a.defaultManager).pendingSeniorImpairment();
            uint256 baseFeeImpairment = DefaultManager(a.defaultManager).performanceFeeImpairment();
            require(
                assessedRedemptionImpairment <= baseRedemptionImpairment,
                "ADR-0027: assessment increases impairment above zero-recovery base"
            );
            require(
                baseFeeImpairment >= baseRedemptionImpairment,
                "ADR-0031: base performance impairment omits fee-neutral junior credit"
            );
            require(
                assessedFeeImpairment >= assessedRedemptionImpairment,
                "ADR-0031: assessed performance impairment below redemption impairment"
            );
            require(
                assessedFeeImpairment <= baseFeeImpairment,
                "ADR-0031: assessed performance impairment exceeds gross base"
            );
        }
        require(
            DefaultManager(a.defaultManager).hasRole(Roles.CREDIT_ROLE, a.waterfall),
            "ADR-0022: engine lacks CREDIT_ROLE on DefaultManager (onDefaultResolved reverts)"
        );
        require(
            SUSDfr(a.vault).hasRole(Roles.CREDIT_ROLE, a.waterfall),
            "ADR-0023: engine lacks CREDIT_ROLE on the vault (notifyYield reverts, so every "
            "distribution would revert)"
        );
        require(
            SUSDfr(a.vault).yieldVestingPeriod() == Config.DEFAULT_YIELD_VESTING_PERIOD,
            "ADR-0023: launch yield-recognition policy differs from the approved zero-period default"
        );
        require(
            SUSDfr(a.vault).redemptionTotalAssets() <= SUSDfr(a.vault).totalAssets(),
            "ADR-0022 S.Y.2: redemption NAV exceeds deposit NAV"
        );
        require(SUSDfr(a.vault).pointsModule() == a.points, "vault->a.points");
        // AUDIT FIX (pre-redeploy): the USDfr compliance + points hooks must be wired, else
        // the sanctions freeze (now the SOLE USDfr transfer gate) and USDfr points are silently
        // off — an unwired module (address(0)) skips the checks entirely.
        require(USDfr(a.usdfr).complianceModule() == a.compliance, "usdfr->a.compliance");
        require(USDfr(a.usdfr).pointsModule() == a.points, "usdfr->a.points");
        // P-01: the curator<->points link must be wired both ways so first-loss accrues points.
        require(PointsModule(a.points).curatorModule() == a.curator, "points->a.curator");
        require(CuratorModule(a.curator).pointsModule() == a.points, "curator->a.points");
        require(DefaultManager(a.defaultManager).backstop() == a.sGrove, "defaultManager->backstop");
        require(FRGovernor(payable(a.governor)).timelock() == a.timelock, "governor->a.timelock");
        // audit R5 M-5: a wrong IVotes token would let an attacker's token drive governance
        // while every other check still passed — assert the governor's vote source. Post
        // ADR-0026 (L-02) that source is the AGGREGATOR, not GROVE directly, so the R5 M-5
        // threat is only still covered if we ALSO pin both of the aggregator's legs.
        require(address(FRGovernor(payable(a.governor)).token()) == a.votesAggregator, "governor->votesAggregator");
        require(
            address(GroveVotesAggregator(a.votesAggregator).grove()) == a.grove
                && address(GroveVotesAggregator(a.votesAggregator).sGrove()) == a.sGrove,
            "votesAggregator legs"
        );
        // ADR-0026: the silent-fallback catcher. `GovernorVotes.clock()` and `CLOCK_MODE()`
        // each swallow a failing token call and fall back to BLOCK NUMBERS. Both vote
        // sources checkpoint in timestamps, so that fallback would leave every voter
        // reading ~0 votes (or every proposal stuck Pending) with no revert anywhere and
        // every other assertion here green. Asserting the governor's clock VALUE cannot
        // catch it; only the mode string can.
        require(_isTimestampClock(FRGovernor(payable(a.governor)).CLOCK_MODE()), "governor clock must be timestamp");
        require(_isTimestampClock(SGrove(a.sGrove).CLOCK_MODE()), "sGrove clock must be timestamp");
        require(_isTimestampClock(GroveToken(a.grove).CLOCK_MODE()), "GROVE clock must be timestamp");
        // ADR-0026: THE no-double-count precondition. The whole argument that staked GROVE
        // is counted exactly once rests on sGROVE's custodied GROVE being UNDELEGATED. A
        // single `delegate` call would make every staked GROVE count twice — once through
        // GROVE, once through sGROVE — while the quorum denominator stayed GROVE-only.
        require(GroveToken(a.grove).delegates(a.sGrove) == address(0), "sGrove custody must stay undelegated");
        // ADR-0026: sGROVE's checkpointed voting units must equal its active stake exactly.
        // This catches a dropped or duplicated mint/burn of voting units, and — the reason it
        // is asserted HERE rather than only in tests — an in-place upgrade of a pre-L-02
        // SGrove proxy, whose Votes namespace is virgin while `staked` is populated, so
        // legacy stakers would panic on `requestUnstake` and their active stake would be
        // trapped. It does NOT catch the `stake` self-delegate-ordering double count:
        // `_delegate` only moves votes between delegates and never touches
        // `_totalCheckpoints`, so the total is unchanged under that bug. That one is caught
        // by `invariant_sgrove_votesEqualDelegatedStake` and the two supply bounds.
        require(SGrove(a.sGrove).totalVotingUnits() == SGrove(a.sGrove).totalStaked(), "sGrove votes != staked");

        // ── roles: positive ────────────────────────────────────────────────
        require(IAccessControl(a.usdfr).hasRole(Roles.MINTER_ROLE, a.controller), "controller mints");
        require(IAccessControl(a.reserves).hasRole(Roles.CONTROLLER_ROLE, a.controller), "controller custody");
        require(IAccessControl(a.bridge).hasRole(Roles.CREDIT_ROLE, a.waterfall), "waterfall on a.bridge");
        require(IAccessControl(a.bridge).hasRole(Roles.CREDIT_ROLE, a.defaultManager), "dm on a.bridge");
        require(IAccessControl(a.registry).hasRole(Roles.CREDIT_ROLE, a.bridge), "bridge on a.registry");
        require(IAccessControl(a.registry).hasRole(Roles.CREDIT_ROLE, a.waterfall), "waterfall on a.registry");
        require(IAccessControl(a.registry).hasRole(Roles.CREDIT_ROLE, a.defaultManager), "dm on a.registry");
        require(IAccessControl(a.reserves).hasRole(Roles.CREDIT_ROLE, a.waterfall), "waterfall on a.reserves");
        require(IAccessControl(a.reserves).hasRole(Roles.CREDIT_ROLE, a.defaultManager), "dm on a.reserves");
        require(IAccessControl(a.controller).hasRole(Roles.CREDIT_ROLE, a.waterfall), "waterfall mints yield");
        require(IAccessControl(a.controller).hasRole(Roles.LOSS_BURNER_ROLE, a.defaultManager), "dm burns loss");
        require(IAccessControl(a.controller).hasRole(Roles.LOSS_BURNER_ROLE, a.reserves), "reserves burn custody loss");
        // AUDIT FIX (R16-M1) — THE NEGATIVES ARE THE POINT. A positive-only role check passes
        // just as happily on an over-granted topology, and over-granting is exactly what the
        // finding was: the engine held a `burnLoss` power it never used, i.e. half of the
        // burn-then-mint confiscation composition, for nothing.
        require(!IAccessControl(a.controller).hasRole(Roles.LOSS_BURNER_ROLE, a.waterfall), "waterfall must not burn");
        require(!IAccessControl(a.controller).hasRole(Roles.CREDIT_ROLE, a.defaultManager), "dm must not mint yield");
        // AUDIT FIX (R16-M1). The credit-layer endpoint lists must be wired, or the cascade and
        // the interest leg are bricked (fail-closed by design — an unwired controller refuses).
        // The negatives pin that no user-reachable address was named.
        require(MintRedeemController(a.controller).isYieldSink(a.vault), "vault is a yield sink");
        require(MintRedeemController(a.controller).isYieldSink(a.feeRecipient), "feeRecipient is a yield sink");
        require(MintRedeemController(a.controller).isLossSource(a.defaultManager), "dm is a loss source");
        require(MintRedeemController(a.controller).isLossSource(a.reserves), "reserves is a loss source");
        require(MintRedeemController(a.controller).isLossSource(a.vault), "vault is a loss source");
        require(!MintRedeemController(a.controller).isLossSource(a.waterfall), "waterfall not a loss source");
        require(!MintRedeemController(a.controller).isLossSource(a.queue), "queue not a loss source");
        require(IAccessControl(a.curator).hasRole(Roles.CREDIT_ROLE, a.defaultManager), "dm absorbs");
        require(IAccessControl(a.curator).hasRole(Roles.CREDIT_ROLE, a.reserves), "reserves absorb curator loss");
        require(IAccessControl(a.oracle).hasRole(Roles.CREDIT_ROLE, a.waterfall), "waterfall consumes");
        require(IAccessControl(a.sGrove).hasRole(Roles.CREDIT_ROLE, a.defaultManager), "dm covers");
        require(IAccessControl(a.sGrove).hasRole(Roles.CREDIT_ROLE, a.reserves), "reserves draw custody cover");
        require(
            ReserveManager(a.reserves).lossController() == a.controller,
            "C-01: reserve loss controller is not MintRedeemController"
        );
        (address lossCurator, address lossBackstop, address lossVault, address lossGovernor, address lossTimelock) =
            ReserveManager(a.reserves).reserveLossModules();
        require(lossCurator == a.curator, "C-01: reserve loss curator mismatch");
        require(lossBackstop == a.sGrove, "C-01: reserve loss backstop mismatch");
        require(lossVault == a.vault, "C-01: reserve loss vault mismatch");
        require(lossGovernor == a.governor, "C-01: reserve loss governor mismatch");
        require(lossTimelock == a.timelock, "C-01: reserve loss timelock mismatch");
        require(CuratorModule(a.curator).reserveManager() == a.reserves, "C-01: curator interlock mismatch");
        (uint256 pendingBackingReduction, uint256 pendingSurplus, uint256 pendingSupplyReduction) =
            ReserveManager(a.reserves).recognizedReserveLoss();
        require(
            pendingBackingReduction == 0 && pendingSurplus == 0 && pendingSupplyReduction == 0,
            "C-01: reserve loss unexpectedly pending"
        );
        (uint256 activeReserveLossIncident,) = ReserveManager(a.reserves).activeReserveLossIncident();
        require(activeReserveLossIncident == 0, "C-01: reserve loss incident unexpectedly active");
        require(ReserveManager(a.reserves).reserveDeficit() == 0, "C-01: reserve deficit at validation");
        require(
            ReserveManager(a.reserves).lossAbsorber() == a.defaultManager,
            "C-01: reserve loss absorber is not DefaultManager"
        );
        require(
            ReserveManager(a.reserves).lossController() == a.controller,
            "C-01: reserve loss controller is not MintRedeemController"
        );
        // ADR-0034 Y-bis — THE ATOMIC JUNIOR DRAW HAS NO WIRING OF ITS OWN, BY DESIGN, SO ITS
        // PRECONDITIONS ARE ASSERTED EXPLICITLY HERE. `MintRedeemController._drawJuniorForExit`
        // DERIVES its draw source from `ReserveManager.lossAbsorber()` rather than storing a second
        // pointer that could desynchronise, and authorises the burn against the existing
        // `setLossSource` list. The four requires above already pin every component; this one
        // states the COMPOSITION, so an edit that drops any of them fails with a message naming
        // the decision rather than a generic wiring error. Under-backed exits price at the GROSS
        // mark — the pre-ADR-0034 defect — the moment this composition breaks.
        require(
            ReserveManager(a.reserves).lossAbsorber() == a.defaultManager
                && MintRedeemController(a.controller).isLossSource(a.defaultManager)
                && IAccessControl(a.curator).hasRole(Roles.CREDIT_ROLE, a.defaultManager)
                && IAccessControl(a.sGrove).hasRole(Roles.CREDIT_ROLE, a.defaultManager),
            "ADR-0034 Y-bis: the atomic junior exit draw is not wired end to end"
        );
        require(
            ReserveManager(a.reserves).exitPrepaidAbsorption() == 0,
            "ADR-0034 Y-bis: exit prepayment ledger non-zero on a fresh deployment"
        );
        require(
            IAccessControl(a.vault).hasRole(Roles.FEE_ACCOUNTING_ROLE, a.curator),
            "curator cannot synchronize vault fee hurdle"
        );
        require(
            IAccessControl(a.vault).hasRole(Roles.FEE_ACCOUNTING_ROLE, a.sGrove),
            "sGrove cannot synchronize vault fee hurdle"
        );
        require(
            IAccessControl(a.vault).hasRole(Roles.FEE_ACCOUNTING_ROLE, a.defaultManager),
            "dm cannot synchronize backstop fee hurdle"
        );
        require(IAccessControl(a.waterfall).hasRole(Roles.SERVICER_ROLE, a.opsAdmin), "ops services a.waterfall");
        require(IAccessControl(a.defaultManager).hasRole(Roles.SERVICER_ROLE, a.opsAdmin), "ops services dm");
        require(IAccessControl(a.bridge).hasRole(Roles.ORIGINATOR_ROLE, a.opsAdmin), "ops originates");
        require(IAccessControl(a.oracle).hasRole(Roles.ATTESTER_ROLE, _attester1(a)), "attester1");
        require(IAccessControl(a.oracle).hasRole(Roles.ATTESTER_ROLE, a.attester2), "attester2");

        // ── roles: negative (no EOA holds module-to-module powers) ────────
        require(!IAccessControl(a.usdfr).hasRole(Roles.MINTER_ROLE, a.deployer), "deployer must NOT mint");
        require(!IAccessControl(a.controller).hasRole(Roles.CREDIT_ROLE, a.deployer), "deployer must NOT credit");
        require(!IAccessControl(a.controller).hasRole(Roles.CREDIT_ROLE, a.opsAdmin), "ops must NOT credit");
        require(!IAccessControl(a.reserves).hasRole(Roles.CREDIT_ROLE, a.opsAdmin), "ops must NOT move principal");
        require(!IAccessControl(a.curator).hasRole(Roles.CREDIT_ROLE, a.opsAdmin), "ops must NOT absorb");
        require(!IAccessControl(a.sGrove).hasRole(Roles.CREDIT_ROLE, a.opsAdmin), "ops must NOT cover");
        require(
            !IAccessControl(a.vault).hasRole(Roles.FEE_ACCOUNTING_ROLE, a.deployer),
            "deployer must NOT synchronize fee accounting"
        );
        require(
            !IAccessControl(a.vault).hasRole(Roles.FEE_ACCOUNTING_ROLE, a.opsAdmin),
            "ops must NOT synchronize fee accounting"
        );
        // AUDIT FIX (R6 L-3): the CREDIT negatives were spot checks — assert no EOA holds it
        // on the remaining CREDIT-bearing modules too.
        require(!IAccessControl(a.bridge).hasRole(Roles.CREDIT_ROLE, a.deployer), "deployer NOT credit(bridge)");
        require(!IAccessControl(a.registry).hasRole(Roles.CREDIT_ROLE, a.deployer), "deployer NOT credit(registry)");
        require(!IAccessControl(a.oracle).hasRole(Roles.CREDIT_ROLE, a.deployer), "deployer NOT credit(oracle)");
        require(!IAccessControl(a.bridge).hasRole(Roles.CREDIT_ROLE, a.opsAdmin), "ops NOT credit(bridge)");
        require(!IAccessControl(a.registry).hasRole(Roles.CREDIT_ROLE, a.opsAdmin), "ops NOT credit(registry)");
        require(!IAccessControl(a.oracle).hasRole(Roles.CREDIT_ROLE, a.opsAdmin), "ops NOT credit(oracle)");
        // AUDIT FIX (R6 M-1): RESERVE_ADMIN (which stables back the protocol) must be
        // governance-held. Assert the timelock holds it; on the prod shape, no EOA does.
        require(
            IAccessControl(a.reserves).hasRole(Roles.RESERVE_ADMIN_ROLE, a.timelock), "timelock holds RESERVE_ADMIN"
        );
        if (!a.keepOpsAdmin) {
            require(
                !IAccessControl(a.reserves).hasRole(Roles.RESERVE_ADMIN_ROLE, a.deployer), "deployer NOT reserve-admin"
            );
            require(
                !IAccessControl(a.reserves).hasRole(Roles.RESERVE_ADMIN_ROLE, a.opsAdmin),
                "ops NOT reserve-admin (prod)"
            );
        }
    }

    /// @dev The governance topology, the privilege receipt, and the L-04 liveness checks.
    ///      Everything a handover can affect, and nothing that a genesis-only equality would
    ///      make un-runnable against an exercised deployment (reviewer issue A2).
    /// @param a The deployed address set and posture flags.
    function _validateGovernance(M memory a) internal view {
        // ── governance handover ────────────────────────────────────────────
        address[] memory mods = PrivilegeTopology.handoverTargets(_topologyTargets(a));
        // Keep the validator-side fail-closed distinctness proof even though the source list is
        // generated: a changed field adapter must never silently remove a governed module.
        for (uint256 i = 0; i < mods.length; ++i) {
            require(mods[i] != address(0), "governed module list has a ZERO address");
            for (uint256 j = 0; j < i; ++j) {
                require(mods[i] != mods[j], "governed module list has a DUPLICATE entry");
            }
        }
        // AUDIT FIX (SWEEP-3 S3-02) — DO NOT DELETE. This is a hand-written positional literal of a
        // fixed length, so a duplicated or reordered entry silently removes a module from every
        // assertion below WITH NO COMPILE ERROR. The same shape, measured on the 17-address audit
        // list, let an ops-held USDfr `MINTER_ROLE` pass both validators green. Every entry is a
        // distinct deployed contract, so a duplicate or a zero is unambiguously a mis-copy.
        // Mirrors `PrivilegeAudit.requireDistinctModules`, which covers the audit lists.
        for (uint256 i = 0; i < mods.length; ++i) {
            require(mods[i] != address(0), "governed module list has a ZERO address");
            for (uint256 j = 0; j < i; ++j) {
                require(mods[i] != mods[j], "governed module list has a DUPLICATE entry");
            }
        }
        for (uint256 i = 0; i < mods.length; ++i) {
            require(IAccessControl(mods[i]).hasRole(bytes32(0), a.timelock), "timelock must be admin everywhere");
            // AUDIT FIX: assert the UPGRADER topology too — it is the most upgrade-critical
            // role, and was previously unchecked. The timelock must hold it; no EOA may.
            require(IAccessControl(mods[i]).hasRole(Roles.UPGRADER_ROLE, a.timelock), "timelock must be upgrader");
            require(!IAccessControl(mods[i]).hasRole(Roles.UPGRADER_ROLE, a.deployer), "deployer must NOT upgrade");
            require(!IAccessControl(mods[i]).hasRole(Roles.UPGRADER_ROLE, a.opsAdmin), "ops must NOT upgrade");
            if (!a.keepOpsAdmin) {
                require(!IAccessControl(mods[i]).hasRole(bytes32(0), a.deployer), "deployer admin must be gone");
                require(!IAccessControl(mods[i]).hasRole(bytes32(0), a.opsAdmin), "ops admin must be gone (prod)");
            }
        }
        // AUDIT FIX (M-6): the ComplianceRegistry must have a LIVE COMPLIANCE_ADMIN holder.
        // `setAllowed` is the only KYC path, and it is COMPLIANCE_ADMIN-gated with no
        // fallback: with zero holders no address can ever be allowlisted, so nobody can mint,
        // stake or redeem, and the whole stack is inert. `Deploy._handover` used to renounce
        // the deployer's grant unconditionally on the production shape — and when `OPS_ADMIN`
        // defaults to the deployer that grant is the ONLY one, so the rehearsal shipped a dead
        // registry while every other check here printed PASSED. A validation that passes on a
        // dead registry is worse than no validation. Checked against the two principals a
        // clean deploy can leave it with (ops operationally, governance as the recovery path);
        // AccessControlUpgradeable is not enumerable, so an exhaustive scan is impossible.
        require(
            IAccessControl(a.compliance).hasRole(Roles.COMPLIANCE_ADMIN_ROLE, a.opsAdmin)
                || IAccessControl(a.compliance).hasRole(Roles.COMPLIANCE_ADMIN_ROLE, a.timelock),
            "ComplianceRegistry has NO COMPLIANCE_ADMIN holder: no address can ever be KYC'd (M-6)"
        );

        // AUDIT FIX (C-01): the posture receipt. Retaining DEFAULT_ADMIN is a deliberate
        // owner choice, not a defect — retaining it SILENTLY was the defect. Validation
        // still PASSES in the retained shape; it just refuses to look identical to a clean
        // handover. In the production shape the same enumeration becomes a hard assertion.
        _reportPrivilegePosture(a);
        {
            TimelockControllerUpgradeable tl = TimelockControllerUpgradeable(payable(a.timelock));
            require(tl.hasRole(tl.PROPOSER_ROLE(), a.governor), "governor proposes");
            require(tl.hasRole(tl.CANCELLER_ROLE(), a.governor), "governor cancels pre-execution operations");
            require(tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "open executor");
            require(!tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), a.deployer), "deployer a.timelock admin must be gone");
            // AUDIT FIX (L-04): a zero `minDelay` makes the timelock a pass-through — a
            // compromised governor could execute instantly, defeating the entire point of
            // routing ownership to a TimelockController. Pin the intended delay exactly.
            // Asserted as a FLOOR, not an equality: `updateDelay` is a lawful governance
            // action and LENGTHENING the delay is strictly safer, so an exact equality would
            // turn a legitimately-operating deployment red (reviewer issue B5). Shortening it
            // below the ADR value -- the actual L-04 risk, up to and including a zero
            // pass-through timelock -- still fails.
            require(tl.getMinDelay() >= Config.TIMELOCK_MIN_DELAY, "timelock minDelay below the intended floor (L-04)");
        }

        // AUDIT FIX (L-04): governance-dead deploy. GroveToken is ERC20Votes: the fixed supply
        // minted to the treasury counts for NOTHING until the holder delegates. Without an
        // active delegation, quorum is unreachable, no proposal can ever execute, and the
        // timelock-held DEFAULT_ADMIN becomes permanently unusable — the protocol would be
        // ungovernable while every other check printed green. Deploy self-delegates only when
        // frTreasury == deployer, so on the production shape this is the check that catches
        // the missing manual `grove.delegate(...)` step.
        //
        // ADR-0026 (L-02) AMENDS THIS CHECK. Voting power is no longer GROVE alone: staked
        // GROVE votes through sGROVE. Reading `grove.getVotes` only would report a treasury
        // that had staked its balance as having ZERO votes and declare healthy governance
        // dead on arrival — and because the sGROVE exit is a 21-day unbond, that false
        // negative would block the one-command handover for three weeks with no fast
        // recovery. Every leg below therefore reads through the aggregator. The two
        // delegations are independent, so each source is checked for its own delegate.
        {
            address groveDelegatee = GroveToken(a.grove).delegates(a.frTreasury);
            address sGroveDelegatee = SGrove(a.sGrove).delegates(a.frTreasury);
            require(
                GroveToken(a.grove).balanceOf(a.frTreasury) == 0 || groveDelegatee != address(0),
                "GROVE treasury has not delegated: governance dead on arrival (L-04)"
            );
            require(
                SGrove(a.sGrove).stakedOf(a.frTreasury) == 0 || sGroveDelegatee != address(0),
                "sGROVE treasury stake has not delegated: governance dead on arrival (L-04/ADR-0026)"
            );
            // Asserted against the treasury's CURRENT holdings, not against
            // `GROVE_INITIAL_SUPPLY` (reviewer issue A2): `QA.s.sol` stakes GROVE into sGROVE
            // on the live testnet system, which lawfully moves tokens out of the treasury.
            // A genesis-only equality here would make the whole validator -- and, through it,
            // the one-command handover -- unrunnable against any exercised deployment, while
            // catching nothing this does not. Post ADR-0026 the staked leg is added back on
            // BOTH sides, so staking is vote-neutral to this assertion, as it is in reality.
            uint256 votable = GroveVotesAggregator(a.votesAggregator).getVotes(groveDelegatee)
                + (
                    sGroveDelegatee == groveDelegatee
                        ? 0
                        : GroveVotesAggregator(a.votesAggregator).getVotes(sGroveDelegatee)
                );
            require(
                votable >= GroveToken(a.grove).balanceOf(a.frTreasury) + SGrove(a.sGrove).stakedOf(a.frTreasury),
                "GROVE treasury holdings are not delegated (L-04)"
            );
            require(votable > 0, "GROVE voting power is zero (L-04)");
        }
    }

    /// @dev GENESIS-ONLY assertions: exact parameter tuples, the untouched GROVE supply, the
    ///      locked vault seed. Correct for a freshly-deployed stack; deliberately NOT part of
    ///      `validateHandover`, because an exercised deployment lawfully breaks some of them.
    /// @param a The deployed address set and posture flags.
    function _validateGenesis(M memory a) internal view {
        // ── genesis parameters + retired bootstrap paths ───────────────────
        _validateClasses(a);
        _validateThresholdsAndExemptions(a);

        // DS-1: pin the governance value sinks — a wrong FEE_RECIPIENT/FR_TREASURY
        // routes all fees / the entire GROVE supply to an attacker, so assert them.
        require(GroveToken(a.grove).totalSupply() == Config.GROVE_INITIAL_SUPPLY, "GROVE supply");
        // AUDIT FIX (item 8): asserted in the STAKING-NEUTRAL form. The old
        // `balanceOf(frTreasury) == GROVE_INITIAL_SUPPLY` equality is permanently broken by
        // the very first thing the mandated live QA does with GROVE — `QA.s.sol` stakes
        // 1,000e18 into sGROVE — which made post-deploy validation ONE-SHOT: a stack could
        // never be re-validated after it had been exercised, exactly when re-validation is
        // most useful. Staking moves GROVE from `balanceOf` into `sGrove.stakedOf`, so adding
        // the staked leg back keeps the property this check actually defends (the entire
        // genesis supply sits with the treasury and nowhere else) while making it invariant
        // to lawful staking. CAVEAT (stated rather than hidden): `stakedOf` excludes GROVE in
        // the 21-day unbonding window, so a treasury mid-unbond will fail this until it
        // claims. That is a genesis-scope check, not part of `validateHandover`.
        require(
            GroveToken(a.grove).balanceOf(a.frTreasury) + SGrove(a.sGrove).stakedOf(a.frTreasury)
                == Config.GROVE_INITIAL_SUPPLY,
            "GROVE not all in treasury (balance + staked)"
        );
        require(WaterfallEngine_feeRecipient(a.waterfall) == a.feeRecipient, "fee recipient mismatch");
        require(
            SUSDfr(a.vault).performanceFeeBps() == Config.DEFAULT_PERFORMANCE_FEE_BPS, "vault performance fee mismatch"
        );
        require(
            SUSDfr(a.vault).maxPerformanceFeeBps() == Config.MAX_PERFORMANCE_FEE_BPS,
            "vault performance fee cap mismatch"
        );
        require(
            SUSDfr(a.vault).managementFeeBps() == Config.DEFAULT_MANAGEMENT_FEE_BPS,
            "vault management fee not at genesis default"
        );
        require(
            SUSDfr(a.vault).maxManagementFeeBps() == Config.MAX_MANAGEMENT_FEE_BPS, "vault management fee cap mismatch"
        );
        require(SUSDfr(a.vault).managementFeeYear() == Config.MANAGEMENT_FEE_YEAR, "vault management fee year mismatch");
        require(SUSDfr(a.vault).highWaterMark() != 0, "vault high-water mark not initialized");

        require(ReserveManager(a.reserves).usdc() == a.stable, "canonical USDC mismatch");
        // AUDIT FIX (final-audit #5): assert the C-1 anti-dust-wedge floor is seeded. On the
        // mandated FRESH proxy this cannot be mis-seeded, but an accidental IN-PLACE upgrade of a
        // pre-existing proxy would leave `minRedemptionValue == 0` (floor disabled, re-exposing
        // the dust-wedge surface stop-and-wait relies on the floor to bar) and this check makes
        // that regression LOUD rather than silently PASSED.
        // AUDIT FIX (D7-01 round 5, BLOCKING): CLAUDE.md §2.1 requires post-deploy validation to
        // assert roles are assigned correctly. Before this, a deployment that granted
        // SETTLEMENT_KEEPER_ROLE to address(0) — leaving the protocol's ONLY senior exit with a
        // single usable holder — validated GREEN. Assert the configured holder and operational
        // backstop are real; ValidateMainnet separately requires that they are distinct.
        require(a.queueKeeper != address(0), "Validate: manifest is missing the settlement keeper");
        require(
            IAccessControl(a.queue).hasRole(Roles.SETTLEMENT_KEEPER_ROLE, a.queueKeeper),
            "Validate: settlement keeper does not hold SETTLEMENT_KEEPER_ROLE"
        );
        require(
            IAccessControl(a.queue).hasRole(Roles.SETTLEMENT_KEEPER_ROLE, a.opsAdmin),
            "Validate: the backstop holder does not hold SETTLEMENT_KEEPER_ROLE"
        );
        require(
            !IAccessControl(a.queue).hasRole(Roles.SETTLEMENT_KEEPER_ROLE, address(0)),
            "Validate: SETTLEMENT_KEEPER_ROLE granted to the zero address"
        );

        require(
            RedemptionQueue(a.queue).minRedemptionValue() == Config.DEFAULT_MIN_REDEMPTION_VALUE,
            "queue min redemption value not set (C-1)"
        );
        // AUDIT FIX (final-audit #5, H-5): assert the past-due grace window is seeded within its
        // bound for every class. On the mandated FRESH proxy it is seeded to the cooldown in
        // `initialize`, but an accidental IN-PLACE upgrade of a pre-existing proxy would leave every
        // `graceWindows[classId] == 0`; this per-class check makes that regression LOUD rather than
        // silently PASSED (mirrors the `minRedemptionValue` assertion above). Zero is a valid
        // configured value (mark instantly past maturity), but it is only reachable through an
        // explicit `setGraceWindow`, never as a genesis default, so the bound check is the guard.
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            require(
                DefaultManager(a.defaultManager).graceWindow(classId) <= Config.DEFAULT_REDEEM_COOLDOWN,
                "grace window above cooldown bound (H-5)"
            );
        }

        // AUDIT FIX (R7): assert the anti-inflation seed is LOCKED at the burn sink, not just
        // that some supply exists — a regression seeding a withdrawable deployer-held balance
        // would otherwise pass. SEED_SINK mirrors Deploy.s.sol (0x…dEaD).
        require(SUSDfr(a.vault).totalSupply() > 0, "vault seed missing (ADR-0005)");
        require(
            SUSDfr(a.vault).balanceOf(0x000000000000000000000000000000000000dEaD) >= 10e18,
            "vault seed not locked at burn sink"
        );
        require(MintRedeemController(a.controller).backingInvariantHolds(), "backing invariant");

        // AUDIT FIX (C-01 round 2, reviewer issue A1). A production-shape deployment whose
        // 2-of-n attestation quorum is satisfiable by ONE secret is not a clean deployment.
        // `Deploy` derives attester2's key from the deployer's own key unless `ATTESTER_2` is
        // supplied, and grants ATTESTER_ROLE to both. That key could authorize originations,
        // payment distributions, term amendments, defaults, and realized-loss evidence. Asserted here
        // (the post-deploy gate) rather than in `validateHandover`, so that it can never
        // block the handover itself -- moving admin to the timelock is strictly an
        // improvement and must not be gated on a Part 11 human decision it cannot make.
        if (!a.keepOpsAdmin) {
            address attester1_ = _attester1(a);
            require(attester1_ != a.attester2, "PRODUCTION SHAPE: both attesters are the deployer");
            require(
                a.attesterQuorumIndependent,
                "PRODUCTION SHAPE: attestation quorum is satisfiable by one key (set ATTESTER_2)"
            );
        }
    }

    /// @dev AUDIT FIX (C-01). Enumerate and PRINT every privileged (module, role) pair the
    ///      deployer and operations principals still hold, so a deployment that retained
    ///      an operational admin can
    ///      never again produce output identical to one that handed over cleanly.
    ///
    ///      Posture semantics:
    ///      - `keepOpsAdmin == true` (the owner's deliberate testing / prod-test posture):
    ///        validation PASSES, but prints an unmissable RETAINED PRIVILEGE block naming
    ///        every pair and stating plainly that the backing invariant is not enforceable
    ///        against that key. Nothing is blocked; the operator just gets a receipt.
    ///      - `keepOpsAdmin == false` (production shape): the AUTHORITY subset becomes a hard
    ///        assertion, and everything that legitimately REMAINS on an operational
    ///        principal is still
    ///        enumerated line by line.
    ///
    ///      ROUND 2 (reviewer issues A1 / A3 / B2). The production branch previously asserted
    ///      seven AccessControl roles and then printed the affirmative claim
    ///      "HANDOVER CLEAN: timelock holds all authority" while ENUMERATING NOTHING -- with
    ///      the same hot EOA still holding COMPLIANCE_ADMIN, GUARDIAN on eleven modules (pause
    ///      power over the redemption exit and the loss cascade), ORIGINATOR, SERVICER,
    ///      ATTESTER, the KYC allowlist, and -- entirely outside the scanned role set -- the
    ///      timelock's own PROPOSER/CANCELLER. A green, detail-free receipt over a dangerous
    ///      posture IS the C-01 failure mode; the fix had reproduced it one layer up. The
    ///      clean branch now enumerates unconditionally and claims only what it has proven.
    /// @param a The deployed address set and posture flags.
    function _reportPrivilegePosture(M memory a) internal view {
        (address[] memory targets, string[] memory names) = PrivilegeAudit.moduleSet(_topologyTargets(a));

        // AUDIT FIX (C-01 round 2, reviewer issue B4). The durable manifest receipt is
        // cross-checked against LIVE chain state, so a stale artifact (the pre-round-2
        // `Handover` never refreshed it) or a hand-edited one claiming a clean posture is
        // CONTRADICTED by validation instead of silently believed -- the same fail-open class,
        // moved into the artifact layer.
        if (a.hasManifestClaim) {
            bool actuallyClean = PrivilegeAudit.scan(targets, names, a.deployer, false).length == 0
                && PrivilegeAudit.scanTimelock(a.timelock, a.deployer, false).length == 0;
            require(
                actuallyClean == a.manifestClaimsDeployerClean,
                "manifest deployerCleanExceptAttester contradicts on-chain state"
            );
        }

        if (!a.keepOpsAdmin) {
            // Production shape: NO authority role may survive on either principal. This is the
            // assertion that closes C-01 — the old code only checked DEFAULT_ADMIN, and only
            // on the deployer, so a retained MINTER/CONTROLLER/CREDIT/RESERVE_ADMIN or
            // an ops-held admin still validated green.
            (bytes32[] memory authIds, string[] memory authNames) = PrivilegeAudit.authorityRoleSet();
            require(
                PrivilegeAudit.scanRoles(targets, names, authIds, authNames, a.deployer).length == 0,
                "PRODUCTION SHAPE: deployer authority survived the handover"
            );
            require(
                PrivilegeAudit.scanRoles(targets, names, authIds, authNames, a.opsAdmin).length == 0,
                "PRODUCTION SHAPE: ops authority survived the handover"
            );
            // AUDIT FIX (round 2, reviewer issue A3). The timelock's own role graph. With the
            // open executor asserted a few lines above, PROPOSER is DEFAULT_ADMIN-equivalent
            // (it can schedule `grantRole(MINTER_ROLE, self)` on USDfr and self-execute after
            // minDelay); CANCELLER can veto every proposal. Neither was scanned or asserted.
            require(
                PrivilegeAudit.scanTimelock(a.timelock, a.deployer, true).length == 0,
                "PRODUCTION SHAPE: deployer holds timelock PROPOSER/CANCELLER"
            );
            require(
                PrivilegeAudit.scanTimelock(a.timelock, a.opsAdmin, true).length == 0,
                "PRODUCTION SHAPE: ops holds timelock PROPOSER/CANCELLER"
            );
            // AUDIT FIX (SWEEP-2 F1) — THE PRINCIPAL AXIS. DO NOT DELETE.
            //
            // Everything above scans exactly TWO of the EIGHT principals this deployment names.
            // `Deploy`/`DeployMainnet` also name `queueKeeper`, `frTreasury`, `feeRecipient`,
            // `anchorCurator`, `attester1` and `attester2`, while
            // `DeployMainnet._validatePrincipals`
            // spends twenty-odd `require`s proving they are DISTINCT from one another — then
            // nothing ever asks what any of them HOLDS. MEASURED on a production-shaped ceremony:
            // `UPGRADER_ROLE` on the sUSDfr vault granted to the anchor curator, to the hot
            // settlement keeper, or `DEFAULT_ADMIN_ROLE` granted to the treasury (which also holds
            // the entire GROVE supply and therefore all voting power) survived the full
            // deploy->wire->seed->handover sequence and passed BOTH `validateDeployment` and
            // `validateHandover` green. `Validate._printPosture` prints the keeper's pairs and
            // nothing else's, and printing is not blocking.
            //
            // This is SEAM-1's shape on the other axis: SEAM-1 was a ROLE present in the drop list
            // and absent from the detect list; this was a PRINCIPAL present in the ceremony and
            // absent from the detect list. The handover cannot strip these keys (it only ever
            // acts as/on the two EOAs of record), so detection is the whole remedy: a genesis
            // principal carrying protocol authority must fail the production gate loudly.
            _assertNamedPrincipalsHoldNoAuthority(a, targets, names);
            if (a.opsAdmin != a.deployer) {
                // A separate deployer key is a pure bootstrap artefact: it must hold nothing
                // at all beyond the ATTESTER concession.
                require(
                    PrivilegeAudit.scan(targets, names, a.deployer, false).length == 0,
                    "PRODUCTION SHAPE: deployer privilege survived the handover"
                );
                // NEXT_SESSION 4.1 item 3: the bootstrap key's seed-mint allowlist entry must
                // be gone too, or a decommissioned key still holds a transferable USDfr seat.
                require(
                    !ComplianceRegistry(a.compliance).isAllowed(a.deployer),
                    "PRODUCTION SHAPE: bootstrap deployer is still KYC-allowlisted"
                );
            }
        }

        _printPosture(a, targets, names);
    }

    /// @dev Named conversion makes a generated field addition a compile-time change at every
    /// topology consumer rather than an unnoticed positional shift.
    function _topologyTargets(M memory a) internal pure returns (PrivilegeTopology.ModuleAddresses memory targets) {
        return PrivilegeTopology.ModuleAddresses({
            compliance: a.compliance,
            usdfr: a.usdfr,
            reserves: a.reserves,
            controller: a.controller,
            vault: a.vault,
            points: a.points,
            registry: a.registry,
            oracle: a.oracle,
            bridge: a.bridge,
            curator: a.curator,
            waterfall: a.waterfall,
            defaultManager: a.defaultManager,
            assessedImpairmentSource: a.assessedImpairmentSource,
            queue: a.queue,
            sGrove: a.sGrove,
            grove: a.grove,
            timelock: a.timelock
        });
    }

    /// @dev AUDIT FIX (SWEEP-2 F1). The six genesis principals other than
    ///      `deployer`/`opsAdmin`
    ///      must hold NO protocol authority: no module AUTHORITY role
    ///      (`PrivilegeAudit.authorityRoleSet` — admin / upgrader / minter / controller / credit /
    ///      reserve-admin / loss-burner / fee-accounting) and no timelock PROPOSER or CANCELLER
    ///      (which, with the open executor asserted above, is DEFAULT_ADMIN-equivalent authority
    ///      over every module, merely delayed).
    ///
    ///      DO NOT DELETE, AND DO NOT NARROW THE PRINCIPAL LIST. Every entry here is an address
    ///      the deployment scripts NAME and the mainnet validator separately proves distinct;
    ///      an address worth proving distinct is an address worth scanning. `ATTESTER_ROLE` is
    ///      deliberately NOT in `authorityRoleSet`, so the two attesters keep the role they exist
    ///      to hold — this asserts only that they hold nothing BEYOND it.
    ///
    ///      Zero entries are skipped rather than scanned: `Validate.M` soft-defaults several of
    ///      these for legacy manifests, and scanning `address(0)` would assert about the open
    ///      `EXECUTOR_ROLE` grant rather than about a principal.
    /// @param a The deployed address set and posture flags.
    /// @param targets The scanned module addresses.
    /// @param names The scanned module names.
    function _assertNamedPrincipalsHoldNoAuthority(M memory a, address[] memory targets, string[] memory names)
        internal
        view
    {
        address[6] memory principals =
            [a.queueKeeper, a.frTreasury, a.feeRecipient, _anchorCurator(a), _attester1(a), a.attester2];
        (bytes32[] memory authIds, string[] memory authNames) = PrivilegeAudit.authorityRoleSet();
        for (uint256 i = 0; i < principals.length; ++i) {
            address p = principals[i];
            if (p == address(0)) continue;
            require(
                PrivilegeAudit.scanRoles(targets, names, authIds, authNames, p).length == 0,
                "PRODUCTION SHAPE: a named genesis principal holds a module AUTHORITY role"
            );
            require(
                PrivilegeAudit.scanTimelock(a.timelock, p, true).length == 0,
                "PRODUCTION SHAPE: a named genesis principal holds timelock PROPOSER/CANCELLER"
            );
        }
    }

    /// @dev The receipt itself. Printed in BOTH postures — a handover that satisfied every
    ///      authority assertion still leaves operational power on principals, and the
    ///      operator is entitled to see exactly what.
    /// @param a The deployed address set and posture flags.
    /// @param targets The scanned module addresses.
    /// @param names The scanned module names.
    function _printPosture(M memory a, address[] memory targets, string[] memory names) internal view {
        string[] memory deployerHeld = PrivilegeAudit.scanEverything(targets, names, a.timelock, a.deployer);
        string memory banner = a.keepOpsAdmin
            ? "======================= RETAINED PRIVILEGE ======================="
            : "=============== RESIDUAL PRIVILEGE AFTER HANDOVER ===============";
        console2.log(banner);
        if (a.keepOpsAdmin) {
            console2.log("This deployment did NOT hand over. Privileged keys are still held.");
        } else {
            console2.log("AUTHORITY HANDED OVER: the timelock holds DEFAULT_ADMIN and UPGRADER on");
            console2.log("every module, and no AUTHORITY role (admin/upgrader/minter/");
            console2.log("controller/credit/reserve-admin) nor timelock PROPOSER/CANCELLER");
            console2.log("survives on either EOA or any named genesis principal. That is ALL");
            console2.log("that has been proven. Everything");
            console2.log("still held by an operational principal is enumerated below - read it");
            console2.log("before treating this deployment as handed over.");
        }
        console2.log("deployer EOA:", a.deployer);
        for (uint256 i = 0; i < deployerHeld.length; ++i) {
            console2.log("  RETAINED PRIVILEGE  deployer  ->", deployerHeld[i]);
        }
        if (ComplianceRegistry(a.compliance).isAllowed(a.deployer)) {
            console2.log("  RETAINED PRIVILEGE  deployer  -> compliance.KYC_ALLOWLISTED");
        }
        if (a.opsAdmin != a.deployer) {
            string[] memory opsHeld = PrivilegeAudit.scanEverything(targets, names, a.timelock, a.opsAdmin);
            console2.log("opsAdmin principal:", a.opsAdmin);
            for (uint256 i = 0; i < opsHeld.length; ++i) {
                console2.log("  RETAINED PRIVILEGE  opsAdmin  ->", opsHeld[i]);
            }
            if (ComplianceRegistry(a.compliance).isAllowed(a.opsAdmin)) {
                console2.log("  RETAINED PRIVILEGE  opsAdmin  -> compliance.KYC_ALLOWLISTED");
            }
        } else {
            console2.log("opsAdmin principal == deployer EOA (pairs above cover both).");
        }
        if (a.queueKeeper != a.opsAdmin && a.queueKeeper != a.deployer) {
            string[] memory keeperHeld = PrivilegeAudit.scanEverything(targets, names, a.timelock, a.queueKeeper);
            console2.log("queueKeeper principal:", a.queueKeeper);
            for (uint256 i = 0; i < keeperHeld.length; ++i) {
                console2.log("  RETAINED PRIVILEGE  queueKeeper  ->", keeperHeld[i]);
            }
        } else {
            console2.log("queueKeeper principal is already enumerated above.");
        }
        console2.log("-----------------------------------------------------------------");
        // AUDIT FIX (round 2, reviewer issue A1): the attestation quorum. This is named in
        // BOTH postures because it is the one privilege that survives a fully successful
        // handover and still reaches the backing invariant.
        if (IAccessControl(a.oracle).hasRole(Roles.ATTESTER_ROLE, a.deployer) && !a.attesterQuorumIndependent) {
            console2.log("ATTESTATION QUORUM IS NOT INDEPENDENT. attester2's key is derived from");
            console2.log("the deployer key, and BOTH hold ATTESTER_ROLE, so ONE secret satisfies");
            console2.log("the 2-of-n threshold alone. That key can authorize originations,");
            console2.log("payment distributions, term amendments, defaults, and realized losses.");
            console2.log("Rotating to independent attesters is Part 11 gate 6, a human decision.");
            console2.log("Set ATTESTER_2 at deploy time, or rotate the attester set before this");
            console2.log("deployment is treated as production.");
            console2.log("-----------------------------------------------------------------");
        }
        if (a.keepOpsAdmin) {
            console2.log("DEFAULT_ADMIN_ROLE administers EVERY other role. Any holder above can");
            console2.log("grantRole(MINTER_ROLE, self) and mint USDfr without ever passing through");
            console2.log("MintRedeemController._assertBacking. While these roles are held, the");
            console2.log("BACKING INVARIANT IS NOT ENFORCEABLE against these keys, and neither is");
            console2.log("the loss cascade ordering or the upgrade timelock.");
            // ADR-0026 (L-02) WIDENS THIS BLAST RADIUS, and the owner is entitled to be told
            // so explicitly rather than discover it. sGROVE is now a source of historical
            // voting power. DEFAULT_ADMIN administers UPGRADER_ROLE, so a holder can grant
            // itself UPGRADER on sGROVE and ship an implementation that writes arbitrary
            // values into the ERC-7201 Votes namespace - including RETROACTIVE votes at any
            // past timepoint. Combined with the treasury holding the genesis GROVE supply,
            // that makes the key structurally unremovable by governance. Making the vote
            // AGGREGATOR immutable does not close this; the vote SOURCE is still upgradeable.
            console2.log("ADR-0026: sGROVE now reports historical VOTING POWER. A DEFAULT_ADMIN");
            console2.log("holder can self-grant UPGRADER on sGROVE and mint itself RETROACTIVE");
            console2.log("votes at any past timepoint, defeating any proposal to remove it.");
            _printExitInstruction(a);
        } else {
            console2.log("GUARDIAN_ROLE can PAUSE the redemption exit path and the loss cascade.");
            console2.log("COMPLIANCE_ADMIN_ROLE can freeze or allowlist any USDfr holder.");
            console2.log("These are intended operator powers, not protocol authority.");
        }
        console2.log("=================================================================");
    }

    /// @dev True when an EIP-6372 clock description is the timestamp mode both vote sources
    ///      and the aggregator must agree on (ADR-0026). String compare, because
    ///      `GovernorVotes.CLOCK_MODE()` swallows a failing call and returns the
    ///      block-number description instead of reverting.
    /// @param mode The `CLOCK_MODE()` string read from a live contract.
    /// @return ok Whether it is exactly "mode=timestamp".
    function _isTimestampClock(string memory mode) internal pure returns (bool ok) {
        return keccak256(bytes(mode)) == keccak256(bytes("mode=timestamp"));
    }

    /// @dev Print the CORRECT one-command exit for the posture actually observed.
    /// @param a The deployed address set and posture flags.
    function _printExitInstruction(M memory a) internal view {
        // AUDIT FIX (C-01 round 2, reviewer issue B1). The exit instruction used to be
        // printed unconditionally, and `Handover.run()` only ever loaded
        // `TESTNET_DEPLOYER_PRIVATE_KEY`. In a split-key retained deploy `Deploy._handoverOne`
        // grants DEFAULT_ADMIN to the OPS EOA and renounces the deployer's, so the advertised
        // command reverted for the one posture whose hot key can mint unbacked USDfr. Both
        // halves are fixed: `Handover` now resolves the signer, and this names the key needed.
        bool deployerIsAdmin = IAccessControl(a.usdfr).hasRole(bytes32(0), a.deployer);
        if (!deployerIsAdmin && IAccessControl(a.usdfr).hasRole(bytes32(0), a.opsAdmin)) {
            console2.log("The OPS key holds DEFAULT_ADMIN here, not the deployer key. Exit with");
            console2.log("TESTNET_OPS_ADMIN_PRIVATE_KEY set:");
        } else {
            console2.log("Exit it in one command (TESTNET_DEPLOYER_PRIVATE_KEY set):");
        }
        console2.log("  forge script script/Handover.s.sol --broadcast");
    }

    /// @dev DS-4: pin the exact per-class economic tuples, not just `active`.
    function _validateClasses(M memory a) internal view {
        CollateralRegistry reg = CollateralRegistry(a.registry);
        uint256 bitCredit = 1 << uint256(IAttestationOracle.AttestationKind.CreditIssued);
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            ICollateralRegistry.ClassParams memory p = reg.classParams(classId);
            require(p.active, "class inactive");
            require(ClaimBridge(a.bridge).requiredMintAttestations(classId) != 0, "mint gate unset");
            require(CuratorModule(a.curator).isApprovedCurator(classId, _anchorCurator(a)), "anchor curator missing");
            require(
                CuratorModule(a.curator).firstLossTarget(classId) == Config.DEFAULT_FIRST_LOSS_PER_CLASS,
                "first-loss target"
            );
            // SM-1 + AUDIT FIX (H-4): EVERY class's mint gate must include the 2-of-n
            // CreditIssued bit — it is the terms attestation the gate binds against.
            require(
                ClaimBridge(a.bridge).requiredMintAttestations(classId) & bitCredit != 0, "gate missing CreditIssued"
            );
            if (classId != Config.CLASS_DIGITAL_ASSETS) {
                require(p.model == ICollateralRegistry.CollateralModel.Receivable, "receivable model");
                require(p.marginCallLtvBps == 0 && p.liquidationLtvBps == 0, "receivable carries margin params");
                // AUDIT FIX (R7): pin the EXACT per-class economic tuple. Previously only the
                // MTM class tuple was pinned; a receivable LTV/maturity/concentration
                // in-range typo would deploy and Validate still printed PASSED — yet maxLtv and
                // concentration are §1.3-named safety params and DS-4 claimed to pin the tuples.
                _assertReceivableTuple(p, classId);
            }
        }
        // exact digital-assets (MTM) tuple — an over-leveraged typo must fail here
        ICollateralRegistry.ClassParams memory da = reg.classParams(Config.CLASS_DIGITAL_ASSETS);
        require(da.model == ICollateralRegistry.CollateralModel.MarkedToMarket, "class 5 must be MTM");
        require(da.maxLtvBps == 5000 && da.marginCallLtvBps == 6500 && da.liquidationLtvBps == 8000, "MTM thresholds");
        require(da.maxMaturity == 365 days, "MTM maxMaturity tuple");
        require(da.maxMarkAge == 1 days, "MTM mark age");
        require(
            da.concentrationLimitBps == _expectedClassConcentrationBps(Config.CLASS_DIGITAL_ASSETS),
            "MTM concentration tuple"
        );
        _reportConcentrationPosture(reg);
    }

    /// @dev Concentration posture receipt. A deployment whose limits are wide open MUST NOT
    ///      produce output identical to one that is actually constrained -- the same rule the
    ///      `keepOpsAdmin` receipt follows. Prints, does not block: the open posture is a
    ///      deliberate Forest Road ramp decision (`Config.RAMP_CONCENTRATION_LIMIT_BPS`), not
    ///      a misconfiguration for this validator to veto.
    /// @param reg The collateral registry.
    function _reportConcentrationPosture(CollateralRegistry reg) internal view {
        (uint16 borrowerBps, uint16 stateBps, uint256 floor) = reg.limits();
        bool anyOpen = borrowerBps >= uint16(Config.BPS) || stateBps >= uint16(Config.BPS);
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            if (reg.classParams(c).concentrationLimitBps >= uint16(Config.BPS)) anyOpen = true;
        }
        if (!anyOpen) return;
        console2.log("=============== CONCENTRATION LIMITS OPEN ===============");
        console2.log("One or more concentration dimensions is set to 100% (unbounded).");
        console2.log("NOTHING BINDS on those dimensions: a single class, borrower or state may");
        console2.log("hold the ENTIRE book. This is the deliberate ramp posture, so that idle");
        console2.log("deposit capital can be deployed before the book has diversity to measure.");
        console2.log("Two consequences:");
        console2.log(" 1. Concentration TELEMETRY IS DARK. isOverConcentrated / the drift events");
        console2.log("    / concentrationHeadroom all measure against the configured limit, so");
        console2.log("    they report clean unconditionally. Monitor ExposureRecorded instead.");
        console2.log(" 2. Setting a real limit later FREEZES whatever is concentrated from");
        console2.log("    further growth until the book grows around it. Set the first real");
        console2.log("    limits at/above actual composition, then step down.");
        console2.log("borrower limit bps:", borrowerBps);
        console2.log("state limit bps:", stateBps);
        console2.log("concentration floor:", floor);
        console2.log("=========================================================");
    }

    /// @dev The exact genesis tuple for each receivable class — MUST mirror the `_receivable`
    ///      literals in Deploy.s.sol. An in-range human typo (still within setClass's (0,BPS]
    ///      bound-checks) in any of these five fields would otherwise deploy silently.
    function _assertReceivableTuple(ICollateralRegistry.ClassParams memory p, uint256 classId) internal view {
        uint16 maxLtv;
        uint64 maxMat;
        uint16 conc;
        if (classId == Config.CLASS_FILM_TAX_CREDITS) {
            (maxLtv, maxMat, conc) = (8000, 730 days, _expectedClassConcentrationBps(classId));
        } else if (classId == Config.CLASS_RENEWABLE_ENERGY) {
            (maxLtv, maxMat, conc) = (7500, 1825 days, _expectedClassConcentrationBps(classId));
        } else if (classId == Config.CLASS_LIFE_SCIENCES) {
            (maxLtv, maxMat, conc) = (6000, 2555 days, _expectedClassConcentrationBps(classId));
        } else if (classId == Config.CLASS_REAL_ESTATE) {
            (maxLtv, maxMat, conc) = (7000, 3650 days, _expectedClassConcentrationBps(classId));
        } else {
            revert("unknown receivable class");
        }
        require(p.maxLtvBps == maxLtv, "receivable maxLtv tuple");
        require(p.maxMaturity == maxMat, "receivable maxMaturity tuple");
        require(p.concentrationLimitBps == conc, "receivable concentration tuple");
    }

    /// @dev Testnet validator expectation. ValidateMainnet overrides this with the
    ///      constrained production tuple, so neither validator can silently accept the
    ///      other deployment posture.
    function _expectedClassConcentrationBps(uint256) internal view virtual returns (uint16) {
        return Config.RAMP_CONCENTRATION_LIMIT_BPS;
    }

    function _attester1(M memory a) internal pure returns (address) {
        return a.attester1 == address(0) ? a.deployer : a.attester1;
    }

    function _anchorCurator(M memory a) internal pure returns (address) {
        return a.anchorCurator == address(0) ? a.opsAdmin : a.anchorCurator;
    }

    /// @dev DS-3 + F1/F2 wiring: all four high-value thresholds are 2-of-n, and every
    ///      internal-value-moving protocol module is compliance-exempt.
    function _validateThresholdsAndExemptions(M memory a) internal view {
        AttestationOracle o = AttestationOracle(a.oracle);
        require(o.threshold(IAttestationOracle.AttestationKind.CreditIssued) == 2, "CreditIssued threshold");
        require(o.threshold(IAttestationOracle.AttestationKind.Valuation) == 2, "Valuation threshold");
        require(o.threshold(IAttestationOracle.AttestationKind.PaymentReceived) == 2, "PaymentReceived threshold");
        require(o.threshold(IAttestationOracle.AttestationKind.DefaultDeclared) == 2, "DefaultDeclared threshold");

        ComplianceRegistry cr = ComplianceRegistry(a.compliance);
        require(cr.isProtocolExempt(a.vault), "vault not exempt");
        require(cr.isProtocolExempt(a.queue), "queue not exempt");
        require(cr.isProtocolExempt(a.reserves), "reserves not exempt");
        require(cr.isProtocolExempt(a.controller), "controller not exempt");
        require(cr.isProtocolExempt(a.curator), "curator not exempt");
        require(cr.isProtocolExempt(a.sGrove), "sGrove not exempt");
        require(cr.isProtocolExempt(a.defaultManager), "defaultManager not exempt");
        require(cr.isProtocolExempt(a.waterfall), "waterfall not exempt");
        require(cr.isProtocolExempt(a.feeRecipient), "feeRecipient not exempt");
    }

    function WaterfallEngine_feeRecipient(address w) internal view returns (address) {
        (bool ok, bytes memory data) = w.staticcall(abi.encodeWithSignature("feeRecipient()"));
        require(ok, "feeRecipient()");
        return abi.decode(data, (address));
    }

    // helper: WaterfallEngine.modules() via typed call (avoids import cycle noise)
    function WaterfallEngine_modules(address w)
        internal
        view
        returns (address, address, address, address, address, address)
    {
        (bool ok, bytes memory data) = w.staticcall(abi.encodeWithSignature("modules()"));
        require(ok, "waterfall modules()");
        return abi.decode(data, (address, address, address, address, address, address));
    }
}
