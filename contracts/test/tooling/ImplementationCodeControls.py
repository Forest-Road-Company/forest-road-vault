#!/usr/bin/env python3
"""Run checked validator mutations in a separate checkout; never modify the input tree."""

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
    stage = Path(tempfile.mkdtemp(prefix="frv-implementation-code-controls-"))
    shutil.copytree(source / "src", stage / "src")
    (stage / "lib").symlink_to((source / "lib").resolve(), target_is_directory=True)
    copied = set()

    def copy_dependency(relative):
        if relative in copied:
            return
        assert relative.parts[0] in ("script", "test"), relative
        assert "audit-poc" not in relative.parts, relative
        copied.add(relative)
        text = (source / relative).read_text()
        target = stage / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        for name in re.findall(r'import\s+(?:[^;]*?\s+from\s+)?["\x27]([^"\x27]+)["\x27]\s*;', text):
            if name.startswith("."):
                child = ((source / relative).parent / name).resolve().relative_to(source)
                if child.parts[0] != "src":
                    copy_dependency(child)

    copy_dependency(Path("test/unit/ImplementationCodeValidation.t.sol"))
    (stage / "deployments").mkdir()
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
fs_permissions = [{access = "read", path = "./out"}]
''')
    env = dict(os.environ, FOUNDRY_OUT=str(stage / "out"), FOUNDRY_CACHE_PATH=str(stage / "cache"))
    command = ["forge", "test", "--offline", "--match-contract", "ImplementationCodeValidationTest", "-vv"]

    def run(label, expected_success):
        result = subprocess.run(command, cwd=stage, env=env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, check=False)
        (stage / (label + ".log")).write_text(result.stdout)
        assert "Compiler run successful!" in result.stdout or "No files changed, compilation skipped" in result.stdout, label
        assert re.search(r"Ran \d+ test", result.stdout), label + ": tests did not run"
        assert (result.returncode == 0) == expected_success, label
        return {"exit_code": result.returncode,
                "failed_tests": re.findall(r"^\[FAIL[^\n]*", result.stdout, flags=re.M)}

    results = {"stage": str(stage), "positive_before": run("positive-before", True), "controls": []}
    file = stage / "script/ValidateMainnet.s.sol"
    original = file.read_text()
    digest = lambda value: hashlib.sha256(value.encode()).hexdigest()
    cases = [
        ("implementation-hash-ignored",
         "implementation.codehash == _implementationRuntimeHash(artifact, implementation, isManager)",
         "implementation.codehash == _implementationRuntimeHash(artifact, implementation, isManager) || implementation != address(0)"),
        ("correct-code-rejected",
         "implementation.codehash == _implementationRuntimeHash(artifact, implementation, isManager)",
         "implementation.codehash != _implementationRuntimeHash(artifact, implementation, isManager)"),
        ("proxy-hash-ignored", "proxy.codehash == keccak256(type(ERC1967Proxy).runtimeCode)",
         "proxy.codehash == keccak256(type(ERC1967Proxy).runtimeCode) || proxy != address(0)"),
        ("implementation-slot-ignored", "liveImplementation == expectedImplementation,",
         "liveImplementation == expectedImplementation || proxy != address(0),"),
    ]
    for label, before, after in cases:
        assert original.count(before) == 1, label + ": mutation must match exactly once"
        changed = original.replace(before, after)
        assert digest(changed) != digest(original), label
        try:
            file.write_text(changed)
            assert file.read_text() == changed, label + ": mutation write was not verified"
            outcome = run(label, False)
            results["controls"].append({"name": label, "before_sha256": digest(original),
                                        "changed_sha256": digest(changed), **outcome})
        finally:
            file.write_text(original)
            assert file.read_text() == original, label + ": restoration failed"
    results["positive_after"] = run("positive-after", True)
    results["source_restored"] = digest(file.read_text()) == digest(original)
    (stage / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
