// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {Config} from "../../src/libraries/Config.sol";
import {MockAttestationOracle} from "../helpers/MockAttestationOracle.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

/// @title SolvencyHandler — bounded handler for the audit's SOLVENCY AND CONSERVATION family
///        (Phase B invariants INV-1 .. INV-4).
///
/// @notice INDEPENDENCE IS THE POINT. Every ghost below is maintained from the AMOUNTS THIS
///         HANDLER PASSED IN, never by reading the contract's own accounting back and comparing
///         it to itself. The reserve ledger, the USDfr supply, the interest split, the deployed
///         exposure and every actor's value position are all reconstructed here from handler
///         inputs, and the invariant file then asserts the contract agrees. A test that
///         re-derives the production expression cannot falsify it (NEXT_SESSION section 6).
///
/// @dev    `fail_on_revert = true`. Every path is bounded or guarded so it can never revert;
///         a revert here is itself a finding. The three LOUD, non-destructive `closeEpoch`
///         abandons are the sole tolerated failures and are matched by selector.
///
///         DELIBERATE SCOPE EXCLUSION: reserve-loss writes are covered by the atomic
///         loss-absorption and cascade suites. This handler owns the independent model for
///         ordinary backing, reserve, queue and repayment flows.
///
///         ALSO EXCLUDED: the loss cascade (`declareDefault` / `realizeLoss`). It is another
///         family's assignment (INV-5..INV-7) and is already driven by `CreditHandler`; both of
///         its legs (`recordPrincipalWritedown` + `burnLoss`) are backing-neutral by
///         construction, so it adds no reachable state to INV-1..INV-4 that this handler misses.
contract SolvencyHandler is Test {
    // ── wired system ─────────────────────────────────────────────────────
    MockERC20 internal usdc;
    USDfr internal usdfr;
    ReserveManager internal reserves;
    MintRedeemController internal controller;
    SUSDfr internal vault;
    CollateralRegistry internal registry;
    ClaimBridge internal bridge;
    MockAttestationOracle internal oracle;
    WaterfallEngine internal waterfall;
    RedemptionQueue internal queue;

    address internal servicer;
    address internal originator;
    address internal custodian;
    address internal protocolFeeRecipient;
    address internal borrower;

    /// @dev Constructor wiring bundle (flat addresses exceed the stack budget).
    struct Wiring {
        address usdc;
        address usdfr;
        address compliance;
        address reserves;
        address controller;
        address vault;
        address registry;
        address bridge;
        address oracle;
        address waterfall;
        address queue;
        address servicer;
        address originator;
        address custodian;
        address feeRecipient;
        address borrower;
        address complianceAdmin;
    }

    uint256 internal constant UNIT = 1e12; // USDfr wei per USDC unit
    /// @dev The SPEC values, hardcoded rather than read back from the contracts, so the
    ///      expectation model is independent of the implementation it checks. `setUp` asserts
    ///      the deployed configuration still matches these, so a governance retune is a loud
    ///      failure rather than a silently-tautological model.
    uint256 internal constant PROTOCOL_FEE_BPS = Config.DEFAULT_PROTOCOL_FEE_BPS;
    uint256 internal constant ORIGINATION_FEE_BPS = Config.DEFAULT_ORIGINATION_FEE_BPS;

    address[3] public actors;
    uint256[] public facilities;
    uint256 internal constant MAX_FACILITIES = 8;

    /// @dev The genesis seed, mirroring `script/Deploy.s.sol` `_seed()` exactly: 10 USDC minted
    ///      and deposited to a permanently locked sink so the vault is NEVER empty. This is not
    ///      cosmetic. Without it, the first `distribute` mints yield into a ZERO-SUPPLY vault,
    ///      which permanently inflates assets-per-share-unit by up to 1e18x and makes every
    ///      later depositor forfeit up to one whole share unit of assets to the incumbents.
    ///      Measured in this handler before the seed was added: a 5,000 USDfr deposit lost
    ///      0.206 USDfr (4.1e-5) to an incumbent holder. Reproducing the deployed configuration
    ///      is the correct fixture choice; the underlying exposure is reported separately.
    address internal constant SEED_SINK = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant SEED_USDC_UNITS = 10e6;

    struct QueueRef {
        address owner;
        uint256 id;
    }

    QueueRef[] public reqs;

    // ── INV-2 ghosts: the reserve ledger, rebuilt from handler inputs ────
    /// @notice USDC units (6dp) the ledger SHOULD hold, accumulated from the exact amounts
    ///         this handler moved. Never read back from `ReserveManager`.
    uint256 public gIdleUnits;
    /// @notice Deployed principal (18dp), accumulated from the exact deployments/repayments.
    uint256 public gDeployedValue;
    mapping(uint256 tokenId => uint256) public gDeployedTo;

    // ── INV-1 ghosts: the USDfr supply, rebuilt from handler inputs ──────
    uint256 public gMinted;
    uint256 public gBurned;

    // ── INV-3 ghosts: waterfall conservation, summed over the campaign ───
    uint256 public gInterestTotal;
    uint256 public gFeeTotal;
    uint256 public gToVaultTotal;
    uint256 public gOriginationFeeTotal;
    uint256 public gPrincipalRepaid;
    /// @notice Gross cash deployed to borrowers over the campaign (18dp), excluding the
    ///         capitalised origination fee, which never physically leaves the treasury.
    uint256 public gDeployedGross;
    /// @notice MEASURED USDfr actually credited to the vault by distributions (per-call delta,
    ///         summed). Compared against `gToVaultTotal`, which is the independent model.
    uint256 public gVaultCredited;
    /// @notice MEASURED USDfr actually credited to the protocol fee recipient by distributions.
    uint256 public gFeeCredited;

    // ── INV-4 ghosts: per-actor value, denominated in USDfr wei ──────────
    mapping(address actor => uint256) public gValueIn;
    mapping(address actor => uint256) public gEntitlement;
    uint256 public gDonatedToVault;
    uint256 public gRoundingSlack;

    // ── reach witnesses (anti-vacuity) ──────────────────────────────────
    uint256 public nMints;
    uint256 public nRedeems;
    uint256 public nDeposits;
    uint256 public nRequests;
    uint256 public nFills;
    uint256 public nClaims;
    uint256 public nFundings;
    uint256 public nDistributions;
    uint256 public nReconciles;
    uint256 public nRoundTrips;
    uint256 public nWarps;
    uint256 public gDonatedUSDC;
    uint256 public callCount;

    constructor(Wiring memory w) {
        usdc = MockERC20(w.usdc);
        usdfr = USDfr(w.usdfr);
        reserves = ReserveManager(w.reserves);
        controller = MintRedeemController(w.controller);
        vault = SUSDfr(w.vault);
        registry = CollateralRegistry(w.registry);
        bridge = ClaimBridge(w.bridge);
        oracle = MockAttestationOracle(w.oracle);
        waterfall = WaterfallEngine(w.waterfall);
        queue = RedemptionQueue(w.queue);
        servicer = w.servicer;
        originator = w.originator;
        custodian = w.custodian;
        protocolFeeRecipient = w.feeRecipient;
        borrower = w.borrower;

        actors[0] = makeAddr("solvencyActor0");
        actors[1] = makeAddr("solvencyActor1");
        actors[2] = makeAddr("solvencyActor2");
        vm.startPrank(w.complianceAdmin);
        for (uint256 i = 0; i < 3; ++i) {
            ComplianceRegistry(w.compliance).setAllowed(actors[i], true);
        }
        ComplianceRegistry(w.compliance).setAllowed(address(this), true);
        ComplianceRegistry(w.compliance).setAllowed(SEED_SINK, true);
        vm.stopPrank();

        // Genesis seed, byte-for-byte the deploy script's `_seed()` shape. Recorded in the
        // reserve and supply ghosts like any other entry; the seed shares belong to the locked
        // sink and are deliberately NOT credited to any actor's value ledger.
        usdc.mint(address(this), SEED_USDC_UNITS);
        usdc.approve(address(controller), SEED_USDC_UNITS);
        uint256 seedAssets = controller.mint(SEED_USDC_UNITS);
        usdfr.approve(address(vault), seedAssets);
        vault.deposit(seedAssets, SEED_SINK);
        gIdleUnits += SEED_USDC_UNITS;
        gMinted += seedAssets;

        // The expectation model is only independent while the deployed parameters match the
        // spec constants it is written against. Pin that here rather than reading them back.
        require(waterfall.protocolFeeBps() == PROTOCOL_FEE_BPS, "model/protocol-fee drift");
        require(
            waterfall.originationFeeBps(Config.CLASS_FILM_TAX_CREDITS) == ORIGINATION_FEE_BPS,
            "model/origination-fee drift"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  ACTIONS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Permissionless entry: USDC in, USDfr out, 1:1.
    function mintUSDfr(uint256 actorSeed, uint256 usdcUnits) external {
        address actor = actors[actorSeed % 3];
        usdcUnits = bound(usdcUnits, 1, 5_000_000e6);
        _enter(actor, usdcUnits);
        callCount++;
    }

    /// @notice Permissionless exit: USDfr in, USDC out, 1:1 (whole USDC units only).
    /// @dev Self-seeds its own precondition. Every action in this handler is written to be
    ///      REACHABLE ON ITS OWN DRAW rather than to depend on the fuzzer having chosen a
    ///      particular earlier selector; that is what makes the `afterInvariant` anti-vacuity
    ///      gate a reliable gate instead of a flaky one. The seeding is itself an ordinary
    ///      protocol entry and is recorded in every ghost, so it never hides value.
    function redeemUSDfr(uint256 actorSeed, uint256 usdcUnits) external {
        address actor = actors[actorSeed % 3];
        if (_redeemableUnits(actor) == 0) _enter(actor, 1_000e6);
        uint256 cap = _redeemableUnits(actor);
        if (cap == 0) return;
        usdcUnits = bound(usdcUnits, 1, cap);
        _exit(actor, usdcUnits);
        callCount++;
    }

    /// @notice Permissionless senior entry.
    function depositToVault(uint256 actorSeed, uint256 assets) external {
        address actor = actors[actorSeed % 3];
        if (usdfr.balanceOf(actor) == 0) _enter(actor, 1_000e6);
        uint256 bal = usdfr.balanceOf(actor);
        if (bal == 0) return;
        assets = bound(assets, 1, bal);
        _stake(actor, assets);
        callCount++;
    }

    /// @notice Originate a film facility and fund it in the same call, self-seeding exactly the
    ///         idle liquidity the deployment consumes so the action never starves.
    function originateAndFund(uint256 borrowerSeed, uint256 stateSeed, uint256 principal) external {
        uint256 id = _originate(borrowerSeed, stateSeed, principal);
        if (id == 0) return;
        _fund(id);
        callCount++;
    }

    /// @notice An attested repayment. Self-seeds a live facility when none exists, so the
    ///         senior-yield witness is produced whenever this selector is drawn.
    function repayWithInterest(uint256 facSeed, uint256 interest, uint256 principal) external {
        uint256 id = _ensureLiveFacility(facSeed);
        if (id == 0) return;
        uint256 outstanding = gDeployedTo[id];
        interest = bound(interest, UNIT, 250_000e18);
        interest -= interest % UNIT;
        principal = bound(principal, 0, outstanding);
        principal -= principal % UNIT;
        _distribute(id, interest, principal);
        callCount++;
    }

    /// @notice Permissionless queue entry (the sole senior exit path).
    function requestQueueExit(uint256 actorSeed, uint256 shares) external {
        address actor = actors[actorSeed % 3];
        if (vault.balanceOf(actor) == 0) _seedSeniorPosition(actor);
        _request(actor, shares);
        callCount++;
    }

    /// @notice Permissionless settlement chunk in the role of an ordinary keeper: seed a queue
    ///         entry if the book is empty, advance to the point at which settlement is legal,
    ///         perturb custody adversarially (an unsolicited USDC donation the ledger must
    ///         refuse to recognise, then the unguarded and unpausable `reconcileIdleUSDC`),
    ///         settle a chunk, and claim.
    function settleAndClaim(uint256 maxRequests, uint256 reqSeed, uint256 donation) external {
        _donateUSDC(donation);
        _reconcile();
        if (queue.head() >= queue.totalRequests()) _seedQueueEntry(reqSeed);
        _advanceToSettlementWindow();
        _closeEpochChunk(maxRequests);
        _claimFor(reqSeed);
        callCount++;
    }

    /// @notice The INV-4 named round trip, executed end to end by ONE actor in ONE call, in a
    ///         campaign state that already contains genuine attested yield:
    ///         mint -> deposit -> (yield event) -> queue -> settle -> claim -> redeem.
    ///         Asserts per call that the actor did not end ahead of what it put in plus its
    ///         independently-modelled pro-rata share of yield.
    function queueRoundTrip(uint256 actorSeed, uint256 usdcUnits, uint256 facSeed) external {
        address actor = actors[actorSeed % 3];
        usdcUnits = bound(usdcUnits, 1_000e6, 250_000e6);
        _enter(actor, usdcUnits);
        _stake(actor, usdcUnits * UNIT);

        // A genuine attested yield event, so the "absent genuine yield" clause of INV-4 is
        // exercised rather than trivially true.
        uint256 id = _ensureLiveFacility(facSeed);
        if (id != 0) {
            uint256 interest = bound(uint256(keccak256(abi.encode(facSeed, callCount))), UNIT, 50_000e18);
            interest -= interest % UNIT;
            _distribute(id, interest, 0);
        }

        _request(actor, type(uint256).max);
        vm.warp(block.timestamp + uint256(queue.redeemCooldown()) + 1 days + 1);
        for (uint256 i = 0; i < 3; ++i) {
            if (!_closeEpochChunk(5)) break;
        }
        _claimAll();
        uint256 cap = _redeemableUnits(actor);
        if (cap != 0) _exit(actor, cap);

        _assertActorDidNotGain(actor);
        nRoundTrips++;
        callCount++;
    }

    /// @notice Adversarial, unauthenticated custody perturbation. Neither move may be recognised
    ///         as backing: the USDC donation is not credited, and `reconcileIdleUSDC` may only
    ///         ratchet DOWN (it is a no-op while live custody exceeds the ledger).
    function donateAndReconcile(uint256 actorSeed, uint256 usdcDonation, uint256 usdfrDonation) external {
        _donateUSDC(usdcDonation);
        address actor = actors[actorSeed % 3];
        uint256 bal = usdfr.balanceOf(actor);
        if (bal != 0) {
            usdfrDonation = bound(usdfrDonation, 1, bal);
            vm.prank(actor);
            usdfr.transfer(address(vault), usdfrDonation);
            gDonatedToVault += usdfrDonation;
        }
        _reconcile();
        callCount++;
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 1 hours, 30 days);
        vm.warp(block.timestamp + secs);
        nWarps++;
        callCount++;
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PRIMITIVES — each maintains the independent ghosts
    // ═══════════════════════════════════════════════════════════════════

    function _enter(address actor, uint256 usdcUnits) internal {
        usdc.mint(actor, usdcUnits);
        vm.startPrank(actor);
        usdc.approve(address(controller), usdcUnits);
        controller.mint(usdcUnits);
        vm.stopPrank();
        gIdleUnits += usdcUnits;
        gMinted += usdcUnits * UNIT;
        gValueIn[actor] += usdcUnits * UNIT;
        gRoundingSlack += 2;
        nMints++;
    }

    function _exit(address actor, uint256 usdcUnits) internal {
        vm.prank(actor);
        controller.redeem(usdcUnits * UNIT);
        gIdleUnits -= usdcUnits;
        gBurned += usdcUnits * UNIT;
        gRoundingSlack += 2;
        nRedeems++;
    }

    function _redeemableUnits(address actor) internal view returns (uint256) {
        uint256 byBalance = usdfr.balanceOf(actor) / UNIT;
        uint256 byLiquidity = gIdleUnits;
        return byBalance < byLiquidity ? byBalance : byLiquidity;
    }

    function _stake(address actor, uint256 assets) internal {
        // AUDIT H-3 / R15-01: the vault CLOSES to new capital in the degenerate-pricing band.
        // Skip rather than revert (`fail_on_revert = true`); the state is another family's
        // subject and cannot arise here (no cascade loss is driven by this handler).
        if (vault.maxDeposit(actor) == 0) return;
        if (assets == 0) return;
        uint256 bal = usdfr.balanceOf(actor);
        if (bal < assets) assets = bal;
        if (assets == 0) return;
        vm.startPrank(actor);
        usdfr.approve(address(vault), assets);
        vault.deposit(assets, actor);
        vm.stopPrank();
        // ERC-4626 mints shares rounded DOWN, so an entrant forfeits up to one whole share unit
        // of assets to the incumbents. That is a bounded integer discontinuity, not value
        // creation, and it is the ONLY legitimate way an incumbent's position can rise without a
        // yield event. Bound it explicitly rather than leaving the ceiling unable to express it.
        gRoundingSlack += _shareUnitValue() + 2;
        nDeposits++;
    }

    /// @dev The assets represented by ONE share unit, rounded up: the exact size of the
    ///      ERC-4626 entry/exit rounding step at the current NAV. Computed from the vault's
    ///      published totals, independently of any position under test.
    function _shareUnitValue() internal view returns (uint256) {
        return Math.mulDiv(1, vault.totalAssets() + 1, vault.totalSupply() + 1e6, Math.Rounding.Ceil);
    }

    function _request(address actor, uint256 shares) internal {
        // `requestRedeem` crystallises fees first; do the same here so the admissibility
        // arithmetic below is computed against exactly the state the queue will price against.
        vault.accrueFees();
        uint256 bal = vault.balanceOf(actor);
        if (bal == 0) return;
        uint256 floorValue = queue.minRedemptionValue();
        uint256 minShares = vault.previewWithdraw(floorValue);
        if (minShares == 0) minShares = 1;
        if (bal < minShares) return;
        shares = shares >= bal ? bal : bound(shares, minShares, bal);
        if (vault.convertToAssets(shares) < floorValue) return;
        vm.startPrank(actor);
        vault.approve(address(queue), shares);
        uint256 id = queue.requestRedeem(shares);
        vm.stopPrank();
        reqs.push(QueueRef({owner: actor, id: id}));
        gRoundingSlack += 2;
        nRequests++;
    }

    /// @dev Returns true when the settlement made progress and another chunk is worth trying.
    function _closeEpochChunk(uint256 maxRequests) internal returns (bool progressed) {
        if (!queue.isSettling()) {
            if (block.timestamp < queue.epochEndsAt()) return false;
            if (queue.head() < queue.totalRequests() && block.timestamp < queue.eligibleToSettleAt(queue.head())) {
                return false;
            }
            if (queue.availableLiquidity() == 0 && queue.head() < queue.totalRequests()) return false;
        }
        maxRequests = bound(maxRequests, 1, 5);
        uint256 balBefore = usdfr.balanceOf(address(queue));
        (bool ok, bytes memory ret) = address(queue).call(abi.encodeCall(IRedemptionQueue.closeEpoch, (maxRequests)));
        if (!ok) {
            bytes4 sel = bytes4(ret);
            // The three loud, non-destructive abandons, and nothing else. Anything outside this
            // set is a genuine handler or contract bug and must fail the campaign.
            assertTrue(
                sel == IRedemptionQueue.Queue_NoLiquidity.selector
                    || sel == IRedemptionQueue.Queue_HeadNotRedeemable.selector
                    || sel == IRedemptionQueue.Queue_AllInCooldown.selector,
                "UNEXPECTED SETTLEMENT REVERT"
            );
            return false;
        }
        uint256 filled = usdfr.balanceOf(address(queue)) - balBefore;
        if (filled != 0) {
            nFills++;
            gRoundingSlack += 2;
            return true;
        }
        return false;
    }

    /// @dev Claims the first claimable request at or after a fuzzed start offset, so claim order
    ///      still varies while the action remains reliable.
    function _claimFor(uint256 reqSeed) internal {
        uint256 n = reqs.length;
        if (n == 0) return;
        uint256 start = reqSeed % n;
        for (uint256 i = 0; i < n; ++i) {
            QueueRef memory r = reqs[(start + i) % n];
            (,, uint256 claimable,,) = queue.request(r.id);
            if (claimable == 0) continue;
            _claimOne(r);
            return;
        }
    }

    function _claimAll() internal {
        uint256 n = reqs.length;
        for (uint256 i = 0; i < n; ++i) {
            _claimOne(reqs[i]);
        }
    }

    /// @dev Keeper-style time advance to the earliest moment the queue will legally settle its
    ///      current head. Only ever moves time FORWARD, and only to a boundary the contract
    ///      itself publishes (`eligibleToSettleAt`, `epochEndsAt`).
    function _advanceToSettlementWindow() internal {
        if (queue.head() >= queue.totalRequests()) return;
        if (!queue.isSettling()) {
            uint256 eligible = queue.eligibleToSettleAt(queue.head());
            if (block.timestamp < eligible) vm.warp(eligible + 1);
            uint256 endsAt = uint256(queue.epochEndsAt());
            if (block.timestamp < endsAt) vm.warp(endsAt);
        }
    }

    /// @dev Mint, stake and queue one modest senior position. Used only to make the settlement
    ///      action self-sufficient; every leg is an ordinary permissionless protocol operation
    ///      and is recorded in the value and reserve ghosts exactly as any other entry is.
    function _seedQueueEntry(uint256 seed) internal {
        address actor = actors[seed % 3];
        _seedSeniorPosition(actor);
        _request(actor, type(uint256).max);
    }

    function _seedSeniorPosition(address actor) internal {
        _enter(actor, 5_000e6);
        _stake(actor, 5_000e18);
    }

    function _claimOne(QueueRef memory r) internal {
        (,, uint256 claimable,,) = queue.request(r.id);
        if (claimable == 0) return;
        vm.prank(r.owner);
        queue.claim(r.id);
        gRoundingSlack += 2;
        nClaims++;
    }

    function _donateUSDC(uint256 amount) internal {
        amount = bound(amount, 1, 100_000e6);
        usdc.mint(address(reserves), amount);
        gDonatedUSDC += amount;
    }

    function _reconcile() internal {
        reserves.reconcileIdleUSDC();
        nReconciles++;
    }

    // ── credit primitives ────────────────────────────────────────────────

    function _originate(uint256 borrowerSeed, uint256 stateSeed, uint256 principal) internal returns (uint256 id) {
        if (facilities.length >= MAX_FACILITIES) return 0;
        principal = bound(principal, 10_000e18, 1_500_000e18);
        bytes32 borrowerId = borrowerSeed % 2 == 0 ? keccak256("solvency-borrower-A") : keccak256("solvency-borrower-B");
        bytes32 stateId = stateSeed % 2 == 0 ? keccak256("US-GA") : keccak256("US-NV");
        uint256 room = registry.concentrationHeadroom(Config.CLASS_FILM_TAX_CREDITS, borrowerId, stateId);
        if (principal > room) principal = room;
        principal -= principal % UNIT;
        if (principal < UNIT) return 0;

        uint256 nextId = bridge.totalOriginated() + 1;
        ClaimBridge.OriginationTerms memory terms = _terms(borrowerId, stateId, principal);
        bytes32 termsHash = bridge.creditTermsHash(terms);
        oracle.setPayload(
            nextId, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash, uint64(block.timestamp), true
        );
        oracle.setPayload(nextId, IAttestationOracle.AttestationKind.UCCFiled, termsHash, uint64(block.timestamp), true);
        oracle.setPayload(
            nextId, IAttestationOracle.AttestationKind.CreditIssued, termsHash, uint64(block.timestamp), true
        );
        vm.prank(originator);
        id = bridge.originate(custodian, terms);
        facilities.push(id);
    }

    function _terms(bytes32 borrowerId, bytes32 stateId, uint256 principal)
        internal
        view
        returns (ClaimBridge.OriginationTerms memory t)
    {
        t = ClaimBridge.OriginationTerms({
            classId: Config.CLASS_FILM_TAX_CREDITS,
            borrowerId: borrowerId,
            stateId: stateId,
            principal: principal,
            ltvBps: 7500,
            interestRateBps: 1400,
            maturity: uint64(block.timestamp + 365 days),
            fundingRecipient: borrower,
            paymentInterval: 30 days,
            nextPaymentDue: uint64(block.timestamp + 30 days),
            rateType: ClaimBridge.RateType.Fixed,
            dayCountConvention: ClaimBridge.DayCountConvention.Actual360,
            renewable: false,
            paymentScheduleHash: keccak256("solvency-schedule"),
            rateIndexRef: bytes32(0),
            renewalTermsHash: bytes32(0),
            offchainRef: keccak256("solvency-ucc-ref")
        });
    }

    struct FundModel {
        uint256 usdcAmount;
        uint256 feeUSDC;
        uint256 fee18;
        uint256 deployUSDC;
        uint256 feeBalBefore;
    }

    function _fund(uint256 id) internal {
        ClaimBridge.Facility memory f = bridge.facility(id);
        if (f.state != ClaimBridge.LoanState.Pending) return;
        if (block.timestamp >= f.maturity || block.timestamp >= f.nextPaymentDue) return;

        FundModel memory m;
        m.usdcAmount = f.principal / UNIT;
        // Self-seed exactly the shortfall so funding never starves the campaign, and record it
        // as the genuine protocol entry that it is.
        if (gIdleUnits < m.usdcAmount) _enter(actors[0], m.usdcAmount - gIdleUnits);

        // INDEPENDENT MODEL of ADR-0019 OID mechanics, from the spec constants.
        m.feeUSDC = (m.usdcAmount * ORIGINATION_FEE_BPS) / Config.BPS;
        m.fee18 = m.feeUSDC * UNIT;
        m.deployUSDC = m.usdcAmount - m.feeUSDC;
        m.feeBalBefore = usdfr.balanceOf(protocolFeeRecipient);

        vm.prank(servicer);
        waterfall.fund(id, m.usdcAmount);

        // Per-call differential: the borrower nets principal minus fee, the CLAIM is the full
        // principal, and the fee mints against the capitalised backing.
        assertEq(usdfr.balanceOf(protocolFeeRecipient) - m.feeBalBefore, m.fee18, "INV-3 origination fee mint");

        gIdleUnits -= m.deployUSDC; // recordDeployment moved cash out of custody
        gDeployedValue += m.deployUSDC * UNIT; // recordDeployment
        gDeployedValue += m.fee18; // recordFeeCapitalization (the cash STAYS idle)
        gDeployedTo[id] += m.deployUSDC * UNIT + m.fee18;
        gDeployedGross += m.deployUSDC * UNIT;
        gMinted += m.fee18; // mintYield to the protocol fee recipient
        gOriginationFeeTotal += m.fee18;
        nFundings++;
    }

    function _ensureLiveFacility(uint256 facSeed) internal returns (uint256 id) {
        uint256 n = facilities.length;
        // `facSeed` is a raw fuzz word, so reduce it BEFORE adding the offset: `facSeed + i`
        // overflows for seeds near `type(uint256).max`, which the fuzzer reaches constantly.
        uint256 start = n == 0 ? 0 : facSeed % n;
        for (uint256 i = 0; i < n; ++i) {
            uint256 candidate = facilities[(start + i) % n];
            ClaimBridge.LoanState st = bridge.facility(candidate).state;
            if (st == ClaimBridge.LoanState.Active || st == ClaimBridge.LoanState.Amortizing) return candidate;
        }
        id = _originate(facSeed, facSeed >> 1, 250_000e18);
        if (id == 0) return 0;
        _fund(id);
        ClaimBridge.LoanState after_ = bridge.facility(id).state;
        if (after_ != ClaimBridge.LoanState.Active && after_ != ClaimBridge.LoanState.Amortizing) return 0;
    }

    struct DistModel {
        uint256 usdcAmount;
        uint256 expFee;
        uint256 expToVault;
        uint256 feeBefore;
        uint256 vaultBefore;
        uint256 supplyBefore;
        uint256 outstanding;
        uint64 nextDue;
        bytes32 paymentId;
    }

    function _distribute(uint256 id, uint256 interest, uint256 principal) internal {
        if (interest == 0 && principal == 0) return;
        DistModel memory m;
        m.outstanding = gDeployedTo[id];
        if (principal > m.outstanding) principal = m.outstanding;
        m.usdcAmount = (interest + principal) / UNIT;
        if (m.usdcAmount == 0) return;

        // INDEPENDENT MODEL of the interest split, from the spec constant.
        m.expFee = (interest * PROTOCOL_FEE_BPS) / Config.BPS;
        m.expToVault = interest - m.expFee;

        ClaimBridge.Facility memory f = bridge.facility(id);
        m.nextDue = principal == m.outstanding ? 0 : f.nextPaymentDue + f.paymentInterval;
        if (m.nextDue > f.maturity) m.nextDue = f.maturity;
        m.paymentId = keccak256(abi.encode("solvency-payment", id, callCount, interest, principal, block.timestamp));

        usdc.mint(borrower, m.usdcAmount);
        vm.prank(borrower);
        usdc.approve(address(reserves), m.usdcAmount);
        oracle.setPayload(
            id,
            IAttestationOracle.AttestationKind.PaymentReceived,
            keccak256(
                abi.encode(m.paymentId, id, address(usdc), borrower, m.usdcAmount, interest, principal, m.nextDue)
            ),
            uint64(block.timestamp),
            true
        );

        // Snapshot the pro-rata entitlement model BEFORE the yield lands. Pre-call shares over
        // pre-call supply is a strict OVER-estimate of each actor's claim on this yield (the
        // fee checkpoint inside `distribute` mints fee shares that dilute them further), which
        // is exactly the direction that keeps the INV-4 ceiling sound.
        _accrueEntitlement(m.expToVault);

        m.feeBefore = usdfr.balanceOf(protocolFeeRecipient);
        m.vaultBefore = usdfr.balanceOf(address(vault));
        m.supplyBefore = usdfr.totalSupply();

        vm.prank(servicer);
        waterfall.distribute(
            IWaterfallEngine.Payment({
                tokenId: id,
                paymentId: m.paymentId,
                payer: borrower,
                interest: interest,
                principal: principal,
                nextPaymentDue: m.nextDue
            })
        );

        // ── INV-3 per-call differential: nothing created, nothing destroyed ──
        uint256 feeDelta = usdfr.balanceOf(protocolFeeRecipient) - m.feeBefore;
        uint256 vaultDelta = usdfr.balanceOf(address(vault)) - m.vaultBefore;
        assertEq(feeDelta, m.expFee, "INV-3 protocol fee leg");
        assertEq(vaultDelta, m.expToVault, "INV-3 senior leg");
        assertEq(feeDelta + vaultDelta, interest, "INV-3 interest == fee + toVault");
        assertEq(usdfr.totalSupply() - m.supplyBefore, interest, "INV-3 supply moved by exactly the interest");

        gIdleUnits += m.usdcAmount;
        gDeployedValue -= principal;
        gDeployedTo[id] -= principal;
        gMinted += interest;
        gInterestTotal += interest;
        gFeeTotal += m.expFee;
        gToVaultTotal += m.expToVault;
        gPrincipalRepaid += principal;
        gVaultCredited += vaultDelta;
        gFeeCredited += feeDelta;
        gRoundingSlack += 2;
        nDistributions++;
    }

    function _accrueEntitlement(uint256 toVault) internal {
        if (toVault == 0) return;
        uint256 supply = vault.totalSupply();
        if (supply == 0) return;
        for (uint256 i = 0; i < 3; ++i) {
            uint256 eff = vault.balanceOf(actors[i]) + _queuedShares(actors[i]);
            if (eff == 0) continue;
            gEntitlement[actors[i]] += Math.mulDiv(eff, toVault, supply, Math.Rounding.Ceil);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //  INV-4 VALUATION — every position an actor can hold, in USDfr wei
    // ═══════════════════════════════════════════════════════════════════

    function _queuedShares(address actor) internal view returns (uint256 total) {
        uint256 n = reqs.length;
        for (uint256 i = 0; i < n; ++i) {
            if (reqs[i].owner != actor) continue;
            (, uint256 sharesRemaining,,,) = queue.request(reqs[i].id);
            total += sharesRemaining;
        }
    }

    /// @notice Everything `actor` owns anywhere in the system, valued in USDfr wei at the
    ///         OPTIMISTIC (realized) rate. Optimistic on purpose: exits actually price at the
    ///         conservative redemption NAV, so valuing holdings this way can only OVERSTATE the
    ///         actor's position and therefore makes the no-value-creation bound harder to pass.
    function heldValue(address actor) public view returns (uint256 total) {
        total = usdc.balanceOf(actor) * UNIT;
        total += usdfr.balanceOf(actor);
        total += vault.convertToAssets(vault.balanceOf(actor));
        uint256 n = reqs.length;
        for (uint256 i = 0; i < n; ++i) {
            if (reqs[i].owner != actor) continue;
            (, uint256 sharesRemaining, uint256 claimable,,) = queue.request(reqs[i].id);
            total += vault.convertToAssets(sharesRemaining);
            total += claimable;
        }
    }

    /// @notice The most an actor may legitimately end up holding: what it paid in, plus its
    ///         independently-modelled pro-rata share of genuine attested yield, plus the total
    ///         value voluntarily donated into the vault by anyone (a donation is a gift to the
    ///         remaining share holders and is not value creation), plus a bounded rounding
    ///         allowance of 2 wei per value-moving operation.
    function valueCeiling(address actor) public view returns (uint256) {
        return gValueIn[actor] + gEntitlement[actor] + gDonatedToVault + gRoundingSlack;
    }

    function _assertActorDidNotGain(address actor) internal view {
        assertLe(heldValue(actor), valueCeiling(actor), "INV-4 ROUND TRIP WAS NET POSITIVE");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  VIEWS FOR THE INVARIANT FILE
    // ═══════════════════════════════════════════════════════════════════

    function modelledSupply() external view returns (uint256) {
        return gMinted - gBurned;
    }

    function modelledBacking() external view returns (uint256) {
        return gIdleUnits * UNIT + gDeployedValue;
    }

    function facilityCount() external view returns (uint256) {
        return facilities.length;
    }

    function facilityAt(uint256 i) external view returns (uint256) {
        return facilities[i];
    }

    function requestCount() external view returns (uint256) {
        return reqs.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function aggregateHeldValue() external view returns (uint256 total) {
        for (uint256 i = 0; i < 3; ++i) {
            total += heldValue(actors[i]);
        }
    }

    function aggregateValueIn() external view returns (uint256 total) {
        for (uint256 i = 0; i < 3; ++i) {
            total += gValueIn[actors[i]];
        }
    }
}
