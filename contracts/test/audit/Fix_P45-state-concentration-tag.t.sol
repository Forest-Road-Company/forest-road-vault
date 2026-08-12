// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {Config} from "../../src/libraries/Config.sol";
import {RealOracleFixture} from "../helpers/RealOracleFixture.sol";

/// @title P-45 discriminator — `stateId` is optional and unvalidated, so a tax-credit origination
///        escapes the per-state concentration limit entirely by omitting the tag.
///
/// @dev WRITTEN BY THE AUDIT STREAM, NOT BY THE STREAM THAT FIXES IT. **Do not edit to match a fix.**
///
///      ── REVISION 2026-08-11, and why ──────────────────────────────────────────────────────────
///      The first version of this file asserted the CONSEQUENCE: two untagged originations exceeding
///      the state limit. Codex correctly identified that as a specification conflict — under strict
///      "non-zero for tax-credit classes" enforcement the FIRST untagged origination is refused, so
///      that test could never reach its assertion. **They flagged it rather than editing it, which is
///      the right call and the reason this revision exists.**
///
///      This version asserts the RULE instead, which is what is actually specified. The bypass is why
///      the rule matters, not what the rule says.
///
///      ── THE SPEC, FROM THE CODE ITSELF ────────────────────────────────────────────────────────
///      `ClaimBridge.sol:67` declares the field as:
///          bytes32 stateId; // US state key for tax-credit classes (zero elsewhere)
///      So the invariant is **non-zero for tax-credit classes, zero elsewhere**. Neither half is
///      enforced. This is not a policy decision — the rule is already written down.
///
///      ── THE MECHANISM ─────────────────────────────────────────────────────────────────────────
///      `CollateralRegistry._checkConcentration` puts the ENTIRE per-state limb behind a zero check,
///      and `recordExposureIncrease` only accumulates `$.stateExp[stateId]` when the tag is non-zero.
///      So a zero tag does not fail the check — **it skips both the accumulation and the check**, and
///      the exposure becomes invisible to the state dimension rather than being measured against it.
///
///      MEASURED on the pre-fix tree: with the state limit isolated to 1%, two untagged originations
///      totalling 400,000e18 in a tax-credit class both succeeded, against a 250,000e18 threshold —
///      the same pair tagged is refused. CLAUDE.md §1.3 lists concentration limits as a system
///      invariant, so this is a BYPASS, not a coverage gap.
///
///      ── HOW TO READ THIS FILE ─────────────────────────────────────────────────────────────────
///      Two-sided by construction:
///        - `test_P45_untaggedOriginationInATaxCreditClassIsRefused` REDs pre-fix, GREENs post-fix.
///        - the THREE controls GREEN on BOTH trees. In particular
///          `..._anUntaggedOriginationOutsideTaxCreditClassesStillSucceeds` exists so the fix cannot
///          be "reject every zero tag" — that would break the "zero elsewhere" half of the same rule.
///
///      The discriminator is MECHANISM-AGNOSTIC: a low-level call asserting only that origination
///      fails, because the remedy may reject at the bridge or at the registry. Any correct fix passes.
contract FixP45StateConcentrationTagTest is RealOracleFixture {
    /// @dev 1% of the 25,000,000e18 floor = 250,000e18 of state exposure before the limit binds.
    ///      Isolation only: at launch defaults the BORROWER limit (1,500 bps) binds before the STATE
    ///      limit (2,500 bps), which would mask the axis under test. Nothing else is altered.
    uint16 internal constant ISOLATED_STATE_LIMIT_BPS = 100;
    uint256 internal constant HALF = 200_000e18;

    function setUp() public virtual override {
        super.setUp();
        vm.prank(admin);
        registry.setStateLimit(ISOLATED_STATE_LIMIT_BPS);
    }

    // ── controls: green on BOTH trees ────────────────────────────────────

    /// @notice PRECONDITION. A correctly tagged origination inside the limit succeeds.
    function test_P45_control_aTaggedOriginationWithinTheLimitSucceeds() public {
        _originateFilm(BORROWER_1, STATE_GA, HALF);
    }

    /// @notice CONTROL. Correctly tagged, the per-state limit BINDS — with the exact error and its
    ///         exact arguments, so this proves the STATE dimension binds and not the class or
    ///         borrower one.
    function test_P45_control_theStateLimitBindsWhenTagged() public {
        _originateFilm(BORROWER_1, STATE_GA, HALF);

        // Attest first, then expect the revert on `originate` itself — `_originateFilm` makes several
        // calls, so `vm.expectRevert` before it would bind to the first attestation.
        uint256 nextId = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + 365 days);
        _attestFilmGate(nextId, BORROWER_2, STATE_GA, HALF, FILM_LTV_BPS, FILM_RATE_BPS, maturity, FILM_REF);
        ClaimBridge.OriginationTerms memory terms = _facilityTerms(
            Config.CLASS_FILM_TAX_CREDITS, BORROWER_2, STATE_GA, HALF, FILM_LTV_BPS, FILM_RATE_BPS, maturity, FILM_REF
        );

        vm.prank(originator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralRegistry.Registry_StateConcentrationExceeded.selector,
                STATE_GA,
                2 * HALF,
                ISOLATED_STATE_LIMIT_BPS
            )
        );
        bridge.originate(custodian, terms);
    }

    /// @notice CONTROL — THE OTHER HALF OF THE RULE. Outside the tax-credit classes the tag is
    ///         SUPPOSED to be zero ("zero elsewhere"), so an untagged origination there must keep
    ///         working. This exists so the fix cannot be "refuse every zero tag", which would satisfy
    ///         the discriminator while breaking the specification it is enforcing.
    function test_P45_control_anUntaggedOriginationOutsideTaxCreditClassesStillSucceeds() public {
        _originateDigital(HALF, HALF * 4); // 25% LTV, well inside DIGITAL_LTV_BPS (5000)
    }

    // ── the discriminator ────────────────────────────────────────────────

    /// @notice THE FINDING, stated as the rule. A tax-credit-class origination with no state tag is
    ///         invisible to the per-state limit, so it must be refused at origination.
    ///
    ///         REDs pre-fix — today it simply succeeds. GREENs once the tag is validated.
    function test_P45_untaggedOriginationInATaxCreditClassIsRefused() public {
        uint256 nextId = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + 365 days);

        // Attest the full gate for an UNTAGGED film facility, so the only thing that can refuse the
        // call is the tag rule itself rather than a missing attestation.
        _attestFilmGate(nextId, BORROWER_1, bytes32(0), HALF, FILM_LTV_BPS, FILM_RATE_BPS, maturity, FILM_REF);
        ClaimBridge.OriginationTerms memory terms = _facilityTerms(
            Config.CLASS_FILM_TAX_CREDITS, BORROWER_1, bytes32(0), HALF, FILM_LTV_BPS, FILM_RATE_BPS, maturity, FILM_REF
        );

        vm.prank(originator);
        (bool ok,) = address(bridge).call(abi.encodeCall(ClaimBridge.originate, (custodian, terms)));

        assertFalse(ok, "an untagged origination in a tax-credit class was accepted, escaping the per-state limit");
    }
}
