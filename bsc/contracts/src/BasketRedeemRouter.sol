// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IComplianceRegistry} from "./interfaces/IComplianceRegistry.sol";
import {IMintRedeemController} from "./interfaces/IMintRedeemController.sol";
import {IReserveManager} from "./interfaces/IReserveManager.sol";

/// @title BasketRedeemRouter - the periphery where a market call is allowed to live
/// @notice ADR-0037 D5(d) as amended by ADR-0038 and by the Forest Road direction of 2026-09-07.
///         `MintRedeemController.redeem` pays IN KIND and has no function by which a redeemer NAMES
///         an asset. It pays a redeemer THE ASSETS THAT REDEEMER THEMSELVES DEPOSITED, capped by
///         their own deposit record, and the PRO-RATA BASKET for the remainder. A holder who wants
///         to end up in a DIFFERENT asset from the one the protocol owes them uses this contract: it
///         redeems on their behalf, swaps the legs they did not want AT MARKET, in their own
///         transaction, under their own slippage bound, and forwards everything to them.
///
/// @dev WHAT THE RECORD-CAPPED EXIT MEANS FOR THIS CONTRACT, AND IT IS THE FIRST THING TO READ.
///      The reserve draws THE REDEEMER'S OWN record, and on this path the redeemer of record is THE
///      ROUTER, because the router is what burns and what the reserve pays. The router never
///      deposits, so it has no record, so every redemption routed through it settles ENTIRELY ON THE
///      PRO-RATA BASKET. Three consequences, all of them stated rather than left to be discovered:
///
///        1. THE ROUTER IS NOT A WAY AROUND THE RECORD CAP, AND THAT IS ENFORCED, NOT ASSUMED. The
///           cap stops a holder converting an impaired asset into a sound one at the expense of the
///           holders who stay. Routing does not reach past it: the router cannot draw ANY address's
///           record, its own included, because it has none, and `_assertNoRecord` refuses the whole
///           call if it ever acquires one. What the router hands back is the reserve's own mix,
///           which involves no choice and therefore shifts no currency risk, converted at whatever
///           the market charges AT THE HOLDER'S OWN COST. Nothing here is subsidised.
///
///        2. A DEPOSITOR WHO WANTS THE ASSET THEY DEPOSITED SHOULD NOT ROUTE. Redeeming DIRECTLY on
///           the controller is what the record entitles them to: it pays them their own asset at one
///           to one, with no market leg, no slippage and no swap fee. Routing would pay them the
///           basket instead and then charge them a market to get back to where the protocol would
///           have put them for nothing. `recordedExitOf` publishes exactly that, per asset, so a
///           frontend can say so before the holder signs rather than after. Offering a route the
///           holder should not take is the contract contradicting itself in one block, which is the
///           standard the core contracts hold themselves to.
///
///        3. THE PROMISED-CLAIM PATH IS UNREACHABLE HERE, BY CONSTRUCTION. A recorded asset the
///           reserve cannot fund becomes a DEFERRED CLAIM on that asset, keyed by the redeemer. With
///           no record there is no recorded draw and therefore no claim, so the router needs no
///           mirror for `pendingClaimUnits` the way it needs one for `deferredLegs`. That absence is
///           correct only while premise (1) holds, which is why the guard exists and why it also
///           refuses a standing pending claim.
///
/// @dev WHY THIS IS A SEPARATE, NON-UPGRADEABLE CONTRACT, AND WHY IT MUST STAY ONE. The protocol
///      never calls a market (ADR-0025's solvency-path rule, restated binding in ADR-0037 D5(d)).
///      Leg election, a price input, a slippage bound and an aggregator call are all things that
///      turn a solvency path into a market path, so all four live HERE and none of them lives in
///      `ReserveManager` or `MintRedeemController`. Those two contracts hold no router address, no
///      allowance to a router and no single-asset release door, and that absence is a property to
///      be TESTED (`test_FO4_theSolvencyPathCallsNoMarket`), not merely observed. This contract is
///      not upgradeable, so the audited core cannot acquire a market call by an upgrade here.
///
/// @dev THE FREE OPTION IS CLOSED AGAINST THE PROTOCOL AND NOT AGAINST THE MARKET, AND THAT IS THE
///      DESIGN. The redeemer receives the reserve's mix; converting it to one asset costs whatever
///      the market charges, INCLUDING a depegged leg's discount. That cost is the redeemer's, which
///      is exactly what keeps the option closed. Nothing in this contract subsidises it.
///
/// @dev THE KYC HOLE THIS CONTRACT WOULD OTHERWISE OPEN, AND HOW IT IS CLOSED.
///      `MintRedeemController._redeem` gates on `msg.sender`, so for this flow to work at all the
///      router must itself be allowlisted in the compliance registry. But `USDfr._update` gates
///      transfers on the PAUSE ONLY, not on KYC, so once the router is allowlisted ANY address can
///      send it USDfr and reach the redemption door. That is a KYC bypass created entirely in the
///      periphery. It is closed here, fail-closed, by reading the SAME `IComplianceRegistry` the
///      controller reads and refusing a caller it does not allow, BEFORE any USDfr is pulled. The
///      alternative - a `redeemFor(address holder, ...)` on the controller with an allowance - was
///      REJECTED: it enlarges the audited core's privileged surface, puts a market-adjacent flow
///      inside the contract that must make no external call, and duplicates the KYC check in two
///      places that can diverge.
///
/// @dev THE ROUTER HOLDS NOTHING AT REST, WITH ONE NAMED EXCEPTION. Everything a call receives is
///      forwarded in the same call, measured by balance delta, and any residue REVERTS. The
///      exception is a DEFERRED LEG: `ReserveManager` degrades a leg it cannot deliver into a
///      claimable escrow entry keyed by the RECIPIENT, which on this path is the router, not the
///      holder. If the router did not mirror that attribution, the first caller to claim would take
///      another holder's escrowed tokens. `_deferred` is that mirror and it is not optional; see
///      `claimDeferred`.
///
/// @dev WHAT `Validate` MUST ASSERT POST-DEPLOY: this router is allowlisted in the compliance
///      registry; it is the ONLY contract so allowlisted for redemption; it points at the same
///      compliance registry and the same reserve as the controller does; and it is neither a
///      `yieldSink` nor a `lossSource` on the controller.
///
/// @dev USE A PRIVATE RELAY. ADR-0037 section 4.4 records that BNB Smart Chain has roughly 0.45-second
///      blocks and two dominant builders, so a transaction carrying both a redemption and a market
///      swap is an unusually clean MEV target. Both the controller's `deadline` and this contract's
///      `minElectedOut` bound the damage; neither removes the incentive.
contract BasketRedeemRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice One market swap the caller wants performed on one basket leg.
    /// @dev THE CALLDATA IS THE CALLER'S, THE TARGET IS NOT. An arbitrary target would be a
    ///      catastrophe: holders approve this router for USDfr, so a caller could pass
    ///      `target = USDfr` and `callData = transferFrom(victim, attacker, ...)` and drain every
    ///      standing approval. Targets therefore come from a CONSTRUCTOR-FIXED allowlist that no
    ///      one can extend, and are additionally refused at call time if the reserve has since
    ///      listed them as an asset.
    /// @param asset The basket leg to sell. Must be a listed reserve asset and must not be the
    ///        elected asset.
    /// @param target The aggregator or pool. Must be allowlisted; it is also the spender.
    /// @param minOut The least of the elected asset this leg must produce. The caller's own bound
    ///        on their own swap, which is where market risk belongs.
    /// @param callData The encoded market call.
    struct SwapLeg {
        address asset;
        address target;
        uint256 minOut;
        bytes callData;
    }

    /// @notice One routed redemption, passed as a struct.
    /// @dev IT IS A STRUCT FOR A MECHANICAL REASON AND THE REASON IS WORTH RECORDING: as five flat
    ///      parameters this function does not fit the EVM stack alongside its own measurements, and
    ///      the fix must not be to drop a measurement. A calldata struct costs one slot instead of
    ///      five and leaves the guards intact.
    /// @param usdfrAmount USDfr to offer. The controller may burn LESS; see `redeemAndSwap`.
    /// @param minValueOut The CONTROLLER's bound: the least 18-decimal par-valued total, across ALL
    ///        legs, the caller will accept. Pass `previewRedeem`'s `valueOut`, which is a floor.
    /// @param deadline Latest `block.timestamp` at which this may settle.
    /// @param electedAsset The listed reserve asset the caller wants to end up holding.
    /// @param minElectedOut The MARKET bound: the least of `electedAsset` the whole route must
    ///        deliver. It is the caller's bound on the caller's own swap, which is where market risk
    ///        belongs - the protocol never takes a view on a price.
    struct RedeemRequest {
        uint256 usdfrAmount;
        uint256 minValueOut;
        uint256 deadline;
        address electedAsset;
        uint256 minElectedOut;
    }

    /// @dev Snapshot of everything the settlement loop needs, taken ONCE before the redemption so
    ///      every delta is measured against one reading of one state.
    struct Ctx {
        address[] tokens;
        uint256[] deferredBefore;
        uint256[] balanceBefore;
        address elected;
        uint256 electedBefore;
    }

    /// @notice The controller this router redeems through.
    IMintRedeemController public immutable CONTROLLER;
    /// @notice The USDfr token.
    IERC20 public immutable USDFR;
    /// @notice The SAME compliance registry the controller gates on.
    IComplianceRegistry public immutable COMPLIANCE;
    /// @notice The reserve, read for the registry, the escrow ledger and the deferred-leg claim.
    IReserveManager public immutable RESERVES;

    /// @dev Constructor-fixed market targets. There is no setter, by design.
    mapping(address target => bool) private _allowedTarget;
    /// @dev The router's mirror of `ReserveManager.deferredLegOf(address(this), asset)`, attributed
    ///      to the holder whose redemption produced it.
    mapping(address holder => mapping(address asset => uint256)) private _deferred;
    /// @dev Escrow tokens already pulled out of the reserve and not yet handed to their holder. A
    ///      claim pulls the router's WHOLE reserve-side escrow for that asset at once, so the
    ///      surplus is held here and attributed by `_deferred`.
    mapping(address asset => uint256) private _escrowHeld;

    /// @notice A basket redemption was routed and settled.
    /// @param holder The redeemer.
    /// @param electedAsset The asset the holder elected to receive.
    /// @param usdfrIn USDfr the controller actually burned.
    /// @param valuePaid 18-decimal par-valued total the controller settled.
    /// @param electedOut Native units of `electedAsset` forwarded to the holder.
    event BasketRouted(
        address indexed holder, address indexed electedAsset, uint256 usdfrIn, uint256 valuePaid, uint256 electedOut
    );
    /// @notice A leg was sold at market for the elected asset.
    event LegSwapped(address indexed holder, address indexed asset, address indexed target, uint256 sold, uint256 got);
    /// @notice A leg was forwarded to the holder UNCHANGED - either no swap was supplied for it, or
    ///         the market call did not consume all of it. This is the in-kind fallback.
    event LegForwardedInKind(address indexed holder, address indexed asset, uint256 units);
    /// @notice The reserve could not deliver a leg and escrowed it against this router. The units
    ///         are recorded against the holder and claimed with `claimDeferred`.
    event LegDeferred(address indexed holder, address indexed asset, uint256 units);
    /// @notice A holder pulled a previously deferred leg.
    event DeferredLegClaimed(address indexed holder, address indexed asset, uint256 units);

    /// @notice The caller is not on the compliance allowlist the controller gates on.
    error Router_NotKYCAllowed(address account);
    /// @notice The request expired before it was included.
    error Router_DeadlinePassed(uint256 deadline, uint256 nowTimestamp);
    /// @notice Zero is not a meaningful redemption size.
    error Router_ZeroAmount();
    /// @notice A wired address was zero at construction.
    error Router_ZeroAddress();
    /// @notice The elected asset must be a listed reserve asset, so that "how much did the holder
    ///         get" is a question about a leg of the basket rather than about an arbitrary token.
    error Router_ElectedAssetNotListed(address asset);
    /// @notice The USDfr pulled from the caller did not equal the amount requested, so a
    ///         fee-on-transfer or blocklisting token cannot silently short the redemption.
    error Router_UsdfrNotPulled(uint256 requested, uint256 pulled);
    /// @notice The controller returned a basket that is not the reserve registry in listing order.
    ///         The router pairs legs with assets BY INDEX; a mis-paired array would misroute value.
    error Router_BasketShapeMismatch(uint256 index, address expected, address returned);
    /// @notice The reserve escrowed more of a leg than the controller says was allocated.
    error Router_DeferredExceedsLeg(address asset, uint256 allocated, uint256 deferred);
    /// @notice The market target is not on the constructor-fixed allowlist, or it is an address no
    ///         target may ever be (the token, the core modules, or a listed reserve asset).
    error Router_TargetNotAllowed(address target);
    /// @notice A swap leg names an asset the basket did not pay, or names the elected asset.
    error Router_SwapLegInvalid(address asset);
    /// @notice The market call reverted. Not swallowed: a failure here must fail loudly
    ///         (CLAUDE.md prime directive 4), and the holder can retry in kind by supplying no swap.
    error Router_SwapFailed(address asset, address target);
    /// @notice The market call spent more of the leg than the redemption produced, i.e. it reached
    ///         for tokens that are not this redemption's.
    error Router_SwapOverspent(address asset, uint256 available, uint256 spent);
    /// @notice One leg's swap produced less of the elected asset than the caller required.
    error Router_SwapSlippage(address asset, uint256 got, uint256 minOut);
    /// @notice The whole route produced less of the elected asset than the caller required.
    error Router_ElectedSlippage(uint256 electedOut, uint256 minElectedOut);
    /// @notice Value was left on the router at the end of a call. The router is value-neutral at
    ///         rest, and this is the same shape as the controller's own stranding guard.
    error Router_ResidueStranded(address asset, uint256 expected, uint256 actual);
    /// @notice The router itself holds a reserve deposit record or a pending claim, so a redemption
    ///         routed through it would draw a record that belongs to no user of this contract.
    /// @dev FAIL-CLOSED AND UNREACHABLE ON THE HONEST PATH. The router never deposits and has no
    ///      function that mints, so `depositRecord[router][asset]` cannot grow: reaching this state
    ///      needs a privileged reserve caller to have credited a record to this address. Refusing
    ///      every route is the right answer anyway, because a router that drew a record would pay one
    ///      caller out of units attributed to nobody and would create pending claims it has no
    ///      ledger to attribute. This contract is not upgradeable, so the remedy is a new router;
    ///      that is the correct blast radius for a state that should be impossible.
    /// @param asset The listed asset the record or claim stands in.
    /// @param record Native units of `asset` recorded to this router.
    /// @param pendingClaim Native units of `asset` promised to this router.
    error Router_HoldsDepositRecord(address asset, uint256 record, uint256 pendingClaim);

    /// @notice The caller has no escrowed units of this asset.
    error Router_NoDeferredLeg(address asset);
    /// @notice The reserve could not release enough of the escrowed asset to satisfy the claim.
    error Router_DeferredLegUnavailable(address asset, uint256 owed, uint256 held);

    /// @notice Wires the router immutably and fixes the market-target allowlist forever.
    /// @dev NO SETTER FOLLOWS, DELIBERATELY. An extensible target list on a contract holding user
    ///      approvals is a governance key that can drain them; a fixed list means the blast radius
    ///      of this contract is decided once, in public, at deployment, and a new aggregator means a
    ///      new router rather than a new privilege.
    /// @param controller The `MintRedeemController` proxy.
    /// @param compliance The compliance registry - MUST be the one the controller gates on.
    /// @param reserves The `ReserveManager` proxy.
    /// @param usdfr The USDfr token.
    /// @param targets Market targets this router may call. Each must have code and must not be one
    ///        of the wired protocol addresses or a currently listed reserve asset.
    constructor(address controller, address compliance, address reserves, address usdfr, address[] memory targets) {
        if (controller == address(0) || compliance == address(0) || reserves == address(0) || usdfr == address(0)) {
            revert Router_ZeroAddress();
        }
        CONTROLLER = IMintRedeemController(controller);
        COMPLIANCE = IComplianceRegistry(compliance);
        RESERVES = IReserveManager(reserves);
        USDFR = IERC20(usdfr);
        uint256 n = targets.length;
        for (uint256 i; i < n; ++i) {
            address target = targets[i];
            if (
                target == address(0) || target.code.length == 0 || target == controller || target == compliance
                    || target == reserves || target == usdfr || target == address(this)
                    || IReserveManager(reserves).isListed(target)
            ) revert Router_TargetNotAllowed(target);
            _allowedTarget[target] = true;
        }
    }

    /// @notice Redeems USDfr through the controller, swaps the legs the caller did not want, and
    ///         forwards everything to the caller.
    /// @dev THE CALLER MUST APPROVE THIS ROUTER FOR `req.usdfrAmount` OF USDfr FIRST. The router
    ///      pulls exactly that amount and proves the pull by balance delta.
    /// @dev THE BURN MAY BE SMALLER THAN THE REQUEST. A redeem-frozen or adjudication-pending leg's
    ///      share is REFUSED by the controller rather than re-weighted onto the sound legs, so
    ///      `usdfrIn` can be below `req.usdfrAmount`. The unburned remainder is returned to the
    ///      caller in the same transaction; it is a claim that stays fully redeemable once the
    ///      freeze lifts.
    /// @dev A LEG WITH NO SWAP IS FORWARDED IN KIND, AND SO IS THE UNCONSUMED PART OF A PARTIAL
    ///      FILL. That is the fallback the design requires: the market failing to fill a leg must
    ///      never cost the holder that leg.
    /// @dev THIS ROUTE ALWAYS SETTLES ON THE PRO-RATA BASKET, NEVER ON THE CALLER'S DEPOSIT RECORD.
    ///      The reserve pays the redeemer of record, which on this path is this contract, and this
    ///      contract has no record and is refused if it ever acquires one. A caller who still holds
    ///      a record is therefore giving up a one-to-one payout in their own asset in exchange for
    ///      the mix plus a market. Read `recordedExitOf` before offering this route.
    /// @param req The redemption and its two bounds. See `RedeemRequest`.
    /// @param swaps One entry per leg the caller wants sold. Legs with no entry are forwarded in
    ///        kind.
    /// @return usdfrIn USDfr the controller actually burned.
    /// @return valuePaid 18-decimal par-valued total the controller settled.
    /// @return electedOut Native units of `req.electedAsset` forwarded to the caller.
    function redeemAndSwap(RedeemRequest calldata req, SwapLeg[] calldata swaps)
        external
        nonReentrant
        returns (uint256 usdfrIn, uint256 valuePaid, uint256 electedOut)
    {
        // FAIL-CLOSED, AND BEFORE ANY VALUE MOVES. See the contract NatSpec: without this, an
        // allowlisted router is a KYC bypass for the whole protocol.
        if (!COMPLIANCE.isAllowed(msg.sender)) revert Router_NotKYCAllowed(msg.sender);
        if (block.timestamp > req.deadline) revert Router_DeadlinePassed(req.deadline, block.timestamp);
        if (req.usdfrAmount == 0) revert Router_ZeroAmount();
        if (!RESERVES.isListed(req.electedAsset)) revert Router_ElectedAssetNotListed(req.electedAsset);

        Ctx memory ctx = _snapshot(req.electedAsset);
        uint256 usdfrBefore = USDFR.balanceOf(address(this));
        USDFR.safeTransferFrom(msg.sender, address(this), req.usdfrAmount);
        {
            uint256 pulled = USDFR.balanceOf(address(this)) - usdfrBefore;
            if (pulled != req.usdfrAmount) revert Router_UsdfrNotPulled(req.usdfrAmount, pulled);
        }

        {
            address[] memory legs;
            uint256[] memory amounts;
            (legs, amounts, usdfrIn, valuePaid) = CONTROLLER.redeem(req.usdfrAmount, req.minValueOut, req.deadline);
            _settleLegs(ctx, legs, amounts, swaps);
        }

        electedOut = _forwardElected(ctx);
        if (electedOut < req.minElectedOut) revert Router_ElectedSlippage(electedOut, req.minElectedOut);

        // The unburned remainder is the caller's, and it goes back in the same call.
        if (usdfrIn < req.usdfrAmount) USDFR.safeTransfer(msg.sender, req.usdfrAmount - usdfrIn);
        _assertNoResidue(ctx, usdfrBefore);
        emit BasketRouted(msg.sender, req.electedAsset, usdfrIn, valuePaid, electedOut);
    }

    /// @notice Pulls a basket leg the reserve could not deliver when it was allocated.
    /// @dev DELIBERATELY NOT KYC-GATED. These units were ALREADY allocated and already debited from
    ///      the reserve's tally: they are the holder's property sitting in escrow, not a redemption.
    ///      Gating delivery of settled property on a status that can lapse would strand it, and the
    ///      reserve's own `claimDeferredLeg` is ungated for the same reason.
    /// @dev THE ROUTER'S ESCROW IS SHARED AND THE MIRROR IS WHAT MAKES IT SAFE. The reserve keys its
    ///      escrow by RECIPIENT, which on this path is the router, so one `claimDeferredLeg` pulls
    ///      EVERY holder's escrowed units of that asset at once. The surplus stays here in
    ///      `_escrowHeld` and is handed out against `_deferred`, which is measured, not trusted: the
    ///      pull is credited by balance delta.
    /// @param asset The escrowed reserve asset.
    /// @return amount Native units delivered to the caller.
    function claimDeferred(address asset) external nonReentrant returns (uint256 amount) {
        amount = _deferred[msg.sender][asset];
        if (amount == 0) revert Router_NoDeferredLeg(asset);
        _deferred[msg.sender][asset] = 0;
        uint256 held = _escrowHeld[asset];
        if (held < amount) {
            IERC20 token = IERC20(asset);
            uint256 before = token.balanceOf(address(this));
            RESERVES.claimDeferredLeg(asset);
            uint256 pulled = token.balanceOf(address(this)) - before;
            held += pulled;
        }
        if (held < amount) revert Router_DeferredLegUnavailable(asset, amount, held);
        _escrowHeld[asset] = held - amount;
        IERC20(asset).safeTransfer(msg.sender, amount);
        emit DeferredLegClaimed(msg.sender, asset, amount);
    }

    /// @notice Units of `asset` this router holds in escrow for `holder`.
    function deferredOf(address holder, address asset) external view returns (uint256) {
        return _deferred[holder][asset];
    }

    /// @notice What `holder` would be paid IN KIND by redeeming DIRECTLY, ahead of any basket.
    /// @dev IT EXISTS SO THIS CONTRACT CAN TELL A CALLER NOT TO USE IT. Under the record-capped
    ///      exit a depositor is paid back the assets they themselves deposited, at one to one, with
    ///      no market leg at all. Routing that same redemption pays the basket instead and then
    ///      charges the holder a market to get back to the composition the protocol would have given
    ///      them for nothing, because on this path the redeemer of record is the router and the
    ///      router has no record. A frontend reads this first and says so before the holder signs.
    /// @dev IT IS A READ OF THE RESERVE, NOT A SECOND LEDGER. The record lives in reserve storage
    ///      and this view only projects it across the registry, so it cannot drift from the figure
    ///      the settlement actually draws against. It takes no view on how much of the record a
    ///      given redemption would reach: that is bounded by the value being redeemed and by the
    ///      idle tally, both of which move.
    /// @param holder The depositor.
    /// @return assets The reserve's listed assets, in listing order, at full length.
    /// @return records Native units of each asset `holder` has deposited and not yet drawn down.
    /// @return pendingClaims Native units of each asset already promised to `holder` and claimable
    ///         from `ReserveManager.claimPendingUnits` once the units return. Those are settled
    ///         property, not a redemption, and this router is not on that path.
    function recordedExitOf(address holder)
        external
        view
        returns (address[] memory assets, uint256[] memory records, uint256[] memory pendingClaims)
    {
        assets = RESERVES.reserveAssets();
        uint256 n = assets.length;
        records = new uint256[](n);
        pendingClaims = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            (records[i], pendingClaims[i],,) = RESERVES.recordOf(holder, assets[i]);
        }
    }

    /// @notice Units of `asset` already pulled out of the reserve and awaiting their holders.
    function escrowHeld(address asset) external view returns (uint256) {
        return _escrowHeld[asset];
    }

    /// @notice True if `target` is on the constructor-fixed market allowlist.
    function isAllowedTarget(address target) external view returns (bool) {
        return _allowedTarget[target];
    }

    /// @notice The immutable wiring, for post-deploy validation and the dashboard.
    function wiring() external view returns (address controller, address compliance, address reserves, address usdfr) {
        return (address(CONTROLLER), address(COMPLIANCE), address(RESERVES), address(USDFR));
    }

    // -- Internals --------------------------------------------------------

    /// @dev ONE READING, BEFORE ANYTHING MOVES. Every later measurement is a delta against this, so
    ///      tokens standing on the router from a previous deferred claim cannot be mistaken for
    ///      this redemption's proceeds.
    ///      IT ALSO CARRIES THE RECORD GUARD, IN THE SAME LOOP RATHER THAN IN A SECOND ONE. See
    ///      `Router_HoldsDepositRecord`: the router must hold no reserve deposit record and no
    ///      pending claim, because a redemption routed through it settles as the redeemer of record,
    ///      and the redeemer of record here is this contract. Checking it here means it is checked
    ///      BEFORE any USDfr is pulled, on the same reading of the same state every other
    ///      measurement is taken against.
    function _snapshot(address electedAsset) private view returns (Ctx memory ctx) {
        address[] memory tokens = RESERVES.reserveAssets();
        uint256 n = tokens.length;
        ctx.tokens = tokens;
        ctx.deferredBefore = new uint256[](n);
        ctx.balanceBefore = new uint256[](n);
        ctx.elected = electedAsset;
        for (uint256 i; i < n; ++i) {
            address token = tokens[i];
            (uint256 record, uint256 pendingClaim,,) = RESERVES.recordOf(address(this), token);
            if (record != 0 || pendingClaim != 0) revert Router_HoldsDepositRecord(token, record, pendingClaim);
            ctx.deferredBefore[i] = RESERVES.deferredLegOf(address(this), token);
            uint256 bal = IERC20(token).balanceOf(address(this));
            ctx.balanceBefore[i] = bal;
            if (token == electedAsset) ctx.electedBefore = bal;
        }
    }

    /// @dev The settlement loop: attribute what was escrowed, sell what the caller asked to sell,
    ///      forward the rest in kind.
    ///
    ///      DEFERRAL IS READ FROM THE RESERVE'S OWN LEDGER, NOT FROM A BALANCE DELTA, AND THAT IS
    ///      LOAD-BEARING. A leg is deferred precisely because its token could not be transferred -
    ///      it reverts, it is paused, or it gas-bombs - so a `balanceOf` on that token is exactly
    ///      the read most likely to fail. `deferredLegOf` is storage on the reserve and cannot
    ///      revert for a listed asset however broken the token is, which keeps a hostile secondary
    ///      from bricking the whole route.
    function _settleLegs(Ctx memory ctx, address[] memory legs, uint256[] memory amounts, SwapLeg[] calldata swaps)
        private
    {
        uint256 n = ctx.tokens.length;
        if (legs.length != n || amounts.length != n) {
            revert Router_BasketShapeMismatch(n, address(0), address(0));
        }
        _validateSwaps(ctx.elected, swaps);
        for (uint256 i; i < n; ++i) {
            address token = ctx.tokens[i];
            if (legs[i] != token) revert Router_BasketShapeMismatch(i, token, legs[i]);
            uint256 allocated = amounts[i];
            if (allocated == 0) continue;
            uint256 deferred = RESERVES.deferredLegOf(address(this), token) - ctx.deferredBefore[i];
            if (deferred > allocated) revert Router_DeferredExceedsLeg(token, allocated, deferred);
            if (deferred != 0) {
                _deferred[msg.sender][token] += deferred;
                emit LegDeferred(msg.sender, token, deferred);
            }
            uint256 received = allocated - deferred;
            if (received == 0) continue;
            if (token == ctx.elected) continue;
            uint256 leftover = _maybeSwap(ctx, token, received, swaps);
            if (leftover != 0) {
                IERC20(token).safeTransfer(msg.sender, leftover);
                emit LegForwardedInKind(msg.sender, token, leftover);
            }
        }
    }

    /// @dev Refuses a swap list that names the elected asset (selling what the caller asked to be
    ///      paid in is never what they meant) or an asset the reserve does not list (there is no
    ///      such leg, so the entry could only be an attempt to move something else). Both are
    ///      refused LOUDLY rather than silently ignored: an unmatched entry that quietly did
    ///      nothing would leave the caller believing a leg had been sold when it had not.
    function _validateSwaps(address elected, SwapLeg[] calldata swaps) private view {
        uint256 count = swaps.length;
        for (uint256 j; j < count; ++j) {
            address asset = swaps[j].asset;
            if (asset == elected || !RESERVES.isListed(asset)) revert Router_SwapLegInvalid(asset);
        }
    }

    /// @dev Sells `received` of `token` if the caller supplied a swap for it, and returns whatever
    ///      the market did not take. A leg with no swap entry returns the whole amount, which the
    ///      caller then forwards in kind.
    function _maybeSwap(Ctx memory ctx, address token, uint256 received, SwapLeg[] calldata swaps)
        private
        returns (uint256 leftover)
    {
        uint256 count = swaps.length;
        for (uint256 j; j < count; ++j) {
            if (swaps[j].asset != token) continue;
            return received - _executeSwap(ctx.elected, token, received, swaps[j]);
        }
        // No swap supplied for this leg: the in-kind fallback.
        return received;
    }

    /// @dev The one place in the whole system that calls a market.
    ///
    ///      THE TARGET IS RE-CHECKED AGAINST THE REGISTRY AT CALL TIME, not only at construction.
    ///      An asset listed AFTER this router was deployed could otherwise be named as a market
    ///      target, which would let a caller drive the router's own token movements through an
    ///      allowlisted address that is now part of the protocol's value surface.
    ///
    ///      CONSUMPTION IS MEASURED AND BOUNDED BY THE LEG. The allowance is granted for exactly
    ///      `received` and zeroed immediately, and the measured balance delta is required not to
    ///      exceed `received`, so a market call can never reach past this redemption into another
    ///      holder's escrowed units standing on the router.
    ///
    ///      THE OUTPUT IS MEASURED, NOT TAKEN FROM THE RETURN DATA. An aggregator's return value is
    ///      the aggregator's claim about itself; the elected asset's balance delta is a fact about
    ///      this contract. `minOut` binds against the fact.
    ///
    ///      A FAILED CALL REVERTS RATHER THAN DEGRADING TO IN-KIND. The caller asked for a swap and
    ///      priced their transaction around getting one; silently handing them the unwanted leg
    ///      instead would be a worse surprise than a revert, and CLAUDE.md prime directive 4 refuses
    ///      the silent catch. A caller who wants the leg in kind supplies no swap for it.
    /// @param elected The asset every swap must produce.
    /// @param token The leg being sold.
    /// @param received Native units of `token` this redemption produced. The upper bound on spend.
    /// @param leg The caller's swap instruction.
    /// @return spent Native units of `token` the market actually took.
    function _executeSwap(address elected, address token, uint256 received, SwapLeg calldata leg)
        private
        returns (uint256 spent)
    {
        address target = leg.target;
        if (!_allowedTarget[target] || RESERVES.isListed(target)) revert Router_TargetNotAllowed(target);
        uint256 soldBefore = IERC20(token).balanceOf(address(this));
        uint256 electedBefore = IERC20(elected).balanceOf(address(this));
        IERC20(token).forceApprove(target, received);
        (bool ok,) = target.call(leg.callData);
        if (!ok) revert Router_SwapFailed(token, target);
        IERC20(token).forceApprove(target, 0);
        uint256 soldAfter = IERC20(token).balanceOf(address(this));
        spent = soldBefore > soldAfter ? soldBefore - soldAfter : 0;
        if (spent > received) revert Router_SwapOverspent(token, received, spent);
        uint256 got = IERC20(elected).balanceOf(address(this)) - electedBefore;
        if (got < leg.minOut) revert Router_SwapSlippage(token, got, leg.minOut);
        emit LegSwapped(msg.sender, token, target, spent, got);
    }

    /// @dev Forwards everything the route accumulated in the elected asset. Measured as a delta
    ///      across the WHOLE call, so it covers both the elected asset's own basket leg and every
    ///      swap's output in one number.
    function _forwardElected(Ctx memory ctx) private returns (uint256 electedOut) {
        IERC20 elected = IERC20(ctx.elected);
        uint256 balance = elected.balanceOf(address(this));
        electedOut = balance > ctx.electedBefore ? balance - ctx.electedBefore : 0;
        if (electedOut != 0) elected.safeTransfer(msg.sender, electedOut);
    }

    /// @dev THE ROUTER IS VALUE-NEUTRAL AT REST - DO NOT DELETE. Every token balance, USDfr
    ///      included, must return to exactly what it was before the call. This is the same shape as
    ///      the controller's `Controller_CashStrandedOnController` and it is an EQUALITY on a DELTA
    ///      rather than an absolute balance, so a donation made before the call cannot brick the
    ///      route and a donation made during it cannot be pocketed. A deferred leg is not an
    ///      exception: those tokens never reach the router, they stay in the reserve's escrow.
    function _assertNoResidue(Ctx memory ctx, uint256 usdfrBefore) private view {
        uint256 n = ctx.tokens.length;
        for (uint256 i; i < n; ++i) {
            uint256 balance = IERC20(ctx.tokens[i]).balanceOf(address(this));
            if (balance != ctx.balanceBefore[i]) {
                revert Router_ResidueStranded(ctx.tokens[i], ctx.balanceBefore[i], balance);
            }
        }
        uint256 usdfrAfter = USDFR.balanceOf(address(this));
        if (usdfrAfter != usdfrBefore) revert Router_ResidueStranded(address(USDFR), usdfrBefore, usdfrAfter);
    }
}
