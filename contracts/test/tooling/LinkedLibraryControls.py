#!/usr/bin/env python3
"""Prove library manifest/validator checks detect defects in an isolated checkout."""

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
    stage = Path(tempfile.mkdtemp(prefix="frv-linked-library-controls-"))
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
        text = (source / relative).read_text()
        target = stage / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        for name in re.findall(r'import\s+(?:[^;]*?\s+from\s+)?["\x27]([^"\x27]+)["\x27]\s*;', text):
            if name.startswith("."):
                child = ((source / relative).parent / name).resolve().relative_to(source)
                if child.parts[0] != "src":
                    copy_dependency(child)

    copy_dependency(Path("test/unit/LinkedLibraryManifest.t.sol"))
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
fs_permissions = [{access = "read", path = "./out"}, {access = "read-write", path = "./deployments"}]
''')
    env = dict(os.environ, FOUNDRY_OUT=str(stage / "out"), FOUNDRY_CACHE_PATH=str(stage / "cache"))
    command = ["forge", "test", "--offline", "--match-contract",
               "LinkedLibraryManifestTest|ImplementationCodeValidationTest", "-vv"]

    def run(label, expected_success):
        result = subprocess.run(command, cwd=stage, env=env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, check=False)
        (stage / (label + ".log")).write_text(result.stdout)
        assert "Compiler run successful!" in result.stdout or "No files changed, compilation skipped" in result.stdout, label
        assert re.search(r"Ran \d+ test", result.stdout), label + ": tests did not run"
        assert (result.returncode == 0) == expected_success, label
        failures = re.findall(r"^\[FAIL[^\n]*", result.stdout, flags=re.M)
        return {"exit_code": result.returncode, "failed_tests": sorted(set(failures))}

    results = {"stage": str(stage), "positive_before": run("positive-before", True), "controls": []}
    cases = [
        ("migration-library-record-omitted", "script/LinkedLibraryArtifacts.sol",
         'a[18] = Entry("ReserveMigrationLib", address(ReserveMigrationLib));',
         'a[18] = Entry("ReserveWiringLib", address(ReserveWiringLib));'),
        ("manifest-recording-omitted", "script/Deploy.s.sol", "LinkedLibraryArtifacts.record(j);",
         'vm.serializeUint(j, "control", 1);'),
        ("validator-library-check-omitted", "script/ValidateMainnet.s.sol", "LinkedLibraryArtifacts.validate();",
         "if (a.deployer == address(0)) LinkedLibraryArtifacts.validate();"),
        ("library-codehash-ignored", "script/LinkedLibraryArtifacts.sol", "if (actualHash != expectedHash) {",
         "if (actualHash != expectedHash && entry.implementation == address(0)) {"),
        ("fee-library-record-omitted", "script/LinkedLibraryArtifacts.sol",
         'a[16] = Entry("VaultFeeMath", address(VaultFeeMath));',
         'a[16] = Entry("ReserveWiringLib", address(ReserveWiringLib));'),
        ("recorded-address-changed", "script/LinkedLibraryArtifacts.sol",
         'VM.serializeAddress(objectKey, string.concat("lib_", entry.name), entry.implementation);',
         'VM.serializeAddress(objectKey, string.concat("lib_", entry.name), address(uint160(entry.implementation) ^ 1));'),
        ("recorded-runtime-hash-zeroed", "script/LinkedLibraryArtifacts.sol",
         'VM.serializeBytes32(objectKey, string.concat("libRuntimeHash_", entry.name), codeHash);',
         'VM.serializeBytes32(objectKey, string.concat("libRuntimeHash_", entry.name), codeHash & bytes32(0));'),
    ]
    originals = {relative: (stage / relative).read_text() for _, relative, _, _ in cases}
    digest = lambda value: hashlib.sha256(value.encode()).hexdigest()
    for label, relative, before, after in cases:
        file = stage / relative
        original = originals[relative]
        assert file.read_text() == original, label + ": prior source not restored"
        assert original.count(before) == 1, label + ": mutation must match exactly once"
        changed = original.replace(before, after)
        assert digest(changed) != digest(original), label
        try:
            file.write_text(changed)
            assert file.read_text() == changed, label + ": mutation write was not verified"
            outcome = run(label, False)
            results["controls"].append({"name": label, "file": relative, "before_sha256": digest(original),
                                        "changed_sha256": digest(changed), **outcome})
        finally:
            file.write_text(original)
            assert file.read_text() == original, label + ": restoration failed"
    results["positive_after"] = run("positive-after", True)
    results["source_restored"] = all((stage / p).read_text() == text for p, text in originals.items())
    (stage / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
