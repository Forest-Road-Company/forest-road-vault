// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ReserveAccrualStorageLib} from "./ReserveAccrualStorageLib.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICuratorModule} from "../interfaces/ICuratorModule.sol";
import {IMintRedeemController} from "../interfaces/IMintRedeemController.sol";
import {IReserveLossAbsorber} from "../interfaces/IReserveLossAbsorber.sol";
import {IReserveManager} from "../interfaces/IReserveManager.sol";
import {IsUSDfr} from "../interfaces/IsUSDfr.sol";

/// @title ReserveStorageLib - the single declaration of ReserveManager's ERC-7201 layout
/// @notice Declared once and shared by the implementation and by every linked library, because a
///         second declaration is a second source of truth that the compiled-layout gate cannot
///         compare.
/// @dev EVERY function here is `internal`, so this library adds no deployed bytecode of its own and
///      needs no link reference. Only the `public` functions of `ReserveBasketLib`,
///      `ReserveCascadeLib` and `ReserveWiringLib` are separately deployed.
///
///      STORAGE RULES, BINDING FROM GENESIS.
///      This is a fresh deployment with virgin storage, so the genesis layout below is laid out
///      freely: the head mirrors the Ethereum instance's field order minus the fields ADR-0037
///      deletes, so a reader who knows that contract can diff the two, and the multi-asset tail
///      follows. That freedom ENDS HERE. From genesis onward the ERC-7201 rule binds absolutely:
///      new fields append at the tail, never in the middle, and no field ever changes type or
///      order. Do not read the genesis reordering as a licence to reorder on an upgrade, and do not
///      read it as a licence to reorder the Ethereum instance, whose proxies are live.
library ReserveStorageLib {
    /// @notice Par, in the protocol's 18-decimal value language. The absolute cap on a mint price.
    uint256 internal constant ONE = 1e18;

    /// @notice One admitted reserve asset.
    /// @dev `scale` is recorded from the decimals governance ASSERTED at listing, never from a raw
    ///      live read, and never changes afterwards. The first seven fields pack into one slot.
    struct ReserveAsset {
        uint8 decimals;
        bool listed;
        bool frozenMint;
        bool frozenRedeem;
        uint16 mintFeeBps;
        uint32 listedAt;
        uint64 scale;
        uint256 units;
        uint256 cap;
        uint256 recognizedCapLoss;
        uint256 custodyShortfallUnits;
        uint256 deferredUnits;
        /// @dev Custody loss not debited from idle at discovery; retained through ratification.
        uint256 unappliedCustodyLossUnits;
    }

    /// @notice One custody-loss adjudication.
    /// @dev The asset is a FIELD of the record and NEVER part of the id derivation. Multiplexing an
    ///      asset index into the id would create a second coordinate system minting into one
    ///      namespace, which is exactly the shape of Corrovera DV-02.
    struct LossArm {
        address asset;
        IReserveManager.ArmState state;
        bytes32 evidenceHash;
        uint256 recoveryCapacityUnits;
    }

    /// @notice One asset's latched relative price and its absolute mint floor (ADR-0038).
    /// @dev DELIBERATELY NOT A FIELD OF `ReserveAsset`, and this placement is load-bearing.
    ///      `ReserveAsset` is the struct `contribution()` and `payableValue()` read, and
    ///      `writeAsset` is documented as THE SINGLE WRITER of its value-bearing fields. Putting a
    ///      price inside it would place a price one field away from the two functions that compute
    ///      backing, with a different writer and a different authority path sharing the struct -
    ///      exactly the edit a future engineer makes by accident. Held in a SIBLING mapping instead,
    ///      so the code can state flatly, and a test can assert, that NO FUNCTION THAT READS
    ///      `ReserveAsset` READS A PRICE. That is the ADR-0025 preservation property.
    ///
    ///      Two slots: `price`, `asOf` pack into the first; `floor` takes the second.
    struct AssetPrice {
        /// @dev 18-decimal relative price, `1e18 == par`, bounded above at push time.
        uint128 price;
        /// @dev The ATTESTED observation time of the latched value, never the submission time.
        uint64 asOf;
        /// @dev 18-decimal absolute floor below which minting in this asset refuses entirely.
        ///      OWNER DECISION, per asset (spec 06 section 5). A zero floor is refused by the setter AND
        ///      treated as "not configured" on read, so an asset is closed to minting until
        ///      governance has chosen one.
        uint256 floor;
    }

    /// @custom:storage-location erc7201:forestroad.storage.ReserveManager
    struct ReserveStorage {
        // -- head: the Ethereum field order, minus the ADR-0037 deletions --
        uint256 totalDeployedPrincipal;
        mapping(uint256 facilityId => uint256) deployed;
        // Retained ADR-0034 compatibility hook: still consumed by `recordExitPrepayment`,
        // `consumeExitPrepayment` and the fail-closed limb of `_reserveLossExitsLocked`.
        IReserveLossAbsorber lossAbsorber;
        IMintRedeemController lossController;
        uint256 reserveDeficit;
        ICuratorModule lossCurator;
        // ADR-0037 D3a(ii): there is no cascade layer two on this instance. The slot is reserved
        // and never written, so that if Forest Road later funds a BSC layer two the field lands at
        // the position its Ethereum sibling occupies and the cross-instance storage-parity fixture
        // stays a straight comparison rather than an offset table. Cost: one slot, zero bytecode.
        address __reservedLossBackstop;
        IsUSDfr lossVault;
        IERC20 lossUSDfr;
        address lossTimelock;
        uint256 recognizedBackingReduction;
        uint256 recognizedSurplusAbsorbed;
        uint256 recognizedSupplyReduction;
        bool guardianReserveLossArmsEnabled;
        uint256 nextReserveLossArmId;
        uint256 totalPrincipalImpairment;
        mapping(uint256 facilityId => uint256) principalImpairment;
        uint256 exitPrepaidAbsorption;
        // -- multi-asset tail --
        address[] assetList;
        mapping(address asset => ReserveAsset) assets;
        mapping(address asset => uint256 armId) activeArmOf;
        mapping(uint256 armId => LossArm) arms;
        mapping(address holder => mapping(address asset => uint256)) deferredLegs;
        mapping(uint256 facilityId => address) facilityAsset;
        // O(1) caches maintained by writeAsset and setUnappliedCustodyLoss below.
        uint256 totalIdleBackingValue;
        uint256 totalPayableIdleValue;
        uint256 totalCustodyShortfallValue;
        uint256 openArmCount;
        // Register only. The controller owns the fee path; the reserve never carves a fee.
        address feeRecipientHint;
        // -- ADR-0038 tail: the priced mint, and the record-capped exit --
        // APPEND ONLY. Everything below this line was added after the head was frozen.
        /// @dev The latched price series, per asset. A SIBLING of `assets`, never a field of it.
        mapping(address asset => AssetPrice) assetPrices;
        /// @dev Where the m-of-n price attestations are verified. Bound once, validated.
        address priceOracle;
        /// @dev Staleness bound, seconds. GLOBAL: it is a property of the keeper's push cadence,
        ///      not of an asset. OWNER DECISION (spec 06 section 5).
        uint64 priceMaxAge;
        /// @dev Per-update deviation bound, bps, symmetric. GLOBAL, same reason.
        ///      OWNER DECISION (spec 06 section 5, section 10(3)).
        uint16 priceMaxDeviationBps;
        /// @dev THE DEPOSIT RECORD (Forest Road direction 2026-09-07). Native units of each asset
        ///      each address has DEPOSITED, incremented when a deposit is credited and decremented
        ///      as it is drawn down on withdrawal. IT DOES NOT MOVE WHEN USDfr IS TRANSFERRED, and
        ///      that is the whole security property: a redemption draws the redeemer's OWN recorded
        ///      assets one to one, capped by this record, so no holder can convert an impaired
        ///      asset into a sound one at the expense of the holders who stay.
        mapping(address holder => mapping(address asset => uint256)) depositRecord;
        /// @dev Native units of one asset a holder is owed but which were NOT in the idle tally
        ///      when their recorded draw ran (the units were deployed into a facility, or the asset
        ///      was redeem-frozen). Settled by `claimPendingUnits` once units return. The holder is
        ///      NOT paid the basket instead: that would reopen exactly the transfer the record cap
        ///      closes.
        mapping(address holder => mapping(address asset => uint256)) pendingClaimUnits;
        /// @dev Per-asset sum of `pendingClaimUnits`. These units are RESERVED: they stay inside
        ///      `ReserveAsset.units` (so custody reconciliation still balances) but no basket may
        ///      allocate them and no deployment may spend them.
        mapping(address asset => uint256) claimedUnits;
        /// @dev 18-decimal value of every outstanding pending claim. SUBTRACTED FROM BACKING at
        ///      escrow time, because supply falls when the claim is written while the units have
        ///      not yet left. Without it backing per remaining USDfr would rise by the claim and
        ///      then fall again when the claim settled, which is a solvency hole in the second leg.
        uint256 totalClaimValue;
        /// @dev Sum of each asset's unappliedCustodyLossUnits * scale. Deducted once from backing.
        uint256 totalUnappliedCustodyLossValue;
        mapping(address asset => uint256) pendingUnappliedCustodyLossUnits;
        mapping(uint256 armId => uint256) armUnappliedCustodyLossUnits;
    }

    bytes32 private constant RESERVE_STORAGE_LOCATION =
        0xc49ad79e2b58679c441432bede06c67f7802343349e70ccf00d8d1ce92bb1b00;

    /// @dev The ERC-7201 slot. Libraries here are delegatecalled, so this resolves to the same
    ///      storage in the implementation and in every linked library.
    function layout() internal pure returns (ReserveStorage storage $) {
        assembly {
            $.slot := RESERVE_STORAGE_LOCATION
        }
    }

    /// @dev `par - recognizedCapLoss`. The `recognizedCapLoss` term is what makes a cap cut below
    ///      the standing tally survive a later cap RAISE: raising restores nothing, because nothing
    ///      was proved. A repayment or recapitalisation does restore value, because units actually
    ///      arrived (ADR-0025, up only on proof).
    ///
    ///      THE `min(..., cap)` CLAMP WAS REMOVED ON 2026-09-08, Forest Road direction: backing
    ///      counts every unit the reserve actually holds, and the cap governs DEPOSITS only.
    ///
    ///      IT CONTRADICTED THE PARAGRAPH ABOVE, which is how the defect was found. `setCap`'s own
    ///      NatSpec works the example: par 100, cap 100 cut to 60, so `recognizedCapLoss` is 40 and
    ///      the contribution is 60; then "a repayment of 20 units DOES raise it, to 80, because
    ///      units actually arrived". With the clamp it did not: `min(120 - 40, 60)` is 60, so the
    ///      repaid cash stayed unrecognised, which is exactly the trap the same comment says
    ///      `recognizedCapLoss` exists as a separate ledger to avoid.
    ///
    ///      FOUND BY SYMBOLIC EXECUTION, not by reading.
    ///      `BackingSymbolic.check_paymentThenYieldMintPreservesBacking_asset2` produced a
    ///      counterexample on the 6-decimal asset (units 2^120, principal 2^120, interest 28*2^112);
    ///      both 18-decimal siblings passed, because at `scale == 1` a `uint128` unit count cannot
    ///      reach the cap. The mixed-scale registry is what exposed it.
    ///
    ///      NOTHING IS LOST BY REMOVING IT. Deposit admission still enforces the ceiling in
    ///      `ReserveWiringLib.deposit`, which is the "voluntary mint-side door" the cap's own
    ///      NatSpec describes. A governance cap cut still lowers backing, through
    ///      `recognizedCapLoss`, which is an explicit written mark rather than an implicit clamp
    ///      and is the ADR-0025 "down on authority" path.
    function contribution(ReserveAsset storage r) internal view returns (uint256) {
        uint256 par = r.units * r.scale;
        uint256 loss = r.recognizedCapLoss;
        return par > loss ? par - loss : 0;
    }

    /// @dev Par tally a basket may draw on. A redeem-frozen leg is worth zero LIQUIDITY and its
    ///      full contribution of SOLVENCY: the units exist, they are stuck. Freezing therefore
    ///      never moves backing, which is what stops an unfreeze being an upward move on authority.
    function payableValue(ReserveAsset storage r) internal view returns (uint256) {
        return r.frozenRedeem ? 0 : idleAfterCustodyLoss(r) * r.scale;
    }

    /// @notice Recorded physical custody, including deferred claims and net of known losses.
    function custodiedUnits(ReserveAsset storage r) internal view returns (uint256) {
        return r.units + r.deferredUnits - r.unappliedCustodyLossUnits;
    }

    /// @notice Refreshes one asset's custody ledger from its currently held units.
    /// @dev Shared by permissionless observation and authorized ratification. It reads only the
    ///      selected asset and latches only incremental loss; aggregate backing views remain local.
    function reconcileCustody(ReserveStorage storage $, address asset) internal returns (uint256 shortfall) {
        ReserveAsset storage r = requireListed($, asset);
        uint256 live = IERC20(asset).balanceOf(address(this));
        uint256 owed = custodiedUnits(r);
        if (owed > live) {
            shortfall = owed - live;
            uint256 units = r.units;
            uint256 debit = shortfall < units ? shortfall : units;
            writeAsset($, r, units - debit, r.cap, r.recognizedCapLoss, r.frozenRedeem);
            uint256 unapplied = shortfall - debit;
            if (unapplied != 0) {
                setUnappliedCustodyLoss($, asset, r.unappliedCustodyLossUnits + unapplied);
                $.pendingUnappliedCustodyLossUnits[asset] += unapplied;
            }
            r.custodyShortfallUnits += shortfall;
            $.totalCustodyShortfallValue += shortfall * r.scale;
        }
        emit IReserveManager.IdleUnitsReconciled(asset, owed, live, shortfall, r.custodyShortfallUnits);
    }

    /// @notice Idle units remaining after reserving the deficit against deferred obligations.
    function idleAfterCustodyLoss(ReserveAsset storage r) internal view returns (uint256) {
        uint256 loss = r.unappliedCustodyLossUnits;
        return r.units > loss ? r.units - loss : 0;
    }

    /// @dev Single writer of the unapplied loss and its value/payable caches. Existing idle and
    ///      cap-mark fields retain their meanings; a later deposit does not erase either mark.
    function setUnappliedCustodyLoss(ReserveStorage storage $, address asset, uint256 newUnits) internal {
        ReserveAsset storage r = $.assets[asset];
        uint256 previous = r.unappliedCustodyLossUnits;
        uint256 payBefore = payableValue(r);
        r.unappliedCustodyLossUnits = newUnits;
        $.totalUnappliedCustodyLossValue = $.totalUnappliedCustodyLossValue - previous * r.scale + newUnits * r.scale;
        $.totalPayableIdleValue = $.totalPayableIdleValue - payBefore + payableValue(r);
        emit IReserveManager.UnappliedCustodyLossUpdated(asset, previous, newUnits, $.totalUnappliedCustodyLossValue);
    }

    /// @dev A proved recovery first releases its own unapplied loss, then restores the part
    ///      previously debited from idle. The caller bounds recovery by delivered surplus and
    ///      its pending or arm-specific capacity before invoking this helper.
    function restoreCustody(ReserveStorage storage $, address asset, uint256 units, uint256 unappliedAvailable)
        internal
        returns (uint256 released)
    {
        ReserveAsset storage r = $.assets[asset];
        released = units < unappliedAvailable ? units : unappliedAvailable;
        if (released != 0) setUnappliedCustodyLoss($, asset, r.unappliedCustodyLossUnits - released);
        uint256 idleRestored = units - released;
        if (idleRestored != 0) writeAsset($, r, r.units + idleRestored, r.cap, r.recognizedCapLoss, r.frozenRedeem);
    }

    /// @notice THE SINGLE WRITER of `units`, `cap`, `recognizedCapLoss` and `frozenRedeem`.
    /// @dev Both O(1) aggregates are recomputed here from the before/after delta with checked
    ///      arithmetic. setUnappliedCustodyLoss also updates the payable aggregate when its
    ///      separate loss deduction changes. No repair setter exists anywhere in the contract: a "recompute" door would
    ///      be an upward move on authority. The guarantee is instead the named invariant
    ///      `invariant_idleAggregates_equalTheIndependentSum`, an independent O(N) recompute over
    ///      `assetList` fuzzed against both caches.
    function writeAsset(
        ReserveStorage storage $,
        ReserveAsset storage r,
        uint256 newUnits,
        uint256 newCap,
        uint256 newCapLoss,
        bool newFrozenRedeem
    ) internal {
        uint256 backBefore = contribution(r);
        uint256 payBefore = payableValue(r);
        r.units = newUnits;
        r.cap = newCap;
        r.recognizedCapLoss = newCapLoss;
        r.frozenRedeem = newFrozenRedeem;
        uint256 backAfter = contribution(r);
        uint256 payAfter = payableValue(r);
        $.totalIdleBackingValue = $.totalIdleBackingValue - backBefore + backAfter;
        $.totalPayableIdleValue = $.totalPayableIdleValue - payBefore + payAfter;
    }

    /// @notice THE SINGLE MEASURED-RECEIPT PULL, shared by the proxy and by every linked library.
    /// @dev Fee-on-transfer is closed at source: the balance delta must equal the requested amount
    ///      EXACTLY, so nothing is ever credited that did not arrive. Declared once here rather than
    ///      restated per caller, because two enumerations of a receipt rule are two places for it to
    ///      drift.
    /// @param asset The token to pull.
    /// @param from The payer, who must have approved this contract.
    /// @param amount Native units requested.
    /// @return received Native units that actually arrived; always equal to `amount` on success.
    function pullExact(address asset, address from, uint256 amount) internal returns (uint256 received) {
        IERC20 token = IERC20(asset);
        uint256 beforeBalance = token.balanceOf(address(this));
        SafeERC20.safeTransferFrom(token, from, address(this), amount);
        received = token.balanceOf(address(this)) - beforeBalance;
        if (received == 0) revert IReserveManager.ReserveManager_NoValueReceived();
        if (received != amount) revert IReserveManager.ReserveManager_UnexpectedReceipt(asset, amount, received);
    }

    /// @dev Resolves a listed asset or reverts. Every asset-taking entry point starts here.
    function requireListed(ReserveStorage storage $, address asset) internal view returns (ReserveAsset storage r) {
        r = $.assets[asset];
        if (!r.listed) revert IReserveManager.ReserveManager_AssetNotListed(asset);
    }

    /// @notice The R4-01 gate: nobody exits at par while an adjudicated custody loss is unallocated.
    /// @dev STORAGE ONLY, and deliberately GLOBAL. It is a LOSS predicate, not a token-liveness
    ///      predicate: a reverting, paused or gas-bombing token produces no latch at all (its own
    ///      `reconcileIdleUnits` reverts locally) and therefore freezes nothing. Allocation is
    ///      protocol-wide because supply is protocol-wide.
    function requireCustodied(ReserveStorage storage $) internal view {
        uint256 latched = $.totalCustodyShortfallValue;
        if (latched != 0) revert IReserveManager.ReserveManager_IdleCustodyShortfall(latched);
    }

    /// @dev O(1), storage-only backing: recorded idle after cap marks plus net receivables,
    ///      less pending withdrawal claims and known custody loss outside the idle tallies.
    ///      A deferred shortage can exceed one asset's idle value, so its full-face deduction
    ///      belongs at portfolio level. The result is floored at zero. No token, price or oracle
    ///      read occurs here. Ratification retains the deduction; only delivered recovery
    ///      releases it, through the corresponding pending or arm-specific loss record.
    function backingValue(ReserveStorage storage $) internal view returns (uint256) {
        uint256 gross = $.totalIdleBackingValue + ($.totalDeployedPrincipal - $.totalPrincipalImpairment)
            + ReserveAccrualStorageLib.unposted();
        uint256 owed = $.totalClaimValue + $.totalUnappliedCustodyLossValue;
        return gross > owed ? gross - owed : 0;
    }

    /// @notice Whether the selected reserve currency still awaits loss assessment.
    /// @dev Uses the arm state independently of idle units, incoming receipts and token liveness.
    function adjudicationPending(ReserveStorage storage $, address asset) internal view returns (bool) {
        uint256 armId = $.activeArmOf[asset];
        return armId != 0 && $.arms[armId].state == IReserveManager.ArmState.Armed;
    }

    /// @notice Native units of one asset a basket or a recorded draw may actually allocate.
    /// @dev Storage only: a redeem freeze zeroes it; known custody loss and units already
    ///      promised to a pending claim are reserved out of the idle tally. Reserving rather than
    ///      debiting is what keeps `reconcileIdleUnits` honest - the units are physically held and
    ///      still counted as owed, so custody still balances.
    /// @param $ The reserve's ERC-7201 storage.
    /// @param asset The listed asset.
    /// @return units Allocatable native units; zero when redeem-frozen or fully reserved.
    function availableUnits(ReserveStorage storage $, address asset) internal view returns (uint256 units) {
        ReserveAsset storage r = $.assets[asset];
        if (r.frozenRedeem) return 0;
        uint256 held = idleAfterCustodyLoss(r);
        uint256 reserved = $.claimedUnits[asset];
        return held > reserved ? held - reserved : 0;
    }

    /// @notice The effective mint price for one asset, and why it is or is not usable.
    /// @dev STORAGE ONLY. No external call, no oracle, no `block.number`. THE PAR CAP IS APPLIED
    ///      HERE AND NOWHERE ELSE, so no second caller can skip it, and it is what makes a credit
    ///      unable to exceed the increase in backing (ADR-0038 section 1).
    ///
    ///      EVERY GUARD REFUSES THE MINT RATHER THAN FALLING BACK TO PAR. That is one deleted `if`
    ///      away from being false, and ADR-0038 records why it must not be: a silent fallback to par
    ///      reopens the free option during exactly the outage an attacker would choose.
    ///
    ///      `asOf` is the ATTESTED observation time. `AttestationOracle.attest` already refuses a
    ///      future `asOf`, so the staleness comparison can neither underflow nor be gamed forward.
    /// @param $ The reserve's ERC-7201 storage.
    /// @param asset The listed asset.
    /// @return effective `min(price, 1e18)`, or zero when the price is not usable.
    /// @return reason 0 live, 1 never pushed, 2 stale, 3 below floor, 4 no floor configured.
    function effectiveMintPrice(ReserveStorage storage $, address asset)
        internal
        view
        returns (uint256 effective, uint8 reason)
    {
        AssetPrice storage p = $.assetPrices[asset];
        uint64 asOf = p.asOf;
        if (asOf == 0) return (0, 1);
        if (block.timestamp > uint256(asOf) + $.priceMaxAge) return (0, 2);
        uint256 floor_ = p.floor;
        // An UNCONFIGURED floor is not a floor. Refusing here is what stops an asset being minted
        // against with no lower bound at all merely because governance has not reached it yet.
        if (floor_ == 0) return (0, 4);
        uint256 raw = p.price;
        if (raw < floor_) return (0, 3);
        effective = raw > ONE ? ONE : raw;
    }
}
