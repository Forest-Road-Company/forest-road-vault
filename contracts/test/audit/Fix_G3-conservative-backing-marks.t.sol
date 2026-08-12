// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @dev The errors and events FINDING G3 adds to `IReserveManager`, re-declared locally so this
///      whole file compiles unchanged against the PRE-FIX snapshot. That is the point: the RED
///      run recorded for this finding must be reproducible by anyone who checks out the unfixed
///      tree and runs this path. Selectors and topics are derived from name + argument types, so
///      a rename or a signature change in `IReserveManager` still fails these assertions —
///      re-declaring here costs no assertion strength. Same convention as
///      `test/audit/YieldVestingStream.t.sol`.
interface IG3 {
    event PrincipalImpairmentRecognized(
        uint256 indexed facilityId,
        uint256 amount,
        uint256 facilityImpairment,
        uint256 totalImpairment,
        uint256 backingAfter,
        bytes32 evidenceHash
    );
    event PrincipalImpairmentReleased(
        uint256 indexed facilityId,
        uint256 amount,
        uint256 facilityImpairment,
        uint256 totalImpairment,
        bytes32 evidenceHash
    );
    event PrincipalImpairmentRealized(
        uint256 indexed facilityId, uint256 amount, uint256 facilityImpairment, uint256 totalImpairment
    );

    error ReserveManager_ZeroEvidenceHash();
    error ReserveManager_ImpairmentExceedsFace(uint256 facilityId, uint256 requested, uint256 face);
    error ReserveManager_ImpairmentReleaseExceedsRecognized(uint256 facilityId, uint256 requested, uint256 recognized);
}

/// @title FINDING G3 (High) — a loss exceeding cascade capacity must still be markable
/// @notice THE DEFECT. `ReserveManager.totalBackingValue()` returned
///         `_normalize(idleUSDCUnits) + totalDeployedPrincipal` — pure FACE value — and the
///         contract had no impairment input of any kind (`grep -c impairment` returned 0).
///         `DefaultManager.realizeLoss` reverts `LossExceedsAbsorptionCapacity` BEFORE
///         `reserves.recordPrincipalWritedown`, and the revert rolls the write-down back with it.
///         Consequences, each asserted below against the pre-mark state:
///           - worthless deployed principal counted as backing indefinitely;
///           - `backingInvariantHolds()` reported TRUE against that fiction;
///           - 1:1 minting continued into an already-insolvent protocol.
///
///         THE FIX. `ReserveManager` gains a governance-only, evidence-committed
///         `recognizePrincipalImpairment` / `releasePrincipalImpairment` pair, and
///         `totalBackingValue()` is reported NET of the recognized mark — which is what
///         CLAUDE.md §1.3's "at conservative marks" has always required of the right-hand side
///         of the backing invariant, and what the implementation did not do.
///
/// @dev WRITTEN TO COMPILE AGAINST THE UNFIXED TREE, deliberately. Do not "tidy" the two
///      mutating calls into typed calls: they go through `address(reserves).call(...)` and the
///      new views through `staticcall` precisely so this file compiles on the pre-fix snapshot
///      and its RED run is reproducible. Every assertion is exact; nothing is softened.
contract Fix_G3_ConservativeBackingMarks is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    bytes32 internal constant EVIDENCE = keccak256("G3-workout-memorandum");
    bytes32 internal constant EVIDENCE_2 = keccak256("G3-recovery-memorandum");

    // ── low-level bridges to the post-fix API (see the @dev note above) ──

    function _recognize(address caller, uint256 facilityId, uint256 amount, bytes32 evidenceHash)
        internal
        returns (bool ok, bytes memory ret)
    {
        vm.prank(caller);
        (ok, ret) = address(reserves).call(
            abi.encodeWithSignature(
                "recognizePrincipalImpairment(uint256,uint256,bytes32)", facilityId, amount, evidenceHash
            )
        );
    }

    function _releaseMark(address caller, uint256 facilityId, uint256 amount, bytes32 evidenceHash)
        internal
        returns (bool ok, bytes memory ret)
    {
        vm.prank(caller);
        (ok, ret) = address(reserves).call(
            abi.encodeWithSignature(
                "releasePrincipalImpairment(uint256,uint256,bytes32)", facilityId, amount, evidenceHash
            )
        );
    }

    function _mustRecognize(uint256 facilityId, uint256 amount, bytes32 evidenceHash) internal {
        (bool ok,) = _recognize(admin, facilityId, amount, evidenceHash);
        assertTrue(ok, "G3: ReserveManager has no conservative-mark input");
    }

    function _mustRelease(uint256 facilityId, uint256 amount, bytes32 evidenceHash) internal {
        (bool ok,) = _releaseMark(admin, facilityId, amount, evidenceHash);
        assertTrue(ok, "G3: ReserveManager has no impairment-release input");
    }

    function _totalImpairment() internal view returns (uint256) {
        (bool ok, bytes memory ret) =
            address(reserves).staticcall(abi.encodeWithSignature("totalPrincipalImpairment()"));
        assertTrue(ok && ret.length == 32, "G3: totalPrincipalImpairment() view is missing");
        return abi.decode(ret, (uint256));
    }

    function _impairmentOf(uint256 facilityId) internal view returns (uint256) {
        (bool ok, bytes memory ret) =
            address(reserves).staticcall(abi.encodeWithSignature("principalImpairmentOf(uint256)", facilityId));
        assertTrue(ok && ret.length == 32, "G3: principalImpairmentOf() view is missing");
        return abi.decode(ret, (uint256));
    }

    function _selectorOf(bytes memory ret) internal pure returns (bytes4 sel) {
        require(ret.length >= 4, "G3: revert carried no selector");
        assembly {
            sel := mload(add(ret, 32))
        }
    }

    // ── scenario builders ────────────────────────────────────────────────

    function _stakeVault(address who, uint256 amount) internal {
        _mintUSDfrTo(who, amount);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
    }

    /// @dev A facility whose loss CANNOT be absorbed: 300k outstanding against 1k of curator
    ///      first-loss, no backstop capital and 1k of staked senior principal. This is the exact
    ///      state `test/unit/DefaultManager.t.sol::test_realizeLoss_beyondAllLayersRevertsLoudly`
    ///      pins — that test proves the revert; this file proves the state is now markable.
    function _unabsorbableDefault() internal returns (uint256 id) {
        _postFirstLoss(anchorCurator, FILM, 1_000e18);
        _stakeVault(alice, 1_000e18);
        id = _liveFilmFacility(300_000e18);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
    }

    // ── 1. the defect, and its closure ───────────────────────────────────

    /// @notice G3 CORE. Worthless principal beyond cascade capacity can be marked down, and
    ///         backing falls by exactly the mark while the FACE ledger is left intact.
    function test_G3_unabsorbableLossCanBeMarkedDownAndBackingFalls() public {
        uint256 id = _unabsorbableDefault();

        // The cascade genuinely cannot take it: 300k loss, 1k curator + 0 backstop + 1k senior.
        _attestLoss(id, 300_000e18, FILM_REF);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_LossExceedsAbsorptionCapacity.selector, id, 299_000e18, 1_000e18
            )
        );
        vm.prank(servicer);
        defaultManager.realizeLoss(id, 300_000e18, FILM_REF);

        // PRE-MARK: the fiction. Face value, invariant "holds", protocol open for business.
        uint256 idle = reserves.idleReserve();
        assertEq(reserves.deployedTo(id), 300_000e18, "the worthless claim is still carried at face");
        assertEq(reserves.totalBackingValue(), idle + 300_000e18, "backing is face value");
        assertTrue(controller.backingInvariantHolds(), "pre-mark, the invariant reports true");

        // THE MARK. Governance adjudicates zero recovery on the whole claim.
        _mustRecognize(id, 300_000e18, EVIDENCE);

        assertEq(_impairmentOf(id), 300_000e18, "facility mark not recorded");
        assertEq(_totalImpairment(), 300_000e18, "aggregate mark not recorded");
        assertEq(reserves.deployedPrincipal(), 300_000e18, "a mark must NOT move the face ledger");
        assertEq(reserves.deployedTo(id), 300_000e18, "a mark must NOT move per-facility face");
        assertEq(reserves.totalBackingValue(), idle, "backing did not fall by the mark");
        assertFalse(controller.backingInvariantHolds(), "the invariant must now report the truth");
    }

    /// @notice The point of the whole finding: 1:1 minting must STOP once the mark is recognized.
    function test_G3_mintingHaltsOnceTheShortfallIsRecognized() public {
        uint256 id = _unabsorbableDefault();

        // Pre-mark: a fresh depositor mints 1:1 into an already-insolvent protocol. The defect.
        usdc.mint(bob, 10_000e6);
        vm.startPrank(bob);
        usdc.approve(address(controller), 10_000e6);
        controller.mint(10_000e6);
        vm.stopPrank();
        assertEq(usdfr.balanceOf(bob), 10_000e18, "pre-mark mint is unobstructed (the defect)");

        _mustRecognize(id, 300_000e18, EVIDENCE);

        usdc.mint(bob, 10_000e6);
        vm.startPrank(bob);
        usdc.approve(address(controller), 10_000e6);
        // AUDIT NOTE (R16-M3): the ERROR changed and the behaviour did not. Minting is still
        // refused; it is now refused BEFORE the deposit is taken, and it names the standing
        // condition (`supply > backing` at the moment of refusal) instead of reporting a
        // hypothetical post-mint state. The old form reported the invariant "violated" at
        // (supply+10k, backing+10k) — numbers that describe a state the transaction never
        // reached, in a protocol that was ALREADY under-backed before the call.
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_MintClosedWhileUnderBacked.selector,
                usdfr.totalSupply(),
                reserves.totalBackingValue()
            )
        );
        controller.mint(10_000e6);
        vm.stopPrank();
    }

    /// @notice Every dollar of gap between supply and backing is a dollar of RECOGNIZED,
    ///         evented mark — never more. Silent unbacking stays impossible.
    function test_G3_recognizedShortfallEqualsTheUnabsorbableRemainder() public {
        uint256 id = _unabsorbableDefault();
        uint256 slack = reserves.totalBackingValue() - usdfr.totalSupply();

        _mustRecognize(id, 300_000e18, EVIDENCE);

        uint256 gap = usdfr.totalSupply() - reserves.totalBackingValue();
        assertEq(gap, 300_000e18 - slack, "the gap is not the mark net of pre-existing slack");
        assertLe(gap, _totalImpairment(), "a gap larger than the recognized mark is unexplained unbacking");
    }

    // ── 2. no double count: the mark and the realized write-down ────────

    /// @notice A realized write-down on an already-marked facility must NOT drop backing twice.
    ///         The write-down lowers face; the mark that sat on that face is consumed with it.
    /// @dev The curator pool here (300k) exceeds the mark (100k), so the layer-1 burn closes the
    ///      recognized shortfall before `MintRedeemController._assertBacking` runs — which is
    ///      exactly how a marked facility is worked out on-chain.
    function test_G3_writeDownOfAMarkedFacilityLeavesBackingFlat() public {
        _postFirstLoss(anchorCurator, FILM, 300_000e18);
        uint256 id = _liveFilmFacility(300_000e18);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        _mustRecognize(id, 100_000e18, EVIDENCE);
        uint256 backingAfterMark = reserves.totalBackingValue();
        assertFalse(controller.backingInvariantHolds(), "the mark must open the shortfall it recognizes");

        _attestLoss(id, 100_000e18, FILM_REF);
        vm.prank(servicer);
        defaultManager.realizeLoss(id, 100_000e18, FILM_REF);

        assertEq(_impairmentOf(id), 0, "the realized write-down did not consume the mark");
        assertEq(_totalImpairment(), 0, "the aggregate mark did not fall with the write-down");
        assertEq(reserves.deployedTo(id), 200_000e18, "face did not fall by the realized loss");
        assertEq(reserves.totalBackingValue(), backingAfterMark, "backing moved TWICE for one dollar of loss");
        assertTrue(controller.backingInvariantHolds(), "burning the junior layer did not close the shortfall");
    }

    /// @notice ═══ INVERTED (SWEEP-1 RMDM-F2, 2026-08-08) — DO NOT RESTORE THE OLD ASSERTIONS ═══
    ///         The predecessor of this test, `test_G3_cashRecoveryOnAMarkedFacilityConsumesTheMark`,
    ///         ASSERTED THE OPTIMISTIC CONVENTION AS A SAFETY PROPERTY, at the point of maximal
    ///         divergence (mark == recovery): it required a 120,000 cash collection to retire a
    ///         120,000 governance mark in full and RAISE `totalBackingValue()` by 120,000 —
    ///         returning the facility to its pre-mark carrying value with no adjudication, no
    ///         evidence hash and no governance transaction. That is the defect, written down as
    ///         though it were the cure, which is the most dangerous kind of test because it makes
    ///         fixing the bug look like a regression.
    ///
    ///         WHY THE OLD CONVENTION WAS WRONG. `recognizePrincipalImpairment`'s own parameter is
    ///         documented as "Additional UNRECOVERABLE face principal", and cash arriving is
    ///         definitionally RECOVERABLE face. A mark of M against face F asserts expected
    ///         recovery F - M; collecting C leaves expected recovery F - M - C against face F - C,
    ///         so the mark on what remains is still M and BACKING IS FLAT. The old rule overstated
    ///         `totalBackingValue()` — the right-hand side of the CLAUDE.md §1.3 backing invariant —
    ///         by up to `min(cash principal, mark)`, and `backingInvariantHolds()` could flip true
    ///         against it, reopening 1:1 minting against value governance had evidenced as gone.
    ///
    ///         WHAT G3 STILL GUARANTEES, and is asserted below: the mark may never STRAND above
    ///         face that no longer exists (the H-2 bug class on the backing side). The narrowed
    ///         release in `ReserveManager.recordPayment` delivers exactly that and nothing more.
    ///
    /// @dev    MUTATION: widen `recordPayment` back to
    ///         `_consumeImpairmentOnFaceDecrease($, facilityId, principal)` -> this test goes RED
    ///         on "SWEEP-1: ordinary collection retired an evidenced mark".
    function test_G3_cashRecoveryOnAMarkedFacilityDoesNotConsumeTheMark() public {
        _postFirstLoss(anchorCurator, FILM, 1_000e18);
        uint256 id = _liveFilmFacility(300_000e18);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        _mustRecognize(id, 120_000e18, EVIDENCE);
        uint256 backingAfterMark = reserves.totalBackingValue();

        // 120k of principal is actually collected in the workout. It is ACCEPTED — the R17-01
        // liveness property — and it moves cash from receivable into idle.
        _repay(id, 0, 120_000e18);

        assertEq(reserves.deployedTo(id), 180_000e18, "face did not fall by the cash principal");
        assertEq(_impairmentOf(id), 120_000e18, "SWEEP-1: ordinary collection retired an evidenced mark");
        assertEq(_totalImpairment(), 120_000e18, "SWEEP-1: the aggregate mark followed the face down");
        assertEq(reserves.totalBackingValue(), backingAfterMark, "collecting cash silently repaired reported backing");
        assertFalse(controller.backingInvariantHolds(), "a collection cannot close a shortfall governance still marks");

        // THE EVIDENCED PATH IS WHAT CLOSES IT. If the workout genuinely recovered more than the
        // mark expected, governance says so with a fresh evidence hash — and only then does
        // backing rise. The mark is not a ratchet; it is just not reversible by accident.
        _mustRelease(id, 120_000e18, EVIDENCE_2);
        assertEq(_impairmentOf(id), 0, "the evidenced release did not retire the mark");
        assertEq(
            reserves.totalBackingValue(), backingAfterMark + 120_000e18, "the evidenced release did not repair backing"
        );
        assertTrue(controller.backingInvariantHolds(), "the evidenced release did not close the shortfall");
    }

    /// @notice ANTI-STRANDING, THE HALF OF G3 THAT DID NOT CHANGE. A collection that takes face
    ///         BELOW the standing mark still releases exactly the excess, so
    ///         `principalImpairment[f] <= deployed[f]` holds on every path and `_backingValue()`
    ///         can never underflow.
    /// @dev MUTATION: delete the `if (recognized > newFace)` release in `recordPayment` -> RED here.
    function test_G3_aCollectionBelowTheMarkStillCannotStrandIt() public {
        uint256 id = _liveFilmFacility(300_000e18);
        _mustRecognize(id, 200_000e18, EVIDENCE);
        uint256 backingAfterMark = reserves.totalBackingValue();

        _repay(id, 0, 180_000e18); // face 300k -> 120k; 80k of the 200k mark would strand

        assertEq(reserves.deployedTo(id), 120_000e18, "face");
        assertEq(_impairmentOf(id), 120_000e18, "the mark is clamped to the new face, exactly");
        assertEq(reserves.totalBackingValue(), backingAfterMark + 80_000e18, "the release was not the stranded excess");
    }

    /// @notice Cash recovery cannot silently erase a governance-adjudicated impairment.
    /// @dev This exercises ReserveManager's primitive directly, independently of Waterfall's
    ///      non-worsening collection gate covered by the W7 regression above.
    function test_H1_cashRepaymentCannotEraseTheAdjudicatedImpairment() public {
        _postFirstLoss(anchorCurator, FILM, 1_000e18);
        uint256 id = _liveFilmFacility(300_000e18);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        _mustRecognize(id, 120_000e18, EVIDENCE);
        uint256 backingAfterMark = reserves.totalBackingValue();

        vm.prank(admin);
        reserves.grantRole(Roles.CREDIT_ROLE, address(this));
        usdc.mint(borrower, 120_000e6);
        vm.prank(borrower);
        usdc.approve(address(reserves), 120_000e6);
        reserves.recordPayment(id, borrower, 120_000e6, 120_000e18);

        assertEq(_impairmentOf(id), 120_000e18, "cash silently erased the facility mark");
        assertEq(_totalImpairment(), 120_000e18, "cash silently erased the aggregate mark");
        assertEq(reserves.deployedTo(id), 180_000e18, "face did not fall by the cash principal");
        assertEq(reserves.totalBackingValue(), backingAfterMark, "cash changed the adjudicated valuation");
        assertFalse(controller.backingInvariantHolds(), "cash reopened par exits without governance evidence");
    }

    /// @notice A repayment releases only the portion of a mark that cannot fit beneath remaining face.
    function test_H1_cashRepaymentOnlyClampsMarkAboveRemainingFace() public {
        uint256 id = _unabsorbableDefault();
        _mustRecognize(id, 250_000e18, EVIDENCE);
        uint256 backingAfterMark = reserves.totalBackingValue();

        vm.prank(admin);
        reserves.grantRole(Roles.CREDIT_ROLE, address(this));
        usdc.mint(borrower, 100_000e6);
        vm.prank(borrower);
        usdc.approve(address(reserves), 100_000e6);
        reserves.recordPayment(id, borrower, 100_000e6, 100_000e18);

        assertEq(reserves.deployedTo(id), 200_000e18, "remaining face mismatch");
        assertEq(_impairmentOf(id), 200_000e18, "mark was not clamped exactly to remaining face");
        assertEq(_totalImpairment(), 200_000e18, "aggregate clamp mismatch");
        assertEq(reserves.totalBackingValue(), backingAfterMark + 50_000e18, "clamp changed backing incorrectly");
    }

    /// @notice The mark can never exceed the face it qualifies, on any path.
    function test_G3_markCanNeverExceedTheFaceItQualifies() public {
        uint256 id = _unabsorbableDefault();

        (bool ok, bytes memory ret) = _recognize(admin, id, 300_000e18 + 1, EVIDENCE);
        assertFalse(ok, "a mark above face was accepted");
        assertEq(_selectorOf(ret), IG3.ReserveManager_ImpairmentExceedsFace.selector, "wrong error above face");

        _mustRecognize(id, 200_000e18, EVIDENCE);
        (ok, ret) = _recognize(admin, id, 100_000e18 + 1, EVIDENCE);
        assertFalse(ok, "cumulative marks above face were accepted");
        assertEq(
            _selectorOf(ret), IG3.ReserveManager_ImpairmentExceedsFace.selector, "wrong error above cumulative face"
        );

        _mustRecognize(id, 100_000e18, EVIDENCE); // exactly to face is allowed
        assertEq(_impairmentOf(id), 300_000e18, "an exact-to-face mark was not recorded");
    }

    // ── 3. reversal is bounded and evidenced ─────────────────────────────

    /// @notice A release restores backing but can never push it above face. The ceiling is the
    ///         pre-fix behaviour, so reversal can never make the report worse than it ever was.
    function test_G3_releaseIsBoundedByWhatWasRecognized() public {
        uint256 id = _unabsorbableDefault();
        _mustRecognize(id, 300_000e18, EVIDENCE);

        (bool ok, bytes memory ret) = _releaseMark(admin, id, 300_000e18 + 1, EVIDENCE_2);
        assertFalse(ok, "a release above the recognized mark was accepted");
        assertEq(
            _selectorOf(ret),
            IG3.ReserveManager_ImpairmentReleaseExceedsRecognized.selector,
            "wrong error for an over-release"
        );

        uint256 idle = reserves.idleReserve();
        _mustRelease(id, 120_000e18, EVIDENCE_2);
        assertEq(_impairmentOf(id), 180_000e18, "release did not lower the facility mark");
        assertEq(reserves.totalBackingValue(), idle + 120_000e18, "release did not restore exactly its own amount");

        _mustRelease(id, 180_000e18, EVIDENCE_2);
        assertEq(_totalImpairment(), 0, "a full release did not clear the mark");
        assertEq(reserves.totalBackingValue(), idle + 300_000e18, "backing did not return to face");
        assertTrue(controller.backingInvariantHolds(), "clearing the mark did not reopen the invariant");
    }

    // ── 4. access control and input validation ───────────────────────────

    function test_G3_recognizeIsGovernanceOnly() public {
        uint256 id = _unabsorbableDefault();
        (bool ok, bytes memory ret) = _recognize(servicer, id, 1e18, EVIDENCE);
        assertFalse(ok, "a servicer could mark down backing");
        assertEq(
            _selectorOf(ret), IAccessControl.AccessControlUnauthorizedAccount.selector, "wrong error for a servicer"
        );

        // RESERVE_ADMIN_ROLE is deliberately NOT enough: a valuation act, not treasury ops.
        vm.prank(admin);
        reserves.grantRole(Roles.RESERVE_ADMIN_ROLE, servicer);
        (ok, ret) = _recognize(servicer, id, 1e18, EVIDENCE);
        assertFalse(ok, "RESERVE_ADMIN_ROLE could mark down backing");
        assertEq(
            _selectorOf(ret), IAccessControl.AccessControlUnauthorizedAccount.selector, "wrong error for reserve admin"
        );
    }

    function test_G3_releaseIsGovernanceOnly() public {
        uint256 id = _unabsorbableDefault();
        _mustRecognize(id, 1_000e18, EVIDENCE);
        (bool ok, bytes memory ret) = _releaseMark(admin, id, 1_000e18, EVIDENCE_2);
        assertTrue(ok, "governance could not release its own mark");

        _mustRecognize(id, 1_000e18, EVIDENCE);
        (ok, ret) = _releaseMark(servicer, id, 1_000e18, EVIDENCE_2);
        assertFalse(ok, "a servicer could restore backing");
        assertEq(
            _selectorOf(ret), IAccessControl.AccessControlUnauthorizedAccount.selector, "wrong error for a servicer"
        );
    }

    function test_G3_zeroAmountAndZeroEvidenceAreRejected() public {
        uint256 id = _unabsorbableDefault();

        (bool ok, bytes memory ret) = _recognize(admin, id, 0, EVIDENCE);
        assertFalse(ok, "a zero mark was accepted");
        assertEq(_selectorOf(ret), IReserveManager.ReserveManager_ZeroAmount.selector, "wrong error for a zero mark");

        (ok, ret) = _recognize(admin, id, 1e18, bytes32(0));
        assertFalse(ok, "an unevidenced mark was accepted");
        assertEq(_selectorOf(ret), IG3.ReserveManager_ZeroEvidenceHash.selector, "wrong error, unevidenced mark");

        _mustRecognize(id, 1e18, EVIDENCE);
        (ok, ret) = _releaseMark(admin, id, 0, EVIDENCE_2);
        assertFalse(ok, "a zero release was accepted");
        assertEq(_selectorOf(ret), IReserveManager.ReserveManager_ZeroAmount.selector, "wrong error for a zero release");

        (ok, ret) = _releaseMark(admin, id, 1e18, bytes32(0));
        assertFalse(ok, "an unevidenced release was accepted");
        assertEq(_selectorOf(ret), IG3.ReserveManager_ZeroEvidenceHash.selector, "wrong error, unevidenced release");
    }

    /// @notice A mark against a facility with no deployed face is rejected, so the aggregate can
    ///         never drift away from the sum of the per-facility marks.
    function test_G3_markOnAnUnknownFacilityIsRejected() public {
        _unabsorbableDefault();
        (bool ok, bytes memory ret) = _recognize(admin, 99_999, 1e18, EVIDENCE);
        assertFalse(ok, "a mark against no face was accepted");
        assertEq(_selectorOf(ret), IG3.ReserveManager_ImpairmentExceedsFace.selector, "wrong error, no face");
    }

    // ── 5. events (the register must be reconstructable, CLAUDE.md §3.1) ─

    function test_G3_recognizeAndReleaseAreEvented() public {
        uint256 id = _unabsorbableDefault();
        uint256 idle = reserves.idleReserve();

        vm.expectEmit(true, false, false, true, address(reserves));
        emit IG3.PrincipalImpairmentRecognized(id, 300_000e18, 300_000e18, 300_000e18, idle, EVIDENCE);
        _mustRecognize(id, 300_000e18, EVIDENCE);

        vm.expectEmit(true, false, false, true, address(reserves));
        emit IG3.PrincipalImpairmentReleased(id, 120_000e18, 180_000e18, 180_000e18, EVIDENCE_2);
        _mustRelease(id, 120_000e18, EVIDENCE_2);
    }

    function test_G3_realizedConsumptionIsEvented() public {
        _postFirstLoss(anchorCurator, FILM, 300_000e18);
        uint256 id = _liveFilmFacility(300_000e18);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        _mustRecognize(id, 100_000e18, EVIDENCE);

        _attestLoss(id, 100_000e18, FILM_REF);
        vm.expectEmit(true, false, false, true, address(reserves));
        emit IG3.PrincipalImpairmentRealized(id, 100_000e18, 0, 0);
        vm.prank(servicer);
        defaultManager.realizeLoss(id, 100_000e18, FILM_REF);
    }

    // ── 6. residual risk, PINNED rather than left implicit ───────────────

    /// @notice DOCUMENTED LIMITATION, asserted so it cannot be discovered in production. While a
    ///         recognized shortfall is larger than the backing a single collection restores, the
    ///         waterfall's LEVEL check (`WaterfallEngine.distribute`'s closing
    ///         `backingInvariantHolds()` gate) refuses the collection. That gate asks "does the
    ///         invariant hold now?", not "did this operation make the shortfall worse?" — the
    ///         same level-vs-monotonicity gap that governs the C-01 residual-deficit state, and
    ///         it belongs to that workstream. The workout order this fix supports is therefore:
    ///         release the mark, collect/realize, re-mark whatever remains unrecoverable.
    ///         DO NOT DELETE this test to make a future change look greener — if the gate becomes
    ///         a non-worsening check, invert it and say so.
    /// @notice AUDIT FIX (R16-M4/M5) — THIS TEST IS INVERTED ON PURPOSE, AND THE INVERSION IS
    ///         THE FIX. It was called
    ///         `test_G3_collectionIsBlockedWhileTheShortfallExceedsWhatItRepairs` and it asserted
    ///         that a defaulted borrower's 120,000 cash principal repayment REVERTED with
    ///         `Waterfall_BackingWouldBreak`, then documented an "escape": governance releases
    ///         the whole conservative mark, collects, and re-marks the residual — three
    ///         timelocked transactions and a window in which the protocol's published backing is
    ///         knowingly overstated, all to accept money a borrower was trying to hand back.
    ///
    ///         That was the M4/M5 defect in its purest form. `distribute` hard-gated on the
    ///         ABSOLUTE `backingInvariantHolds()`, so once ANY loss was recognised the repayment
    ///         path shut down entirely — including repayments that strictly REPAIR backing. The
    ///         gate is now non-worsening, so the collection goes straight through and the escape
    ///         is not needed.
    function test_G3_collectionIsAcceptedWhileTheProtocolIsShortBecauseItRepairsBacking() public {
        _postFirstLoss(anchorCurator, FILM, 1_000e18);
        uint256 id = _liveFilmFacility(300_000e18);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        _mustRecognize(id, 300_000e18, EVIDENCE);
        uint256 backingBefore = reserves.totalBackingValue();
        uint256 deficitBefore = controller.backingDeficit();
        assertGt(deficitBefore, 0, "the scenario must actually be under-backed, else it proves nothing");

        IWaterfallEngine.Payment memory payment = _preparePayment(id, 0, 120_000e18);
        vm.prank(servicer);
        waterfall.distribute(payment);

        assertEq(reserves.deployedTo(id), 180_000e18, "the collection did not land");
        assertEq(reserves.totalBackingValue(), backingBefore + 120_000e18, "cash back did not repair backing");
        assertEq(controller.backingDeficit(), deficitBefore - 120_000e18, "the hole did not shrink by the cash");
        assertEq(reserves.totalBackingValue(), reserves.idleReserve(), "the residual mark did not survive");
    }

    // ── 7. the fuzzed identity ───────────────────────────────────────────

    /// @notice For any admissible mark, backing is exactly face minus the mark, the face ledger
    ///         is untouched, and the mark never exceeds the face it qualifies.
    function testFuzz_G3_backingIsFaceMinusTheMark(uint256 mark) public {
        uint256 id = _unabsorbableDefault();
        uint256 idle = reserves.idleReserve();
        mark = bound(mark, 1, 300_000e18);

        _mustRecognize(id, mark, EVIDENCE);

        assertEq(reserves.deployedPrincipal(), 300_000e18, "a mark moved the face ledger");
        assertEq(reserves.totalBackingValue(), idle + 300_000e18 - mark, "backing is not face minus the mark");
        assertLe(_totalImpairment(), reserves.deployedPrincipal(), "the mark exceeded the face it qualifies");
    }
}
