// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ContinuousAccrualDeployment} from "../../script/ContinuousAccrualDeployment.sol";
import {ContinuousAccrualMigration} from "../../script/ContinuousAccrualMigration.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {WaterfallEngine} from "../../src/WaterfallEngine.sol";
import {IAccrualLifecycle} from "../../src/interfaces/IAccrualLifecycle.sol";
import {IAccrualMigration} from "../../src/interfaces/IAccrualMigration.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {AccrualBook} from "../../src/libraries/AccrualBook.sol";
import {AccrualCeiling} from "../../src/libraries/AccrualCeiling.sol";
import {AccrualLoans} from "../../src/libraries/AccrualLoans.sol";
import {Config} from "../../src/libraries/Config.sol";
import {DefaultAccrualLib} from "../../src/libraries/DefaultAccrualLib.sol";
import {ReserveAccrualLib} from "../../src/libraries/ReserveAccrualLib.sol";
import {ReserveMigrationLib} from "../../src/libraries/ReserveMigrationLib.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title ATK_AccrualMigrationFork: adversarial rehearsal of the LEGACY-TO-CONTINUOUS opening
///        migration, the path mainnet must execute, against the full protocol on a pinned fork.
///
/// @notice Target: `ReserveMigrationLib` (the import it implements, `IAccrualMigration`), the
///         `AccrualOpening` attestation kind, `DefaultManager.onAccrualOpening`, and the operator
///         script `script/ContinuousAccrualMigration.sol` whose encoding the attesters must
///         reproduce. Every other fork suite inherits a book that `Deploy._wireContinuousAccrual`
///         enabled at deploy, which closes the migration (`ReserveAccrual_AlreadyConfigured`) and
///         left the library at 1 of 41 branches reached. This suite overrides that hook to leave
///         the modules UNBOUND, exactly the state the live deployment is in today, funds two
///         facilities through the legacy engine with elapsed time, a cash coupon receipt, a PIK
///         capitalisation and a PIK principal prepayment, and then runs the migration with the
///         real operator helper: `ContinuousAccrualMigration.prepare` binds, seats the quorum,
///         grants the consumer role and freezes the roster in one invocation; `openingPayload`
///         is what the attesters sign; `importCalldata` is what the operator broadcasts.
///
///         Invariants under attack (CLAUDE.md 1.3): I1 backing (imported income raises deployed
///         face, never supply, and materialisation mints exactly the attested income); I2 value
///         conservation (an opening is consumed once, posted once, and the continuous engine
///         resumes from the imported balances so that the next PIK coupon equals the coupon the
///         legacy planner would have capitalised, to the wei); I7 sUSDfr rate integrity (the
///         migration is not a price event); I8 access control (carol reaches nothing).
///
///         The attacker is carol: not KYC'd, no role, real USDC. Operator calls appear only to
///         reach a legitimate state.
///
///         Attacks:
///           A1. CAROL: every configuration, preparation, import, cancel and activation entry,
///               every consumer binding, the oracle's consumer role and the risk callback reject
///               her with the exact role error; her one permitted act, relaying a genuine quorum,
///               leaves the migration exactly where it was; during preparation no financial entry
///               is open to anyone; after activation the keeper entries are hers by design (I8).
///           A2. THE REHEARSAL: the operator script, byte for byte, on a legacy book with a paid
///               cash coupon, a capitalised PIK coupon and a PIK principal prepayment that leaves
///               the legacy cursor basis above the deployed face. The script's payload equals the
///               contract's; both openings import with the exact attested income; the backing
///               invariant holds through import, activation and materialisation; the engine's
///               first capitalisation after the cutoff equals the legacy planner's coupon on the
///               frozen basis, not on the reduced principal; the legacy receipt and crank paths
///               are closed; a receipt settles through the engine (I1, I2, I7).
///           A3. OFF-FACE OPENINGS: one wei off principal, interest or frozen basis is refused
///               `InexactOpening`; cash principal one grid unit above the recorded face, face
///               below the recorded face, a cash coupon date, a period start after the cutoff and a
///               PIK coupon date at the cutoff are each refused with the exact error and every
///               refusal leaves the standing fact for governance to revoke; balances the contract
///               cannot verify (one grid unit of extra cash interest, one grid unit of unrecorded
///               PIK principal) import as attested and are minted as attested, no more (I1, I2).
///           A4. ROSTER AND BATCH DISCIPLINE: a roster missing a positive-face facility, unsorted,
///               duplicated, zero-padded, empty or naming a facility that was never funded; every
///               unknown action; a batch out of roster order, empty or oversized; activation and
///               cancellation after a partial import; the same facility twice under a fresh
///               approval reference; an attestation at the wrong asOf, for the wrong session, or a
///               second after the cutoff; the operator helper is not re-runnable once bound (I2).
///           A5. CANCEL AND RESTART: a cancelled session zeroes its progress but burns its nonce,
///               reopens the legacy engine, and cannot be activated without a new session; the old
///               session's standing facts block the new quorum until governance revokes them, and
///               never authenticate against the new session key (I2).
///           A6. DELAYED ACTIVATION: activating after a contractual PIK boundary has elapsed leaves
///               the book stale and every priced entry closed until one permissionless checkpoint
///               capitalises exactly the contractual coupon; the amount does not depend on when
///               activation happened (I2, I7).
contract ATK_AccrualMigrationForkTest is ForkLifecycleFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    uint256 internal constant SCALE = 1e12;
    uint256 internal constant YEAR = 360 days;
    uint16 internal constant RATE_BPS = 1400;
    uint64 internal constant INTERVAL = 90 days;
    uint64 internal constant TERM = 360 days;
    uint256 internal constant CASH_P = 1_000_000e18;
    uint256 internal constant PIK_P = 500_000e18;
    uint256 internal constant PIK_PREPAY = 100_000e18;
    uint256 internal constant DFLT_P = 200_000e18;

    // Legacy history, all exact on the 1e12 grid at 14% Actual/360:
    //   cash coupon for 90 days on 1,000,000: 35,000; accrued 45 days at the cutoff: 17,500.
    //   PIK coupon for 90 days on 500,000: 17,500; basis after the crank 517,500; prepayment of
    //   100,000 leaves deployed 417,500 while the legacy cursor basis stays 517,500; accrued 45 days
    //   at the cutoff on the frozen basis: 9,056.25; the next legacy coupon on that basis: 18,112.5.
    //   A third cash note of 200,000 misses its first coupon (7,000 for 90 days) and is declared
    //   defaulted on day 120; its opening carries that missed coupon and never earns again.
    uint256 internal constant CASH_COUPON = 35_000e18;
    uint256 internal constant CASH_OPEN_INTEREST = 17_500e18;
    uint256 internal constant PIK_COUPON_1 = 17_500e18;
    uint256 internal constant PIK_BASIS = PIK_P + PIK_COUPON_1; // 517,500
    uint256 internal constant PIK_RECORDED = PIK_BASIS - PIK_PREPAY; // 417,500
    uint256 internal constant PIK_OPEN_INTEREST = 9_056_250_000_000_000_000_000; // 9,056.25
    uint256 internal constant PIK_COUPON_2 = 18_112_500_000_000_000_000_000; // 18,112.5 on 517,500
    uint256 internal constant DFLT_OPEN_INTEREST = 7_000e18;
    uint256 internal constant LEGACY_FACE = CASH_P + PIK_RECORDED + DFLT_P; // 1,617,500
    uint256 internal constant OPEN_INCOME = CASH_OPEN_INTEREST + PIK_OPEN_INTEREST + DFLT_OPEN_INTEREST; // 33,556.25

    uint256 internal cashId;
    uint256 internal pikId;
    uint256 internal dfltId;
    uint64 internal t0;
    uint64 internal cutoff;

    /// @dev Mainnet shape: the modules are deployed and running with NO accrual binding. The real
    ///      operator helper installs the bindings during preparation (A2).
    function _wireContinuousAccrual(D memory) internal override {}

    // ── A1 ────────────────────────────────────────────────────────────────

    /// @notice Attacks every privileged entry of the migration from carol, before, during and after
    ///         a genuine session, and proves that preparation closes financial entry to everyone.
    function test_atk_carolCannotDriveAnyMigrationStepAndPreparationClosesTheBook() public onFork {
        _legacyBook();
        IContinuousAccrual.Modules memory m = _modules();
        uint256[] memory ids = _roster();
        bytes memory begin = abi.encode(uint8(0), abi.encode(ids));

        // Before any binding exists.
        _expectAdmin(carol);
        vm.prank(carol);
        reserves.configureContinuousAccrual(m);
        _expectAdmin(carol);
        vm.prank(carol);
        reserves.prepareContinuousAccrualMigration(begin);
        _expectAdmin(carol);
        vm.prank(carol);
        reserves.enableContinuousAccrual();
        _expectAdmin(carol);
        vm.prank(carol);
        usdfr.setAccrualReserve(address(reserves));
        _expectAdmin(carol);
        vm.prank(carol);
        controller.enableContinuousAccrual();
        _expectAdmin(carol);
        vm.prank(carol);
        vault.setAccrualReserve(address(reserves));
        _expectAdmin(carol);
        vm.prank(carol);
        registry.setAccrualReserve(address(reserves));
        _expectAdmin(carol);
        vm.prank(carol);
        bridge.setAccrualReserve(address(reserves));
        _expectAdmin(carol);
        vm.prank(carol);
        waterfall.setAccrualReserve(address(reserves));
        _expectAdmin(carol);
        vm.prank(carol);
        defaultManager.setAccrualReserve(address(reserves));
        vm.expectRevert(abi.encodeWithSelector(DefaultAccrualLib.DefaultAccrual_CallerNotReserve.selector, carol));
        vm.prank(carol);
        defaultManager.onAccrualOpening(cashId, 0);
        assertEq(waterfall.accrualReserve(), address(0), "carol bound nothing");
        assertFalse(reserves.accrualMigration().active, "carol began nothing");

        // The operator prepares for real (bind, quorum, consumer role, roster) in one invocation.
        _prepare(ids);
        IAccrualMigration.Progress memory p = reserves.accrualMigration();
        assertTrue(p.active && p.nonce == 1 && p.expected == 3 && p.imported == 0, "session 1 open");
        assertEq(p.originalFace, LEGACY_FACE, "roster face equals the legacy deployed total");

        // Carol's one permitted act: relaying the genuine quorum. It records, and nothing moves.
        IAccrualMigration.Opening memory cash = _cashOpening(bytes32(0));
        _relayOpening(cash, cutoff, carol);
        (bytes32 payload,, bool satisfied) =
            oracle.latestPayload(cashId, IAttestationOracle.AttestationKind.AccrualOpening);
        assertTrue(satisfied && payload == _scriptPayload(cash), "genuine opening recorded from carol's relay");
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.CREDIT_ROLE)
        );
        vm.prank(carol);
        oracle.consume(cashId, IAttestationOracle.AttestationKind.AccrualOpening);
        _expectAdmin(carol);
        vm.prank(carol);
        reserves.prepareContinuousAccrualMigration(abi.encode(uint8(1), abi.encode(_one(cash))));
        _expectAdmin(carol);
        vm.prank(carol);
        reserves.prepareContinuousAccrualMigration(abi.encode(uint8(2), bytes("")));
        _expectAdmin(carol);
        vm.prank(carol);
        reserves.enableContinuousAccrual();
        vm.expectRevert(abi.encodeWithSelector(DefaultAccrualLib.DefaultAccrual_CallerNotReserve.selector, carol));
        vm.prank(carol);
        defaultManager.onAccrualOpening(cashId, CASH_OPEN_INTEREST);
        p = reserves.accrualMigration();
        assertTrue(p.active && p.imported == 0 && p.nextFacilityId == cashId, "carol advanced nothing");
        assertEq(reserves.deployedTo(cashId), CASH_P, "cash face untouched");
        assertEq(reserves.deployedTo(pikId), PIK_RECORDED, "PIK face untouched");
        assertEq(
            uint8(oracle.factStatus(cashId, IAttestationOracle.AttestationKind.AccrualOpening, payload)),
            uint8(IAttestationOracle.FactStatus.Recorded),
            "fact still standing, unconsumed"
        );

        // No financial entry is open to anyone while preparation is active: KYC'd depositor,
        // servicer receipt, the permissionless legacy crank and the permissionless mark all stop.
        bytes memory busy = abi.encodeWithSelector(ReserveAccrualLib.ReserveAccrual_OperationInProgress.selector);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(controller), 1_000e6);
        vm.expectRevert(busy);
        controller.mint(1_000e6);
        vm.stopPrank();
        vm.expectRevert(busy);
        vm.prank(carol);
        waterfall.capitalizePik(pikId);
        vm.expectRevert(busy);
        vm.prank(carol);
        defaultManager.markPastDue(cashId);
        _expectDistributeRevert(cashId, SCALE, 0, busy);
        vm.expectRevert(busy);
        reserves.accrualSnapshot();

        // Finish the migration legitimately on the fact carol relayed; her attempts left no trace.
        _relayOpening(_pikOpening(bytes32(0)), cutoff, carol);
        _relayOpening(_defaultOpening(bytes32(0)), cutoff, carol);
        _import(_three(cash, _pikOpening(bytes32(0)), _defaultOpening(bytes32(0))));
        reserves.enableContinuousAccrual();
        assertTrue(reserves.accrualSnapshot().enabled, "book enabled after the complete import");
        (, bool fresh) = _checkpointAs(carol);
        assertTrue(fresh, "the keeper entry is permissionless by design");
        _expectAdmin(carol);
        vm.prank(carol);
        reserves.prepareContinuousAccrualMigration(begin);
    }

    // ── A2 ────────────────────────────────────────────────────────────────

    struct Rehearsal {
        uint256 supplyBefore;
        uint256 backingBefore;
        uint256 rateBefore;
        uint256 exposureBefore;
        uint256 senior;
        uint256 fee;
        bytes32 cashPayload;
        bytes32 pikPayload;
        uint256 assetsBefore;
        uint256 rateAtEnable;
        uint256 rateBeforeIssue;
    }

    /// @notice Runs the operator script against a legacy book and proves the continuous engine
    ///         resumes from the imported balances exactly where the legacy planner would have been.
    function test_atk_operatorScriptRehearsalMigratesTheLegacyBookExactly() public onFork {
        _legacyBook();
        Rehearsal memory r;
        r.supplyBefore = usdfr.totalSupply();
        r.backingBefore = reserves.totalBackingValue();
        r.rateBefore = vault.convertToAssets(10 ** vault.decimals());
        r.assetsBefore = vault.totalAssets();
        r.exposureBefore = registry.totalBookExposure();
        assertEq(reserves.deployedPrincipal(), LEGACY_FACE, "legacy deployed total");
        assertEq(r.exposureBefore, LEGACY_FACE, "legacy exposure equals deployed face");
        _assertLegacyCursor("legacy cursor settled through the first coupon");

        // Step 1 of the operator sequence: one invocation binds, seats the quorum, grants the
        // consumer role and freezes the roster. The helper is not re-runnable once bound.
        uint256[] memory ids = _roster();
        vm.expectEmit(true, false, false, false, address(reserves));
        emit ReserveMigrationLib.AccrualMigrationBegun(1, bytes32(0), 0, 0, 0);
        this.prepareExternal(ids);
        IAccrualMigration.Progress memory p = reserves.accrualMigration();
        assertEq(p.nonce, 1, "first session");
        assertEq(p.cutoff, cutoff, "cutoff is the preparation block");
        assertEq(p.expected, 3, "three rows frozen");
        assertEq(p.originalFace, LEGACY_FACE, "frozen original face");
        assertEq(p.nextFacilityId, cashId, "roster order");
        assertTrue(oracle.hasRole(Roles.CREDIT_ROLE, address(reserves)), "reserve may consume openings");
        assertEq(oracle.threshold(IAttestationOracle.AttestationKind.AccrualOpening), 2, "quorum floor kept");
        vm.expectRevert(abi.encodeWithSelector(ReserveAccrualLib.ReserveAccrual_OperationInProgress.selector));
        this.prepareExternal(ids);

        // Step 2: the attesters sign the script's payload; it must be the contract's payload.
        IAccrualMigration.Opening memory cash = _cashOpening(bytes32(0));
        IAccrualMigration.Opening memory pik = _pikOpening(bytes32(0));
        IAccrualMigration.Opening memory dflt = _defaultOpening(bytes32(0));
        assertEq(_scriptPayload(cash), _contractPayload(cash), "script and contract agree on the cash opening");
        assertEq(_scriptPayload(pik), _contractPayload(pik), "script and contract agree on the PIK opening");
        assertEq(_scriptPayload(dflt), _contractPayload(dflt), "script and contract agree on the defaulted opening");
        r.cashPayload = _scriptPayload(cash);
        r.pikPayload = _scriptPayload(pik);
        _relayOpening(cash, cutoff, carol);
        _relayOpening(pik, cutoff, carol);
        _relayOpening(dflt, cutoff, carol);

        // Step 3: one import transaction with the script's calldata. Each row posts exactly the
        // attested income above the recorded face; no token moves.
        vm.expectEmit(true, true, false, true, address(reserves));
        emit ReserveMigrationLib.AccrualOpeningImported(
            1, cashId, CASH_P, CASH_P, CASH_OPEN_INTEREST, CASH_OPEN_INTEREST, false, false
        );
        vm.expectEmit(true, true, false, true, address(reserves));
        emit ReserveMigrationLib.AccrualOpeningImported(
            1, pikId, PIK_RECORDED, PIK_RECORDED, PIK_OPEN_INTEREST, PIK_OPEN_INTEREST, false, false
        );
        // The declared default imports its missed coupon as stopped income: the risk callback
        // re-anchors the declared contribution and the ledger row to the new face.
        vm.expectEmit(true, false, false, true, address(defaultManager));
        emit DefaultAccrualLib.OpeningRiskRecorded(dfltId, DFLT_OPEN_INTEREST, true, false);
        vm.expectEmit(true, true, false, true, address(reserves));
        emit ReserveMigrationLib.AccrualOpeningImported(
            1, dfltId, DFLT_P, DFLT_P, DFLT_OPEN_INTEREST, DFLT_OPEN_INTEREST, true, false
        );
        _import(_three(cash, pik, dflt));
        p = reserves.accrualMigration();
        assertTrue(p.active && p.imported == 3 && p.nextFacilityId == 0, "all rows imported, session open");
        assertEq(reserves.deployedTo(dfltId), DFLT_P + DFLT_OPEN_INTEREST, "defaulted face carries its missed coupon");
        assertEq(
            defaultManager.defaultedContribution(dfltId),
            DFLT_P + DFLT_OPEN_INTEREST,
            "declared contribution re-anchored"
        );
        assertEq(
            defaultManager.declaredDefaultedPrincipal(FILM),
            DFLT_P + DFLT_OPEN_INTEREST,
            "class declared principal rose by the imported income"
        );
        assertEq(p.importedOriginalFace, LEGACY_FACE, "imported original face reconciles");
        assertEq(reserves.deployedTo(cashId), CASH_P + CASH_OPEN_INTEREST, "cash face carries its accrued coupon");
        assertEq(reserves.deployedTo(pikId), PIK_RECORDED + PIK_OPEN_INTEREST, "PIK face carries its accrued coupon");
        assertEq(
            reserves.deployedPrincipal(),
            LEGACY_FACE + OPEN_INCOME,
            "deployed total rose by exactly the imported income"
        );
        assertEq(registry.totalBookExposure(), reserves.deployedPrincipal(), "exposure follows face");
        assertEq(usdfr.totalSupply(), r.supplyBefore, "import minted nothing");
        assertEq(
            reserves.totalBackingValue(), r.backingBefore + OPEN_INCOME, "backing rose by exactly the imported income"
        );
        _assertConsumed(cashId, r.cashPayload);
        _assertConsumed(pikId, r.pikPayload);
        // The script quotes the LIVE face, so an imported row's payload is no longer reproducible
        // from it: the record moved by the posted income. Harmless (the fact is spent), noted.
        assertTrue(_scriptPayload(cash) != r.cashPayload, "script payload moves with the posted face");

        // While the session is open the senior vault cannot even be quoted: every ERC-4626 view
        // that reads the reserve's effective supply reverts until activation (observation).
        vm.expectRevert(abi.encodeWithSelector(ReserveAccrualLib.ReserveAccrual_OperationInProgress.selector));
        vault.totalAssets();

        // Step 4: activation, then the deployment helper's independent validation.
        vm.expectEmit(true, false, false, true, address(reserves));
        emit ReserveAccrualLib.AccrualEnabled(cutoff, uint16(Config.DEFAULT_PROTOCOL_FEE_BPS), ops);
        reserves.enableContinuousAccrual();
        ContinuousAccrualDeployment.validate(address(reserves), _modules());
        assertFalse(reserves.accrualMigration().active, "session closed by activation");
        IContinuousAccrual.Snapshot memory s = reserves.accrualSnapshot();
        assertTrue(s.enabled && s.fresh, "enabled and fresh at the cutoff");
        assertEq(s.seniorUnissued + s.feeUnissued, OPEN_INCOME, "imported income awaits issuance");
        assertEq(s.feeUnissued, OPEN_INCOME / 10, "protocol fee on imported income");
        _assertBacking("after activation");
        // Activation is the ONE recognition of the imported income: the senior vault's fee-net
        // assets rise by exactly the senior share (income less the 10% protocol fee) at this
        // instant, a step the legacy book would have taken at the next coupon receipt instead.
        assertEq(
            vault.totalAssets(), r.assetsBefore + s.seniorUnissued, "senior assets rose by the imported senior claim"
        );
        r.rateAtEnable = vault.convertToAssets(10 ** vault.decimals());
        assertGt(r.rateAtEnable, r.rateBefore, "the imported senior claim is priced at activation");
        emit log_named_uint("session key (uint)", uint256(reserves.accrualMigration().sessionKey));
        emit log_named_uint("cutoff", cutoff);
        emit log_named_uint("senior assets before activation", r.assetsBefore);
        emit log_named_uint("senior assets after activation", vault.totalAssets());
        emit log_named_uint("senior price before activation (per share)", r.rateBefore);
        emit log_named_uint("senior price after activation (per share)", r.rateAtEnable);

        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(pikId);
        assertTrue(d.known && d.active && d.pik, "PIK row known and earning");
        assertEq(d.principal, PIK_RECORDED, "imported PIK principal is the deployed face");
        assertEq(d.interest, PIK_OPEN_INTEREST, "imported PIK interest is the attested coupon so far");
        assertEq(d.nextCapitalization, t0 + 2 * INTERVAL, "contractual coupon date preserved");
        d = reserves.accruedDebt(cashId);
        assertEq(d.principal, CASH_P, "imported cash principal");
        assertEq(d.interest, CASH_OPEN_INTEREST, "imported cash interest");
        d = reserves.accruedDebt(dfltId);
        assertTrue(d.known && !d.active, "defaulted row known and stopped");
        assertEq(d.interest, DFLT_OPEN_INTEREST, "defaulted row carries exactly the attested coupon");

        // The legacy paths are closed: the planner refuses, the cursor is frozen where it was.
        vm.expectRevert(abi.encodeWithSelector(WaterfallEngine.Waterfall_AccrualManagedPik.selector, pikId));
        waterfall.planPik(pikId);
        _assertLegacyCursor("legacy cursor frozen");
        _mintFromUSDC(alice, 1_000e6);

        // Step 5: the first contractual boundary after the cutoff. The engine capitalises the
        // coupon the legacy planner would have produced on the FROZEN basis (517,500), not on the
        // reduced principal (417,500), and from the cutoff only the unrecognised part is new.
        _warp(uint256(t0 + 2 * INTERVAL) - block.timestamp);
        (uint256 processed, bool fresh) = _checkpointAs(carol);
        assertGe(processed, 1, "the PIK boundary was processed");
        assertTrue(fresh, "fresh after the boundary");
        d = reserves.accruedDebt(pikId);
        assertEq(d.principal, PIK_RECORDED + PIK_COUPON_2, "capitalised exactly the legacy coupon on the frozen basis");
        assertEq(d.interest, 0, "coupon fully capitalised at the boundary");
        assertEq(d.nextCapitalization, t0 + 3 * INTERVAL, "cursor advanced one interval");
        assertEq(reserves.deployedTo(pikId), PIK_RECORDED + PIK_COUPON_2, "face follows the capitalisation");
        d = reserves.accruedDebt(cashId);
        assertEq(d.interest, CASH_COUPON, "cash accrued a second 45 days: 17,500 + 17,500");
        d = reserves.accruedDebt(dfltId);
        assertEq(d.interest, DFLT_OPEN_INTEREST, "a declared default does not restart earning");
        assertEq(d.principal, DFLT_P, "defaulted principal untouched");
        _assertLegacyCursor("legacy cursor still frozen; the engine owns the clock");

        // Step 6: materialisation mints exactly the recognised income, is not a second price
        // event, and the backing invariant holds; then a receipt settles through the engine, not
        // through the legacy ledger.
        _assertBacking("before materialisation");
        r.rateBeforeIssue = vault.convertToAssets(10 ** vault.decimals());
        (r.senior, r.fee) = reserves.materializeAccrued(3);
        assertEq(
            vault.convertToAssets(10 ** vault.decimals()), r.rateBeforeIssue, "materialisation is not a price event"
        );
        emit log_named_uint("materialised senior", r.senior);
        emit log_named_uint("materialised fee", r.fee);
        emit log_named_uint("senior price at materialisation (per share)", r.rateBeforeIssue);
        s = reserves.accrualSnapshot();
        assertEq(s.seniorUnissued + s.feeUnissued, 0, "everything recognised was issued");
        assertEq(
            usdfr.totalSupply(),
            r.supplyBefore + 1_000e18 + r.senior + r.fee,
            "supply rose by the minted deposit and the materialised claims only"
        );
        _assertBacking("after materialisation");
        assertGe(r.rateBeforeIssue, r.rateAtEnable, "senior rate never fell after activation");

        IWaterfallEngine.Payment memory receipt = _preparedReceipt(cashId, CASH_COUPON, 0);
        vm.expectEmit(true, true, false, true, address(waterfall));
        emit WaterfallEngine.AccruedReceiptSettled(cashId, receipt.paymentId, CASH_P);
        vm.prank(ops);
        waterfall.distribute(receipt);
        d = reserves.accruedDebt(cashId);
        assertEq(d.interest, 0, "the engine discharged the accrued interest");
        assertEq(reserves.deployedTo(cashId), CASH_P, "cash face back to principal");
        _assertBacking("after the engine receipt");
    }

    // ── A3 ────────────────────────────────────────────────────────────────

    /// @notice Attacks the opening balances: exactness, the cash-only bounds, the cursor bounds,
    ///         and what the contract deliberately cannot check.
    function test_atk_openingsOffTheLegacyFaceAreRefusedOrCarriedExactlyAsAttested() public onFork {
        _legacyBook();
        _prepare(_roster());
        uint256 supplyBefore = usdfr.totalSupply();

        IAccrualMigration.Opening memory o = _cashOpening(bytes32(0));
        o.principal = CASH_P - 1;
        _probe(o, abi.encodeWithSelector(ReserveMigrationLib.AccrualMigration_InexactOpening.selector, cashId));
        o = _cashOpening(bytes32(0));
        o.interest = CASH_OPEN_INTEREST + 1;
        _probe(o, abi.encodeWithSelector(ReserveMigrationLib.AccrualMigration_InexactOpening.selector, cashId));
        o = _cashOpening(bytes32(0));
        o.principal = CASH_P + SCALE;
        _probe(o, abi.encodeWithSelector(ReserveMigrationLib.AccrualMigration_InvalidFacility.selector, cashId));
        o = _cashOpening(bytes32(0));
        o.principal = CASH_P - SCALE;
        o.interest = 0;
        _probe(o, abi.encodeWithSelector(ReserveMigrationLib.AccrualMigration_InvalidFacility.selector, cashId));
        o = _cashOpening(bytes32(0));
        o.nextCapitalization = t0 + 2 * INTERVAL;
        _probe(o, abi.encodeWithSelector(ReserveMigrationLib.AccrualMigration_InvalidFacility.selector, cashId));
        o = _cashOpening(bytes32(0));
        o.periodStart = cutoff + 1;
        _probe(o, abi.encodeWithSelector(ReserveMigrationLib.AccrualMigration_InvalidFacility.selector, cashId));
        o = _cashOpening(bytes32(0));
        o.frozenPikBasis = SCALE;
        _probe(o, abi.encodeWithSelector(AccrualLoans.AccrualLoans_InvalidOpening.selector));
        assertEq(reserves.accrualMigration().imported, 0, "every refused batch was atomic");
        assertEq(reserves.deployedTo(cashId), CASH_P, "no refused opening touched the face");

        // What the contract cannot verify: one grid unit of interest above the contractual
        // accrual. The attesters are the authority (ADR-0007); it imports as attested.
        o = _cashOpening(keccak256("cash-plus-one-grid"));
        o.interest = CASH_OPEN_INTEREST + SCALE;
        _relayOpening(o, cutoff, carol);
        vm.expectEmit(true, true, false, true, address(reserves));
        emit ReserveMigrationLib.AccrualOpeningImported(
            1, cashId, CASH_P, CASH_P, CASH_OPEN_INTEREST + SCALE, CASH_OPEN_INTEREST + SCALE, false, false
        );
        _import(_one(o));

        // PIK: one wei off the frozen basis; a coupon date at the cutoff; then one grid unit of
        // principal above the recorded face (an uncranked coupon the legacy book never posted)
        // imports as attested income.
        o = _pikOpening(bytes32(0));
        o.frozenPikBasis = PIK_BASIS + 1;
        _probe(o, abi.encodeWithSelector(ReserveMigrationLib.AccrualMigration_InexactOpening.selector, pikId));
        o = _pikOpening(bytes32(0));
        o.nextCapitalization = cutoff;
        _probe(o, abi.encodeWithSelector(AccrualCeiling.AccrualCeiling_InvalidSchedule.selector));
        o = _pikOpening(bytes32(0));
        o.periodStart = uint64(bridge.facility(pikId).maturity);
        _probe(o, abi.encodeWithSelector(ReserveMigrationLib.AccrualMigration_InvalidFacility.selector, pikId));
        o = _pikOpening(keccak256("pik-plus-one-grid"));
        o.principal = PIK_RECORDED + SCALE;
        _relayOpening(o, cutoff, carol);
        vm.expectEmit(true, true, false, true, address(reserves));
        emit ReserveMigrationLib.AccrualOpeningImported(
            1, pikId, PIK_RECORDED, PIK_RECORDED + SCALE, PIK_OPEN_INTEREST, PIK_OPEN_INTEREST + SCALE, false, false
        );
        _import(_one(o));

        // The declared default: a coupon date is refused (its principal is not PIK), an interest
        // one wei off is inexact, and the exact missed coupon imports as stopped income.
        o = _defaultOpening(bytes32(0));
        o.nextCapitalization = cutoff + 1;
        _probe(o, abi.encodeWithSelector(ReserveMigrationLib.AccrualMigration_InvalidFacility.selector, dfltId));
        o = _defaultOpening(bytes32(0));
        o.interest = DFLT_OPEN_INTEREST - 1;
        _probe(o, abi.encodeWithSelector(ReserveMigrationLib.AccrualMigration_InexactOpening.selector, dfltId));
        o = _defaultOpening(keccak256("dflt-approval"));
        _relayOpening(o, cutoff, carol);
        _import(_one(o));

        reserves.enableContinuousAccrual();
        uint256 income = OPEN_INCOME + 2 * SCALE;
        IContinuousAccrual.Snapshot memory s = reserves.accrualSnapshot();
        assertEq(s.seniorUnissued + s.feeUnissued, income, "exactly the attested income is recognised");
        (uint256 senior, uint256 fee) = reserves.materializeAccrued(3);
        assertEq(senior + fee, income, "exactly the attested income is minted");
        assertEq(usdfr.totalSupply(), supplyBefore + income, "supply rose by the attested income only");
        _assertBacking("after materialising attested income");
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(pikId);
        assertEq(d.principal, PIK_RECORDED + SCALE, "PIK principal as attested");
        assertEq(d.interest, PIK_OPEN_INTEREST, "PIK interest as attested");
    }

    // ── A4 ────────────────────────────────────────────────────────────────

    /// @notice Attacks the roster, the batch order and the session authentication.
    function test_atk_rosterAndBatchDisciplineCannotBeEvaded() public onFork {
        _legacyBook();
        uint256[] memory ids = _roster();
        bytes memory invalidRoster = abi.encodeWithSelector(ReserveMigrationLib.AccrualMigration_InvalidRoster.selector);
        bytes memory invalidBatch = abi.encodeWithSelector(ReserveMigrationLib.AccrualMigration_InvalidBatch.selector);

        // A roster that omits the PIK facility fails the operator helper AFTER it has bound every
        // consumer; the helper cannot be re-run, so the operator continues with the reserve directly.
        uint256[] memory shortRoster = new uint256[](1);
        shortRoster[0] = cashId;
        vm.expectRevert(invalidRoster);
        this.prepareExternal(shortRoster);
        assertEq(waterfall.accrualReserve(), address(0), "the failed invocation reverted as a unit");
        ContinuousAccrualDeployment.bind(address(reserves), _modules());
        oracle.grantRole(Roles.CREDIT_ROLE, address(reserves));
        vm.expectRevert(abi.encodeWithSelector(ReserveAccrualLib.ReserveAccrual_AlreadyConfigured.selector));
        this.prepareExternal(ids);

        vm.expectRevert(invalidRoster);
        _begin(shortRoster);
        uint256[] memory bad = new uint256[](2);
        bad[0] = pikId;
        bad[1] = cashId;
        vm.expectRevert(invalidRoster);
        _begin(bad);
        bad[0] = cashId;
        bad[1] = cashId;
        vm.expectRevert(invalidRoster);
        _begin(bad);
        bad[0] = 0;
        bad[1] = cashId;
        vm.expectRevert(invalidRoster);
        _begin(bad);
        vm.expectRevert(invalidRoster);
        _begin(new uint256[](0));
        uint256[] memory ghost = new uint256[](4);
        ghost[0] = cashId;
        ghost[1] = pikId;
        ghost[2] = dfltId;
        ghost[3] = dfltId + 1;
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_UnknownToken.selector, dfltId + 1));
        _begin(ghost);
        uint256 pendingId = _originateLegacy(250_000e18, false, keccak256("never-funded"), false, cutoff);
        assertEq(reserves.deployedTo(pendingId), 0, "a pending facility has no face");
        ghost[3] = pendingId;
        vm.expectRevert(
            abi.encodeWithSelector(ReserveMigrationLib.AccrualMigration_InvalidFacility.selector, pendingId)
        );
        _begin(ghost);
        vm.expectRevert(abi.encodeWithSelector(ReserveMigrationLib.AccrualMigration_InvalidAction.selector, 3));
        reserves.prepareContinuousAccrualMigration(abi.encode(uint8(3), bytes("")));
        vm.expectRevert(invalidBatch);
        reserves.prepareContinuousAccrualMigration(abi.encode(uint8(2), bytes("x")));
        vm.expectRevert(abi.encodeWithSelector(ReserveMigrationLib.AccrualMigration_NotStarted.selector));
        reserves.prepareContinuousAccrualMigration(abi.encode(uint8(2), bytes("")));
        vm.expectRevert(abi.encodeWithSelector(ReserveMigrationLib.AccrualMigration_NotStarted.selector));
        reserves.prepareContinuousAccrualMigration(abi.encode(uint8(1), abi.encode(_one(_cashOpening(bytes32(0))))));
        assertFalse(reserves.accrualMigration().active, "nothing began");

        _begin(ids);
        vm.expectRevert(abi.encodeWithSelector(ReserveMigrationLib.AccrualMigration_AlreadyStarted.selector));
        _begin(ids);
        IAccrualMigration.Opening memory cash = _cashOpening(bytes32(0));
        IAccrualMigration.Opening memory pik = _pikOpening(bytes32(0));
        _relayOpening(cash, cutoff, carol);

        // Batch shape: out of roster order, empty, oversized.
        vm.expectRevert(invalidBatch);
        reserves.prepareContinuousAccrualMigration(abi.encode(uint8(1), abi.encode(_one(pik))));
        vm.expectRevert(invalidBatch);
        reserves.prepareContinuousAccrualMigration(abi.encode(uint8(1), abi.encode(new IAccrualMigration.Opening[](0))));
        IAccrualMigration.Opening[] memory four = new IAccrualMigration.Opening[](4);
        four[0] = cash;
        four[1] = pik;
        four[2] = _defaultOpening(bytes32(0));
        four[3] = pik;
        vm.expectRevert(invalidBatch);
        reserves.prepareContinuousAccrualMigration(abi.encode(uint8(1), abi.encode(four)));

        // Partial import: activation and cancellation both refuse; the same facility cannot be
        // imported again under a fresh approval reference.
        _import(_one(cash));
        vm.expectRevert(
            abi.encodeWithSelector(ReserveAccrualLib.ReserveAccrual_MigrationIncomplete.selector, uint32(1), uint32(3))
        );
        reserves.enableContinuousAccrual();
        vm.expectRevert(abi.encodeWithSelector(ReserveMigrationLib.AccrualMigration_CannotCancelImportedDebt.selector));
        reserves.prepareContinuousAccrualMigration(abi.encode(uint8(2), bytes("")));
        IAccrualMigration.Opening memory dup = _cashOpening(keccak256("second-approval"));
        _relayOpening(dup, cutoff, carol);
        vm.expectRevert(invalidBatch);
        reserves.prepareContinuousAccrualMigration(abi.encode(uint8(1), abi.encode(_one(dup))));
        vm.expectRevert(invalidBatch);
        reserves.prepareContinuousAccrualMigration(abi.encode(uint8(1), abi.encode(_pair(dup, pik))));
        assertEq(reserves.deployedTo(cashId), CASH_P + CASH_OPEN_INTEREST, "cash imported exactly once");
        oracle.revoke(cashId, IAttestationOracle.AttestationKind.AccrualOpening);

        // Session authentication for the PIK row: wrong asOf (past), wrong session, then a later
        // asOf after time has passed, then the genuine fact signed at the cutoff. A revoked fact is
        // a permanent tombstone (C4-02), so the mistimed genuine payload can never be re-recorded:
        // each replacement carries a fresh approvalRef, which is exactly what the field is for.
        bytes memory required =
            abi.encodeWithSelector(ReserveMigrationLib.AccrualMigration_AttestationRequired.selector, pikId);
        _relayOpening(pik, cutoff - 1, carol);
        vm.expectRevert(required);
        reserves.prepareContinuousAccrualMigration(abi.encode(uint8(1), abi.encode(_one(pik))));
        oracle.revoke(pikId, IAttestationOracle.AttestationKind.AccrualOpening);
        _relayExpecting(
            pik,
            cutoff,
            carol,
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_FactAlreadyRealised.selector,
                oracle.factKey(pikId, IAttestationOracle.AttestationKind.AccrualOpening, _scriptPayload(pik)),
                IAttestationOracle.FactStatus.Revoked
            )
        );
        _relayPayload(pikId, _foreignSessionPayload(pik), cutoff, carol);
        vm.expectRevert(required);
        reserves.prepareContinuousAccrualMigration(abi.encode(uint8(1), abi.encode(_one(pik))));
        oracle.revoke(pikId, IAttestationOracle.AttestationKind.AccrualOpening);
        _warp(1 days);
        pik = _pikOpening(keccak256("replacement-approval-2"));
        _relayOpening(pik, cutoff + 1, carol);
        vm.expectRevert(required);
        reserves.prepareContinuousAccrualMigration(abi.encode(uint8(1), abi.encode(_one(pik))));
        oracle.revoke(pikId, IAttestationOracle.AttestationKind.AccrualOpening);
        pik = _pikOpening(keccak256("replacement-approval-3"));
        _relayOpening(pik, cutoff, carol);
        _import(_one(pik));
        vm.expectRevert(
            abi.encodeWithSelector(ReserveAccrualLib.ReserveAccrual_MigrationIncomplete.selector, uint32(2), uint32(3))
        );
        reserves.enableContinuousAccrual();
        IAccrualMigration.Opening memory dflt = _defaultOpening(bytes32(0));
        _relayOpening(dflt, cutoff, carol);
        _import(_one(dflt));
        assertEq(reserves.accrualMigration().nextFacilityId, 0, "roster complete");
        reserves.enableContinuousAccrual();
        assertTrue(reserves.accrualSnapshot().enabled, "activated after the complete import");
        vm.expectRevert(abi.encodeWithSelector(ReserveAccrualLib.ReserveAccrual_AlreadyConfigured.selector));
        _begin(ids);
        _assertBacking("after a disciplined migration");
    }

    // ── A5 ────────────────────────────────────────────────────────────────

    /// @notice Attacks the cancel path: a cancelled session must leave no authority behind and a
    ///         restarted one must not accept the old session's facts.
    function test_atk_cancelledSessionBurnsItsNonceAndItsFactsNeverAuthenticateAgain() public onFork {
        _legacyBook();
        _prepare(_roster());
        IAccrualMigration.Progress memory p = reserves.accrualMigration();
        bytes32 session1 = p.sessionKey;
        IAccrualMigration.Opening memory cash1 = _cashOpening(bytes32(0));
        bytes32 oldCashPayload = _scriptPayload(cash1);
        _relayOpening(cash1, cutoff, carol);
        _relayOpening(_pikOpening(bytes32(0)), cutoff, carol);
        _relayOpening(_defaultOpening(bytes32(0)), cutoff, carol);
        vm.expectRevert(
            abi.encodeWithSelector(ReserveAccrualLib.ReserveAccrual_MigrationIncomplete.selector, uint32(0), uint32(3))
        );
        reserves.enableContinuousAccrual();

        vm.expectEmit(true, true, false, true, address(reserves));
        emit ReserveMigrationLib.AccrualMigrationCancelled(1, session1);
        reserves.prepareContinuousAccrualMigration(abi.encode(uint8(2), bytes("")));
        p = reserves.accrualMigration();
        assertFalse(p.active, "cancelled");
        assertEq(p.nonce, 1, "nonce burned, not reused");
        assertTrue(
            p.sessionKey == bytes32(0) && p.cutoff == 0 && p.expected == 0 && p.originalFace == 0
                && p.nextFacilityId == 0,
            "progress zeroed"
        );
        vm.expectRevert(
            abi.encodeWithSelector(ReserveAccrualLib.ReserveAccrual_MigrationRequired.selector, LEGACY_FACE)
        );
        reserves.enableContinuousAccrual();
        vm.expectRevert(abi.encodeWithSelector(ReserveMigrationLib.AccrualMigration_NotStarted.selector));
        reserves.prepareContinuousAccrualMigration(abi.encode(uint8(1), abi.encode(_one(cash1))));

        // The legacy engine reopens: a KYC'd mint and a legacy cash coupon receipt both settle.
        _mintFromUSDC(alice, 1_000e6);
        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        _repay(cashId, CASH_OPEN_INTEREST, 0);
        assertGt(usdfr.balanceOf(address(vault)), vaultBefore, "legacy interest routed to the vault again");
        assertEq(reserves.deployedTo(cashId), CASH_P, "legacy receipt left the face unchanged");

        // A new session: new nonce, new key, same cutoff instant is fine. The old facts are still
        // standing and block the quorum's new facts until governance revokes them; they never
        // authenticate against the new session.
        _begin(_roster());
        p = reserves.accrualMigration();
        assertEq(p.nonce, 2, "second session");
        assertTrue(p.sessionKey != session1 && p.sessionKey != bytes32(0), "fresh session key");
        IAccrualMigration.Opening memory cash2 = _cashOpening(bytes32(0));
        cash2.interest = 0; // the coupon just paid settled the accrual through the cutoff
        cash2.periodStart = cutoff;
        IAccrualMigration.Opening memory pik2 = _pikOpening(bytes32(0));
        assertTrue(_scriptPayload(cash2) != _scriptPayload(cash1), "the payload is session-bound");
        vm.expectRevert(
            abi.encodeWithSelector(ReserveMigrationLib.AccrualMigration_AttestationRequired.selector, cashId)
        );
        reserves.prepareContinuousAccrualMigration(abi.encode(uint8(1), abi.encode(_one(cash2))));
        _relayExpecting(
            cash2,
            cutoff,
            carol,
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_UnconsumedFact.selector,
                cashId,
                IAttestationOracle.AttestationKind.AccrualOpening,
                oldCashPayload
            )
        );
        oracle.revoke(cashId, IAttestationOracle.AttestationKind.AccrualOpening);
        oracle.revoke(pikId, IAttestationOracle.AttestationKind.AccrualOpening);
        oracle.revoke(dfltId, IAttestationOracle.AttestationKind.AccrualOpening);
        _relayOpening(cash2, cutoff, carol);
        _relayOpening(pik2, cutoff, carol);
        _relayOpening(_defaultOpening(bytes32(0)), cutoff, carol);
        vm.expectEmit(true, true, false, true, address(reserves));
        emit ReserveMigrationLib.AccrualOpeningImported(2, cashId, CASH_P, CASH_P, 0, 0, false, false);
        _import(_three(cash2, pik2, _defaultOpening(bytes32(0))));
        reserves.enableContinuousAccrual();
        assertTrue(reserves.accrualSnapshot().enabled, "second session activated");
        assertEq(reserves.deployedTo(cashId), CASH_P, "cash imported at face with no income");
        assertEq(reserves.deployedTo(pikId), PIK_RECORDED + PIK_OPEN_INTEREST, "PIK imported with its coupon");
        _assertBacking("after the restarted session");
    }

    // ── A6 ────────────────────────────────────────────────────────────────

    /// @notice Activates after a contractual boundary has elapsed and proves the catch-up is
    ///         exactly the contractual coupon, independent of when activation happened.
    function test_atk_delayedActivationCatchesUpToTheContractualCouponOnly() public onFork {
        _legacyBook();
        _prepare(_roster());
        IAccrualMigration.Opening memory cash = _cashOpening(bytes32(0));
        IAccrualMigration.Opening memory pik = _pikOpening(bytes32(0));
        IAccrualMigration.Opening memory dflt = _defaultOpening(bytes32(0));
        _relayOpening(cash, cutoff, carol);
        _relayOpening(pik, cutoff, carol);
        _relayOpening(dflt, cutoff, carol);
        _import(_three(cash, pik, dflt));
        uint256 supplyBefore = usdfr.totalSupply();

        // Fifty-five days pass between the last import and activation, across the PIK boundary at
        // t0 + 180 days. Financial entry stays closed throughout (the session is still active).
        _warp(55 days);
        uint64 boundary = t0 + 2 * INTERVAL;
        assertGt(block.timestamp, boundary, "the boundary has elapsed before activation");
        reserves.enableContinuousAccrual();
        IContinuousAccrual.Snapshot memory s = reserves.accrualSnapshot();
        assertTrue(s.enabled && !s.fresh, "activated but stale");
        assertEq(s.accruedThrough, boundary, "recognition is capped at the unprocessed boundary");
        bytes memory pending =
            abi.encodeWithSelector(AccrualBook.AccrualBook_BoundaryPending.selector, boundary, uint64(block.timestamp));
        vm.startPrank(alice);
        IERC20(USDC).approve(address(controller), 1_000e6);
        vm.expectRevert(pending);
        controller.mint(1_000e6);
        vm.stopPrank();
        vm.expectRevert(pending);
        reserves.materializeAccrued(3);
        _expectDistributeRevert(cashId, SCALE, 0, pending);

        // One permissionless checkpoint. The coupon is the contractual one on the frozen basis,
        // the same number A2 obtains when activation happens at the cutoff.
        (uint256 processed, bool fresh) = _checkpointAs(carol);
        assertGe(processed, 1, "boundary processed");
        assertTrue(fresh, "fresh after catch-up");
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(pikId);
        assertEq(d.principal, PIK_RECORDED + PIK_COUPON_2, "late activation capitalised exactly the contractual coupon");
        assertEq(d.nextCapitalization, t0 + 3 * INTERVAL, "cursor advanced exactly one interval");
        assertEq(usdfr.totalSupply(), supplyBefore, "catch-up minted nothing");
        _assertBacking("after catch-up");
        _mintFromUSDC(alice, 1_000e6);
        (uint256 senior, uint256 fee) = reserves.materializeAccrued(3);
        assertGt(senior + fee, OPEN_INCOME, "post-cutoff accrual was recognised too");
        assertEq(reserves.accruedDebt(dfltId).interest, DFLT_OPEN_INTEREST, "the declared default earned nothing");
        _assertBacking("after materialisation");
    }

    // ── legacy book ──────────────────────────────────────────────────────

    /// @dev Two FILM facilities funded and serviced through the LEGACY engine (no accrual binding
    ///      exists): a cash note with one paid coupon, and a PIK note with one capitalised coupon
    ///      and a later principal prepayment, so the legacy cursor basis (517,500) exceeds the
    ///      deployed face (417,500) at the cutoff, 135 days after funding.
    function _legacyBook() internal {
        assertEq(waterfall.accrualReserve(), address(0), "fixture must leave the modules unbound");
        assertFalse(reserves.accrualSnapshot().enabled, "fixture must leave the book disabled");
        _mintFromUSDC(alice, 3_000_000e6);
        _stake(alice, 2_000_000e18);
        t0 = uint64(block.timestamp);
        cashId = _originateLegacy(CASH_P, false, keccak256("legacy-cash"), true, t0);
        pikId = _originateLegacy(PIK_P, true, keccak256("legacy-pik"), true, t0);
        dfltId = _originateLegacy(DFLT_P, false, keccak256("legacy-default"), true, t0);
        assertEq(reserves.deployedTo(cashId), CASH_P, "legacy cash face");
        assertEq(reserves.deployedTo(pikId), PIK_P, "legacy PIK face");
        assertEq(reserves.deployedTo(dfltId), DFLT_P, "legacy defaulting face");

        _warp(INTERVAL);
        _repay(cashId, CASH_COUPON, 0);
        uint256 capitalised = waterfall.capitalizePik(pikId);
        assertEq(capitalised, PIK_COUPON_1, "legacy coupon on the funded principal");
        assertEq(reserves.deployedTo(pikId), PIK_BASIS, "legacy PIK face after the crank");
        _warp(30 days);
        _repay(pikId, 0, PIK_PREPAY);
        assertEq(reserves.deployedTo(pikId), PIK_RECORDED, "legacy PIK face after the prepayment");
        _declareDefault(dfltId, keccak256("legacy-default-evidence"));
        assertTrue(bridge.facility(dfltId).state == ClaimBridge.LoanState.Defaulted, "third note declared defaulted");
        assertEq(defaultManager.defaultedContribution(dfltId), DFLT_P, "declared at its recorded face");
        _warp(15 days);
        cutoff = uint64(block.timestamp);
        assertEq(cutoff, t0 + INTERVAL + 45 days, "cutoff 135 days after funding");
    }

    function _originateLegacy(uint256 principal, bool pik, bytes32 note, bool fund, uint64 start)
        internal
        returns (uint256 id)
    {
        ClaimBridge.OriginationTerms memory t = _forkTermsFor(
            FILM, keccak256("migration-borrower"), keccak256("US-GA"), principal, 7500, RATE_BPS, start + TERM, note
        );
        t.pik = pik;
        t.paymentInterval = INTERVAL;
        t.nextPaymentDue = start + INTERVAL;
        id = bridge.totalOriginated() + 1;
        bytes32 termsHash = bridge.creditTermsHash(t);
        _attest(id, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash);
        _attest(id, IAttestationOracle.AttestationKind.UCCFiled, termsHash);
        _attest(id, IAttestationOracle.AttestationKind.CreditIssued, termsHash);
        assertEq(bridge.originate(ops, t), id, "tokenId drift");
        if (fund) waterfall.fund(id, principal / SCALE);
    }

    // ── operator script ──────────────────────────────────────────────────

    function _modules() internal view returns (IContinuousAccrual.Modules memory) {
        return IContinuousAccrual.Modules({
            token: address(usdfr),
            controller: address(controller),
            vault: address(vault),
            waterfall: address(waterfall),
            bridge: address(bridge),
            registry: address(registry),
            defaultManager: address(defaultManager)
        });
    }

    function _roster() internal view returns (uint256[] memory ids) {
        ids = new uint256[](3);
        ids[0] = cashId;
        ids[1] = pikId;
        ids[2] = dfltId;
    }

    /// @dev The real operator helper, called as the administering operator.
    function _prepare(uint256[] memory ids) internal {
        ContinuousAccrualMigration.prepare(address(reserves), _modules(), ids);
    }

    /// @dev The same helper behind one external frame, so a refusal anywhere inside it reverts the
    ///      whole invocation (what a single operator transaction would do) and can be expected.
    function prepareExternal(uint256[] memory ids) external {
        require(msg.sender == address(this), "self only");
        _prepare(ids);
    }

    /// @dev An attested receipt, not yet distributed, so an expectation can bind to `distribute`.
    function _preparedReceipt(uint256 tokenId, uint256 interest, uint256 principalRepaid)
        internal
        returns (IWaterfallEngine.Payment memory p)
    {
        uint256 stableAmount = (interest + principalRepaid) / SCALE;
        deal(USDC, borrower, IERC20(USDC).balanceOf(borrower) + stableAmount);
        vm.prank(borrower);
        IERC20(USDC).approve(address(reserves), stableAmount);
        ClaimBridge.Facility memory f = bridge.facility(tokenId);
        uint64 nextDue = f.nextPaymentDue + f.paymentInterval;
        bytes32 paymentId = keccak256(abi.encode("migration-receipt", tokenId, interest, principalRepaid));
        _attest(
            tokenId,
            IAttestationOracle.AttestationKind.PaymentReceived,
            keccak256(abi.encode(paymentId, tokenId, USDC, borrower, stableAmount, interest, principalRepaid, nextDue))
        );
        p = IWaterfallEngine.Payment({
            tokenId: tokenId,
            paymentId: paymentId,
            payer: borrower,
            interest: interest,
            principal: principalRepaid,
            nextPaymentDue: nextDue
        });
    }

    /// @dev A servicer receipt refused before its attestation gate: `distribute` checks freshness
    ///      first, so no fact is needed to observe the refusal.
    function _expectDistributeRevert(uint256 tokenId, uint256 interest, uint256 principal, bytes memory err) internal {
        IWaterfallEngine.Payment memory payment = IWaterfallEngine.Payment({
            tokenId: tokenId,
            paymentId: keccak256("refused"),
            payer: borrower,
            interest: interest,
            principal: principal,
            nextPaymentDue: 0
        });
        vm.expectRevert(err);
        vm.prank(ops);
        waterfall.distribute(payment);
    }

    function _begin(uint256[] memory ids) internal {
        reserves.prepareContinuousAccrualMigration(abi.encode(uint8(0), abi.encode(ids)));
    }

    /// @dev The real operator import calldata, broadcast as the operator would broadcast it.
    function _import(IAccrualMigration.Opening[] memory openings) internal {
        bytes memory data = ContinuousAccrualMigration.importCalldata(openings);
        assertEq(bytes4(data), IAccrualMigration.prepareContinuousAccrualMigration.selector, "import selector");
        (bool ok, bytes memory ret) = address(reserves).call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    /// @dev The cash opening the legacy book implies: principal is the deployed face, interest is
    ///      the on-grid accrual from the last paid coupon to the cutoff, no PIK fields.
    function _cashOpening(bytes32 ref) internal view returns (IAccrualMigration.Opening memory) {
        return IAccrualMigration.Opening({
            facilityId: cashId,
            principal: CASH_P,
            interest: CASH_OPEN_INTEREST,
            frozenPikBasis: 0,
            periodStart: t0 + INTERVAL,
            nextCapitalization: 0,
            approvalRef: ref
        });
    }

    /// @dev The PIK opening the legacy book implies: principal is the deployed face after the
    ///      prepayment, the frozen basis is the legacy cursor basis, the period runs from the last
    ///      capitalisation to the contractual coupon date, interest is the on-grid accrual so far.
    function _pikOpening(bytes32 ref) internal view returns (IAccrualMigration.Opening memory) {
        return IAccrualMigration.Opening({
            facilityId: pikId,
            principal: PIK_RECORDED,
            interest: PIK_OPEN_INTEREST,
            frozenPikBasis: PIK_BASIS,
            periodStart: t0 + INTERVAL,
            nextCapitalization: t0 + 2 * INTERVAL,
            approvalRef: ref
        });
    }

    /// @dev The defaulted cash note: recorded face plus the missed first coupon, cursor at funding.
    function _defaultOpening(bytes32 ref) internal view returns (IAccrualMigration.Opening memory) {
        return IAccrualMigration.Opening({
            facilityId: dfltId,
            principal: DFLT_P,
            interest: DFLT_OPEN_INTEREST,
            frozenPikBasis: 0,
            periodStart: t0,
            nextCapitalization: 0,
            approvalRef: ref
        });
    }

    function _scriptPayload(IAccrualMigration.Opening memory o) internal view returns (bytes32) {
        return ContinuousAccrualMigration.openingPayload(address(reserves), o);
    }

    /// @dev The contract's own shape (ReserveMigrationLib._row and _consume), computed
    ///      independently of the script so a divergence between the two is caught here.
    function _contractPayload(IAccrualMigration.Opening memory o) internal view returns (bytes32) {
        return _payloadFor(o, reserves.accrualMigration().sessionKey);
    }

    function _foreignSessionPayload(IAccrualMigration.Opening memory o) internal view returns (bytes32) {
        return _payloadFor(o, reserves.accrualMigration().sessionKey ^ bytes32(uint256(1)));
    }

    function _payloadFor(IAccrualMigration.Opening memory o, bytes32 session) internal view returns (bytes32) {
        bytes32 record = keccak256(
            abi.encode(
                session,
                o.facilityId,
                USDC,
                reserves.deployedTo(o.facilityId),
                keccak256(abi.encode(bridge.facility(o.facilityId)))
            )
        );
        return keccak256(
            abi.encode(
                keccak256("AccrualOpening(bytes32 frozenRecord,bytes32 opening)"), record, keccak256(abi.encode(o))
            )
        );
    }

    // ── attestation relay ────────────────────────────────────────────────

    function _relayOpening(IAccrualMigration.Opening memory o, uint64 asOf, address relayer) internal {
        _relayPayload(o.facilityId, _scriptPayload(o), asOf, relayer);
    }

    /// @dev A genuine bundle whose submission is expected to be refused with `err`.
    function _relayExpecting(IAccrualMigration.Opening memory o, uint64 asOf, address relayer, bytes memory err)
        internal
    {
        _relay(o.facilityId, _scriptPayload(o), asOf, relayer, err);
    }

    function _relayPayload(uint256 facilityId, bytes32 payload, uint64 asOf, address relayer) internal {
        _relay(facilityId, payload, asOf, relayer, bytes(""));
    }

    /// @dev A genuine 2-of-n bundle over the payload, relayed by `relayer` (carol throughout).
    function _relay(uint256 facilityId, bytes32 payload, uint64 asOf, address relayer, bytes memory err) internal {
        IAttestationOracle.AttestationInput memory a = IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: IAttestationOracle.AttestationKind.AccrualOpening,
            payload: payload,
            asOf: asOf,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: ++attestationNonce
        });
        bytes32 digest = oracle.attestationDigest(a);
        (uint256 lo, uint256 hi) = vm.addr(PK1) < vm.addr(PK2) ? (PK1, PK2) : (PK2, PK1);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sig(lo, digest);
        sigs[1] = _sig(hi, digest);
        if (err.length != 0) vm.expectRevert(err);
        vm.prank(relayer);
        oracle.attest(a, sigs);
    }

    function _sig(uint256 pk, bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Attest an opening, attempt its import expecting `err`, then revoke the standing fact
    ///      so the next probe can be attested (a refused import is atomic and leaves the fact).
    function _probe(IAccrualMigration.Opening memory o, bytes memory err) internal {
        _relayOpening(o, cutoff, carol);
        vm.expectRevert(err);
        reserves.prepareContinuousAccrualMigration(abi.encode(uint8(1), abi.encode(_one(o))));
        (,, bool satisfied) = oracle.latestPayload(o.facilityId, IAttestationOracle.AttestationKind.AccrualOpening);
        assertTrue(satisfied, "refused import leaves the fact standing");
        oracle.revoke(o.facilityId, IAttestationOracle.AttestationKind.AccrualOpening);
    }

    // ── assertions and small helpers ─────────────────────────────────────

    function _assertConsumed(uint256 facilityId, bytes32 payload) internal view {
        (bytes32 recorded, uint64 asOf, bool satisfied) =
            oracle.latestPayload(facilityId, IAttestationOracle.AttestationKind.AccrualOpening);
        assertTrue(!satisfied && recorded == payload && asOf == cutoff, "opening consumed, record retained");
        assertEq(
            uint8(oracle.factStatus(facilityId, IAttestationOracle.AttestationKind.AccrualOpening, payload)),
            uint8(IAttestationOracle.FactStatus.Consumed),
            "fact ledger says consumed"
        );
    }

    function _assertLegacyCursor(string memory why) internal view {
        (uint64 lastAt, uint16 curRate) = waterfall.pikCursorOf(pikId);
        assertEq(lastAt, t0 + INTERVAL, why);
        assertEq(curRate, RATE_BPS, "legacy cursor rate");
    }

    function _assertBacking(string memory when) internal view {
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), string.concat("backing invariant ", when));
    }

    function _checkpointAs(address who) internal returns (uint256 processed, bool fresh) {
        vm.prank(who);
        return reserves.checkpointAccrual(32);
    }

    function _expectAdmin(address who) internal {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who, bytes32(0))
        );
    }

    function _one(IAccrualMigration.Opening memory o) internal pure returns (IAccrualMigration.Opening[] memory b) {
        b = new IAccrualMigration.Opening[](1);
        b[0] = o;
    }

    function _pair(IAccrualMigration.Opening memory a, IAccrualMigration.Opening memory b)
        internal
        pure
        returns (IAccrualMigration.Opening[] memory batch)
    {
        batch = new IAccrualMigration.Opening[](2);
        batch[0] = a;
        batch[1] = b;
    }

    function _three(
        IAccrualMigration.Opening memory a,
        IAccrualMigration.Opening memory b,
        IAccrualMigration.Opening memory c
    ) internal pure returns (IAccrualMigration.Opening[] memory batch) {
        batch = new IAccrualMigration.Opening[](3);
        batch[0] = a;
        batch[1] = b;
        batch[2] = c;
    }
}
