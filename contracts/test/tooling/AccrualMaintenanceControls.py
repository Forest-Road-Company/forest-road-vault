#!/usr/bin/env python3
"""Check bounded maintenance defects in isolated checkouts, with verified restoration."""

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
    stage = Path(tempfile.mkdtemp(prefix="frv-accrual-maintenance-controls-"))
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

    copy_dependency(Path("test/unit/AccrualMaintenance.t.sol"))
    copy_dependency(Path("test/unit/AccrualMaintenanceNative.t.sol"))
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
    command = ["forge", "test", "--offline", "--match-contract", "AccrualMaintenance(Test|Native.*Test)", "--fuzz-runs", "10000", "-vv"]

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

    helper = "script/AccrualMaintenance.s.sol"
    cases = [
        ("wrong-chain-accepted", helper, "if (block.chainid != expectedChainId)",
         "if (block.chainid != expectedChainId && expectedChainId == 0)"),
        ("invalid-limits-accepted", helper,
         "if (maximum == 0 || maximum > 32 || maxBatches == 0 || maxBatches > 32)",
         "if ((maximum == 0 || maximum > 32 || maxBatches == 0 || maxBatches > 32) && reserve == address(0))"),
        ("no-code-guard-omitted", helper, "if (reserve.code.length == 0)",
         "if (reserve.code.length == 0 && maximum == 0)"),
        ("disabled-recognition-accepted", helper, "if (!snapshot.enabled)",
         "if (!snapshot.enabled && block.timestamp == 0)"),
        ("future-frontier-accepted", helper,
         "uint256(snapshot.accruedThrough) > block.timestamp",
         "(uint256(snapshot.accruedThrough) > block.timestamp && snapshot.accruedThrough == 0)"),
        ("old-fresh-frontier-accepted", helper,
         "(snapshot.fresh && uint256(snapshot.accruedThrough) != block.timestamp)",
         "(snapshot.fresh && uint256(snapshot.accruedThrough) != block.timestamp && block.timestamp == 0)"),
        ("over-limit-progress-accepted", helper, "if (processed > maximum)",
         "if (processed > maximum && maximum == 0)"),
        ("stalled-progress-accepted", helper, "if (processed == 0 && !fresh)",
         "if (processed == 0 && !fresh && maximum == 0)"),
        ("concurrent-completion-refused", helper, "if (processed == 0 && !fresh)",
         "if (processed == 0)"),
        ("incoherent-freshness-accepted", helper, "if (fresh != snapshot.fresh)",
         "if (fresh != snapshot.fresh && maximum == 0)"),
        ("backward-frontier-accepted", helper, "if (snapshot.accruedThrough < report.accruedThrough)",
         "if (snapshot.accruedThrough < report.accruedThrough && maximum == 0)"),
        ("invocation-budget-exceeded", helper, "report.batches < maxBatches",
         "report.batches <= maxBatches"),
        ("fresh-book-checkpointed", helper, "while (!report.fresh && report.batches < maxBatches)",
         "while (report.batches < maxBatches)"),
        ("report-current-too-early", helper, "report.fresh = fresh;",
         "report.fresh = true;"),
        ("native-batch-size-ignored", helper, "        return source.checkpointAccrual(maximum);",
         "        return source.checkpointAccrual(maximum == 0 ? maximum : 1);"),
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
