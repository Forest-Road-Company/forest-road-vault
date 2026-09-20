// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IPausableModule
/// @notice The one-bit pause surface of a wired module, declared here because `previewRedeem` must
///         read the reserve's pause and `IReserveManager` does not declare it.
/// @dev CANTINA 3.1.3 LIMB (a), CLOSED BY CONSTRUCTION ON THIS INSTANCE. On Ethereum the quote read
///      the controller pause and the token pause but not the reserve's, so it could publish a full
///      price for a redemption whose every release is `whenNotPaused`. The disposition there was
///      "an integrator should read `ReserveManager.paused()` alongside the quote", because closing
///      it was an upgrade. The mechanical reason the sibling fix missed the third surface is that
///      `ReserveManager` gets `paused()` from `PausableUpgradeable` and never declares it on its own
///      interface, so nothing in the type system pointed at it. This declaration is that pointer.
interface IPausableModule {
    /// @notice True while the module refuses its `whenNotPaused` entry points.
    function paused() external view returns (bool);
}

/// @title IMintRedeemController
/// @notice KYC-gated issuance and redemption of USDfr against a GOVERNED REGISTRY of reserve
///         stablecoins, and the enforcement point of the protocol's solvency rule.
///
///         MINT names the asset, is CREDITED AT `min(price, par)` against that asset's latched
///         relative price (ADR-0038), is bounded by that asset's per-asset cap, carves that asset's
///         per-asset mint fee OUT OF the credit, and is CLOSED while the protocol is under-backed on
///         the RECOGNITION-AWARE basis. Every price guard REFUSES the mint; none of them falls back
///         to par, because a silent fallback reopens the free option during exactly the outage an
///         attacker would choose.
///
///         REDEMPTION IS RECORD-CAPPED, NOT ELECTED (ADR-0037 D5(d) as amended by ADR-0038 and by
///         the Forest Road direction of 2026-09-07). A redeemer is paid, first, THE ASSETS THEY
///         THEMSELVES DEPOSITED, one unit of value per USDfr of value, capped by the units their own
///         deposit record still carries; everything beyond that record is paid as the PRO-RATA
///         BASKET. There is still no function by which a redeemer NAMES an asset, and none may be
///         added. The warning that used to say the door does not exist is rewritten rather than
///         deleted, and it carries its condition forward: free election reopens the free option, and
///         what closes it here is THE CAP. A redeemer can only take back what they put in, so they
///         cannot convert an impaired asset into a sound one at the expense of the holders who stay.
///         The deposit record does NOT move when USDfr is transferred, so buying USDfr on a market
///         confers no record and no claim on anybody else's deposit.
///
///         A redeemer who wants a DIFFERENT asset from the one the protocol owes them swaps the legs
///         in their OWN transaction, through `BasketRedeemRouter`, on tokens already in their own
///         wallet, at their own slippage bound and their own cost. The protocol never calls a market.
///
///         The price is par while the protocol is whole; while it is short it settles at the
///         JUNIOR-DRAWN price, which is at least the coverage ratio and may be par (ADR-0034 Y-bis).
///
/// @dev WHAT DIFFERS FROM THE ETHEREUM INSTANCE, so an auditor comparing the two files is not
///      surprised by silence (ADR-0037):
///        - THERE IS NO `SCALE` CONSTANT. Scale is per-asset reserve STORAGE, recorded at listing.
///          Both genesis assets are 18-decimal, so their scale is 1 and every grid the Ethereum file
///          documents is the identity function here. The arguments that rested on the grid are
///          deleted rather than ported: a stale justification on a value path is a defect, because
///          the next engineer prunes the guard once they discover the reason given for it is untrue.
///        - THERE IS NO CASCADE LAYER TWO (D3a(ii)). No sGROVE, no GROVE, no backstop. The junior
///          draw is curator first-loss and nothing else, and what it declines is borne by the
///          exiting holder's own settlement price.
///        - THE TWO-ARGUMENT `redeem(uint256,uint256)` IS NOT SHIPPED. It exists on Ethereum only
///          because deleting it is an ABI break. A new instance has no such caller, so not shipping
///          it closes Cantina 3.1.5 (a price-bounded but not time-bounded free option) BY
///          CONSTRUCTION rather than by disclosure.
///
/// @dev THE SOLVENCY RULE IS NOT ADR-0012's ABSOLUTE PREDICATE. What the contract enforces:
///        - Redemption is NOT 1:1. The exit price is `backing / supply` while short, lifted toward
///          par by the junior draw, and the one-argument form settles AT PAR or reverts.
///        - The absolute predicate is REPLACED by the NON-WORSENING rule: an operation may not
///          increase `deficit = max(0, totalSupply - backingValue)`. While the protocol is whole
///          that reduces exactly to ADR-0012 and still reverts with
///          `Controller_BackingInvariantViolated`; while it is short it permits the operations that
///          repair holders' position and refuses the ones that dilute it. See
///          `MintRedeemController`'s contract-level NatSpec, which sets out the whole model.
///        - It is not asserted "after every supply-affecting op": `burnLoss` carries NO solvency
///          assertion, deliberately (the assertion it used to carry was unfalsifiable).
///      `ADR/0012-backing-invariant.md` still states the superseded absolute rule verbatim. IT MUST
///      BE AMENDED OR SUPERSEDED so the code and the decision record agree; that is OUTSTANDING and
///      is Forest Road's to take (CLAUDE.md section 0.7).
interface IMintRedeemController {
    // -- Events -----------------------------------------------------------
    /// @notice USDfr was issued against a named reserve asset.
    /// @dev THE THIRD AND FOURTH PARAMETERS CHANGED MEANING relative to the Ethereum instance.
    ///      `assetIn` is native units of `asset`, not of one hard-wired token, and `usdfrOut` is NET
    ///      OF THE FEE. An indexer that wants the gross recognised value must read
    ///      `usdfrOut + fee`, which is exactly `assetIn * scale`.
    /// @param user The minter.
    /// @param asset The reserve asset deposited.
    /// @param assetIn Native units of `asset` pulled from the minter.
    /// @param usdfrOut USDfr credited to the minter, net of the fee.
    /// @param fee USDfr minted to the fee recipient, carved out of the PRICED credit.
    /// @param price The effective 18-decimal price applied, `min(latched, 1e18)`. REQUIRED, because
    ///        without it the credit is no longer reconstructable from events (CLAUDE.md section 3.1):
    ///        `assetIn * scale` recovers the PAR value that entered backing, and `usdfrOut + fee`
    ///        recovers the PRICED credit that entered supply. Under ADR-0038 those two differ
    ///        whenever the asset trades below par, and the difference accrues to every standing
    ///        holder rather than to the minter.
    event Minted(
        address indexed user, address indexed asset, uint256 assetIn, uint256 usdfrOut, uint256 fee, uint256 price
    );

    /// @notice The per-asset mint fee was carved and paid. Emitted only when the fee is non-zero.
    /// @param user The minter it was carved from.
    /// @param asset The reserve asset whose registry row set the rate.
    /// @param fee USDfr minted to `recipient`.
    /// @param recipient The controller-level `mintFeeRecipient()`.
    event MintFeeCharged(address indexed user, address indexed asset, uint256 fee, address indexed recipient);

    /// @notice A basket redemption settled.
    /// @param user The redeemer.
    /// @param usdfrIn USDfr actually burned.
    /// @param valuePaid 18-decimal par-valued total of every leg paid.
    event Redeemed(address indexed user, uint256 usdfrIn, uint256 valuePaid);

    /// @notice One leg of a basket redemption was allocated to the redeemer.
    /// @dev REQUIRED, NOT OPTIONAL (CLAUDE.md section 3.1: the on-chain register must be reconstructable
    ///      purely from events). `Redeemed` carries only the scalar `valuePaid`; without a per-leg
    ///      event no observer can reconstruct who was paid in which asset. The reserve emits its own
    ///      `BasketLegPaid`/`BasketLegDeferred` pair, which distinguishes DELIVERED from ESCROWED;
    ///      this event records the ALLOCATION, which is the quantity the redeemer's USDfr bought.
    /// @param user The redeemer.
    /// @param asset The reserve asset.
    /// @param units Native units of `asset` allocated to the redeemer.
    /// @param value `units * scale`, in 18-decimal USD at par-valued marks.
    event RedeemLegSettled(address indexed user, address indexed asset, uint256 units, uint256 value);

    /// @notice Part of a redemption settled as a DEFERRED CLAIM on the redeemer's own recorded
    ///         asset rather than as cash, because those units were not in the idle tally.
    /// @dev The redeemer is deliberately NOT paid the basket for this part. Paying the basket there
    ///      would hand them assets other holders deposited, which is exactly the transfer the record
    ///      cap exists to close. The value has already left backing, so it counts toward `valuePaid`
    ///      and does NOT crystallise a senior shortfall. The per-asset breakdown is the reserve's
    ///      `PendingClaimEscrowed`; this event is the controller-side scalar that makes the split
    ///      between cash and promise readable without joining two logs.
    /// @param user The redeemer.
    /// @param promisedValue 18-decimal value promised rather than delivered.
    event RedeemPromised(address indexed user, uint256 promisedValue);

    /// @notice Emitted when USDfr is minted against attested yield receipts (waterfall path).
    event YieldMinted(address indexed to, uint256 amount);
    /// @notice Emitted when USDfr is burned to realize a loss (the senior layer of the cascade).
    event LossBurned(address indexed from, uint256 amount);

    /// @notice Emitted IN ADDITION to `Redeemed` when a redemption settled below par because the
    ///         protocol was under-backed. Carries the supply and backing the quote was struck
    ///         against, so the coverage ratio applied to any exit is reconstructable purely from
    ///         events (CLAUDE.md section 3.1).
    /// @param user The redeemer.
    /// @param usdfrBurned USDfr burned.
    /// @param valuePaid 18-decimal par-valued total actually paid across every leg.
    /// @param supply `totalUSDfr()` before the redemption.
    /// @param backing `backingValue()` before the redemption.
    event SubParRedemption(
        address indexed user, uint256 usdfrBurned, uint256 valuePaid, uint256 supply, uint256 backing
    );

    /// @notice Emitted alongside `SubParRedemption`. Records the value PERMANENTLY crystallised out
    ///         of the senior layer by an exit priced against a REVERSIBLE impairment mark, and the
    ///         running total. `mintableHeadroom()` nets the running total out, so value recovered
    ///         when the mark is released stays in the pool as coverage instead of being minted to
    ///         the `sUSDfr` vault as yield.
    /// @param user The redeemer who bore it.
    /// @param amount `usdfrIn - valuePaid` for this exit, in 18-decimal USD.
    /// @param cumulative `seniorSubParShortfall()` after this exit.
    event SeniorShortfallCrystallised(address indexed user, uint256 amount, uint256 cumulative);

    /// @notice Governance authorized or revoked a `mintYield` destination.
    event YieldSinkUpdated(address indexed account, bool authorized);
    /// @notice Governance authorized or revoked a `burnLoss` source.
    event LossSourceUpdated(address indexed account, bool authorized);
    /// @notice Governance changed the address that receives the per-asset mint fee (ADR-0037 section 4.4).
    event MintFeeRecipientUpdated(address indexed previous, address indexed recipient);

    /// @notice Junior capital was drawn forward, in cascade order, to fund this exit's price
    ///         (ADR-0034 Y-bis). `drawn` USDfr was burned out of curator first-loss.
    /// @dev THERE IS NO LAYER TWO ON THIS INSTANCE (ADR-0037 D3a(ii)). `required` is the whole
    ///      cascade-ordered need and `drawn` is what curator first-loss alone could meet; the
    ///      difference is borne by the exiting holder at their own settlement price.
    event SeniorExitJuniorDrawn(address indexed redeemer, uint256 required, uint256 drawn);

    // -- Errors -----------------------------------------------------------
    error Controller_ZeroAddress();

    /// @notice A module handed to `initialize` is not a contract, or does not answer its interface.
    /// @dev CANTINA 3.1.2. `initialize` checked only that the three module addresses were non-zero,
    ///      so a wrong or CODELESS address left the controller unusable and unrecoverable without
    ///      an upgrade. The asymmetry was visible in the same file: `setLossSource` already refused
    ///      a non-contract. A code-length check alone would not catch a wrong-but-contract address,
    ///      so each module is also PROBED on a view it must answer.
    error Controller_ModuleNotResponding(address module);
    error Controller_NotKYCAllowed(address account);
    error Controller_BackingInvariantViolated(uint256 supply, uint256 backing);
    error Controller_ZeroAmount();

    /// @notice The whole exit floored to nothing across every paying leg, so there is nothing to
    ///         settle and nothing is burned.
    /// @dev RE-SCOPED FOR THE BASKET (ADR-0037 section 6). On Ethereum this meant "worth less than one
    ///      whole USDC unit". With both genesis assets 18-decimal the per-leg grid is the identity
    ///      and this is reachable only through the frozen-leg reduction driving the burn to zero. It
    ///      becomes reachable per leg again the moment a 6-decimal asset is listed, when a leg's
    ///      share floors below one native unit. It is therefore NOT deleted as unreachable: it is
    ///      re-scoped, and its falsifier must run on a basket with a sub-18-decimal leg.
    error Controller_AmountTooSmall(uint256 usdfrAmount);

    /// @notice The user paths are closed for THIS ASSET while the reserve holds less of it than its
    ///         idle ledger claims. Recognition of the gap is permissionless and immediate;
    ///         restoring custody, or the authenticated custody-loss cascade writing the ledger down
    ///         to the live balance, reopens mint and redeem with no governance action.
    /// @dev THE ASSET PARAMETER IS THE ADR-0037 section 4.4 CHANGE. A single global gate meant a paused or
    ///      broken secondary token closed the sound asset's door too, which is the R2-M-03 brick
    ///      class ADR-0025 removed and which the registry must not reintroduce.
    /// @param asset The asset whose custody is short, or `address(0)` when the refusal is the
    ///        reserve's own PROTOCOL-WIDE R4-01 gate rather than a named paying leg.
    /// @param shortfallValue The observable custody gap in 18-decimal USD.
    /// @param recognizedBacking Backing net of that gap - the honest basis.
    error Controller_ReserveCustodyShortfall(address asset, uint256 shortfallValue, uint256 recognizedBacking);

    /// @notice The operation would have WIDENED an already-standing backing deficit. Distinct from
    ///         `Controller_BackingInvariantViolated`, which is raised when a whole protocol would be
    ///         pushed below par: an integrator seeing that error inside a knowingly sub-par protocol
    ///         would reasonably read it as the standing condition rather than as a refusal of this
    ///         specific call.
    /// @param deficitBefore `max(0, totalUSDfr() - backingValue())` before the operation.
    /// @param deficitAfter The same quantity after it, which must not exceed `deficitBefore`.
    error Controller_DeficitWorsened(uint256 deficitBefore, uint256 deficitAfter);

    /// @notice A paired-yield baseline is already open, so a second cannot be started.
    error Controller_PairedYieldAlreadyOpen(address caller);
    /// @notice A split mint must consume this caller's existing paired backing baseline.
    error Controller_PairedYieldRequired();
    /// @notice A paired operation cannot complete against a changed retention obligation.
    error Controller_PairedRetentionChanged(uint256 beforeRequirement, uint256 afterRequirement);
    /// @notice The protocol fee cannot exceed the total amount being issued.
    error Controller_InvalidYieldSplit(uint256 total, uint256 fee);

    /// @notice A paired-yield baseline was recorded before its caller moved backing.
    event PairedYieldOpened(address indexed caller, uint256 supplyBefore, uint256 backingBefore);

    /// @notice A stranded paired-yield baseline was cleared by governance.
    event PairedYieldCleared(address indexed caller);

    /// @notice Records the supply/backing baseline for a yield mint whose backing leg moves first.
    function beginPairedYield() external;

    /// @notice Governance escape for a paired-yield baseline stranded by a reverted operation.
    function clearStalePairedYield() external;

    /// @notice Par issuance is closed while the protocol is under-backed for ANY reason.
    /// @dev THE BASIS CHANGED FOR THE BSC INSTANCE, AND IT IS NOT COSMETIC. The custody predicate on
    ///      `mint` is now PER ASSET, so a shortfall in asset B is no longer caught anywhere on a
    ///      mint of asset A. Measuring this level gate on `recognizedBackingValue()` nets EVERY
    ///      asset's observed shortfall, so a global hole closes mint in every asset while the
    ///      per-asset predicate closes the specific asset. That is the separation ADR-0037 section 4.4
    ///      requires: accepted-for-mint is per asset, recognized backing is protocol-wide.
    /// @dev THIS GATE IS NOT DEPEG PROTECTION AND MUST NOT BE READ AS ANY. Under ADR-0037 D4 a
    ///      reserve-asset depeg is a loss the ledger never sees: backing is carried at PAR-VALUED
    ///      marks, so `backing >= supply` still holds through a depeg, this error does not fire, and
    ///      `_exitDrawTarget` returns zero. The only controls that bite during a depeg are the
    ///      per-asset cap, the per-asset mint fee and the guardian's per-asset mint freeze.
    /// @param supply `totalUSDfr()` at the time of refusal.
    /// @param recognizedBacking `recognizedBackingValue()` at the time of refusal.
    error Controller_MintClosedWhileUnderBacked(uint256 supply, uint256 recognizedBacking);

    /// @notice The asset is not on the reserve's ADR-0037 section 4.4 registry.
    error Controller_AssetNotListed(address asset);

    /// @notice The asset's latched relative price is not usable, so MINT IN THAT ASSET REFUSES.
    /// @dev IT NEVER FALLS BACK TO PAR, AND THAT IS ONE DELETED `if` AWAY FROM BEING FALSE.
    ///      ADR-0038 records why: a silent fallback to par reopens the mint-side free option during
    ///      exactly the outage an attacker would choose, so every guard on the price is a REFUSAL.
    ///      The refusal is per asset: another asset with a live price still mints, which is the
    ///      R2-M-03 rule that a broken secondary must not close the sound asset's door. Redemption
    ///      reads no price at any point and therefore never halts for this reason.
    /// @dev THE ERROR IS RAISED HERE RATHER THAN INSIDE THE RESERVE, deliberately. The reserve
    ///      publishes ONE predicate (`mintPriceQuote`) and returns rather than reverting; the
    ///      contract the caller is actually talking to decodes it. That is the same R9 doctrine the
    ///      redeem path already follows, and it keeps a single enumeration of liveness.
    /// @param asset The asset whose price is not usable.
    /// @param reason 1 never pushed, 2 stale, 3 below floor, 4 no floor configured. Zero is live and
    ///        is therefore never carried by this error.
    /// @param effective The effective price, which is zero in every state that raises this.
    error Controller_ReservePriceNotLive(address asset, uint8 reason, uint256 effective);

    /// @notice The deposit is too small to credit one wei of USDfr once the price is applied.
    /// @dev Reachable only at scale 1 (an 18-decimal asset) and only for a deposit of one or two
    ///      native units below par, where `floor(grossValue * effective / 1e18)` truncates to zero.
    ///      At a sub-18-decimal listing the smallest possible gross value is `10 ** (18 - decimals)`,
    ///      so the branch is unreachable there. Stated because the unit suite must cover it at
    ///      scale 1 and must NOT assert it at a coarser scale.
    /// @param assetAmount Native units offered.
    /// @param effective The effective price applied.
    error Controller_MintTooSmallAfterPricing(uint256 assetAmount, uint256 effective);

    /// @notice The par form of `mint` was called while the asset is credited below par.
    /// @dev THE PAR FORM SUPPLIES AN EQUALITY, NOT A NUMBER. It settles only where the effective
    ///      price is exactly par, so a transaction held in the mempool sells no option: every
    ///      downward move REVERTS rather than settling worse. That is why it needs no deadline, and
    ///      it is the same argument `redeem(uint256)` rests on. A minter who accepts a below-par
    ///      credit uses the four-argument form and states their own floor.
    /// @param asset The asset.
    /// @param effective The effective price that would have been applied.
    error Controller_ParMintNotAvailable(address asset, uint256 effective);

    /// @notice The reserve reported value settled beyond the units it moved, without writing a
    ///         matching deferred-claim liability for it.
    /// @dev THE ONE CHECK THAT REPLACES A STRICT EQUALITY, AND IT MUST NOT BE DROPPED. On the pure
    ///      basket path `sum units_i * scale_i == valuePaid` exactly, and the controller could refuse
    ///      any reserve that over-reported. The record-capped path legitimately settles value with
    ///      NO units moving, when the redeemer's own recorded asset is deployed into a facility, so
    ///      the equality has to relax to `<=`. What replaces the lost half of it is this: the
    ///      promised remainder must appear, wei for wei, as a rise in the reserve's own outstanding
    ///      claim liability, which is a MEASUREMENT of a second ledger rather than a restatement of
    ///      the reserve's word. Without it a reserve could report a settlement it never owed.
    /// @param promised `valuePaid` minus the value of the units actually moved.
    /// @param recognized The rise in the reserve's aggregate outstanding claim value.
    error Controller_ClaimNotRecognized(uint256 promised, uint256 recognized);

    /// @notice The guardian has frozen this asset for MINT. Redemption legs are unaffected: the two
    ///         freezes are separate flags precisely so closing the door on new exposure does not
    ///         close the door on existing holders.
    error Controller_AssetMintFrozen(address asset);

    /// @notice The deposit would push this asset's par-valued tally past its governed cap.
    /// @dev THE CHECK MUST PRECEDE THE DEPOSIT AND THAT IS THE LOAD-BEARING PART. Backing counts
    ///      `min(tally, cap)`, so a deposit allowed past the cap raises `totalBackingValue()` by
    ///      LESS than the credited value and trips the recognition equality
    ///      (`Controller_DepositNotRecognized`) on the honest path. Refusing outright keeps
    ///      `delta totalBackingValue == assetAmount * scale` exact at every scale and in every cap state.
    /// @param asset The asset.
    /// @param tallyValue The asset's current par-valued tally, 18 decimals.
    /// @param addedValue The value this deposit would add, 18 decimals.
    /// @param cap The governed ceiling, 18 decimals.
    error Controller_AssetCapExceeded(address asset, uint256 tallyValue, uint256 addedValue, uint256 cap);

    /// @notice A non-zero mint fee is due and governance has not named a recipient.
    /// @dev FAIL-CLOSED BY DESIGN. The alternative - skipping the fee when the recipient is unset -
    ///      would make a wiring omission silently free for minters and invisible in the logs.
    error Controller_MintFeeRecipientUnset();

    /// @notice The whole deposit was consumed by the mint fee, so the minter would be credited
    ///         nothing. Refused rather than settled, so no deposit is ever taken for zero credit.
    error Controller_MintTooSmallAfterFee(uint256 assetAmount, uint256 fee);

    /// @notice The two mints of a fee-carving mint did not raise supply by exactly the recognised
    ///         gross value, i.e. the fee was not carved out of the credit.
    /// @dev THE SUPPLY TWIN OF `Controller_DepositNotRecognized`, AND IT EARNS ITS BYTES. The
    ///      recognition equality measures BACKING; nothing measured SUPPLY, and this path issues TWO
    ///      mints where the Ethereum path issues one. `USDfr._update` fires the deliberately
    ///      fail-open participation-points hook inside every mint, and a fail-open hook inside a
    ///      measurement window changes what the window means. One `totalSupply()` delta equality
    ///      across both mints makes "the fee is carved, not added" a falsifiable property in one
    ///      line rather than an inference from reading two `mint` calls.
    /// @param expected `assetAmount * scale` - what supply must have risen by.
    /// @param measured What it actually rose by.
    error Controller_MintSupplyNotRecognized(uint256 expected, uint256 measured);

    /// @notice The asset the user was charged did not arrive in the reserve's custody, or the
    ///         reserve credited a value that does not match it. Measured from the reserve's own
    ///         token balance rather than from anything the reserve reports about itself.
    /// @param asset The reserve asset.
    /// @param requested Native units pulled from the user.
    /// @param delivered The reserve's measured balance increase in that asset.
    /// @param credited The 18-decimal value `depositAsset` reported.
    error Controller_DepositNotCustodied(address asset, uint256 requested, uint256 delivered, uint256 credited);

    /// @notice The reserve took the cash and reported the right credit but did not BOOK it as
    ///         backing. Measured as a DELTA on `totalBackingValue()` across the deposit leg, so no
    ///         standing surplus can absorb it, and as an EQUALITY, so an over-booking reserve is
    ///         refused too.
    /// @param asset The reserve asset.
    /// @param credited The 18-decimal value `depositAsset` reported.
    /// @param recognized The measured increase in `backingValue()` across the same call.
    error Controller_DepositNotRecognized(address asset, uint256 credited, uint256 recognized);

    /// @notice Reserve assets were left sitting on the controller after a mint. The controller is
    ///         value-neutral at rest; a reserve that funded the deposit from somewhere other than
    ///         the controller's allowance satisfies the delivery equality while leaving the user's
    ///         cash here with a live approval against it.
    /// @dev Measured as a DELTA across the call, never as an absolute balance: anyone can send a
    ///      token to the controller, so `balanceOf(this) != 0` would be a one-wei permanent
    ///      griefing lock on `mint`.
    /// @param asset The reserve asset.
    /// @param balanceBefore The controller's balance before the deposit leg.
    /// @param balanceAfter Its balance after it. Any inequality is refused.
    error Controller_CashStrandedOnController(address asset, uint256 balanceBefore, uint256 balanceAfter);

    /// @notice `to` is not a governance-authorized yield destination.
    error Controller_NotYieldSink(address to);

    /// @notice `from` is not a governance-authorized loss source. Without this, `burnLoss` and
    ///         `mintYield` composed into arbitrary confiscation, and `USDfr.burn`'s allowance-free
    ///         burn made any holder seizable one-sidedly.
    error Controller_NotLossSource(address from);

    /// @notice A loss source must be a CONTRACT. `burnLoss` burns with no allowance, carries no
    ///         backing assertion and is deliberately not pausable, so listing an EOA would restore a
    ///         forced, non-pro-rata seizure of one named holder in a single routine-looking timelock
    ///         transaction. Deliberately NOT applied to `setYieldSink` or `setMintFeeRecipient`,
    ///         which CREDIT an address rather than seizing from one.
    error Controller_LossSourceNotContract(address account);

    /// @notice A loss source must not be an EIP-7702 DELEGATED EOA. An ordinary key-controlled
    ///         wallet that signed a delegation carries a 23-byte `0xef0100`-prefixed code field, so
    ///         `EXTCODESIZE` returns 23 and the contract check alone admitted it.
    /// @dev EIP-7702 IS LIVE ON BNB SMART CHAIN (Pascal hard fork, March 2025) exactly as it is on
    ///      Ethereum L1, and EIP-3541's ban on deploying leading-`0xEF` code holds there too, so
    ///      both halves of the Ethereum argument carry across unchanged.
    error Controller_LossSourceIsDelegatedEOA(address account);

    /// @notice The settled par-valued total was below the floor the caller named.
    /// @dev THE BOUND IS DENOMINATED IN USDfr VALUE, NOT IN ONE TOKEN, AND THAT IS THE BASKET
    ///      CHANGE. A basket payout is a vector; a bound on one leg is not a bound on the exit,
    ///      because a redeemer who floors leg 0 at 100 can be paid entirely in leg 1 and the bound
    ///      never binds. A PER-LEG minimum vector was considered and REJECTED: the mix is protocol
    ///      state, not caller state, so a per-leg floor can only produce griefing reverts on an
    ///      honest exit. The redeemer's real concern - "I want USDC and I will be handed 40% USD1" -
    ///      is a MARKET risk, and it belongs in `BasketRedeemRouter`'s own slippage bound on its own
    ///      swap, in the redeemer's own transaction, paid by the redeemer.
    /// @param valuePaid The 18-decimal par-valued total the exit would have paid.
    /// @param minValueOut The floor the caller required.
    error Controller_SlippageExceeded(uint256 valuePaid, uint256 minValueOut);

    /// @notice The one-argument `redeem` could not settle at par, so it refused rather than
    ///         haircutting a caller who did not ask to be haircut.
    /// @dev A DISTINCT ERROR RATHER THAN A REUSE OF `Controller_SlippageExceeded`, for the same
    ///      reason `Controller_DeficitWorsened` is split off `Controller_BackingInvariantViolated`:
    ///      an integrator reading "slippage exceeded" on a form that names no slippage parameter
    ///      will misdiagnose it.
    /// @param usdfrIn The USDfr the exit burned.
    /// @param valuePaid The par-valued total actually settled, which fell short of it.
    error Controller_ParExitNotAvailable(uint256 usdfrIn, uint256 valuePaid);

    /// @notice Backing has fallen to zero, so there is nothing to pay out at any size.
    /// @param supply `totalUSDfr()` at the time of refusal.
    error Controller_NoRedeemableBacking(uint256 supply);

    /// @notice Every listed asset is refused for payout - redeem-frozen, adjudication-pending, or
    ///         empty - so no basket can be formed at any size.
    /// @dev THE INTENDED GLOBAL LOCK, AND A GUARDIAN POWER THAT MUST BE DISCLOSED. On a two-asset
    ///      instance this state is TWO guardian transactions away, on arms that carry NO EXPIRY and
    ///      that `GUARDIAN_ROLE` alone cannot cancel, adjudicate, finalize or execute. That is a
    ///      strictly LARGER guardian power than the Ethereum instance's, whose reserve-loss arm does
    ///      not close direct redemption at all - which is precisely Cantina 3.1.4, the finding this
    ///      instance fixes. Both directions are Forest Road's to accept and they are the same
    ///      decision seen from two sides; it belongs in the disclosure surface and the threat model.
    error Controller_NoPayableReserve();

    /// @notice The exit is priced at more value than the reserve's idle, unfrozen legs can pay. The
    ///         protocol is solvent and illiquid.
    /// @dev A DECODED ERROR WHERE THERE WAS A RAW ONE, AND THE CHECK MOVED AHEAD OF THE BURN.
    ///      `backing` includes deployed principal and every asset's tally; `totalPayable` is only
    ///      the idle, unfrozen legs, so this is reachable on a healthy book. The exit is NOT clamped
    ///      to `totalPayable` and settled partially: ADR-0034 evaluated that shape and rejected it,
    ///      because a cap alone converts a full exit into a permanently partial one with no ordered
    ///      claim on the remainder, which is strictly worse for the holder.
    /// @param valueOut The par-valued total the quote struck.
    /// @param payableValue The par-valued total the paying legs can currently settle.
    error Controller_InsufficientPayableReserve(uint256 valueOut, uint256 payableValue);

    /// @notice The redemption would have burned more USDfr than the post-draw supply.
    /// @dev CANTINA 3.1.1, RE-DERIVED AT SCALE 1 AND CLOSED RATHER THAN ACKNOWLEDGED. On Ethereum
    ///      the whole-unit grid returned `M mod 1e12` wei of headroom at the top of the range, so
    ///      `usdfrIn + drawn` overflowed only for inputs within 1e12 of `type(uint256).max` - a
    ///      panic window of width at most 2**40, which is why "acknowledged" was a defensible
    ///      judgement. At scale 1 the grid is the identity, `usdfrIn == usdfrAmount` exactly, and
    ///      the window widens to the whole top `drawn` of the range. That is not the same judgement
    ///      about the same object. Bounding the SUM rather than the addend makes the overflow
    ///      UNREPRESENTABLE rather than merely unlikely, refuses only inputs no holder can hold, and
    ///      makes `previewRedeem` answer a controller error instead of `Panic(0x11)`.
    /// @param usdfrIn The amount the exit would burn.
    /// @param bound `supply - drawn`, which `supply - drawn <= supply` makes underflow-free because
    ///        `drawn` was burned out of `supply`.
    error Controller_RedeemExceedsSupply(uint256 usdfrIn, uint256 bound);

    /// @notice The reserve returned a basket whose legs are not the registry in listing order.
    /// @dev THE POSITIONAL RETURN SHAPE IS THE WHOLE SAFETY PROPERTY OF THE ARRAYS. The router
    ///      caches the registry once and pairs legs with assets BY INDEX; a reserve that reorders,
    ///      truncates or pads its return would silently mis-pair every integrator. Compacting the
    ///      arrays to non-zero legs was considered and rejected for the same reason, and because the
    ///      array LENGTH would then leak the payout-freeze state.
    /// @param index The position at which the returned registry diverged.
    /// @param expected The asset the controller read from the registry.
    /// @param returned The asset the reserve named at that position.
    error Controller_BasketShapeMismatch(uint256 index, address expected, address returned);

    /// @notice A leg the basket refused was nonetheless paid, or a paid leg's units do not match
    ///         what the reserve booked.
    /// @param asset The reserve asset.
    /// @param expected Native units the controller expected the leg to move.
    /// @param settled Native units the reserve reports it moved.
    /// @param usdfrBurned The USDfr burned to pay for the basket.
    error Controller_RedemptionNotSettled(address asset, uint256 expected, uint256 settled, uint256 usdfrBurned);

    /// @notice The reserve's reported `valuePaid` does not equal the par value of the units it says
    ///         it moved, or it exceeds the value the exit was priced at.
    /// @dev AN INDEPENDENT RECOMPUTE, AND THAT IS THE POINT. The controller re-derives
    ///      `sum units_i * scale_i` from ITS OWN cached scales and requires it to equal the reserve's
    ///      own answer. It catches a reserve that over-pays one leg while under-booking its ledger,
    ///      which a one-sided `<=` relaxation would not. It touches no token, so a hostile or paused
    ///      reserve asset cannot make this check itself revert.
    /// @param expectedValue The par value of the units the reserve reported moving.
    /// @param settledValue The `valuePaid` the reserve reported.
    error Controller_BasketValueMismatch(uint256 expectedValue, uint256 settledValue);

    /// @notice A listed asset has a pending loss review, so the whole exit is refused.
    /// @dev Applies even when that asset is frozen for redemption or has zero payable value.
    /// @param asset The asset under review.
    error Controller_AssetAdjudicationPending(address asset);

    /// @notice The operation would have widened the deficit measured on the RECOGNITION-AWARE
    ///         basis. Raised only by `mintYield`, the one supply-EXPANDING path with no custody
    ///         precondition.
    /// @param deficitBefore `max(0, totalUSDfr() - recognizedBackingValue())` before the call.
    /// @param deficitAfter The same quantity after it.
    error Controller_RecognizedDeficitWorsened(uint256 deficitBefore, uint256 deficitAfter);

    /// @notice A yield mint would have consumed value retained against `seniorSubParShortfall()` -
    ///         the haircut crystallised out of holders who exited against a REVERSIBLE impairment
    ///         mark. `mintableHeadroom()` advertises the retention; this error enforces it.
    /// @dev STILL LOAD-BEARING AS THE LAST LINE OF DEFENCE RATHER THAN THE ONLY ONE. `CREDIT_ROLE`
    ///      gates `mintYield` and the deploy script grants it to `WaterfallEngine` alone; a second
    ///      grantee, or any future unclamped call site, would spend the junior retention silently.
    ///      The clamp is a caller-side property; this is the callee-side one.
    /// @param threshold THE BOUND THAT WAS ACTUALLY ENFORCED, which differs by branch and is why
    ///        this parameter is not named `retention`. On an ordinary yield mint it is
    ///        `seniorSubParShortfall() + ReserveManager.exitPrepaidAbsorption()`, the junior
    ///        retention the surplus must not fall below. On a PAIRED mint opened by
    ///        `beginPairedYield` it is the surplus recorded BEFORE the caller moved any backing,
    ///        because a paired move raises backing and supply by the identical amount and the
    ///        property enforced there is exact neutrality rather than a floor. Reporting the
    ///        retention on the paired branch made the error describe a rule that branch does not
    ///        apply; corrected 2026-09-10.
    /// @param surplus `max(0, recognizedBackingValue() - totalUSDfr())` after the mint.
    error Controller_SeniorRetentionBreached(uint256 threshold, uint256 surplus);

    /// @notice A composite view was read while this contract's reentrancy guard was entered - i.e.
    ///         from inside a supply change that has not finished settling - and would have answered
    ///         a number known to be false.
    /// @dev `_redeem` burns before it releases, and `DefaultManager.realizeLoss` burns before it
    ///      writes backing down; `USDfr._update` fires the participation-points hook inside every one
    ///      of those burns. From there `mintableHeadroom()` read the entire realised loss of a
    ///      cascade as distributable yield capacity, `backingInvariantHolds()` read TRUE on a short
    ///      book and `previewRedeem` quoted PAR on it. Reverting is the honest answer and is
    ///      fail-closed for an integrator. The raw delegating views (`backingValue`,
    ///      `recognizedBackingValue`, `totalUSDfr`) are NOT gated: each is true whenever it is read.
    ///      Only the composites are.
    error Controller_ViewUnavailableMidTransition();

    /// @notice `redeem(uint256,uint256,uint256)` was included after the caller's deadline
    ///         (ADR-0034 W).
    /// @dev THE JUSTIFICATION IS STRONGER ON THIS CHAIN, NOT WEAKER. BNB Smart Chain has roughly
    ///      0.45-second blocks and two dominant builders, so holding a transaction in the mempool
    ///      until the coverage ratio moves is cheaper there than on L1.
    error Controller_DeadlinePassed(uint256 deadline, uint256 nowTimestamp);

    /// @notice The junior-draw source named by `ReserveManager.lossAbsorber()` is not on the
    ///         governance-maintained `setLossSource` list (ADR-0034 Y-bis). Fail-closed: the exit
    ///         refuses rather than burning a third party's USDfr on an unvouched-for pointer.
    error Controller_ExitDrawSourceNotAuthorised(address source);

    /// @notice The junior-draw source reported one number and moved another, or delivered more than
    ///         was asked of it (ADR-0034 Y-bis). Measured, not trusted.
    error Controller_ExitDrawNotDelivered(uint256 requested, uint256 reported, uint256 measured);

    // -- User paths (KYC-gated) -------------------------------------------

    /// @notice Deposits a listed reserve asset and mints USDfr AT PAR, or reverts. NET of the fee.
    /// @dev THE PAR FORM SUPPLIES AN EQUALITY, NOT A NUMBER, AND THAT IS WHY IT NEEDS NO DEADLINE.
    ///      It settles only where the asset's effective price is exactly par and reverts
    ///      `Controller_ParMintNotAvailable` otherwise, so a transaction held in the mempool sells
    ///      no option: every downward move in the latched price REVERTS rather than settling worse.
    ///      That is the same arithmetic argument `redeem(uint256)` rests on (ADR-0034 W), restated
    ///      for the entry side. A minter willing to accept a below-par credit uses the four-argument
    ///      form and states their own floor there.
    /// @dev THE FEE IS CARVED FROM THE CREDIT, NEVER ADDED ON TOP, AND NEVER ROUTED TO RESERVE
    ///      SURPLUS (ADR-0037 section 4.4). Minting `grossValue` to the minter AND `feeOut` to the
    ///      recipient would raise supply by `grossValue + feeOut` against a backing rise of
    ///      `grossValue`, widening the deficit by the fee on the very first mint. Routing the fee to
    ///      reserve surplus instead would be worse: ADR-0033 section 6 step 1 makes existing backing
    ///      surplus the first thing a recognized loss consumes, so protocol revenue parked there
    ///      becomes first-loss capital sitting AHEAD of the curator - the cascade inverted. And it
    ///      must not be routed through `mintYield`, which enforces the senior retention and is an
    ///      ADR-0031 fee-share instrument, a different thing entirely.
    /// @dev THE FEE PRICES THE FREE OPTION; IT DOES NOT CLOSE IT. With a secondary asset trading at
    ///      price `p`, cap `K` and fee `f`, a KYC'd minter earns `(1 - f - p)` per unit on
    ///      `min(K, sound idle)` per conversion cycle whenever `p < 1 - f`. The basket shrinks the
    ///      redemption half of that (the minter can no longer take the sound asset in full), but the
    ///      mint-side option is BOUNDED BY THE CAP, not removed. Do not let anyone argue the fee is
    ///      loss absorption.
    /// @param asset The listed reserve asset to deposit.
    /// @param assetAmount Native units of `asset` to deposit.
    /// @return usdfrOut USDfr credited to the minter, NET of the fee.
    /// @return feeOut USDfr minted to `mintFeeRecipient()`. On this form, and only on this form,
    ///         `usdfrOut + feeOut == assetAmount * scale`, because par is asserted.
    function mint(address asset, uint256 assetAmount) external returns (uint256 usdfrOut, uint256 feeOut);

    /// @notice Deposits a listed reserve asset and mints USDfr at `min(price, par)`, bounded by a
    ///         minimum credit and a deadline. THE CANONICAL FORM, and the one integrators must use.
    /// @dev THE CREDIT IS `assetAmount * scale * min(price, 1e18) / 1e18`, floored, and the fee is
    ///      carved out of THAT rather than out of the gross. Charging the fee on the gross while
    ///      crediting the priced amount would make the effective fee rate rise as the asset fell,
    ///      which nothing decided and nobody could explain to a depositor, and it would leave the
    ///      supply-delta equality assembled from two bases.
    /// @dev BOTH BOUNDS ARE REQUIRED AND NEITHER SUBSTITUTES FOR THE OTHER. `minUsdfrOut` bounds the
    ///      PRICE; `deadline` bounds the TIME. The latched price is now a variable input that moves
    ///      between broadcast and inclusion, the path that moves it (`syncAssetPrice`) is
    ///      permissionless and publicly visible before it lands, and BNB Smart Chain's roughly
    ///      0.45-second blocks and two dominant builders make mempool holding cheap. A minter who
    ///      bounded only the price hands whoever chooses inclusion a free option.
    /// @dev THE MINIMUM IS CHECKED ONCE, BEFORE CUSTODY, AND THE ASYMMETRY WITH `redeem` IS
    ///      DELIBERATE. On the exit side the early check is advisory and the binding one is on the
    ///      SETTLED number, because `valuePaid` is the reserve's answer and can differ from the
    ///      quote. Here `usdfrOut` is COMPUTED, not measured: it is a pure function of the gross
    ///      value, the effective price and the fee rate, all read from one state before anything
    ///      moves, and nothing between the check and the mint can change it. What proves the
    ///      computed number was actually issued is the supply-delta equality, which IS a
    ///      measurement. A second post-settlement check would have no state it could catch.
    /// @param asset The listed reserve asset to deposit.
    /// @param assetAmount Native units of `asset` to deposit.
    /// @param minUsdfrOut The least USDfr, net of fee, the minter will accept. Zero accepts any
    ///        credit down to one wei; pass zero only deliberately.
    /// @param deadline Latest `block.timestamp` at which this mint may settle.
    /// @return usdfrOut USDfr credited to the minter, NET of the fee.
    /// @return feeOut USDfr minted to `mintFeeRecipient()`.
    function mint(address asset, uint256 assetAmount, uint256 minUsdfrOut, uint256 deadline)
        external
        returns (uint256 usdfrOut, uint256 feeOut);

    /// @notice Quotes a mint without executing it: the net credit and the fee at current registry
    ///         state.
    /// @dev Returns `(0, 0)` whenever the mint CANNOT execute: pause, an unlisted or mint-frozen
    ///      asset, a cap that the deposit would breach, a custody shortfall in that asset, an
    ///      under-backed book, A PRICE THAT IS NOT LIVE, a credit truncated to zero by the price, or
    ///      a deposit entirely consumed by the fee. That is the same contract `previewRedeem`
    ///      publishes, and it exists so a frontend can state the refusal rather than discovering it
    ///      by simulating a revert.
    /// @dev IT CONSUMES THE SAME `mintPriceQuote` THE MINT CONSUMES and must never grow a second
    ///      liveness predicate of its own, so the quote and the settlement cannot disagree. A
    ///      frontend that needs to say WHY the price is not live reads `mintPriceQuote`'s `reason`
    ///      from the reserve directly.
    /// @param asset The listed reserve asset.
    /// @param assetAmount Native units that would be deposited.
    /// @return usdfrOut USDfr that would be credited to the minter.
    /// @return feeOut USDfr that would be minted to the fee recipient.
    function previewMint(address asset, uint256 assetAmount) external view returns (uint256 usdfrOut, uint256 feeOut);

    /// @notice Burns USDfr and settles the caller's OWN RECORDED ASSETS first, then the PRO-RATA
    ///         BASKET for the remainder, AT PAR.
    /// @dev SETTLES AT PAR ACROSS THE BASKET OR REVERTS; IT NEVER HAIRCUTS A CALLER WHO DID NOT ASK
    ///      TO BE HAIRCUT. Par is expressed as the RELATION `valuePaid == usdfrIn`, not as a number:
    ///      a numeric floor derived from the requested amount cannot survive per-leg flooring, which
    ///      can leave `valuePaid` a few wei short of `usdfrIn` on a perfectly healthy book. While
    ///      the protocol is short this form still settles at par out of JUNIOR capital drawn forward
    ///      in the same transaction (ADR-0034 Y-bis); it reverts `Controller_ParExitNotAvailable`
    ///      only once that draw cannot reach par.
    /// @dev THE MIX IS PROTOCOL STATE AND IS NOT NEGOTIABLE HERE, AND THE WARNING THAT SAID SO IS
    ///      REWRITTEN RATHER THAN DELETED. There is still no parameter by which a caller NAMES an
    ///      asset, and none may be added: free election is the free option ADR-0037 section 4.1 exists to
    ///      close. What the caller gets instead is not a choice, it is a fact about their own past:
    ///      the reserve pays THE ASSETS THIS CALLER DEPOSITED, capped by the units their own deposit
    ///      record still carries, and the CAP is what closes the option. A redeemer can take back
    ///      only what they put in, so they cannot convert an impaired asset into a sound one at the
    ///      expense of the holders who stay. The record does not move when USDfr is transferred, so
    ///      a buyer on a market acquires no record. Value beyond the record pays the PRO-RATA
    ///      BASKET, which involves no choice and therefore shifts no currency risk; yield and
    ///      protocol-fee USDfr are minted with no record at all, so that is the ordinary path for
    ///      those holders. Swapping what you were paid into something else is
    ///      `BasketRedeemRouter`'s job, in the redeemer's own transaction, at the redeemer's own
    ///      cost. A depegged leg's discount is therefore paid by the redeemer.
    /// @dev A RECORDED ASSET THE RESERVE CANNOT FUND BECOMES A DEFERRED CLAIM ON THAT SAME ASSET,
    ///      NOT A BASKET PAYMENT. Where the redeemer's own units are deployed into a facility, the
    ///      reserve escrows a claim, removes its value from backing in the same transaction, and the
    ///      holder pulls it with `ReserveManager.claimPendingUnits` once units return. Paying the
    ///      basket there would reopen precisely the transfer the record cap closes. That promised
    ///      value counts toward `valuePaid`, because it has already left backing and the holder owns
    ///      it in the ledger, and it therefore does NOT crystallise a senior shortfall. The
    ///      controller emits `RedeemPromised` for the scalar and the reserve emits
    ///      `PendingClaimEscrowed` per asset.
    /// @param usdfrAmount USDfr offered. The amount actually burned may be LOWER: a redeem-frozen or
    ///        adjudication-pending leg's share is REFUSED rather than re-weighted onto the sound
    ///        legs, and the residual claim stays in the caller's wallet as fully transferable USDfr.
    /// @return assets The reserve's listed assets in registry order. ALWAYS full length, including
    ///         zero-amount legs, so the arrays are positionally stable across calls.
    /// @return amounts Native units of each asset allocated to the caller, index-aligned with
    ///         `assets`. A leg the reserve could not deliver becomes a claimable escrow entry
    ///         (`ReserveManager.claimDeferredLeg`) rather than reverting the whole basket.
    /// @return usdfrIn USDfr actually burned.
    /// @return valuePaid 18-decimal par-valued total settled, cash plus any deferred claim written.
    ///         Equals `usdfrIn` on this form.
    function redeem(uint256 usdfrAmount)
        external
        returns (address[] memory assets, uint256[] memory amounts, uint256 usdfrIn, uint256 valuePaid);

    /// @notice Burns USDfr and settles the caller's own recorded assets then the pro-rata basket,
    ///         refusing to settle below `minValueOut` or after `deadline`. THE CANONICAL EXIT
    ///         (ADR-0034 W).
    /// @dev A minimum-out bounds the PRICE; it does not bound WHEN the exit executes. Every path
    ///      that moves the coverage ratio down is un-timelocked and publicly visible before it
    ///      lands, so a transaction left in the mempool is a free option for whoever chooses
    ///      inclusion.
    /// @dev A FREEZE BETWEEN QUOTE AND SETTLEMENT REVERTS THE EXIT; REQUOTE. A leg that was payable
    ///      at `previewRedeem` and redeem-frozen at settlement lowers `valuePaid` below the quote,
    ///      so `minValueOut` binds and the exit reverts. That is the correct fail-closed outcome -
    ///      the redeemer is not silently paid less - but it is a NEW way for a quoted number to fail
    ///      that the Ethereum instance does not have, and an integrator must be told.
    /// @param usdfrAmount USDfr offered; see `redeem(uint256)` for why less may be burned.
    /// @param minValueOut The lowest 18-decimal par-valued total, across ALL legs, the caller will
    ///        accept. Zero accepts ANY price, including a deep haircut - pass zero only
    ///        deliberately. Pass the `valueOut` that `previewRedeem` returned, which is a FLOOR on
    ///        what settlement pays and therefore safe to bind against.
    /// @param deadline Latest `block.timestamp` at which this exit may settle.
    /// @return assets The reserve's listed assets in registry order, always full length.
    /// @return amounts Native units of each asset allocated to the caller.
    /// @return usdfrIn USDfr actually burned.
    /// @return valuePaid 18-decimal par-valued total of `amounts`.
    function redeem(uint256 usdfrAmount, uint256 minValueOut, uint256 deadline)
        external
        returns (address[] memory assets, uint256[] memory amounts, uint256 usdfrIn, uint256 valuePaid);

    // -- Protocol paths (credit layer) ------------------------------------

    /// @notice Mints USDfr to `to` against newly received, attested backing (loan interest /
    ///         reserve yield). `CREDIT_ROLE`.
    /// @dev `to` must be a governance-authorized yield sink. Refuses while the protocol is
    ///      under-backed on EITHER basis and while the controller is paused (a pause must never
    ///      permit supply expansion). EVERY CALLER MUST SIZE ITSELF OFF `mintableHeadroom()`: it is
    ///      the one view that nets the retention, both pauses and the recognition basis. A caller
    ///      that does not will revert rather than withhold.
    function mintYield(address to, uint256 amount) external;

    /// @notice Issues one paired increase to two authorized sinks, checking the complete total.
    /// @param senior Destination of total minus fee; unused when that amount is zero.
    /// @param total Total new supply, justified by the backing increase since beginPairedYield.
    /// @param feeRecipient Destination of fee; unused when fee is zero.
    /// @param fee Part of total allocated before the senior leg, in normalized USDfr units.
    function mintYieldSplit(address senior, uint256 total, address feeRecipient, uint256 fee) external;

    /// @notice Burns USDfr from `from` to realize a loss through the cascade.
    ///         `LOSS_BURNER_ROLE` - deliberately NOT `CREDIT_ROLE`.
    /// @dev `from` must be a governance-authorized loss source, and the role is split from
    ///      `CREDIT_ROLE` so `WaterfallEngine`, which never burns, does not hold the power to. Never
    ///      pausable: loss absorption must stay available.
    function burnLoss(address from, uint256 amount) external;

    // -- Governance -------------------------------------------------------

    /// @notice Authorizes (or revokes) an address as a destination for `mintYield`.
    function setYieldSink(address account, bool authorized) external;

    /// @notice Authorizes (or revokes) an address as a source for `burnLoss`.
    function setLossSource(address account, bool authorized) external;

    /// @notice Sets the address that receives the per-asset mint fee (ADR-0037 section 4.4).
    /// @dev Timelocked governance. Zero is refused so a non-zero fee can never mint into the void,
    ///      and because `mint` fails closed on an unset recipient rather than skipping the fee. NOT
    ///      constrained to a contract: unlike `setLossSource`, this address is CREDITED, not seized
    ///      from, so the EIP-7702 reasoning does not apply - the same asymmetry `setYieldSink`
    ///      already documents.
    function setMintFeeRecipient(address recipient) external;

    /// @notice The address that receives the per-asset mint fee.
    function mintFeeRecipient() external view returns (address);

    // -- Views ------------------------------------------------------------

    /// @notice Current backing value on the RECORDED-LEDGER basis
    ///         (delegates to `ReserveManager.totalBackingValue()`).
    /// @dev This is the basis the custody-loss arithmetic reconciles against within a single
    ///      transaction and is deliberately NOT recognition-aware. For any solvency or exit-pricing
    ///      question use `recognizedBackingValue()`. On this instance it is
    ///      `sum min(tally_i, cap_i) * scale_i + deployedPrincipal - impairment`, and it remains
    ///      STORAGE-ONLY: no `decimals()`, no `balanceOf`, no oracle enters it (ADR-0025).
    function backingValue() external view returns (uint256);

    /// @notice Backing net of every latched, un-ratified custody shortfall the reserve can observe
    ///         right now (delegates to `ReserveManager.recognizedBackingValue()`).
    function recognizedBackingValue() external view returns (uint256);

    /// @notice Current USDfr total supply.
    function totalUSDfr() external view returns (uint256);

    /// @notice True if supply is covered on the RECORDED ledger.
    /// @dev Compatibility diagnostic only. DELIBERATELY BLIND TO THE CUSTODY SHORTFALL. Do not use
    ///      this absolute view as an admission gate, user-path condition, exit price, or solvency
    ///      display.
    function creditServicingBackingHolds() external view returns (bool);

    /// @notice True if the backing invariant currently holds. Public so anyone can check.
    /// @dev Measured against `recognizedBackingValue()`, so it can no longer report true in the same
    ///      block in which the reserve publishes a shortfall. Reverts with
    ///      `Controller_ViewUnavailableMidTransition` if called from inside an unsettled supply
    ///      change.
    function backingInvariantHolds() external view returns (bool);

    /// @notice `max(0, totalUSDfr() - backingValue())` on the RECORDED basis - the quantity every
    ///         supply-affecting path refuses to increase.
    function backingDeficit() external view returns (uint256);

    /// @notice The same quantity on the RECOGNITION-AWARE basis (net of any observable custody
    ///         shortfall). This is what `WaterfallEngine.distribute` gates on, comparing it before
    ///         and after the call.
    function recognizedDeficit() external view returns (uint256);

    /// @notice How much NEW supply may be minted without widening the deficit or paying away value
    ///         the protocol owes: `(paused() || USDfr.paused()) ? 0 : max(0, recognizedBackingValue()
    ///         - totalUSDfr() - seniorSubParShortfall() - ReserveManager.exitPrepaidAbsorption())`.
    /// @dev `WaterfallEngine._routeInterest` reads this and distributes only what fits, WITHHOLDING
    ///      the rest so the cash stays in the reserve and repairs backing. That is the
    ///      protocol-native cure for a residual deficit: loan interest closes the hole
    ///      automatically, with no governance action and no recapitalisation, and yield resumes by
    ///      itself once it is closed. All four terms are load-bearing and the published formula must
    ///      stay in step with the code - a caller sizing off a stale formula gets a revert instead of
    ///      a withholding.
    function mintableHeadroom() external view returns (uint256);

    /// @notice Cumulative value crystallised out of the senior layer by sub-par exits, in
    ///         18-decimal USD. Monotonically non-decreasing; no setter.
    /// @dev IT READS DIFFERENTLY ON THIS INSTANCE, AND AN OPERATOR MUST KNOW THAT. On Ethereum this
    ///      ledger absorbs up to `1e12 - 1` wei of whole-unit GRID RESIDUE on every exit, so a
    ///      non-zero balance is not by itself evidence of a haircut. With both genesis assets
    ///      18-decimal there is no grid, and the only non-haircut contribution is at most `N - 1`
    ///      wei of `mulDiv` truncation across `N` legs. A non-zero number here is therefore
    ///      essentially all REAL haircut, and `mintableHeadroom()` nets out a quantity that means
    ///      what it says.
    function seniorSubParShortfall() external view returns (uint256);

    /// @notice Quotes the current permitted withdrawal, with no junior draw assumed.
    /// @dev During a reserve-currency review the caller must have sufficient records entirely in
    ///      healthy currencies. Set the holder as the RPC `from` account. The quote shares the
    ///      reserve's record allocator and refuses a remainder that those currencies cannot
    ///      represent. Value can include a pending claim on a healthy recorded currency; the units
    ///      array includes only its currently allocatable portion. A router has its own records.
    /// @dev Outside review this remains a holder-agnostic basket quote. Its composition need not
    ///      match a holder's deposit records; with sub-18-decimal records, use a conservative
    ///      minValueOut. A changed state can invalidate any quote. Actual settlement alone binds
    ///      the caller's minimum; junior funding can improve the undrawn price shown here.
    /// @param usdfrAmount USDfr offered for withdrawal.
    /// @return assets Full reserve registry in listing order.
    /// @return amounts Quoted native units per currency, subject to the conditions above.
    /// @return usdfrIn USDfr to burn, or zero when the quote is refused.
    /// @return valueOut Quoted settlement value, including any same-currency pending claim.
    function previewRedeem(uint256 usdfrAmount)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts, uint256 usdfrIn, uint256 valueOut);

    /// @notice True if `account` may receive `mintYield`.
    function isYieldSink(address account) external view returns (bool);

    /// @notice True if `account` may be burned from by `burnLoss`.
    function isLossSource(address account) external view returns (bool);

    /// @notice Wired module addresses, used to bind ReserveManager's independent loss check to the
    ///         controller that actually points back to that reserve.
    function modules() external view returns (address usdfr, address compliance, address reserves);
}
