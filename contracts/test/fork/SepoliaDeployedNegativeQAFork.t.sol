// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockControllerUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {AttestationOracle} from "../../src/AttestationOracle.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {MintRedeemController} from "../../src/MintRedeemController.sol";
import {RedemptionQueue} from "../../src/RedemptionQueue.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {SUSDfr} from "../../src/sUSDfr.sol";
import {USDfr} from "../../src/USDfr.sol";
import {WaterfallEngine} from "../../src/WaterfallEngine.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

/// @notice NEGATIVE counterpart to `SepoliaDeployedLifecycleFork.t.sol`, which proves the
///         positive economic paths against the addresses the Sepolia ceremony actually produced.
///         This suite drives the CLAUDE.md §2.2 must-fail list against those same deployed
///         contracts on a pinned, chain-31337 local fork.
///
/// @dev     TWO PASSES, NEVER ONE. Every expectation in this file was MEASURED first (bare
///          low-level call, revert bytes logged) and PINNED second. The repository's exhaustive
///          attack campaign produced fifteen false reds from `expectRevert` selectors that were
///          guessed rather than measured; two of the six cases below reverted on a DIFFERENT
///          protective gate than a reasonable prediction would have named:
///
///          • The concentration probes first returned `Bridge_AttestationMissing`, not a
///            `Registry_*ConcentrationExceeded` error, because `ClaimBridge._originate` runs the
///            attestation gate BEFORE `CollateralRegistry.recordExposureIncrease`. An over-limit
///            probe must therefore carry a complete, correctly bound attestation bundle or it
///            never reaches the concentration check at all. See `_assertOverLimitRefused`.
///          • `mint` while under-backed reverts with `Controller_MintClosedWhileUnderBacked`, a
///            distinct error from the `Controller_BackingInvariantViolated` that the credit-side
///            `mintYield` door raises. They are not interchangeable.
///
///          Every assertion below matches the COMPLETE revert payload — selector AND arguments —
///          via `_assertReverts`. Asserting only that "something reverted" is the failure mode
///          catalogued in `STATE.md` as instrument defect 5 and is not used anywhere in this file.
///          Each case is paired with a positive control so that no negative result is vacuous.
contract SepoliaDeployedNegativeQAForkTest is Test {
    uint256 internal constant ATTESTER_PK_1 = 0xA11CE;
    uint256 internal constant ATTESTER_PK_2 = 0xB0B;

    /// @dev ERC-1967 implementation slot, read to prove the timelocked upgrade actually landed.
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    bool internal forkReady;
    uint256 internal forkBlock;
    uint256 internal actorPk;
    uint256 internal attestationNonce;

    address internal actor;
    address internal outsider = makeAddr("sepoliaNegativeQAOutsider");
    address internal ops;
    address internal deployer;
    address internal queueKeeper;
    address internal timelock;
    address internal governor;
    address internal usdfrImpl;

    MockERC20 internal stable;
    USDfr internal usdfr;
    SUSDfr internal vault;
    MintRedeemController internal controller;
    ReserveManager internal reserves;
    RedemptionQueue internal queue;
    ComplianceRegistry internal compliance;
    AttestationOracle internal oracle;
    ClaimBridge internal bridge;
    CollateralRegistry internal registry;
    WaterfallEngine internal waterfall;

    modifier onPinnedFork() {
        vm.skip(!forkReady);
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("SEPOLIA_FORK_RPC_URL", string(""));
        forkBlock = vm.envOr("SEPOLIA_FORK_BLOCK", uint256(0));
        string memory manifestPath = _manifestPath();
        if (bytes(rpc).length == 0 || forkBlock == 0 || !vm.exists(manifestPath)) return;

        vm.createSelectFork(rpc, forkBlock);
        require(block.chainid == 31337, "local fork must use chain ID 31337");

        string memory manifest = vm.readFile(manifestPath);
        uint256 manifestChainId = vm.parseJsonUint(manifest, ".chainId");
        bool localDeploymentRehearsal = vm.envOr("LOCAL_DEPLOYMENT_REHEARSAL", false);
        require(
            manifestChainId == 11155111 || (localDeploymentRehearsal && manifestChainId == 31337),
            "manifest must be Sepolia"
        );
        require(forkBlock > vm.parseJsonUint(manifest, ".deployedAtBlock"), "fork must be post-deployment");
        bool keepOpsAdmin = vm.keyExistsJson(manifest, ".keepOpsAdmin")
            ? vm.parseJsonBool(manifest, ".keepOpsAdmin")
            : vm.parseJsonBool(manifest, ".TESTNET_keepOpsAdmin");
        require(keepOpsAdmin, "curated test requires the manifest-declared testnet ops posture");

        ops = vm.parseJsonAddress(manifest, ".opsAdmin");
        deployer = vm.parseJsonAddress(manifest, ".deployer");
        queueKeeper = vm.parseJsonAddress(manifest, ".queueKeeper");
        timelock = vm.parseJsonAddress(manifest, ".timelock");
        governor = vm.parseJsonAddress(manifest, ".governor");
        usdfrImpl = vm.parseJsonAddress(manifest, ".impl_usdfr");
        stable = MockERC20(vm.parseJsonAddress(manifest, ".stable"));
        usdfr = USDfr(vm.parseJsonAddress(manifest, ".usdfr"));
        vault = SUSDfr(vm.parseJsonAddress(manifest, ".vault"));
        controller = MintRedeemController(vm.parseJsonAddress(manifest, ".controller"));
        reserves = ReserveManager(vm.parseJsonAddress(manifest, ".reserves"));
        queue = RedemptionQueue(vm.parseJsonAddress(manifest, ".queue"));
        compliance = ComplianceRegistry(vm.parseJsonAddress(manifest, ".compliance"));
        oracle = AttestationOracle(vm.parseJsonAddress(manifest, ".oracle"));
        bridge = ClaimBridge(vm.parseJsonAddress(manifest, ".bridge"));
        registry = CollateralRegistry(vm.parseJsonAddress(manifest, ".registry"));
        waterfall = WaterfallEngine(vm.parseJsonAddress(manifest, ".waterfall"));

        actorPk = uint256(keccak256("sepolia deployed negative qa actor"));
        actor = vm.addr(actorPk);
        forkReady = true;
    }

    // ─────────────────────────────────────────────────────────────────────
    // §2.2 case 1 — mint over the backing limit
    // Invariant 1.3: USDfr total supply <= backing value, always.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The par mint window is CLOSED while the recorded book sits below par, so a new
    ///         1:1 claim cannot be sold against an impaired reserve.
    /// @dev The under-backed state is reached the way governance would reach it in production:
    ///      a conservative mark recognised against a live facility (`recognizePrincipalImpairment`,
    ///      DEFAULT_ADMIN on `ReserveManager`), which lowers `totalBackingValue()` while leaving
    ///      USDC custody perfectly intact. The custody assertion below is load-bearing: without
    ///      it this test could pass on `Controller_ReserveCustodyShortfall`, a DIFFERENT guard
    ///      that fires earlier in `mint` for a different reason.
    function test_sepoliaDeployedNegativeQA_mintOverBackingIsRefused() public onPinnedFork {
        _allow(actor);
        _prepareAttesters();

        uint256 principal = _surplus() + 10_000e18;
        uint256 usdcFace = principal / 1e12;
        _mintUsdfr(actor, usdcFace + 5_000e6);

        uint256 tokenId = _originate(principal, keccak256("NEGQA_BORROWER_BACKING"), keccak256("GA"));
        vm.prank(ops);
        waterfall.fund(tokenId, usdcFace);
        assertEq(reserves.deployedTo(tokenId), principal, "facility deployed at face");

        // POSITIVE CONTROL — while the book is whole, this exact mint succeeds.
        assertTrue(controller.backingInvariantHolds(), "control requires a whole book");
        _mintUsdfr(actor, 100e6);

        vm.prank(ops);
        reserves.recognizePrincipalImpairment(tokenId, principal, keccak256("NEGQA_CONSERVATIVE_MARK"));

        assertEq(reserves.idleCustodyShortfall(), 0, "custody intact: this is not the custody guard");
        uint256 supply = usdfr.totalSupply();
        uint256 backing = reserves.totalBackingValue();
        assertGt(supply, backing, "book is under par");
        assertFalse(controller.backingInvariantHolds());

        stable.mint(actor, 1_000e6);
        vm.prank(actor);
        stable.approve(address(controller), 1_000e6);
        _assertReverts(
            "mint() while under-backed",
            actor,
            address(controller),
            abi.encodeCall(controller.mint, (1_000e6)),
            abi.encodeWithSelector(
                IMintRedeemController.Controller_MintClosedWhileUnderBacked.selector, supply, backing
            )
        );
    }

    /// @notice The credit-side yield door cannot mint USDfr the backing does not support either.
    ///         This is the other half of "mint over backing": a fully AUTHORISED caller
    ///         (`WaterfallEngine`, the live `CREDIT_ROLE` holder) asking for one wei more than the
    ///         standing surplus.
    function test_sepoliaDeployedNegativeQA_yieldMintOverBackingIsRefused() public onPinnedFork {
        _allow(actor);
        _mintUsdfr(actor, 20_000e6);

        assertTrue(controller.hasRole(Roles.CREDIT_ROLE, address(waterfall)), "waterfall is the credit door");
        assertTrue(controller.isYieldSink(address(vault)), "the vault is a declared yield sink");

        uint256 surplus = _surplus();
        if (surplus != 0) {
            // POSITIVE CONTROL — exactly the surplus is mintable as yield.
            vm.prank(address(waterfall));
            controller.mintYield(address(vault), surplus);
        }
        assertEq(_surplus(), 0, "surplus exhausted");

        uint256 supplyAfter = usdfr.totalSupply() + 1e18;
        uint256 backingAfter = reserves.totalBackingValue();
        _assertReverts(
            "mintYield() beyond the surplus",
            address(waterfall),
            address(controller),
            abi.encodeCall(controller.mintYield, (address(vault), 1e18)),
            abi.encodeWithSelector(
                IMintRedeemController.Controller_BackingInvariantViolated.selector, supplyAfter, backingAfter
            )
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // §2.2 case 2 — claim an unfilled / not-yet-settled queue position
    // Invariant 1.3: FIFO holds; no double-claim.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice An unsettled position pays nothing, a stranger cannot claim someone else's
    ///         position, an unknown id is rejected, and a settled position cannot be claimed
    ///         twice. The queue is NOT empty at this block — request 0 is an outstanding,
    ///         unfilled operator request — so the stranger case is exercised against real
    ///         live state as well as against the position this test creates.
    function test_sepoliaDeployedNegativeQA_unsettledQueueClaimIsRefused() public onPinnedFork {
        _allow(actor);
        _mintUsdfr(actor, 40_000e6);
        vm.startPrank(actor);
        usdfr.approve(address(vault), 20_000e18);
        vault.deposit(20_000e18, actor);
        vm.stopPrank();

        uint256 preexisting = queue.totalRequests();
        assertGt(preexisting, 0, "the deployed queue carries an outstanding operator request");
        (address operatorOwner, uint256 operatorShares, uint256 operatorClaimable,,) = queue.request(0);
        assertEq(operatorOwner, ops, "request 0 belongs to the ops admin");
        assertGt(operatorShares, 0, "request 0 is still unfilled");
        assertEq(operatorClaimable, 0, "request 0 has nothing claimable");

        uint256 shares = vault.previewWithdraw(1_000e18);
        vm.startPrank(actor);
        vault.approve(address(queue), shares);
        uint256 rid = queue.requestRedeem(shares);
        vm.stopPrank();
        (, uint256 remaining, uint256 claimable,,) = queue.request(rid);
        assertEq(remaining, shares, "position is unfilled");
        assertEq(claimable, 0, "position has nothing claimable");

        _assertReverts(
            "claim() an unfilled position",
            actor,
            address(queue),
            abi.encodeCall(queue.claim, (rid)),
            abi.encodeWithSelector(IRedemptionQueue.Queue_NothingClaimable.selector, rid)
        );
        _assertReverts(
            "claim() someone else's position",
            outsider,
            address(queue),
            abi.encodeCall(queue.claim, (rid)),
            abi.encodeWithSelector(IRedemptionQueue.Queue_NotRequestOwner.selector, rid, outsider)
        );
        _assertReverts(
            "claim() an unknown id",
            actor,
            address(queue),
            abi.encodeCall(queue.claim, (queue.totalRequests())),
            abi.encodeWithSelector(IRedemptionQueue.Queue_UnknownRequest.selector, queue.totalRequests())
        );
        _assertReverts(
            "claim() the live operator position as a stranger",
            actor,
            address(queue),
            abi.encodeCall(queue.claim, (0)),
            abi.encodeWithSelector(IRedemptionQueue.Queue_NotRequestOwner.selector, uint256(0), actor)
        );
        _assertReverts(
            "closeEpoch() before the epoch has ended",
            queueKeeper,
            address(queue),
            abi.encodeCall(queue.closeEpoch, (10)),
            abi.encodeWithSelector(IRedemptionQueue.Queue_EpochNotOver.selector, queue.epochEndsAt())
        );

        // POSITIVE CONTROL — the same claim pays once the keeper has settled the position.
        uint256 rounds;
        while (remaining != 0 && rounds < 8) {
            uint256 settleAt = queue.epochEndsAt();
            uint256 eligibleAt = queue.eligibleToSettleAt(rid);
            if (eligibleAt > settleAt) settleAt = eligibleAt;
            vm.warp(settleAt + 1);
            vm.prank(queueKeeper);
            queue.closeEpoch(10);
            (, remaining,,,) = queue.request(rid);
            ++rounds;
        }
        assertEq(remaining, 0, "position settled");
        uint256 balanceBefore = usdfr.balanceOf(actor);
        vm.prank(actor);
        uint256 claimed = queue.claim(rid);
        assertGt(claimed, 0, "control claim paid");
        assertEq(usdfr.balanceOf(actor) - balanceBefore, claimed, "control claim delivered the assets");

        _assertReverts(
            "claim() the same position twice",
            actor,
            address(queue),
            abi.encodeCall(queue.claim, (rid)),
            abi.encodeWithSelector(IRedemptionQueue.Queue_NothingClaimable.selector, rid)
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // §2.2 case 3 — originate over a concentration limit
    // Invariant 1.3: per-vertical / per-state / per-borrower limits are
    // never exceeded by an origination.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice All three concentration dimensions refuse an origination one wei past their
    ///         headroom, and admit exactly the headroom.
    /// @dev    HONEST DISCLOSURE OF THE LIVE POSTURE, ASSERTED RATHER THAN NARRATED. The deployed
    ///         registry carries `Config.RAMP_CONCENTRATION_LIMIT_BPS == 10_000` on every dimension
    ///         — 100% of the book — which by construction CANNOT breach: the admission test is
    ///         `wouldBe > limitBps * max(newTotal, floor) / BPS`, and at 10,000 bps `wouldBe` is
    ///         bounded above by `newTotal`. So on the deployment as it stands today, no
    ///         origination of any size can trip a concentration limit; the only refusal available
    ///         at an absurd principal is `Registry_PrincipalTooLarge`, an overflow guard rather
    ///         than a concentration limit. That is asserted below first. The enforcement logic in
    ///         the deployed bytecode is then exercised for real by having the live registry admin
    ///         tighten each dimension in turn — which is what a launch out of ramp mode does.
    /// @dev    SCOPE, so this is not mis-read as a mainnet finding. The 100% ramp posture is the
    ///         BASE `Deploy` default and therefore a TESTNET fact. `DeployMainnet` overrides every
    ///         dimension at deployment — `_classParams` to `MainnetConfig.classParams` (Film 3500,
    ///         Renewable 3500, Life Sciences 3000, Real Estate 3500, Digital Assets 2000),
    ///         `_borrowerLimitBps` to 1500, `_stateLimitBps` to 2500 and `_concentrationFloor` to
    ///         25,000,000e18 (`DeployMainnet.s.sol:504-518`). A mainnet-v1 deployment therefore
    ///         launches WITH real limits already enforced; nothing has to be ratcheted afterwards.
    ///         What this test proves is that the deployed bytecode enforces whatever limits it is
    ///         given, measured on a stack that happens to carry the open ones.
    function test_sepoliaDeployedNegativeQA_originationOverConcentrationIsRefused() public onPinnedFork {
        _allow(actor);
        _prepareAttesters();

        ICollateralRegistry.ClassParams memory p = registry.classParams(Config.CLASS_FILM_TAX_CREDITS);
        (uint16 borrowerBps, uint16 stateBps,) = registry.limits();
        assertEq(uint256(p.concentrationLimitBps), 10_000, "LIVE: class limit is the 100% ramp default");
        assertEq(uint256(borrowerBps), 10_000, "LIVE: borrower limit is the 100% ramp default");
        assertEq(uint256(stateBps), 10_000, "LIVE: state limit is the 100% ramp default");
        // Unreachable-as-configured, proven rather than asserted: a book-sized principal is
        // admitted by the live registry's own admission predicate.
        registry.checkConcentration(
            Config.CLASS_FILM_TAX_CREDITS, keccak256("NEGQA_PROBE_BORROWER"), keccak256("GA"), 100_000_000e18
        );

        // Dimension 1 — per-vertical (class).
        _setLimits(2_000, 10_000, 10_000);
        _assertOverLimitRefused(0, keccak256("NEGQA_CLASS_BORROWER"), keccak256("NEGQA_CLASS_STATE"), 2_000);

        // Dimension 2 — per-borrower.
        _setLimits(10_000, 1_000, 10_000);
        _assertOverLimitRefused(1, keccak256("NEGQA_BORROWER_ONLY"), keccak256("NEGQA_BORROWER_STATE"), 1_000);

        // Dimension 3 — per-state.
        _setLimits(10_000, 10_000, 1_000);
        _assertOverLimitRefused(2, keccak256("NEGQA_STATE_BORROWER"), keccak256("NEGQA_STATE_ONLY"), 1_000);
    }

    // ─────────────────────────────────────────────────────────────────────
    // §2.2 case 4 — mint a Loan NFT without the required attestations
    // Invariant 1.3: a Loan NFT cannot mint unless all required attestations
    // are satisfied; escrow cannot release without them either.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The mint gate refuses an absent fact, a quorate fact bound to the wrong terms, and
    ///         a documentary fact bound to another deal — and the FUNDING door re-runs the same
    ///         gate, so revoking a fact after origination stops the draw.
    function test_sepoliaDeployedNegativeQA_loanNftMintGateIsRefused() public onPinnedFork {
        _allow(actor);
        _prepareAttesters();
        _mintUsdfr(actor, 20_000e6);

        uint256 classId = Config.CLASS_FILM_TAX_CREDITS;
        assertEq(bridge.requiredMintAttestations(classId), 7, "AssignmentExecuted | UCCFiled | CreditIssued");

        uint256 nextId = bridge.totalOriginated() + 1;
        ClaimBridge.OriginationTerms memory terms =
            _terms(5_000e18, keccak256("NEGQA_MINTGATE_BORROWER"), keccak256("NEGQA_MINTGATE_STATE"));
        bytes32 termsHash = bridge.creditTermsHash(terms);
        bytes memory originate = abi.encodeCall(bridge.originate, (actor, terms));

        _assertReverts(
            "originate() with no attestations at all",
            ops,
            address(bridge),
            originate,
            abi.encodeWithSelector(
                ClaimBridge.Bridge_AttestationMissing.selector,
                classId,
                IAttestationOracle.AttestationKind.AssignmentExecuted
            )
        );

        _attest(nextId, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash);
        _attest(nextId, IAttestationOracle.AttestationKind.UCCFiled, termsHash);
        _assertReverts(
            "originate() with CreditIssued absent",
            ops,
            address(bridge),
            originate,
            abi.encodeWithSelector(
                ClaimBridge.Bridge_AttestationMissing.selector, classId, IAttestationOracle.AttestationKind.CreditIssued
            )
        );

        bytes32 wrongTerms = keccak256("NEGQA_WRONG_TERMS");
        _attest(nextId, IAttestationOracle.AttestationKind.CreditIssued, wrongTerms);
        _assertReverts(
            "originate() with a quorum attested to other terms",
            ops,
            address(bridge),
            originate,
            abi.encodeWithSelector(ClaimBridge.Bridge_TermsNotAttested.selector, nextId, termsHash, wrongTerms)
        );

        // POSITIVE CONTROL — the complete, correctly bound bundle mints the Loan NFT.
        _attest(nextId, IAttestationOracle.AttestationKind.CreditIssued, termsHash);
        vm.prank(ops);
        uint256 tokenId = bridge.originate(actor, terms);
        assertEq(tokenId, nextId, "control minted the Loan NFT");
        assertEq(bridge.ownerOf(tokenId), actor, "control delivered the position");

        // P-32: a documentary fact that exists and is quorate but commits to a DIFFERENT deal.
        _assertUnboundDocumentaryFactRefused();

        // Escrow cannot release once a required fact is withdrawn: `WaterfallEngine.fund` re-runs
        // `checkFundable`, so a revocation after origination stops the draw.
        vm.prank(timelock);
        oracle.revoke(tokenId, IAttestationOracle.AttestationKind.CreditIssued);
        _assertReverts(
            "fund() after a required attestation was revoked",
            ops,
            address(waterfall),
            abi.encodeCall(waterfall.fund, (tokenId, 5_000e6)),
            abi.encodeWithSelector(
                ClaimBridge.Bridge_AttestationMissing.selector, classId, IAttestationOracle.AttestationKind.CreditIssued
            )
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // §2.2 case 5 — privileged functions as the wrong role
    // Invariant 1.3: no privileged action is reachable by an unauthorized
    // role in any state.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A deliberately SMALL set: an earlier campaign already ran 213 generic
    ///         unauthorized-caller tests, so this adds only what those cannot — the two
    ///         principals that actually retain privilege on the live deployment attempting
    ///         powers they were specifically NOT given. The ops admin holds `DEFAULT_ADMIN` on
    ///         almost every module and is still refused the credit and minting doors; the
    ///         deployer, whose sole retained privilege is `oracle.ATTESTER_ROLE`, is refused
    ///         origination and oracle governance.
    function test_sepoliaDeployedNegativeQA_privilegedCallsRejectTheWrongRole() public onPinnedFork {
        assertTrue(oracle.hasRole(Roles.ATTESTER_ROLE, deployer), "deployer retains the attester role");
        assertTrue(compliance.hasRole(Roles.COMPLIANCE_ADMIN_ROLE, ops), "ops retains compliance admin");

        _assertReverts(
            "ops -> controller.mintYield (CREDIT_ROLE)",
            ops,
            address(controller),
            abi.encodeCall(controller.mintYield, (address(vault), 1e18)),
            _unauthorized(ops, Roles.CREDIT_ROLE)
        );
        _assertReverts(
            "ops -> usdfr.mint (MINTER_ROLE)",
            ops,
            address(usdfr),
            abi.encodeCall(usdfr.mint, (ops, 1e18)),
            _unauthorized(ops, Roles.MINTER_ROLE)
        );
        _assertReverts(
            "deployer -> bridge.originate (ORIGINATOR_ROLE)",
            deployer,
            address(bridge),
            abi.encodeCall(
                bridge.originate,
                (deployer, _terms(1_000e18, keccak256("NEGQA_ROLE_BORROWER"), keccak256("NEGQA_ROLE_STATE")))
            ),
            _unauthorized(deployer, Roles.ORIGINATOR_ROLE)
        );
        // The registry's exposure book is only writable through the bridge: a direct call would
        // otherwise let a caller book or unbook concentration without originating anything.
        _assertReverts(
            "queueKeeper -> registry.recordExposureIncrease (CREDIT_ROLE)",
            queueKeeper,
            address(registry),
            abi.encodeCall(
                registry.recordExposureIncrease,
                (Config.CLASS_FILM_TAX_CREDITS, keccak256("NEGQA_ROLE_BORROWER"), keccak256("GA"), 1_000e18)
            ),
            _unauthorized(queueKeeper, Roles.CREDIT_ROLE)
        );
        _assertReverts(
            "outsider -> queue.closeEpoch (SETTLEMENT_KEEPER_ROLE)",
            outsider,
            address(queue),
            abi.encodeCall(queue.closeEpoch, (10)),
            _unauthorized(outsider, Roles.SETTLEMENT_KEEPER_ROLE)
        );
        // MEASURED, NOT ASSUMED: oracle revocation is DEFAULT_ADMIN-gated, not guardian-gated.
        // Holding ATTESTER_ROLE does not let the deployer withdraw a fact it once signed.
        _assertReverts(
            "deployer -> oracle.revoke (DEFAULT_ADMIN_ROLE)",
            deployer,
            address(oracle),
            abi.encodeCall(oracle.revoke, (1, IAttestationOracle.AttestationKind.CreditIssued)),
            _unauthorized(deployer, bytes32(0))
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // §2.2 case 6 — upgrade a UUPS proxy without the timelock
    // ─────────────────────────────────────────────────────────────────────

    /// @notice No principal other than the timelock can move an implementation, the timelock
    ///         itself cannot execute an operation it never scheduled or one whose delay has not
    ///         run, and the implementation contract refuses a direct (non-proxied) upgrade call.
    /// @dev    HONEST DISCLOSURE, ASSERTED: on THIS deployment `keepOpsAdmin` is true, so the ops
    ///         admin holds `DEFAULT_ADMIN_ROLE`, which administers `UPGRADER_ROLE`. The upgrade
    ///         gate is therefore only as strong as that admin posture — ops cannot upgrade
    ///         directly, but it can grant itself the role first. `Handover.s.sol`'s production
    ///         shape sets `keepOpsAdmin = false` and renounces exactly this, which is what closes
    ///         the escalation. The escalation is exercised below so the record is measured rather
    ///         than argued.
    function test_sepoliaDeployedNegativeQA_uupsUpgradeRequiresTheTimelock() public onPinnedFork {
        assertTrue(usdfr.hasRole(Roles.UPGRADER_ROLE, timelock), "the timelock is the upgrader");
        assertFalse(usdfr.hasRole(Roles.UPGRADER_ROLE, ops), "ops is not an upgrader");
        assertFalse(usdfr.hasRole(Roles.UPGRADER_ROLE, deployer), "the deployer is not an upgrader");
        assertFalse(usdfr.hasRole(Roles.UPGRADER_ROLE, outsider), "no stranger is an upgrader");

        address freshImpl = address(new USDfr());
        bytes memory upgradeCall = abi.encodeCall(usdfr.upgradeToAndCall, (freshImpl, ""));

        _assertReverts(
            "ops -> usdfr.upgradeToAndCall", ops, address(usdfr), upgradeCall, _unauthorized(ops, Roles.UPGRADER_ROLE)
        );
        _assertReverts(
            "deployer -> usdfr.upgradeToAndCall",
            deployer,
            address(usdfr),
            upgradeCall,
            _unauthorized(deployer, Roles.UPGRADER_ROLE)
        );
        _assertReverts(
            "outsider -> usdfr.upgradeToAndCall",
            outsider,
            address(usdfr),
            upgradeCall,
            _unauthorized(outsider, Roles.UPGRADER_ROLE)
        );
        // The vault's `_authorizeUpgrade` carries an extra impairment-source check; the role gate
        // still fires first, so an unauthorized caller learns nothing about the vault's state.
        _assertReverts(
            "ops -> vault.upgradeToAndCall",
            ops,
            address(vault),
            abi.encodeCall(vault.upgradeToAndCall, (freshImpl, "")),
            _unauthorized(ops, Roles.UPGRADER_ROLE)
        );
        // Calling the implementation directly rather than through its proxy.
        _assertReverts(
            "timelock -> the implementation contract directly",
            timelock,
            usdfrImpl,
            upgradeCall,
            abi.encodeWithSelector(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector)
        );

        TimelockControllerUpgradeable tl = TimelockControllerUpgradeable(payable(timelock));
        uint256 minDelay = tl.getMinDelay();
        assertEq(minDelay, Config.TIMELOCK_MIN_DELAY, "live timelock delay");
        assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), governor), "the governor proposes");

        bytes32 salt = keccak256("NEGQA_UPGRADE_OPERATION");
        bytes32 opId = tl.hashOperation(address(usdfr), 0, upgradeCall, bytes32(0), salt);
        bytes memory execute = abi.encodeCall(tl.execute, (address(usdfr), 0, upgradeCall, bytes32(0), salt));
        bytes32 expectReady = bytes32(uint256(1) << uint8(TimelockControllerUpgradeable.OperationState.Ready));

        _assertReverts(
            "execute() an operation that was never scheduled",
            outsider,
            timelock,
            execute,
            abi.encodeWithSelector(
                TimelockControllerUpgradeable.TimelockUnexpectedOperationState.selector, opId, expectReady
            )
        );

        vm.prank(governor);
        tl.schedule(address(usdfr), 0, upgradeCall, bytes32(0), salt, minDelay);
        _assertReverts(
            "execute() before the timelock delay has elapsed",
            outsider,
            timelock,
            execute,
            abi.encodeWithSelector(
                TimelockControllerUpgradeable.TimelockUnexpectedOperationState.selector, opId, expectReady
            )
        );

        // POSITIVE CONTROL — the same upgrade lands once the delay has run, so every refusal
        // above is about the route taken and not about the upgrade being impossible.
        uint256 supplyBefore = usdfr.totalSupply();
        vm.warp(block.timestamp + minDelay + 1);
        vm.prank(outsider);
        tl.execute(address(usdfr), 0, upgradeCall, bytes32(0), salt);
        assertEq(
            address(uint160(uint256(vm.load(address(usdfr), IMPLEMENTATION_SLOT)))),
            freshImpl,
            "the timelocked upgrade landed"
        );
        assertEq(usdfr.totalSupply(), supplyBefore, "state survived the upgrade");

        // The disclosed escalation, measured: `keepOpsAdmin` leaves the role's admin with ops.
        assertEq(usdfr.getRoleAdmin(Roles.UPGRADER_ROLE), bytes32(0), "UPGRADER_ROLE is DEFAULT_ADMIN-administered");
        assertTrue(usdfr.hasRole(bytes32(0), ops), "TESTNET keepOpsAdmin posture: ops holds DEFAULT_ADMIN");
        vm.startPrank(ops);
        usdfr.grantRole(Roles.UPGRADER_ROLE, ops);
        usdfr.upgradeToAndCall(address(new USDfr()), "");
        vm.stopPrank();
    }

    // ── helpers ──────────────────────────────────────────────────────────

    /// @dev Drives `data` from `caller` with a low-level call and asserts the COMPLETE returned
    ///      revert payload — selector and arguments — equals `expected`. A bare "it reverted"
    ///      check would pass on any unrelated failure; this cannot.
    function _assertReverts(
        string memory label,
        address caller,
        address target,
        bytes memory data,
        bytes memory expected
    ) internal {
        vm.prank(caller);
        (bool ok, bytes memory ret) = target.call(data);
        assertFalse(ok, string.concat(label, ": expected a revert but the call SUCCEEDED"));
        assertEq(ret, expected, string.concat(label, ": reverted with a DIFFERENT error than expected"));
    }

    function _unauthorized(address account, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role);
    }

    /// @dev One concentration dimension: `headroom + 1` is refused with the dimension's own
    ///      error and exact arguments, and `headroom` is admitted.
    function _assertOverLimitRefused(uint8 dimension, bytes32 borrowerId, bytes32 stateId, uint256 limitBps) internal {
        uint256 headroom = registry.concentrationHeadroom(Config.CLASS_FILM_TAX_CREDITS, borrowerId, stateId);
        assertGt(headroom, 0, "the tightened dimension must still admit something");

        // MEASURED THE HARD WAY: `ClaimBridge._originate` runs the attestation gate BEFORE the
        // registry's concentration check, so an unattested probe reverts with
        // `Bridge_AttestationMissing` and never reaches the limit at all. The over-limit probe
        // must therefore carry a complete, correctly bound bundle.
        ClaimBridge.OriginationTerms memory over = _terms(headroom + 1, borrowerId, stateId);
        _attestBundle(bridge.totalOriginated() + 1, bridge.creditTermsHash(over));
        _assertReverts(
            "originate() one wei over the concentration limit",
            ops,
            address(bridge),
            abi.encodeCall(bridge.originate, (actor, over)),
            _expectedConcentrationError(dimension, borrowerId, stateId, headroom, limitBps)
        );

        // POSITIVE CONTROL — exactly the headroom is admissible.
        uint256 tokenId = _originate(headroom, borrowerId, stateId);
        assertEq(bridge.ownerOf(tokenId), actor, "control originated at the limit");
        assertEq(registry.borrowerExposure(borrowerId), headroom, "the limit-sized draw was booked");
    }

    function _expectedConcentrationError(
        uint8 dimension,
        bytes32 borrowerId,
        bytes32 stateId,
        uint256 headroom,
        uint256 limitBps
    ) internal view returns (bytes memory) {
        if (dimension == 0) {
            return abi.encodeWithSelector(
                ICollateralRegistry.Registry_ConcentrationExceeded.selector,
                Config.CLASS_FILM_TAX_CREDITS,
                registry.classExposure(Config.CLASS_FILM_TAX_CREDITS) + headroom + 1,
                limitBps
            );
        }
        if (dimension == 1) {
            return abi.encodeWithSelector(
                ICollateralRegistry.Registry_BorrowerConcentrationExceeded.selector,
                borrowerId,
                registry.borrowerExposure(borrowerId) + headroom + 1,
                limitBps
            );
        }
        return abi.encodeWithSelector(
            ICollateralRegistry.Registry_StateConcentrationExceeded.selector,
            stateId,
            registry.stateExposure(stateId) + headroom + 1,
            limitBps
        );
    }

    /// @dev P-32: every deal-identity attestation must commit to THIS deal's terms hash. A fact
    ///      that is present and quorate but bound to another deal is refused with its own error,
    ///      distinct from the plain missing-fact error.
    function _assertUnboundDocumentaryFactRefused() internal {
        ClaimBridge.OriginationTerms memory unbound =
            _terms(4_000e18, keccak256("NEGQA_UNBOUND_BORROWER"), keccak256("NEGQA_UNBOUND_STATE"));
        uint256 unboundId = bridge.totalOriginated() + 1;
        bytes32 unboundHash = bridge.creditTermsHash(unbound);
        bytes32 foreignUcc = keccak256("NEGQA_UNBOUND_UCC");
        _attest(unboundId, IAttestationOracle.AttestationKind.AssignmentExecuted, unboundHash);
        _attest(unboundId, IAttestationOracle.AttestationKind.CreditIssued, unboundHash);
        _attest(unboundId, IAttestationOracle.AttestationKind.UCCFiled, foreignUcc);
        _assertReverts(
            "originate() with UCCFiled bound to another deal",
            ops,
            address(bridge),
            abi.encodeCall(bridge.originate, (actor, unbound)),
            abi.encodeWithSelector(
                ClaimBridge.Bridge_AttestationNotBoundToDeal.selector,
                Config.CLASS_FILM_TAX_CREDITS,
                IAttestationOracle.AttestationKind.UCCFiled,
                unboundHash,
                foreignUcc
            )
        );
    }

    function _attestBundle(uint256 facilityId, bytes32 termsHash) internal {
        _attest(facilityId, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash);
        _attest(facilityId, IAttestationOracle.AttestationKind.UCCFiled, termsHash);
        _attest(facilityId, IAttestationOracle.AttestationKind.CreditIssued, termsHash);
    }

    function _setLimits(uint16 classBps, uint16 borrowerBps, uint16 stateBps) internal {
        ICollateralRegistry.ClassParams memory p = registry.classParams(Config.CLASS_FILM_TAX_CREDITS);
        p.concentrationLimitBps = classBps;
        vm.startPrank(ops);
        registry.setClass(Config.CLASS_FILM_TAX_CREDITS, p);
        registry.setBorrowerLimit(borrowerBps);
        registry.setStateLimit(stateBps);
        vm.stopPrank();
    }

    function _surplus() internal view returns (uint256) {
        uint256 supply = usdfr.totalSupply();
        uint256 backing = reserves.totalBackingValue();
        return backing > supply ? backing - supply : 0;
    }

    function _terms(uint256 principal, bytes32 borrowerId, bytes32 stateId)
        internal
        view
        returns (ClaimBridge.OriginationTerms memory)
    {
        return ClaimBridge.OriginationTerms({
            classId: Config.CLASS_FILM_TAX_CREDITS,
            borrowerId: borrowerId,
            stateId: stateId,
            principal: principal,
            ltvBps: 7500,
            interestRateBps: 1400,
            maturity: uint64(block.timestamp + 365 days),
            fundingRecipient: actor,
            paymentInterval: 30 days,
            nextPaymentDue: uint64(block.timestamp + 30 days),
            rateType: ClaimBridge.RateType.Fixed,
            dayCountConvention: ClaimBridge.DayCountConvention.Actual360,
            renewable: false,
            paymentScheduleHash: keccak256("NEGQA_AMORTIZATION"),
            rateIndexRef: bytes32(0),
            renewalTermsHash: bytes32(0),
            offchainRef: keccak256("NEGQA_CREDIT_FILE")
        });
    }

    function _originate(uint256 principal, bytes32 borrowerId, bytes32 stateId) internal returns (uint256 tokenId) {
        tokenId = bridge.totalOriginated() + 1;
        ClaimBridge.OriginationTerms memory terms = _terms(principal, borrowerId, stateId);
        bytes32 termsHash = bridge.creditTermsHash(terms);
        _attest(tokenId, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash);
        _attest(tokenId, IAttestationOracle.AttestationKind.UCCFiled, termsHash);
        _attest(tokenId, IAttestationOracle.AttestationKind.CreditIssued, termsHash);
        vm.prank(ops);
        uint256 originated = bridge.originate(actor, terms);
        assertEq(originated, tokenId);
    }

    function _attest(uint256 facilityId, IAttestationOracle.AttestationKind kind, bytes32 payload) internal {
        IAttestationOracle.AttestationInput memory input = IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: kind,
            payload: payload,
            asOf: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 2 hours),
            nonce: uint256(keccak256(abi.encode(facilityId, kind, payload, ++attestationNonce)))
        });
        bytes32 digest = oracle.attestationDigest(input);
        (uint256 low, uint256 high) = vm.addr(ATTESTER_PK_1) < vm.addr(ATTESTER_PK_2)
            ? (ATTESTER_PK_1, ATTESTER_PK_2)
            : (ATTESTER_PK_2, ATTESTER_PK_1);
        uint8 threshold = oracle.threshold(kind);
        bytes[] memory signatures = new bytes[](threshold);
        signatures[0] = _sign(low, digest);
        if (threshold > 1) signatures[1] = _sign(high, digest);
        oracle.attest(input, signatures);
        assertTrue(oracle.isSatisfied(facilityId, kind));
    }

    function _prepareAttesters() internal {
        vm.startPrank(ops);
        oracle.grantRole(Roles.ATTESTER_ROLE, vm.addr(ATTESTER_PK_1));
        oracle.grantRole(Roles.ATTESTER_ROLE, vm.addr(ATTESTER_PK_2));
        vm.stopPrank();
    }

    function _mintUsdfr(address recipient, uint256 usdcAmount) internal returns (uint256 amount) {
        stable.mint(recipient, usdcAmount);
        vm.startPrank(recipient);
        stable.approve(address(controller), usdcAmount);
        amount = controller.mint(usdcAmount);
        vm.stopPrank();
    }

    function _allow(address account) internal {
        vm.prank(ops);
        compliance.setAllowed(account, true);
        assertTrue(compliance.isAllowed(account));
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _manifestPath() internal view returns (string memory) {
        return vm.envOr("DEPLOYMENT_MANIFEST", string("deployments/11155111.json"));
    }
}
