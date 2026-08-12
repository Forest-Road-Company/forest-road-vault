// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IMintRedeemController
/// @notice KYC-gated issuance and redemption of USDfr against canonical USDC, and the enforcement
///         point of the protocol's solvency rule. MINT is at par and is CLOSED while the protocol
///         is under-backed. REDEMPTION is at par while the protocol is whole; while it is short it
///         settles at the JUNIOR-DRAWN price, which is at least the coverage ratio and MAY BE PAR,
///         and which the caller must elect via `redeem(uint256,uint256)`.
///         AUDIT FIX (SWEEP-2 S2-I1) — THIS FILE-LEVEL LINE SAID "at the coverage ratio while it is
///         short", the THIRD round in which a false settlement claim sat on the one line an
///         explorer or ABI doc renders first. SWEEP-1 MRC-F2 corrected the two `redeem` overloads
///         and the contract-level block and left this headline. Falsified by the shipped
///         `ADR0034Y_AtomicJuniorExitDraw::test_Y_theExitSettlesAtParWhileCuratorCapitalStandsIntact`
///         and by SWEEP-2 S2-F3, in which a sub-par book settled at PAR because ADR-0034 Y-bis drew
///         junior capital forward to fund it.
/// @dev THE SOLVENCY RULE IS NOT ADR-0012's ABSOLUTE PREDICATE ANY MORE, AND THIS HEADLINE USED TO
///      SAY IT WAS (corrected in audit round R18). Until R18 this contract-level notice line read "KYC-gated 1:1
///      mint/redeem … `USDfr.totalSupply() <= backingValue()` after every supply-affecting op".
///      Both halves were false of the shipped code, and an auditor handed ADR-0012 plus this
///      interface as the specification would reasonably have reported "the contract does not
///      enforce its stated invariant" as a High. What the contract actually enforces:
///        - Redemption is NOT 1:1. R16-M3 made the exit price `backing / supply` while short, and
///          R17 gave the one-argument form a PAR FLOOR, so it reverts rather than settling short.
///        - The absolute predicate was REPLACED by the NON-WORSENING rule: an operation may not
///          increase `deficit = max(0, totalSupply - backingValue)`. While the protocol is whole
///          that reduces exactly to ADR-0012 and still reverts with
///          `Controller_BackingInvariantViolated`; while it is short it permits the operations that
///          repair holders' position and refuses the ones that dilute it. See
///          `MintRedeemController`'s contract-level NatSpec, which sets out the whole model.
///        - It is not asserted "after every supply-affecting op": `burnLoss` carries NO solvency
///          assertion, deliberately (finding M6 — the assertion it used to carry was unfalsifiable).
///      The comment was not independently wrong: it correctly quoted `ADR/0012-backing-invariant.md`
///      (Status: Accepted), which still states the superseded absolute rule verbatim as "a hard
///      on-chain check on every supply-affecting operation". THAT ADR MUST BE AMENDED OR SUPERSEDED
///      so the code and the decision record agree; it is OUTSTANDING and is Forest Road's to take
///      (CLAUDE.md §0.7).
interface IMintRedeemController {
    // ── Events ───────────────────────────────────────────────────────────
    event Minted(address indexed user, uint256 usdcIn, uint256 usdfrOut);
    event Redeemed(address indexed user, uint256 usdfrIn, uint256 usdcOut);
    /// @notice Emitted when USDfr is minted against attested yield receipts (waterfall path).
    event YieldMinted(address indexed to, uint256 amount);
    /// @notice Emitted when USDfr is burned to realize a loss (cascade layer 3).
    event LossBurned(address indexed from, uint256 amount);
    /// @notice AUDIT FIX (R16-M3). Emitted IN ADDITION to `Redeemed` when a redemption settled
    ///         below par because the protocol was under-backed. Carries the supply and backing
    ///         the quote was struck against, so the coverage ratio applied to any exit is
    ///         reconstructable purely from events (CLAUDE.md §3.1).
    /// @param user The redeemer.
    /// @param usdfrBurned USDfr burned (whole-USDC-unit aligned).
    /// @param usdcOut Native USDC units actually paid out.
    /// @param supply `totalUSDfr()` before the redemption.
    /// @param backing `backingValue()` before the redemption.
    event SubParRedemption(address indexed user, uint256 usdfrBurned, uint256 usdcOut, uint256 supply, uint256 backing);
    /// @notice AUDIT FIX (R17). Emitted alongside `SubParRedemption`. Records the value
    ///         PERMANENTLY crystallised out of the senior layer by an exit priced against a
    ///         REVERSIBLE impairment mark, and the running total. `mintableHeadroom()` nets the
    ///         running total out, so value recovered when the mark is released stays in the pool
    ///         as coverage instead of being minted to the `sUSDfr` vault as yield.
    /// @param user The redeemer who bore it.
    /// @param amount `usdfrBurned - usdcOut * 1e12` for this exit, in 18-decimal USD.
    /// @param cumulative `seniorSubParShortfall()` after this exit.
    event SeniorShortfallCrystallised(address indexed user, uint256 amount, uint256 cumulative);
    /// @notice AUDIT FIX (R16-M1). Governance authorized or revoked a `mintYield` destination.
    event YieldSinkUpdated(address indexed account, bool authorized);
    /// @notice AUDIT FIX (R16-M1/M2). Governance authorized or revoked a `burnLoss` source.
    event LossSourceUpdated(address indexed account, bool authorized);

    // ── Errors ───────────────────────────────────────────────────────────
    error Controller_NotKYCAllowed(address account);
    error Controller_BackingInvariantViolated(uint256 supply, uint256 backing);
    error Controller_ZeroAmount();
    error Controller_AmountTooSmall(uint256 usdfrAmount);
    /// @notice AUDIT FIX (R4-01): the user par paths are closed while the reserve holds less USDC
    ///         than its idle ledger claims. Recognition of the gap is permissionless and immediate;
    ///         restoring custody, or the authenticated custody-loss cascade writing the ledger down
    ///         to the live balance, reopens mint and redeem with no governance action.
    /// @param shortfallValue The observable custody gap in 18-decimal USD.
    /// @param recognizedBacking Backing net of that gap — the honest basis.
    error Controller_ReserveCustodyShortfall(uint256 shortfallValue, uint256 recognizedBacking);

    /// @notice AUDIT FIX (R16-M3/M4/M5). The operation would have WIDENED an already-standing
    ///         backing deficit. Distinct from `Controller_BackingInvariantViolated`, which is
    ///         raised when a whole protocol would be pushed below par: an integrator seeing that
    ///         error inside a knowingly sub-par protocol would reasonably read it as the standing
    ///         condition rather than as a refusal of this specific call.
    /// @param deficitBefore `max(0, totalUSDfr() - backingValue())` before the operation.
    /// @param deficitAfter The same quantity after it, which must not exceed `deficitBefore`.
    error Controller_DeficitWorsened(uint256 deficitBefore, uint256 deficitAfter);

    /// @notice AUDIT FIX (R16-M3). Par issuance is closed while the protocol is under-backed for
    ///         ANY reason — a G3 conservative mark or a residual cascade deficit as well as the
    ///         R4-01 custody gap. `redeem` deliberately stays OPEN in this state and re-prices to
    ///         the coverage ratio; see `previewRedeem`.
    /// @param supply `totalUSDfr()` at the time of refusal.
    /// @param backing `backingValue()` at the time of refusal.
    error Controller_MintClosedWhileUnderBacked(uint256 supply, uint256 backing);

    /// @notice AUDIT FIX (R16-L2). The USDC the user was charged did not arrive in the reserve's
    ///         custody, or the reserve credited a value that does not match it. Measured from the
    ///         reserve's own token balance rather than from anything the reserve reports about
    ///         itself, so `mint` no longer derives both sides of its safety check from one module.
    /// @param requested Native USDC units pulled from the user.
    /// @param delivered The reserve's measured USDC balance increase.
    /// @param credited The 18-decimal value `depositUSDC` reported.
    error Controller_DepositNotCustodied(uint256 requested, uint256 delivered, uint256 credited);

    /// @notice AUDIT FIX (R16-M1). `to` is not a governance-authorized yield destination.
    error Controller_NotYieldSink(address to);

    /// @notice AUDIT FIX (R16-M1/M2). `from` is not a governance-authorized loss source. Without
    ///         this, `burnLoss` and `mintYield` composed into arbitrary confiscation, and
    ///         `USDfr.burn`'s allowance-free burn made any holder seizable one-sidedly.
    error Controller_NotLossSource(address from);

    /// @notice AUDIT FIX (R17). A loss source must be a CONTRACT. `burnLoss` burns with no
    ///         allowance, carries no backing assertion and is deliberately not pausable, so
    ///         listing an EOA would restore finding M2 — a forced, non-pro-rata seizure of one
    ///         named holder — in a single routine-looking timelock transaction. Mirrors
    ///         `ReserveManager.setLossAbsorber`/`setLossController`. Deliberately NOT applied to
    ///         `setYieldSink`, whose fee-recipient treasury may legitimately be an EOA.
    error Controller_LossSourceNotContract(address account);

    /// @notice AUDIT FIX (R17). The settled price was below the floor the caller named. The
    ///         one-argument `redeem` supplies the PAR floor, so it reverts with this rather than
    ///         silently haircutting a holder against a mark that may later be released.
    /// @param usdcOut What the redemption would have paid.
    /// @param minUsdcOut The floor the caller required.
    error Controller_SlippageExceeded(uint256 usdcOut, uint256 minUsdcOut);

    /// @notice AUDIT FIX (R17). Backing has fallen to zero, so there is nothing to pay out at any
    ///         size. Previously this answered `Controller_AmountTooSmall`, which told the holder
    ///         their amount was the problem when the truth was that the protocol was worth nothing.
    /// @param supply `totalUSDfr()` at the time of refusal.
    error Controller_NoRedeemableBacking(uint256 supply);

    /// @notice AUDIT FIX (R17). The USDC the redemption was priced at did not reach the redeemer.
    ///         The outflow twin of `Controller_DepositNotCustodied`: R16-L2 installed an
    ///         independent measurement on the inflow leg only, leaving `redeem` to take the
    ///         reserve's own word for a release on the leg where the holder's USDfr is already
    ///         burned and the loss is irreversible.
    /// @param expected The quoted payout in native USDC units.
    /// @param settled The redeemer's measured USDC balance increase.
    /// @param usdfrBurned The USDfr burned to pay for it.
    error Controller_RedemptionNotSettled(uint256 expected, uint256 settled, uint256 usdfrBurned);

    /// @notice AUDIT FIX (R17). USDC was left sitting on the controller after a mint. The
    ///         controller is value-neutral at rest; a reserve that funded the deposit from
    ///         somewhere other than the controller's allowance satisfies the delivery equality
    ///         while leaving the user's cash here with a live approval against it.
    /// @dev Measured as a DELTA across the call, never as an absolute balance: anyone can send
    ///      USDC to the controller, so `balanceOf(this) != 0` would be a one-wei permanent
    ///      griefing lock on `mint`.
    /// @param balanceBefore The controller's USDC balance before the deposit leg.
    /// @param balanceAfter Its balance after it. Any inequality is refused.
    error Controller_CashStrandedOnController(uint256 balanceBefore, uint256 balanceAfter);

    /// @notice AUDIT FIX (R17). The operation would have widened the deficit measured on the
    ///         RECOGNITION-AWARE basis — backing net of the custody shortfall the reserve can
    ///         observe right now. Raised only by `mintYield`, the one supply-EXPANDING path with
    ///         no custody precondition; `mint` and `redeem` are refused earlier by
    ///         `Controller_ReserveCustodyShortfall`, and `burnLoss` is deliberately ungated.
    /// @param deficitBefore `max(0, totalUSDfr() - recognizedBackingValue())` before the call.
    /// @param deficitAfter The same quantity after it.
    error Controller_RecognizedDeficitWorsened(uint256 deficitBefore, uint256 deficitAfter);

    /// @notice AUDIT FIX (R17). A yield mint would have consumed value retained against
    ///         `seniorSubParShortfall()` — the haircut crystallised out of holders who exited
    ///         against a REVERSIBLE impairment mark. `mintableHeadroom()` advertises the retention;
    ///         this error enforces it.
    /// @dev CORRECTED (SWEEP-1 MRC-F3, 2026-08-08). This sentence used to end "...because
    ///      `WaterfallEngine.fund`'s origination-fee mint is not sized off that headroom and would
    ///      otherwise spend it." THAT JUSTIFICATION EXPIRED AT R18. `WaterfallEngine.fund` now
    ///      reads `uint256 headroom = $.controller.mintableHeadroom();` and clamps
    ///      `mintable = fee <= headroom ? fee : headroom` (WaterfallEngine.sol:195-197);
    ///      `MintRedeemController` says so in two places, and
    ///      `test_R18_A1_originationSurvivesACrystallisedHaircut` passes over the clamped path.
    ///      This is the same class of defect the merge author fixed on
    ///      `CollateralRegistry.conservativeSeniorMark`: a stale justification on a value path is
    ///      a defect, because the next engineer prunes the guard once they discover the reason
    ///      given for it is untrue.
    ///
    ///      THE ERROR IS STILL LOAD-BEARING, ON A DIFFERENT GROUND — DO NOT DELETE IT. It is the
    ///      LAST line of defence rather than the only one. `CREDIT_ROLE` gates `mintYield`, and
    ///      `Deploy.s.sol` grants that role to `WaterfallEngine` alone TODAY; a second grantee, or
    ///      any future unclamped call site, would spend the junior retention silently. The clamp is
    ///      a caller-side property; this is the callee-side one.
    /// @param retention `seniorSubParShortfall()`.
    /// @param surplus `max(0, recognizedBackingValue() - totalUSDfr())` after the mint.
    error Controller_SeniorRetentionBreached(uint256 retention, uint256 surplus);

    /// @notice AUDIT FIX (R18). The reserve took the USDC and reported the right credit but did not
    ///         BOOK it as backing. The recognition twin of `Controller_DepositNotCustodied`: R16-L2
    ///         measured custody and R17 measured the reported credit, while recognition was left to
    ///         the NON-WORSENING deficit rule — which a standing surplus silently pays for, up to
    ///         its own size. Measured as a DELTA on `backingValue()` across the deposit leg, so no
    ///         surplus can absorb it, and as an EQUALITY, so an over-booking reserve is refused too.
    /// @param credited The 18-decimal value `depositUSDC` reported.
    /// @param recognized The measured increase in `backingValue()` across the same call.
    error Controller_DepositNotRecognized(uint256 credited, uint256 recognized);

    /// @notice AUDIT FIX (R18). A loss source must not be an EIP-7702 DELEGATED EOA. Since Pectra
    ///         an ordinary key-controlled wallet that signed a delegation carries a 23-byte
    ///         `0xef0100`-prefixed code field, so `EXTCODESIZE` returns 23 and
    ///         `Controller_LossSourceNotContract`'s check admitted it — leaving finding M2 (a
    ///         forced, allowance-free, non-pro-rata seizure of one named holder, unstoppable by the
    ///         guardian) one routine-looking timelock transaction away for exactly the class of
    ///         wallet the guard claimed to exclude.
    error Controller_LossSourceIsDelegatedEOA(address account);

    /// @notice AUDIT FIX (R18). A composite view was read while this contract's reentrancy guard
    ///         was entered — i.e. from inside a supply change that has not finished settling — and
    ///         would have answered a number known to be false.
    /// @dev `_redeem` burns before it releases, and `DefaultManager.realizeLoss` burns before it
    ///      writes backing down; `USDfr._update` fires the participation-points hook inside every
    ///      one of those burns. From there `mintableHeadroom()` read the entire realised loss of a
    ///      cascade as distributable yield capacity, `backingInvariantHolds()` read TRUE on a short
    ///      book and `previewRedeem` quoted PAR on it. Reverting is the honest answer and is
    ///      fail-closed for an integrator; returning the number is the R4-01 self-contradiction one
    ///      frame deeper. The raw delegating views (`backingValue`, `recognizedBackingValue`,
    ///      `totalUSDfr`) are NOT gated: each is true whenever it is read. Only the composites are.
    error Controller_ViewUnavailableMidTransition();

    /// @notice `redeem(uint256,uint256,uint256)` was included after the caller's deadline
    ///         (ADR-0034 W).
    error Controller_DeadlinePassed(uint256 deadline, uint256 nowTimestamp);
    /// @notice The junior-draw source named by `ReserveManager.lossAbsorber()` is not on the
    ///         governance-maintained `setLossSource` list (ADR-0034 Y-bis). Fail-closed: the exit
    ///         refuses rather than burning a third party's USDfr on an unvouched-for pointer.
    error Controller_ExitDrawSourceNotAuthorised(address source);
    /// @notice The junior-draw source reported one number and moved another, or delivered more
    ///         than was asked of it (ADR-0034 Y-bis). Measured, not trusted.
    error Controller_ExitDrawNotDelivered(uint256 requested, uint256 reported, uint256 measured);

    /// @notice Junior capital was drawn forward, in cascade order, to fund this exit's price
    ///         (ADR-0034 Y-bis). `drawn` USDfr was burned out of the junior layers.
    event SeniorExitJuniorDrawn(address indexed redeemer, uint256 required, uint256 drawn);

    // ── User paths (KYC-gated) ───────────────────────────────────────────
    /// @notice Deposits USDC (6 decimals) and mints USDfr 1:1 in 18-decimal USD units.
    function mint(uint256 usdcAmount) external returns (uint256 usdfrOut);

    /// @notice Burns USDfr and releases the reserve's cash equivalent AT PAR. While the protocol
    ///         is short this form settles at par out of JUNIOR capital drawn forward in the same
    ///         transaction (ADR-0034 Y-bis), and reverts `Controller_SlippageExceeded` only once
    ///         that draw cannot reach par. It never haircuts the caller. Use
    ///         `redeem(uint256,uint256)` to elect a sub-par exit.
    /// @dev AUDIT FIX (R18) CORRECTED THE NOTICE LINE ABOVE, which every block explorer, ABI
    ///      doc and integrator reads first. It said this form is "priced at the coverage ratio: par
    ///      while the protocol is whole, `backing / supply` while it is short". After R17's par
    ///      floor that is false of THIS form. The coverage-ratio behaviour described below is
    ///      R16-M3's and is true of the two-argument form.
    /// @dev CORRECTED AGAIN (SWEEP-1 MRC-F2, 2026-08-08) — SAME LINE, ONE ROUND LATER. R18's
    ///      replacement said this form "REVERTS" while short, full stop. That stopped being true
    ///      at ADR-0034 Y-bis, which draws curator first-loss and the sGROVE backstop forward in
    ///      the same transaction to fund the cascade-ordered price. MEASURED: with a gross quote of
    ///      185,928.705440 USDC this form settled 200,000.000000 — AT PAR, out of junior capital.
    ///      It reverts only when the draw cannot reach par. Two successive rounds put a false
    ///      settlement claim on the one line integrators read first; check it against
    ///      `MintRedeemController._quoteRedeem` and `_drawJuniorForExit` before editing it again.
    /// @dev AUDIT FIX (R17): THIS FORM SUPPLIES THE PAR FLOOR. It settles at par or reverts with
    ///      `Controller_SlippageExceeded`. R16 made the price a live function of state and left
    ///      this one-argument signature accepting whatever the ratio was at inclusion, while
    ///      several NON-timelocked paths move backing down in the same block. Taking a haircut is
    ///      now an explicit election: quote with `previewRedeem`, then call the two-argument form
    ///      with the floor you will accept.
    function redeem(uint256 usdfrAmount) external returns (uint256 usdcOut);

    /// @notice Burns USDfr and releases the reserve's cash equivalent, refusing to settle below
    ///         `minUsdcOut`. This is the form that accepts a SUB-PAR exit — an explicit, informed
    ///         election by the holder (R16-M3, R17).
    /// @dev CORRECTED (SWEEP-1 MRC-F2, 2026-08-08). This line said the form "pays the COVERAGE
    ///      RATIO". It pays the JUNIOR-DRAWN price, which is >= the coverage ratio and may be par:
    ///      ADR-0034 Y-bis draws curator first-loss and the sGROVE backstop forward in the same
    ///      transaction, and the gross `backing / supply` mark is only the floor the price degrades
    ///      to once junior capital is exhausted. Quote with `previewRedeem`, which shares the
    ///      drawn arithmetic.
    /// @dev AUDIT FIX (R17). `previewRedeem` is advisory ACROSS TRANSACTIONS — it shares
    ///      `redeem`'s arithmetic, not its state — so this parameter is the only thing that binds
    ///      the settlement price. Pass the value `previewRedeem` returned (or lower, to tolerate
    ///      movement).
    /// @dev THE DEADLINE IS NOW SHIPPED, ON A NEW SIGNATURE (ADR-0034 W). R17 wrote here that
    ///      "there is no deadline parameter: there is no AMM-style path here, and the floor alone
    ///      is sufficient to make the exit refusable", which argued an ACCEPTED requirement away.
    ///      `redeem(uint256,uint256,uint256)` carries it. THIS form is deliberately left
    ///      deadline-free rather than being given a new expiry semantic under an unchanged
    ///      signature — see that overload's NatSpec. Prefer the three-argument form.
    /// @param usdfrAmount USDfr offered; the burn is snapped down to the whole-USDC-unit grid.
    /// @param minUsdcOut The lowest native-USDC payout the caller will accept. Zero accepts ANY
    ///        price, including a deep haircut — pass zero only deliberately.
    function redeem(uint256 usdfrAmount, uint256 minUsdcOut) external returns (uint256 usdcOut);

    /// @notice Burns USDfr and releases the reserve's cash equivalent, refusing to settle below
    ///         `minUsdcOut` or after `deadline`. THE CANONICAL EXIT (ADR-0034 W).
    /// @dev A minimum-out bounds the PRICE; it does not bound WHEN the exit executes. Every path
    ///      that moves the coverage ratio down is un-timelocked and publicly visible before it
    ///      lands, so a transaction left in the mempool is a free option for whoever chooses
    ///      inclusion. See the implementation NatSpec.
    /// @param usdfrAmount USDfr offered; the burn is snapped down to the whole-USDC-unit grid.
    /// @param minUsdcOut The lowest native-USDC payout the caller will accept.
    /// @param deadline Latest `block.timestamp` at which this exit may settle.
    function redeem(uint256 usdfrAmount, uint256 minUsdcOut, uint256 deadline) external returns (uint256 usdcOut);

    // ── Protocol paths (credit layer; wired in Phases E/G) ───────────────
    /// @notice Mints USDfr to `to` against newly received, attested backing (loan
    ///         interest / reserve yield). `CREDIT_ROLE`.
    /// @dev AUDIT FIX (R16-M1): `to` must be a governance-authorized yield sink. Refuses while
    ///      the protocol is under-backed (incoming cash repairs the hole before it is paid out
    ///      as yield) and while the controller is paused (a pause must never permit supply
    ///      expansion). Callers should size the mint with `mintableHeadroom()`.
    /// @dev AUDIT FIX (R17/R18): it ALSO refuses while the surplus is below
    ///      `seniorSubParShortfall()` (`Controller_SeniorRetentionBreached`) — an ABSOLUTE level
    ///      check that bites in states the protocol publishes as fully backed. EVERY CALLER MUST
    ///      SIZE ITSELF OFF `mintableHeadroom()`: it is the one view that nets the retention, both
    ///      pauses and the recognition basis. `WaterfallEngine` now does so on BOTH of its mints
    ///      (interest since R16-M5, the origination fee since R18); a caller that does not will
    ///      revert rather than withhold.
    function mintYield(address to, uint256 amount) external;

    /// @notice Burns USDfr from `from` to realize a loss through the cascade.
    ///         `LOSS_BURNER_ROLE` — deliberately NOT `CREDIT_ROLE`.
    /// @dev AUDIT FIX (R16-M1/M2): `from` must be a governance-authorized loss source, and the
    ///      role is split from `CREDIT_ROLE` so `WaterfallEngine`, which never burns, no longer
    ///      holds the power to. Never pausable: loss absorption must stay available.
    function burnLoss(address from, uint256 amount) external;

    // ── Governance: credit-layer endpoints (AUDIT FIX R16-M1) ────────────
    /// @notice Authorizes (or revokes) an address as a destination for `mintYield`.
    function setYieldSink(address account, bool authorized) external;

    /// @notice Authorizes (or revokes) an address as a source for `burnLoss`.
    function setLossSource(address account, bool authorized) external;

    // ── Views ────────────────────────────────────────────────────────────
    /// @notice Current backing value on the RECORDED-LEDGER basis
    ///         (delegates to `ReserveManager.totalBackingValue()`).
    /// @dev AUDIT FIX (R4-01): this is the basis the C-01 custody-loss arithmetic reconciles
    ///      against within a single transaction and is deliberately NOT recognition-aware. For any
    ///      solvency or exit-pricing question use `recognizedBackingValue()`.
    function backingValue() external view returns (uint256);

    /// @notice AUDIT FIX (R4-01). Backing net of the custody shortfall the reserve can observe
    ///         right now (delegates to `ReserveManager.recognizedBackingValue()`).
    function recognizedBackingValue() external view returns (uint256);

    /// @notice Current USDfr total supply.
    function totalUSDfr() external view returns (uint256);

    /// @notice True if supply is covered on the RECORDED ledger.
    /// @dev Compatibility diagnostic only. DELIBERATELY BLIND TO THE CUSTODY SHORTFALL and no
    ///      longer consumed by `WaterfallEngine.distribute`: that path enforces exact receipt and
    ///      a non-worsening recognised deficit. Do not use this absolute view as an admission
    ///      gate, user-path condition, exit price, or solvency display.
    function creditServicingBackingHolds() external view returns (bool);

    /// @notice True if the backing invariant currently holds. Public so anyone can check.
    /// @dev AUDIT FIX (R4-01): measured against `recognizedBackingValue()`, so it can no longer
    ///      report true in the same block in which `observeIdleUSDC()` publishes a shortfall.
    /// @dev AUDIT FIX (R18): reverts with `Controller_ViewUnavailableMidTransition` if called from
    ///      inside an unsettled supply change — mid-burn it read TRUE on a 20%-short book.
    function backingInvariantHolds() external view returns (bool);

    /// @notice AUDIT FIX (R16-M4/M5). `max(0, totalUSDfr() - backingValue())` on the RECORDED
    ///         basis — the quantity every supply-affecting path refuses to increase.
    /// @dev AUDIT FIX (R18): reverts with `Controller_ViewUnavailableMidTransition` if called from
    ///      inside an unsettled supply change; it composes a supply reading with a backing reading.
    function backingDeficit() external view returns (uint256);

    /// @notice AUDIT FIX (R16-M4). The same quantity on the RECOGNITION-AWARE basis (net of any
    ///         observable custody shortfall).
    /// @dev This is what `WaterfallEngine.distribute` gates on, comparing it before and after the
    ///      call. Non-worsening rather than absolute, so a repayment that REPAIRS backing is not
    ///      refused merely because the protocol was already short — which is what previously
    ///      turned a single conservative mark into a total halt of repayment processing.
    /// @dev AUDIT FIX (R18): reverts with `Controller_ViewUnavailableMidTransition` if called from
    ///      inside an unsettled supply change, as `backingDeficit()` does.
    function recognizedDeficit() external view returns (uint256);

    /// @notice AUDIT FIX (R16-M5, corrected by R17, R18 and SWEEP-2 S2-F4). How much NEW supply may
    ///         be minted without widening the deficit or paying away value the protocol owes:
    ///         `(paused() || USDfr.paused()) ? 0 : max(0, recognizedBackingValue() - totalUSDfr() -
    ///         seniorSubParShortfall() - ReserveManager.exitPrepaidAbsorption())`.
    /// @dev AUDIT FIX (SWEEP-2 S2-F4) — THE FOURTH TERM WAS MISSING FROM THIS PUBLISHED FORMULA, AND
    ///      THE STRING `exitPrepaid` APPEARED NOWHERE IN THIS FILE. ADR-0034 Y-bis added
    ///      `ReserveManager.exitPrepaidAbsorption()` to the implementation and not to the
    ///      specification. This is the one view that decides how much yield may be minted, and
    ///      `mintYield`'s note below warns that "a caller that does not size itself off
    ///      `mintableHeadroom()` will revert rather than withhold" — so a caller sizing off the
    ///      PUBLISHED formula got `Controller_SeniorRetentionBreached` /
    ///      `Controller_RecognizedDeficitWorsened` instead of a withholding. MEASURED: published
    ///      formula 9,900.99e18, code 0, undocumented term 9,900.99e18. The retention has NO
    ///      RESTITUTION PATH and is not necessarily released — see `mintableHeadroom`'s own
    ///      implementation note and the SWEEP-2 S2-F3 register entry.
    /// @dev AUDIT FIX (R18): the pause term reads BOTH pauses. R17 read only the controller's, while
    ///      the same guardian key holds `GUARDIAN_ROLE` on `USDfr` and a token pause refuses every
    ///      mint — so one transaction still reverted every interest-bearing
    ///      `WaterfallEngine.distribute` in full. `WaterfallEngine.fund` now sizes its origination
    ///      fee off this view as well, so under either pause it withholds the fee instead of
    ///      reverting the origination.
    /// @dev AUDIT FIX (R18): reverts with `Controller_ViewUnavailableMidTransition` if called from
    ///      inside an unsettled supply change — mid-cascade it read the entire realised loss as
    ///      distributable yield capacity.
    /// @dev `WaterfallEngine._routeInterest` reads this and distributes only what fits,
    ///      WITHHOLDING the rest so the cash stays in the reserve and repairs backing. That is
    ///      the protocol-native cure for a residual deficit: loan interest closes the hole
    ///      automatically, with no governance action and no recapitalisation, and yield resumes
    ///      by itself once it is closed.
    /// @dev AUDIT FIX (R17): the basis is RECOGNITION-AWARE. Measured on the recorded ledger the
    ///      cure was blind to the entire deficit class R4-01 exists to recognise — a custody hole
    ///      left headroom equal to the whole interest receipt, so the clamp withheld nothing, the
    ///      protocol fee was taken on the gross, and the hole never closed while every user was
    ///      frozen out of `mint` and `redeem`. It is also zero while the controller is PAUSED, so
    ///      the pause withholds yield instead of reverting every borrower repayment, and it nets
    ///      out `seniorSubParShortfall()`.
    function mintableHeadroom() external view returns (uint256);

    /// @notice AUDIT FIX (R17). Cumulative value crystallised out of the senior layer by sub-par
    ///         exits, in 18-decimal USD. Monotonically non-decreasing; no setter.
    /// @dev Sub-par exits are priced against `recognizePrincipalImpairment` marks, which are
    ///      REVERSIBLE by design (`releasePrincipalImpairment`). The exiter's loss is not. Without
    ///      this, value recovered when a mark is released reappeared as `mintableHeadroom()` and
    ///      was minted to the `sUSDfr` vault — the senior's haircut becoming the yield layer's
    ///      income, ahead of the §1.3 cascade's first two layers. Netting it out of the headroom
    ///      keeps recovered value in the pool as coverage instead. Reconstructable from
    ///      `SeniorShortfallCrystallised` events.
    /// @dev AUDIT FIX (R18) — WHAT IT COSTS, CORRECTED. `mintYield` enforces this as an ABSOLUTE
    ///      level check, so it withholds ORIGINATION FEES as well as interest, and it does so in
    ///      states the protocol publishes as fully backed and even OVER-backed. Under R17 that
    ///      REFUSED `WaterfallEngine.fund` outright and therefore blocked the only cure the
    ///      mechanism names (interest requires a facility; a facility requires `fund`) — finding M5
    ///      on the origination axis. `fund` now clamps its fee to `mintableHeadroom()` and withholds
    ///      instead. The retention is unchanged. Read `MintRedeemController.seniorSubParShortfall`
    ///      for the full statement, including the known over-charge on a REALISED (as opposed to
    ///      released) loss, which is outstanding.
    function seniorSubParShortfall() external view returns (uint256);

    /// @notice AUDIT FIX (R16-M3/L3). Quotes a redemption without executing it: the USDC that
    ///         would be paid and the USDfr that would actually be burned.
    /// @dev Returns `(0, 0)` — BOTH components — in FOUR cases: the amount is below the settleable
    ///      floor; the protocol has no backing; the protocol is empty (`totalUSDfr() == 0`); or
    ///      REDEMPTION IS CLOSED because the reserve has an unreconciled custody shortfall
    ///      (`idleCustodyShortfall() != 0`, AUDIT FIX R18). In all four, nothing is payable at any
    ///      size, which is what `(0, 0)` has always meant here. A frontend can therefore state the
    ///      floor, or state that redemption is unavailable, without simulating a revert.
    /// @dev AUDIT FIX (R18) added the fourth case. R17 changed WHICH number this published over a
    ///      custody hole; it did not change WHETHER one was published, so in the standing R4-01
    ///      state — where `backingInvariantHolds()` already publishes FALSE — this returned a full,
    ///      settleable-looking quote for a call that `_requireCustodiedReserve` then refuses with
    ///      `Controller_ReserveCustodyShortfall`. Passing that number back in as `minUsdcOut`, as
    ///      the sentence above directs, reverted.
    /// @dev AUDIT FIX (R18): reverts with `Controller_ViewUnavailableMidTransition` if called from
    ///      inside an unsettled supply change (the participation-points hook fires mid-burn, where
    ///      this view quoted PAR on a short book).
    /// @dev AUDIT FIX (R17), correcting R16's claim that "quote and settlement cannot diverge".
    ///      This view shares `redeem`'s ARITHMETIC; it does not share `redeem`'s preconditions and
    ///      it does not bind the price. Two consequences a caller must know:
    ///        - It is priced on `recognizedBackingValue()`, because unlike `redeem` it is not
    ///          behind `_requireCustodiedReserve`. On the recorded basis it published a par quote
    ///          in exactly the state where the recorded ledger is known to be false and the call it
    ///          quoted for would revert. Wherever `redeem` is reachable the two bases are equal, so
    ///          the quote is exact there.
    ///        - It is a snapshot of the current state, valid for that state only. Pass it back into
    ///          `redeem(usdfrAmount, minUsdcOut)`; that parameter, not this view, is what binds.
    function previewRedeem(uint256 usdfrAmount) external view returns (uint256 usdcOut, uint256 usdfrIn);

    /// @notice AUDIT FIX (R16-M1). True if `account` may receive `mintYield`.
    function isYieldSink(address account) external view returns (bool);

    /// @notice AUDIT FIX (R16-M1/M2). True if `account` may be burned from by `burnLoss`.
    function isLossSource(address account) external view returns (bool);

    /// @notice Wired module addresses, used to bind ReserveManager's independent loss check to
    ///         the controller that actually points back to that reserve.
    function modules() external view returns (address usdfr, address compliance, address reserves);
}
