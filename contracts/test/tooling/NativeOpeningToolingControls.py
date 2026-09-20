#!/usr/bin/env python3
"""Verify migration preparation and calldata regressions with compiled deliberate changes."""
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
stage = Path(tempfile.mkdtemp(prefix='frv-native-opening-tooling-controls-'))
print('Control checkout:', stage, flush=True)
shutil.copytree(source / 'src', stage / 'src')
pending = [source / 'test/unit/NativeOpeningTooling.t.sol']
seen = set()
while pending:
    path = pending.pop().resolve()
    relative = path.relative_to(source)
    assert 'audit-poc' not in relative.parts, relative
    if path in seen or relative.parts[0] == 'src':
        continue
    seen.add(path)
    text = path.read_text()
    target_file = stage / relative
    target_file.parent.mkdir(parents=True, exist_ok=True)
    target_file.write_text(text)
    for imported in re.findall(r'import\s+(?:[^;]*?from\s+)?[\"\']([^\"\']+)[\"\']\s*;', text):
        if imported.startswith('.'):
            pending.append(path.parent / imported)
shutil.copy2(source / 'foundry.toml', stage / 'foundry.toml')
(stage / 'lib').symlink_to((source / 'lib').resolve(), target_is_directory=True)
env = dict(os.environ, FOUNDRY_OUT=str(stage / 'out'), FOUNDRY_CACHE_PATH=str(stage / 'cache'))
command = ['forge', 'test', '--offline', '--match-contract', 'NativeOpening.*ToolingTest', '-vv']
target = stage / 'script/ContinuousAccrualMigration.sol'
original = target.read_text()
tests = {str(p.relative_to(stage)): hashlib.sha256(p.read_bytes()).hexdigest()
         for p in (stage / 'test').rglob('*.sol')}
cases = [
    ('missing-binding', 'ContinuousAccrualDeployment.bind(reserve, m);', ''),
    ('missing-quorum-initialization',
     'oracle.setThreshold(IAttestationOracle.AttestationKind.AccrualOpening, 2);', ''),
    ('higher-quorum-overwritten',
     'if (oracle.threshold(IAttestationOracle.AttestationKind.AccrualOpening) < 2)',
     'if (oracle.threshold(IAttestationOracle.AttestationKind.AccrualOpening) < 5)'),
    ('empty-roster-accepted-by-tooling',
     'IAccrualMigration(reserve).prepareContinuousAccrualMigration(abi.encode(uint8(0), abi.encode(ids)));',
     'if (ids.length != 0) IAccrualMigration(reserve).prepareContinuousAccrualMigration(abi.encode(uint8(0), abi.encode(ids)));'),
    ('inactive-payload-guard-omitted',
     'if (!progress.active) revert AccrualMigrationTool_NotPreparing();', ''),
    ('payload-session-omitted', 'progress.sessionKey, opening.facilityId,', 'bytes32(0), opening.facilityId,'),
    ('import-step-changed', 'abi.encode(uint8(1), abi.encode(openings))',
     'abi.encode(uint8(0), abi.encode(openings))'),
]


def run(label, positive):
    result = subprocess.run(command, cwd=stage, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
    (stage / (label + '.log')).write_text(result.stdout)
    assert 'Compiler run successful!' in result.stdout or 'No files changed, compilation skipped' in result.stdout, label
    summary = re.search(r'Ran \d+ test suites? in .*: (\d+) tests passed, (\d+) failed, (\d+) skipped', result.stdout)
    assert summary, label
    counts = list(map(int, summary.groups()))
    assert (result.returncode == 0) == positive and counts[2] == 0, (label, counts)
    assert positive or counts[1] > 0, label
    failures = re.findall(r'^\[FAIL[^\n]*', result.stdout, re.M)
    print(label, counts, flush=True)
    return {'exit_code': result.returncode, 'counts': counts, 'failed_tests': failures}


results = []
try:
    baseline = run('baseline', True)
    for label, before, after in cases:
        assert original.count(before) == 1, label
        changed = original.replace(before, after)
        assert changed != original
        target.write_text(changed)
        assert target.read_text() == changed
        try:
            row = run(label, False)
            row.update(name=label, matches=1, before_sha256=hashlib.sha256(original.encode()).hexdigest(),
                       after_sha256=hashlib.sha256(changed.encode()).hexdigest())
            results.append(row)
            (stage / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        finally:
            target.write_text(original)
            assert target.read_text() == original
            for name, expected in tests.items():
                assert hashlib.sha256((stage / name).read_bytes()).hexdigest() == expected, name
    names = set(re.findall(r'function\s+(test_\w+)\(',
                          (stage / 'test/unit/NativeOpeningTooling.t.sol').read_text()))
    detected = {name for name in names if any(name + '(' in line for row in results for line in row['failed_tests'])}
    assert detected == names, sorted(names - detected)
    restored = run('restored', True)
    (stage / 'summary.json').write_text(json.dumps({
        'cases': len(results), 'detected_test_functions': sorted(detected),
        'unchanged_test_sha256': tests, 'baseline': baseline, 'restored': restored,
    }, indent=2) + '\n')
finally:
    target.write_text(original)
    assert target.read_text() == original
