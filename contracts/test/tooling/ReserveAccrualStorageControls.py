#!/usr/bin/env python3
"""Require the shared reserve-clock tests to detect compiled accounting defects."""
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
    stage = Path(tempfile.mkdtemp(prefix='frv-reserve-clock-controls-'))
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

    test = Path('test/unit/ReserveAccrualStorageGuards.t.sol')
    dependency(test)
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
    command = ['forge', 'test', '--offline', '--match-contract',
               'ReserveAccrualStorage(Guards|Native)Test', '--fuzz-runs', '256', '-vv']

    def run(label, success):
        result = subprocess.run(command, cwd=stage, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
        (stage / (label + '.log')).write_text(result.stdout)
        assert 'Compiler run successful!' in result.stdout or 'No files changed, compilation skipped' in result.stdout, label
        assert re.search(r'Ran \d+ test', result.stdout) and '4 total tests' in result.stdout, label
        assert (result.returncode == 0) == success, label + ': unexpected result'
        failures = sorted(set(re.findall(r'^\[FAIL[^\n]*', result.stdout, flags=re.M)))
        assert success or failures, label + ': no test failed'
        print(label, 'pass' if success else str(len(failures)) + ' failing tests', flush=True)
        return {'exit_code': result.returncode, 'failed_tests': failures}

    cases = [
        ('clock-overflow-truncated',
         'if (block.timestamp > type(uint64).max) revert ReserveAccrual_TimeOverflow();',
         'if (block.timestamp == type(uint256).max) revert ReserveAccrual_TimeOverflow();'),
        ('overdue-frontier-not-capped',
         'if (boundary < at) at = boundary;', 'if (boundary == at) at = boundary;'),
        ('global-posting-subtraction-omitted',
         'return book.total.value + book.total.rate * (at - book.total.at) - book.posted;',
         'return book.total.value + book.total.rate * (at - book.total.at);'),
        ('facility-posting-subtraction-omitted',
         'return entry.clock.value + entry.clock.rate * (at - entry.clock.at) - entry.posted;',
         'return entry.clock.value + entry.clock.rate * (at - entry.clock.at);'),
        ('disabled-global-book-read',
         'if (!s.enabled) return 0;\n        AccrualBook.Book storage book',
         'if (s.enabled && !s.enabled) return 0;\n        AccrualBook.Book storage book'),
        ('disabled-facility-book-read',
         'if (!s.enabled) return 0;\n        AccrualBook.Entry storage entry',
         'if (s.enabled && !s.enabled) return 0;\n        AccrualBook.Entry storage entry'),
        ('unknown-facility-clock-read',
         'if (!entry.known) return 0;', 'if (!entry.known && facilityId == 0) return 0;'),
    ]
    target = stage / 'src/libraries/ReserveAccrualStorageLib.sol'
    original = target.read_text()
    test_hash = hashlib.sha256((stage / test).read_bytes()).hexdigest()
    results = []
    try:
        run('baseline', True)
        for label, before, after in cases:
            assert original.count(before) == 1, (label, original.count(before))
            changed = original.replace(before, after)
            assert changed != original
            target.write_text(changed)
            assert target.read_text() == changed
            try:
                result = run(label, False)
                if label == 'overdue-frontier-not-capped':
                    assert any('test_overdueNativeViewsStayAtTheSharedFrontierUntilCatchup' in line
                               for line in result['failed_tests']), 'native check did not detect the defect'
                result.update(name=label, matches=1,
                              source_before_sha256=hashlib.sha256(original.encode()).hexdigest(),
                              source_after_sha256=hashlib.sha256(changed.encode()).hexdigest())
                results.append(result)
                (stage / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
            finally:
                target.write_text(original)
                assert target.read_text() == original
                assert hashlib.sha256((stage / test).read_bytes()).hexdigest() == test_hash
        functions = set(re.findall(r'function (test\w+)\(', (source / test).read_text()))
        detected = {name for name in functions if any(name in line for row in results for line in row['failed_tests'])}
        assert functions == detected, ('tests not demonstrated to fail', sorted(functions - detected))
        restored = run('restored', True)
        (stage / 'summary.json').write_text(json.dumps({
            'cases': len(results), 'test_functions_detected': sorted(detected),
            'unchanged_test_sha256': test_hash, 'restored': restored,
        }, indent=2) + '\n')
        print('Verified controls:', len(results), 'test functions:', len(detected), flush=True)
    finally:
        target.write_text(original)
        assert target.read_bytes() == (source / 'src/libraries/ReserveAccrualStorageLib.sol').read_bytes()
        assert hashlib.sha256((stage / test).read_bytes()).hexdigest() == test_hash


if __name__ == '__main__':
    main()
