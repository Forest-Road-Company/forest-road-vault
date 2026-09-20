#!/usr/bin/env python3
"""Check constant-cost ledger reads and PIK servicing with compiled defects."""
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
    stage = Path(tempfile.mkdtemp(prefix='frv-ledger-servicing-controls-'))
    print('Control checkout:', stage, flush=True)
    shutil.copytree(source / 'src', stage / 'src')
    (stage / 'lib').symlink_to((source / 'lib').resolve(), target_is_directory=True)
    copied = set()

    def dependency(relative):
        if relative in copied:
            return
        assert relative.parts[0] in ('test', 'script') and 'audit-poc' not in relative.parts, relative
        copied.add(relative)
        content = (source / relative).read_text()
        target = stage / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
        for name in re.findall(r'import\s+(?:[^;]*?\s+from\s+)?["\x27]([^"\x27]+)["\x27]\s*;', content):
            if name.startswith('.'):
                child = ((source / relative).parent / name).resolve().relative_to(source)
                if child.parts[0] != 'src':
                    dependency(child)

    test = Path('test/unit/PikLiveness.t.sol')
    other = Path('test/audit/W7_PerEventLadder.t.sol')
    dependency(test)
    dependency(other)
    (stage / 'foundry.toml').write_text('''[profile.default]
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
''')
    env = dict(os.environ, FOUNDRY_OUT=str(stage / 'out'), FOUNDRY_CACHE_PATH=str(stage / 'cache'))
    command = ['forge', 'test', '--offline', '--match-test',
               'test_(thirtyTwoDeclared|coldImpairment|pik_largeLedger|pik_retainedGas)', '--fuzz-runs', '256', '-vv']

    def run(label, success):
        result = subprocess.run(command, cwd=stage, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
        (stage / (label + '.log')).write_text(result.stdout)
        assert 'Compiler run successful!' in result.stdout or 'No files changed, compilation skipped' in result.stdout, label
        assert re.search(r'Ran \d+ test', result.stdout), label + ': no tests ran'
        assert (result.returncode == 0) == success, label + ': unexpected result'
        failures = sorted(set(re.findall(r'^\[FAIL[^\n]*', result.stdout, flags=re.M)))
        assert success or failures, label + ': no test failed'
        if success:
            assert '4 tests passed, 0 failed, 0 skipped' in result.stdout, label
        print(label, 'pass' if success else str(len(failures)) + ' failing tests', flush=True)
        return {'exit_code': result.returncode, 'failed_tests': failures}

    library = 'src/CommitmentLedger.sol'
    host = 'src/DefaultManager.sol'
    cases = [
        ('row-walk-restored', library,
         'uint256 principal = $.remainingPrincipalByClass[classId];',
         'uint256 principal;\n            for (uint256 row; row < $.eventIds.length; ++row) {\n                uint256 id = $.eventIds[row];\n                if (($.eventMetadata[id] & CLASS_MASK) == classId) principal += $.entries[id].remainingPrincipal;\n            }'),
        ('insufficient-retained-gas', host,
         'uint256 private constant PIK_SETTLE_RESERVE_SHIFT = 3;',
         'uint256 private constant PIK_SETTLE_RESERVE_SHIFT = 6;'),
        ('incorrect-servicing-selector', host,
         'bytes4 private constant PIK_CAPITALIZE_SELECTOR = 0x41a3f095;',
         'bytes4 private constant PIK_CAPITALIZE_SELECTOR = 0x41a3f096;'),
    ]
    originals = {path: (stage / path).read_text() for _, path, *_ in cases}
    test_hash = hashlib.sha256((stage / test).read_bytes() + (stage / other).read_bytes()).hexdigest()
    results = []
    try:
        run('baseline', True)
        for label, path, before, after in cases:
            original = originals[path]
            assert original.count(before) == 1, (label, original.count(before))
            changed = original.replace(before, after)
            assert changed != original
            target = stage / path
            target.write_text(changed)
            assert target.read_text() == changed
            try:
                result = run(label, False)
                result.update(name=label, path=path, matches=1,
                              source_before_sha256=hashlib.sha256(original.encode()).hexdigest(),
                              source_after_sha256=hashlib.sha256(changed.encode()).hexdigest())
                results.append(result)
                (stage / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
            finally:
                target.write_text(original)
                assert target.read_text() == original
                assert hashlib.sha256((stage / test).read_bytes() + (stage / other).read_bytes()).hexdigest() == test_hash
        functions = {name for name in re.findall(r'function (test\w+)\(', (source / test).read_text() + (source / other).read_text()) if re.match(r'test_(thirtyTwoDeclared|coldImpairment|pik_largeLedger|pik_retainedGas)', name)}
        detected = {name for name in functions if any(name in line for row in results for line in row['failed_tests'])}
        assert functions == detected, ('tests not demonstrated to fail', sorted(functions - detected))
        restored = run('restored', True)
        (stage / 'summary.json').write_text(json.dumps({
            'cases': len(results), 'test_functions_detected': sorted(detected),
            'unchanged_test_sha256': test_hash, 'restored': restored,
        }, indent=2) + '\n')
        print('Verified controls:', len(results), 'test functions:', len(detected), flush=True)
    finally:
        for path, original in originals.items():
            (stage / path).write_text(original)
            assert (stage / path).read_bytes() == (source / path).read_bytes()
        assert hashlib.sha256((stage / test).read_bytes() + (stage / other).read_bytes()).hexdigest() == test_hash


if __name__ == '__main__':
    main()
