// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {AttestationOracle} from "../../src/AttestationOracle.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {CuratorModule} from "../../src/CuratorModule.sol";
import {DefaultManager} from "../../src/DefaultManager.sol";
import {MintRedeemController} from "../../src/MintRedeemController.sol";
import {RedemptionQueue} from "../../src/RedemptionQueue.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {SGrove} from "../../src/SGrove.sol";
import {SUSDfr} from "../../src/sUSDfr.sol";
import {USDfr} from "../../src/USDfr.sol";
import {WaterfallEngine} from "../../src/WaterfallEngine.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IAccrualLifecycle} from "../../src/interfaces/IAccrualLifecycle.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {AccrualBook} from "../../src/libraries/AccrualBook.sol";
import {AccrualLoans} from "../../src/libraries/AccrualLoans.sol";
import {ReserveAccrualLib} from "../../src/libraries/ReserveAccrualLib.sol";
import {ReserveRoundingLib} from "../../src/libraries/ReserveRoundingLib.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @title AccrualInvariantHandler: bounded, never-reverting driver of the continuous-accrual engine
///        on the FULL protocol deployed onto a pinned mainnet fork with REAL USDC.
///
/// @notice Every action is bounded so it cannot revert on its own account; every external call is
///         wrapped so a revert is COUNTED by reason, never swallowed. Reverts the engine documents
///         (a stale book refusing a priced write, a deliberately over-sized receipt, a queue that
///         has nothing to settle) land in named buckets; anything else lands in
///         `unexpectedReverts`, which the harness asserts is zero. The handler keeps GHOST figures
///         that the invariants compare against the live contracts:
///           gIssued        every wei the reserve ever reported delivering (AccrualMaterialized);
///           gRoundingLoss  every sub-unit write-down the rounding cascade allocated;
///           gUnabsorbed    every wei of those write-downs the cascade recorded as unabsorbed
///                          because the senior vault was already exhausted (the write-down still
///                          lowers backing, so this is exactly the deficit I1 then reports);
///           gRealizedLoss  every attested loss the default cascade allocated;
///           i3..i6         violation counters with the offending numbers, evaluated per call from
///                          the pre-call capacities and the post-call events and views.
///
///         Actors: carol (no KYC, no role) drives the four permissionless entries; ops (all
///         operator roles, the harness) originates, funds, services, marks, declares and writes
///         off; alice and bob (KYC'd) mint, stake, queue, claim and redeem.
contract AccrualInvariantHandler is Test {
    // ── wiring ───────────────────────────────────────────────────────────
    struct Wiring {
        address usdc;
        USDfr usdfr;
        ReserveManager reserves;
        MintRedeemController controller;
        SUSDfr vault;
        ClaimBridge bridge;
        AttestationOracle oracle;
        WaterfallEngine waterfall;
        DefaultManager defaultManager;
        RedemptionQueue queue;
        CuratorModule curator;
        SGrove sGrove;
        address ops;
        address alice;
        address bob;
        address carol;
        address borrower;
        uint256 pk1;
        uint256 pk2;
    }

    address internal usdc;
    USDfr internal usdfr;
    ReserveManager internal reserves;
    MintRedeemController internal controller;
    SUSDfr internal vault;
    ClaimBridge internal bridge;
    AttestationOracle internal oracle;
    WaterfallEngine internal waterfall;
    DefaultManager internal defaultManager;
    RedemptionQueue internal queue;
    CuratorModule internal curator;
    SGrove internal sGrove;
    address internal ops;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal borrower;
    uint256 internal pk1;
    uint256 internal pk2;

    uint256 internal constant SCALE = 1e12; // one USDC unit in USDfr wei
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    uint16 internal constant RATE_BPS = 1400;
    uint256 internal constant MAX_LIVE = 4;
    uint256 internal constant MAX_TOTAL = 8;
    /// @dev CLAUDE.md 1.3 / AccrualBook header: the streamed integer slope lags its endpoint
    ///      interpolation by less than one technical segment's duration (at most 365 days of
    ///      wei), and the interpolation differs from the grid-rounded canonical curve by less
    ///      than one reserve grid unit. Per facility, per segment.
    uint256 public constant SEGMENT_BOUND = SCALE + 365 days;

    uint8 internal constant PICK_LIVE = 0;
    uint8 internal constant PICK_PERFORMING = 1;
    uint8 internal constant PICK_DEFAULTED = 2;
    uint8 internal constant PICK_MARKED = 3;
    uint8 internal constant PICK_UNMARKED_PERFORMING = 4;

    // ── facilities the handler funded ────────────────────────────────────
    struct Fac {
        uint256 id;
        bool pik;
        bool marked;
        bool live;
    }

    Fac[] internal facs;

    struct QueueRef {
        address owner;
        uint256 id;
    }

    QueueRef[] internal reqs;

    uint256 internal attNonce;
    uint256 internal payNonce;
    uint256 internal evNonce;

    // ── ghosts ───────────────────────────────────────────────────────────
    uint256 public gIssued;
    uint256 public gRoundingLoss;
    uint256 public gRealizedLoss;
    uint256 public gSeniorBurned;
    uint256 public gClosuresWithRounding;
    uint256 public gUnabsorbed;
    uint256 public nRoundingUnabsorbed; // rounding closures that left a remainder (senior exhausted)

    uint256 public i3Violations;
    string public i3Detail;
    uint256 public i4Violations;
    string public i4Detail;
    uint256 public i5Violations;
    string public i5Detail;
    uint256 public i6Violations;
    string public i6Detail;

    // ── call and refusal census ──────────────────────────────────────────
    uint256 public nWarp;
    uint256 public nCheckpoint;
    uint256 public nCheckpointFresh;
    uint256 public nCheckpointPartial;
    uint256 public nBoundariesProcessed;
    uint256 public nMaterialize;
    uint256 public nMaterializeDelivered;
    uint256 public nPost;
    uint256 public nPosted;
    uint256 public nService;
    uint256 public nServiced;
    uint256 public nOriginate;
    uint256 public nFunded;
    uint256 public nFundedPik;
    uint256 public nRepay;
    uint256 public nRepaySettled;
    uint256 public nRepayFull;
    uint256 public nRepayRecovery;
    uint256 public nMark;
    uint256 public nMarked;
    uint256 public nClear;
    uint256 public nCleared;
    uint256 public nDeclare;
    uint256 public nDeclared;
    uint256 public nLoss;
    uint256 public nLossRealized;
    uint256 public nLossLayer1;
    uint256 public nLossLayer2;
    uint256 public nLossLayer3;
    uint256 public nRoundingLayer1;
    uint256 public nRoundingLayer2;
    uint256 public nRoundingLayer3;
    uint256 public nFirstLoss;
    uint256 public nCoverage;
    uint256 public nMint;
    uint256 public nMinted;
    uint256 public nDeposit;
    uint256 public nDeposited;
    uint256 public nRequest;
    uint256 public nRequested;
    uint256 public nSettle;
    uint256 public nSettled;
    uint256 public nClaimed;
    uint256 public nRedeem;
    uint256 public nRedeemed;

    uint256 public staleRefusals; // AccrualBook_BoundaryPending on a permissionless or user entry
    uint256 public overDebtRefusals; // AccrualLoans_PaymentAboveDebt on the deliberate probe
    uint256 public pastDueRefusals; // NotPastDue / AlreadyPastDue / NotDefaultable / NotPastDueMarked
    uint256 public queueRefusals; // Queue_* on closeEpoch / requestRedeem
    uint256 public nAbsorptionProbes; // deliberate whole-face write-offs above every layer's capacity
    uint256 public absorptionRefusals; // LossExceedsAbsorptionCapacity on that probe (fail-closed, expected)
    uint256 public frozenRefusals; // Queue_ReserveLossSettlementFrozen on closeEpoch: the C-01 deficit signal
    uint256 public frozenWithoutDeficit; // the freeze fired while effective supply was within backing
    string public frozenDetail;
    uint256 public degenerateRefusals; // SUSDfr_DegenerateSharePrice: entry closed on a wiped-out vault (H-3)
    uint256 public degenerateWithoutCause; // that guard fired while the vault still had assets (or no shares)
    string public degenerateDetail;
    uint256 public mintClosedRefusals; // Controller_MintClosedWhileUnderBacked (R16-M3): the same deficit signal
    uint256 public mintClosedWithoutDeficit; // the mint window closed while effective supply was within backing
    string public mintClosedDetail;
    uint256 public parRedeemRefusals; // Controller_SlippageExceeded on redeem(amount)'s par floor: sub-par pricing
    uint256 public parRedeemWithoutDeficit; // a par redemption was quoted below par while supply was within backing
    string public parRedeemDetail;
    uint256 public nRedeemedSubPar; // redemptions settled at the quoted sub-par price after a par refusal
    uint256 public gSubParHaircut; // USDfr wei burned above the USDC value paid on those exits
    uint256 public keeperCheckpoints; // checkpoints the handler ran to make an operator act fresh
    uint256 public revokes; // standing facts retired after a refused action
    uint256 public skipped; // actions with nothing to act on
    uint256 public unexpectedReverts;
    string public lastUnexpected;

    // ── per-call pre-state ───────────────────────────────────────────────
    struct Pre {
        uint256 rate;
        uint256 assets;
        uint256 revision;
        uint256 seniorMark;
        uint256 performanceMark;
        uint256 ts;
        uint256 curatorPool;
        uint256 coverage;
        uint256 vaultAssets;
        uint256 prepaid;
        uint256 vaultBalance; // physical USDfr held by the vault: the senior layer's burnable capacity
        bool exit;
    }

    Pre internal pre;
    /// @dev Whether fee legs are delivered to the vault too (then they add to its capacity).
    bool internal feeToVault;

    struct Legs {
        uint256 interest;
        uint256 principal;
        bool over;
    }

    constructor(Wiring memory w) {
        usdc = w.usdc;
        usdfr = w.usdfr;
        reserves = w.reserves;
        controller = w.controller;
        vault = w.vault;
        bridge = w.bridge;
        oracle = w.oracle;
        waterfall = w.waterfall;
        defaultManager = w.defaultManager;
        queue = w.queue;
        curator = w.curator;
        sGrove = w.sGrove;
        ops = w.ops;
        alice = w.alice;
        bob = w.bob;
        carol = w.carol;
        borrower = w.borrower;
        pk1 = w.pk1;
        pk2 = w.pk2;
        feeToVault = reserves.accrualSnapshot().feeRecipient == address(vault);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  ACTIONS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Time: one second to 120 days, blocks moving with it. One warp in four is followed
    ///         by a keeper batch of ONE, the cadence that leaves boundaries queued behind a fresh
    ///         answer if the keeper's fresh flag ever lies (I5).
    function warp(uint256 secs) external {
        ++nWarp;
        bool keeperOne = secs % 4 == 0;
        secs = bound(secs, 1, 120 days);
        _before(false);
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + secs / 12);
        if (keeperOne) _keeper(1, "warp+checkpoint(1)");
        _after("warp");
    }

    /// @notice carol runs the permissionless keeper with a bounded batch; one call in four uses a
    ///         batch of one, so partial batches over several due boundaries are common.
    function checkpoint(uint256 maximum) external {
        ++nCheckpoint;
        maximum = maximum % 4 == 0 ? 1 : bound(maximum, 1, 32);
        _before(false);
        _keeper(maximum, "checkpoint");
        _after("checkpoint");
    }

    /// @dev One keeper call as carol, with the I5 consistency checks on its answer.
    function _keeper(uint256 maximum, string memory name) internal {
        vm.prank(carol);
        try reserves.checkpointAccrual(maximum) returns (uint256 processed, bool fresh) {
            nBoundariesProcessed += processed;
            if (fresh) {
                ++nCheckpointFresh;
                _assertFreshAfter(name);
            } else {
                ++nCheckpointPartial;
                // I5: an unfresh answer is legitimate only when the batch was exhausted.
                if (processed != maximum) {
                    ++i5Violations;
                    i5Detail = string.concat(
                        name,
                        " returned fresh=false with capacity left: processed ",
                        vm.toString(processed),
                        " of ",
                        vm.toString(maximum)
                    );
                }
            }
        } catch (bytes memory err) {
            _discard();
            _unexpected(name, err);
        }
    }

    /// @notice carol delivers the selected virtual legs.
    function materialize(uint8 legs) external {
        ++nMaterialize;
        legs = uint8(bound(uint256(legs), 1, 3));
        _before(false);
        vm.prank(carol);
        try reserves.materializeAccrued(legs) returns (uint256 senior, uint256 fee) {
            if (senior + fee != 0) ++nMaterializeDelivered;
            _assertFreshAfter("materialize");
        } catch (bytes memory err) {
            _discard();
            if (_isStale(err)) ++staleRefusals;
            else _unexpected("materialize", err);
        }
        _after("materialize");
    }

    /// @notice carol posts one facility's virtual receivable to its recorded face.
    function post(uint256 facSeed) external {
        ++nPost;
        (bool ok, uint256 idx) = _pick(facSeed, PICK_LIVE);
        if (!ok) {
            ++skipped;
            return;
        }
        _before(false);
        vm.prank(carol);
        try reserves.postAccruedLoan(facs[idx].id) returns (uint256 amount) {
            if (amount != 0) ++nPosted;
            _assertFreshAfter("post");
        } catch (bytes memory err) {
            _discard();
            if (_isStale(err)) ++staleRefusals;
            else _unexpected("post", err);
        }
        _after("post");
    }

    /// @notice carol services one facility's signed dormant dates.
    function service(uint256 facSeed) external {
        ++nService;
        (bool ok, uint256 idx) = _pick(facSeed, PICK_LIVE);
        if (!ok) {
            ++skipped;
            return;
        }
        _before(false);
        uint64 dueBefore = reserves.accruedDebt(facs[idx].id).nextCapitalization;
        vm.prank(carol);
        try reserves.serviceAccruedLoan(facs[idx].id) {
            if (reserves.accruedDebt(facs[idx].id).nextCapitalization != dueBefore) ++nServiced;
            _assertFreshAfter("service");
        } catch (bytes memory err) {
            _discard();
            if (_isStale(err)) ++staleRefusals;
            else _unexpected("service", err);
        }
        _after("service");
    }

    /// @notice ops originates a FILM facility through the real 2-of-n gate and funds it: cash
    ///         (14% Actual/360, 30-day coupons, 365-day term), a PIK note (14%, 90-day
    ///         capitalisations, 360-day term, as in FullPikFork), a PIK note capitalising every
    ///         7 days (so several signed boundaries fall due inside one warp and partial keeper
    ///         batches are reachable), or a micro PIK note whose coupon floors to zero on the
    ///         reserve grid, so its signed dates are DORMANT and the servicer entry has work to do.
    function originateAndFund(uint256 principalSeed, uint256 shapeSeed) external {
        ++nOriginate;
        if (_liveCount() >= MAX_LIVE || facs.length >= MAX_TOTAL) {
            ++skipped;
            return;
        }
        _before(false);
        _ensureFresh();
        uint256 shape = shapeSeed % 8;
        bool pik = shape <= 2;
        uint256 units = shape == 2 ? bound(principalSeed, 1, 28) : bound(principalSeed, 50_000e6, 1_000_000e6);
        uint256 principal = units * SCALE;
        if (!_ensureIdle(principal)) {
            ++skipped;
            _after("originate");
            return;
        }
        uint256 id = bridge.totalOriginated() + 1;
        ClaimBridge.OriginationTerms memory t = _terms(id, principal, pik, shape == 1 ? 7 days : 90 days);
        bytes32 h = bridge.creditTermsHash(t);
        if (
            !_attest(id, IAttestationOracle.AttestationKind.AssignmentExecuted, h)
                || !_attest(id, IAttestationOracle.AttestationKind.UCCFiled, h)
                || !_attest(id, IAttestationOracle.AttestationKind.CreditIssued, h)
        ) {
            _after("originate");
            return;
        }
        vm.prank(ops);
        try bridge.originate(ops, t) returns (uint256 minted) {
            if (minted != id) {
                ++unexpectedReverts;
                lastUnexpected = "originate: tokenId drift";
                _after("originate");
                return;
            }
        } catch (bytes memory err) {
            _discard();
            _unexpected("originate", err);
            _after("originate");
            return;
        }
        vm.prank(ops);
        try waterfall.fund(id, units) {
            facs.push(Fac({id: id, pik: pik, marked: false, live: true}));
            ++nFunded;
            if (pik) ++nFundedPik;
            _assertFreshAfter("fund");
        } catch (bytes memory err) {
            _discard();
            _unexpected("fund", err);
        }
        _after("originate");
    }

    /// @notice ops attests and distributes a receipt: an interest-only coupon, a full payoff, a
    ///         bounded partial receipt, or (mode 0) a deliberate probe ONE GRID UNIT ABOVE the
    ///         engine debt, which the engine must refuse with AccrualLoans_PaymentAboveDebt.
    function repay(uint256 facSeed, uint256 interestSeed, uint256 principalSeed, uint256 modeSeed) external {
        ++nRepay;
        (bool ok, uint256 idx) = _pick(facSeed, PICK_LIVE);
        if (!ok) {
            ++skipped;
            return;
        }
        _before(false);
        _ensureFresh();
        Fac storage f = facs[idx];
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(f.id);
        Legs memory l = _chooseLegs(f.pik, d, modeSeed % 8, interestSeed, principalSeed);
        if (l.interest + l.principal == 0) {
            ++skipped;
            _after("repay");
            return;
        }
        bool recovery = _isDefaulted(f.id);
        (bool attested, IWaterfallEngine.Payment memory p) = _preparePayment(f.id, l.interest, l.principal);
        if (!attested) {
            _after("repay");
            return;
        }
        uint256 debtPrincipalCap = f.pik ? d.principal + d.interest : d.principal;
        vm.prank(ops);
        try waterfall.distribute(p) {
            ++nRepaySettled;
            if (recovery) ++nRepayRecovery;
            // I6: an accepted leg above the engine debt read one call earlier is a violation,
            // whether it was the deliberate probe or an ordinary bounded receipt.
            if (l.interest > d.interest || l.principal > debtPrincipalCap) {
                ++i6Violations;
                i6Detail = string.concat(
                    "accepted receipt above engine debt: facility ",
                    vm.toString(f.id),
                    " interest leg ",
                    vm.toString(l.interest),
                    " vs debt interest ",
                    vm.toString(d.interest),
                    ", principal leg ",
                    vm.toString(l.principal),
                    " vs cap ",
                    vm.toString(debtPrincipalCap)
                );
            }
            _assertFreshAfter("repay");
            _syncLive(idx);
            if (!facs[idx].live) ++nRepayFull;
        } catch (bytes memory err) {
            _discard();
            if (l.over && _sel(err) == AccrualLoans.AccrualLoans_PaymentAboveDebt.selector) ++overDebtRefusals;
            else _unexpected("repay", err);
            _revoke(f.id, IAttestationOracle.AttestationKind.PaymentReceived);
        }
        _after("repay");
    }

    /// @notice carol marks a performing facility past due (permissionless accounting mark).
    function markPastDue(uint256 facSeed) external {
        ++nMark;
        (bool ok, uint256 idx) = _pick(facSeed, PICK_UNMARKED_PERFORMING);
        if (!ok) {
            ++skipped;
            return;
        }
        _before(false);
        _ensureFresh();
        vm.prank(carol);
        try defaultManager.markPastDue(facs[idx].id) {
            facs[idx].marked = true;
            ++nMarked;
            _assertFreshAfter("markPastDue");
        } catch (bytes memory err) {
            _discard();
            bytes4 sel = _sel(err);
            if (
                sel == IDefaultManager.DefaultManager_NotPastDue.selector
                    || sel == IDefaultManager.DefaultManager_AlreadyPastDue.selector
                    || sel == IDefaultManager.DefaultManager_NotDefaultable.selector
            ) ++pastDueRefusals;
            else _unexpected("markPastDue", err);
        }
        _after("markPastDue");
    }

    /// @notice ops cures a past-due mark with a real PastDueCured attestation.
    function clearPastDue(uint256 facSeed) external {
        ++nClear;
        (bool ok, uint256 idx) = _pick(facSeed, PICK_MARKED);
        if (!ok) {
            ++skipped;
            return;
        }
        _before(false);
        _ensureFresh();
        uint256 id = facs[idx].id;
        bytes32 evidence = keccak256(abi.encode("inv-cure", id, ++evNonce));
        if (!_attest(id, IAttestationOracle.AttestationKind.PastDueCured, keccak256(abi.encode(id, evidence)))) {
            _after("clearPastDue");
            return;
        }
        vm.prank(ops);
        try defaultManager.clearPastDue(id, evidence) {
            facs[idx].marked = false;
            ++nCleared;
            _assertFreshAfter("clearPastDue");
        } catch (bytes memory err) {
            _discard();
            if (_sel(err) == IDefaultManager.DefaultManager_NotPastDueMarked.selector) {
                ++pastDueRefusals;
                facs[idx].marked = false; // the mark had already been cleared by a repayment
            } else {
                _unexpected("clearPastDue", err);
            }
            _revoke(id, IAttestationOracle.AttestationKind.PastDueCured);
        }
        _after("clearPastDue");
    }

    /// @notice ops declares a default with the evidence-bound attestation.
    function declareDefault(uint256 facSeed) external {
        ++nDeclare;
        (bool ok, uint256 idx) = _pick(facSeed, PICK_PERFORMING);
        if (!ok) {
            ++skipped;
            return;
        }
        _before(false);
        _ensureFresh();
        uint256 id = facs[idx].id;
        bytes32 evidence = keccak256(abi.encode("inv-default", id, ++evNonce));
        if (!_attest(id, IAttestationOracle.AttestationKind.DefaultDeclared, keccak256(abi.encode(id, evidence)))) {
            _after("declareDefault");
            return;
        }
        vm.prank(ops);
        try defaultManager.declareDefault(id, evidence) {
            facs[idx].marked = false;
            ++nDeclared;
            _assertFreshAfter("declareDefault");
        } catch (bytes memory err) {
            _discard();
            _unexpected("declareDefault", err);
            _revoke(id, IAttestationOracle.AttestationKind.DefaultDeclared);
        }
        _after("declareDefault");
    }

    /// @notice ops realises a loss on a defaulted facility, bounded by the outstanding face and
    ///         by the three layers' capacity so the cascade has somewhere to land; one seed in
    ///         four, when the whole face exceeds every layer's capacity, PROBES it anyway: the
    ///         loss cascade must refuse (DefaultManager_LossExceedsAbsorptionCapacity) rather than
    ///         reach past the senior vault into unstaked holders' backing.
    function realizeLoss(uint256 facSeed, uint256 lossSeed) external {
        ++nLoss;
        (bool ok, uint256 idx) = _pick(facSeed, PICK_DEFAULTED);
        if (!ok) {
            ++skipped;
            return;
        }
        _before(false);
        _ensureFresh();
        uint256 id = facs[idx].id;
        uint256 outstanding = reserves.deployedTo(id);
        uint256 cap = pre.curatorPool + pre.coverage + vault.totalAssets();
        // Layer 0 (exit prepayments) can only add to what the cascade absorbs, so the probe stays
        // above it too; `% 4 == 3` never coincides with the whole-face rule (`% 4 == 0`).
        bool probe = lossSeed % 4 == 3 && outstanding > cap + pre.prepaid;
        if (cap > outstanding) cap = outstanding;
        if (cap == 0 && !probe) {
            ++skipped;
            _after("realizeLoss");
            return;
        }
        uint256 loss;
        if (probe) {
            ++nAbsorptionProbes;
            loss = outstanding;
        } else {
            // A servicer writes off whole USDC units, or the whole outstanding face: a sub-unit
            // write-off would leave an off-grid face that no cash receipt can discharge in full.
            loss = lossSeed % 4 == 0 || cap < SCALE ? cap : _grid(bound(lossSeed, SCALE, cap));
        }
        bytes32 evidence = keccak256(abi.encode("inv-loss", id, ++evNonce));
        if (!_attest(id, IAttestationOracle.AttestationKind.LossRealized, keccak256(abi.encode(id, loss, evidence)))) {
            _after("realizeLoss");
            return;
        }
        vm.prank(ops);
        try defaultManager.realizeLoss(id, loss, evidence) {
            ++nLossRealized;
            if (probe) {
                _i3("loss above every layer's capacity was accepted", "realizeLoss", loss, cap + pre.prepaid, 0);
            }
            _assertFreshAfter("realizeLoss");
            _syncLive(idx);
        } catch (bytes memory err) {
            _discard();
            // Only the probe may be refused for capacity: a bounded loss refused this way would mean
            // the cascade absorbs less than the sum of its layers, which is unexpected and counted so.
            if (probe && _sel(err) == IDefaultManager.DefaultManager_LossExceedsAbsorptionCapacity.selector) {
                ++absorptionRefusals;
            } else {
                _unexpected("realizeLoss", err);
            }
            _revoke(id, IAttestationOracle.AttestationKind.LossRealized);
        }
        _after("realizeLoss");
    }

    /// @notice ops posts curator first-loss capital for FILM (layer 1).
    function postFirstLoss(uint256 amountSeed) external {
        ++nFirstLoss;
        uint256 amount = bound(amountSeed, 1e18, 200_000e18) / SCALE * SCALE;
        _before(false);
        _ensureFresh();
        if (!_mintTo(ops, amount / SCALE)) {
            _after("postFirstLoss");
            return;
        }
        vm.prank(ops);
        usdfr.approve(address(curator), amount);
        vm.prank(ops);
        try curator.postFirstLoss(FILM, amount) {
            _assertFreshAfter("postFirstLoss");
        } catch (bytes memory err) {
            _discard();
            _unexpected("postFirstLoss", err);
        }
        _after("postFirstLoss");
    }

    /// @notice ops funds the sGROVE shared coverage reserve (layer 2).
    function fundCoverage(uint256 amountSeed) external {
        ++nCoverage;
        uint256 amount = bound(amountSeed, 1e18, 200_000e18) / SCALE * SCALE;
        _before(false);
        _ensureFresh();
        if (!_mintTo(ops, amount / SCALE)) {
            _after("fundCoverage");
            return;
        }
        vm.prank(ops);
        usdfr.approve(address(sGrove), amount);
        vm.prank(ops);
        try sGrove.fundCoverage(amount) {
            _assertFreshAfter("fundCoverage");
        } catch (bytes memory err) {
            _discard();
            _unexpected("fundCoverage", err);
        }
        _after("fundCoverage");
    }

    /// @notice alice or bob mints USDfr from real USDC. A stale refusal is counted, then the
    ///         keeper runs and the mint is retried once so the action still reaches state.
    function mintUSDfr(uint256 actorSeed, uint256 amountSeed) external {
        ++nMint;
        address actor = _actor(actorSeed);
        uint256 units = bound(amountSeed, 1e6, 500_000e6);
        _before(false);
        deal(usdc, actor, IERC20(usdc).balanceOf(actor) + units);
        vm.prank(actor);
        IERC20(usdc).approve(address(controller), units);
        if (_mintStale(actor, units)) {
            ++staleRefusals;
            _ensureFresh();
            _mintStale(actor, units);
        }
        _after("mint");
    }

    /// @notice alice or bob stakes USDfr into the senior vault, at most 100,000 per action: with the
    ///         whole balance stakeable (up to 500,000 per mint) the vault outgrew every facility and the
    ///         senior-exhaustion region (layer 3 clamps, the capacity probe, the deficit gates) was
    ///         reached in well under one run in a hundred.
    function deposit(uint256 actorSeed, uint256 amountSeed) external {
        ++nDeposit;
        address actor = _actor(actorSeed);
        _before(false);
        if (usdfr.balanceOf(actor) < 1e18) {
            _ensureFresh();
            _mintTo(actor, bound(amountSeed, 1e6, 500_000e6));
        }
        uint256 balance = usdfr.balanceOf(actor);
        if (balance < 1e18) {
            ++skipped;
            _after("deposit");
            return;
        }
        uint256 assets = bound(amountSeed, 1e18, balance < 100_000e18 ? balance : 100_000e18);
        vm.prank(actor);
        usdfr.approve(address(vault), assets);
        if (_depositStale(actor, assets)) {
            ++staleRefusals;
            _ensureFresh();
            _depositStale(actor, assets);
        }
        _after("deposit");
    }

    /// @notice alice or bob queues a redemption of sUSDfr shares worth at least the minimum.
    function requestRedeem(uint256 actorSeed, uint256 sharesSeed) external {
        ++nRequest;
        address actor = _actor(actorSeed);
        uint256 balance = vault.balanceOf(actor);
        if (balance == 0) {
            ++skipped;
            return;
        }
        _before(false);
        uint256 shares = bound(sharesSeed, 1, balance);
        if (vault.previewRedeem(shares) < Config.DEFAULT_MIN_REDEMPTION_VALUE) shares = balance;
        if (vault.previewRedeem(shares) < Config.DEFAULT_MIN_REDEMPTION_VALUE) {
            ++skipped;
            _after("requestRedeem");
            return;
        }
        vm.prank(actor);
        vault.approve(address(queue), shares);
        if (_requestStale(actor, shares)) {
            ++staleRefusals;
            _ensureFresh();
            _requestStale(actor, shares);
        }
        _after("requestRedeem");
    }

    /// @notice The keeper (ops) closes an epoch and every owner claims what was filled.
    function settleQueue(uint256 maxSeed) external {
        ++nSettle;
        if (queue.totalQueuedShares() == 0 && reqs.length == 0) {
            ++skipped;
            return;
        }
        uint256 maximum = bound(maxSeed, 1, 8);
        _before(true);
        if (queue.totalQueuedShares() != 0) {
            if (_closeStale(maximum)) {
                ++staleRefusals;
                _ensureFresh();
                _closeStale(maximum);
            }
        }
        for (uint256 i; i < reqs.length; ++i) {
            (,, uint256 claimable,,) = queue.request(reqs[i].id);
            if (claimable == 0) continue;
            vm.prank(reqs[i].owner);
            try queue.claim(reqs[i].id) {
                ++nClaimed;
            } catch (bytes memory err) {
                _discard();
                _unexpected("claim", err);
            }
        }
        _after("settleQueue");
    }

    /// @notice alice or bob redeems USDfr for real USDC through the controller at par; when the par
    ///         floor refuses (the controller quotes below par, which it may do only under a deficit)
    ///         the holder takes the quoted sub-par exit, as ADR-0034 provides.
    function redeemUSDfr(uint256 actorSeed, uint256 amountSeed) external {
        ++nRedeem;
        address actor = _actor(actorSeed);
        uint256 cap = usdfr.balanceOf(actor);
        uint256 idle = reserves.idleReserve();
        if (idle < cap) cap = idle;
        if (cap < SCALE) {
            ++skipped;
            return;
        }
        _before(false);
        uint256 amount = bound(amountSeed, SCALE, cap) / SCALE * SCALE;
        vm.prank(actor);
        usdfr.approve(address(controller), amount);
        if (_redeemStale(actor, amount)) {
            ++staleRefusals;
            _ensureFresh();
            _redeemStale(actor, amount);
        }
        _after("redeem");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  PRE / POST: ghosts, cascade order, rate integrity
    // ═══════════════════════════════════════════════════════════════════

    function _before(bool exit_) internal {
        pre.rate = vault.currentExchangeRate();
        pre.assets = vault.totalAssets();
        pre.revision = defaultManager.impairmentRevision();
        pre.seniorMark = defaultManager.pendingSeniorImpairment();
        pre.performanceMark = defaultManager.performanceFeeImpairment();
        pre.ts = block.timestamp;
        pre.curatorPool = curator.poolBalance(FILM);
        pre.coverage = sGrove.coverageReserve();
        pre.vaultAssets = pre.assets;
        pre.prepaid = reserves.exitPrepaidAbsorption();
        pre.vaultBalance = usdfr.balanceOf(address(vault));
        pre.exit = exit_;
        vm.recordLogs();
    }

    /// @dev Running figures while walking one call's events.
    struct Walk {
        uint256 seniorBurn;
        uint256 pool;
        uint256 cover;
        uint256 prepaid;
        /// @dev The vault's physical USDfr at each cascade event: pre-call balance, plus every senior
        ///      leg AccrualMaterialized reports minted to it inside the call, minus every burn the
        ///      earlier cascade events of the call took. ReserveRoundingLib.allocate refuses to run
        ///      while any senior claim is still virtual, so this is exactly the `available` it
        ///      clamps the senior layer against; DefaultLossLib reads the same figure to fail closed.
        uint256 seniorCap;
    }

    /// @dev Reads every cascade and delivery event the call emitted, checks the layer order
    ///      against the capacities read before the call (I3), accumulates the ghosts (I2) and
    ///      checks the senior rate against the loss events (I4).
    function _after(string memory name) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Walk memory w = Walk({
            seniorBurn: 0,
            pool: pre.curatorPool,
            cover: pre.coverage,
            prepaid: pre.prepaid,
            seniorCap: pre.vaultBalance
        });
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.topics.length == 0) continue;
            if (log.emitter == address(defaultManager) && log.topics[0] == IDefaultManager.LossRealized.selector) {
                _onLossRealized(name, log.data, w);
            } else if (
                log.emitter == address(reserves)
                    && log.topics[0] == ReserveRoundingLib.AccrualRoundingAllocated.selector
            ) {
                _onRoundingAllocated(name, log.data, w);
            } else if (
                log.emitter == address(reserves) && log.topics[0] == ReserveAccrualLib.AccrualMaterialized.selector
            ) {
                (, uint256 senior, uint256 fee) = abi.decode(log.data, (uint8, uint256, uint256));
                gIssued += senior + fee;
                w.seniorCap += senior + (feeToVault ? fee : 0);
            }
        }
        gSeniorBurned += w.seniorBurn;

        // I4: absent a senior-layer loss and absent a change of the impairment marks (a fee
        // becoming economically due), the fee-net rate never falls; and in a call that is not
        // an exit and does not move time, vault assets fall by at most the senior burn.
        bool marksUnchanged = defaultManager.impairmentRevision() == pre.revision
            && defaultManager.pendingSeniorImpairment() == pre.seniorMark
            && defaultManager.performanceFeeImpairment() == pre.performanceMark;
        uint256 rate = vault.currentExchangeRate();
        if (w.seniorBurn == 0 && marksUnchanged && rate < pre.rate) {
            _i4(name, "fee-net rate fell without a senior loss", pre.rate, rate);
        }
        if (!pre.exit && block.timestamp == pre.ts) {
            uint256 assets = vault.totalAssets();
            if (assets + w.seniorBurn < pre.assets) {
                _i4(name, "vault assets fell by more than the senior burn", pre.assets, assets + w.seniorBurn);
            }
        }
    }

    /// @dev LossRealized(tokenId, classId, loss, curatorAbsorbed, backstopCovered, depositorLoss).
    function _onLossRealized(string memory name, bytes memory data, Walk memory w) internal {
        (uint256 loss, uint256 absorbed, uint256 covered, uint256 depositor) =
            abi.decode(data, (uint256, uint256, uint256, uint256));
        gRealizedLoss += loss;
        w.seniorBurn += depositor;
        uint256 used = loss - absorbed - covered - depositor; // layer 0: exit prepayments
        if (used > w.prepaid) _i3("prepayment above the recorded exit prepayment", name, loss, used, w.prepaid);
        w.prepaid -= used > w.prepaid ? w.prepaid : used;
        uint256 rest = _checkJuniorOrder(name, loss - used, absorbed, covered, w);
        // Layer 3 FAILS CLOSED (DefaultLossLib.realizeLoss): the senior vault takes exactly the rest
        // and is never charged past its assets; a loss the three layers cannot carry must revert
        // rather than reach unstaked holders' backing.
        if (depositor != rest) _i3("layer 3 (senior) took the wrong amount", name, rest, depositor, rest);
        if (depositor > w.seniorCap) {
            _i3("layer 3 (senior) charged past the vault's assets", name, rest, depositor, w.seniorCap);
        }
        w.seniorCap -= depositor > w.seniorCap ? w.seniorCap : depositor;
        if (absorbed != 0) ++nLossLayer1;
        if (covered != 0) ++nLossLayer2;
        if (depositor != 0) ++nLossLayer3;
    }

    /// @dev AccrualRoundingAllocated(facilityId, closureNonce, amount, prepaid, curator, backstop,
    ///      senior, unabsorbed, markConsumed).
    function _onRoundingAllocated(string memory name, bytes memory data, Walk memory w) internal {
        (uint256 amount, uint256 used, uint256 cur, uint256 back, uint256 senior, uint256 unabsorbed,) =
            abi.decode(data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256));
        gRoundingLoss += amount;
        ++gClosuresWithRounding;
        w.seniorBurn += senior;
        // The documented sub-grid bound: a closure discrepancy is below one grid unit.
        if (amount >= SCALE) _i4(name, "rounding closure at or above one grid unit", amount, SCALE);
        if (used > w.prepaid) {
            _i3("rounding prepayment above the recorded exit prepayment", name, amount, used, w.prepaid);
        }
        w.prepaid -= used > w.prepaid ? w.prepaid : used;
        uint256 rest = _checkJuniorOrder(name, amount - used, cur, back, w);
        // Layer 3 is CLAMPED at the vault's assets (ReserveRoundingLib.allocate, build log
        // 2026-09-12 18:04: "then available senior assets, recording any unabsorbed remainder"):
        // the senior vault takes min(rest, capacity), the event's remainder is exactly what it
        // could not take, and a remainder may stand ONLY when this allocation exhausted the layer.
        // Whether a standing remainder is acceptable is I1's question (it is the deficit), not I3's.
        uint256 expectSenior = rest < w.seniorCap ? rest : w.seniorCap;
        if (senior != expectSenior) _i3("layer 3 (senior) took the wrong amount", name, rest, senior, expectSenior);
        uint256 taken = senior < rest ? senior : rest;
        if (unabsorbed != rest - taken) {
            _i3("unabsorbed != the remainder past the senior layer", name, rest, senior, unabsorbed);
        }
        if (unabsorbed != 0 && senior < w.seniorCap) {
            _i3("rounding loss left unabsorbed with senior assets standing", name, amount, senior, w.seniorCap);
        }
        w.seniorCap -= senior < w.seniorCap ? senior : w.seniorCap;
        gUnabsorbed += unabsorbed;
        if (unabsorbed != 0) ++nRoundingUnabsorbed;
        if (cur != 0) ++nRoundingLayer1;
        if (back != 0) ++nRoundingLayer2;
        if (senior != 0) ++nRoundingLayer3;
    }

    /// @dev Junior layer order for one cascade event, given the capacities standing before it:
    ///      the curator pool takes min(allocatable, pool), sGROVE takes min(residual, coverage).
    ///      Returns what is left for the senior layer; the caller checks that leg, because the two
    ///      cascades treat it differently (loss: exact and fail-closed; rounding: clamped).
    function _checkJuniorOrder(
        string memory name,
        uint256 allocatable,
        uint256 absorbed,
        uint256 covered,
        Walk memory w
    ) internal returns (uint256 rest) {
        uint256 expectAbsorbed = allocatable < w.pool ? allocatable : w.pool;
        if (absorbed != expectAbsorbed) {
            _i3("layer 1 (curator) took the wrong amount", name, allocatable, absorbed, expectAbsorbed);
        }
        uint256 residual = allocatable - (absorbed < allocatable ? absorbed : allocatable);
        uint256 expectCovered = residual < w.cover ? residual : w.cover;
        if (covered != expectCovered) {
            _i3("layer 2 (sGROVE) took the wrong amount", name, residual, covered, expectCovered);
        }
        rest = residual - (covered < residual ? covered : residual);
        w.pool -= absorbed < w.pool ? absorbed : w.pool;
        w.cover -= covered < w.cover ? covered : w.cover;
    }

    function _i3(string memory what, string memory name, uint256 a, uint256 b, uint256 c) internal {
        ++i3Violations;
        i3Detail = string.concat(what, " in ", name, ": ", vm.toString(a), " / ", vm.toString(b), " / ", vm.toString(c));
    }

    function _i4(string memory name, string memory what, uint256 before_, uint256 after_) internal {
        ++i4Violations;
        i4Detail = string.concat(what, " in ", name, ": ", vm.toString(before_), " -> ", vm.toString(after_));
    }

    /// @dev I5: every successful rate-changing action leaves the book fresh at block.timestamp.
    function _assertFreshAfter(string memory name) internal {
        IContinuousAccrual.Snapshot memory s = reserves.accrualSnapshot();
        if (!s.fresh || s.accruedThrough != block.timestamp) {
            ++i5Violations;
            i5Detail = string.concat(
                "book not fresh after ",
                name,
                ": accruedThrough ",
                vm.toString(uint256(s.accruedThrough)),
                " vs now ",
                vm.toString(block.timestamp)
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //  helpers
    // ═══════════════════════════════════════════════════════════════════

    /// @dev Brings the book current the way an operator's keeper would before a priced act.
    function _ensureFresh() internal {
        for (uint256 i; i < 8; ++i) {
            if (reserves.accrualSnapshot().fresh) return;
            vm.prank(carol);
            try reserves.checkpointAccrual(32) returns (uint256 processed, bool) {
                ++keeperCheckpoints;
                nBoundariesProcessed += processed;
            } catch (bytes memory err) {
                _discard();
                _unexpected("keeper checkpoint", err);
                return;
            }
        }
    }

    /// @dev Tops the idle reserve up for a funding; false when the mint window is closed (a deficit).
    function _ensureIdle(uint256 principal) internal returns (bool) {
        uint256 idle = reserves.idleReserve();
        if (idle >= principal + 1e18) return true;
        return _mintTo(alice, (principal + 1e18 - idle) / SCALE + 1);
    }

    /// @dev Mints `units` USDC worth of USDfr to a KYC'd actor on a fresh book; false on failure.
    function _mintTo(address actor, uint256 units) internal returns (bool) {
        deal(usdc, actor, IERC20(usdc).balanceOf(actor) + units);
        vm.prank(actor);
        IERC20(usdc).approve(address(controller), units);
        vm.prank(actor);
        try controller.mint(units) {
            return true;
        } catch (bytes memory err) {
            _discard();
            if (!_mintClosed("mint (helper)", err)) _unexpected("mint (helper)", err);
            return false;
        }
    }

    /// @dev R16-M3: the par mint window is closed whenever effective supply exceeds backing. Like the
    ///      C-01 freeze it is the protocol's own deficit signal, counted on its own and allowed only
    ///      under a real deficit (invariant_C01). Returns true when the revert was that gate.
    function _mintClosed(string memory name, bytes memory err) internal returns (bool) {
        if (_sel(err) != IMintRedeemController.Controller_MintClosedWhileUnderBacked.selector) return false;
        ++mintClosedRefusals;
        uint256 supply = controller.totalUSDfr();
        uint256 backing = controller.backingValue();
        if (supply <= backing) {
            ++mintClosedWithoutDeficit;
            mintClosedDetail = string.concat(
                name,
                " closed without a deficit: effective supply ",
                vm.toString(supply),
                " backing ",
                vm.toString(backing)
            );
        }
        return true;
    }

    /// @dev Returns true when the call was refused as stale and should be retried.
    function _mintStale(address actor, uint256 units) internal returns (bool) {
        vm.prank(actor);
        try controller.mint(units) {
            ++nMinted;
            _assertFreshAfter("mint");
            return false;
        } catch (bytes memory err) {
            _discard();
            if (_isStale(err)) return true;
            if (!_mintClosed("mint", err)) _unexpected("mint", err);
            return false;
        }
    }

    function _depositStale(address actor, uint256 assets) internal returns (bool) {
        vm.prank(actor);
        try vault.deposit(assets, actor) {
            ++nDeposited;
            _assertFreshAfter("deposit");
            return false;
        } catch (bytes memory err) {
            _discard();
            if (_isStale(err)) return true;
            if (_sel(err) == SUSDfr.SUSDfr_DegenerateSharePrice.selector) {
                // Documented fail-closed entry guard: the zero deposit base (audit H-3) and the
                // collapsed-price band below par / SUSDFR_DEGENERATE_RATE_DIVISOR (audit R15-01),
                // which the main-tree run of 2026-09-16 reached after a senior wipe-out followed by
                // a small re-accrual (assets 22,604e18 against 7.09e30 shares). `maxDeposit` reports
                // 0 in exactly the states `_isDegenerate()` closes, so that is the cause check; a
                // refusal while `maxDeposit` is non-zero would be the guard firing outside its band.
                ++degenerateRefusals;
                if (vault.maxDeposit(actor) != 0 || vault.totalSupply() == 0) {
                    ++degenerateWithoutCause;
                    degenerateDetail = string.concat(
                        "deposit refused as degenerate with assets ",
                        vm.toString(vault.totalAssets()),
                        " and shares ",
                        vm.toString(vault.totalSupply())
                    );
                }
                return false;
            }
            _unexpected("deposit", err);
            return false;
        }
    }

    function _requestStale(address actor, uint256 shares) internal returns (bool) {
        vm.prank(actor);
        try queue.requestRedeem(shares) returns (uint256 id) {
            reqs.push(QueueRef({owner: actor, id: id}));
            ++nRequested;
            _assertFreshAfter("requestRedeem");
            return false;
        } catch (bytes memory err) {
            _discard();
            if (_isStale(err)) return true;
            if (_sel(err) == IRedemptionQueue.Queue_BelowMinRedemption.selector) ++queueRefusals;
            else _unexpected("requestRedeem", err);
            return false;
        }
    }

    function _closeStale(uint256 maximum) internal returns (bool) {
        vm.prank(ops);
        try queue.closeEpoch(maximum) {
            ++nSettled;
            _assertFreshAfter("closeEpoch");
            return false;
        } catch (bytes memory err) {
            _discard();
            if (_isStale(err)) return true;
            bytes4 sel = _sel(err);
            if (sel == IRedemptionQueue.Queue_ReserveLossSettlementFrozen.selector) {
                // The C-01 interlock is the protocol's own deficit signal, not a queue refusal: it is
                // counted on its own so the freeze stays visible, and it may fire only while
                // effective supply exceeds backing (invariant_C01).
                ++frozenRefusals;
                uint256 supply = controller.totalUSDfr();
                uint256 backing = controller.backingValue();
                if (supply <= backing) {
                    ++frozenWithoutDeficit;
                    frozenDetail = string.concat(
                        "closeEpoch frozen without a deficit: effective supply ",
                        vm.toString(supply),
                        " backing ",
                        vm.toString(backing)
                    );
                }
            } else if (
                sel == IRedemptionQueue.Queue_EpochNotOver.selector
                    || sel == IRedemptionQueue.Queue_AllInCooldown.selector
                    || sel == IRedemptionQueue.Queue_NoLiquidity.selector
                    || sel == IRedemptionQueue.Queue_HeadNotRedeemable.selector
            ) {
                ++queueRefusals;
            } else {
                _unexpected("closeEpoch", err);
            }
            return false;
        }
    }

    function _redeemStale(address actor, uint256 amount) internal returns (bool) {
        vm.prank(actor);
        try controller.redeem(amount) {
            ++nRedeemed;
            _assertFreshAfter("redeem");
            return false;
        } catch (bytes memory err) {
            _discard();
            if (_isStale(err)) return true;
            if (_sel(err) == IMintRedeemController.Controller_SlippageExceeded.selector) {
                _subParRedeem(actor, amount);
                return false;
            }
            _unexpected("redeem", err);
            return false;
        }
    }

    /// @dev The par floor of `redeem(amount)` was refused: the controller quotes below par, which is
    ///      legitimate only while effective supply exceeds backing (invariant_C01). The holder then
    ///      exits at the quoted price; the haircut is what the exit burns above what it is paid.
    function _subParRedeem(address actor, uint256 amount) internal {
        ++parRedeemRefusals;
        uint256 supply = controller.totalUSDfr();
        uint256 backing = controller.backingValue();
        if (supply <= backing) {
            ++parRedeemWithoutDeficit;
            parRedeemDetail = string.concat(
                "redeem quoted below par without a deficit: effective supply ",
                vm.toString(supply),
                " backing ",
                vm.toString(backing)
            );
        }
        (uint256 quote, uint256 usdfrIn) = controller.previewRedeem(amount);
        if (quote == 0) {
            ++skipped;
            return;
        }
        vm.prank(actor);
        try controller.redeem(amount, quote) {
            ++nRedeemedSubPar;
            gSubParHaircut += usdfrIn - quote * SCALE;
            _assertFreshAfter("redeem (sub-par)");
        } catch (bytes memory err) {
            _discard();
            _unexpected("redeem (sub-par)", err);
        }
    }

    function _chooseLegs(bool pik, IAccrualLifecycle.Debt memory d, uint256 mode, uint256 iSeed, uint256 pSeed)
        internal
        pure
        returns (Legs memory l)
    {
        // Every leg is floored to the USDC grid: the reserve settles cash in whole units, and a
        // face left off-grid by a sub-unit write-off is repaid down to its last whole unit.
        if (mode == 0) {
            l.over = true;
            if (pik) l.principal = _grid(d.principal + d.interest) + SCALE;
            else l.interest = _grid(d.interest) + SCALE;
        } else if (mode == 1) {
            if (pik) l.principal = _grid(d.interest);
            else l.interest = _grid(d.interest);
        } else if (mode == 2) {
            if (pik) {
                l.principal = _grid(d.principal + d.interest);
            } else {
                l.interest = _grid(d.interest);
                l.principal = _grid(d.principal);
            }
        } else {
            if (pik) {
                l.principal = _grid(bound(pSeed, 0, d.principal + d.interest));
            } else {
                l.interest = _grid(bound(iSeed, 0, d.interest));
                l.principal = _grid(bound(pSeed, 0, d.principal));
            }
        }
    }

    function _grid(uint256 x) internal pure returns (uint256) {
        return x / SCALE * SCALE;
    }

    /// @dev Funds and approves the borrower, then attests the receipt. Returns the payment.
    function _preparePayment(uint256 id, uint256 interest, uint256 principal)
        internal
        returns (bool attested, IWaterfallEngine.Payment memory p)
    {
        uint256 stableAmount = (interest + principal) / SCALE;
        deal(usdc, borrower, IERC20(usdc).balanceOf(borrower) + stableAmount);
        vm.prank(borrower);
        IERC20(usdc).approve(address(reserves), stableAmount);
        ClaimBridge.Facility memory f = bridge.facility(id);
        uint64 nextDue = f.nextPaymentDue;
        if (!f.pik && nextDue < f.maturity) {
            nextDue = f.nextPaymentDue + f.paymentInterval;
            if (nextDue > f.maturity) nextDue = f.maturity;
        }
        bytes32 paymentId = keccak256(abi.encode("inv-payment", id, ++payNonce));
        p = IWaterfallEngine.Payment({
            tokenId: id,
            paymentId: paymentId,
            payer: borrower,
            interest: interest,
            principal: principal,
            nextPaymentDue: nextDue
        });
        attested = _attest(
            id,
            IAttestationOracle.AttestationKind.PaymentReceived,
            keccak256(abi.encode(paymentId, id, usdc, borrower, stableAmount, interest, principal, nextDue))
        );
    }

    function _terms(uint256 id, uint256 principal, bool pik, uint64 pikInterval)
        internal
        view
        returns (ClaimBridge.OriginationTerms memory t)
    {
        uint64 interval = pik ? pikInterval : 30 days;
        uint64 term = pik ? 360 days : 365 days;
        t = ClaimBridge.OriginationTerms({
            classId: FILM,
            borrowerId: keccak256(abi.encode("inv-borrower", id)),
            stateId: keccak256("US-GA"),
            principal: principal,
            ltvBps: 7500,
            interestRateBps: RATE_BPS,
            maturity: uint64(block.timestamp) + term,
            fundingRecipient: borrower,
            paymentInterval: interval,
            nextPaymentDue: uint64(block.timestamp) + interval,
            rateType: ClaimBridge.RateType.Fixed,
            dayCountConvention: ClaimBridge.DayCountConvention.Actual360,
            renewable: false,
            paymentScheduleHash: keccak256("inv-schedule"),
            rateIndexRef: bytes32(0),
            renewalTermsHash: bytes32(0),
            offchainRef: keccak256(abi.encode("inv-ref", id)),
            pik: pik
        });
    }

    /// @dev A REAL 2-of-n EIP-712 attestation, relayed through an external self-call so a
    ///      refusal is counted rather than reverting the handler.
    function _attest(uint256 id, IAttestationOracle.AttestationKind kind, bytes32 payload) internal returns (bool) {
        IAttestationOracle.AttestationInput memory a = IAttestationOracle.AttestationInput({
            facilityId: id,
            kind: kind,
            payload: payload,
            asOf: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 1 hours),
            nonce: ++attNonce
        });
        bytes32 digest = oracle.attestationDigest(a);
        (uint256 lo, uint256 hi) = vm.addr(pk1) < vm.addr(pk2) ? (pk1, pk2) : (pk2, pk1);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(lo, digest);
        sigs[1] = _sign(hi, digest);
        try this.relayAttestation(a, sigs) {
            return true;
        } catch (bytes memory err) {
            _discard();
            _unexpected("attest", err);
            return false;
        }
    }

    /// @dev Self-call target for `_attest`; nobody else may use the handler as a relay.
    function relayAttestation(IAttestationOracle.AttestationInput calldata a, bytes[] calldata sigs) external {
        if (msg.sender != address(this)) revert("handler: self only");
        oracle.attest(a, sigs);
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Retires the standing fact a refused action left behind, so the facility stays usable.
    function _revoke(uint256 id, IAttestationOracle.AttestationKind kind) internal {
        vm.prank(ops);
        try oracle.revoke(id, kind) {
            ++revokes;
        } catch (bytes memory err) {
            _discard();
            _unexpected("revoke", err);
        }
    }

    function _pick(uint256 seed, uint8 kind) internal view returns (bool, uint256) {
        uint256 n = facs.length;
        if (n == 0) return (false, 0);
        uint256 start = seed % n;
        for (uint256 k; k < n; ++k) {
            uint256 i = (start + k) % n;
            Fac storage f = facs[i];
            if (!f.live) continue;
            ClaimBridge.LoanState state = bridge.facility(f.id).state;
            bool performing = state == ClaimBridge.LoanState.Active || state == ClaimBridge.LoanState.Amortizing;
            bool defaulted = state == ClaimBridge.LoanState.Defaulted || state == ClaimBridge.LoanState.Accelerated;
            if (kind == PICK_LIVE && (performing || defaulted)) return (true, i);
            if (kind == PICK_PERFORMING && performing) return (true, i);
            if (kind == PICK_DEFAULTED && defaulted) return (true, i);
            if (kind == PICK_MARKED && f.marked && performing) return (true, i);
            if (kind == PICK_UNMARKED_PERFORMING && !f.marked && performing) return (true, i);
        }
        return (false, 0);
    }

    function _isDefaulted(uint256 id) internal view returns (bool) {
        ClaimBridge.LoanState state = bridge.facility(id).state;
        return state == ClaimBridge.LoanState.Defaulted || state == ClaimBridge.LoanState.Accelerated;
    }

    function _syncLive(uint256 idx) internal {
        ClaimBridge.LoanState state = bridge.facility(facs[idx].id).state;
        if (state == ClaimBridge.LoanState.Repaid || state == ClaimBridge.LoanState.Resolved) {
            facs[idx].live = false;
            facs[idx].marked = false;
        }
    }

    function _liveCount() internal view returns (uint256 n) {
        for (uint256 i; i < facs.length; ++i) {
            if (facs[i].live) ++n;
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return seed % 2 == 0 ? alice : bob;
    }

    function _isStale(bytes memory err) internal pure returns (bool) {
        return _sel(err) == AccrualBook.AccrualBook_BoundaryPending.selector;
    }

    function _sel(bytes memory err) internal pure returns (bytes4 sel) {
        if (err.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            sel := mload(add(err, 32))
        }
    }

    /// @dev `vm.getRecordedLogs()` retains the logs of a call that REVERTED (the chain does not),
    ///      so the events of a refused call must be dropped before the ghosts read them: the
    ///      campaign's first counterexample was a delivery materialised inside a receipt that
    ///      `AccrualLoans_PaymentAboveDebt` then rolled back.
    function _discard() internal {
        vm.getRecordedLogs();
        vm.recordLogs();
    }

    function _unexpected(string memory name, bytes memory err) internal {
        ++unexpectedReverts;
        lastUnexpected = string.concat(
            name, ": selector ", vm.toString(abi.encodePacked(_sel(err))), " (", vm.toString(err.length), " bytes)"
        );
    }

    // ── views for the harness ────────────────────────────────────────────

    function facilityTotal() external view returns (uint256) {
        return facs.length;
    }

    function facilityAt(uint256 i) external view returns (uint256 id, bool pik, bool marked, bool live) {
        Fac storage f = facs[i];
        return (f.id, f.pik, f.marked, f.live);
    }

    function requestCount() external view returns (uint256) {
        return reqs.length;
    }
}

/// @title ATK_AccrualInvariantFork: STATEFUL invariants of the continuous-accrual engine, driven
///        through arbitrary interleavings on the FULL protocol on a pinned mainnet fork.
///
/// @notice The six ATK_* suites attack one mechanism at a time from a chosen state. This suite
///         lets the fuzzer choose the state: up to four live FILM facilities (cash, 90-day PIK,
///         weekly PIK and a dormant micro-PIK), keeper cadence and materialisation legs picked by
///         carol, coupons,
///         payoffs, partial receipts and deliberate over-debt probes, past-due marks and cures,
///         declarations, bounded write-offs, curator and sGROVE capital, senior deposits, queue
///         exits after the 21-day cooldown and USDC redemptions, in any order, with time moving
///         by one second to 120 days between them. After every call the invariants below are
///         evaluated against the live contracts and the handler's ghosts (CLAUDE.md 1.3):
///           I1  backing: physical and effective supply within backing; effective supply equals
///               backing to the wei; backing reconciles to idle plus every facility's face;
///           I2  value conservation of the accrual book: gross == delivered + unissued; the
///               portfolio clock equals the sum of the facility clocks; deployed principal equals
///               the sum of the facility faces;
///           I3  loss cascade order: every realised loss and every rounding correction landed on
///               the curator first, then sGROVE, then senior, each layer taking exactly its
///               capacity before the next was touched; the loss cascade never charges the senior
///               vault past its assets (it fails closed instead, and a probe above capacity must
///               be refused); the rounding cascade leaves a remainder only once the senior layer
///               is exhausted;
///           I4  sUSDfr rate integrity: absent a senior-layer loss (or a fee becoming due through
///               an impairment mark) the fee-net rate never falls; every rounding closure is
///               below one grid unit; vault assets never fall by more than the senior burn;
///           I5  freshness: every successful rate-changing action leaves accruedThrough at
///               block.timestamp; a partial keeper batch is unfresh only when exhausted;
///           I6  no accepted repayment leg ever exceeded the engine debt;
///           I7  per facility, the streamed face and the canonical debt agree within the
///               documented per-segment bound (one grid unit plus 365 days of wei);
///           C01 the fail-closed deficit gates (the RedemptionQueue.closeEpoch and curator
///               withdrawal interlock, the controller's par mint window, the par floor of
///               redeem(amount)) are armed exactly when effective supply exceeds backing, and never
///               refused a settlement, a mint or a par exit while supply was within backing;
///           and no handler action ever reverted for an unlisted reason.
///
///         KNOWN RED ON UNMODIFIED CONTRACTS (report section R4). With the senior vault exhausted
///         by earlier write-offs, a sub-unit rounding closure on another facility leaves a
///         remainder the cascade cannot burn; the write-down still lowers backing by the whole
///         discrepancy, so effective supply exceeds backing by that remainder and the C-01
///         interlock arms. I1 fails there by design of THIS suite: per CLAUDE.md 1.3 an invariant
///         that cannot be made to hold is surfaced, not weakened. `test_finding_*` pins the state
///         deterministically with its exact numbers so the record does not depend on the seed.
///
///         REACH is proven by the deterministic tests below, one per handler action, each of
///         which drives the action once and asserts the state it changed. Ghost counters reset
///         per run, so reach cannot be read from the campaign; it is proven by mutation of the
///         state, not by reading the handler. `test_observation_*` pins a behaviour the campaign
///         surfaced on unmodified code, so the record carries its exact numbers.
///
///         Run: forge test --match-path test/fork/ATK_AccrualInvariantFork.t.sol (default profile,
///         256 runs x depth 128, fail_on_revert = true; handlers never revert).
contract ATK_AccrualInvariantForkTest is ForkLifecycleFixture {
    AccrualInvariantHandler internal handler;

    function setUp() public override {
        super.setUp();
        if (!forkReady) return;
        handler = new AccrualInvariantHandler(
            AccrualInvariantHandler.Wiring({
                usdc: USDC,
                usdfr: usdfr,
                reserves: reserves,
                controller: controller,
                vault: vault,
                bridge: bridge,
                oracle: oracle,
                waterfall: waterfall,
                defaultManager: defaultManager,
                queue: queue,
                curator: curator,
                sGrove: sGrove,
                ops: ops,
                alice: alice,
                bob: bob,
                carol: carol,
                borrower: borrower,
                pk1: PK1,
                pk2: PK2
            })
        );
        // The senior vault has a price to defend from the first call: alice mints 3,000,000 and
        // stakes 2,000,000, as every ATK_* suite does.
        _mintFromUSDC(alice, 3_000_000e6);
        _stake(alice, 2_000_000e18);

        targetContract(address(handler));
        // EVERY action is registered explicitly (this repository has shipped invariants whose
        // action was never driven because its selector was missing from the list).
        bytes4[] memory selectors = new bytes4[](18);
        selectors[0] = AccrualInvariantHandler.warp.selector;
        selectors[1] = AccrualInvariantHandler.checkpoint.selector;
        selectors[2] = AccrualInvariantHandler.materialize.selector;
        selectors[3] = AccrualInvariantHandler.post.selector;
        selectors[4] = AccrualInvariantHandler.service.selector;
        selectors[5] = AccrualInvariantHandler.originateAndFund.selector;
        selectors[6] = AccrualInvariantHandler.repay.selector;
        selectors[7] = AccrualInvariantHandler.markPastDue.selector;
        selectors[8] = AccrualInvariantHandler.clearPastDue.selector;
        selectors[9] = AccrualInvariantHandler.declareDefault.selector;
        selectors[10] = AccrualInvariantHandler.realizeLoss.selector;
        selectors[11] = AccrualInvariantHandler.postFirstLoss.selector;
        selectors[12] = AccrualInvariantHandler.fundCoverage.selector;
        selectors[13] = AccrualInvariantHandler.mintUSDfr.selector;
        selectors[14] = AccrualInvariantHandler.deposit.selector;
        selectors[15] = AccrualInvariantHandler.requestRedeem.selector;
        selectors[16] = AccrualInvariantHandler.settleQueue.selector;
        selectors[17] = AccrualInvariantHandler.redeemUSDfr.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  INVARIANTS (CLAUDE.md 1.3)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice I1 (backing invariant). USDfr supply, physical and effective, never exceeds the
    ///         canonical backing view; and effective supply equals backing to the wei, because
    ///         every flow on this fixture moves both sides together (mint, redeem, receipt,
    ///         accrual, delivery, posting, and the two cascades pair every burn with a write-down).
    function invariant_I1_supplyWithinBackingAndEffectiveSupplyEqualsBacking() public onFork {
        uint256 backing = reserves.totalBackingValue();
        uint256 effective = controller.totalUSDfr();
        assertLe(usdfr.totalSupply(), backing, "I1: physical supply exceeds backing");
        // The message carries the mechanism: on this fixture the only way effective supply gets
        // above backing is a rounding remainder the exhausted senior layer could not burn.
        assertLe(
            effective,
            backing,
            string.concat(
                "I1: effective supply exceeds backing by ",
                vm.toString(effective > backing ? effective - backing : 0),
                " wei (rounding remainder unabsorbed ",
                vm.toString(reserves.roundingLossUnabsorbed()),
                ", exit interlock ",
                reserves.reserveLossExitsLocked() ? "ARMED" : "off",
                ")"
            )
        );
        assertEq(effective, backing, "I1: effective supply != backing to the wei");
        IContinuousAccrual.Snapshot memory s = reserves.accrualSnapshot();
        assertEq(
            controller.totalUSDfr(), usdfr.totalSupply() + s.unissued, "I1: effective supply != physical + unissued"
        );
    }

    /// @notice I1 (reserve accounting reconciles to its parts). Backing equals idle plus the
    ///         sum of every facility's effective face less recorded impairment; the aggregate
    ///         carrier and the per-facility carriers must agree without double counting.
    function invariant_I1_backingReconcilesToIdlePlusFacilityFaces() public onFork {
        uint256 faces;
        uint256 n = handler.facilityTotal();
        for (uint256 i; i < n; ++i) {
            (uint256 id,,,) = handler.facilityAt(i);
            faces += reserves.deployedTo(id);
        }
        assertEq(
            reserves.totalBackingValue(),
            reserves.normalizeUSDC(reserves.idleUSDC()) + faces - reserves.totalPrincipalImpairment(),
            "I1: backing != idle + sum of facility faces - impairment"
        );
    }

    /// @notice I2 (value conservation of the accrual book). Recognised gross equals everything
    ///         the reserve ever reported delivering plus what is still unissued; the portfolio
    ///         clock equals the sum of the facility clocks; deployed principal equals the sum of
    ///         the facility faces. Nothing is created by keeper cadence or destroyed by delivery.
    function invariant_I2_accrualBookConservesValue() public onFork {
        IContinuousAccrual.Snapshot memory s = reserves.accrualSnapshot();
        assertEq(s.gross, handler.gIssued() + s.unissued, "I2: gross != delivered + unissued");
        uint256 unposted;
        uint256 faces;
        uint256 n = handler.facilityTotal();
        for (uint256 i; i < n; ++i) {
            (uint256 id,,,) = handler.facilityAt(i);
            unposted += reserves.unpostedAccruedLoan(id);
            faces += reserves.deployedTo(id);
        }
        assertEq(s.unposted, unposted, "I2: portfolio unposted != sum of facility unposted");
        assertEq(reserves.deployedPrincipal(), faces, "I2: deployed principal != sum of facility faces");
    }

    /// @notice I3 (loss cascade ordering). Every LossRealized and every AccrualRoundingAllocated
    ///         event took the curator pool first, then sGROVE, then senior, each to exactly its
    ///         standing capacity, never skipping a layer with capacity and never charging one
    ///         beyond it; nothing was left unabsorbed while senior assets stood.
    function invariant_I3_cascadeNeverSkipsOrInvertsALayer() public onFork {
        assertEq(handler.i3Violations(), 0, handler.i3Detail());
    }

    /// @notice I4 (sUSDfr fee-net exchange-rate integrity). Yield alone never lowers the rate:
    ///         with no senior-layer loss and no impairment-mark change in the call, the fee-net
    ///         rate is monotone; every rounding closure is below one grid unit; and outside exits
    ///         the vault's assets fall by at most the senior burn the events account for.
    function invariant_I4_rateMonotoneAbsentSeniorLoss() public onFork {
        assertEq(handler.i4Violations(), 0, handler.i4Detail());
    }

    /// @notice I5 (freshness). After every successful rate-changing action the book's
    ///         accruedThrough equals block.timestamp and the snapshot is fresh; a keeper batch
    ///         may report unfresh only when it processed its whole maximum.
    function invariant_I5_bookFreshAfterEveryRateChangingAction() public onFork {
        assertEq(handler.i5Violations(), 0, handler.i5Detail());
    }

    /// @notice I6 (receipt bound). No accepted repayment leg ever exceeded the engine debt read
    ///         immediately before the receipt; the deliberate one-grid-unit-over probe is refused.
    function invariant_I6_noReceiptLegAboveEngineDebt() public onFork {
        assertEq(handler.i6Violations(), 0, handler.i6Detail());
    }

    /// @notice I7 (streamed vs canonical). For every facility the reserve's streamed face and the
    ///         canonical principal plus interest agree within one grid unit plus one segment's
    ///         worth of integer-slope lag, through the same coherent frontier.
    function invariant_I7_streamedFaceTracksCanonicalDebtWithinSegmentBound() public onFork {
        uint256 n = handler.facilityTotal();
        uint256 bound_ = handler.SEGMENT_BOUND();
        for (uint256 i; i < n; ++i) {
            (uint256 id,,,) = handler.facilityAt(i);
            IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
            uint256 face = reserves.deployedTo(id);
            uint256 canonical = d.principal + d.interest;
            uint256 diff = face > canonical ? face - canonical : canonical - face;
            assertLe(diff, bound_, string.concat("I7: facility ", vm.toString(id), " drifted past the segment bound"));
        }
    }

    /// @notice C-01 / R16-M3 (the fail-closed deficit gates are exact). On this fixture no custody
    ///         arm, incident, recognised reduction or live shortfall can exist, so
    ///         `reserveLossExitsLocked()` reduces to its last limb, effective supply above backing:
    ///         the exit interlock (and the curator-withdrawal lock that shares it) must be armed
    ///         exactly when that deficit stands; `closeEpoch` may be refused as frozen, the par mint
    ///         window closed, and a par redemption quoted below par, only while it stands.
    function invariant_C01_deficitGatesTrackTheDeficitExactly() public onFork {
        bool deficit = controller.totalUSDfr() > controller.backingValue();
        assertEq(reserves.reserveLossExitsLocked(), deficit, "C-01: exit interlock disagrees with the deficit");
        assertEq(reserves.curatorWithdrawalsLocked(), deficit, "C-01: curator lock disagrees with the deficit");
        assertEq(handler.frozenWithoutDeficit(), 0, handler.frozenDetail());
        assertEq(handler.mintClosedWithoutDeficit(), 0, handler.mintClosedDetail());
        assertEq(handler.parRedeemWithoutDeficit(), 0, handler.parRedeemDetail());
    }

    /// @notice Handler discipline: a revert outside the named refusal buckets is a bug, and a
    ///         documented fail-closed refusal that fired outside its documented state is one too.
    function invariant_handlerNeverRevertedUnexpectedly() public onFork {
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
        assertEq(handler.degenerateWithoutCause(), 0, handler.degenerateDetail());
    }

    /// @dev Prints the last run's census (visible on a failing run); the REACH claims live in
    ///      the deterministic tests below.
    function afterInvariant() public {
        if (!forkReady) return;
        emit log_named_uint("warp", handler.nWarp());
        emit log_named_uint("checkpoint fresh", handler.nCheckpointFresh());
        emit log_named_uint("checkpoint partial", handler.nCheckpointPartial());
        emit log_named_uint("boundaries processed", handler.nBoundariesProcessed());
        emit log_named_uint("materialize delivered", handler.nMaterializeDelivered());
        emit log_named_uint("posted", handler.nPosted());
        emit log_named_uint("serviced", handler.nServiced());
        emit log_named_uint("funded", handler.nFunded());
        emit log_named_uint("funded PIK", handler.nFundedPik());
        emit log_named_uint("receipts settled", handler.nRepaySettled());
        emit log_named_uint("receipts closing the facility", handler.nRepayFull());
        emit log_named_uint("recovery receipts", handler.nRepayRecovery());
        emit log_named_uint("over-debt refusals", handler.overDebtRefusals());
        emit log_named_uint("marked", handler.nMarked());
        emit log_named_uint("cleared", handler.nCleared());
        emit log_named_uint("declared", handler.nDeclared());
        emit log_named_uint("losses realized", handler.nLossRealized());
        emit log_named_uint("loss layer 1", handler.nLossLayer1());
        emit log_named_uint("loss layer 2", handler.nLossLayer2());
        emit log_named_uint("loss layer 3", handler.nLossLayer3());
        emit log_named_uint("rounding layer 1", handler.nRoundingLayer1());
        emit log_named_uint("rounding layer 2", handler.nRoundingLayer2());
        emit log_named_uint("rounding layer 3", handler.nRoundingLayer3());
        emit log_named_uint("rounding closures leaving a remainder", handler.nRoundingUnabsorbed());
        emit log_named_uint("rounding remainder unabsorbed (wei)", handler.gUnabsorbed());
        emit log_named_uint("absorption probes", handler.nAbsorptionProbes());
        emit log_named_uint("minted", handler.nMinted());
        emit log_named_uint("deposited", handler.nDeposited());
        emit log_named_uint("requested", handler.nRequested());
        emit log_named_uint("settled", handler.nSettled());
        emit log_named_uint("claimed", handler.nClaimed());
        emit log_named_uint("redeemed", handler.nRedeemed());
        emit log_named_uint("stale refusals", handler.staleRefusals());
        emit log_named_uint("queue refusals", handler.queueRefusals());
        emit log_named_uint("past-due refusals", handler.pastDueRefusals());
        emit log_named_uint("absorption refusals", handler.absorptionRefusals());
        emit log_named_uint("frozen refusals (C-01)", handler.frozenRefusals());
        emit log_named_uint("mint closed refusals (R16-M3)", handler.mintClosedRefusals());
        emit log_named_uint("degenerate-vault refusals (H-3)", handler.degenerateRefusals());
        emit log_named_uint("par redemption refusals (sub-par quote)", handler.parRedeemRefusals());
        emit log_named_uint("redeemed sub-par", handler.nRedeemedSubPar());
        emit log_named_uint("sub-par haircut (wei)", handler.gSubParHaircut());
        emit log_named_uint("keeper checkpoints", handler.keeperCheckpoints());
        emit log_named_uint("revokes", handler.revokes());
        emit log_named_uint("skipped", handler.skipped());
    }

    // ═══════════════════════════════════════════════════════════════════
    //  REACH: one deterministic test per action, proven by the state it changes
    // ═══════════════════════════════════════════════════════════════════

    /// @notice The fail-closed leg of the loss cascade is reached: once the senior vault is exhausted,
    ///         a whole-face write-off above every layer's capacity is REFUSED with
    ///         DefaultManager_LossExceedsAbsorptionCapacity, the face is untouched, the standing fact
    ///         is retired, and the cascade never reached past the vault (no I3 violation).
    function test_reach_realizeLoss_overCapacityProbeIsRefused() public onFork {
        handler.originateAndFund(1_000_000e6, 5);
        handler.originateAndFund(1_000_000e6, 5);
        handler.originateAndFund(400_000e6, 5);
        handler.originateAndFund(400_000e6, 5);
        handler.warp(40 days + 1);
        // Declare the fourth facility FIRST, while the vault can still absorb its closure's rounding
        // (declared later, that closure alone reproduces the finding pinned below), then exhaust the
        // senior layer: no junior capital; three whole-face write-offs, the third capped by the
        // handler at the vault's remaining assets (the first two leave the accrued yield).
        (uint256 id,,,) = handler.facilityAt(3);
        handler.declareDefault(3);
        handler.declareDefault(0);
        handler.realizeLoss(0, 4);
        handler.declareDefault(1);
        handler.realizeLoss(1, 4);
        handler.declareDefault(2);
        handler.realizeLoss(2, 4);
        assertEq(vault.totalAssets(), 0, "the senior vault is exhausted");
        assertEq(handler.nLossLayer3(), 3, "three write-offs reached layer 3");
        assertEq(controller.totalUSDfr(), reserves.totalBackingValue(), "no deficit: every closure was absorbed");
        uint256 face = reserves.deployedTo(id);
        assertGt(face, 0, "the fourth facility has a face to write off");
        uint256 revokesBefore = handler.revokes();
        handler.realizeLoss(3, 7); // seed % 4 == 3 and face > capacity: the probe
        assertEq(handler.nAbsorptionProbes(), 1, "the probe was attempted");
        assertEq(handler.absorptionRefusals(), 1, "refused with DefaultManager_LossExceedsAbsorptionCapacity");
        assertEq(handler.nLossRealized(), 3, "the probe realised nothing");
        assertEq(reserves.deployedTo(id), face, "face untouched");
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Defaulted), "still Defaulted");
        assertEq(handler.revokes(), revokesBefore + 1, "the standing LossRealized fact was retired");
        assertEq(handler.i3Violations(), 0, handler.i3Detail());
        assertEq(controller.totalUSDfr(), reserves.totalBackingValue(), "no deficit: the loss path failed closed");
        assertFalse(reserves.reserveLossExitsLocked(), "exits open");
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
    }

    /// @notice FINDING pinned deterministically (report section R4, "Revision after review"; surfaced
    ///         by the review's census campaign on unmodified contracts, 2 runs of 1,889). With the
    ///         senior vault exhausted and no junior capital, a sub-unit rounding closure on another
    ///         facility is clamped at the vault's few remaining wei and the rest is recorded as
    ///         unabsorbed; the write-down still lowers backing by the whole discrepancy. Effective
    ///         supply then exceeds backing by exactly that remainder, so every gate keyed on
    ///         `supply > backing` closes: the C-01 interlock arms (`closeEpoch` frozen, curator
    ///         withdrawals locked), the par mint window shuts (R16-M3), and `redeem(amount)`'s par
    ///         floor refuses. Nothing on this suite's surface repairs it except a redemption at the
    ///         quoted sub-par price, whose one-unit haircut flips the deficit into a surplus. The
    ///         loss cascade in the same state fails closed (test above); the rounding cascade does not.
    function test_finding_roundingRemainderExceedsBackingClosesMintAndFreezesExits() public onFork {
        handler.mintUSDfr(1, 250_000e6); // bob holds unstaked USDfr through what follows,
        handler.deposit(1, 100_000e18); // stakes 100,000 of it,
        handler.requestRedeem(1, type(uint256).max); // and queues his whole position for exit
        assertEq(handler.nRequested(), 1, "bob's exit is queued");
        handler.originateAndFund(1_000_000e6, 5);
        handler.originateAndFund(1_000_000e6, 5);
        handler.originateAndFund(400_000e6, 5);
        handler.originateAndFund(400_001e6, 5);
        (uint256 id3,,,) = handler.facilityAt(3);
        bool found;
        for (uint256 i = 1; i <= 40 && !found; ++i) {
            handler.warp(1 days + i * 977);
            IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id3);
            if (reserves.deployedTo(id3) > d.principal + d.interest) found = true;
        }
        assertTrue(found, "an over-recognising instant for the fourth facility exists within forty steps");
        // Exhaust the senior layer: no junior capital stands; three whole-face write-offs, the third
        // capped by the handler at the vault's remaining assets.
        handler.declareDefault(0);
        handler.realizeLoss(0, 4);
        handler.declareDefault(1);
        handler.realizeLoss(1, 4);
        handler.declareDefault(2);
        handler.realizeLoss(2, 4);
        assertEq(vault.totalAssets(), 0, "the senior vault is exhausted");
        assertEq(handler.nLossLayer3(), 3, "three write-offs reached layer 3");
        assertEq(controller.totalUSDfr(), reserves.totalBackingValue(), "no deficit yet: every loss was burned");
        assertFalse(reserves.reserveLossExitsLocked(), "exits still open");
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());

        // Declaring the fourth facility at the same instant closes its segment above the canonical
        // debt: the rounding cascade runs with nothing but the vault's in-call yield to burn.
        uint256 supplyBefore = usdfr.totalSupply();
        uint256 roundingBefore = handler.gRoundingLoss();
        uint256 seniorBefore = handler.gSeniorBurned();
        handler.declareDefault(3);
        uint256 unabsorbed = reserves.roundingLossUnabsorbed();
        uint256 effective = controller.totalUSDfr();
        uint256 backing = reserves.totalBackingValue();
        uint256 closure = handler.gRoundingLoss() - roundingBefore;
        uint256 seniorTook = handler.gSeniorBurned() - seniorBefore;
        emit log_named_uint("rounding closure discrepancy (wei)", closure);
        emit log_named_uint("senior took (the vault's in-call yield, wei)", seniorTook);
        emit log_named_uint("rounding remainder unabsorbed (wei)", unabsorbed);
        emit log_named_uint("effective supply", effective);
        emit log_named_uint("backing", backing);
        emit log_named_uint("physical supply", usdfr.totalSupply());
        assertEq(handler.nRoundingUnabsorbed(), 1, "one closure left a remainder");
        assertEq(closure, seniorTook + unabsorbed, "closure = senior burn + remainder (no junior capital)");
        assertLt(closure, 1e12, "the closure discrepancy is below one grid unit");
        assertEq(unabsorbed, 897_329_013_544, "PINNED: the unabsorbed remainder, block 25,500,000");
        assertEq(handler.gUnabsorbed(), unabsorbed, "the ghost saw the same remainder the reserve recorded");
        assertEq(effective, 1_206_110_140_229_657_302_335_657, "PINNED: effective supply");
        assertEq(backing, 1_206_110_140_228_759_973_322_113, "PINNED: backing");
        assertGt(effective, backing, "FINDING: effective supply exceeds backing");
        assertEq(effective - backing, unabsorbed, "the deficit is the unabsorbed remainder, to the wei");
        assertLe(usdfr.totalSupply(), backing, "physical supply is still within backing (unissued claims sit between)");
        assertEq(usdfr.totalSupply(), supplyBefore, "the closure burned nothing that was physical");
        assertEq(handler.i3Violations(), 0, string.concat("order respected, no I3 violation: ", handler.i3Detail()));
        assertTrue(reserves.reserveLossExitsLocked(), "C-01 interlock armed by the dust deficit");
        assertTrue(reserves.curatorWithdrawalsLocked(), "curator withdrawals locked by the same predicate");
        vm.prank(ops);
        vm.expectRevert(IRedemptionQueue.Queue_ReserveLossSettlementFrozen.selector);
        queue.closeEpoch(1);

        // The same deficit closes the par mint window (R16-M3, which names "a residual deficit the
        // cascade could not absorb" as a reason). Vault entry is closed too, by the separate
        // wiped-out-vault guard (H-3), since bob's and alice's shares now stand against zero assets.
        handler.mintUSDfr(1, 250_000e6); // bob
        assertEq(handler.nMinted(), 1, "no second mint: the window is closed");
        assertEq(handler.mintClosedRefusals(), 1, "refused with Controller_MintClosedWhileUnderBacked");
        assertEq(handler.mintClosedWithoutDeficit(), 0, "closed under a real deficit");
        assertEq(controller.totalUSDfr() - reserves.totalBackingValue(), unabsorbed, "the refused mint moved nothing");
        handler.deposit(1, 50_000e18);
        assertEq(handler.nDeposited(), 1, "no second stake: entry is closed");
        assertEq(handler.degenerateRefusals(), 1, "refused with SUSDfr_DegenerateSharePrice");
        assertEq(handler.degenerateWithoutCause(), 0, "the vault is wiped out: shares against zero assets");
        handler.warp(Config.DEFAULT_REDEEM_COOLDOWN + 3);
        assertEq(controller.totalUSDfr() - reserves.totalBackingValue(), unabsorbed, "time does not move the deficit");
        handler.settleQueue(8);
        assertEq(handler.frozenRefusals(), 1, "closeEpoch refused as frozen through the handler's own path");
        assertEq(handler.frozenWithoutDeficit(), 0, "the freeze fired under a real deficit");
        assertEq(handler.nSettled(), 0, "no epoch closed");
        assertEq(handler.nClaimed(), 0, "nothing claimable");

        // A direct redemption is the one flow that moves the deficit. The par floor of
        // redeem(amount) refuses (the quote is below par), and the quoted sub-par exit settles: the
        // controller prices it at backing / supply floored to the USDC grid, records the haircut as
        // a crystallised senior shortfall, and the deficit shrinks by that haircut.
        uint256 usdcBefore = IERC20(USDC).balanceOf(bob);
        uint256 shortfallBefore = controller.seniorSubParShortfall();
        handler.redeemUSDfr(1, 500e18);
        uint256 usdcOut = IERC20(USDC).balanceOf(bob) - usdcBefore;
        uint256 crystallised = controller.seniorSubParShortfall() - shortfallBefore;
        uint256 effectiveAfter = controller.totalUSDfr();
        uint256 backingAfter = reserves.totalBackingValue();
        emit log_named_uint("bob redeemed 500 USDfr and received USDC units", usdcOut);
        emit log_named_uint("crystallised sub-par shortfall (wei)", crystallised);
        emit log_named_uint("effective supply after", effectiveAfter);
        emit log_named_uint("backing after", backingAfter);
        emit log_named_string("exit interlock after", reserves.reserveLossExitsLocked() ? "ARMED" : "off");
        assertEq(handler.parRedeemRefusals(), 1, "redeem(amount) refused: Controller_SlippageExceeded below par");
        assertEq(handler.parRedeemWithoutDeficit(), 0, "quoted below par under a real deficit");
        assertEq(handler.nRedeemed(), 0, "no par redemption settled");
        assertEq(handler.nRedeemedSubPar(), 1, "the quoted sub-par redemption settled");
        assertEq(usdcOut, 499_999_999, "PINNED: 500 USDfr bought 499.999999 USDC, one unit below par");
        assertEq(crystallised, 1e12, "PINNED: one whole unit crystallised as senior sub-par shortfall");
        assertEq(handler.gSubParHaircut(), crystallised, "the ghost saw the same haircut");
        // One redeemer's unit cleared a 0.897-unit deficit: the protocol now carries a SURPLUS.
        assertGt(backingAfter, effectiveAfter, "the deficit flipped to a surplus");
        assertEq(backingAfter - effectiveAfter, 1e12 - unabsorbed, "PINNED: surplus 102,670,986,456 wei");
        assertFalse(reserves.reserveLossExitsLocked(), "the interlock released");
        handler.mintUSDfr(1, 1_000e6);
        assertEq(handler.nMinted(), 2, "the par mint window reopened");
        assertEq(handler.i3Violations(), 0, handler.i3Detail());
        assertEq(handler.i4Violations(), 0, handler.i4Detail());
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
    }

    function test_reach_warp() public onFork {
        uint256 t0 = block.timestamp;
        handler.warp(30 days + 1); // not divisible by four: no keeper batch rides on it
        assertEq(block.timestamp, t0 + 30 days + 1, "warp moved the clock by the bounded amount");
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
    }

    function test_reach_originateAndFund_cash() public onFork {
        handler.originateAndFund(400_000e6, 5);
        assertEq(handler.nFunded(), 1, "one facility funded");
        (uint256 id, bool pik,, bool live) = handler.facilityAt(0);
        assertFalse(pik, "shape 5 is a cash facility");
        assertTrue(live, "live");
        assertEq(reserves.deployedTo(id), 400_000e18, "funded at the bounded principal");
        assertTrue(reserves.accruedDebt(id).active, "registered as accruing");
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
    }

    function test_reach_originateAndFund_pik() public onFork {
        handler.originateAndFund(100_000e6, 0);
        (uint256 id, bool pik,,) = handler.facilityAt(0);
        assertTrue(pik, "shape 0 is a PIK note");
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
        assertTrue(d.pik && d.active, "registered as an accruing PIK note");
        assertEq(d.nextCapitalization, block.timestamp + 90 days, "first signed capitalisation date");
        assertEq(handler.nFundedPik(), 1, "counted as PIK");
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
    }

    function test_reach_checkpoint_processesADueBoundary() public onFork {
        handler.originateAndFund(100_000e6, 0); // PIK: first boundary at 90 days
        handler.warp(91 days + 1);
        assertFalse(reserves.accrualSnapshot().fresh, "a boundary is due");
        handler.checkpoint(32);
        assertEq(handler.nBoundariesProcessed(), 1, "the due boundary was processed");
        assertEq(handler.nCheckpointFresh(), 1, "the keeper reported fresh");
        assertTrue(reserves.accrualSnapshot().fresh, "book fresh");
        (uint256 id,,,) = handler.facilityAt(0);
        assertEq(reserves.accruedDebt(id).principal, 100_000e18 + 3_500e18, "the coupon capitalised");
        assertEq(handler.i5Violations(), 0, handler.i5Detail());
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
    }

    function test_reach_checkpoint_partialBatchIsUnfreshOnlyWhenExhausted() public onFork {
        handler.originateAndFund(100_000e6, 1); // shape 1: PIK capitalising every 7 days
        (uint256 id,,,) = handler.facilityAt(0);
        assertEq(reserves.accruedDebt(id).nextCapitalization, block.timestamp + 7 days, "7-day signed dates");
        handler.warp(15 days + 1); // two signed boundaries fall due inside one warp
        handler.checkpoint(1);
        assertEq(handler.nCheckpointPartial(), 1, "one boundary of two: unfresh");
        assertEq(handler.i5Violations(), 0, "a batch-exhausted unfresh answer is legitimate");
        handler.checkpoint(1);
        assertEq(handler.nCheckpointFresh(), 1, "the second boundary made it fresh");
        assertEq(handler.nBoundariesProcessed(), 2, "both boundaries processed");
        uint256 basis = 100_000e18;
        for (uint256 i; i < 2; ++i) {
            basis += basis * 1400 * 7 days / (10_000 * 360 days) / 1e12 * 1e12;
        }
        assertEq(reserves.accruedDebt(id).principal, basis, "two weekly coupons capitalised, to the wei");
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
    }

    function test_reach_materialize_deliversVirtualClaims() public onFork {
        handler.originateAndFund(400_000e6, 5);
        handler.warp(10 days + 1);
        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        uint256 feeBefore = usdfr.balanceOf(waterfall.feeRecipient());
        handler.materialize(3);
        assertEq(handler.nMaterializeDelivered(), 1, "delivered");
        assertGt(usdfr.balanceOf(address(vault)), vaultBefore, "senior leg minted to the vault");
        assertGt(usdfr.balanceOf(waterfall.feeRecipient()), feeBefore, "fee leg minted to the recipient");
        assertEq(handler.gIssued(), reserves.accrualSnapshot().gross, "the ghost counted the whole delivery");
        assertEq(reserves.accrualSnapshot().unissued, 0, "nothing virtual remains");
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
    }

    function test_reach_materialize_refusedStale() public onFork {
        handler.originateAndFund(100_000e6, 1);
        handler.warp(91 days + 1);
        handler.materialize(3);
        assertEq(handler.staleRefusals(), 1, "the stale book refused the delivery");
        assertEq(handler.nMaterializeDelivered(), 0, "nothing delivered");
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
    }

    function test_reach_post_movesVirtualToRecorded() public onFork {
        handler.originateAndFund(400_000e6, 5);
        handler.warp(10 days + 1);
        (uint256 id,,,) = handler.facilityAt(0);
        uint256 unposted = reserves.unpostedAccruedLoan(id);
        assertGt(unposted, 0, "ten days of recognition are unposted");
        uint256 face = reserves.deployedTo(id);
        handler.post(0);
        assertEq(handler.nPosted(), 1, "posted");
        assertEq(reserves.unpostedAccruedLoan(id), 0, "nothing unposted");
        assertEq(reserves.deployedTo(id), face, "posting is face-neutral");
        assertEq(registry.totalBookExposure(), face, "the registry carries the posted face");
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
    }

    function test_reach_service_advancesADormantPikDate() public onFork {
        handler.originateAndFund(10, 2); // micro PIK: 10 USDC units, coupon floors to zero
        (uint256 id, bool pik,,) = handler.facilityAt(0);
        assertTrue(pik, "shape 2 is a PIK note");
        assertFalse(reserves.accrualLoanScheduled(id), "a zero-coupon period is dormant, not scheduled");
        uint64 due0 = reserves.accruedDebt(id).nextCapitalization;
        handler.warp(91 days + 1);
        handler.service(0);
        assertEq(handler.nServiced(), 1, "the servicer advanced the signed date");
        assertEq(reserves.accruedDebt(id).nextCapitalization, due0 + 90 days, "next capitalisation advanced");
        assertEq(bridge.facility(id).nextPaymentDue, due0 + 90 days, "the bridge follows the reserve");
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
    }

    function test_reach_repay_couponAndFullPayoff() public onFork {
        handler.originateAndFund(400_000e6, 5);
        handler.warp(30 days + 1);
        (uint256 id,,,) = handler.facilityAt(0);
        uint256 owed = reserves.accruedDebt(id).interest;
        uint256 expectedCoupon = uint256(400_000e18) * 1400 * (30 days + 1) / (10_000 * 360 days) / 1e12 * 1e12;
        assertEq(owed, expectedCoupon, "thirty-day (plus one second) coupon");
        handler.repay(0, 0, 0, 1); // mode 1: interest-only coupon
        assertEq(handler.nRepaySettled(), 1, "coupon settled");
        assertEq(reserves.accruedDebt(id).interest, 0, "interest discharged");
        handler.warp(5 days + 1);
        handler.repay(0, 0, 0, 2); // mode 2: full payoff
        assertEq(handler.nRepayFull(), 1, "the facility closed");
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Repaid), "Repaid");
        assertEq(reserves.deployedTo(id), 0, "no face remains");
        assertEq(handler.i6Violations(), 0, handler.i6Detail());
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
    }

    function test_reach_repay_overDebtProbeIsRefused() public onFork {
        handler.originateAndFund(400_000e6, 5);
        handler.warp(30 days + 1);
        (uint256 id,,,) = handler.facilityAt(0);
        uint256 face = reserves.deployedTo(id);
        handler.repay(0, 0, 0, 0); // mode 0: one grid unit above the debt
        assertEq(handler.overDebtRefusals(), 1, "refused with AccrualLoans_PaymentAboveDebt");
        assertEq(handler.nRepaySettled(), 0, "nothing settled");
        assertEq(reserves.deployedTo(id), face, "face untouched");
        assertEq(handler.revokes(), 1, "the standing receipt fact was retired");
        // The delivery that ReserveRoundingLib.prepare made inside the refused receipt was rolled
        // back with it; the ghost must not have counted its event (campaign counterexample 1).
        assertEq(handler.gIssued(), 0, "no delivery survived the refused receipt");
        assertEq(reserves.accrualSnapshot().unissued, reserves.accrualSnapshot().gross, "everything still virtual");
        assertEq(handler.i6Violations(), 0, handler.i6Detail());
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
    }

    function test_reach_repay_partialPrincipalAmortizes() public onFork {
        handler.originateAndFund(400_000e6, 5);
        handler.warp(20 days + 1);
        (uint256 id,,,) = handler.facilityAt(0);
        handler.repay(0, 1_000e18, 100_000e18, 3); // mode 3: bounded partial receipt
        assertEq(handler.nRepaySettled(), 1, "partial settled");
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Amortizing), "Amortizing");
        assertLt(reserves.accruedDebt(id).principal, 400_000e18, "principal reduced");
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
    }

    function test_reach_markPastDue_andClear() public onFork {
        handler.originateAndFund(400_000e6, 5);
        handler.warp(30 days + 21 days + 3);
        (uint256 id,,,) = handler.facilityAt(0);
        handler.markPastDue(0);
        assertEq(handler.nMarked(), 1, "marked");
        assertGt(defaultManager.pastDueContribution(id), 0, "past-due contribution recorded");
        (,, bool marked,) = handler.facilityAt(0);
        assertTrue(marked, "handler tracks the mark");
        handler.clearPastDue(0);
        assertEq(handler.nCleared(), 1, "cleared");
        assertEq(defaultManager.pastDueContribution(id), 0, "contribution released");
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
    }

    function test_reach_markPastDue_refusedBeforeGrace() public onFork {
        handler.originateAndFund(400_000e6, 5);
        handler.warp(10 days + 1);
        handler.markPastDue(0);
        assertEq(handler.pastDueRefusals(), 1, "not yet past due");
        assertEq(handler.nMarked(), 0, "not marked");
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
    }

    function test_reach_declareDefault_andRealizeLossAcrossLayers() public onFork {
        handler.originateAndFund(400_000e6, 5);
        handler.postFirstLoss(50_000e18);
        handler.fundCoverage(80_000e18);
        assertEq(curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS), 50_000e18, "layer 1 funded");
        assertEq(sGrove.coverageReserve(), 80_000e18, "layer 2 funded");
        handler.warp(40 days + 1);
        (uint256 id,,,) = handler.facilityAt(0);
        handler.declareDefault(0);
        assertEq(handler.nDeclared(), 1, "declared");
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Defaulted), "Defaulted");
        assertFalse(reserves.accruedDebt(id).active, "accrual stopped");
        uint256 vaultBefore = vault.totalAssets();
        handler.realizeLoss(0, 200_000e18 + 1); // seed % 4 != 0: bounded to the seed
        assertEq(handler.nLossRealized(), 1, "loss realized");
        assertEq(handler.nLossLayer1(), 1, "layer 1 drawn");
        assertEq(handler.nLossLayer2(), 1, "layer 2 drawn");
        assertEq(handler.nLossLayer3(), 1, "layer 3 drawn");
        assertEq(curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS), 0, "layer 1 exhausted first");
        assertEq(sGrove.coverageReserve(), 0, "layer 2 exhausted second");
        assertLt(vault.totalAssets(), vaultBefore, "layer 3 took the residual");
        assertEq(handler.i3Violations(), 0, handler.i3Detail());
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
    }

    function test_reach_realizeLoss_fullWriteOffResolves() public onFork {
        handler.originateAndFund(400_000e6, 5);
        handler.warp(40 days + 1);
        (uint256 id,,,) = handler.facilityAt(0);
        handler.declareDefault(0);
        handler.realizeLoss(0, 4); // seed % 4 == 0: the whole outstanding face
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Resolved), "Resolved");
        assertEq(reserves.deployedTo(id), 0, "written off in full");
        (,,, bool live) = handler.facilityAt(0);
        assertFalse(live, "handler retired the facility");
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
    }

    function test_reach_repay_recoveryOnDefaultedFacility() public onFork {
        handler.originateAndFund(400_000e6, 5);
        handler.warp(40 days + 1);
        (uint256 id,,,) = handler.facilityAt(0);
        handler.declareDefault(0);
        handler.repay(0, 0, 0, 2); // full recovery in cash
        assertEq(handler.nRepayRecovery(), 1, "recovery settled");
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Resolved), "Resolved");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "impairment cleared");
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
    }

    function test_reach_postFirstLoss_andFundCoverage() public onFork {
        handler.postFirstLoss(12_345e18);
        assertEq(curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS), 12_345e18, "curator capital posted");
        handler.fundCoverage(6_789e18);
        assertEq(sGrove.coverageReserve(), 6_789e18, "coverage funded");
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
    }

    function test_reach_mintDepositQueueClaimRedeem() public onFork {
        uint256 supply0 = usdfr.totalSupply();
        handler.mintUSDfr(1, 250_000e6); // bob
        assertEq(handler.nMinted(), 1, "minted");
        assertEq(usdfr.totalSupply(), supply0 + 250_000e18, "supply rose by the mint");
        handler.deposit(1, 100_000e18);
        assertEq(handler.nDeposited(), 1, "deposited");
        assertGt(vault.balanceOf(bob), 0, "bob holds shares");
        handler.requestRedeem(1, type(uint256).max);
        assertEq(handler.nRequested(), 1, "queued");
        assertEq(handler.requestCount(), 1, "handler tracks the request");
        handler.settleQueue(8);
        assertEq(handler.queueRefusals(), 1, "refused: epoch not over or head in cooldown");
        handler.warp(Config.DEFAULT_REDEEM_COOLDOWN + 3);
        uint256 bobBefore = usdfr.balanceOf(bob);
        handler.settleQueue(8);
        assertEq(handler.nSettled(), 1, "epoch closed");
        assertEq(handler.nClaimed(), 1, "claimed");
        assertGt(usdfr.balanceOf(bob), bobBefore, "the claim paid USDfr");
        uint256 usdcBefore = IERC20(USDC).balanceOf(bob);
        handler.redeemUSDfr(1, 50_000e18);
        assertEq(handler.nRedeemed(), 1, "redeemed");
        assertEq(IERC20(USDC).balanceOf(bob) - usdcBefore, 50_000e6, "real USDC returned");
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
    }

    function test_reach_userActionsRetryAfterStaleRefusal() public onFork {
        handler.originateAndFund(100_000e6, 1);
        handler.warp(91 days + 1);
        assertFalse(reserves.accrualSnapshot().fresh, "stale");
        handler.mintUSDfr(0, 10_000e6);
        assertEq(handler.staleRefusals(), 1, "the first mint was refused stale");
        assertEq(handler.nMinted(), 1, "the retry after the keeper minted");
        assertTrue(reserves.accrualSnapshot().fresh, "the keeper ran");
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
    }

    /// @notice The senior leg of the rounding cascade is reached: with no junior capital standing,
    ///         the same sub-unit write-down is burned from the senior vault, bounded below one grid
    ///         unit, and the vault's assets fall by no more than the burn the event reports (I4).
    function test_reach_roundingClosureLandsOnSeniorWhenNoJuniorCapital() public onFork {
        handler.originateAndFund(400_001e6, 5);
        (uint256 id,,,) = handler.facilityAt(0);
        bool found;
        for (uint256 i = 1; i <= 40 && !found; ++i) {
            handler.warp(1 days + i * 977);
            IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
            if (reserves.deployedTo(id) > d.principal + d.interest) found = true;
        }
        assertTrue(found, "an over-recognising instant exists within forty steps");
        assertEq(curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS), 0, "no curator capital");
        assertEq(sGrove.coverageReserve(), 0, "no sGROVE coverage");
        uint256 assetsBefore = vault.totalAssets();
        handler.repay(0, 0, 0, 1);
        assertEq(handler.nRepaySettled(), 1, "coupon settled");
        assertEq(handler.gClosuresWithRounding(), 1, "the close allocated a rounding loss");
        assertEq(handler.nRoundingLayer3(), 1, "it landed on the senior vault");
        assertEq(handler.nRoundingLayer1() + handler.nRoundingLayer2(), 0, "no junior layer was touched");
        uint256 burned = handler.gRoundingLoss();
        assertLt(burned, 1e12, "below one grid unit");
        assertEq(handler.gSeniorBurned(), burned, "the whole write-down was the senior burn");
        assertGe(vault.totalAssets() + burned, assetsBefore, "vault assets fell by at most the senior burn");
        assertEq(handler.i3Violations(), 0, handler.i3Detail());
        assertEq(handler.i4Violations(), 0, handler.i4Detail());
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
    }

    /// @notice OBSERVATION found by the campaign (recorded, not a failure): `realizeLoss` accepts a
    ///         loss of any wei, so a sub-unit write-off leaves an off-grid face. The reserve settles
    ///         cash on the USDC grid, so no receipt can then discharge the face in full: the whole
    ///         units are recoverable, the residual below one unit stays outstanding, and only a
    ///         further write-off of that dust resolves the facility.
    function test_observation_subUnitWriteOffLeavesAnOffGridFace() public onFork {
        handler.originateAndFund(400_000e6, 5);
        handler.warp(40 days + 1);
        (uint256 id,,,) = handler.facilityAt(0);
        handler.declareDefault(0);
        uint256 face = reserves.deployedTo(id);
        assertEq(face % 1e12, 0, "the declared face is on the grid");

        // A one-wei write-off is accepted.
        _realizeLoss(id, 1, keccak256("obs-dust-1"));
        assertEq(reserves.deployedTo(id), face - 1, "one wei written off");
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
        assertEq(d.principal % 1e12, 1e12 - 1, "principal is now off the grid");

        // The full cash recovery is refused before the attestation is even consulted: the total
        // is not representable in USDC units.
        uint256 total = d.principal + d.interest;
        deal(USDC, borrower, IERC20(USDC).balanceOf(borrower) + total / 1e12 + 1);
        vm.prank(borrower);
        IERC20(USDC).approve(address(reserves), total / 1e12 + 1);
        IWaterfallEngine.Payment memory p = IWaterfallEngine.Payment({
            tokenId: id,
            paymentId: keccak256("obs-full"),
            payer: borrower,
            interest: d.interest,
            principal: d.principal,
            nextPaymentDue: 0
        });
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_ValueNotUSDCExact.selector, total));
        waterfall.distribute(p);

        // Every whole unit is recoverable; the residual below one unit stays outstanding.
        handler.repay(0, 0, 0, 2);
        assertEq(handler.nRepaySettled(), 1, "the grid-floored recovery settled");
        uint256 residual = reserves.deployedTo(id);
        assertEq(residual, 1e12 - 1, "the sub-unit residual stays outstanding");
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Defaulted), "still Defaulted");

        // Only a write-off of the dust resolves the facility.
        _realizeLoss(id, residual, keccak256("obs-dust-2"));
        assertEq(reserves.deployedTo(id), 0, "resolved by writing off the dust");
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Resolved), "Resolved");
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
    }

    /// @notice The rounding cascade is reached: a coupon at a non-grid instant closes the
    ///         segment above the canonical figure, and with curator capital standing the
    ///         sub-unit write-down lands on layer 1, never on the senior vault.
    function test_reach_roundingClosureLandsOnCurator() public onFork {
        handler.originateAndFund(400_001e6, 5);
        handler.postFirstLoss(1_000e18);
        // Search a non-grid instant whose close over-recognises (streamed above canonical).
        (uint256 id,,,) = handler.facilityAt(0);
        bool found;
        for (uint256 i = 1; i <= 40 && !found; ++i) {
            handler.warp(1 days + i * 977);
            uint256 face = reserves.deployedTo(id);
            IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
            if (face > d.principal + d.interest) found = true;
        }
        assertTrue(found, "an over-recognising instant exists within forty steps");
        handler.repay(0, 0, 0, 1);
        assertEq(handler.nRepaySettled(), 1, "coupon settled");
        assertEq(handler.gClosuresWithRounding(), 1, "the close allocated a rounding loss");
        assertEq(handler.nRoundingLayer1(), 1, "it landed on the curator");
        assertEq(handler.nRoundingLayer3(), 0, "the senior vault was untouched");
        assertLt(handler.gRoundingLoss(), 1e12, "below one grid unit");
        assertEq(handler.i3Violations(), 0, handler.i3Detail());
        assertEq(handler.i4Violations(), 0, handler.i4Detail());
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpected());
    }
}
