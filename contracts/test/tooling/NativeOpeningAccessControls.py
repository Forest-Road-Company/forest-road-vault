#!/usr/bin/env python3
"""Compile two incorrect native-migration guards against the runtime access-control inventory."""
from pathlib import Path
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).resolve()
stage = Path(tempfile.mkdtemp(prefix='frv-native-opening-access-controls-'))
print('Control checkout:', stage, flush=True)
shutil.copytree(source / 'src', stage / 'src')
copied = set()
def dependency(relative):
    if relative in copied:
        return
    assert relative.parts[0] in ('test', 'script') and 'audit-poc' not in relative.parts
    copied.add(relative)
    text = (source / relative).read_text()
    target = stage / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)
    for name in re.findall(r'import\s+(?:[^;]*?\s+from\s+)?["\x27]([^"\x27]+)["\x27]\s*;', text):
        if name.startswith('.'):
            child = ((source / relative).parent / name).resolve().relative_to(source)
            if child.parts[0] != 'src':
                dependency(child)
dependency(Path('test/invariant/AccessControlSurfaceInvariants.t.sol'))
(stage / 'lib').symlink_to((source / 'lib').resolve(), target_is_directory=True)
shutil.copy2(source / 'foundry.toml', stage / 'foundry.toml')
env = dict(os.environ, FOUNDRY_OUT=str(stage / 'out'), FOUNDRY_CACHE_PATH=str(stage / 'cache'),
           FOUNDRY_INVARIANT_RUNS='32', FOUNDRY_INVARIANT_DEPTH='64')
command = ['forge', 'test', '--offline', '--match-contract', 'INV_AccessControlSurface', '-vv']
test = Path('test/invariant/AccessControlSurfaceInvariants.t.sol')
test_hash = hashlib.sha256((stage / test).read_bytes()).hexdigest()
target = stage / 'src/ReserveManager.sol'
original = target.read_text()
from NativeOpeningControls import fragment
start, end, before = fragment(original, 'prepareContinuousAccrualMigration')
assert before.count('onlyRole(DEFAULT_ADMIN_ROLE)') == 1
cases = [
    ('migration-guard-removed', before.replace('onlyRole(DEFAULT_ADMIN_ROLE)', '')),
    ('migration-wrong-role', before.replace('onlyRole(DEFAULT_ADMIN_ROLE)', 'onlyRole(Roles.GUARDIAN_ROLE)')),
]

def run(label, positive):
    result = subprocess.run(command, cwd=stage, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, check=False)
    (stage / (label + '.log')).write_text(result.stdout)
    assert 'Compiler run successful!' in result.stdout or 'No files changed, compilation skipped' in result.stdout, label
    assert re.search(r'Ran \d+ test suites?', result.stdout), label
    assert (result.returncode == 0) == positive, label
    failures = re.findall(r'^\[FAIL[^\n]*', result.stdout, re.M)
    assert positive or failures, label
    if positive:
        assert '8 tests passed, 0 failed, 0 skipped' in result.stdout, label
    print(label, 'pass' if positive else str(len(failures)) + ' failing tests', flush=True)
    return {'exit_code': result.returncode, 'failures': failures}

rows = []
try:
    run('baseline', True)
    for label, after in cases:
        changed = original.replace(before, after)
        assert changed != original
        target.write_text(changed)
        assert target.read_text() == changed
        try:
            result = run(label, False)
            result.update(name=label, matches=1, before_sha256=hashlib.sha256(original.encode()).hexdigest(),
                          after_sha256=hashlib.sha256(changed.encode()).hexdigest())
            rows.append(result)
            (stage / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')
        finally:
            target.write_text(original)
            assert target.read_text() == original
            assert hashlib.sha256((stage / test).read_bytes()).hexdigest() == test_hash
    names = ['invariant_acl_probeTableIsTheWholeEnumeratedSurface',
             'test_acl_everyPrivilegedSelectorRefusesEveryUnauthorisedActor',
             'test_acl_surfaceEnumerationIsExhaustiveAndDriftProof',
             'test_acl_nativeMigrationIsEnumeratedAndAuthorized']
    for name in names:
        assert any(name in line for row in rows for line in row['failures']), name
    restored = run('restored', True)
    (stage / 'summary.json').write_text(json.dumps({'cases': len(rows), 'tested_functions': names,
        'unchanged_test_sha256': test_hash, 'restored': restored}, indent=2) + '\n')
finally:
    target.write_text(original)
    assert target.read_bytes() == (source / 'src/ReserveManager.sol').read_bytes()
