#!/usr/bin/env python3
"""Demonstrate opening-kind reach and complete oracle state comparison in the invariant model."""
from pathlib import Path
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile


def main():
    source = Path(sys.argv[1]).resolve()
    stage = Path(tempfile.mkdtemp(prefix='frv-opening-oracle-invariant-controls-'))
    print('Control checkout:', stage, flush=True)
    shutil.copytree(source / 'src', stage / 'src')
    shutil.copytree(source / 'test/invariant', stage / 'test/invariant')
    shutil.copy2(source / 'foundry.toml', stage / 'foundry.toml')
    (stage / 'lib').symlink_to((source / 'lib').resolve(), target_is_directory=True)
    env = dict(os.environ, FOUNDRY_OUT=str(stage / 'out'), FOUNDRY_CACHE_PATH=str(stage / 'cache'),
               FOUNDRY_INVARIANT_RUNS='16', FOUNDRY_INVARIANT_DEPTH='32')
    handler = 'test/invariant/handlers/OracleHandler.sol'
    oracle = 'src/AttestationOracle.sol'
    originals = {p: (stage / p).read_text() for p in [handler, oracle]}
    suite = stage / 'test/invariant/OracleInvariants.t.sol'
    suite_hash = hashlib.sha256(suite.read_bytes()).hexdigest()
    cases = [
        ('opening-absent-from-general-actions', handler, 'uint8 k = seed % 10;', 'uint8 k = seed % 9;', None),
        ('opening-absent-from-one-shot-actions', handler, 'uint8 k = seed % 9;', 'uint8 k = seed % 8;', None),
    ]
    for kind in ['AccrualOpening', 'TermsAmended']:
        cases.append((kind + '-view-differs-from-model', oracle,
                      'return (r.payload, r.asOf, r.satisfied);',
                      'return (r.payload ^ (kind == AttestationKind.' + kind +
                      ' && facilityId == 0 ? bytes32(uint256(1)) : bytes32(0)), r.asOf, r.satisfied);',
                      'invariant_oracle_ghostParity'))

    def run(label, success):
        result = subprocess.run(['forge', 'test', '--offline', '--match-contract', 'OracleInvariants', '-vv'],
                                cwd=stage, env=env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, check=False)
        (stage / (label + '.log')).write_text(result.stdout)
        assert 'Compiler run successful!' in result.stdout or 'No files changed, compilation skipped' in result.stdout, label
        summary = re.search(r'Ran \d+ test suites? in .*: (\d+) tests passed, (\d+) failed, (\d+) skipped', result.stdout)
        assert summary, label + ': no completed compiled test run'
        counts = list(map(int, summary.groups()))
        failures = sorted(set(re.findall(r'^\[FAIL[^\n]*', result.stdout, flags=re.M)))
        assert (result.returncode == 0) == success, (label, counts)
        assert counts[2] == 0 and (success or counts[1] > 0), label
        print(label, counts, flush=True)
        return {'exit_code': result.returncode, 'counts': counts, 'failed_tests': failures}

    results = []
    try:
        baseline = run('baseline', True)
        for label, relative, before, after, expected in cases:
            original = originals[relative]
            assert original.count(before) == 1, (label, original.count(before))
            changed = original.replace(before, after)
            assert changed != original
            target = stage / relative
            target.write_text(changed)
            assert target.read_text() == changed
            try:
                row = run(label, False)
                if expected:
                    assert any(expected in line for line in row['failed_tests']), row
                row.update(name=label, path=relative, matches=1,
                           source_before_sha256=hashlib.sha256(original.encode()).hexdigest(),
                           source_after_sha256=hashlib.sha256(changed.encode()).hexdigest())
                results.append(row)
                (stage / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
            finally:
                target.write_text(original)
                assert target.read_text() == original
                assert hashlib.sha256(suite.read_bytes()).hexdigest() == suite_hash
        restored = run('restored', True)
        (stage / 'summary.json').write_text(json.dumps({
            'cases': len(results), 'unchanged_invariant_suite_sha256': suite_hash,
            'baseline': baseline, 'restored': restored,
        }, indent=2) + '\n')
    finally:
        for relative, original in originals.items():
            (stage / relative).write_text(original)
            assert (stage / relative).read_text() == original


if __name__ == '__main__':
    main()
