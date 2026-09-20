#!/usr/bin/env python3
"""Run PIK settlement defect controls in an isolated source and test checkout."""

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
    root = Path(sys.argv[1]).resolve()
    stage = Path(tempfile.mkdtemp(prefix="frv-pik-settlement-controls-"))
    shutil.copytree(root / "src", stage / "src")
    shutil.copy2(root / "foundry.toml", stage / "foundry.toml")
    if (root / "remappings.txt").is_file():
        shutil.copy2(root / "remappings.txt", stage / "remappings.txt")
    (stage / "lib").symlink_to(root / "lib", target_is_directory=True)

    # Copy only the selected test's relative Solidity import closure. Never follow legacy
    # test roots, and never point a script or test symlink back at the source checkout.
    queue = [Path("test/invariant/CreditInvariants.t.sol")]
    copied = set()
    imports = re.compile(r'import\s+(?:[^;]*?\s+from\s+)?["\']([^"\']+)["\']\s*;')
    while queue:
        relative = queue.pop()
        if relative in copied or relative.parts[0] in {"src", "lib"}:
            continue
        assert relative.parts[0] in {"test", "script"}, relative
        assert not {"audit-poc", "audit-invariant"}.intersection(relative.parts)
        source = root / relative
        text = source.read_text()
        target = stage / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        copied.add(relative)
        for imported in imports.findall(text):
            if imported.startswith("."):
                dependency = Path(os.path.normpath(source.parent / imported)).relative_to(root)
                queue.append(dependency)
            elif imported.startswith(("test/", "src/", "script/")):
                queue.append(Path(imported))

    env = dict(os.environ, FOUNDRY_OUT=str(stage / "out"),
               FOUNDRY_CACHE_PATH=str(stage / "cache"))
    base = ["forge", "test", "--root", str(stage), "--offline", "--match-path",
            "test/invariant/CreditInvariants.t.sol"]
    witnesses = "test_wiring_pastDueAction"
    campaign = "invariant_backing_supplyNeverExceedsBacking"
    results = []

    def run(label, pattern, succeeds, campaign_run=False):
        command = base + ["--match-test", pattern]
        settings = dict(env)
        if campaign_run:
            settings.update(FOUNDRY_INVARIANT_RUNS="64", FOUNDRY_INVARIANT_DEPTH="128")
            command += ["--fuzz-seed", "0x" + "0" * 60 + "0912"]
        with (stage / (label + ".log")).open("w") as output:
            result = subprocess.run(command, cwd=stage, env=settings,
                                    stdout=output, stderr=subprocess.STDOUT)
        output = (stage / (label + ".log")).read_text()
        assert "Ran 1 test suite" in output, output[-4000:]
        assert "Compiler run failed" not in output
        if succeeds:
            assert result.returncode == 0 and "0 failed, 0 skipped" in output, output[-4000:]
        else:
            assert result.returncode != 0 and "[FAIL" in output, output[-4000:]
        return output

    run("positive-before", witnesses, True)
    run("campaign-positive-before", campaign, True, True)
    manager = stage / "src/DefaultManager.sol"
    fixture = stage / "test/helpers/CreditLayerFixture.sol"
    handler = stage / "test/invariant/handlers/CreditHandler.sol"
    originals = {p: p.read_text() for p in (manager, fixture, handler)}
    matches = list(re.finditer(r"    function _settlePikPeriod\(.*?(?=\n    function _storage\()",
                              originals[manager], re.S))
    assert len(matches) == 1
    function = matches[0][0]
    assert "ok := call(forwarded, engine" in function
    wiring = "        defaultManager.setWaterfall(address(waterfall)); // exercise PIK settlement before a past-due mark\n"
    timing = """        if (f.pik) {
            uint256 paymentWindows = uint256(f.nextPaymentDue) + 2 * window;
            if (paymentWindows > graceEnd) graceEnd = paymentWindows;
        }
"""
    # A literal unconditional revert triggers solc unreachable-code warnings in the caller.
    # Preserve deny_warnings: this control instead reverts whenever gas remains. With zero
    # gas it cannot complete the subsequent EVM instructions, so every execution still fails.
    controls = [
        ("settlement-reverts", manager, function,
         "    function _settlePikPeriod(DefaultStorage storage, uint256) private view returns (bool) { if (gasleft() != 0) revert(); return false; }\n", True),
        ("settlement-skipped", manager, function,
         "    function _settlePikPeriod(DefaultStorage storage, uint256) private pure returns (bool) { return false; }\n", False),
        ("waterfall-unbound", fixture, wiring, "", False),
        ("terminal-window-omitted", handler, timing, "", False),
    ]
    try:
        for name, target, original, replacement, fuzzed in controls:
            pristine = originals[target]
            assert pristine.count(original) == 1, name
            changed = pristine.replace(original, replacement, 1)
            assert changed != pristine
            target.write_text(changed)
            output = run(name, witnesses, False)
            failing = re.findall(r"^\[FAIL[^\n]*\]\s+(test_wiring_pastDueAction\w+)\(", output, re.M)
            assert failing, output[-4000:]
            if fuzzed:
                fuzz_output = run(name + "-campaign", campaign, False, True)
                assert campaign in fuzz_output and "[FAIL" in fuzz_output
            results.append({"control": name, "replacement_sites": 1,
                            "changed_source_sha256": hashlib.sha256(changed.encode()).hexdigest(),
                            "failing_witnesses": sorted(set(failing)),
                            "invariant_campaign_executed": fuzzed,
                            "invariant_campaign_detected": True if fuzzed else None})
            target.write_text(pristine)
            print(name, "detected", flush=True)
    finally:
        for target, original in originals.items():
            target.write_text(original)
            assert target.read_text() == original
    run("positive-after", witnesses, True)
    run("campaign-positive-after", campaign, True, True)
    report = {"source_checkout": str(root), "isolated_checkout": str(stage),
              "copied_test_dependencies": len(copied), "controls": results,
              "isolated_sources_restored": True}
    (stage / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report), flush=True)


if __name__ == "__main__":
    main()
