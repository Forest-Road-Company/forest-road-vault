#!/usr/bin/env python3
"""Check that accrual deployment regressions are detected, with verified restoration."""

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
    stage = Path(tempfile.mkdtemp(prefix="frv-accrual-wiring-controls-"))
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

    copy_dependency(Path("test/unit/ContinuousAccrualWiring.t.sol"))
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
''')
    env = dict(os.environ, FOUNDRY_OUT=str(stage / "out"), FOUNDRY_CACHE_PATH=str(stage / "cache"))
    command = ["forge", "test", "--offline", "--match-contract", "ContinuousAccrualWiringTest", "-vv"]

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

    helper = "script/ContinuousAccrualDeployment.sol"
    cases = [
        ("deployment-wiring-omitted", "script/Deploy.s.sol", "        _wireContinuousAccrual(d);",
         "        if (d.reserves == address(0)) _wireContinuousAccrual(d);"),
        ("validation-entry-check-omitted", "script/Validate.s.sol", "        _validateContinuousAccrual(a);",
         "        if (a.reserves == address(0)) _validateContinuousAccrual(a);"),
        ("disabled-recognition-accepted", helper, "if (!snapshot.enabled)",
         "if (!snapshot.enabled && reserve == address(0))"),
        ("module-identities-ignored", helper,
         "if (keccak256(abi.encode(source.accrualModules())) != keccak256(abi.encode(expected)))",
         "if (keccak256(abi.encode(source.accrualModules())) != keccak256(abi.encode(expected)) && reserve == address(0))"),
        ("consumer-bindings-ignored", helper, "if (actual != reserve)",
         "if (actual != reserve && reserve == address(0))"),
        ("stale-recognition-accepted", helper, "if (!snapshot.fresh)",
         "if (!snapshot.fresh && reserve == address(0))"),
        ("fee-recipient-ignored", helper, "if (snapshot.feeRecipient != recipient)",
         "if (snapshot.feeRecipient != recipient && reserve == address(0))"),
        ("vesting-accepted", helper, "if (SUSDfr(expected.vault).yieldVestingPeriod() != 0)",
         "if (SUSDfr(expected.vault).yieldVestingPeriod() != 0 && reserve == address(0))"),
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
