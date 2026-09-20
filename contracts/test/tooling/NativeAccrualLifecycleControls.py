#!/usr/bin/env python3
"""Verify native accrual regressions detect compiled defects in isolated copies."""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def invariant_counterexamples(output):
    blocks = re.findall(
        r"^Ran 1 test for test/invariant/CreditInvariants\.t\.sol:(\w+)\n(.*?)(?=\nSuite result:)",
        output, flags=re.M | re.S,
    )
    return sorted({name for name, body in blocks
                   if "[FAIL:" in body and "[Sequence]" in body
                   and " invariant_continuousIncomeBackingAndOrderedLosses() (runs:" in body})


def main():
    source = Path(sys.argv[1]).resolve()
    mode = sys.argv[2] if len(sys.argv) > 2 else "lifecycle"
    assert mode in ("lifecycle", "stateful", "capital", "service", "configuration", "risk", "delivery", "credit", "rounding"), mode
    stage = Path(tempfile.mkdtemp(prefix="frv-native-accrual-controls-"))
    print("Control checkout:", stage, flush=True)
    shutil.copytree(source / "src", stage / "src")
    (stage / "lib").symlink_to((source / "lib").resolve(), target_is_directory=True)
    copied = set()

    def copy_dependency(relative):
        if relative in copied:
            return
        assert relative.parts[0] in ("script", "test"), relative
        assert "audit-poc" not in relative.parts, relative
        copied.add(relative)
        contents = (source / relative).read_text()
        target = stage / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(contents)
        for name in re.findall(r'import\s+(?:[^;]*?\s+from\s+)?["\x27]([^"\x27]+)["\x27]\s*;', contents):
            if name.startswith("."):
                child = ((source / relative).parent / name).resolve().relative_to(source)
                if child.parts[0] != "src":
                    copy_dependency(child)

    if mode == "rounding":
        copy_dependency(Path("test/unit/ReserveAccrualRoundingGuards.t.sol"))
    elif mode == "credit":
        copy_dependency(Path("test/unit/ReserveAccrualCreditGuards.t.sol"))
    elif mode == "delivery":
        copy_dependency(Path("test/unit/ReserveAccrualDeliveryGuards.t.sol"))
    elif mode == "risk":
        copy_dependency(Path("test/unit/DefaultAccrualGuards.t.sol"))
    elif mode == "configuration":
        copy_dependency(Path("test/unit/ReserveAccrualConfiguration.t.sol"))
    elif mode == "service":
        copy_dependency(Path("test/unit/ReserveAccrualService.t.sol"))
    elif mode == "capital":
        copy_dependency(Path("test/unit/NativeAccrualCapitalFlows.t.sol"))
    elif mode == "stateful":
        copy_dependency(Path("test/unit/NativeAccrualSequences.t.sol"))
        copy_dependency(Path("test/invariant/CreditInvariants.t.sol"))
    else:
        copy_dependency(Path("test/unit/NativeAccrualLifecycle.t.sol"))
        six_decimal = Path("test/unit/NativeAccrualSixDecimal.t.sol")
        if (source / six_decimal).is_file():
            copy_dependency(six_decimal)
    (stage / "foundry.toml").write_text('''[profile.default]
src = "src"
test = "test"
script = "script"
libs = ["lib"]
solc_version = "0.8.30"
evm_version = "cancun"
optimizer = true
optimizer_runs = 100
deny_warnings = true
ignored_error_codes = [5574, 3860, 4591]
gas_limit = 4000000000
[profile.default.invariant]
runs = 16
depth = 64
fail_on_revert = true
''')
    env = dict(os.environ, FOUNDRY_OUT=str(stage / "out"), FOUNDRY_CACHE_PATH=str(stage / "cache"))
    command = ["forge", "test", "--offline", "--match-contract", "NativeAccrual.*LifecycleTest",
               "--fuzz-runs", "256", "-vv"]
    if mode == "stateful":
        command = ["forge", "test", "--offline", "--match-contract",
                   "NativeAccrual.*SequencesTest|^Continuous.*CreditInvariants$", "--fuzz-runs", "16", "-vv"]
    elif mode == "capital":
        command = ["forge", "test", "--offline", "--match-contract",
                   "NativeAccrual.*CapitalFlowsTest", "--fuzz-runs", "256", "-vv"]
    elif mode == "service":
        command = ["forge", "test", "--offline", "--match-contract",
                   "ReserveAccrualServiceTest", "--fuzz-runs", "256", "-vv"]
    elif mode == "configuration":
        command = ["forge", "test", "--offline", "--match-contract", "ReserveAccrualConfigurationTest", "-vv"]
    elif mode == "risk":
        command = ["forge", "test", "--offline", "--match-contract", "DefaultAccrualGuardsTest", "-vv"]

    if mode == "delivery":
        command = ["forge", "test", "--offline", "--match-contract", "ReserveAccrualDeliveryGuardsTest", "-vv"]

    if mode == "credit":
        command = ["forge", "test", "--offline", "--match-contract", "ReserveAccrualCreditGuardsTest", "--fuzz-runs", "256", "-vv"]

    if mode == "rounding":
        command = ["forge", "test", "--offline", "--match-contract", "ReserveAccrualRoundingGuardsTest", "--fuzz-runs", "256", "-vv"]

    def run(label, expected_success):
        result = subprocess.run(command, cwd=stage, env=env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, check=False)
        (stage / (label + ".log")).write_text(result.stdout)
        assert "Compiler run successful!" in result.stdout or "No files changed, compilation skipped" in result.stdout, label
        assert re.search(r"Ran \d+ test", result.stdout), label + ": tests did not run"
        assert (result.returncode == 0) == expected_success, label
        failures = sorted(set(re.findall(r"^\[FAIL[^\n]*", result.stdout, flags=re.M)))
        assert expected_success or failures, label + ": failure was not a test failure"
        campaigns = invariant_counterexamples(result.stdout) if mode == "stateful" else []
        if mode == "stateful" and not expected_success:
            assert campaigns, label + ": no invariant action sequence detected this defect"
        if mode == "capital" and not expected_success:
            assert any("testFuzz_depositMintAndQueuedExitUseAccruedFeeNetValue" in line for line in failures), \
                label + ": failure did not reach the capital-flow property"
        return {"exit_code": result.returncode, "failed_tests": failures, "failed_invariant_contracts": campaigns}

    loan = "src/libraries/AccrualLoans.sol"
    cases = [
        ("funding-rate-shifted", loan, "loan.terms.rateBps = funded.rateBps;",
         "loan.terms.rateBps = funded.rateBps == 0 ? 0 : funded.rateBps - 1;"),
        ("protocol-fee-halved", "src/libraries/AccrualBook.sol",
         "Math.mulDiv(s.gross - self.feeBaseGross, self.feeBps, 10_000)",
         "Math.mulDiv(s.gross - self.feeBaseGross, self.feeBps, 20_000)"),
        ("performance-fee-halved", "src/libraries/VaultFeeMath.sol",
         "Math.mulDiv(calc.profitAssets, p.performanceFeeBps, Config.BPS, Math.Rounding.Floor)",
         "Math.mulDiv(calc.profitAssets, p.performanceFeeBps, 2 * Config.BPS, Math.Rounding.Floor)"),
        ("pik-basis-moved-at-amendment", loan, "loan.pik ? loan.frozenPikBasis : loan.principal;",
         "loan.principal;"),
        ("cash-payment-does-not-reset-basis", loan, "(!loan.pik && principalLeg != 0)",
         "(!loan.pik && principalLeg == type(uint256).max)"),
        ("maturity-delayed", loan, "loan.legalMaturity = funded.maturity;",
         "loan.legalMaturity = funded.maturity + 1 days;"),
        ("overpayment-error-changed", loan,
         "error AccrualLoans_PaymentAboveDebt();",
         "error AccrualLoans_PaymentAboveDebt(); error NativeControl_WrongDebtRefusal();"),
        ("stop-does-not-close-income", loan,
         "Loan storage loan = _loan(self, facilityId);\n        work = _close(self, facilityId, loan, at);\n        _deactivate(self, loan);",
         "Loan storage loan = _loan(self, facilityId);\n        work = _work(facilityId, at);\n        _deactivate(self, loan);"),
        ("past-due-growth-omitted", "src/libraries/AccrualBook.sol",
         "risk.rate = _add(risk.rate, e.clock.rate);", "risk.rate = _add(risk.rate, 0);"),
        ("curator-delivery-halved", "src/CuratorModule.sol",
         "absorbed = loss < pool.balance ? loss : pool.balance;",
         "absorbed = (loss < pool.balance ? loss : pool.balance) / 2;"),
    ]
    if (source / "src/SGrove.sol").is_file():
        cases.append(("shared-coverage-not-decremented", "src/SGrove.sol",
                      "$.coverageReserve = reserve - covered;", "$.coverageReserve = reserve;"))
    if mode == "stateful":
        cases = [case for case in cases if case[0] != "overpayment-error-changed"]
        cases.extend([
            ("facility-posting-not-cleared", "src/libraries/AccrualBook.sol",
             "e.posted = e.clock.value;", "e.posted = e.clock.value / 2;"),
            ("loss-principal-under-counted", "src/libraries/ReserveAccrualCreditLib.sol",
             "loan.principal -= principal;", "loan.principal -= principal / 2;"),
            ("cancelled-exposure-not-cleared", "src/ClaimBridge.sol",
             "$.registry.recordExposureDecrease(f.classId, f.borrowerId, f.stateId, f.principal);",
             "$.registry.recordExposureDecrease(f.classId, f.borrowerId, f.stateId, f.principal / 2);"),
            ("past-due-performance-risk-omitted", "src/libraries/DefaultAccrualLib.sol",
             "amount += $.declaredDefaultedPrincipal[classId] + pastDuePrincipal($, classId);",
             "amount += $.declaredDefaultedPrincipal[classId];"),
        ])
    if mode == "capital":
        cases = [case for case in cases if case[0] in ("protocol-fee-halved", "performance-fee-halved")]
        cases.extend([
            ("pending-fee-quote-halved", "src/SUSDfr.sol",
             "return supply + calc.managementShares + calc.performanceShares;",
             "return supply + calc.managementShares + calc.performanceShares / 2;"),
            ("entry-owned-income-halved", "src/libraries/VaultAccrualLib.sol",
             "assets += s.seniorUnissued;", "assets += s.seniorUnissued / 2;"),
            ("queue-claim-delivery-halved", "src/RedemptionQueue.sol",
             "$.usdfr.safeTransfer(r.owner, assets);", "$.usdfr.safeTransfer(r.owner, assets / 2);"),
            ("queue-filled-shares-halved", "src/RedemptionQueue.sol",
             "r.sharesRemaining -= fillShares;", "r.sharesRemaining -= fillShares / 2;"),
            ("cash-redemption-burn-halved", "src/MintRedeemController.sol",
             "$.usdfr.burn(msg.sender, usdfrIn);", "$.usdfr.burn(msg.sender, usdfrIn / 2);"),
        ])
    if mode == "service":
        service = "src/libraries/ReserveAccrualServiceLib.sol"
        cases = [
            ("unknown-facility-refusal-changed", service,
             "revert AccrualService_UnknownFacility(id);", "revert AccrualService_UnknownFacility(id + 1);"),
            ("servicing-closes-unchanged-curves", service,
             "s.loans.serviceDormant(id, ReserveAccrualStorageLib.now64())",
             "s.loans.stop(id, ReserveAccrualStorageLib.now64())"),
            ("signed-service-date-shifted", service,
             "setAccruedPaymentDue(id, work.nextDue);", "setAccruedPaymentDue(id, work.nextDue - 1);"),
            ("aggregate-reservation-release-halved", service,
             "s.reservedCeilings -= prior - face;", "s.reservedCeilings -= (prior - face) / 2;"),
            ("facility-reservation-not-trimmed", service,
             "s.identities[id].reservedCeiling = face;", "s.identities[id].reservedCeiling = prior;"),
            ("invalid-ceiling-refusal-changed", service,
             "revert AccrualService_InvalidCeiling();", "revert AccrualService_UnknownFacility(id);"),
            ("pending-boundary-refusal-changed", "src/libraries/AccrualBook.sol",
             "revert AccrualBook_BoundaryPending(at, at);", "revert AccrualBook_BoundaryPending(at, at + 1);"),
        ]
    if mode == "configuration":
        reserve = "src/libraries/ReserveAccrualLib.sol"
        cases = [
            ("configuration-refusal-changed", reserve,
             "error ReserveAccrual_WrongModules();", "error ReserveAccrual_WrongModules(uint256 unused);"),
            ("forward-route-check-omitted", reserve,
             "_validateRoutes(m, native);", "if (m.token == address(0)) _validateRoutes(m, native);"),
            ("configuration-permanence-refusal-changed", reserve,
             "if (s.modules.token != address(0)) revert ReserveAccrual_AlreadyConfigured();",
             "if (s.modules.token != address(0)) revert ReserveAccrual_WrongModules();"),
            ("default-reverse-binding-omitted", reserve,
             "|| IAccrualVault(m.defaultManager).accrualReserve() != address(this)", "|| false"),
            ("activation-fee-silently-clamped", reserve,
             "uint16 feeBps = IWaterfallEngine(m.waterfall).protocolFeeBps();",
             "uint16 feeBps = IWaterfallEngine(m.waterfall).protocolFeeBps(); if (feeBps > Config.MAX_PROTOCOL_FEE_BPS) feeBps = Config.MAX_PROTOCOL_FEE_BPS;"),
            ("migration-refusal-changed", reserve,
             "revert ReserveAccrual_MigrationRequired(deployed);", "revert ReserveAccrual_MigrationRequired(deployed + 1);"),
        ]
    if mode == "risk":
        risk = "src/libraries/DefaultAccrualLib.sol"
        cases = [
            ("risk-manager-identity-omitted", risk,
             "m.defaultManager != address(this)", "m.defaultManager == address(0)"),
            ("risk-binding-authorization-omitted", "src/DefaultManager.sol",
             "function setAccrualReserve(address reserve) external onlyRole(DEFAULT_ADMIN_ROLE) accrualIdle nonReentrant",
             "function setAccrualReserve(address reserve) external accrualIdle nonReentrant"),
            ("risk-nested-mutation-accepted", risk,
             "if (entered) revert DefaultAccrual_OperationInProgress();", "if (entered) return;"),
            ("risk-callback-refusal-changed", risk,
             "error DefaultAccrual_CallerNotReserve(address caller);",
             "error DefaultAccrual_CallerNotReserve(address caller); error DefaultControl_WrongCaller(address caller);"),
            ("risk-delivery-overlap-accepted", risk,
             "if ($.accrualReserve.accrualDelivery().active) revert DefaultAccrual_OperationInProgress();",
             "if ($.accrualReserve.accrualDelivery().active) return;"),
            ("risk-unknown-debt-refusal-changed", risk,
             "revert DefaultAccrual_UnknownFacility(id);", "revert DefaultAccrual_UnknownFacility(id + 1);"),
            ("risk-rounding-bound-omitted", risk,
             "if (amount > contribution_) revert DefaultAccrual_RoundingExceedsContribution(id, amount, contribution_);",
             "if (amount > contribution_) return;"),
        ]
    if mode == "delivery":
        reserve = "src/libraries/ReserveAccrualLib.sol"
        cases = [("delivery-proof-" + str(i) + "-omitted", reserve,
                  "if (expected != actual) revert ReserveAccrual_DeliveryMismatch(measurement, expected, actual);",
                  "if (measurement != " + str(i) + " && expected != actual) revert ReserveAccrual_DeliveryMismatch(measurement, expected, actual);")
                 for i in range(7)]
        cases += [
            ("disabled-delivery-accepted", reserve,
             "if (!s.enabled) revert ReserveAccrual_NotEnabled();\n        IContinuousAccrual.Snapshot memory beforeBook = snapshot();",
             "IContinuousAccrual.Snapshot memory beforeBook = snapshot();"),
            ("fee-caller-check-omitted", reserve,
             "if (msg.sender != s.modules.waterfall) revert ReserveAccrual_NotWaterfall();",
             "if (msg.sender == address(0)) revert ReserveAccrual_NotWaterfall();"),
            ("disabled-fee-update-accepted", reserve,
             "if (!s.enabled) revert ReserveAccrual_NotEnabled();\n        if (feeBps > Config.MAX_PROTOCOL_FEE_BPS)",
             "if (feeBps > Config.MAX_PROTOCOL_FEE_BPS)"),
            ("fee-limit-refusal-omitted", reserve,
             "if (!s.enabled) revert ReserveAccrual_NotEnabled();\n        if (feeBps > Config.MAX_PROTOCOL_FEE_BPS) revert ReserveAccrual_InvalidFee(feeBps);",
             "if (!s.enabled) revert ReserveAccrual_NotEnabled();"),
            ("busy-vault-delivery-accepted", reserve,
             "if (!d.pricing.materializationAllowed) revert ReserveAccrual_VaultBusy();",
             "if (d.pricing.entryAssets == 0) revert ReserveAccrual_VaultBusy();"),
            ("nonce-exhaustion-refusal-omitted", reserve,
             "if (s.nonce == type(uint256).max) revert ReserveAccrual_NonceOverflow();",
             "if (s.nonce == 1) revert ReserveAccrual_NonceOverflow();"),
            ("delivery-gas-refusal-omitted", reserve,
             "if (available <= retained + 200_000) revert ReserveAccrual_InsufficientDeliveryGas(available);",
             "if (available == 0) revert ReserveAccrual_InsufficientDeliveryGas(available);"),
            ("delivery-gas-boundary-raised", reserve,
             "if (available <= retained + 200_000) revert ReserveAccrual_InsufficientDeliveryGas(available);",
             "if (available <= retained + 400_000) revert ReserveAccrual_InsufficientDeliveryGas(available);"),
        ]
    if mode == "credit":
        credit = "src/libraries/ReserveAccrualCreditLib.sol"
        cases = [
            ("funding-state-check-omitted", credit,
             "f.state != ClaimBridge.LoanState.Active || asset == address(0)", "asset == address(0)"),
            ("funding-asset-check-omitted", credit,
             "f.state != ClaimBridge.LoanState.Active || asset == address(0)", "f.state != ClaimBridge.LoanState.Active"),
            ("funding-face-check-omitted", credit,
             "|| native.deployed[id] != f.principal", "|| false"),
            ("pik-exposure-bound-omitted", credit,
             "if (f.principal > MAX_EXPOSURE / 3) revert AccrualCredit_ExposureCapacity();",
             "if (f.principal == 0) revert AccrualCredit_ExposureCapacity();"),
            ("cash-face-bound-omitted", credit,
             "if (principal > MAX_EXPOSURE || interest > MAX_EXPOSURE - principal) revert AccrualCredit_ExposureCapacity();",
             "if (principal == 0 && interest == 0) revert AccrualCredit_ExposureCapacity();"),
            ("cash-future-bound-omitted", credit,
             "if (units > (MAX_EXPOSURE - ceiling) / scale) revert AccrualCredit_ExposureCapacity();",
             "if (scale == 0) revert AccrualCredit_ExposureCapacity();"),
            ("cash-maturity-check-omitted", credit,
             "if (maturity <= at) revert AccrualLoans.AccrualLoans_InvalidSchedule();",
             "if (maturity == 0) revert AccrualLoans.AccrualLoans_InvalidSchedule();"),
            ("present-exposure-bound-omitted", credit,
             "effective > MAX_EXPOSURE || future > MAX_EXPOSURE - effective", "future > MAX_EXPOSURE - effective"),
            ("reserved-exposure-bound-omitted", credit,
             "effective > MAX_EXPOSURE || future > MAX_EXPOSURE - effective", "effective > MAX_EXPOSURE"),
            ("additional-exposure-bound-omitted", credit,
             "|| additional > MAX_EXPOSURE - effective - future", "|| additional == type(uint256).max"),
            ("amendment-day-count-check-omitted", credit,
             "terms.yearSeconds != 360 days && (loan.pik || terms.yearSeconds != 365 days)",
             "terms.yearSeconds == 0"),
            ("receipt-conversion-proof-omitted", credit,
             "if (received != total) revert AccrualCredit_ReceiptMismatch(id);",
             "if (received == 0) revert AccrualCredit_ReceiptMismatch(id);"),
            ("receipt-face-proof-omitted", credit,
             "if (outstanding != s.loans.loans[id].principal + s.loans.loans[id].unpaidInterest)",
             "if (outstanding == type(uint256).max)"),
            ("retirement-caller-check-omitted", credit,
             "msg.sender != s.modules.waterfall && msg.sender != s.modules.defaultManager",
             "msg.sender == address(0)"),
            ("exposure-kind-check-omitted", credit,
             "if (kind > 3) revert AccrualCredit_InvalidExposureKind(kind);",
             "if (kind == 254) revert AccrualCredit_InvalidExposureKind(kind);"),
            ("disabled-credit-accepted", credit,
             "if (!s.enabled) revert ReserveAccrualLib.ReserveAccrual_NotEnabled();",
             "if (s.modules.waterfall == address(0)) revert ReserveAccrualLib.ReserveAccrual_NotEnabled();"),
            ("cash-ceiling-interest-halved", credit,
             "return ceiling + units * scale;", "return ceiling + units * scale / 2;"),
        ]
    if mode == "rounding":
        rounding = "src/libraries/ReserveRoundingLib.sol"
        ethereum = (source / "src/SGrove.sol").is_file()
        cases = [("rounding-proof-" + str(i) + "-omitted", rounding,
                  "if (expected != actual) revert AccrualRounding_DeltaMismatch(measurement, expected, actual);",
                  "if (measurement != " + str(i) + " && expected != actual) revert AccrualRounding_DeltaMismatch(measurement, expected, actual);")
                 for i in range(10 if ethereum else 8)]
        cases += [
            ("burn-caller-check-omitted", rounding,
             "if (msg.sender != s.modules.controller) revert AccrualRounding_InvalidContinuation();",
             "if (msg.sender == address(0)) revert AccrualRounding_InvalidContinuation();"),
            ("burn-busy-check-omitted", rounding,
             "!s.busy || s.delivery.active || !r.ready", "s.delivery.active || !r.ready"),
            ("burn-delivery-check-omitted", rounding,
             "!s.busy || s.delivery.active || !r.ready", "!s.busy || !r.ready"),
            ("burn-ready-check-omitted", rounding,
             "|| !r.ready || caller != address(this)", "|| caller != address(this)"),
            ("burn-source-check-omitted", rounding,
             "|| caller != address(this) || from != r.from", "|| caller == address(0) || from != r.from"),
            ("burn-holder-check-omitted", rounding,
             "|| from != r.from || amount != r.amount", "|| from == address(0) || amount != r.amount"),
            ("burn-amount-check-omitted", rounding,
             "|| amount != r.amount", "|| false"),
            ("burn-zero-check-omitted", rounding,
             "|| amount == 0", "|| false"),
            ("burn-permit-can-be-reused", rounding,
             "r.ready = false;", "r.ready = true;"),
            ("burn-consumption-proof-omitted", rounding,
             "if (s.rounding.ready) revert AccrualRounding_InvalidContinuation();",
             "if (!s.rounding.active) revert AccrualRounding_InvalidContinuation();"),
            ("allocation-busy-check-omitted", rounding,
             "!s.busy || s.delivery.active || s.rounding.active", "s.delivery.active || s.rounding.active"),
            ("allocation-delivery-check-omitted", rounding,
             "!s.busy || s.delivery.active || s.rounding.active", "!s.busy || s.rounding.active"),
            ("allocation-continuation-check-omitted", rounding,
             "|| s.rounding.active || loss == 0", "|| loss == 0"),
            ("allocation-zero-check-omitted", rounding,
             "|| loss == 0 || loss >= loan.terms.scale", "|| loss >= loan.terms.scale"),
            ("allocation-grid-check-omitted", rounding,
             "|| loss >= loan.terms.scale", "|| false"),
            ("allocation-nonce-check-omitted", rounding,
             "work.closureNonce != loan.closureNonce || _unissuedVaultAssets(s, work.at) != 0",
             "_unissuedVaultAssets(s, work.at) != 0"),
            ("allocation-owned-claim-check-omitted", rounding,
             "|| _unissuedVaultAssets(s, work.at) != 0", "|| _unissuedVaultAssets(s, work.at) == type(uint256).max"),
            ("vault-owned-fee-claim-omitted", rounding,
             "if (s.feeRecipient == s.modules.vault) owned += claims.feeUnissued;",
             "if (s.feeRecipient == address(0)) owned += claims.feeUnissued;"),
            ("rounding-gas-refusal-omitted", rounding,
             "if (available <= retained + 200_000) revert AccrualRounding_InsufficientGas();",
             "if (available == 0) revert AccrualRounding_InsufficientGas();"),
        ]
        mark = "allocation.mark" if ethereum else "mark"
        prepaid = "allocation.prepaid" if ethereum else "prepaid"
        unabsorbed = "allocation.unabsorbed" if ethereum else "unabsorbed"
        cases += [
            ("rounding-mark-clamp-zeroed", rounding,
             "if (" + mark + " > loss) " + mark + " = loss;",
             "if (" + mark + " > loss) " + mark + " = 0;"),
            ("rounding-prepayment-clamp-zeroed", rounding,
             "if (" + prepaid + " > " + mark + ") " + prepaid + " = " + mark + ";",
             "if (" + prepaid + " > " + mark + ") " + prepaid + " = 0;"),
            ("rounding-prepayment-debit-omitted", rounding,
             "native.exitPrepaidAbsorption -= " + prepaid + ";", "native.exitPrepaidAbsorption -= 0;"),
            ("rounding-unabsorbed-record-omitted", rounding,
             "s.roundingUnabsorbed += " + unabsorbed + ";", "s.roundingUnabsorbed += 0;"),
            ("rounding-curator-demand-halved", rounding,
             "_curator(s, native, work.facilityId, loss - " + prepaid + ")",
             "_curator(s, native, work.facilityId, (loss - " + prepaid + ") / 2)"),
        ]
        if ethereum:
            cases.append(("rounding-backstop-layer-omitted", rounding,
                "allocation.backstop = _backstop(s, native, work.facilityId, loss - allocation.prepaid - allocation.curator);",
                "allocation.backstop = 0;"))
    originals = {relative: (stage / relative).read_text() for _, relative, _, _ in cases}
    digest = lambda value: hashlib.sha256(value.encode()).hexdigest()
    results = {"stage": str(stage), "mode": mode, "positive_before": run("positive-before", True), "controls": []}
    for label, relative, before, after in cases:
        file = stage / relative
        original = originals[relative]
        assert file.read_text() == original, label + ": prior source not restored"
        count = 2 if label in ("risk-delivery-overlap-accepted", "risk-unknown-debt-refusal-changed") else 1
        assert original.count(before) == count, label + ": incorrect control preimage count"
        changed = original.replace(before, after)
        if label == "overpayment-error-changed":
            preimage = "revert AccrualLoans_PaymentAboveDebt();"
            assert changed.count(preimage) == 2, label + ": both cash and PIK guards must change"
            changed = changed.replace(preimage, "revert NativeControl_WrongDebtRefusal();")
        if label == "configuration-refusal-changed":
            preimage = "revert ReserveAccrual_WrongModules();"
            sites = 12 if (source / "src/SGrove.sol").is_file() else 11
            assert changed.count(preimage) == sites, label + ": configuration refusal sites changed"
            changed = changed.replace(preimage, "revert ReserveAccrual_WrongModules(1);")
        if label == "risk-callback-refusal-changed":
            preimage = "revert DefaultAccrual_CallerNotReserve(msg.sender);"
            assert changed.count(preimage) == 2, label + ": both risk callbacks must change"
            changed = changed.replace(preimage, "revert DefaultControl_WrongCaller(msg.sender);")
        assert digest(changed) != digest(original), label
        try:
            file.write_text(changed)
            assert file.read_text() == changed, label + ": control write not verified"
            outcome = run(label, False)
            results["controls"].append({"name": label, "file": relative, "before_sha256": digest(original),
                                        "changed_sha256": digest(changed), "preimage_count": count, **outcome})
            print(label + ": detected", flush=True)
        finally:
            file.write_text(original)
            assert file.read_text() == original, label + ": restoration failed"
    results["positive_after"] = run("positive-after", True)
    results["source_restored"] = all((stage / p).read_text() == contents for p, contents in originals.items())
    if mode in ("service", "configuration", "risk", "delivery", "credit", "rounding"):
        suite = {"service": "ReserveAccrualService", "configuration": "ReserveAccrualConfiguration",
                 "risk": "DefaultAccrualGuards", "delivery": "ReserveAccrualDeliveryGuards", "credit": "ReserveAccrualCreditGuards", "rounding": "ReserveAccrualRoundingGuards"}[mode]
        functions = set(re.findall(r"function (test\w+)\(",
                                  (stage / ("test/unit/" + suite + ".t.sol")).read_text()))
        detected = {name for control in results["controls"] for failure in control["failed_tests"]
                    for name in re.findall(r"\b(test\w+)\(", failure)}
        assert functions <= detected, mode + " tests without a detected defect: " + str(functions - detected)
    (stage / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
