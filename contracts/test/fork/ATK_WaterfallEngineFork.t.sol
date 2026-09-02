// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title ATK_WaterfallEngineFork — adversarial attacks on WaterfallEngine against the FULL
///        protocol on a pinned mainnet fork with REAL USDC.
///
/// @notice This suite does not document the engine, it tries to BREAK the three invariants it must
///         hold (CLAUDE.md §1.3):
///           I1. every repayment is fully and correctly allocated (no double-claim, no leak);
///           I2. the senior claim is never subordinated to junior / out-of-cascade capital;
///           I3. a facility is funded ONLY at its exact principal.
///
///         Attacks attempted (each outcome is made unambiguous — a successful exploit asserts the
///         violated state, a correct block asserts the specific custom error / withholding state):
///           A1. `fund` at any amount other than the exact principal (under and over) — I3.
///           A2. reach `fund`/`distribute`/governance from unprivileged / hostile actors.
///           A3. double-fund an already-Active facility (deploy principal twice) — I3.
///           A4. distribute interest while a declared default leaves a senior residual, trying to
///               pay the out-of-cascade protocol-fee recipient ahead of the senior layer — I2.
///           A5. replay one attested receipt twice to double-claim yield — I1.
contract ATK_WaterfallEngineForkTest is ForkLifecycleFixture {
    /// @dev Declared locally so `vm.expectEmit` matches the real emission by signature (topic0);
    ///      identical canonical signature to `IWaterfallEngine.ProtocolFeeWithheldForSeniorImpairment`.
    event ProtocolFeeWithheldForSeniorImpairment(uint256 withheld, uint256 seniorImpairment);

    // ─────────────────────────────────────────────────────────────────────
    // A1 — I3: a facility can only be funded at its EXACT principal
    // ─────────────────────────────────────────────────────────────────────
    function test_atk_fundRejectsAnyPrincipalOtherThanExact() public onFork {
        uint256 principal = 1_000_000e18;
        _mintFromUSDC(alice, 5_000_000e6); // seed idle reserve liquidity to draw from
        uint256 tokenId = _originatePendingFilm(principal);

        uint256 exactUnits = principal / 1e12; // 1,000,000 USDC (6-dec)

        // ATTACK: underfund by one whole USDC unit — would deploy < principal against a full claim.
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWaterfallEngine.Waterfall_PrincipalMismatch.selector, tokenId, principal, principal - 1e12
            )
        );
        waterfall.fund(tokenId, exactUnits - 1);

        // ATTACK: overfund by one whole USDC unit — would deploy > principal.
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWaterfallEngine.Waterfall_PrincipalMismatch.selector, tokenId, principal, principal + 1e12
            )
        );
        waterfall.fund(tokenId, exactUnits + 1);

        // Both blocked — the facility is untouched and nothing left the treasury.
        assertEq(
            uint256(bridge.facility(tokenId).state),
            uint256(ClaimBridge.LoanState.Pending),
            "facility stays Pending after both rejected funds"
        );
        assertEq(reserves.deployedTo(tokenId), 0, "a rejected fund deploys nothing");

        // Legitimate exact fund — conservation must hold to the wei.
        uint256 feeBps = waterfall.originationFeeBps(Config.CLASS_FILM_TAX_CREDITS);
        uint256 feeUnits = exactUnits * feeBps / Config.BPS;
        uint256 borrowerBefore = IERC20(USDC).balanceOf(borrower);

        vm.prank(ops);
        waterfall.fund(tokenId, exactUnits);

        assertEq(reserves.deployedTo(tokenId), principal, "funded facility carries EXACTLY its principal");
        assertEq(
            IERC20(USDC).balanceOf(borrower) - borrowerBefore,
            exactUnits - feeUnits,
            "borrower nets principal minus the OID fee, not a wei more"
        );
        assertEq(
            uint256(bridge.facility(tokenId).state),
            uint256(ClaimBridge.LoanState.Active),
            "facility Active after the exact fund"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // A2 — access control: no privileged action is reachable by a wrong role
    // ─────────────────────────────────────────────────────────────────────
    function test_atk_fundDistributeAndGovernanceRejectUnprivilegedCallers() public onFork {
        uint256 principal = 1_000_000e18;
        _mintFromUSDC(alice, 5_000_000e6);
        uint256 tokenId = _originatePendingFilm(principal);

        // A KYC'd holder is still not a servicer: `fund` is SERVICER_ROLE-gated.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.SERVICER_ROLE)
        );
        waterfall.fund(tokenId, principal / 1e12);

        // `distribute` is SERVICER_ROLE-gated; the modifier fires before the payment is inspected,
        // so a garbage receipt from a non-servicer still bounces on access control.
        IWaterfallEngine.Payment memory dummy = IWaterfallEngine.Payment({
            tokenId: tokenId,
            paymentId: keccak256("atk-dummy"),
            payer: carol,
            interest: 1e18,
            principal: 0,
            nextPaymentDue: 0
        });
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.SERVICER_ROLE)
        );
        waterfall.distribute(dummy);

        // Governance setters are DEFAULT_ADMIN_ROLE (bytes32(0))-gated.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        waterfall.setProtocolFee(1);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        waterfall.setFeeRecipient(alice);

        assertEq(reserves.deployedTo(tokenId), 0, "no funding reached the facility through any wrong-role path");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A3 — I3: an Active facility cannot be re-funded (principal deployed twice)
    // ─────────────────────────────────────────────────────────────────────
    function test_atk_cannotDoubleFundAnActiveFacility() public onFork {
        uint256 principal = 1_000_000e18;
        _mintFromUSDC(alice, 5_000_000e6);
        uint256 tokenId = _originateAndFund(principal);
        assertEq(reserves.deployedTo(tokenId), principal, "first fund deployed exactly principal");

        // ATTACK: fund the SAME facility again — a second deployment of the full principal.
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_NotFundable.selector, tokenId));
        waterfall.fund(tokenId, principal / 1e12);

        assertEq(reserves.deployedTo(tokenId), principal, "the second fund added no exposure");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A4 — I2: the out-of-cascade protocol fee cannot jump ahead of a standing
    //          senior residual (ADR-0034 / ADV-1)
    // ─────────────────────────────────────────────────────────────────────
    function test_atk_protocolFeeCannotOutrankSeniorResidual() public onFork {
        uint256 principal = 1_000_000e18;
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 4_000_000e18); // the senior vault must be non-empty to receive yield
        uint256 tokenId = _originateAndFund(principal);

        // Declare a default with NO curator first-loss and NO sGROVE coverage: the whole
        // outstanding principal lands on the senior (sUSDfr) layer as an unabsorbed residual.
        _declareDefault(tokenId, keccak256("atk-default"));
        uint256 residual = defaultManager.pendingSeniorImpairment();
        assertGt(residual, 0, "precondition: a senior residual stands unabsorbed");

        uint256 interest = 10_000e18;
        uint256 feeGross = interest * uint256(waterfall.protocolFeeBps()) / Config.BPS;
        assertGt(feeGross, 0, "precondition: a nonzero protocol fee would otherwise be taken");
        uint256 withheld = feeGross < residual ? feeGross : residual;
        uint256 toVault = interest - feeGross;

        IWaterfallEngine.Payment memory p = _prepInterestPayment(tokenId, interest);

        address feeSink = waterfall.feeRecipient();
        uint256 feeSinkBefore = usdfr.balanceOf(feeSink);
        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        uint256 supplyBefore = usdfr.totalSupply();

        // The engine must WITHHOLD the fee rather than mint it to the out-of-cascade recipient.
        vm.expectEmit(true, true, true, true, address(waterfall));
        emit ProtocolFeeWithheldForSeniorImpairment(withheld, residual);
        vm.prank(ops);
        waterfall.distribute(p);

        // The out-of-cascade fee recipient is paid NOTHING while the senior residual stands.
        assertEq(
            usdfr.balanceOf(feeSink) - feeSinkBefore,
            feeGross - withheld,
            "protocol fee withheld, never paid ahead of the senior residual"
        );
        assertEq(feeGross - withheld, 0, "with residual >= feeGross the whole fee is withheld");

        // Senior yield still flows to the layer that bears the loss; only the withheld fee is
        // retained as backing, and NOTHING beyond the vault leg was minted.
        assertEq(
            usdfr.balanceOf(address(vault)) - vaultBefore, toVault, "senior vault receives the interest net of the fee"
        );
        assertEq(usdfr.totalSupply() - supplyBefore, toVault, "exactly the vault leg was minted; the fee never existed");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A5 — I1: one attested receipt authorizes exactly one distribution
    // ─────────────────────────────────────────────────────────────────────
    function test_atk_oneAttestationCannotBeSpentTwice() public onFork {
        uint256 principal = 1_000_000e18;
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 4_000_000e18);
        uint256 tokenId = _originateAndFund(principal);

        uint256 interest = 10_000e18;
        IWaterfallEngine.Payment memory p = _prepInterestPayment(tokenId, interest);

        // First distribution consumes the single attested PaymentReceived fact.
        vm.prank(ops);
        waterfall.distribute(p);

        // ATTACK: replay the identical receipt to double-claim the same yield.
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PaymentNotAttested.selector, tokenId));
        waterfall.distribute(p);
    }

    // ── helpers ───────────────────────────────────────────────────────────

    /// @dev Originates a FILM facility through the real m-of-n mint gate but stops at Pending
    ///      (the fixture's `_originateAndFund` funds in the same breath, which A1/A2 must not).
    function _originatePendingFilm(uint256 principal) internal returns (uint256 tokenId) {
        tokenId = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + 365 days);
        _attestFilmGate(
            tokenId, keccak256("FORK_BORROWER"), keccak256("US-GA"), principal, 7500, maturity, keccak256("ucc-ref")
        );
        vm.prank(ops);
        uint256 id = bridge.originate(
            ops,
            _forkTerms(keccak256("FORK_BORROWER"), keccak256("US-GA"), principal, 7500, maturity, keccak256("ucc-ref"))
        );
        require(id == tokenId, "ATK: tokenId drift");
    }

    /// @dev Prepares an attested INTEREST-ONLY receipt (principal leg zero) and returns the exact
    ///      `Payment` the servicer must distribute — mirroring `ForkLifecycleFixture._repay`'s
    ///      payload commitment so the split from preparation lets a test bind checks to the
    ///      `distribute` call itself.
    function _prepInterestPayment(uint256 tokenId, uint256 interest)
        internal
        returns (IWaterfallEngine.Payment memory p)
    {
        uint256 stableAmount = interest / 1e12;
        deal(USDC, borrower, IERC20(USDC).balanceOf(borrower) + stableAmount);
        vm.prank(borrower);
        IERC20(USDC).approve(address(reserves), stableAmount);

        ClaimBridge.Facility memory f = bridge.facility(tokenId);
        uint64 nextDue = f.nextPaymentDue + f.paymentInterval; // principal leg is 0, so never terminal
        bytes32 paymentId = keccak256(abi.encode("atk-interest", tokenId, interest));
        _attest(
            tokenId,
            IAttestationOracle.AttestationKind.PaymentReceived,
            keccak256(abi.encode(paymentId, tokenId, USDC, borrower, stableAmount, interest, uint256(0), nextDue))
        );
        p = IWaterfallEngine.Payment({
            tokenId: tokenId,
            paymentId: paymentId,
            payer: borrower,
            interest: interest,
            principal: 0,
            nextPaymentDue: nextDue
        });
    }
}
