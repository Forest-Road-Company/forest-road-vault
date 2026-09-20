#!/usr/bin/env python3
"""Check loan sequence defects in isolated checkouts, with verified restoration."""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def main():
    source = Path(sys.argv[1]).resolve()
    stage = Path(tempfile.mkdtemp(prefix="frv-accrual-loan-sequence-controls-"))
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

    copy_dependency(Path("test/unit/AccrualLoanSequences.t.sol"))
    (stage / "foundry.toml").write_text('''[profile.default]
src = "src"
test = "test"
script = "script"
out = "out"
cache_path = "cache"
libs = ["lib"]
solc_version = "0.8.30"
evm_version = "cancun"
optimizer = true
optimizer_runs = 100
deny_warnings = true
ignored_error_codes = [5574, 3860, 4591]
gas_limit = 4000000000
''')
    env = dict(os.environ, FOUNDRY_OUT=str(stage / "out"), FOUNDRY_CACHE_PATH=str(stage / "cache"))
    command = ["forge", "test", "--offline", "--match-contract", "AccrualLoanSequencesTest", "--fuzz-runs", "256", "-vv"]

    def run(label, expected_success):
        result = subprocess.run(command, cwd=stage, env=env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, check=False)
        (stage / (label + ".log")).write_text(result.stdout)
        assert "Compiler run successful!" in result.stdout or "No files changed, compilation skipped" in result.stdout, label
        assert re.search(r"Ran \d+ test", result.stdout), label + ": tests did not run"
        assert (result.returncode == 0) == expected_success, label
        failures = sorted(set(re.findall(r"^\[FAIL[^\n]*", result.stdout, flags=re.M)))
        assert expected_success or failures, label + ": failure was not a test failure"
        return {"exit_code": result.returncode, "failed_tests": failures}

    loan = "src/libraries/AccrualLoans.sol"
    book = "src/libraries/AccrualBook.sol"
    cases = [
        ("funding-rate-shifted", loan, "loan.terms.rateBps = funded.rateBps;",
         "loan.terms.rateBps = funded.rateBps == 0 ? 0 : funded.rateBps - 1;"),
        ("cash-interest-compounded", loan, "loan.pik ? loan.frozenPikBasis : loan.principal;",
         "loan.pik ? loan.frozenPikBasis : loan.principal + loan.unpaidInterest;"),
        ("pik-basis-moved-at-amendment", loan, "loan.pik ? loan.frozenPikBasis : loan.principal;",
         "loan.principal;"),
        ("pik-basis-moved-at-payment", loan, "loan.principal -= work.principalReduction;",
         "loan.principal -= work.principalReduction; if (loan.pik) loan.frozenPikBasis = loan.principal;"),
        ("amendment-rate-shifted", loan, "loan.terms.rateBps = changed.rateBps;",
         "loan.terms.rateBps = changed.rateBps == 0 ? 0 : changed.rateBps - 1;"),
        ("capitalization-at-technical-boundary", loan, "if (loan.pik && boundary == loan.nextCapitalization)",
         "if (loan.pik)"),
        ("maturity-delayed", loan, "loan.legalMaturity = funded.maturity;",
         "loan.legalMaturity = funded.maturity + 1 days;"),
        ("principal-payment-under-counted", loan, "loan.principal -= work.principalReduction;",
         "loan.principal -= work.principalReduction / 2;"),
        ("interest-payment-under-counted", loan, "loan.unpaidInterest -= work.interestReduction;",
         "loan.unpaidInterest -= work.interestReduction == 0 ? 0 : work.interestReduction - 1;"),
        ("cash-payment-does-not-reset-basis", loan, "(!loan.pik && principalLeg != 0)",
         "(!loan.pik && principalLeg == type(uint256).max)"),
        ("negative-correction-unreported", loan, "work.roundingLoss = recognized - canonical;",
         "work.roundingLoss = 0;"),
        ("positive-correction-unrecognized", loan,
         "self.book.creditStoppedCorrection(id, work.positiveCorrection, at);",
         "self.book.creditStoppedCorrection(id, 0, at);"),
        ("balance-cap-overstated", loan,
         "loan.terms.cap = face < loan.balanceCeiling ? loan.balanceCeiling - face : 0;",
         "loan.terms.cap = face < loan.balanceCeiling ? loan.balanceCeiling : 0;"),
        ("protocol-fee-understated", book,
         "Math.mulDiv(s.gross - self.feeBaseGross, self.feeBps, 10_000)",
         "Math.mulDiv(s.gross - self.feeBaseGross, self.feeBps, 20_000)"),
        ("past-due-growth-omitted", book,
         "risk.rate = _add(risk.rate, e.clock.rate);",
         "risk.rate = _add(risk.rate, 0);"),
        ("past-due-posting-under-counted", book,
         "risk.value -= amount;",
         "risk.value -= amount == 0 ? 0 : amount - 1;"),
        ("stop-does-not-close-income", loan,
         "Loan storage loan = _loan(self, facilityId);\n        work = _close(self, facilityId, loan, at);\n        _deactivate(self, loan);",
         "Loan storage loan = _loan(self, facilityId);\n        work = _work(facilityId, at);\n        _deactivate(self, loan);"),
    ]
    originals = {relative: (stage / relative).read_text() for _, relative, _, _ in cases}
    digest = lambda value: hashlib.sha256(value.encode()).hexdigest()
    results = {"stage": str(stage), "positive_before": run("positive-before", True), "controls": []}
    for label, relative, before, after in cases:
        file = stage / relative
        original = originals[relative]
        assert file.read_text() == original, label + ": prior source not restored"
        assert original.count(before) == 1, label + ": control must match exactly once"
        changed = original.replace(before, after)
        assert digest(changed) != digest(original), label
        try:
            file.write_text(changed)
            assert file.read_text() == changed, label + ": control write not verified"
            outcome = run(label, False)
            results["controls"].append({"name": label, "file": relative, "before_sha256": digest(original),
                                        "changed_sha256": digest(changed), **outcome})
            print(label + ": detected", flush=True)
        finally:
            file.write_text(original)
            assert file.read_text() == original, label + ": restoration failed"
    results["positive_after"] = run("positive-after", True)
    results["source_restored"] = all((stage / p).read_text() == contents for p, contents in originals.items())
    (stage / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
