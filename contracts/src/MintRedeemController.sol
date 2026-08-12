// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IComplianceRegistry} from "./interfaces/IComplianceRegistry.sol";
import {IMintRedeemController} from "./interfaces/IMintRedeemController.sol";
import {IReserveManager} from "./interfaces/IReserveManager.sol";
import {ISeniorExitDrawSource} from "./interfaces/ISeniorExitDrawSource.sol";
import {IUSDfr} from "./interfaces/IUSDfr.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title MintRedeemController
/// @notice The only mint/burn path for USDfr, and the enforcement point of the backing
///         invariant (ADR-0012). Mint/redeem is KYC-gated (ADR-0011); yield-mint and
///         loss-burn are credit-layer paths (Phase E/G).
///
/// @dev THE SOLVENCY MODEL, IN ONE PLACE (audit round R16 — findings M3/M4/M5).
///      Before this round the contract had exactly ONE solvency predicate: the absolute
///      inequality `totalSupply <= backingValue`, asserted identically after mint, redeem,
///      mintYield and burnLoss. An absolute inequality has only two states, and both of them
///      were wrong once a loss was recognised:
///        - PRETEND. Nothing had recognised the loss yet, so the predicate reported TRUE and the
///          protocol went on issuing and honouring par claims against a hole (R4-01, G3).
///        - FREEZE. Once the loss WAS recognised, the predicate reported FALSE and stayed false,
///          and because every supply-affecting path asserted it, EVERY path reverted at once:
///          `mint`, `redeem`, `mintYield` and `burnLoss`, taking `WaterfallEngine.fund` and
///          `WaterfallEngine.distribute` down with them. A single G3 conservative mark — an
///          ordinary, expected credit event — therefore bricked the whole protocol with no
///          protocol-native cure (M5). Worse, `burnLoss` is the cascade's OWN instrument for
///          absorbing that loss, so the freeze disabled the only mechanism that could have
///          ended it.
///
///      THE REPLACEMENT IS ONE PREDICATE, NOT FOUR. Every supply-affecting path now asserts
///      the same rule, `_assertDeficitNotWorsened`: an operation may not INCREASE
///      `deficit = max(0, totalSupply - backingValue)`. That rule is strictly stronger than the
///      old one where the old one was meaningful and strictly weaker only where the old one was
///      merely punitive:
///        - while the protocol is whole (`deficit == 0`) it reduces EXACTLY to ADR-0012's
///          `totalSupply <= backingValue`, and still reverts with
///          `Controller_BackingInvariantViolated`;
///        - while the protocol is short it permits precisely the operations that repair or
///          preserve holders' position, and refuses the ones that dilute it.
///      With one rule there is no longer an "inconsistent predicate" question to get wrong (M4):
///      `mint`, `redeem` and `mintYield` all assert it, and `burnLoss` is the one path that
///      cannot violate it in any reachable state (see its NatSpec — that is stated as a proof,
///      not asserted as an unfalsifiable guard).
///
///      SUB-PAR REDEMPTION IS THE POINT (M3, AS AMENDED BY R17 — READ THE WHOLE PARAGRAPH; AN
///      EARLIER REVISION OF IT CONTRADICTED THE CODE AND THAT WAS ITSELF A FINDING). Freezing
///      redemption was justified on the ground that par exits out of a short pool are a run. That
///      is true of PAR exits and false of exits generally. THE TWO-ARGUMENT FORM
///      `redeem(uint256,uint256)` pays the coverage ratio: at `backing/supply == 0.97` a holder
///      who passes a floor of 0.97 or lower gets 97 cents, and the ratio left behind for everyone
///      who did not redeem is unchanged to the wei-rounding, which always favours the holders who
///      stayed. THE ONE-ARGUMENT FORM `redeem(uint256)` NEVER PAYS 97 CENTS: R17 gave it the PAR
///      FLOOR, so it either settles at PAR or reverts `Controller_SlippageExceeded` — it never
///      haircuts a caller who did not ask to be haircut (see `redeem(uint256)`).
///
///      CORRECTED (SWEEP-1 MRC-F2, 2026-08-08) — THIS PARAGRAPH SAID THE ONE-ARGUMENT FORM
///      "REVERTS" IN THE SHORT STATE, FULL STOP. THAT IS NO LONGER TRUE AND HAS NOT BEEN SINCE
///      ADR-0034 Y-bis. `_drawJuniorForExit` draws curator first-loss and the sGROVE backstop
///      forward IN THE SAME TRANSACTION to fund the cascade-ordered price, so while junior capital
///      stands the one-argument form can and does SETTLE AT PAR out of that capital; it reverts
///      only once the draw cannot reach par. MEASURED: with a gross quote of 185,928.705440 USDC
///      the one-argument form settled 200,000.000000. The correction matters because this very
///      paragraph carries the warning that "AN EARLIER REVISION OF IT CONTRADICTED THE CODE AND
///      THAT WAS ITSELF A FINDING". So the protocol can say "we
///      are 3% short, here is 97 cents" — but only to a holder who has elected that price.
///      `previewRedeem` publishes the quote so the number is knowable before signing, and the
///      number it returns is what should be passed back as `minUsdcOut`.
///
///      MINT STAYS CLOSED WHILE SHORT. It is not symmetric with redeem and must not be made so:
///      redeeming at the ratio is the holder's own money at an honest price, whereas minting at
///      par into a short book sells a NEW holder a claim worth less than the dollar they paid,
///      and minting at the ratio would let an insolvent protocol keep issuing. Closed is the
///      only honest answer, and it is the R4-01 finding restated.
///
/// @dev WHAT AUDIT ROUND R17 CHANGED, AND WHY (read this next). R16 made the exit price a live
///      function of state and published a view for it. The adversarial round that followed found
///      that the two halves of that change had not been finished:
///
///      (1) TWO BASES, ONE OF THEM FALSIFIABLE. `mintableHeadroom()` and `previewRedeem` were
///          measured on the RECORDED ledger, which an unreconciled custody shortfall has already
///          falsified — the exact R4-01 condition. `WaterfallEngine._routeInterest` sizes yield
///          off `mintableHeadroom()`, so under a custody hole the whole interest leg was minted
///          out as yield (protocol fee taken on the gross) while `mint` and `redeem` were frozen
///          and the hole was not repaired by a wei. Both views are now RECOGNITION-AWARE, and
///          `mintYield` asserts the non-worsening rule on BOTH bases. See `mintableHeadroom`.
///
///      (2) A VARIABLE PRICE WITH NO FLOOR. `redeem(uint256)` was written when the price was the
///          constant 1:1 and needed no `minUsdcOut`. Once the price moved, the one-argument form
///          silently accepted whatever the ratio happened to be at inclusion — and several
///          NON-timelocked paths (`recordPrincipalWritedown`, `reconcileIdleUSDC`) lower backing
///          in the same block. There is now `redeem(uint256,uint256)`, and the ONE-ARGUMENT FORM
///          DEFAULTS TO THE PAR FLOOR: it settles at par or reverts. A sub-par exit is now an
///          EXPLICIT, informed election by the holder, never a silent haircut.
///
///      (3) THE HAIRCUT WAS BEING RECYCLED AS JUNIOR YIELD. `recognizePrincipalImpairment` is a
///          REVERSIBLE governance valuation act (`releasePrincipalImpairment` exists precisely so
///          governance is willing to mark conservatively). A holder who exited against that mark
///          crystallised a permanent loss; when the mark was later released the recovered value
///          reappeared as `mintableHeadroom()` and was minted to the `sUSDfr` vault as yield. The
///          senior's haircut became someone else's income. `seniorSubParShortfall()` now records
///          the cumulative crystallised haircut and `mintableHeadroom()` nets it out, so recovered
///          value stays in the pool as coverage for the holders who are still in it instead of
///          being distributed. This is a MITIGATION, not a full answer — see that function's
///          NatSpec and `redeem`'s "WHAT THIS DOES NOT PROMISE" section for the part that is a
///          Forest Road decision, deliberately NOT taken unilaterally here (CLAUDE.md §0.5/§0.7).
///
///      (4) ONE LEG OF THE R16-L2 MEASUREMENT WAS MISSING. `mint` measured the reserve's own
///          balance across `depositUSDC`; `redeem` took the reserve's word for `releaseUSDC` — on
///          the leg where the holder's USDfr is ALREADY BURNED. `redeem` now measures the
///          redeemer's own balance across the release. See `Controller_RedemptionNotSettled`.
///
/// @dev WHAT AUDIT ROUND R18 CHANGED (the adversarial round that attacked R17). R17's mitigations
///      were sound on the paths they were written for and wrong on the adjacent ones. In order of
///      severity:
///
///      (A) THE SENIOR RETENTION FROZE ORIGINATION, PERMANENTLY. `Controller_SeniorRetentionBreached`
///          is an ABSOLUTE level check, and `WaterfallEngine.fund`'s origination-fee mint was the
///          one `mintYield` caller not sized off `mintableHeadroom()`. So a single crystallised
///          haircut refused `fund` outright — including on a book the protocol publishes as WHOLE
///          or OVER-backed — and the only cure the retention's own NatSpec named (withheld
///          interest) requires a funded facility, which requires the `fund` the retention had just
///          closed. That is finding M5 ("permanently inert, no protocol-native cure") restored on
///          the origination axis. R18 CLAMPS `fund`'s fee to `mintableHeadroom()` exactly the way
///          `_routeInterest` already clamps interest: the undistributable part is WITHHELD as
///          unencumbered backing (which is what rebuilds the surplus the retention wants) and the
///          facility funds. The retention is unchanged and still enforced here; it can no longer
///          brick the path that cures it. See `mintYield` and `seniorSubParShortfall`.
///
///      (B) THE D3 PAUSE FIX WAS HALF APPLIED. `mintableHeadroom()` read only THIS contract's
///          `paused()`. The same guardian key holds `GUARDIAN_ROLE` on `USDfr`, whose `_update`
///          refuses every mint while the token is paused, so one un-timelocked transaction still
///          reverted every interest-bearing `WaterfallEngine.distribute` — the exact harm the
///          clamp was built to prevent, through the pause the clamp could not see.
///          `mintableHeadroom()` now reads BOTH pauses. See `mintableHeadroom` and `pause`.
///
///      (C) EIP-7702 DEFEATED `setLossSource`'s CODE CHECK. Since Pectra an ordinary key-controlled
///          EOA that has signed a delegation carries a 23-byte `0xef0100`-prefixed code field, so
///          `EXTCODESIZE` returns 23 and R17's "no user wallet is seizable" claim was false for
///          precisely the wallets most users now hold. See `setLossSource`.
///
///      (D) THE FAIL-OPEN POINTS HOOK BECAME A REDEMPTION KILL SWITCH. `_redeem` opened its
///          outflow measurement window BEFORE `usdfr.burn`, and `USDfr._update` fires the
///          participation-points hook inside that burn. One wei of USDC moved to the redeemer by
///          that hook broke the settlement equality and reverted the redemption — from outside the
///          token's `try/catch`, so the token's protocol-wide "a points-module failure must never
///          block a transfer, mint or burn" rule held for transfers and not for redemptions. The
///          window now contains `releaseUSDC` and nothing else. See `_redeem`.
///
///      (E) THE VIEWS PUBLISHED THE OPPOSITE OF THE TRUTH MID-TRANSITION. `_redeem` burns before it
///          releases and `DefaultManager.realizeLoss` burns before it writes backing down, so an
///          observer that receives control inside a USDfr balance change (the points hook) read
///          `mintableHeadroom()` as the whole realised loss, `backingInvariantHolds()` as TRUE on a
///          short book and `previewRedeem` as PAR. The composite views now REVERT while this
///          contract's reentrancy guard is entered rather than answer a number that is false. See
///          `Controller_ViewUnavailableMidTransition`.
///
///      (F) `mint` MEASURED CUSTODY AND THE REPORTED CREDIT, NEVER RECOGNITION. A reserve that took
///          the cash, reported the right credit and never booked it as backing was caught only for
///          the part of the gap EXCEEDING the standing surplus, because the only thing covering
///          recognition was the NON-WORSENING rule. `mint` now measures the backing delta directly.
///          See `Controller_DepositNotRecognized`.
///
///      (G) `previewRedeem` QUOTED A SETTLEABLE PRICE FOR A CALL THAT CANNOT EXECUTE. It sits
///          outside `_requireCustodiedReserve` (correctly — it is permissionless), so under an
///          unreconciled custody shortfall it published an honest-looking quote for a `redeem` that
///          reverts. It now answers `(0, 0)`, which its documented contract already means
///          "nothing is payable". See `previewRedeem`.
///
///      (H) ADR-0034 IS ACCEPTED AND IS IMPLEMENTED HERE (CORRECTED, SWEEP-1 MRC-F2, 2026-08-08).
///          THIS PARAGRAPH USED TO READ "IS ACCEPTED AND IS NOT IMPLEMENTED HERE", and it was
///          flatly contradicted 1,300 lines below by `_quoteRedeem`'s own "ADR-0034 Y-bis IS
///          IMPLEMENTED, and `drawn` is what implements it", and by `_drawJuniorForExit` in this
///          same file. The history it describes is accurate and worth keeping: R16/R17 priced the
///          sub-par exit off the GROSS book mark, netting nothing against curator first-loss or the
///          sGROVE backstop, so a senior holder could be haircut while junior capital standing
///          behind them was intact; R16/R17 NatSpec called that an OPEN Forest Road question,
///          "raised, not taken"; ADR-0034 (Accepted, 2026-08-07) took it against the shipped
///          behaviour, and R18 corrected the comments. WHAT CHANGED AFTERWARDS: ADR-0034 Y-bis
///          (Forest Road, 2026-08-08) decided DRAW — junior capital is moved at the moment of the
///          senior exit, in the same transaction, so cascade order is enforced AT SETTLEMENT. That
///          is implemented, in `_drawJuniorForExit` and `_quoteRedeem`. Read those two for the
///          mechanism, and `DefaultManager.drawForSeniorExit` for what the draw may and may not do.
contract MintRedeemController is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IMintRedeemController
{
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:forestroad.storage.MintRedeemController
    /// @dev Fields are APPEND-ONLY (ERC-7201 namespaced struct) for upgrade safety. The two
    ///      endpoint maps were appended in audit round R16 (finding M1) — see `setYieldSink`
    ///      and `setLossSource`; `subParShortfall` was appended in R17 — see
    ///      `seniorSubParShortfall`. Verified with `tools/check-storage-layout.mjs` and
    ///      `tools/check-compiled-storage-layout.mjs`.
    struct ControllerStorage {
        IUSDfr usdfr;
        IComplianceRegistry compliance;
        IReserveManager reserves;
        // ── append-only (upgrade safety) ──────────────────────────────────
        /// @dev AUDIT FIX (R16-M1). Addresses `mintYield` may credit.
        mapping(address account => bool) yieldSink;
        /// @dev AUDIT FIX (R16-M1/M2). Addresses `burnLoss` may burn from.
        mapping(address account => bool) lossSource;
        /// @dev AUDIT FIX (R17). Cumulative value crystallised out of the senior layer by sub-par
        ///      exits, in 18-decimal USD. Monotonically non-decreasing. See
        ///      `seniorSubParShortfall`.
        uint256 subParShortfall;
    }

    // keccak256(abi.encode(uint256(keccak256("forestroad.storage.MintRedeemController")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CONTROLLER_STORAGE_LOCATION =
        0x78d32d002402115460f3fdc161605476f91264ca4d3e131f8b3d65ead1f69100;

    /// @dev USDfr is 18-decimal; canonical USDC is 6-decimal. One whole USDC unit is `SCALE`
    ///      wei of USDfr.
    uint256 private constant SCALE = 1e12;

    error Controller_ZeroAddress();

    /// @dev THE IMPLEMENTATION INITIALISER LOCK — LOAD-BEARING, DO NOT DELETE. Without it the
    ///      logic contract behind the proxy is initialisable by anyone, which is finding A-01's
    ///      shape and the house convention every other implementation in `contracts/src` follows.
    ///      AUDIT NOTE (R18): R17's 63-guard deletion campaign did NOT enumerate this line, and it
    ///      survived the full non-fork suite when deleted — which also falsified R17's claim, made
    ///      on `mint`, that "every other guard in this file reds".
    ///      `test_R18_G64_theImplementationInitialiserIsLocked` is the falsifier that was missing.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the controller.
    /// @param admin Governance timelock.
    /// @param guardian Emergency pauser.
    /// @param upgrader Upgrade authority (timelock).
    /// @param usdfr The USDfr token (this contract must hold its MINTER_ROLE).
    /// @param compliance The compliance registry (KYC gate).
    /// @param reserves The ReserveManager (this contract must hold its CONTROLLER_ROLE).
    /// @dev The credit-layer endpoint maps (`setYieldSink`, `setLossSource`) start EMPTY, so a
    ///      freshly initialized controller can mint no yield and burn no loss until governance
    ///      names the endpoints. That is deliberate fail-closed wiring (CLAUDE.md prime
    ///      directive 4): an unwired controller refuses credit-layer supply changes rather than
    ///      accepting arbitrary ones. `Validate.s.sol` asserts the production wiring post-deploy.
    function initialize(
        address admin,
        address guardian,
        address upgrader,
        address usdfr,
        address compliance,
        address reserves
    ) external initializer {
        if (
            admin == address(0) || guardian == address(0) || upgrader == address(0) || usdfr == address(0)
                || compliance == address(0) || reserves == address(0)
        ) revert Controller_ZeroAddress();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.GUARDIAN_ROLE, guardian);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
        ControllerStorage storage $ = _storage();
        $.usdfr = IUSDfr(usdfr);
        $.compliance = IComplianceRegistry(compliance);
        $.reserves = IReserveManager(reserves);
    }

    // ── User paths (KYC-gated) ───────────────────────────────────────────

    /// @inheritdoc IMintRedeemController
    /// @dev THE INDEPENDENT DELIVERY CHECK (AUDIT FIX R16-L2) — DO NOT DELETE. Before this
    ///      round `mint` derived BOTH sides of its own safety check from the same module: it
    ///      minted exactly what `ReserveManager.depositUSDC` REPORTED, then asserted backing
    ///      using ReserveManager's own tally of that same deposit. A ReserveManager that
    ///      credited its ledger without taking custody of the cash — a skimming implementation,
    ///      a fee-on-transfer or blocklisting USDC, a botched upgrade — satisfied both sides of
    ///      the check with the money missing. The controller now measures the RESERVE'S OWN USDC
    ///      BALANCE across the call, which is a fact no ReserveManager function can report about
    ///      itself, and requires the delivered units and the credited value to agree with what
    ///      the user was charged.
    ///
    ///      RECOGNITION IS MEASURED TOO (AUDIT FIX R18) — DO NOT DELETE
    ///      `Controller_DepositNotRecognized`. R17 measured two of the three facts a mint depends
    ///      on: CUSTODY (`delivered == usdcAmount`, the reserve's own USDC balance really rose) and
    ///      the REPORTED CREDIT (`usdfrOut == usdcAmount * SCALE`). Neither says the reserve BOOKED
    ///      the deposit as backing, and the only thing covering that was `_assertDeficitNotWorsened`
    ///      — a NON-WORSENING rule, so a reserve that took the cash, reported the right credit and
    ///      never recognised it was caught only for the part of the gap EXCEEDING the standing
    ///      surplus. The undetected amount was exactly `backingValue() - totalUSDfr()`, and R17
    ///      WIDENED that window: because `mintableHeadroom()` nets out `seniorSubParShortfall()`,
    ///      the protocol is now designed to sit permanently on a surplus of exactly the retention.
    ///      The backing delta is therefore now measured directly and required to equal the credit,
    ///      which is a LEVEL-FREE check no standing surplus can pay for.
    ///
    ///      THE ALLOWANCE IS ZEROED (AUDIT FIX R17), AND IT IS NOT A FALSIFIABLE GUARD — R18
    ///      CORRECTED THIS PARAGRAPH, WHICH SAID THE OPPOSITE OF THE INLINE COMMENT ON THE LINE
    ///      ITSELF. R16 argued that no residual allowance was possible, because the delivery
    ///      equality refuses unless the reserve's balance rose by exactly `usdcAmount`, "which on
    ///      every reachable path is that allowance being spent in full". THAT ARGUMENT WAS UNSOUND,
    ///      and it was unsound for the same reason the guard three lines above exists: it assumed
    ///      the very module the guard exists to distrust. The equality constrains how much the
    ///      reserve's balance ROSE; it says nothing about WHERE the rise came from. But the guard
    ///      that CATCHES that reserve is the zero-DELTA check on this contract's own balance
    ///      (`Controller_CashStrandedOnController`), not the `forceApprove(…, 0)`;
    ///      `test_R17_L2b_aReserveThatSourcesTheDepositElsewhereIsRefused` reds the former and NOT
    ///      the latter. Read the inline comment on the line itself — it is the accurate one, and it
    ///      states the real reason the line is kept (stale-approval hygiene against L4-donated
    ///      USDC). Deleting it is safe against the whole suite; that is the honest statement and
    ///      finding M6 is why it has to be made rather than dressed up as protection.
    ///
    ///      SLITHER `reentrancy-balance` (High/Medium) FIRES HERE, AND IS ACCEPTED — R17 re-ran
    ///      `tools/run-slither-analysis.mjs` and added the entry to `contracts/slither-baseline.json`
    ///      against `MintRedeemController.mint`, which R16 had claimed was accepted while the gate
    ///      was in fact RED. This paragraph and the one on `_quoteRedeem` ARE the triage and must be
    ///      transcribed into `STATE.md` at merge, as CLAUDE.md §3.2 requires. It fires because a balance
    ///      read straddles an external call and gates a state change, which is the guard, not an
    ///      accident. Three things bound it: the function is `nonReentrant` (falsified by
    ///      `test_R17_G04_mintIsReentrancyLocked`, so that modifier is not an unfalsifiable
    ///      guard either); canonical USDC has no transfer callback; and the check is an EQUALITY,
    ///      so the manipulation direction is fail-CLOSED — an unsolicited donation to the reserve
    ///      mid-call makes `delivered` EXCEED `usdcAmount` and the mint reverts. The only
    ///      manipulation that passes is one in which the attacker funds the missing cash
    ///      themselves, which is not an attack.
    function mint(uint256 usdcAmount) external nonReentrant whenNotPaused returns (uint256 usdfrOut) {
        ControllerStorage storage $ = _storage();
        _requireKYC($, msg.sender);
        // AUDIT FIX (R4-01). See `_requireCustodiedReserve`. 1:1 issuance into a reserve the
        // protocol can already see is short sells a new claim on a hole. Deleting this line
        // reopens that.
        _requireCustodiedReserve($);
        if (usdcAmount == 0) revert Controller_ZeroAmount();

        (uint256 supplyBefore, uint256 backingBefore) = _supplyAndBacking($);
        // AUDIT FIX (R16-M3) — LOAD-BEARING, DO NOT DELETE. The par mint window is closed
        // whenever the protocol is under-backed for ANY reason, not just the R4-01 custody
        // reason immediately above: a G3 conservative mark on deployed principal, or a residual
        // deficit the cascade could not absorb, puts the protocol below par with custody
        // perfectly intact, and `_requireCustodiedReserve` sees none of it. Selling a fresh 1:1
        // claim there hands the new minter a sub-par instrument at par. Note the ASYMMETRY with
        // `redeem`, which stays OPEN and re-prices: see the contract-level NatSpec for why that
        // is deliberate and not an inconsistency.
        if (supplyBefore > backingBefore) {
            revert Controller_MintClosedWhileUnderBacked(supplyBefore, backingBefore);
        }

        IERC20 usdcToken = IERC20($.reserves.usdc());
        uint256 custodyBefore = usdcToken.balanceOf(address($.reserves));
        // A DELTA, NOT AN ABSOLUTE BALANCE, AND THE DIFFERENCE IS LOAD-BEARING. USDC can be sent
        // to this contract by anyone at any time (finding L4), so a guard written as
        // `balanceOf(this) != 0` would let one wei of donated USDC brick `mint` for everyone,
        // permanently — a worse defect than the one it closes, and a free griefing vector. What is
        // refused below is a change in this contract's balance ACROSS THE CALL.
        uint256 selfBefore = usdcToken.balanceOf(address(this));
        usdcToken.safeTransferFrom(msg.sender, address(this), usdcAmount);
        usdcToken.forceApprove(address($.reserves), usdcAmount);
        usdfrOut = $.reserves.depositUSDC(address(this), usdcAmount);
        // NOT A GUARD, AND LABELLED AS SUCH DELIBERATELY (AUDIT FIX R17). The falsifiable guard
        // for the residual-allowance finding is the ZERO-BALANCE check below; this line cannot be
        // turned red by any deletion mutation, because every state that leaves an allowance
        // standing also leaves cash standing and is refused there. That is not an assumption: it
        // is the MEASURED result of R17's 63-mutation guard-deletion campaign, in which this is
        // the ONE line of the 63 ENUMERATED GUARDS that survived the full non-fork suite with it
        // deleted. R18 CORRECTS THE SENTENCE THAT FOLLOWED — R17 wrote "every other guard in this
        // file reds", which was false: the campaign enumerated 63 guards, and at least one line
        // that IS a guard was not among them (`constructor() { _disableInitializers(); }`, which
        // also survived; R18 adds `test_R18_G64_theImplementationInitialiserIsLocked` so it no
        // longer does). The claim that holds is the narrow one: of the 63 guards R17 enumerated,
        // this is the only survivor. This line is kept for one reason only: so that USDC DONATED to
        // this contract after the fact (the L4 stranding case, which no protocol path creates)
        // cannot be pulled out by the reserve on a stale approval. Read it as hygiene, not as
        // protection — that distinction is the whole of finding M6.
        usdcToken.forceApprove(address($.reserves), 0);

        uint256 custodyAfter = usdcToken.balanceOf(address($.reserves));
        // The clamp is not decoration: `ControllerReserveDouble.Mode.DrainOnDeposit` takes the
        // charge and forwards MORE than it took, so the reserve's balance FALLS across the call
        // (`test_R17_G11_aReserveWhoseBalanceFallsAcrossTheDepositIsNamedNotPanicked`). Without
        // it that state is an arithmetic panic instead of `Controller_DepositNotCustodied`.
        uint256 delivered = custodyAfter < custodyBefore ? 0 : custodyAfter - custodyBefore;
        if (delivered != usdcAmount || usdfrOut != usdcAmount * SCALE) {
            revert Controller_DepositNotCustodied(usdcAmount, delivered, usdfrOut);
        }
        // AUDIT FIX (R17) — LOAD-BEARING, DO NOT DELETE. "The controller holds ZERO USDC at rest"
        // was argued in R16 and asserted only against the HONEST reserve. Under the untrusted
        // reserve the guard above already assumes, it is false: a reserve that funds the deposit
        // from a third party satisfies the delivery equality with the user's cash still sitting
        // here and a live allowance against it. Enforcing it makes the mint fail CLOSED instead.
        // The comparison is an EQUALITY on the delta, so it is fail-closed in BOTH directions: the
        // charge staying here is refused, and so is the reserve pulling MORE out of this contract
        // than it was approved for.
        uint256 selfAfter = usdcToken.balanceOf(address(this));
        if (selfAfter != selfBefore) revert Controller_CashStrandedOnController(selfBefore, selfAfter);

        // AUDIT FIX (R18) — LOAD-BEARING, DO NOT DELETE. The RECOGNITION leg of the R16-L2
        // measurement. Custody and the reported credit are both checked above; NEITHER of them
        // says the reserve booked the deposit as BACKING, and the only thing that covered
        // recognition was `_assertDeficitNotWorsened`, whose rule is NON-WORSENING and therefore
        // silently pays for any recognition gap up to the standing surplus. This is a DELTA
        // equality on `totalBackingValue()` across the deposit leg, so no standing surplus can
        // absorb it: `test_R18_F1_aStandingSurplusIsNoLongerABudgetForAnUncreditedDeposit` builds a
        // reserve in `ControllerReserveDouble.Mode.DepositWithoutCrediting` on a book carrying
        // exactly enough surplus to hide the whole deposit, and it is refused here. The equality is
        // fail-closed in BOTH directions: a reserve that OVER-books the deposit is refused too.
        // `depositUSDC` makes no external call that could move any other backing component (the
        // reserve is `nonReentrant` and canonical USDC has no transfer callback), so the honest
        // path is exact, not approximate.
        uint256 backingAfterDeposit = $.reserves.totalBackingValue();
        uint256 recognisedCredit = backingAfterDeposit < backingBefore ? 0 : backingAfterDeposit - backingBefore;
        if (recognisedCredit != usdfrOut) {
            revert Controller_DepositNotRecognized(usdfrOut, recognisedCredit);
        }

        $.usdfr.mint(msg.sender, usdfrOut);
        _assertDeficitNotWorsened($, supplyBefore, backingBefore);
        emit Minted(msg.sender, usdcAmount, usdfrOut);
    }

    /// @inheritdoc IMintRedeemController
    /// @dev THE ONE-ARGUMENT FORM IS THE PAR-FLOOR FORM (AUDIT FIX R17) — LOAD-BEARING, DO NOT
    ///      "SIMPLIFY" IT TO `_redeem(usdfrAmount, 0)`. R16 turned the exit price from the
    ///      constant 1:1 into a live function of `backing/supply` and did not change this
    ///      signature, so every caller written against the old constant kept sending a
    ///      one-argument transaction and silently accepted whatever the ratio was at inclusion.
    ///      Several protocol paths lower backing in the same block and NONE of them is
    ///      timelocked: `ReserveManager.recordPrincipalWritedown` (CREDIT_ROLE, keeper-driven),
    ///      `reconcileIdleUSDC`/`writeDownIdleUSDC` (RESERVE_ADMIN), and a timelock's own
    ///      `recognizePrincipalImpairment`, whose ready transactions are permissionlessly
    ///      executable and publicly visible. Defaulting to the par floor means this form settles
    ///      at par or REVERTS; taking a haircut requires the caller to name the price they will
    ///      accept. A holder is never silently impaired.
    function redeem(uint256 usdfrAmount) external nonReentrant whenNotPaused returns (uint256 usdcOut) {
        // The par floor: one whole USDC unit per `SCALE` wei of USDfr actually burnable.
        return _redeem(usdfrAmount, usdfrAmount / SCALE);
    }

    /// @inheritdoc IMintRedeemController
    function redeem(uint256 usdfrAmount, uint256 minUsdcOut)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 usdcOut)
    {
        return _redeem(usdfrAmount, minUsdcOut);
    }

    /// @inheritdoc IMintRedeemController
    /// @dev THE DEADLINE (ADR-0034 W) — LOAD-BEARING, DO NOT DELETE, AND THIS IS THE CANONICAL
    ///      FORM. R16 turned `redeem` from a fixed-price operation into a variable-price one and
    ///      gave it neither a minimum-out nor a deadline; R17 shipped the minimum-out. A
    ///      minimum-out alone bounds the PRICE but not the TIME: a transaction that sits in the
    ///      mempool through a gas spike executes at whatever ratio holds whenever a builder chooses
    ///      to include it, and every path that moves that ratio down is UNTIMELOCKED and publicly
    ///      visible before it lands — `recordPrincipalWritedown` (CREDIT_ROLE, keeper-driven),
    ///      `reconcileIdleUSDC`/`writeDownIdleUSDC` (RESERVE_ADMIN), and a timelock's own
    ///      `recognizePrincipalImpairment`, whose ready transactions anyone may execute. A
    ///      redeemer who set `minUsdcOut` at a healthy mark and was not included for an hour hands
    ///      a searcher a free option: hold the transaction until the ratio moves, then include it.
    ///      ADR-0034 W requires this "whichever pricing basis is chosen", i.e. independently of the
    ///      junior draw.
    ///
    ///      THE ONE- AND TWO-ARGUMENT FORMS ARE LEFT DEADLINE-FREE ON PURPOSE. Silently giving an
    ///      existing signature a new expiry semantic is R16's own mistake repeated — every caller
    ///      written against the old signature would keep compiling and start behaving differently.
    ///      Integrators should migrate to this form; the older ones remain valid and unexpired.
    function redeem(uint256 usdfrAmount, uint256 minUsdcOut, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 usdcOut)
    {
        // Falsified by `test_Y_G08_theDeadlineRefusesAnExpiredRedemption`.
        if (block.timestamp > deadline) revert Controller_DeadlinePassed(deadline, block.timestamp);
        return _redeem(usdfrAmount, minUsdcOut);
    }

    /// @dev SUB-PAR REDEMPTION (AUDIT FIX R16-M3, AMENDED BY R17) — READ THIS BEFORE CHANGING THE
    ///      ARITHMETIC. `_quoteRedeem` pays the COVERAGE RATIO, not par. The old behaviour is
    ///      preserved exactly while `backing >= supply` (the overwhelmingly common state), and the
    ///      branch only bites once the protocol is genuinely short.
    ///
    ///      WHAT THIS GUARANTEES, STATED EXACTLY (R17 CORRECTION). Every rounding in the quote is
    ///      DOWN, so the redeemer is paid at most their pro-rata share and THE INSTANTANEOUS BOOK
    ///      COVERAGE RATIO left behind for the holders who did not redeem is unchanged or better.
    ///      That property is real — it is fuzzed by
    ///      `testFuzz_M3_aSubParExitNeverWorsensTheRatioForTheHoldersWhoStayed` — and it is the
    ///      ONLY thing this arithmetic promises.
    ///
    ///      WHAT THIS DOES NOT PROMISE, AND R16'S NATSPEC WRONGLY CLAIMED IT DID. The sentence
    ///      "this is the same protection without the freeze" was removed in R17 because it is
    ///      false in two specific ways an auditor must be told:
    ///        - COMPOSITION. Backing is not homogeneous. The exit is settled ENTIRELY in cash out
    ///          of the idle leg, at a ratio struck on a BLENDED mark, so a first mover converts a
    ///          part-liquid, part-impaired claim into 100% cash and the holders who stay are left
    ///          with a residue concentrated in the leg that is still marking. The instant path is
    ///          therefore FIRST-COME-FIRST-SERVED ON LIQUIDITY. It is not a run in VALUE terms; it
    ///          is a race in LIQUIDITY terms.
    ///        - SEQUENCING. The ratio is preserved AT THE CURRENT MARK. A conservative G3 mark
    ///          that is later DEEPENED — the ordinary shape of a workout — reallocates the extra
    ///          loss onto whoever did not move first.
    ///      Capping the instant exit at the redeemer's pro-rata share of the IDLE leg and queueing
    ///      the residue would close both. There is no USDfr->USDC queue (ADR-0018's
    ///      `RedemptionQueue` orders the sUSDfr leg, not this one), so the cap alone would convert
    ///      a full exit into a permanently partial one with no ordered claim on the remainder —
    ///      strictly worse for the holder. R16 and R17 recorded the choice between that, a queue
    ///      and the status quo as an OPEN Forest Road question, "raised, not taken".
    ///
    ///      THAT IS NO LONGER TRUE, AND THE DECISION IS NOW IMPLEMENTED HERE.
    ///      `ADR/0034-exit-pricing-in-cascade-order.md` (Status: ACCEPTED, Forest Road 2026-08-07,
    ///      amended by decision Y-bis 2026-08-08) decides it AGAINST the R16/R17 behaviour.
    ///      Decision X: all capital is at risk, senior included, but losses are borne "in cascade
    ///      order at all times", which puts unstaked USDfr holders LAST rather than outside the
    ///      §1.3 cascade. Decision Y-bis: the junior-netted price and the junior DRAW are not
    ///      alternatives — the residual price promises more than gross-marked backing and the
    ///      difference sits in the curator pool and the sGROVE backstop, so junior capital is drawn
    ///      AT THE MOMENT OF THE EXIT, in this transaction, and cascade order is enforced AT
    ///      SETTLEMENT rather than assumed.
    ///
    ///      WHAT THAT MEANS FOR THE TWO HONEST CAVEATS ABOVE. COMPOSITION is unchanged: the exit is
    ///      still settled entirely in cash out of the idle leg, so the instant path is still
    ///      first-come-first-served ON LIQUIDITY. What HAS changed is the VALUE half: a holder
    ///      exiting while junior capital stands is now made whole out of that junior capital
    ///      instead of being haircut at the gross mark. SEQUENCING is unchanged and is the cost
    ///      ADR-0034 accepts EXPLICITLY: the mark that triggers a draw is conservative and
    ///      REVERSIBLE, so a draw crystallises junior capital against a loss that may never
    ///      materialise, and the beneficiary has already exited. Forest Road accepted that on
    ///      2026-08-08 in preference to a senior absorbing a loss the junior contracted to take
    ///      first. `mintableHeadroom()` retains the standing prepayment so the reversal does not
    ///      become sUSDfr yield.
    ///
    ///      DECISION W IS NOW COMPLETE: `minUsdcOut` shipped in R17, and the DEADLINE it also
    ///      requires ships on `redeem(uint256,uint256,uint256)`. DECISION Z is encoded as a
    ///      stateful campaign in `test/invariant/CascadeOrderedExitInvariants.t.sol`, with a
    ///      falsification test that reds it against a draw that draws nothing.
    ///
    ///      SEE `_drawJuniorForExit` AND `_exitDrawTarget` FOR THE MECHANISM, AND `_quoteRedeem`
    ///      FOR THE THREE THINGS THAT REMAIN OUTSTANDING (`previewRedeem`'s undrawn floor, the
    ///      class-less layer 1, and the draw stopping at layer 2).
    ///
    ///      WHY IT IS SAFE TO PRICE OFF `totalBackingValue()` HERE. `_requireCustodiedReserve`
    ///      has already refused if there is any observable custody gap, so at this line
    ///      `recognizedBackingValue() == totalBackingValue()` by construction. Pricing off the
    ///      recorded basis therefore quotes the same number as the recognition-aware basis while
    ///      keeping ONE basis across the quote and the closing assertion. If
    ///      `_requireCustodiedReserve` is ever relaxed, this must move to
    ///      `recognizedBackingValue()` in the same change. Note `previewRedeem` uses the
    ///      RECOGNITION-AWARE basis precisely because it is NOT behind that guard.
    ///
    ///      THE OUTFLOW DELIVERY MEASUREMENT (AUDIT FIX R17) — DO NOT DELETE. R16-L2 installed an
    ///      independent measurement on `mint` and left `redeem` deriving BOTH sides of its safety
    ///      check from the same module: the reserve lowers its own backing tally in `releaseUSDC`
    ///      and `_assertDeficitNotWorsened` reads that same tally back. A reserve that books the
    ///      release correctly and under-delivers the cash satisfied every guard — on the leg where
    ///      the holder's USDfr is ALREADY BURNED and the loss is irreversible. The redeemer's own
    ///      balance is now measured across the release. Same threat model as `mint`'s (a botched
    ///      upgrade, a blocklisting or fee-on-transfer USDC, a skimming implementation), same
    ///      fail-closed direction: an unsolicited donation to the redeemer mid-call makes the
    ///      delta exceed `usdcOut` and reverts.
    ///
    ///      THE MEASUREMENT WINDOW MUST CONTAIN `releaseUSDC` AND NOTHING ELSE (AUDIT FIX R18) — DO
    ///      NOT MOVE `payeeBefore` BACK ABOVE THE BURN. R17 opened the window before
    ///      `$.usdfr.burn(...)`, and `USDfr._update` fires the participation-points hook inside
    ///      every burn, with `gasleft() - 100_000` available to it. The token wraps that hook in
    ///      `try/catch` under an explicit protocol-wide rule — "a points-module failure must never
    ///      block a USDfr transfer, mint, or burn" (finding C4-USDFR-01) — but a hook that moved ONE
    ///      WEI of USDC to the redeemer broke the equality below, and the revert happened HERE,
    ///      outside that `try/catch`. R17 therefore handed a governance-set module the power to
    ///      brick every redemption while ordinary transfers kept working: the token's fail-open
    ///      guarantee held everywhere except the leg running through this guard. With the burn
    ///      hoisted out of the window the only external call inside it is `releaseUSDC`, and the
    ///      strict equality is preserved — which still catches a reserve that OVER-pays cash while
    ///      under-booking its ledger, something a `settled < usdcOut` relaxation would not.
    ///      GENERAL RULE, for anyone extending this function: no call that a redeemer or a
    ///      governance-set module can influence may be added between `payeeBefore` and `payeeAfter`.
    ///      SLITHER `reentrancy-balance` fires TWICE here for
    ///      the same reason it fires on `mint` — a balance read straddling an external call and
    ///      gating a state change IS the guard — and both entries are carried in
    ///      `contracts/slither-baseline.json` against `MintRedeemController._redeem`.
    function _redeem(uint256 usdfrAmount, uint256 minUsdcOut) private returns (uint256 usdcOut) {
        ControllerStorage storage $ = _storage();
        _requireKYC($, msg.sender);
        // AUDIT FIX (R4-01) — THE FINDING ITSELF. See `_requireCustodiedReserve`. Deleting this
        // line restores first-come-first-served exits out of a reserve whose USDC ledger is
        // known to be a lie — which sub-par pricing CANNOT protect against, because the price it
        // would quote comes from that same lying ledger.
        _requireCustodiedReserve($);
        if (usdfrAmount == 0) revert Controller_ZeroAmount();

        (uint256 supplyBefore, uint256 backingBefore) = _supplyAndBacking($);
        // AUDIT FIX (ADR-0034 Y-bis) — THE ATOMIC JUNIOR DRAW. It runs BEFORE the quote on purpose:
        // the ADR requires that "a quote that cannot be funded must not be issued", and striking
        // the price on the draw's MEASURED outcome makes an unfundable quote unrepresentable
        // rather than merely refused. See `_drawJuniorForExit`.
        uint256 drawn = _drawJuniorForExit($, (usdfrAmount / SCALE) * SCALE, supplyBefore, backingBefore);
        uint256 usdfrIn;
        (usdcOut, usdfrIn) = _quoteRedeem(usdfrAmount, supplyBefore, backingBefore, drawn);
        if (usdcOut == 0) {
            // AUDIT FIX (R17). A protocol whose backing has fallen to zero used to answer
            // `Controller_AmountTooSmall` — an error whose plain meaning is "your amount is too
            // small" when the truth is "there is nothing left to pay you". Distinguish them.
            if (backingBefore == 0 && supplyBefore != 0) revert Controller_NoRedeemableBacking(supplyBefore);
            // USDC has six decimals while USDfr has eighteen, so a redemption worth less than one
            // whole USDC unit cannot be settled at all. See `previewRedeem` for the exact floor
            // and why leaving the dust in the holder's wallet is the correct behaviour (R16-L3).
            revert Controller_AmountTooSmall(usdfrAmount);
        }
        // AUDIT FIX (R17) — LOAD-BEARING, DO NOT DELETE. The caller's price floor. `previewRedeem`
        // is advisory across transactions; this is the only thing that BINDS the settlement.
        if (usdcOut < minUsdcOut) revert Controller_SlippageExceeded(usdcOut, minUsdcOut);

        IERC20 usdcToken = IERC20($.reserves.usdc());

        // Burn (supply down) before releasing backing; the deficit rule is asserted after.
        $.usdfr.burn(msg.sender, usdfrIn);
        // AUDIT FIX (R18) — THE WINDOW OPENS HERE, AFTER THE BURN, ON PURPOSE. See this function's
        // NatSpec: the burn fires USDfr's deliberately FAIL-OPEN points hook, and a hook that moved
        // one wei of USDC to the redeemer inside the window turned this guard into a redemption
        // kill switch that the token's own `try/catch` could not absorb.
        uint256 payeeBefore = usdcToken.balanceOf(msg.sender);
        $.reserves.releaseUSDC(msg.sender, usdcOut);

        uint256 payeeAfter = usdcToken.balanceOf(msg.sender);
        // The clamp is falsified by `ControllerReserveDouble.Mode.ClawbackRelease`, a reserve that
        // debits the redeemer on a standing approval instead of paying them; without it that state
        // is an arithmetic panic rather than `Controller_RedemptionNotSettled`.
        uint256 settled = payeeAfter < payeeBefore ? 0 : payeeAfter - payeeBefore;
        if (settled != usdcOut) revert Controller_RedemptionNotSettled(usdcOut, settled, usdfrIn);

        // AUDIT FIX (ADR-0034 Y-bis) — THE ANCHOR IS RE-BASED ON THE POST-DRAW SUPPLY, AND THAT IS
        // LOAD-BEARING. `supplyBefore` was read BEFORE the junior draw burned `drawn`, so passing
        // it here would hand this check exactly `drawn` wei of slack to worsen into — and would
        // hide an under-delivering reserve behind junior capital, on the leg where the holder's
        // USDfr is ALREADY BURNED and the loss is irreversible. Anyone "simplifying" this back to
        // `supplyBefore` silently disables the guard in exactly the state it exists for.
        // Falsified by `test_Y_G07_theDeficitAnchorIsRebasedOnThePostDrawSupply`
        //      (test/audit/ADR0034Y_ExitDrawAnchor.t.sol).
        _assertDeficitNotWorsened($, supplyBefore - drawn, backingBefore);
        uint256 valuePaid = usdcOut * SCALE;
        if (valuePaid < usdfrIn) {
            // AUDIT FIX (R17) — LOAD-BEARING, DO NOT DELETE. See `seniorSubParShortfall`. This is
            // the crystallised, IRREVERSIBLE part of a REVERSIBLE mark. Recording it is what stops
            // a later `releasePrincipalImpairment` turning the exiter's loss into vault yield.
            uint256 crystallised = usdfrIn - valuePaid;
            uint256 cumulative = $.subParShortfall + crystallised;
            $.subParShortfall = cumulative;
            emit SeniorShortfallCrystallised(msg.sender, crystallised, cumulative);
            emit SubParRedemption(msg.sender, usdfrIn, usdcOut, supplyBefore, backingBefore);
        }
        emit Redeemed(msg.sender, usdfrIn, usdcOut);
    }

    // ── Credit-layer paths (wired in Phases E/G) ─────────────────────────

    /// @inheritdoc IMintRedeemController
    /// @dev THE `to` CONSTRAINT (AUDIT FIX R16-M1) — LOAD-BEARING, DO NOT DELETE. `mintYield`
    ///      constrained `to` in no way, and `burnLoss` constrained `from` in no way. The two
    ///      COMPOSED into arbitrary confiscation — burn a named holder's balance, mint the same
    ///      amount to an attacker — and `_assertBacking` could not detect it BY CONSTRUCTION,
    ///      because it compared two global aggregates and the pair left both unchanged. It was
    ///      reproduced on a mainnet fork with 250,000 real USDC borrowed from the Maker PSM.
    ///
    ///      WHAT CONSTRAINING THE ENDPOINTS ACTUALLY BOUGHT, STATED HONESTLY (R17 CORRECTION).
    ///      R16 claimed the endpoints "break the composition at both ends". That overstates it and
    ///      the overstatement is itself a defect, so here is the true statement. The aggregate
    ///      blindness is STRUCTURAL and untouched: `burnLoss` carries no solvency assertion at all
    ///      (correctly — see its NatSpec) and this function's assertion compares two global
    ///      aggregates, so a burn of X followed by a mint of X is invisible to it BY CONSTRUCTION.
    ///      What the endpoint lists removed is the ARBITRARY-VICTIM form: `from` must now be a
    ///      governance-named loss source AND (R17) a CONTRACT, so no user wallet is seizable, and
    ///      the residual composition can only reach the `sUSDfr` vault, whose burn is pro-rata
    ///      across every senior depositor. What `Roles.LOSS_BURNER_ROLE` removed is the
    ///      SINGLE-ROLE form: the composition now needs BOTH `LOSS_BURNER_ROLE` and `CREDIT_ROLE`,
    ///      which `Deploy.s.sol` deliberately splits across `DefaultManager` and `WaterfallEngine`.
    ///      THAT SPLIT IS LOAD-BEARING AND MUST NEVER BE RELAXED "FOR SYMMETRY" — it is one
    ///      `grantRole` deep, and `Validate.s.sol` asserts it post-deploy.
    ///
    ///      WHY A DEDICATED LIST AND NOT `ComplianceRegistry.isProtocolExempt`. That list looks
    ///      like the right one and is not: it is already overloaded as the sanctions-bypass set,
    ///      the USDfr emergency-pause carve-out, the `PointsModule` ineligibility set and the
    ///      `sUSDfr` fee-recipient validity set. Hanging burn authority off it means a
    ///      compliance-motivated de-listing silently disables the loss cascade, and a listing
    ///      made to keep a module transferable silently grants it burn authority. Separate
    ///      concerns get separate lists.
    ///
    ///      WHENNOTPAUSED IS DELIBERATE AND ASYMMETRIC WITH `burnLoss` (AUDIT FIX R16-L1). A
    ///      guardian pause must never leave supply EXPANSION available while user exits are
    ///      frozen. This mirrors the rule `USDfr._update` already enforces on the token itself
    ///      ("mints stay closed even to a listed module, because a pause must never permit
    ///      supply EXPANSION"), so `WaterfallEngine`'s interest leg was already unavailable
    ///      under a USDfr pause; this makes a controller pause say the same thing instead of
    ///      being a one-way valve that closes the user inflow and leaves the credit-layer
    ///      inflow open. R17 removed the LIVENESS cost of that choice without weakening it:
    ///      `mintableHeadroom()` reads zero while paused, so `WaterfallEngine._routeInterest`
    ///      clamps to zero and WITHHOLDS instead of reverting, and an ordinary borrower repayment
    ///      still settles under a controller pause. See `pause` and `mintableHeadroom`.
    ///
    ///      AUDIT FIX (R18): R17 APPLIED THAT ONLY TO HALF THE PAUSE SURFACE. `mintableHeadroom()`
    ///      read this contract's `paused()` and nothing else, while the SAME guardian address holds
    ///      `GUARDIAN_ROLE` on `USDfr` (`Deploy.s.sol` grants both), and `USDfr._update` refuses
    ///      every mint under a token pause — its `protocolLeg` carve-out requires
    ///      `from != address(0)`, so a mint can never qualify for it. One un-timelocked
    ///      `USDfr.pause()` therefore still reverted the yield leg, and because
    ///      `WaterfallEngine.distribute` is atomic it took the principal leg, the attestation
    ///      spend, the exposure release and the lifecycle transition down with it — the precise
    ///      harm the clamp exists to prevent, reached through the pause the clamp could not see.
    ///      `mintableHeadroom()` now reads BOTH pauses, so either one withholds instead of
    ///      reverting.
    ///
    ///      BOTH BASES ARE ASSERTED (AUDIT FIX R17) — DO NOT DELETE EITHER ASSERTION. This was the
    ///      one supply-EXPANDING path with no recognition-aware check of any kind. R16's comment
    ///      below said "while it is short it refuses outright"; that was true only of the RECORDED
    ///      deficit. Under an unreconciled custody shortfall — the R4-01 state, in which `mint`
    ///      and `redeem` both revert and `backingInvariantHolds()` publishes FALSE — the recorded
    ///      basis still reported the protocol whole, so the credit layer could mint fresh USDfr
    ///      against cash the reserve could already see was absent, and `recognizedDeficit()` rose
    ///      by the full amount minted while the predicate passed. That is R4-01's "sells a new
    ///      claim on a hole" reached through the credit door, and it is the L1 one-way-valve shape
    ///      on the recognition axis. `burnLoss` is deliberately NOT gated the same way: it only
    ///      ever LOWERS supply, and a recognition-aware assertion there would revert the C-01
    ///      cascade's own burns (see `_requireCustodiedReserve`). The asymmetry is now provable
    ///      rather than asserted — `test_R17_B02_burnLossStaysOpenUnderARecognisedShortfall` pins
    ///      it.
    function mintYield(address to, uint256 amount) external onlyRole(Roles.CREDIT_ROLE) nonReentrant whenNotPaused {
        if (amount == 0) revert Controller_ZeroAmount();
        ControllerStorage storage $ = _storage();
        if (!$.yieldSink[to]) revert Controller_NotYieldSink(to);
        (uint256 supplyBefore, uint256 backingBefore) = _supplyAndBacking($);
        uint256 recognizedBefore = $.reserves.recognizedBackingValue();
        // Backing must ALREADY reflect the attested receipts that justify this mint. The rule is
        // the same one every other path asserts: a yield mint may not widen the deficit — on
        // EITHER basis. While the protocol is whole that is exactly ADR-0012; while it is short on
        // the recorded books, or short on the recognised books because custody is missing, it
        // refuses outright, which is correct: incoming cash repairs the hole before it is paid out
        // as yield. `WaterfallEngine._routeInterest` reads `mintableHeadroom()` — which R17 made
        // recognition-aware for exactly this reason — and withholds the undistributable part
        // rather than reverting, so neither refusal costs the REPAYMENT path any liveness. AUDIT
        // FIX (R18): `WaterfallEngine.fund`'s origination-fee mint is now clamped THE SAME WAY and
        // therefore withholds rather than reverting. R17 left it unclamped on the stated ground
        // that originating a new facility out of an under-backed treasury is exactly what should
        // stop. That reasoning is sound about the FACILITY and wrong about the FEE: the fee mint is
        // coverage-neutral by construction (`recordFeeCapitalization` raises backing by exactly the
        // fee immediately before this raises supply by exactly the fee), so refusing it buys no
        // coverage and only stops the origination. Withholding the fee is the same posture
        // `_routeInterest` already documents for the interest leg: Forest Road does not collect out
        // of a shortfall, and the withheld amount stays in the treasury as backing.
        $.usdfr.mint(to, amount);
        _assertDeficitNotWorsened($, supplyBefore, backingBefore);
        _assertRecognizedDeficitNotWorsened($, supplyBefore, recognizedBefore);
        // AUDIT FIX (R17) — LOAD-BEARING, DO NOT DELETE. The retention that `mintableHeadroom()`
        // advertises has to be ENFORCED here as well as advertised, or it is advisory only: a
        // caller that does not size itself off the headroom would otherwise spend it. See
        // `seniorSubParShortfall`.
        //
        // WHAT STATE THIS REFUSES IN — R18 CORRECTED THIS PARAGRAPH, WHICH MIS-DESCRIBED IT. R17
        // wrote that this is "the same judgement the paragraph above makes about originating out of
        // an under-backed treasury". IT IS NOT. The paragraph above refuses when `supply > backing`.
        // This refuses while `recognizedBackingValue() - totalUSDfr() < seniorSubParShortfall()`,
        // which INCLUDES states the protocol publishes as fully backed and even OVER-backed:
        // `backingInvariantHolds()` TRUE, `backingDeficit()` and `recognizedDeficit()` both zero,
        // `mint` open and `redeem` paying par, and one wei of yield still refused. That is an
        // ABSOLUTE LEVEL check, deliberately, and it is the one level check left in a file whose
        // headline NatSpec is otherwise about replacing level checks with the non-worsening rule —
        // because the retention is a QUANTITY OWED, not a solvency predicate, and a non-worsening
        // form of it would let the very first yield mint after a haircut spend the haircut.
        //
        // WHAT UNBLOCKS IT, STATED SO AN OPERATOR CAN ACT ON IT: withheld interest from any
        // performing facility (`_routeInterest`'s clamp leaves it in the treasury as backing),
        // `ReserveManager.releasePrincipalImpairment` on a still-reversible mark, or governance
        // zeroing the class origination fee (`WaterfallEngine.setOriginationFee(classId, 0)`).
        // R18 made the first of those reachable again: before it, the retention refused
        // `WaterfallEngine.fund` outright, and `fund` is what creates the facilities whose interest
        // is the cure — finding M5's shape on the origination axis. `fund` now withholds its fee
        // instead of reverting, so the cure is no longer gated on the thing it cures.
        // ── AUDIT FIX (SWEEP-3 S3-F2) — ENFORCE **BOTH** ADVERTISED RETENTION TERMS ────────────
        // LOAD-BEARING. DO NOT DROP `exitPrepaidAbsorption()` BACK OUT OF THIS SUM.
        // `mintableHeadroom()` publishes `claimed = totalSupply + subParShortfall +
        // exitPrepaidAbsorption()`. R17 taught this function to ENFORCE the first term (see the
        // paragraph above: "the retention that `mintableHeadroom()` advertises has to be ENFORCED
        // here as well as advertised, or it is advisory only"). ADR-0034 Y-bis then added the
        // SECOND term to the VIEW and not to the ENFORCEMENT — two enumerations of one published
        // quantity that did not agree.
        // MEASURED: 4,739.336e18 of crystallised curator capital minted straight to the `sUSDfr`
        // vault while `mintableHeadroom()` read 0, i.e. verbatim the leak the term exists to close
        // ("the curator's crystallised loss becomes the senior's income"), reached through the
        // enforcement gap rather than through the view. The discriminating control proved the
        // SIBLING term refused the identical call one wei past the headroom.
        // SEVERITY IS LOW AND STATED AS SUCH: all three `mintYield` call sites in `src/` are in
        // `WaterfallEngine` and all three clamp to `mintableHeadroom()`, so nothing that ships can
        // reach it. It is defence-in-depth whose sibling is already enforced — an asymmetry an
        // upgrade or a second credit-layer module would silently inherit.
        // Falsified by `test_S3_F2_theExitPrepaymentRetentionIsAdvertisedButNotEnforcedByMintYield`;
        // the sibling term's own falsifier is
        // `test_S3_F2_control_theSubParRetentionIsEnforcedOnTheSameCall`.
        uint256 retention = $.subParShortfall + $.reserves.exitPrepaidAbsorption();
        if (retention != 0) {
            uint256 supplyNow = $.usdfr.totalSupply();
            uint256 backingNow = $.reserves.recognizedBackingValue();
            uint256 surplus = backingNow > supplyNow ? backingNow - supplyNow : 0;
            if (surplus < retention) revert Controller_SeniorRetentionBreached(retention, surplus);
        }
        emit YieldMinted(to, amount);
    }

    /// @inheritdoc IMintRedeemController
    /// @dev THE `from` CONSTRAINT (AUDIT FIX R16-M1/M2) — LOAD-BEARING, DO NOT DELETE. See
    ///      `mintYield` for the confiscation composition this half closes. It also answers a
    ///      second finding on its own: `USDfr.burn` takes NO ALLOWANCE, so an unconstrained
    ///      `from` made the capital-free cure for a shortfall a FORCED, NON-PRO-RATA seizure
    ///      from one named holder while an identically-placed holder paid nothing.
    ///
    ///      WHAT IS AND IS NOT PROMISED HERE (R17 CORRECTION). R16 wrote that "the only reachable
    ///      burns are the cascade's own". That described the DEPLOYED WIRING, not the reachable
    ///      set: `setLossSource` was a plain DEFAULT_ADMIN setter that accepted any non-zero
    ///      address including a bare EOA, so one routine-looking timelock transaction restored the
    ///      seizure this function is supposed to have closed — and the repo's own fixture listed
    ///      an EOA. R17 makes the setter refuse a CODELESS account, mirroring
    ///      `ReserveManager.setLossAbsorber`/`setLossController`, so the claim is now a property of
    ///      the CODE for every externally-owned account: no user wallet is seizable, allowance or
    ///      no allowance. It remains a property of the WIRING for contracts — governance can still
    ///      name a contract that holds USDfr — so the honest statement is: the only reachable burns
    ///      are from governance-named CONTRACT endpoints, which `Deploy.s.sol` sets to
    ///      `DefaultManager` (burning junior capital it has already received into ITSELF) and the
    ///      `sUSDfr` vault (pro-rata by construction, because it moves the vault's exchange rate
    ///      for every senior depositor at once), and which `Validate.s.sol` asserts post-deploy.
    ///
    ///      LEAST PRIVILEGE — `Roles.LOSS_BURNER_ROLE`, NOT `Roles.CREDIT_ROLE`. Verified by
    ///      grep at R16: every `burnLoss` call site in `src/` is in `DefaultManager`, passing
    ///      `address(this)` or `$.vault`. `WaterfallEngine` was granted `CREDIT_ROLE` on this
    ///      contract by `Deploy.s.sol` and therefore held a burn power IT NEVER USED. Splitting
    ///      the role removes that power from the engine entirely, so a compromise of the
    ///      repayment path cannot reach the burn path at all. `Validate.s.sol` asserts the
    ///      engine does NOT hold `LOSS_BURNER_ROLE`.
    ///
    ///      NO BACKING ASSERTION HERE, AND THAT IS THE FIX, NOT AN OMISSION (AUDIT FIX R16-M6).
    ///      This function previously asserted the backing invariant. Burning strictly LOWERS
    ///      `totalSupply` and cannot touch `backingValue` — the contract is `nonReentrant`, and
    ///      nothing on the burn path can raise supply or lower backing — so the assertion was
    ///      unfalsifiable: no reachable state could make it fire. That was proved empirically,
    ///      and it is exactly why the earlier `Controller_LossBurnDeficitMismatch` guard could be
    ///      DELETED IN FULL with the entire deterministic and invariant suite green. A guard no
    ///      test can red is not protection; it is a comment that an auditor will read as
    ///      protection. This round removes it and states the proof instead. The guards that
    ///      remain on this function — the role, the endpoint list, the zero-amount check — are
    ///      each proved by a deletion mutation.
    ///
    ///      NOT `whenNotPaused`, DELIBERATELY. Loss absorption is the one supply path that must
    ///      never be pausable: a guardian pause that stopped the cascade would leave a recognised
    ///      loss unallocated for the whole pause. `USDfr._update`'s emergency carve-out makes the
    ///      same choice for the same reason.
    function burnLoss(address from, uint256 amount) external onlyRole(Roles.LOSS_BURNER_ROLE) nonReentrant {
        if (amount == 0) revert Controller_ZeroAmount();
        ControllerStorage storage $ = _storage();
        if (!$.lossSource[from]) revert Controller_NotLossSource(from);
        $.usdfr.burn(from, amount);
        emit LossBurned(from, amount);
    }

    // ── Governance: credit-layer endpoints (AUDIT FIX R16-M1) ────────────

    /// @notice Authorizes (or revokes) an address as a destination for `mintYield`.
    /// @dev Timelocked governance only. Production wiring is the `sUSDfr` vault and the protocol
    ///      fee recipient; `Deploy.s.sol` sets both and `Validate.s.sol` asserts them. Zero is
    ///      refused so `mintYield(address(0), …)` can never be enabled, which is what lets that
    ///      function drop its own zero-address check instead of carrying an unreachable one.
    /// @param account The address that may receive yield mints.
    /// @param authorized True to authorize, false to revoke.
    function setYieldSink(address account, bool authorized) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert Controller_ZeroAddress();
        _storage().yieldSink[account] = authorized;
        emit YieldSinkUpdated(account, authorized);
    }

    /// @notice Authorizes (or revokes) an address as a source for `burnLoss`.
    /// @dev Timelocked governance only. Production wiring is `DefaultManager` (which burns the
    ///      junior capital it has already received into itself) and the `sUSDfr` vault (cascade
    ///      layer 3, pro-rata by construction). Zero is refused for the same reason as
    ///      `setYieldSink`.
    ///
    ///      THE CONTRACT CHECK (AUDIT FIX R17) — LOAD-BEARING, DO NOT DELETE. `burnLoss` burns
    ///      with NO ALLOWANCE and carries no backing assertion, and it is deliberately not
    ///      pausable, so neither the invariant nor a guardian can stop it. Listing an EOA here is
    ///      therefore a one-transaction, governance-reachable restoration of finding M2 — a
    ///      forced, non-pro-rata seizure of one named holder — dressed as routine wiring in a
    ///      timelock queue, which reads very differently from an upgrade. Every production loss
    ///      source is a protocol module; no user wallet is ever one. `ReserveManager`'s sibling
    ///      setters (`setLossAbsorber`, `setLossController`) already refuse a codeless address and
    ///      this is the same constraint. It is deliberately NOT applied to `setYieldSink`, which
    ///      legitimately names the Forest Road fee-recipient treasury and may be an EOA — that
    ///      half of the M1 composition credits an address, it does not seize one.
    ///
    ///      A CODE CHECK ALONE IS NOT "NO USER WALLET" AFTER PECTRA (AUDIT FIX R18) — DO NOT DELETE
    ///      THE DELEGATION-DESIGNATOR CHECK. R17 wrote that refusing a codeless account made the
    ///      claim "a property of the CODE for every externally-owned account: no user wallet is
    ///      seizable". THAT WAS FALSE ON THE DEPLOYMENT TARGET. EIP-7702 has been live on Ethereum
    ///      L1 (ADR-0009) since Pectra in May 2025: an ordinary key-controlled EOA that signs a
    ///      delegation carries a 23-byte code field of the form `0xef0100 ++ address`, so
    ///      `EXTCODESIZE` returns 23 and R17's check ADMITTED IT. Every MetaMask smart account,
    ///      Ambire wallet and gas-sponsored onboarding flow produces exactly that shape, so finding
    ///      M2 — a forced, allowance-free, non-pro-rata seizure of one named holder, unstoppable by
    ///      the guardian because `burnLoss` is deliberately not pausable and carries no backing
    ///      assertion — was still one routine-looking timelock transaction away for precisely the
    ///      class of wallet the guard names.
    ///
    ///      WHY THE FIRST BYTE IS SUFFICIENT AND A BOUND-BACK PROBE WAS NOT CHOSEN. EIP-3541 has
    ///      forbidden deploying any code beginning with `0xEF` since London, so no legitimately
    ///      deployed contract can collide with the designator prefix; refusing a leading `0xEF`
    ///      byte therefore excludes delegated EOAs without excluding any real module. The stronger
    ///      alternative — requiring the candidate to answer a bound-back probe — was NOT taken
    ///      because the two production loss sources (`DefaultManager` and the `sUSDfr` vault) do not
    ///      implement such a probe and adding one to them is a cross-module change; it is recorded
    ///      here as the follow-up if governance wants "cannot be wired by accident" rather than
    ///      "cannot be a wallet".
    ///
    ///      THE HONEST CLAIM IS THEREFORE: no CODELESS account and no DELEGATED EOA can be named a
    ///      loss source. It remains a property of the WIRING, not the code, that the named contract
    ///      is one whose burn is pro-rata.
    /// @param account The address `burnLoss` may burn from. Must have code, and must not be an
    ///        EIP-7702 delegated EOA.
    /// @param authorized True to authorize, false to revoke.
    function setLossSource(address account, bool authorized) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert Controller_ZeroAddress();
        // Only AUTHORIZATION is constrained. Revocation must never be blocked by the state of the
        // account being revoked — a governance kill-switch that a self-destructed endpoint could
        // disable would be a worse defect than the one this closes.
        if (authorized) {
            if (account.code.length == 0) revert Controller_LossSourceNotContract(account);
            if (_isDelegatedEOA(account)) revert Controller_LossSourceIsDelegatedEOA(account);
        }
        _storage().lossSource[account] = authorized;
        emit LossSourceUpdated(account, authorized);
    }

    /// @dev AUDIT FIX (R18) — LOAD-BEARING, DO NOT DELETE. True if `account` carries an EIP-7702
    ///      delegation designator, i.e. an ordinary EOA whose key signed a `SetCode` authorization.
    ///      The designator is EXACTLY 23 bytes and EXACTLY `0xef0100 ++ delegate`; EIP-3541 makes a
    ///      leading `0xEF` undeployable for real contract code, so this cannot false-positive on a
    ///      protocol module — `test_R18_C2_a23ByteContractThatIsNotADesignatorIsStillNameable`
    ///      pins that half. The refusal itself is falsified by
    ///      `test_R18_C2_a7702DelegatedWalletCannotBeNamedALossSource`, which MODELS the delegation
    ///      with `vm.etch` rather than signing one, so the property is pinned on the repo's default
    ///      `cancun` profile. What matters is the on-chain CODE FIELD, which is byte-identical
    ///      either way; that test carries its own control showing the same address REFUSED as a
    ///      plain EOA and ADMITTED by R17's rule once the designator is present.
    function _isDelegatedEOA(address account) private view returns (bool) {
        if (account.code.length != 23) return false;
        bytes3 head;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0)
            extcodecopy(account, ptr, 0, 3)
            head := mload(ptr)
        }
        return head == bytes3(0xef0100);
    }

    // ── Guardian ─────────────────────────────────────────────────────────

    /// @notice Pauses the user mint/redeem paths and the credit-layer YIELD MINT. Emergency use
    ///         only.
    /// @dev AUDIT FIX (R16-L1) corrected both the code and this NatSpec. A pause closes every
    ///      path that ISSUES USDfr (`mint`, `mintYield`) and the user exit (`redeem`); it
    ///      deliberately leaves `burnLoss` open, because loss absorption must never be pausable.
    ///      Pausing therefore cannot expand supply and cannot be used to freeze the cascade.
    ///      Note this is a SEPARATE pause from `USDfr.pause()`; the token's own pause closes the
    ///      user legs in both directions via `USDfr._update`'s protocol-leg carve-out.
    ///
    ///      WHAT A PAUSE DOES TO THE REPAYMENT PATH (AUDIT FIX R17 — STATED, BECAUSE R16 DID NOT).
    ///      `WaterfallEngine.distribute` is atomic and calls `mintYield` on every payment carrying
    ///      interest, so R16's `whenNotPaused` silently made a single un-timelocked GUARDIAN key
    ///      able to stop EVERY borrower repayment — principal leg, attestation spend, exposure
    ///      release and lifecycle transition included — and with it the ordinary interest payments
    ///      that are the protocol's only native cure for a deficit. R17 keeps the modifier (supply
    ///      expansion must stay closed) and removes the coupling: `mintableHeadroom()` reads ZERO
    ///      while paused, so `_routeInterest` clamps the distribution to zero, emits
    ///      `InterestWithheldForBackingRepair` and settles. The cash still lands in the reserve as
    ///      backing; only the YIELD is suspended.
    ///
    ///      R18 FINISHED THAT FIX ON BOTH AXES, BECAUSE R17 HAD DONE HALF OF EACH.
    ///        - THE OTHER PAUSE. R17's clamp read only THIS contract's `paused()`. The same
    ///          guardian address holds `GUARDIAN_ROLE` on `USDfr` too (`Deploy.s.sol` grants both),
    ///          and `USDfr._update` refuses every mint under a token pause, so one un-timelocked
    ///          `USDfr.pause()` still reverted every interest-bearing `distribute` — principal leg,
    ///          attestation spend, exposure release and lifecycle transition included. The sentence
    ///          above about the coupling being "removed" was therefore true of a controller pause
    ///          and false of a token pause. `mintableHeadroom()` now reads BOTH.
    ///        - THE OTHER MINT. R17 stated here that "`WaterfallEngine.fund`'s origination-fee mint
    ///          still reverts under a pause, which is intended". R18 CLAMPS that mint to
    ///          `mintableHeadroom()` as well, so under either pause `fund` now WITHHOLDS the fee and
    ///          the facility funds. That is deliberate and is not a weakening: stopping origination
    ///          during an emergency is the job of `WaterfallEngine`'s OWN `whenNotPaused` on `fund`,
    ///          which a guardian pausing the engine still gets in full. A CONTROLLER pause is a rule
    ///          about SUPPLY EXPANSION, and the fee is the part of `fund` that expands supply — so
    ///          withholding the fee is exactly what a controller pause should buy, and reverting the
    ///          whole origination was collateral damage of the same shape as the repayment coupling
    ///          this paragraph was written to remove.
    function pause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Unpauses mint/redeem and the yield mint.
    function unpause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _unpause();
    }

    // ── Views ────────────────────────────────────────────────────────────

    /// @inheritdoc IMintRedeemController
    function backingValue() public view returns (uint256) {
        return _storage().reserves.totalBackingValue();
    }

    /// @inheritdoc IMintRedeemController
    function totalUSDfr() public view returns (uint256) {
        return _storage().usdfr.totalSupply();
    }

    /// @inheritdoc IMintRedeemController
    /// @dev AUDIT NOTE (MA-2/R18 MERGE ADJUDICATION). This is a compatibility diagnostic for the
    ///      RECORDED ledger; it is NOT an operation-admission predicate. The earlier MA-2 fix used
    ///      this absolute level as `WaterfallEngine.distribute`'s closing gate. That correctly
    ///      separated custody observation from recorded accounting, but deadlocked principal
    ///      recoveries whenever any genuine impairment or residual deficit remained.
    ///
    ///      `WaterfallEngine.distribute` now snapshots `recognizedDeficit()` and rejects only an
    ///      increase, after `ReserveManager.recordPayment` has independently proved exact cash
    ///      receipt. This view remains useful for comparing recorded and recognised bases, but a
    ///      false result does not forbid a non-worsening cash-in operation and a true result is not
    ///      sufficient authorization for one.
    ///
    ///      WHY THE RECORDED BASIS IS CORRECT HERE, AND IS NOT A HOLE. `distribute` is a cash-IN
    ///      path: `ReserveManager.recordPayment` pulls the borrower's USDC in and verifies receipt
    ///      by balance delta, so a distribution cannot lower live custody and cannot widen the
    ///      recognised gap (`Fix_MA02-recognition-contamination.t.sol
    ///      ::test_MA2_interestIsWithheldToRepairRecognisedGapWithoutBlockingRepayment` and
    ///      `::test_MA2_absorbedCustodyDeficitDoesNotBlockNeutralPrincipalCollection` — CITATION
    ///      CORRECTED, SWEEP-1 VAC-F8: the superseded name
    ///      `test_MA2_theInterestMintCannotWidenTheRecognisedGap` is not in the tree). Gating it
    ///      on the RECOGNISED
    ///      basis halted every performing borrower's repayment, protocol-wide, for a custody hole
    ///      elsewhere — blocking the money that repairs the balance sheet. The custody window is
    ///      closed where cash LEAVES: `_requireCustodiedReserve` (user par),
    ///      `ReserveManager._requireIdleFullyCustodied` (both reserve out-doors, MA-1) and
    ///      `ReserveManager.custodyLossUnabsorbed()` (curator, R6-CF1).
    ///
    ///      DO NOT WIRE THIS INTO A USER path, dashboard, or absolute credit gate. It is
    ///      deliberately blind to the custody shortfall; using it as a solvency or exit-pricing
    ///      signal reinstates R4-01.
    ///      AUDIT FIX (SWEEP-3 S3-F1) — THE `_requireSettledState()` BELOW IS LOAD-BEARING, DO NOT
    ///      DELETE. `_requireSettledState`'s own NatSpec states the rule categorically: the RAW
    ///      delegating views are deliberately ungated because each is a single live read of one
    ///      module, and "what is false mid-transition is the COMPOSITION of a supply reading with a
    ///      backing reading ... so it is exactly the COMPOSITES that are gated". This is a
    ///      composite (`totalUSDfr() <= backingValue()`) and it was the one the R18 fix's
    ///      hand-written five-view enumeration missed — the sixth. MEASURED: it answered TRUE
    ///      ("supply is within backing") from inside the burn window on a book that was short both
    ///      before and after the transaction, while `backingInvariantHolds()` — the identical
    ///      composition one basis over — correctly REFUSED from the same frame.
    ///      Falsified by `test_S3_F1_creditServicingBackingHoldsAnswersFromInsideTheBurnWindow`.
    function creditServicingBackingHolds() external view returns (bool) {
        _requireSettledState();
        return totalUSDfr() <= backingValue();
    }

    /// @inheritdoc IMintRedeemController
    /// @dev AUDIT FIX (R4-01) — LOAD-BEARING, DO NOT "RESTORE" THIS TO `backingValue()`. This is
    ///      the protocol's public honesty surface: the dashboard reads it and the invariant
    ///      campaigns use it as the "is the protocol whole" predicate. Measured against the
    ///      RECORDED ledger it reported TRUE while `observeIdleUSDC()` was simultaneously
    ///      publishing a non-zero shortfall to the same caller in the same block — the contract
    ///      contradicting itself. It is now measured against `recognizedBackingValue()`.
    /// @dev AUDIT NOTE (R16-M4): `WaterfallEngine.distribute` no longer HARD-GATES on this. It
    ///      gates on `recognizedDeficit()` not increasing across the call, which is the same
    ///      recognition-aware measurement expressed as a non-worsening rule, so a repayment that
    ///      REPAIRS backing is no longer refused merely because the protocol was already short.
    /// @dev AUDIT FIX (R18): guarded by `_requireSettledState`. See
    ///      `Controller_ViewUnavailableMidTransition`.
    function backingInvariantHolds() external view returns (bool) {
        _requireSettledState();
        return totalUSDfr() <= recognizedBackingValue();
    }

    /// @inheritdoc IMintRedeemController
    function recognizedBackingValue() public view returns (uint256) {
        return _storage().reserves.recognizedBackingValue();
    }

    /// @inheritdoc IMintRedeemController
    /// @dev AUDIT FIX (R18): guarded by `_requireSettledState` — a composite of a supply reading
    ///      and a backing reading is false mid-burn. See `Controller_ViewUnavailableMidTransition`.
    function backingDeficit() public view returns (uint256) {
        _requireSettledState();
        uint256 supply = totalUSDfr();
        uint256 backing = backingValue();
        return supply > backing ? supply - backing : 0;
    }

    /// @inheritdoc IMintRedeemController
    /// @dev AUDIT FIX (R18): guarded by `_requireSettledState`, as `backingDeficit` is.
    function recognizedDeficit() external view returns (uint256) {
        _requireSettledState();
        uint256 supply = totalUSDfr();
        uint256 backing = recognizedBackingValue();
        return supply > backing ? supply - backing : 0;
    }

    /// @inheritdoc IMintRedeemController
    /// @dev THREE CORRECTIONS, ALL LOAD-BEARING (AUDIT FIX R17). This one view decides how much
    ///      interest `WaterfallEngine._routeInterest` may mint as yield, so every basis error in
    ///      it is paid out of the reserve and cannot be recovered.
    ///
    ///      (1) IT READS THE RECOGNISED BASIS, NOT THE RECORDED ONE. DO NOT "RESTORE" THIS TO
    ///      `backingValue()`. It is the headroom for MINTING, and minting against cash the reserve
    ///      can already see it does not hold is precisely what R4-01 forbids. Measured on the
    ///      recorded ledger, an unreconciled custody shortfall was invisible here: headroom
    ///      equalled the whole interest receipt, `_routeInterest`'s clamp withheld ZERO, the
    ///      protocol fee was taken on the GROSS out of an open hole (contradicting that function's
    ///      own "Forest Road does not collect a performance fee out of a shortfall"), and
    ///      `distribute`'s closing gate passed because the incoming cash and the new supply cancel
    ///      to the wei on both bases. Meanwhile `mint` and `redeem` were frozen and
    ///      `backingInvariantHolds()` published FALSE — the contract contradicting itself, which is
    ///      the R4-01 finding verbatim. In the healthy state `idleCustodyShortfall() == 0` makes
    ///      the two bases identical, so this is a STRICT TIGHTENING: headroom can only shrink,
    ///      withholding can only increase, and the healthy path is bit-for-bit unchanged.
    ///
    ///      (2) IT IS ZERO WHILE PAUSED. See `pause`. This is what lets `mintYield` keep
    ///      `whenNotPaused` — an absolute rule about supply expansion — without a guardian key
    ///      being able to stop every borrower repayment as a side effect.
    ///
    ///      (3) IT NETS OUT `seniorSubParShortfall()`. See that function. Without this, value
    ///      recovered from a released impairment mark becomes yield to the `sUSDfr` vault instead
    ///      of coverage for the holders who bore the mark.
    ///
    ///      (4) IT IS ZERO WHILE THE USDfr TOKEN IS PAUSED, NOT ONLY WHILE THIS CONTRACT IS
    ///      (AUDIT FIX R18) — DO NOT DELETE THE `$.usdfr.paused()` TERM. R17 shipped (2) reading
    ///      only `paused()`, this contract's own Pausable. The SAME guardian address holds
    ///      `GUARDIAN_ROLE` on `USDfr` (`Deploy.s.sol` grants both), and `USDfr._update` refuses
    ///      every mint while the token is paused — its protocol-leg carve-out requires
    ///      `from != address(0)`, which a mint can never satisfy. So one un-timelocked
    ///      `USDfr.pause()` still made `mintYield` REVERT, and `WaterfallEngine.distribute` is
    ///      atomic, so it took every borrower repayment down with it: principal leg, attestation
    ///      spend, exposure release, lifecycle transition. The clamp built to prevent exactly that
    ///      harm could not see the pause that caused it. Both pauses now read zero here, so either
    ///      one WITHHOLDS instead of reverting.
    ///
    ///      The four compose as a floor: whichever binds hardest wins, and each only ever
    ///      REDUCES what may be minted, so none of them can create an over-issuance.
    /// @dev AUDIT FIX (R18): guarded by `_requireSettledState`. See
    ///      `Controller_ViewUnavailableMidTransition` — mid-burn this view read the ENTIRE realised
    ///      loss of a cascade as distributable yield capacity, and it is the exact quantity
    ///      `WaterfallEngine._routeInterest` sizes real yield off.
    function mintableHeadroom() external view returns (uint256) {
        _requireSettledState();
        ControllerStorage storage $ = _storage();
        if (paused() || $.usdfr.paused()) return 0;
        uint256 backing = $.reserves.recognizedBackingValue();
        // AUDIT FIX (ADR-0034 Y-bis) — `exitPrepaidAbsorption()` IS RETAINED ALONGSIDE
        // `subParShortfall`, AND DELETING IT REOPENS THE LEAK ON THE JUNIOR SIDE. The junior draw
        // burns junior USDfr against a mark (`recognizePrincipalImpairment`) that is CONSERVATIVE
        // and REVERSIBLE. If the mark is later released, backing rises while supply is already
        // lower by the drawn amount, so the book carries a surplus of exactly the standing
        // prepayment. Untreated, this view reads that surplus as distributable and
        // `WaterfallEngine._routeInterest` mints it to the `sUSDfr` vault as yield — the curator's
        // crystallised loss becomes the senior's income. That is the identical leak R17's
        // `seniorSubParShortfall` closed for the EXITER's haircut, aimed at the junior tranche
        // instead. Retained, not recycled.
        //
        // IT IS A STOCK NETTED OFF A LEVEL, exactly like `subParShortfall` beside it, and NOT a
        // cumulative stock differenced against a per-transaction flow — the shape that broke an
        // adjacent fix on this same view.
        //
        // WHAT IT DOES NOT DO, SAID PLAINLY: there is no restitution path. A fully reversed mark
        // leaves the curator permanently down and the value parked in this retention. Minting it
        // back needs `CuratorModule` as a yield sink and a reversal of the per-pool share
        // arithmetic. OUTSTANDING, and named as such.
        //
        // SWEEP-2 S2-F3 — OPEN, AND DELIBERATELY NOT FIXED IN THIS ROUND. STOPPED FOR A FOREST ROAD
        // DECISION. The ledger has exactly TWO consumers: `realizeLoss`'s layer-0 credit
        // (`ReserveManager.consumeExitPrepayment`, bounded by the facility's RECOGNISED MARK) and
        // this netting. On an UNMARKED deficit — an idle write-down, a custody-reconciliation
        // residual — the first has no route to fire (`totalPrincipalImpairment() == 0`, so the
        // layer-0 credit is 0 and ReserveManager's live custody cascade deliberately does not
        // consume the ledger, correctly avoiding a double charge), so the retention here stands
        // forever and the book closes permanently over-backed by exactly the junior capital the
        // exit burned. MEASURED: a
        // 9,900.99e18 draw, a par settlement, `seniorSubParShortfall() == 0`, and
        // `mintableHeadroom() == 0` for good.
        //
        // WHY IT IS NOT REMEDIATED HERE. Every available cure is an ECONOMIC choice under
        // CLAUDE.md §0.7 and prime directive 5, not a safety fix:
        //   (a) retiring the ledger releases the surplus into `_routeInterest` — i.e. junior
        //       crystallised capital becomes SENIOR YIELD, which is the exact leak this term was
        //       added to close, merely on a different trigger;
        //   (b) refunding the curator needs `CuratorModule` as a yield sink plus a reversal of the
        //       per-pool share arithmetic — a new mechanism, not an audit-round edit;
        //   (c) leaving it is what ships today: the junior tranche's payment is retained as
        //       over-collateralisation for the remaining USDfr holders, and the withholding is on
        //       the SENIOR YIELD LEG, not a second charge on the junior tranche.
        // Bounding it by `totalPrincipalImpairment()` was evaluated and REJECTED: it releases the
        // surplus at the exact moment a mark is RELEASED, which is when the leak (a) actually
        // fires. Forest Road must choose between (a), (b) and (c); do not choose it in code.
        uint256 claimed = $.usdfr.totalSupply() + $.subParShortfall + $.reserves.exitPrepaidAbsorption();
        return backing > claimed ? backing - claimed : 0;
    }

    /// @inheritdoc IMintRedeemController
    /// @dev THE CRYSTALLISED SENIOR HAIRCUT (AUDIT FIX R17) — DO NOT DELETE, AND DO NOT ADD A
    ///      SETTER THAT LOWERS IT.
    ///
    ///      THE PROBLEM IT ANSWERS. `ReserveManager.recognizePrincipalImpairment` is a governance
    ///      VALUATION act, and a REVERSIBLE one: `releasePrincipalImpairment` exists precisely
    ///      because, as its own NatSpec says, an irreversible mark "would be a one-way ratchet …
    ///      and governance would rationally refuse to mark at all". R16 made that reversible mark
    ///      PRICE-EFFECTIVE for exits the instant it lands. A holder who redeemed during the
    ///      window crystallised a PERMANENT loss against a TEMPORARY number; when the mark was
    ///      later released, the recovered value reappeared as headroom and `_routeInterest` minted
    ///      it to the `sUSDfr` vault. The senior exiter's haircut became someone else's yield —
    ///      and it did so before the §1.3 cascade's layers 1 and 2 (curator first-loss, `sGROVE`
    ///      backstop) had absorbed anything, which is the ordering `DefaultManager.realizeLoss`
    ///      refuses to invert (it reverts with `DefaultManager_LossExceedsAbsorptionCapacity`
    ///      rather than let a loss reach unstaked USDfr holders).
    ///
    ///      WHAT THIS DOES. Every sub-par settlement adds `usdfrIn - usdcOut * SCALE` here, and
    ///      `mintableHeadroom()` subtracts the running total. Recovered value therefore stays in
    ///      the pool as COVERAGE for the holders who are still in it, rather than being minted out
    ///      as yield. It is monotonic and has no setter on purpose: a governance lever that could
    ///      lower it would restore the leak in one transaction.
    ///
    ///      WHAT THIS DOES NOT DO, SAID PLAINLY. It does not REPAY the exiter — there is no
    ///      on-chain record of who exited at what price beyond the `SubParRedemption` and
    ///      `SeniorShortfallCrystallised` events, and building a claims register for departed
    ///      holders is a materially larger design than an audit round should introduce
    ///      unilaterally. It converts "the haircut is captured by the yield layer" into "the
    ///      haircut is retained by the remaining USDfr holders as over-collateralisation".
    ///
    ///      WHAT IT COSTS — R18 REWROTE THIS, BECAUSE R17'S VERSION UNDERSTATED IT AND ITS STATED
    ///      CURE WAS CIRCULAR. R17 said "the cost is bounded and one-off: interest is withheld
    ///      until backing exceeds supply plus this total, after which yield flows normally
    ///      forever". Three things were wrong with that sentence and an auditor must have the
    ///      correct ones:
    ///        1. IT IS NOT ONLY INTEREST. `mintYield` enforces the retention as an ABSOLUTE level
    ///           check, so ORIGINATION FEES are refused by it too — and under R17 that refused
    ///           `WaterfallEngine.fund` OUTRIGHT, because `fund`'s fee mint was the one `mintYield`
    ///           caller not sized off `mintableHeadroom()`.
    ///        2. THE CURE WAS CIRCULAR, WHICH IS FINDING M5's SHAPE. Withheld interest requires a
    ///           performing facility; a new facility requires `fund`; `fund` was refused. After a
    ///           terminal workout — the residual absorbed by the cascade, `deployedPrincipal() == 0`,
    ///           nothing left to release — nothing on chain could pay interest, so "after which
    ///           yield flows normally forever" had no "after which". R18 CLOSES THAT: `fund` now
    ///           clamps its fee to `mintableHeadroom()` and WITHHOLDS instead of reverting, so
    ///           origination stays open and its interest is once again a reachable cure. The
    ///           retention itself is unchanged.
    ///        3. THE QUANTITY IS THE WHOLE LOSS, NOT THE HAIRCUT ALONE. Yield resumes only once
    ///           `recognizedBackingValue() - totalUSDfr() >= seniorSubParShortfall()`, i.e. the
    ///           protocol must earn back the standing deficit AND this retention out of interest.
    ///      The remaining cures, stated so an operator can act on them: withheld interest from any
    ///      performing facility, `ReserveManager.releasePrincipalImpairment` on a still-REVERSIBLE
    ///      mark, and `WaterfallEngine.setOriginationFee(classId, 0)` (DEFAULT_ADMIN, timelocked)
    ///      which removes the fee mint from `fund` altogether.
    ///
    ///      THE KNOWN OVER-CHARGE, DISCLOSED RATHER THAN FIXED. The justification above is that
    ///      value RECOVERED when a REVERSIBLE mark is released must stay with the holders who bore
    ///      it. This code cannot distinguish a mark that will be released from one that becomes a
    ///      REALISED loss, and accrues in both cases. On the realised path there is nothing left to
    ///      recover — curator first-loss, the sGROVE backstop and the senior vault have already
    ///      paid, and the exiter already bore their own haircut — so the retention keeps standing
    ///      against a recovery that can never arrive. The alternative named at the end of this
    ///      paragraph in R17 (a REALISED-LOSS WATERMARK: hold the crystallised amount pending and
    ///      retire it when the cascade allocates the corresponding loss) is the right answer to
    ///      that and is NOT implemented here: retiring retention on a `burnLoss` requires the
    ///      controller to know which burns correspond to which crystallisation, which is a
    ///      `DefaultManager` coordination change, and it would make this quantity non-monotonic —
    ///      the property the whole mitigation rests on. R18's clamp removes the ORIGINATION FREEZE
    ///      that made the over-charge severe; the over-charge itself is OUTSTANDING and is a Forest
    ///      Road decision on the brief's Part 4 locked economics (CLAUDE.md §0.5/§0.7), alongside
    ///      ADR-0034 (see `_redeem`), which decides the adjacent question of the exit PRICE.
    function seniorSubParShortfall() external view returns (uint256) {
        return _storage().subParShortfall;
    }

    /// @inheritdoc IMintRedeemController
    /// @dev THE DUST FLOOR (finding R16-L3), STATED HONESTLY RATHER THAN "FIXED". USDfr worth
    ///      less than one whole USDC unit cannot be redeemed, because USDC has six decimals and
    ///      there is no such thing as a fraction of a unit to pay out. That is a property of the
    ///      SETTLEMENT ASSET, not a lock: the residue is at most 1e-6 USD, USDfr is freely
    ///      transferable so it aggregates, and the alternatives are worse — rounding UP pays out
    ///      cash that is not backed, and a dust ledger adds storage and a claim mechanism for
    ///      sub-cent amounts. What was genuinely wrong was that the threshold was invisible and
    ///      is no longer a constant: under sub-par pricing a holder needs
    ///      `ceil(1e12 * supply / backing)`, rounded up to the whole-USDC grid, before anything
    ///      is payable. This view publishes the exact quote so the frontend can state the floor
    ///      rather than discovering it by simulating a revert. It does NOT promise that a
    ///      redemption is available — see the R18 paragraph below.
    ///
    /// @dev IT PRICES ON THE RECOGNISED BASIS (AUDIT FIX R17) — DO NOT "ALIGN" IT WITH `redeem` BY
    ///      MOVING IT BACK TO `totalBackingValue()`. R16 wrote that this view "shares `_quoteRedeem`
    ///      with `redeem`, so the two can never disagree". They share the ARITHMETIC; they do not
    ///      share the PRECONDITIONS, and that is the whole point. `redeem` sits behind
    ///      `_requireCustodiedReserve`, which guarantees the recorded and recognised bases are
    ///      equal by the time it quotes. This view sits behind nothing — it is permissionless and
    ///      needs no KYC — so on the recorded basis it published a PAR quote in exactly the state
    ///      where the recorded ledger is known to be false, for a call that would then revert
    ///      `Controller_ReserveCustodyShortfall`. That is R4-01 restated on a newer surface: the
    ///      contract contradicting itself in one block. On the recognised basis it now answers the
    ///      honest number, and wherever `redeem` is actually REACHABLE the two bases are identical
    ///      so the quote is still exact.
    ///
    ///      IT STILL IS NOT A PROMISE ACROSS TRANSACTIONS. The quote is valid for the state it was
    ///      read in and nothing more; `recordPrincipalWritedown` and friends can move it in the
    ///      next block, or the same one. The binding surface is `redeem`'s `minUsdcOut`, which is
    ///      what this number should be passed back into.
    ///
    ///      AN EMPTY PROTOCOL QUOTES NOTHING. With `supply == 0` the `backing >= supply` branch is
    ///      `0 >= 0`, so R16 quoted PAR for supply that does not exist. `_quoteRedeem` now returns
    ///      `(0, 0)`, which is also what makes its division provably safe.
    ///
    /// @dev A CLOSED REDEMPTION QUOTES NOTHING EITHER (AUDIT FIX R18) — DO NOT DELETE THE CUSTODY
    ///      GATE. R17 changed WHICH number this published over a custody hole; it did not change
    ///      WHETHER one was published. In the standing R4-01 state — `idleCustodyShortfall() != 0`,
    ///      `backingInvariantHolds()` already FALSE — this view returned a full, honest-looking,
    ///      settleable quote for a call that `_requireCustodiedReserve` then refuses with
    ///      `Controller_ReserveCustodyShortfall`. Passing that very number back in as `minUsdcOut`,
    ///      as both NatSpecs direct, reverted. The window was wider than the sub-par case: wherever
    ///      recognised backing still exceeded supply it quoted full PAR for a call that cannot
    ///      execute. It now answers `(0, 0)`, which is already this view's documented way of saying
    ///      "nothing is payable", and the two surfaces agree in every state.
    ///
    ///      CONSEQUENCE FOR THE BASIS READ BELOW, STATED HONESTLY PER FINDING M6. With this gate in
    ///      place `recognizedBackingValue() == totalBackingValue()` at that line by construction —
    ///      the custody shortfall is the ONLY thing that separates the two bases — so the choice of
    ///      basis here is NO LONGER A FALSIFIABLE GUARD. It is kept, not deleted, because it is the
    ///      safe one if the gate is ever relaxed, and because it makes the intent legible. Read it
    ///      as belt-and-braces, exactly as `mint`'s `forceApprove(…, 0)` is read, and do not write a
    ///      comment claiming a mutation reds it.
    function previewRedeem(uint256 usdfrAmount) external view returns (uint256 usdcOut, uint256 usdfrIn) {
        _requireSettledState();
        ControllerStorage storage $ = _storage();
        // ── AUDIT FIX (SWEEP-3 S3-F3) — READ THE PAUSES, EXACTLY AS `mintableHeadroom()` DOES ───
        // LOAD-BEARING, DO NOT DELETE. R18 finding (G) is "previewRedeem QUOTED A SETTLEABLE PRICE
        // FOR A CALL THAT CANNOT EXECUTE", and its fix claimed "the two surfaces agree in every
        // state". They did not agree under EITHER pause — the axis R18 finding (B) spent its whole
        // effort teaching `mintableHeadroom()` to read. MEASURED: a full 400e6 USDC quote published
        // while `redeem` reverts `EnforcedPause`, and again while the USDfr token pause closes the
        // burn in `_update`. Direction is safe (the quote is too HIGH, so passing it back as
        // `minUsdcOut` can only revert on a pause that would have reverted anyway), which is why
        // this is LOW — it is a self-contradiction-in-one-block of the class R4-01 established, not
        // a value defect. Falsified by
        // `test_S3_F3_previewRedeemQuotesAFullPriceWhileRedemptionIsPaused` and
        // `test_S3_F3b_previewRedeemQuotesAFullPriceWhileTheTokenPauseClosesTheBurn`.
        if (paused() || $.usdfr.paused()) return (0, 0);
        if ($.reserves.idleCustodyShortfall() != 0) return (0, 0);
        // IT QUOTES THE UNDRAWN FLOOR, AND THAT IS A NAMED, DELIBERATE GAP (ADR-0034 Y-bis).
        // `drawn = 0` here, so below par this view publishes the GROSS-marked price while `redeem`
        // settles at the junior-drawn price — which is equal or BETTER, never worse. The direction
        // is what makes it safe: passing this number back as `minUsdcOut`, exactly as this view's
        // NatSpec directs, can never revert on slippage.
        //
        // WHY IT IS NOT SIMULATED. Simulating the draw needs live junior capacity — the five
        // curator pools plus the shared sGROVE reserve. Neither is reachable from this contract
        // (it holds no reference to `CuratorModule` or `SGrove`), and
        // publishing it from `DefaultManager` measured 218 bytes in a contract that has 183 left
        // after this change. ADR-0034 Y names `previewRedeem` alongside `redeem`, so this is
        // recorded as OUTSTANDING rather than closed: the dashboard understates the exit price
        // whenever junior capital stands behind it.
        return _quoteRedeem(usdfrAmount, $.usdfr.totalSupply(), $.reserves.recognizedBackingValue(), 0);
    }

    /// @inheritdoc IMintRedeemController
    function isYieldSink(address account) external view returns (bool) {
        return _storage().yieldSink[account];
    }

    /// @inheritdoc IMintRedeemController
    function isLossSource(address account) external view returns (bool) {
        return _storage().lossSource[account];
    }

    /// @notice Wired module addresses (for post-deploy validation and the dashboard).
    function modules() external view returns (address usdfr, address compliance, address reserves) {
        ControllerStorage storage $ = _storage();
        return (address($.usdfr), address($.compliance), address($.reserves));
    }

    // ── Internals ────────────────────────────────────────────────────────

    function _requireKYC(ControllerStorage storage $, address account) private view {
        if (!$.compliance.isAllowed(account)) revert Controller_NotKYCAllowed(account);
    }

    /// @dev AUDIT FIX (R18) — LOAD-BEARING, DO NOT DELETE FROM ANY VIEW THAT CARRIES IT. The
    ///      READ-ONLY-REENTRANCY GUARD on the composite views.
    ///
    ///      THE WINDOW IS THE PROTOCOL'S OWN DESIGNED CALLBACK, NOT AN EXOTIC ONE. `_redeem` burns
    ///      (supply down) BEFORE `releaseUSDC` lowers backing, and `DefaultManager.realizeLoss`
    ///      burns both junior layers and the senior vault BEFORE `recordPrincipalWritedown` lowers
    ///      backing. `USDfr._update` fires the participation-points hook inside every one of those
    ///      burns. The R18 adversarial round measured an observer holding control there reading
    ///      `mintableHeadroom()` as the ENTIRE realised loss of a cascade — 400,000e18 of phantom
    ///      yield capacity, where the view reads 0 on both sides of the transaction —
    ///      `backingInvariantHolds()` as TRUE on a 20%-short book, and `previewRedeem` as PAR on
    ///      the same book. `mintableHeadroom()` is the exact quantity
    ///      `WaterfallEngine._routeInterest` sizes real yield off.
    ///
    ///      WHY REVERT RATHER THAN RETURN A NUMBER. R4-01's standard, which this file invokes
    ///      repeatedly, is that the contract must not contradict itself inside one block;
    ///      `backingInvariantHolds()`'s own NatSpec cites exactly that. Answering with a number
    ///      known to be false is the contradiction. A named revert is the honest answer and is
    ///      fail-CLOSED for an integrator: a `try/catch` reader sees "unavailable", never a lie.
    ///      The WRITE half was already closed — every entry point is `nonReentrant`, pinned by
    ///      `test_R17_G04_mintIsReentrancyLocked` and siblings — so this closes the read half with
    ///      the same slot and no new state.
    ///
    ///      THE RAW DELEGATING VIEWS (`backingValue`, `recognizedBackingValue`, `totalUSDfr`) ARE
    ///      DELIBERATELY NOT GATED. Each is a single live read of one module and is TRUE whenever it
    ///      is read — mid-transition included. What is false mid-transition is the COMPOSITION of a
    ///      supply reading with a backing reading taken at different points of the same state
    ///      change, so it is exactly the composites that are gated.
    function _requireSettledState() private view {
        if (_reentrancyGuardEntered()) revert Controller_ViewUnavailableMidTransition();
    }

    /// @dev AUDIT FIX (R4-01) — LOAD-BEARING GUARD, DO NOT DELETE. The USER paths are closed
    ///      while the reserve holds less USDC than its idle ledger claims. `observeIdleUSDC()`
    ///      published that gap to anyone for free; nothing consumed it, so `redeem` kept paying
    ///      100 cents on the dollar to whoever arrived first until the live balance was gone.
    ///
    ///      SUB-PAR REDEMPTION DOES NOT REPLACE THIS AND MUST NOT BE ARGUED TO. Sub-par pricing
    ///      protects holders when the protocol KNOWS what it is worth. An unreconciled custody
    ///      gap is precisely the state in which it does NOT: `idleUSDCUnits` is a claim that has
    ///      been falsified by the live balance, so any quote derived from it would over-pay by
    ///      exactly the amount of the hole. Recognition (this) must come first; then
    ///      `reconcileIdleUSDC` writes the ledger down to the truth; THEN sub-par pricing is
    ///      meaningful and redemption reopens by itself.
    ///
    ///      WHY THIS IS NOT FOLDED INTO THE DEFICIT RULE, and must not be. The C-01 cascade's own
    ///      burn runs while this shortfall is standing: `ReserveManager.reconcileIdleUSDC`
    ///      allocates the loss and burns supply BEFORE it lowers `idleUSDCUnits`. A
    ///      recognition-aware assertion on the credit-layer paths would revert those burns and
    ///      brick custody-loss absorption entirely — the opposite of the intent. Recognition
    ///      closes the user window; absorption stays authenticated and unobstructed.
    ///
    ///      NOT A LATCH, and no role is needed to clear it: restoring custody, or the
    ///      authenticated `reconcileIdleUSDC` writing the ledger down to the live balance,
    ///      reopens mint and redeem in the same block with no governance action
    ///      (`test_R4_01_restoringCustodyReopensParBusinessWithNoGovernanceAction`).
    function _requireCustodiedReserve(ControllerStorage storage $) private view {
        uint256 shortfall = $.reserves.idleCustodyShortfall();
        if (shortfall != 0) {
            revert Controller_ReserveCustodyShortfall(shortfall, $.reserves.recognizedBackingValue());
        }
    }

    /// @dev The one solvency measurement, read on the RECORDED basis. Deliberately NOT
    ///      recognition-aware — see `_requireCustodiedReserve` for why a recognition-aware
    ///      measurement on the supply-affecting paths would brick the C-01 absorption cascade,
    ///      and `ReserveManager`'s MERGE NOTE for why `totalBackingValue()` must stay recorded.
    function _supplyAndBacking(ControllerStorage storage $) private view returns (uint256 supply, uint256 backing) {
        supply = $.usdfr.totalSupply();
        backing = $.reserves.totalBackingValue();
    }

    /// @dev THE SINGLE SOLVENCY RULE (ADR-0012 as amended by audit round R16 — findings
    ///      M3/M4/M5) — LOAD-BEARING, DO NOT DELETE FROM ANY CALL SITE. An operation may not
    ///      INCREASE `deficit = max(0, totalSupply - backingValue)`.
    ///
    ///      WHICH BASIS THIS MEASURES (R17 CORRECTION — R16 STATED THE RULE IN BASIS-FREE TERMS AN
    ///      AUDITOR WOULD READ AS COVERING BOTH). It measures the RECORDED deficit only. That is
    ///      correct for `mint` and `redeem`, which sit behind `_requireCustodiedReserve` and so
    ///      cannot execute at all while the two bases differ, and it is deliberate for `burnLoss`,
    ///      which carries no assertion because it can only lower supply. It was NOT sufficient for
    ///      `mintYield`, the one supply-EXPANDING path with no custody precondition, which is why
    ///      that path additionally asserts `_assertRecognizedDeficitNotWorsened`.
    ///
    ///      WHILE THE PROTOCOL IS WHOLE THIS IS ADR-0012, UNCHANGED. `deficitBefore == 0` forces
    ///      `deficitAfter == 0`, i.e. `totalSupply <= backingValue`, and it still reverts with
    ///      `Controller_BackingInvariantViolated(supply, backing)` — the same error, the same
    ///      arguments, the same meaning. Nothing about the healthy path is relaxed.
    ///
    ///      WHILE THE PROTOCOL IS SHORT IT IS THE RULE THE ABSOLUTE FORM COULD NOT EXPRESS. The
    ///      absolute form said only "supply exceeds backing", which is already true and stays
    ///      true, so it reverted every operation including the ones that repair the hole. The
    ///      distinct `Controller_DeficitWorsened` error exists so that a caller in this state is
    ///      told the operation was refused for WIDENING the gap, not that a gap exists — an
    ///      auditor or an integrator reading `Controller_BackingInvariantViolated` in a
    ///      knowingly sub-par protocol would reasonably conclude the check was firing for the
    ///      standing condition.
    ///
    ///      IT IS MEASURED, NOT ASSUMED — BUT IT IS A NON-WORSENING RULE, AND R18 CORRECTED WHAT
    ///      R17 CLAIMED THAT BUYS. Both readings do come from live external calls to the token and
    ///      the reserve, taken before and after the operation. R17 concluded from that: "a module
    ///      that reports one thing and does another is caught here even when the operation's own
    ///      arithmetic looks correct." THAT SENTENCE WAS FALSE WHENEVER THE PROTOCOL CARRIED
    ///      SURPLUS. The rule is non-worsening, so a discrepancy is caught only for the part
    ///      EXCEEDING `backingValue() - totalUSDfr()`; the standing surplus silently pays for the
    ///      rest. R17 made that worse rather than better, because `mintableHeadroom()` now nets out
    ///      `seniorSubParShortfall()` and `_routeInterest` therefore mints down to
    ///      `surplus == retention` rather than to zero — so after any crystallised haircut the
    ///      protocol is DESIGNED to sit permanently on a masking budget of exactly that size.
    ///      The correct statement is: this rule catches only the part of any discrepancy that
    ///      exceeds the standing surplus, and it is a BACKSTOP, not the primary measurement. The
    ///      primary measurements are the LEVEL-FREE DELTA CHECKS on the operations themselves —
    ///      `Controller_DepositNotCustodied` (custody), `Controller_DepositNotRecognized`
    ///      (recognition, added in R18 for exactly this reason) and
    ///      `Controller_RedemptionNotSettled` (outflow) — each of which is an EQUALITY on a measured
    ///      delta that no surplus can absorb.
    function _assertDeficitNotWorsened(ControllerStorage storage $, uint256 supplyBefore, uint256 backingBefore)
        private
        view
    {
        (uint256 supplyAfter, uint256 backingAfter) = _supplyAndBacking($);
        uint256 deficitAfter = supplyAfter > backingAfter ? supplyAfter - backingAfter : 0;
        uint256 deficitBefore = supplyBefore > backingBefore ? supplyBefore - backingBefore : 0;
        if (deficitAfter <= deficitBefore) return;
        if (deficitBefore == 0) revert Controller_BackingInvariantViolated(supplyAfter, backingAfter);
        revert Controller_DeficitWorsened(deficitBefore, deficitAfter);
    }

    /// @dev THE SAME RULE ON THE RECOGNITION-AWARE BASIS (AUDIT FIX R17) — LOAD-BEARING ON
    ///      `mintYield`, DO NOT DELETE. `recognizedBackingValue()` is backing net of the custody
    ///      shortfall the reserve can observe right now; it is the basis `backingInvariantHolds()`
    ///      and `WaterfallEngine.distribute` already use, and the basis on which the protocol
    ///      publishes whether it is whole. Without this, `mintYield` could raise the PUBLISHED
    ///      deficit by the full amount minted and still pass, because the recorded ledger the
    ///      missing cash had falsified reported the protocol whole. Applied ONLY to `mintYield`:
    ///      `mint` and `redeem` are already refused outright in that state by
    ///      `_requireCustodiedReserve`, and applying it to `burnLoss` would revert the C-01
    ///      cascade's own absorption burns, which is the opposite of the intent.
    function _assertRecognizedDeficitNotWorsened(
        ControllerStorage storage $,
        uint256 supplyBefore,
        uint256 recognizedBefore
    ) private view {
        uint256 supplyAfter = $.usdfr.totalSupply();
        uint256 recognizedAfter = $.reserves.recognizedBackingValue();
        uint256 deficitAfter = supplyAfter > recognizedAfter ? supplyAfter - recognizedAfter : 0;
        uint256 deficitBefore = supplyBefore > recognizedBefore ? supplyBefore - recognizedBefore : 0;
        if (deficitAfter > deficitBefore) revert Controller_RecognizedDeficitWorsened(deficitBefore, deficitAfter);
    }

    /// @dev THE REDEMPTION QUOTE (AUDIT FIX R16-M3) — shared by `redeem` and `previewRedeem` so
    ///      the quoted price and the settled price cannot diverge.
    ///
    ///      ADR-0034 Y-bis IS IMPLEMENTED, AND `drawn` IS WHAT IMPLEMENTS IT (THIS PARAGRAPH
    ///      REPLACES R18's "KNOWN OPEN FINDING" ENTRY). R18 recorded that this priced off the GROSS
    ///      book mark while the `sUSDfr` path priced off `DefaultManager.pendingSeniorImpairment()`
    ///      — two bases in one tree, the direct one un-netted, so a senior could be haircut here
    ///      while junior capital contracted to absorb first sat intact. The cure is NOT a change of
    ///      basis: the junior-netted price PROMISES more than gross-marked backing, and the
    ///      difference sits in the curator pool and the backstop, not in the reserve's USDC. So
    ///      `_drawJuniorForExit` MOVES that capital in the same transaction and hands the result in
    ///      here as `drawn`. See `_exitDrawTarget` for the sizing and why `pendingSeniorImpairment()`
    ///      is deliberately NOT consulted.
    ///
    ///      WHAT IS STILL OUTSTANDING, NAMED SO NO READER TAKES THIS AS COMPLETE. (1)
    ///      `previewRedeem` passes `drawn = 0` and therefore publishes the UNDRAWN floor — see its
    ///      NatSpec. (2) Layer 1 of the draw is CLASS-LESS pro-rata, not per-class as Y-bis's
    ///      wording says; the deficit a redemption prices against is not class-attributed on-chain.
    ///      (3) The draw stops at layer 2, so once junior capital is exhausted the exiting holder
    ///      takes a haircut while the `sUSDfr` vault sits intact — which inverts decision X's
    ///      layers 3 and 4. All three need Forest Road, and all three are recorded in
    ///      `DefaultManager.drawForSeniorExit`.
    ///
    ///      STEP 1, THE WHOLE-UNIT GRID. `usdfrIn` is `usdfrAmount` truncated to a whole USDC
    ///      unit. Sub-unit dust is never burned, so it stays in the holder's wallet rather than
    ///      being silently taken — the pre-existing behaviour, preserved.
    ///
    ///      STEP 2, THE PRICE. At or above par the holder is paid par. Below par they are paid
    ///      `usdfrIn * backing / supply`, FLOORED. Flooring twice (once here, once by the
    ///      division to whole USDC units) means the payout is always at or below the exact
    ///      pro-rata share, so `deficitAfter <= deficitBefore` holds by construction and the
    ///      coverage ratio for the holders who did not redeem never falls. Every wei of rounding
    ///      accrues to them, never to the redeemer.
    ///
    ///      OVERFLOW AND DIVISION BY ZERO. `Math.mulDiv` computes the 512-bit intermediate, so
    ///      `usdfrIn * backing` cannot overflow regardless of supply. The division is guarded by
    ///      the explicit `supply == 0` early return below — R16 argued instead that the
    ///      `backing >= supply` branch covered it, which was true but ALSO meant an empty protocol
    ///      quoted PAR against supply that does not exist (see `previewRedeem`). The explicit
    ///      guard fixes the quote and carries the division safety, and unlike the argument it
    ///      replaces it is falsifiable: delete it and
    ///      `test_R17_V02_anEmptyProtocolQuotesNothingRatherThanPar` goes red.
    ///
    ///      TWO GUARDS REMOVED / KEPT, PER FINDING M6'S OWN RULE. The `if (usdfrIn == 0) return`
    ///      short-circuit R16 shipped was DELETED in R17: it was provably redundant (with
    ///      `supply != 0`, `mulDiv(0, backing, supply)` is 0 and the par branch returns 0 too), and
    ///      a mutation campaign confirmed it could be removed with the entire deterministic AND
    ///      invariant suite green. The `usdcOut == 0` clamp below is KEPT because it has an
    ///      observable effect — `previewRedeem`'s documented `(0, 0)` contract, which a caller
    ///      uses to decide whether anything will be burned — and R17 asserts BOTH components of
    ///      that contract in `test_L3_theDustFloorIsQuotableRatherThanAHiddenRevert`, which is what
    ///      makes it falsifiable.
    ///
    ///      SLITHER `divide-before-multiply` FIRES ON `(usdfrAmount / SCALE) * SCALE`, AND IS
    ///      ACCEPTED. R16 claimed the triaged baseline "already carried" it against `redeem`; it
    ///      did not carry it against THIS function, and the baseline checker fingerprints on the
    ///      element name with line numbers deliberately excluded, so moving the expression created
    ///      a NEW finding and staled the old entry. R17 re-ran the analysis, removed the stale
    ///      `redeem` fingerprint and added `_quoteRedeem`; this paragraph is the triage and must be
    ///      transcribed into `STATE.md` at merge, as CLAUDE.md §3.2 requires. The precision
    ///      loss is the POINT: it snaps the burn to the whole-USDC grid so sub-unit dust is never
    ///      taken from the holder.
    function _quoteRedeem(uint256 usdfrAmount, uint256 supply, uint256 backing, uint256 drawn)
        private
        pure
        returns (uint256 usdcOut, uint256 usdfrIn)
    {
        if (supply == 0) return (0, 0);
        usdfrIn = (usdfrAmount / SCALE) * SCALE;
        uint256 valueOut;
        if (backing >= supply) {
            valueOut = usdfrIn;
        } else {
            valueOut = Math.mulDiv(usdfrIn + drawn, backing, supply);
            // THE PAR CEILING (ADR-0034 Y-bis). Stated honestly per finding M6's own rule: with
            // `_exitDrawTarget`'s exact `ceil` sizing this is UNREACHABLE, and I could not
            // construct a mutation that reds it without also breaking the sizing — so DO NOT write
            // a comment claiming a mutation reds it. It is kept, not deleted, because it is the
            // only thing standing between a future sizing bug and an exiting holder being paid
            // ABOVE par out of first-loss capital, i.e. stealing the junior tranche through
            // `redeem`. Read it exactly as `mint`'s `forceApprove(…, 0)` is read.
            if (valueOut > usdfrIn) valueOut = usdfrIn;
        }
        usdcOut = valueOut / SCALE;
        if (usdcOut == 0) usdfrIn = 0;
    }

    /// @dev ADR-0034 Y-bis — HOW MUCH JUNIOR CAPITAL THIS EXIT NEEDS. Pure so it can be reasoned
    ///      about and fuzzed on its own.
    ///
    ///      THE RULE. `d* = min( ceil(usdfrIn * D / B), D )` with `D = supply - backing`.
    ///
    ///      WHY `/B` AND NOT `/supply` — THIS IS THE WHOLE ARITHMETIC AND IT IS EASY TO GET WRONG.
    ///      Burning `d` of junior USDfr removes `d` from SUPPLY ONLY; backing does not move,
    ///      because junior capital is denominated in USDfr, not in the reserve's USDC. Requiring
    ///      that the holders who STAY are no worse off after the exit gives
    ///      `B(supply - d - u) <= supply(B - v)`, i.e. `v <= B(u + d)/supply`; setting `v = u`
    ///      (par) yields `d >= u * D / B`. A `u * D / supply` draw structurally UNDER-draws and
    ///      leaves the exiter impaired while junior capital sits intact — which is decision X's
    ///      defect, not its cure.
    ///
    ///      WHY IT CANNOT OVER-DRAW, WHICH IS ADR-0034's THIRD BINDING REQUIREMENT. Each draw
    ///      lowers supply by exactly `d` with backing unmoved, so `D' = D - d` EXACTLY, and the
    ///      exit itself lowers `D` by a further `u - v >= 0`. The stock therefore decrements by the
    ///      flow one-for-one and draws TELESCOPE: cumulative draw over any sequence of exits can
    ///      never exceed the `D` standing when the mark was taken.
    ///
    ///      THE `min(..., D)` CLAMP IS UNREACHABLE, AND THIS PARAGRAPH USED TO CLAIM OTHERWISE.
    ///      CORRECTED (SWEEP-3 S3-F4). It said the clamp "makes over-draw UNREPRESENTABLE rather
    ///      than merely bounded" and cited
    ///      `testFuzz_Y_G05_theDrawNeverExceedsTheStandingDeficit` as its falsifier. BOTH CLAIMS
    ///      WERE FALSE. MEASURED: neutralising the clamp so it still compiles and still reads both
    ///      operands leaves the ENTIRE non-fork suite byte-identical to baseline — including that
    ///      named fuzz test at 1,025 runs and the ADR-0034 Z certifier
    ///      `invariant_Z_noDrawExceedsTheStandingDeficit` at 256 runs x 32,768 calls. Zero catchers.
    ///      THE THEOREM, so nobody re-argues it: the clamp binds iff `ceil(u*D/B) > D`, i.e. iff
    ///      `u > B`. `drawn` is measured as a balance RISE on the source, so the tokens must arrive
    ///      from other USDfr balances: `drawn <= S - u - balBefore(source) <= S - u`. With
    ///      `u > B = S - D` that gives `drawn < D <= the clamped target`. The clamp can never change
    ///      `drawn` on any path, including against a lying source.
    ///      KEEP IT — it is the cheap, legible statement of the bound, exactly as the par ceiling in
    ///      `_quoteRedeem` is kept — but label it honestly, and DO NOT write a comment claiming a
    ///      mutation reds it.
    ///
    ///      WHY IT CANNOT UNDER-DRAW. The target rounds UP (`Ceil`); every other rounding in the
    ///      quote is DOWN. So R17's
    ///      `testFuzz_M3_aSubParExitNeverWorsensTheRatioForTheHoldersWhoStayed` property is
    ///      STRENGTHENED by this change, never weakened.
    ///
    ///      IT IS A FLOW COMPUTED FROM A STOCK, AND `pendingSeniorImpairment()` IS DELIBERATELY NOT
    ///      CONSULTED. That view is a CREDIT-layer stock in units of declared/past-due PRINCIPAL;
    ///      `D` is a CUSTODY/VALUATION quantity. They diverge in BOTH directions — a
    ///      `writeDownIdleUSDC` custody loss has `D > 0` with `pendingSeniorImpairment() == 0`, and
    ///      a declared-but-unmarked default has the reverse — so mixing them would either fail to
    ///      fund the exit at all or price a whole book sub-par. That mixing of a cumulative stock
    ///      into a per-transaction flow is precisely the shape that broke an adjacent
    ///      `mintableHeadroom()` fix.
    function _exitDrawTarget(uint256 usdfrIn, uint256 supply, uint256 backing) private pure returns (uint256 target) {
        if (usdfrIn == 0 || backing == 0 || backing >= supply) return 0;
        uint256 deficit = supply - backing;
        target = Math.mulDiv(usdfrIn, deficit, backing, Math.Rounding.Ceil);
        if (target > deficit) target = deficit;
    }

    /// @dev ADR-0034 Y-bis — THE ATOMIC JUNIOR DRAW — LOAD-BEARING, DO NOT DELETE. Read
    ///      `ADR/0034-exit-pricing-in-cascade-order.md` in full before changing anything here.
    ///
    ///      WHAT IT FIXES. `_quoteRedeem` priced the direct exit off GROSS `totalBackingValue()`,
    ///      which nets NOTHING against junior capital, while the `sUSDfr` path prices off
    ///      `DefaultManager.pendingSeniorImpairment()`, which nets curator first-loss and then the
    ///      sGROVE backstop. A holder redeeming while curator capital sat intact therefore absorbed
    ///      a loss the junior tranche contracted to take first — the locked §1.3 cascade run
    ///      backwards. Forest Road (2026-08-08) decided the residual price and the draw are NOT
    ///      alternatives: the residual price PROMISES more than gross-marked backing, and the
    ///      difference sits in the curator pool and the backstop, not in the reserve's USDC. So
    ///      junior capital is drawn IN THIS TRANSACTION and cascade order is enforced AT
    ///      SETTLEMENT.
    ///
    ///      THE SOURCE IS DERIVED, NOT STORED, AND THAT IS DELIBERATE. `$.reserves.lossAbsorber()`
    ///      IS the cascade the protocol runs its losses through; `ReserveManager.setLossAbsorber`
    ///      already refuses any address whose `reserveLossSource()` does not point back at it. A
    ///      second stored pointer here would be a second source of truth that could DISAGREE — a
    ///      controller drawing from `DefaultManager` v1 while the reserve allocates losses through
    ///      v2 — and it would cost a namespaced tail field, a governance setter, an ACL-surface
    ///      re-pin and `Deploy`/`Validate`/`Handover` wiring to buy that risk. Deriving costs one
    ///      `staticcall` and cannot desynchronise.
    ///
    ///      THE BURN AUTHORISATION IS THE `lossSource` LIST, AND IT IS THE GUARD THAT MATTERS.
    ///      `$.usdfr.burn(source, drawn)` is raw MINTER_ROLE power over a third party's balance —
    ///      exactly the confiscation primitive R16-M1/M2 constrained. Requiring `source` to be a
    ///      governance-named loss source reuses that existing, already-deployed list rather than
    ///      inventing a parallel one, so a compromised or misconfigured `ReserveManager` can at
    ///      worst point this at an address that is not on the list — which REVERTS. It can never
    ///      make `redeem` burn a user's wallet. Falsified by
    ///      `test_Y_G02_theDrawRefusesASourceGovernanceHasNotNamedALossSource`.
    ///
    ///      IT BURNS IN PLACE RATHER THAN CALLING `burnLoss`. `burnLoss` is `nonReentrant` on THIS
    ///      contract and `redeem` already holds that lock, so the `DefaultManager.realizeLoss`
    ///      shape (draw, then call back into `burnLoss`) reverts with
    ///      `ReentrancyGuardReentrantCall`. The drawn USDfr is left standing at the source and
    ///      burned here. Anyone "restoring symmetry" with `realizeLoss` bricks every under-backed
    ///      exit.
    ///
    ///      MEASURE, DO NOT TRUST. The delivered amount is measured as a balance delta on the
    ///      SOURCE and must be AT LEAST what the source reported, and the report must be at most
    ///      what was requested. A source that over-reports, under-delivers, or hands back more than
    ///      asked can therefore only cause a REVERT, never an overpayment out of junior capital.
    ///      Falsified by `test_Y_G06_aLyingDrawSourceCanOnlyRevertTheExitNeverOverpayIt` (the
    ///      report/delivery legs) and by
    ///      `S2_GuardVacuity.t.sol::test_S2_anOverDeliveringDrawSourceMustStillBeRefused` (the
    ///      `reported > target` leg, which had NO falsifier in the tree until SWEEP-2 measured it
    ///      as a deletable guard).
    ///
    ///      AUDIT FIX (SWEEP-2 S2-F5): the delivery leg is a FLOOR, not an equality, because a
    ///      strict equality here is a redemption kill switch in the hands of the fail-open points
    ///      hook. The full finding is at the comparison itself — read it before touching this.
    ///
    ///      WHERE IT SITS IN `_redeem`, AND WHY IT MUST STAY THERE. It runs BEFORE the R18
    ///      `payeeBefore`/`payeeAfter` delivery window. The burn fires `USDfr`'s deliberately
    ///      FAIL-OPEN points hook and `CuratorModule` fires `IPointsModule.onCuratorLoss`, and
    ///      R18's general rule on `_redeem` is that no call a redeemer or a governance-set module
    ///      can influence may sit between `payeeBefore` and `payeeAfter`. DO NOT MOVE IT DOWN.
    ///
    ///      UNWIRED IS TOLERATED, AND ONLY BECAUSE IT IS SAFE. A zero `lossAbsorber()` draws
    ///      nothing and the exit settles at exactly today's gross price. That is the state every
    ///      deployment starts in, and refusing the exit there would be a fresh deadlock in the
    ///      state ADR-0034 exists to cure. `Validate.s.sol` asserts the production wiring.
    ///
    ///      NOT WIRED IS SAFE; WIRED-BUT-UNANSWERING IS NOT, AND THAT IS DELIBERATE. A source that
    ///      is present but cannot answer `drawForSeniorExit` reverts the exit rather than silently
    ///      pricing it at the gross mark. This follows the house rule `WaterfallEngine` states for
    ///      the same shape — optional wiring via a zero check, and NEVER `try/catch`, because "a
    ///      failure here must fail loudly" (CLAUDE.md prime directive 4). THE OPERATIONAL
    ///      CONSEQUENCE, STATED SO IT IS NOT DISCOVERED LATE: `DefaultManager` MUST BE UPGRADED
    ///      BEFORE THIS CONTROLLER. Upgrading the controller first leaves every UNDER-BACKED exit
    ///      reverting until the manager catches up. Par exits are unaffected in either order,
    ///      because no draw is attempted while `backing >= supply`.
    ///
    ///      SLITHER TRIAGE (CLAUDE.md §3.2 — transcribe into `STATE.md` at merge). This function
    ///      adds `reentrancy-balance` on itself and on `_redeem` (which goes 1 -> 3), plus
    ///      `incorrect-equality`. Both are the guard, not a bug, and are the same triage `mint` and
    ///      `_redeem` already carry: a balance read STRADDLING an external call and gating a state
    ///      change IS the measurement. AUDIT FIX (SWEEP-2 S2-F5) CORRECTS THIS PARAGRAPH: it used
    ///      to say the STRICT EQUALITY is what makes a lying source fail closed in both directions,
    ///      and that "a `>=` relaxation would let a source over-deliver and strand USDfr". Both
    ///      halves were wrong. The equality was breakable by any third party pushing one wei into
    ///      the window (measured), and over-delivery is refused by `reported > target`, not by the
    ///      delivery comparison at all — the source cannot over-deliver AND report honestly without
    ///      failing that first check, and if it under-reports its own over-delivery the excess is
    ///      simply never burned. A non-straddling read would still let it lie, which is why the
    ///      straddle stays.
    ///      `DefaultManager._coverFromBackstop` keeps the same straddling measurement for facility
    ///      defaults, senior exits and the retained compatibility entry. The live custody path
    ///      performs its equivalent balance-delta check inside `ReserveManager`; the extraction is
    ///      therefore a RENAME with no net new finding.
    function _drawJuniorForExit(ControllerStorage storage $, uint256 usdfrIn, uint256 supply, uint256 backing)
        private
        returns (uint256 drawn)
    {
        uint256 target = _exitDrawTarget(usdfrIn, supply, backing);
        if (target == 0) return 0;

        address source = $.reserves.lossAbsorber();
        if (source == address(0)) return 0;
        if (!$.lossSource[source]) revert Controller_ExitDrawSourceNotAuthorised(source);

        uint256 balBefore = $.usdfr.balanceOf(source);
        uint256 reported = ISeniorExitDrawSource(source).drawForSeniorExit(target);
        uint256 balAfter = $.usdfr.balanceOf(source);
        uint256 delivered = balAfter < balBefore ? 0 : balAfter - balBefore;
        // ── AUDIT FIX (SWEEP-2 S2-F5) — THE MEASUREMENT IS A FLOOR, NOT AN EQUALITY ──
        //
        // LOAD-BEARING IN BOTH DIRECTIONS. DO NOT RESTORE `drawn != reported || drawn > target`.
        //
        // WHY THE EQUALITY HAD TO GO. R18 found that `_redeem`'s outflow window contained a call
        // the deliberately FAIL-OPEN points hook could influence, hoisted the burn out, and wrote a
        // general rule into `_redeem`'s NatSpec: no call a redeemer or a governance-set module can
        // influence may sit inside a strict-equality balance window. ADR-0034 Y-bis then opened a
        // SECOND such window here. Everything inside `drawForSeniorExit` — `CuratorModule`'s USDfr
        // transfer to `DefaultManager`, `SGrove.coverShortfall`'s — fires `USDfr._update`'s points
        // hook, which is fail-open ONLY inside the token's own `try/catch`; a points module that
        // succeeds while transferring ONE WEI of USDfr into `source` broke `delivered == reported`,
        // and this revert is OUTSIDE that `try/catch`. MEASURED: `Controller_ExitDrawNotDelivered
        // (target=4950...50, reported=4950...50, measured=4950...51)` — exactly one wei bricked
        // EVERY under-backed exit, the one path ADR-0034 exists to keep open, and unwiring the
        // module reopened it in the same state.
        //
        // WHAT IS STILL FAIL-CLOSED, AND WHY THAT IS THE WHOLE SAFETY PROPERTY:
        //   • `reported > target`  -> REVERT. A source may never hand back more than it was asked
        //     for; ADR-0034 requirement 3 is that the draw brings absorption FORWARD in time, it
        //     does not ENLARGE it. This is also the disjunct SWEEP-2 M3 measured as unfalsifiable
        //     in its old `drawn > target` form (`LyingExitDrawSource` never moves a token, so both
        //     of its modes were caught by the equality alone). It now has a real falsifier:
        //     `S2_GuardVacuity.t.sol::test_S2_anOverDeliveringDrawSourceMustStillBeRefused`.
        //   • `delivered < reported` -> REVERT. A source that OVER-REPORTS or UNDER-DELIVERS still
        //     fails loudly, which is the house rule (CLAUDE.md prime directive 4) and the reason
        //     this is a measurement at all.
        // Only a THIRD PARTY pushing EXTRA tokens into the source is now tolerated, and it is
        // strictly harmless: `drawn` is set from `reported`, which is bounded by `target`, so the
        // donation is neither burned nor credited to the redeemer's price. It simply sits at the
        // loss absorber, exactly as an unsolicited transfer to any module does.
        if (reported > target || delivered < reported) {
            revert Controller_ExitDrawNotDelivered(target, reported, delivered);
        }
        drawn = reported;
        if (drawn == 0) return 0;
        $.usdfr.burn(source, drawn);
        emit SeniorExitJuniorDrawn(msg.sender, target, drawn);
    }

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}

    function _storage() private pure returns (ControllerStorage storage $) {
        assembly {
            $.slot := CONTROLLER_STORAGE_LOCATION
        }
    }
}
