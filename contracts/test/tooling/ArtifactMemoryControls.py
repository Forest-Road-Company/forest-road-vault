#!/usr/bin/env python3
"""Bound validator memory with full compiler AST artifacts and a checked call-frame mutation."""

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
    stage = Path(tempfile.mkdtemp(prefix="frv-artifact-memory-controls-"))
    print("Control checkout:", stage, flush=True)
    shutil.copytree(source / "src", stage / "src")
    # Git worktrees expose submodules as gitlink directories. Local rehearsals may
    # temporarily populate those paths with links to the canonical dependencies,
    # so link each dependency by its resolved target instead of linking the parent.
    # This also keeps the control checkout independent of nested-link behaviour.
    (stage / "lib").mkdir()
    for dependency in (
        "forge-std",
        "openzeppelin-contracts",
        "openzeppelin-contracts-upgradeable",
        "solady",
    ):
        target = (source / "lib" / dependency).resolve()
        assert target.is_dir(), f"missing dependency: {dependency}"
        (stage / "lib" / dependency).symlink_to(target, target_is_directory=True)
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
    shutil.copy2(source / "remappings.txt", stage / "remappings.txt")
    env = dict(os.environ, FOUNDRY_OUT=str(stage / "out"), FOUNDRY_CACHE_PATH=str(stage / "cache"))
    artifact_names = ["ComplianceRegistry", "USDfr", "ReserveManager", "MintRedeemController", "SUSDfr",
                      "PointsModule", "CollateralRegistry", "AttestationOracle", "ClaimBridge", "CuratorModule",
                      "WaterfallEngine", "DefaultManager", "AssessedImpairmentSource", "RedemptionQueue"]
    if (source / "src/GroveToken.sol").is_file():
        artifact_names += ["GroveToken", "SGrove", "FRGovernor"]

    def run(label, succeeds):
        command = ["forge", "test", "--offline", "--ast", "--match-contract", "ImplementationCodeValidationTest",
                   "--match-test", "test_acceptsAllRealConstructorRuntimes", "-vv"]
        tested = subprocess.run(command, cwd=stage, env=env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, check=False)
        (stage / (label + ".log")).write_text(tested.stdout)
        assert "Compiler run successful!" in tested.stdout or "No files changed, compilation skipped" in tested.stdout, label + ": compilation failed"
        assert "Ran 1 test" in tested.stdout, label + ": witness did not run"
        assert (tested.returncode == 0) == succeeds, label
        sizes = {}
        for name in artifact_names:
            filename = "sUSDfr" if name == "SUSDfr" else name
            path = stage / "out" / (filename + ".sol") / (name + ".json")
            obj = json.loads(path.read_text())
            assert obj.get("ast"), "compiler AST output must actually be present"
            sizes[name] = path.stat().st_size
        return {"exit_code": tested.returncode, "artifact_bytes": sizes,
                "result": [line for line in tested.stdout.splitlines() if line.startswith("Suite result:")]}

    result = {"stage": str(stage), "positive_before": run("positive-before", True)}
    path = stage / "script/ImplementationRuntimeHash.sol"
    original = path.read_text()
    before = "return runtimeHashWorker.implementationRuntimeHash(artifact, implementation, isManager);"
    after = "return implementationRuntimeHash(artifact, implementation, isManager);"
    assert original.count(before) == 1
    changed = original.replace(before, after)
    digest = lambda value: hashlib.sha256(value.encode()).hexdigest()
    assert digest(changed) != digest(original)
    try:
        path.write_text(changed)
        assert path.read_text() == changed
        result["shared-frame-control"] = run("shared-frame-control", False)
        result["before_sha256"] = digest(original)
        result["changed_sha256"] = digest(changed)
    finally:
        path.write_text(original)
        assert path.read_text() == original
    result["positive_after"] = run("positive-after", True)
    result["source_restored"] = path.read_text() == original
    (stage / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
