#!/usr/bin/env python3
"""Check native waterfall binding, servicing quotes and checkpoints with compiled defects."""
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
    stage = Path(tempfile.mkdtemp(prefix='frv-waterfall-accrual-controls-'))
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

    test = Path('test/unit/WaterfallAccrualGuards.t.sol')
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
               'WaterfallAccrual(Binding|Status|Native)GuardsTest', '--fuzz-runs', '256', '-vv']

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
            assert '6 tests passed, 0 failed, 0 skipped' in result.stdout, label
        print(label, 'pass' if success else str(len(failures)) + ' failing tests', flush=True)
        return {'exit_code': result.returncode, 'failed_tests': failures}

    library = 'src/libraries/WaterfallAccrualLib.sol'
    host = 'src/WaterfallEngine.sol'
    cases = [
        ('binding-admin-gate-omitted', host,
         'function setAccrualReserve(address reserve) external onlyRole(DEFAULT_ADMIN_ROLE) {',
         'function setAccrualReserve(address reserve) external {'),
        ('binding-permanence-gate-omitted', host,
         'if ($.accrualReserve != address(0)) revert Waterfall_AccrualAlreadyBound();',
         'if ($.accrualReserve == address(0xBAD)) revert Waterfall_AccrualAlreadyBound();'),
        ('wrong-native-waterfall-accepted', library,
         'm.waterfall != address(this)', 'm.waterfall == address(0)'),
        ('dirty-controller-word-accepted', library,
         'controller[1] > type(uint160).max', 'controller[1] > type(uint256).max'),
        ('oversized-reply-accepted', library,
         'if (!ok || data.length != length)', 'if (!ok || data.length < length)'),
        ('unknown-status-not-blocked', library,
         'if (!d.known) return (false, true);', 'if (!d.known) return (false, false);'),
        ('busy-status-not-blocked', library,
         'catch {\n            return (false, true);\n        }',
         'catch {\n            return (false, false);\n        }'),
        ('dormant-status-ignores-shared-backlog', library,
         'return (fresh, !fresh);', 'return (fresh || !fresh, false);'),
        ('interest-only-debt-treated-as-empty', library,
         '(d.principal == 0 && d.interest == 0)', '(d.principal == 0 || d.interest == 0)'),
        ('queued-status-never-due', library,
         'return (true, false);', 'return (false, false);'),
        ('inactive-or-future-status-reported-due', library,
         ') return (false, false);\n        try IAccrualExposure',
         ') return (true, false);\n        try IAccrualExposure'),
        ('nonperforming-status-reported-blocked', library,
         '            return (false, false);\n        }\n        IAccrualLifecycle.Debt memory d',
         '            return (false, true);\n        }\n        IAccrualLifecycle.Debt memory d'),
        ('cash-checkpoint-admitted', library,
         'if (!f.pik) revert IWaterfallEngine.Waterfall_PikNotDesignated(tokenId);',
         'if (!f.pik && tokenId == 0) revert IWaterfallEngine.Waterfall_PikNotDesignated(tokenId);'),
        ('nonperforming-checkpoint-admitted', library,
         'if (f.state != ClaimBridge.LoanState.Active && f.state != ClaimBridge.LoanState.Amortizing) {\n'
         '            revert IWaterfallEngine.Waterfall_PikNotPerforming',
         'if (f.state == ClaimBridge.LoanState.Cancelled) {\n'
         '            revert IWaterfallEngine.Waterfall_PikNotPerforming'),
        ('unknown-checkpoint-admitted', library,
         'if (!before_.known) revert IWaterfallEngine.Waterfall_PikNotFunded(tokenId);',
         'if (!before_.known && tokenId == 0) revert IWaterfallEngine.Waterfall_PikNotFunded(tokenId);'),
        ('empty-checkpoint-admitted', library,
         'if (before_.principal == 0 && before_.interest == 0) {',
         'if (before_.principal == 0 && before_.interest == 0 && tokenId == 0) {'),
        ('dormant-service-gate-inverted', library,
         'if (fresh && !IAccrualServicing(reserve).accrualLoanScheduled(tokenId)) {',
         'if (!fresh && !IAccrualServicing(reserve).accrualLoanScheduled(tokenId)) {'),
        ('capitalization-return-halved', library,
         'capitalized = IAccrualLifecycle(reserve).accruedDebt(tokenId).principal - before_.principal;',
         'capitalized = (IAccrualLifecycle(reserve).accruedDebt(tokenId).principal - before_.principal) / 2;'),
    ]
    originals = {path: (stage / path).read_text() for _, path, *_ in cases}
    test_hash = hashlib.sha256((stage / test).read_bytes()).hexdigest()
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
        for path, original in originals.items():
            (stage / path).write_text(original)
            assert (stage / path).read_bytes() == (source / path).read_bytes()
        assert hashlib.sha256((stage / test).read_bytes()).hexdigest() == test_hash


if __name__ == '__main__':
    main()
