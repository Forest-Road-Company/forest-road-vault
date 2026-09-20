// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {AccrualLoans} from "../../src/libraries/AccrualLoans.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {Config} from "../../src/libraries/Config.sol";
import {ReserveCreditLib} from "../../src/libraries/ReserveCreditLib.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @notice Waterfall correctness checks on a pinned fork with real USDC and local current modules.
/// @dev Verifies exact funding, access checks, earned-fee delivery and single-use receipts.
///      Continuous fees crystallise as interest is earned; the legacy receipt-only withholding
///      rule is covered separately in the legacy unit tests.
contract ATK_WaterfallEngineForkTest is ForkLifecycleFixture {
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

    /// @notice Earned fees remain payable through default, and receiving the coupon charges no second fee.
    function test_earnedFeeSurvivesDefaultWithoutChargingTheReceiptAgain() public onFork {
        uint256 principal = 1_000_000e18;
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 4_000_000e18);
        uint256 tokenId = _originateAndFund(principal);
        address recipient = waterfall.feeRecipient();
        uint256 feesBefore = usdfr.balanceOf(recipient);
        _warp(30 days);
        _declareDefault(tokenId, keccak256("earned-fee-default"));

        // Independent fixed-note arithmetic: 14% Actual/360, first segment ends at tenor - 1.
        uint256 duration = 365 days - 1;
        uint256 endpoint = (principal * 1400 * duration / (Config.BPS * 360 days)) / 1e12 * 1e12;
        uint256 recognized = endpoint * 30 days / duration;
        uint256 fee = recognized * uint256(waterfall.protocolFeeBps()) / Config.BPS;
        uint256 coupon = (principal * 1400 * 30 days / (Config.BPS * 360 days)) / 1e12 * 1e12;
        assertEq(reserves.accruedDebt(tokenId).interest, coupon, "signed coupon at default");
        assertEq(defaultManager.pendingSeniorImpairment(), principal + coupon, "uncovered full-face default");
        assertGt(fee, 0, "nonzero earned-fee case");
        assertEq(reserves.accrualSnapshot().feeUnissued, fee, "earned fee is preserved");
        assertEq(usdfr.balanceOf(recipient), feesBefore, "claim not yet delivered");
        _assertEarnedFeeDelivery(fee);
        assertEq(usdfr.balanceOf(recipient), feesBefore + fee);

        uint256 supplyBefore = usdfr.totalSupply();
        uint256 reserveCashBefore = IERC20(USDC).balanceOf(address(reserves));
        IWaterfallEngine.Payment memory payment = _prepInterestPayment(tokenId, coupon);
        vm.prank(ops);
        waterfall.distribute(payment);
        assertEq(usdfr.balanceOf(recipient), feesBefore + fee, "receipt charged a second protocol fee");
        assertEq(usdfr.totalSupply(), supplyBefore, "receipt issued already recognized income again");
        assertEq(reserves.accrualSnapshot().unissued, 0, "receipt created another claim");
        assertEq(reserves.accruedDebt(tokenId).interest, 0, "cash discharged the entire coupon");
        assertEq(reserves.deployedTo(tokenId), principal);
        assertEq(defaultManager.pendingSeniorImpairment(), principal, "receipt reduced the risk mark");
        assertEq(IERC20(USDC).balanceOf(address(reserves)), reserveCashBefore + coupon / 1e12);
        assertTrue(controller.backingInvariantHolds(), "receipt conserved recognized backing");
    }

    /// @notice The old zero-elapsed default fixture owes no interest, so its interest receipt is refused.
    function test_defaultRecoveryCannotPayInterestThatWasNeverEarned() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 4_000_000e18);
        uint256 tokenId = _originateAndFund(1_000_000e18);
        _declareDefault(tokenId, keccak256("unearned-recovery-interest"));
        assertEq(reserves.accruedDebt(tokenId).interest, 0);
        uint256 supplyBefore = usdfr.totalSupply();
        IWaterfallEngine.Payment memory payment = _prepInterestPayment(tokenId, 10_000e18);
        vm.expectRevert(AccrualLoans.AccrualLoans_PaymentAboveDebt.selector);
        vm.prank(ops);
        waterfall.distribute(payment);
        assertEq(usdfr.totalSupply(), supplyBefore);
        assertEq(reserves.accruedDebt(tokenId).interest, 0);
        assertEq(reserves.deployedTo(tokenId), 1_000_000e18);
        assertEq(defaultManager.pendingSeniorImpairment(), 1_000_000e18);
        bytes32 payload = keccak256(
            abi.encode(
                payment.paymentId,
                tokenId,
                USDC,
                borrower,
                uint256(10_000e6),
                uint256(10_000e18),
                uint256(0),
                payment.nextPaymentDue
            )
        );
        assertEq(
            uint256(oracle.factStatus(tokenId, IAttestationOracle.AttestationKind.PaymentReceived, payload)),
            uint256(IAttestationOracle.FactStatus.Recorded),
            "refused receipt consumed the attestation"
        );
    }

    function _assertEarnedFeeDelivery(uint256 expectedFee) private {
        IContinuousAccrual.Snapshot memory beforeBook = reserves.accrualSnapshot();
        uint256 effectiveSupply = controller.totalUSDfr();
        uint256 backing = reserves.totalBackingValue();
        uint256 vaultAssets = vault.totalAssets();
        uint256 residual = defaultManager.pendingSeniorImpairment();
        uint256 rawSupply = usdfr.totalSupply();
        (, uint256 deliveredFee) = reserves.materializeAccrued(3);
        assertEq(deliveredFee, expectedFee, "senior residual withheld an already earned fee");
        assertEq(usdfr.totalSupply(), rawSupply + beforeBook.unissued);
        assertEq(controller.totalUSDfr(), effectiveSupply, "delivery changed effective supply");
        assertEq(reserves.totalBackingValue(), backing, "delivery changed backing");
        assertEq(vault.totalAssets(), vaultAssets, "delivery changed senior assets");
        assertEq(defaultManager.pendingSeniorImpairment(), residual, "delivery changed risk");
        assertEq(reserves.accrualSnapshot().unissued, 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // A5 — I1: one attested receipt authorizes exactly one distribution
    // ─────────────────────────────────────────────────────────────────────
    /// @notice ADR-0038 continuous accrual (`ADR/0038-continuous-interest-accrual-to-susdfr.md`,
    ///         "Decision" item 4 and "Loss-bearing cash and PIK without changing the contractual
    ///         basis"): a cash interest leg discharges already-recognised contractual interest and
    ///         is refused above it with `AccrualLoans_PaymentAboveDebt` (`AccrualLoans.sol`, "Cash
    ///         legs discharge their own separate balances"). The receipt is therefore spent one
    ///         earned month after funding, where the 10,000 USDfr leg is a partial coupon inside
    ///         the 11,666.666666 USDfr accrued (1,000,000 x 1400 bps x 30/360, Actual/360, floored
    ///         to USDC's 1e12 grid; the closed form `FullLifecycleFork.t.sol` pins). The attack is
    ///         unchanged: the first spend consumes the single PaymentReceived fact and discharges
    ///         exactly the attested leg, leaving 1,666.666666 USDfr accrued; the identical receipt
    ///         is then refused by `Waterfall_PaymentNotAttested` and discharges nothing.
    function test_atk_oneAttestationCannotBeSpentTwice() public onFork {
        uint256 principal = 1_000_000e18;
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 4_000_000e18);
        uint256 tokenId = _originateAndFund(principal);

        // ADR-0038: interest accrues to the second and a cash interest leg may not exceed it.
        // One earned monthly coupon on the fixture note (fixed 14%, Actual/360) on USDC's grid.
        _warp(30 days);
        uint256 accrued = (principal * 1400 * 30 days / (10_000 * 360 days)) / 1e12 * 1e12;
        assertEq(accrued, 11_666_666_666e12, "1,000,000 x 1400 bps x 30/360 floored to 1e12 = 11,666.666666");
        assertEq(reserves.accruedDebt(tokenId).interest, accrued, "engine accrued interest matches the signed note");

        uint256 interest = 10_000e18; // a partial coupon, strictly inside the accrued interest
        assertLt(interest, accrued, "precondition: the leg is representable under ADR-0038");
        IWaterfallEngine.Payment memory p = _prepInterestPayment(tokenId, interest);
        bytes32 payload = keccak256(
            abi.encode(p.paymentId, p.tokenId, USDC, p.payer, interest / 1e12, interest, uint256(0), p.nextPaymentDue)
        );
        assertEq(
            uint256(oracle.factStatus(tokenId, IAttestationOracle.AttestationKind.PaymentReceived, payload)),
            uint256(IAttestationOracle.FactStatus.Recorded),
            "precondition: the fact stands Recorded before the first spend"
        );

        // First distribution consumes the single attested PaymentReceived fact (the oracle emits
        // the spend before the engine takes the receipt) and discharges EXACTLY the attested
        // interest leg: 10,000 USDC native units, zero principal, 10,000 USDfr of interest.
        vm.expectEmit(true, true, true, false, address(oracle));
        emit IAttestationOracle.AttestationConsumed(
            tokenId, IAttestationOracle.AttestationKind.PaymentReceived, address(waterfall)
        );
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveCreditLib.AccruedPaymentReceived(tokenId, USDC, borrower, interest / 1e12, 0, interest);
        vm.prank(ops);
        waterfall.distribute(p);

        // The remaining accrued interest is the coupon less the leg discharged, to the wei.
        uint256 remaining = accrued - interest;
        assertEq(remaining, 1_666_666_666e12, "11,666.666666 less 10,000 = 1,666.666666");
        assertEq(reserves.accruedDebt(tokenId).interest, remaining, "first spend discharged exactly the attested leg");
        assertEq(
            uint256(oracle.factStatus(tokenId, IAttestationOracle.AttestationKind.PaymentReceived, payload)),
            uint256(IAttestationOracle.FactStatus.Consumed),
            "the fact is terminally Consumed by the first spend"
        );

        // ATTACK: replay the identical receipt to double-claim the same yield.
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PaymentNotAttested.selector, tokenId));
        waterfall.distribute(p);

        // The refused replay discharged nothing: the accrued interest is untouched.
        assertEq(reserves.accruedDebt(tokenId).interest, remaining, "the replay discharged no interest");
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
