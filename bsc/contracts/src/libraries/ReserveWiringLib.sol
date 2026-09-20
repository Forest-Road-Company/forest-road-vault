// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IAttestationOracle} from "../interfaces/IAttestationOracle.sol";
import {ICuratorModule} from "../interfaces/ICuratorModule.sol";
import {IMintRedeemController} from "../interfaces/IMintRedeemController.sol";
import {IReserveLossAbsorber} from "../interfaces/IReserveLossAbsorber.sol";
import {IReserveLossTimelock} from "../interfaces/IReserveLossGovernance.sol";
import {IReserveManager} from "../interfaces/IReserveManager.sol";
import {IsUSDfr} from "../interfaces/IsUSDfr.sol";
import {Config} from "./Config.sol";
import {ReserveStorageLib} from "./ReserveStorageLib.sol";
import {ReserveAccrualStorageLib} from "./ReserveAccrualStorageLib.sol";

/// @title ReserveWiringLib - deployment- and governance-time configuration for ReserveManager
/// @notice Holds module/asset configuration and measured deposit, custody-reconciliation and repair edges.
/// @dev EIP-170. These are `public` library functions, so they are deployed separately and reached
///      by `delegatecall`; only public/external library functions buy space, an `internal` one
///      inlines and saves nothing. Native custody methods preserve the reserve's original measured
///      receipt and storage-ledger order. No live token read is added to aggregate backing.
///
///      A `delegatecall` into a library keeps `msg.sender`, `address(this)` and storage. Role
///      checks, `nonReentrant` and `whenNotPaused` therefore stay in the PROXY-SIDE function and
///      are never relied upon inside this library.
///      Each public entry resolves the same fixed reserve namespace formerly supplied by the
///      proxy as its first argument. This removes repeated ABI encoding without changing the
///      storage destination, validation order, native accounting or external return types.
library ReserveWiringLib {
    using ReserveStorageLib for ReserveStorageLib.ReserveStorage;

    /// @notice Latches only the incremental shortage beyond custody losses already recorded.
    /// @dev The host retains nonReentrant and continuous-accounting admission.
    function reconcileIdleUnits(address asset) public returns (uint256 shortfall) {
        return ReserveStorageLib.reconcileCustody(ReserveStorageLib.layout(), asset);
    }

    /// @notice Clears only a latched shortage supported by currently delivered surplus tokens.
    function cureCustodyShortfall(address asset) public returns (uint256 credited) {
        ReserveStorageLib.ReserveStorage storage $ = ReserveStorageLib.layout();
        ReserveStorageLib.ReserveAsset storage r = $.requireListed(asset);
        uint256 latch = r.custodyShortfallUnits;
        uint256 owed = ReserveStorageLib.custodiedUnits(r);
        uint256 live = IERC20(asset).balanceOf(address(this));
        if (latch == 0 || live <= owed) revert IReserveManager.ReserveManager_NoCustodyShortfall(asset);
        uint256 surplus = live - owed;
        uint256 units = surplus < latch ? surplus : latch;
        r.custodyShortfallUnits = latch - units;
        credited = units * r.scale;
        $.totalCustodyShortfallValue -= credited;
        uint256 pending = $.pendingUnappliedCustodyLossUnits[asset];
        $.pendingUnappliedCustodyLossUnits[asset] = pending - $.restoreCustody(asset, units, pending);
        emit IReserveManager.CustodyShortfallCured(asset, units, latch - units);
    }

    /// @notice Measures a voluntary recapitalization and preserves the existing per-asset cap.
    /// @dev Receipts do not change which deposit records may exit during a currency review.
    ///      Withdrawal admission is enforced by the controller and reserve settlement paths.
    function recapitalize(address asset, uint256 amount) public returns (uint256 credited) {
        ReserveStorageLib.ReserveStorage storage $ = ReserveStorageLib.layout();
        if (amount == 0) revert IReserveManager.ReserveManager_ZeroAmount();
        ReserveStorageLib.ReserveAsset storage r = $.requireListed(asset);
        uint256 scale = r.scale;
        credited = amount * scale;
        uint256 attempted = r.units * scale + credited;
        if (attempted > r.cap) revert IReserveManager.ReserveManager_AssetCapExceeded(asset, r.cap, attempted);
        uint256 received = ReserveStorageLib.pullExact(asset, msg.sender, amount);
        $.writeAsset(r, r.units + received, r.cap, r.recognizedCapLoss, r.frozenRedeem);
        emit IReserveManager.Recapitalized(asset, msg.sender, received, credited, $.backingValue(), $.reserveDeficit);
    }

    /// @notice Maximum number of reserve assets the registry will ever admit.
    /// @dev OWNER DECISION, open question O-2, defaulted to the spec's recommendation. The value is
    ///      sized so the basket's three passes stay cheap and bounded; it is immutable in spirit
    ///      once assets are listed, because the listing order it caps is append-only and the dust
    ///      rule and the event register both depend on that order never being renumbered.
    uint256 internal constant MAX_RESERVE_ASSETS = 8;

    /// @notice Ceiling on any single asset's mint fee, in basis points.
    /// @dev OWNER DECISION, open question O-3, defaulted to the spec's recommendation of 5%. The
    ///      fee sets the STRIKE of the depeg free option, it does not remove it, and a fee wide
    ///      enough to close a March-2023-sized depeg would tax every honest mint. The number is a
    ///      Forest Road economic decision; this default assumes only that it must be bounded.
    uint16 internal constant MAX_MINT_FEE_BPS = 500;

    /// @notice Representability ceiling on a latched reserve-asset price, 18 decimals.
    /// @dev MUST EQUAL `AttestationOracle.MAX_ATTESTED_PRICE`. It is restated rather than imported
    ///      because the reserve does not otherwise depend on the oracle's implementation, and the
    ///      reserve must be able to refuse a magnitude on its own rather than trusting the pusher.
    ///      NOT an economic number: see the oracle's constant for why an absurd magnitude accepted
    ///      once would brick the series against the deviation bound.
    uint256 internal constant MAX_ATTESTED_PRICE = 2e18;

    /// @notice Engineering ceiling on the global price staleness bound.
    /// @dev The VALUE of `priceMaxAge` is a Forest Road decision (spec 06 section 5): it must exceed the
    ///      keeper's push interval by enough to cover one missed push plus inclusion latency, and be
    ///      SHORTER than the time a human guardian takes to react, because staleness is the
    ///      automatic backstop for a sleeping guardian. This constant only stops a mistyped value
    ///      disabling staleness entirely, which would silently remove that backstop.
    uint64 internal constant MAX_PRICE_MAX_AGE = 7 days;

    /// @notice Engineering ceiling on the global per-update price deviation bound, in bps.
    /// @dev The VALUE is a Forest Road decision (spec 06 section 5, section 10(3)); the bound trades liveness
    ///      against blast radius in both directions and is SYMMETRIC by recommendation. This
    ///      constant only stops a setting so wide that a single compromised quorum could move the
    ///      credit arbitrarily in one push, which is the state the guard exists to prevent.
    uint16 internal constant MAX_PRICE_DEVIATION_BPS = 2_000;

    /// @notice Admits a reserve asset after asserting its declared decimals against the token.
    /// @dev The `decimals()` read is an EXTERNAL read, deliberately, at the listing edge where a
    ///      failure is local and the act is a timelocked governance act. A token that cannot answer
    ///      `decimals()` cannot be listed. `scale` is recorded from the ASSERTED value, never from
    ///      the raw read. `units` is initialised to zero even if the reserve already holds a balance
    ///      of `asset`: a pre-existing balance is a donation and stays unrecognised.
    ///
    ///      A zero `cap` is legal. Such an asset is payable in the basket and closed to mint, which
    ///      is the "listed at zero weight until funded" case ADR-0037 contemplates.
    ///
    ///      There is no `removeReserveAsset`. `listed` never returns to false, so a delisted and
    ///      relisted asset cannot reset a tally, and removing an entry would renumber the fixed
    ///      index order the basket's dust rule and the event register depend on. Removing an asset
    ///      from BACKING is done by cutting its cap, which is a mark that reaches the cascade.
    ///      "Accepted for mint/redeem" is `frozenMint`/`frozenRedeem`; "recognized backing value"
    ///      is the capped contribution. They are different fields and neither implies the other.
    /// @param asset The candidate token.
    /// @param expectedDecimals The decimals governance asserts, checked against the token.
    /// @param cap The 18-decimal exposure ceiling; may be zero.
    /// @param mintFeeBps The per-asset mint fee the controller carves; never charged here.
    /// @param admissionEvidenceHash Commitment to the per-asset admission review.
    function addAsset(
        address asset,
        uint8 expectedDecimals,
        uint256 cap,
        uint16 mintFeeBps,
        bytes32 admissionEvidenceHash
    ) public {
        ReserveStorageLib.ReserveStorage storage $ = ReserveStorageLib.layout();
        if (asset == address(0)) revert IReserveManager.ReserveManager_ZeroAddress();
        if (asset.code.length == 0) revert IReserveManager.ReserveManager_AssetNotContract(asset);
        ReserveStorageLib.ReserveAsset storage r = $.assets[asset];
        if (r.listed) revert IReserveManager.ReserveManager_AssetAlreadyListed(asset);
        uint256 index = $.assetList.length;
        if (index >= MAX_RESERVE_ASSETS) revert IReserveManager.ReserveManager_AssetLimitReached();
        if (expectedDecimals > 18) revert IReserveManager.ReserveManager_UnsupportedDecimals(asset, expectedDecimals);
        uint8 observed = IERC20Metadata(asset).decimals();
        if (observed != expectedDecimals) {
            revert IReserveManager.ReserveManager_DecimalsMismatch(asset, expectedDecimals, observed);
        }
        // Shape probe: a candidate must answer `balanceOf` with a full word.
        (bool ok,) = readStaticWordWithArg(asset, IERC20.balanceOf.selector, address(this));
        if (!ok) revert IReserveManager.ReserveManager_AssetNotERC20(asset);
        if (mintFeeBps > MAX_MINT_FEE_BPS) revert IReserveManager.ReserveManager_MintFeeTooHigh(mintFeeBps);
        // Commits to the per-asset admission review; the review is consumed by every listing.
        if (admissionEvidenceHash == bytes32(0)) revert IReserveManager.ReserveManager_ZeroEvidenceHash();

        uint64 scale = uint64(10 ** (18 - uint256(expectedDecimals)));
        r.decimals = expectedDecimals;
        r.listed = true;
        r.mintFeeBps = mintFeeBps;
        r.listedAt = uint32(block.timestamp);
        r.scale = scale;
        r.cap = cap;
        $.assetList.push(asset);
        emit IReserveManager.ReserveAssetListed(
            asset, expectedDecimals, scale, cap, mintFeeBps, admissionEvidenceHash, index
        );
    }

    /// @notice Sets one asset's 18-decimal exposure ceiling, recognizing any cut below the tally.
    /// @dev A cap cut BELOW the standing tally is a governance-written mark that reaches the
    ///      cascade: backing falls at once, mint closes for that asset, and the next direct exit
    ///      prices sub-par and draws junior capital. `approvedMaxLoss` and the non-zero evidence
    ///      hash are therefore not decoration; they give the proposal the same bounded shape
    ///      `ratifyAndOpen` has and stop one mistyped parameter from zeroing the book.
    ///
    ///      RAISING THE CAP BACK RESTORES NOTHING. With par 100 and cap 100 cut to 60, the
    ///      recognized cap loss is 40 and the contribution is 60; raising the cap to 100 leaves it
    ///      at 60. A repayment of 20 units does raise it, to 80, because units actually arrived.
    ///      That asymmetry is why `recognizedCapLoss` is a separate ledger rather than a naive
    ///      `min(par, cap)`: a "refuse a raise while par > cap" guard would have permanently
    ///      trapped that repaid cash as unrecognised.
    /// @param asset The listed asset.
    /// @param newCap The new 18-decimal ceiling.
    /// @param approvedMaxLoss Ceiling on the backing loss this act may recognize.
    /// @param evidenceHash Commitment to the proposal record; may not be zero.
    function setCap(address asset, uint256 newCap, uint256 approvedMaxLoss, bytes32 evidenceHash) public {
        ReserveStorageLib.ReserveStorage storage $ = ReserveStorageLib.layout();
        if (evidenceHash == bytes32(0)) revert IReserveManager.ReserveManager_ZeroEvidenceHash();
        ReserveStorageLib.ReserveAsset storage r = ReserveStorageLib.requireListed($, asset);
        uint256 previousCap = r.cap;
        uint256 capLoss = r.recognizedCapLoss;
        uint256 par = r.units * r.scale;
        uint256 net = par > capLoss ? par - capLoss : 0;
        // `valueBefore` IS THE UNCLAMPED CONTRIBUTION, and that is the whole of the fix applied on
        // Forest Road direction after review. It was briefly `min(net, previousCap)`, on the theory
        // that a cut may only recognize how far the CEILING moved over the part of the position it
        // covered. That bounded the recognisable loss by `previousCap` and broke delisting: with
        // par 100 and cap 40 - reachable because `pay` deliberately ignores the ceiling - cutting
        // the cap to zero to remove a worthless asset from backing wrote down only 40 and left 60
        // counted, and repeating the call recognized nothing further because `previousCap` was then
        // zero. `addAsset`'s NatSpec names a cap cut as the ONLY way to remove an asset from
        // backing, so that mechanism has to reach the whole position.
        //
        // THE "PHANTOM" LOSS THIS AVOIDED IS NOT PHANTOM. With par above the ceiling, governance
        // moving the ceiling to or below where it already stands means "cap my recognised exposure
        // here", and writing the excess down is the act, not an accident. It is idempotent from the
        // second call: the first cut leaves `net == newCap`, so every repeat recognizes zero.
        //
        // BUT ONLY A CUT MAY WRITE ANYTHING DOWN, AND THE DIRECTION TEST IS LOAD-BEARING. An
        // earlier draft of this fix measured unclamped on EVERY call, which turned a RAISE into a
        // write-down whenever par already exceeded the ceiling: par 1000 with cap 100 raised to 200
        // recognized 800, because `valueAfter` was clamped to the new cap while `valueBefore` was
        // not. `CapArithmeticInvariants` caught it immediately once the campaign could reach an
        // over-cap tally. `newCap <= previousCap` is what keeps ADR-0025's "up only on proof" true:
        // a raise restores nothing AND takes nothing.
        uint256 valueBefore = net;
        uint256 valueAfter = net < newCap ? net : newCap;
        if (newCap <= previousCap && valueAfter < valueBefore) {
            uint256 recognized = valueBefore - valueAfter;
            if (recognized > approvedMaxLoss) {
                revert IReserveManager.ReserveManager_CapCutExceedsApproval(recognized, approvedMaxLoss);
            }
            capLoss += recognized;
            emit IReserveManager.ReserveAssetCapLossRecognized(asset, valueBefore, valueAfter, recognized, evidenceHash);
        }
        ReserveStorageLib.writeAsset($, r, r.units, newCap, capLoss, r.frozenRedeem);
        emit IReserveManager.ReserveAssetCapSet(asset, previousCap, newCap, evidenceHash);
    }

    /// @notice Sets the per-asset mint fee the controller carves from the minter's USDfr credit.
    /// @dev The fee is stored so the registry is one source of truth and the post-deploy validator
    ///      can assert it. It is NEVER charged here: charging it in the reserve would make the fee
    ///      reserve surplus, which is layer zero of the cascade.
    /// @param asset The listed asset.
    /// @param mintFeeBps The new fee in basis points.
    function setMintFee(address asset, uint16 mintFeeBps) public {
        ReserveStorageLib.ReserveStorage storage $ = ReserveStorageLib.layout();
        if (mintFeeBps > MAX_MINT_FEE_BPS) revert IReserveManager.ReserveManager_MintFeeTooHigh(mintFeeBps);
        ReserveStorageLib.ReserveAsset storage r = ReserveStorageLib.requireListed($, asset);
        uint16 previous = r.mintFeeBps;
        r.mintFeeBps = mintFeeBps;
        emit IReserveManager.ReserveAssetMintFeeSet(asset, previous, mintFeeBps);
    }

    /// @notice Sets one asset's freeze flags in one direction.
    /// @dev The Guardian freezes DOWN, instantly, with no external read; the timelock lifts. The
    ///      caller-side role check enforces that asymmetry, and it is exactly why a freeze must not
    ///      touch backing: if it did, the lift would be an upward move on authority. A redeem
    ///      freeze goes through the single tally writer so the payable aggregate stays exact.
    /// @param asset The listed asset.
    /// @param mint Whether to change the mint flag.
    /// @param redeem Whether to change the redeem flag.
    /// @param frozen The value to set the selected flags to.
    function setFreeze(address asset, bool mint, bool redeem, bool frozen) public {
        ReserveStorageLib.ReserveStorage storage $ = ReserveStorageLib.layout();
        if (!mint && !redeem) revert IReserveManager.ReserveManager_NoFreezeFlagsSelected();
        ReserveStorageLib.ReserveAsset storage r = ReserveStorageLib.requireListed($, asset);
        if (mint) r.frozenMint = frozen;
        if (redeem) ReserveStorageLib.writeAsset($, r, r.units, r.cap, r.recognizedCapLoss, frozen);
        emit IReserveManager.ReserveAssetFreezeSet(asset, r.frozenMint, r.frozenRedeem);
    }

    /// @notice Pulls an exact amount of a listed reserve asset into recorded idle custody.
    /// @dev EIP-170: the body lives here and the proxy keeps only the role check and the guards,
    ///      because the proxy is the size-constrained contract. Reached by `delegatecall`, so
    ///      `address(this)` is still the reserve and every write lands in reserve storage.
    ///
    ///      A zero `holder` means "credit no deposit record", which is the correct behaviour for a
    ///      credit-side repayment: nobody deposited those units against a USDfr claim, so nobody may
    ///      withdraw them under the ADR-0038 record cap.
    /// @param asset The listed reserve asset.
    /// @param from The address the units are pulled from.
    /// @param holder The depositor whose record is credited; zero to credit none.
    /// @param amount Native units.
    /// @return credited The 18-decimal value recognized.
    function deposit(address asset, address from, address holder, uint256 amount) public returns (uint256 credited) {
        ReserveStorageLib.ReserveStorage storage $ = ReserveStorageLib.layout();
        ReserveStorageLib.ReserveAsset storage r = ReserveStorageLib.requireListed($, asset);
        if (r.frozenMint) revert IReserveManager.ReserveManager_AssetMintFrozen(asset);
        if (from == address(0)) revert IReserveManager.ReserveManager_ZeroAddress();
        if (amount == 0) revert IReserveManager.ReserveManager_ZeroAmount();
        // The cap is checked on the REQUESTED amount, before the pull. `pullExact` then proves the
        // balance delta equals that amount exactly, so the two are the same number and the check
        // stays ahead of the interaction.
        uint256 scale = r.scale;
        credited = amount * scale;
        uint256 attempted = r.units * scale + credited;
        if (attempted > r.cap) revert IReserveManager.ReserveManager_AssetCapExceeded(asset, r.cap, attempted);
        uint256 received = ReserveStorageLib.pullExact(asset, from, amount);
        ReserveStorageLib.writeAsset($, r, r.units + received, r.cap, r.recognizedCapLoss, r.frozenRedeem);
        if (holder != address(0)) {
            // The record grows by the units that ACTUALLY ARRIVED, never by the requested amount.
            // `pullExact` already proves those are equal; recording the measured figure keeps the
            // record a receipt rather than an assertion, which is the rule the tally follows too.
            uint256 recordAfter = $.depositRecord[holder][asset] + received;
            $.depositRecord[holder][asset] = recordAfter;
            emit IReserveManager.DepositRecorded(holder, asset, received, recordAfter);
        }
        emit IReserveManager.AssetDeposited(asset, from, amount, credited);
    }

    // ------------------------- ADR-0038 price path -------------------------

    /// @notice Latches the attested price for `asset` into reserve storage.
    /// @dev PERMISSIONLESS, and THE ONLY EXTERNAL READ ON THE PRICE PATH. It sits at the EDGE, so
    ///      an unreachable or reverting oracle makes only this call fail: no latch moves, no backing
    ///      moves, and nothing else in the contract is touched. That is the same doctrine
    ///      `reconcileIdleUnits` follows and the same reason ADR-0025 gives for putting external
    ///      reads at edges.
    ///
    ///      THE SUBJECT IS DERIVED, NEVER SUPPLIED. `uint256(uint160(asset))` is computed here from
    ///      the asset the caller named and this function asserted listed, so no caller can latch one
    ///      asset's record onto another asset's slot.
    ///
    ///      A REFUSED PUSH EMITS NOTHING, because it reverts. Monitoring watches its own failed
    ///      transactions and the growing age of `asOf`; that is stated in the runbook rather than
    ///      papered over with a `try`/`catch` that would swallow the failure.
    ///      IT RETURNS NOTHING ON PURPOSE. `ReserveAssetPriceSynced` carries the price and its
    ///      `asOf`, so a keeper reads the outcome from the log rather than from a return value, and
    ///      the proxy is spared a return encoder it does not have the EIP-170 room for.
    /// @param asset The listed reserve asset.
    function syncAssetPrice(address asset) public {
        ReserveStorageLib.ReserveStorage storage $ = ReserveStorageLib.layout();
        ReserveStorageLib.requireListed($, asset);
        address oracle = $.priceOracle;
        if (oracle == address(0)) revert IReserveManager.ReserveManager_PriceOracleUnset();

        (bytes32 payload, uint64 attestedAsOf, bool satisfied) = IAttestationOracle(oracle).latestPayload(
            uint256(uint160(asset)), IAttestationOracle.AttestationKind.ReserveAssetPrice
        );
        if (!satisfied) revert IReserveManager.ReserveManager_PriceNotAttested(asset);
        uint256 proposed = uint256(payload);
        if (proposed == 0 || proposed > MAX_ATTESTED_PRICE) {
            revert IReserveManager.ReserveManager_PriceOutOfRange(asset, proposed);
        }

        ReserveStorageLib.AssetPrice storage rec = $.assetPrices[asset];
        uint64 latchedAsOf = rec.asOf;
        // Idempotence: re-latching the same observation is a no-op that must not pretend to be an
        // update, and a strictly-newer rule is the same anti-rollback shape the oracle enforces.
        if (attestedAsOf <= latchedAsOf) {
            revert IReserveManager.ReserveManager_PriceNotNewer(asset, attestedAsOf, latchedAsOf);
        }

        uint256 previous = rec.price;
        // THE PER-UPDATE DEVIATION BOUND. The FIRST push after listing has no reference and is
        // exempt; it is bounded instead by `MAX_ATTESTED_PRICE` above, and by the floor and the par
        // cap on read.
        if (latchedAsOf != 0) {
            uint16 maxBps = $.priceMaxDeviationBps;
            uint256 move = proposed > previous ? proposed - previous : previous - proposed;
            if (move * uint256(Config.BPS) > previous * uint256(maxBps)) {
                revert IReserveManager.ReserveManager_PriceDeviationExceeded(asset, previous, proposed, maxBps);
            }
        }

        rec.price = uint128(proposed);
        rec.asOf = attestedAsOf;
        emit IReserveManager.ReserveAssetPriceSynced(asset, previous, proposed, attestedAsOf, msg.sender);
    }

    /// @notice Binds the price oracle and sets the global staleness and deviation guards.
    /// @dev The oracle must answer the price kind's threshold as a complete first word, which fails
    ///      closed against a permissive fallback, a proxy with an empty implementation slot, or a
    ///      Safe at this address; and that threshold must be at least two, because a single-key
    ///      authority over a mint-side input is not acceptable. Rebinding is refused while any loss
    ///      condition is live, exactly as the other module bindings are.
    /// @param oracle The AttestationOracle whose records this reserve latches.
    /// @param maxAge Staleness bound in seconds. OWNER DECISION; bounded above here only.
    /// @param maxDeviationBps Symmetric per-update bound in bps. OWNER DECISION; bounded here only.
    function setPriceGuards(address oracle, uint64 maxAge, uint16 maxDeviationBps) public {
        ReserveStorageLib.ReserveStorage storage $ = ReserveStorageLib.layout();
        requireRebindAllowed($);
        if (
            maxAge == 0 || maxAge > MAX_PRICE_MAX_AGE || maxDeviationBps == 0
                || maxDeviationBps > MAX_PRICE_DEVIATION_BPS
        ) {
            revert IReserveManager.ReserveManager_InvalidPriceGuards(maxAge, maxDeviationBps);
        }
        (bool ok, uint256 required) = readStaticWordWithSelectorArg(
            oracle,
            IAttestationOracle.threshold.selector,
            uint256(uint8(IAttestationOracle.AttestationKind.ReserveAssetPrice))
        );
        if (!ok || required < 2) revert IReserveManager.ReserveManager_InvalidPriceOracle(oracle);
        $.priceOracle = oracle;
        $.priceMaxAge = maxAge;
        $.priceMaxDeviationBps = maxDeviationBps;
        emit IReserveManager.ReservePriceGuardsSet(oracle, maxAge, maxDeviationBps);
    }

    /// @notice Sets one asset's absolute mint floor, below which minting in it refuses entirely.
    /// @dev A ZERO FLOOR IS REFUSED. It would reopen the credit-to-near-zero griefing with no
    ///      refusal at all, and `effectiveMintPrice` additionally treats an unset floor as "not
    ///      configured" so an asset is closed to minting until governance has chosen one. The floor
    ///      may not exceed par, because a floor above par would close an asset that is sound.
    ///
    ///      THE VALUE IS A FOREST ROAD DECISION, PER ASSET (spec 06 section 5). Too high and the asset
    ///      closes to mint on ordinary noise; too low and the protocol keeps accepting an asset the
    ///      market has repriced heavily, which is precisely what the floor exists to stop.
    /// @param asset The listed asset.
    /// @param floor The 18-decimal floor, in `(0, 1e18]`.
    function setAssetPriceFloor(address asset, uint256 floor) public {
        ReserveStorageLib.ReserveStorage storage $ = ReserveStorageLib.layout();
        ReserveStorageLib.requireListed($, asset);
        if (floor == 0 || floor > ReserveStorageLib.ONE) {
            revert IReserveManager.ReserveManager_InvalidPriceFloor(asset, floor);
        }
        ReserveStorageLib.AssetPrice storage rec = $.assetPrices[asset];
        uint256 previous = rec.floor;
        rec.floor = floor;
        emit IReserveManager.ReserveAssetPriceFloorSet(asset, previous, floor);
    }

    /// @notice Wires the controller used for supply, backing and loss-burn verification.
    /// @dev Fails closed on a controller that does not answer `modules()`, that is bound to a
    ///      different reserve, or whose USDfr is not a contract. Also caches `lossUSDfr`, which is
    ///      the token every cascade delivery is measured in.
    /// @param controller_ The candidate MintRedeemController.
    function bindController(address controller_) public {
        ReserveStorageLib.ReserveStorage storage $ = ReserveStorageLib.layout();
        requireRebindAllowed($);
        if (controller_ == address(0) || controller_.code.length == 0) {
            revert IReserveManager.ReserveManager_InvalidLossController(controller_);
        }
        address boundReserves;
        address usdfr_;
        try IMintRedeemController(controller_).modules() returns (address usdfr__, address, address reserves_) {
            usdfr_ = usdfr__;
            boundReserves = reserves_;
        } catch {
            revert IReserveManager.ReserveManager_InvalidLossController(controller_);
        }
        if (boundReserves != address(this) || usdfr_ == address(0) || usdfr_.code.length == 0) {
            revert IReserveManager.ReserveManager_InvalidLossController(controller_);
        }
        address previous = address($.lossController);
        $.lossController = IMintRedeemController(controller_);
        $.lossUSDfr = IERC20(usdfr_);
        emit IReserveManager.LossControllerSet(previous, controller_);
    }

    /// @notice Wires the two-layer custody cascade and the governance timing source.
    /// @dev ADR-0037 D3a(ii) and D3: neither a backstop nor a Governor is accepted, because neither
    ///      exists on this instance. Keeping a zero-address backstop parameter would be worse than
    ///      removing it: it preserves an installation door for a layer two the disclosure surface
    ///      says does not exist. The curator/vault cross-binding block is carried over verbatim.
    /// @param curator Cascade layer 1, curator first-loss.
    /// @param vault Cascade layer 2 on this instance: the sUSDfr senior vault.
    /// @param timelock The governance timelock whose `getMinDelay()` bounds the recognition path.
    function bindModules(address curator, address vault, address timelock) public {
        ReserveStorageLib.ReserveStorage storage $ = ReserveStorageLib.layout();
        requireRebindAllowed($);
        if (address($.lossController) == address(0)) {
            revert IReserveManager.ReserveManager_InvalidLossController(address(0));
        }
        if (curator == address(0) || curator.code.length == 0) {
            revert IReserveManager.ReserveManager_InvalidLossAbsorber(curator);
        }
        if (vault == address(0) || vault.code.length == 0) {
            revert IReserveManager.ReserveManager_InvalidLossAbsorber(vault);
        }

        address curatorUSDfr;
        address curatorVault;
        try ICuratorModule(curator).modules() returns (address usdfr_, address, address vault_) {
            curatorUSDfr = usdfr_;
            curatorVault = vault_;
        } catch {
            revert IReserveManager.ReserveManager_InvalidLossAbsorber(curator);
        }
        (bool curatorReserveReadable, address curatorReserve) =
            readStaticAddress(curator, ICuratorModule.reserveManager.selector);
        if (!curatorReserveReadable) revert IReserveManager.ReserveManager_InvalidLossAbsorber(curator);
        (bool vaultAssetReadable, address vaultAsset) = readStaticAddress(vault, IERC4626.asset.selector);
        if (!vaultAssetReadable) revert IReserveManager.ReserveManager_InvalidLossAbsorber(vault);
        if (
            curatorUSDfr != address($.lossUSDfr) || curatorVault != vault || curatorReserve != address(this)
                || vaultAsset != address($.lossUSDfr)
        ) revert IReserveManager.ReserveManager_InvalidLossAbsorber(curator);

        if (!timelockValid(timelock)) revert IReserveManager.ReserveManager_InvalidTimelock(timelock);

        $.lossCurator = ICuratorModule(curator);
        $.lossVault = IsUSDfr(vault);
        $.lossTimelock = timelock;
        emit IReserveManager.ReserveLossModulesSet(curator, vault, timelock);
    }

    /// @notice Wires the retained ADR-0034 compatibility absorber.
    /// @dev This is not a credit path. Custody recovery stays exclusively arm-bound through
    ///      `creditRecoveredIdleUnits`. The absorber must name this reserve as its own source, so a
    ///      loss absorber cannot be installed against the wrong accounting source.
    /// @param absorber The candidate absorber.
    function bindAbsorber(address absorber) public {
        ReserveStorageLib.ReserveStorage storage $ = ReserveStorageLib.layout();
        requireRebindAllowed($);
        (bool readable, address source) = readStaticAddress(absorber, IReserveLossAbsorber.reserveLossSource.selector);
        if (!readable || source != address(this)) {
            revert IReserveManager.ReserveManager_InvalidLossAbsorber(absorber);
        }
        address previous = address($.lossAbsorber);
        $.lossAbsorber = IReserveLossAbsorber(absorber);
        emit IReserveManager.LossAbsorberSet(previous, absorber);
    }

    /// @dev Rebinding is forbidden while any loss condition is live, so a module swap can never be
    ///      used to change who absorbs a loss that has already been observed.
    function requireRebindAllowed(ReserveStorageLib.ReserveStorage storage $) internal view {
        if (ReserveAccrualStorageLib.state().modules.token != address(0)) {
            revert IReserveManager.ReserveManager_ModuleRebindForbidden();
        }
        if (
            $.openArmCount != 0 || $.recognizedSupplyReduction != 0 || $.reserveDeficit != 0
                || $.totalCustodyShortfallValue != 0
        ) revert IReserveManager.ReserveManager_ModuleRebindForbidden();
        IMintRedeemController controller = $.lossController;
        if (address(controller) != address(0) && controller.totalUSDfr() > controller.backingValue()) {
            revert IReserveManager.ReserveManager_ModuleRebindForbidden();
        }
    }

    /// @dev Two things are checked and both are load-bearing: `getMinDelay()` is READABLE as
    ///      as a complete first word, which rejects empty replies from a fallback or a proxy with an
    ///      empty implementation slot, or a Safe at this address; and it is at least
    ///      `Config.TIMELOCK_MIN_DELAY`, so a timelock deployed with - or later retuned to - a
    ///      shorter delay than the protocol's own floor cannot become the timing source. The second
    ///      check is NEW relative to the Ethereum path: with the five Governor reads deleted,
    ///      readability alone would leave this predicate with nothing to fail on, and on an
    ///      instance whose sole proposer is also its sole canceller the delay IS the protection.
    function timelockValid(address timelock) internal view returns (bool) {
        (bool ok, uint256 minDelay) = readStaticWord(timelock, IReserveLossTimelock.getMinDelay.selector);
        if (!ok) return false;
        return minDelay >= Config.TIMELOCK_MIN_DELAY;
    }

    /// @dev Reads a complete first word and accepts trailing data. Empty and short replies fail.
    function readStaticWord(address target, bytes4 selector) internal view returns (bool ok, uint256 word) {
        if (target == address(0) || target.code.length == 0) return (false, 0);
        bytes memory data;
        (ok, data) = target.staticcall(abi.encodeWithSelector(selector));
        if (!ok || data.length < 32) return (false, 0);
        assembly ("memory-safe") {
            word := mload(add(data, 0x20))
        }
    }

    /// @dev As `readStaticWord`, for a selector taking one address argument.
    function readStaticWordWithArg(address target, bytes4 selector, address arg)
        internal
        view
        returns (bool ok, uint256 word)
    {
        if (target.code.length == 0) return (false, 0);
        bytes memory data;
        (ok, data) = target.staticcall(abi.encodeWithSelector(selector, arg));
        if (!ok || data.length < 32) return (false, 0);
        assembly ("memory-safe") {
            word := mload(add(data, 0x20))
        }
    }

    /// @dev As `readStaticWord`, for a selector taking one `uint256` argument. Kept separate from
    ///      the address form so neither probe silently widens the other's accepted call shape.
    function readStaticWordWithSelectorArg(address target, bytes4 selector, uint256 arg)
        internal
        view
        returns (bool ok, uint256 word)
    {
        if (target == address(0) || target.code.length == 0) return (false, 0);
        bytes memory data;
        (ok, data) = target.staticcall(abi.encodeWithSelector(selector, arg));
        if (!ok || data.length < 32) return (false, 0);
        assembly ("memory-safe") {
            word := mload(add(data, 0x20))
        }
    }

    /// @dev As `readStaticWord`, additionally rejecting a word that is not a clean address.
    function readStaticAddress(address target, bytes4 selector) internal view returns (bool ok, address value) {
        uint256 word;
        (ok, word) = readStaticWord(target, selector);
        if (!ok || word > type(uint160).max) return (false, address(0));
        value = address(uint160(word));
    }
}
