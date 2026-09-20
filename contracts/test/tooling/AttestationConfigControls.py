#!/usr/bin/env python3
"""Compile three omission controls against the actual attestation validator and config."""
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
    chain = sys.argv[2]
    assert chain in ('bsc', 'ethereum')
    label = 'Bsc' if chain == 'bsc' else 'Mainnet'
    previous = 'ReserveAssetPrice' if chain == 'bsc' else 'TermsAmended'
    stage = Path(tempfile.mkdtemp(prefix='frv-' + chain + '-attestation-controls-'))
    print('Control checkout:', stage, flush=True)
    shutil.copytree(source / 'src', stage / 'src')
    shutil.copy2(source / 'foundry.toml', stage / 'foundry.toml')
    (stage / 'lib').symlink_to((source / 'lib').resolve(), target_is_directory=True)
    copied = set()

    def dependency(relative):
        if relative in copied or relative.parts[0] == 'src':
            return
        assert relative.parts[0] in ('test', 'script') and 'audit-poc' not in relative.parts
        copied.add(relative)
        text = (source / relative).read_text()
        target = stage / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        for name in re.findall(r'import\s+(?:[^;]*?\s+from\s+)?["\x27]([^"\x27]+)["\x27]\s*;', text):
            if name.startswith('.'):
                dependency(((source / relative).parent / name).resolve().relative_to(source))

    dependency(Path('test/unit/AttestationConfigValidation.t.sol'))
    originals = {str(p.relative_to(stage)): p.read_bytes()
                 for folder in ('src', 'test', 'script') for p in (stage / folder).rglob('*.sol')}
    hashes = {p: hashlib.sha256(value).hexdigest() for p, value in originals.items()}
    command = ['forge', 'test', '--offline', '--match-contract', 'AttestationConfigValidationTest', '-vv']
    env = dict(os.environ, FOUNDRY_OUT=str(stage / 'out'), FOUNDRY_CACHE_PATH=str(stage / 'cache'))
    threshold_test = 'test_validatorRefusesEveryIncorrectThresholdIncludingOpening'
    receipt_test = 'test_thresholdReceiptCommitsEveryValidEnumMember'

    def run(name, expected_failures):
        result = subprocess.run(command, cwd=stage, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
        (stage / (name + '.log')).write_text(result.stdout)
        assert 'Compiler run successful!' in result.stdout or 'No files changed, compilation skipped' in result.stdout, name
        summary = re.search(r'Ran \d+ test suites? in .*: (\d+) tests passed, (\d+) failed, (\d+) skipped', result.stdout)
        assert summary, name + ': no completed tests'
        counts = list(map(int, summary.groups()))
        assert counts == [2 - len(expected_failures), len(expected_failures), 0], (name, counts)
        assert (result.returncode == 0) == (not expected_failures), name
        for test_name in expected_failures:
            assert re.search(r'^\[FAIL[^\n]*' + test_name, result.stdout, re.M), (name, test_name)
        print(name, result.returncode, counts, flush=True)
        return {'exit_code': result.returncode, 'counts': counts,
                'log_sha256': hashlib.sha256(result.stdout.encode()).hexdigest()}

    controls = [
        ('validator-omits-opening', 'script/Validate' + label + '.s.sol',
         'kind <= uint256(IAttestationOracle.AttestationKind.AccrualOpening)',
         'kind <= uint256(IAttestationOracle.AttestationKind.' + previous + ')', [threshold_test]),
        ('receipt-omits-opening', 'script/' + label + 'Config.sol',
         'attestationThreshold(IAttestationOracle.AttestationKind.' + previous + '),\n'
         '                attestationThreshold(IAttestationOracle.AttestationKind.AccrualOpening)',
         'attestationThreshold(IAttestationOracle.AttestationKind.' + previous + ')', [receipt_test]),
        ('enum-extension', 'src/interfaces/IAttestationOracle.sol',
         '        AccrualOpening\n    }',
         '        AccrualOpening,\n        FutureKindForCompletenessControl\n    }',
         [threshold_test, receipt_test]),
    ]
    results = {'chain': chain, 'baseline': run('baseline', [])}
    try:
        for name, relative, before, after, failures in controls:
            original = originals[relative].decode()
            assert original.count(before) == 1 and before != after, name
            changed = original.replace(before, after)
            target = stage / relative
            target.write_text(changed)
            assert target.read_text() == changed and before not in changed, name
            try:
                results[name] = run(name, failures)
                results[name].update({'applied_matches': 1,
                                     'changed_source_sha256': hashlib.sha256(changed.encode()).hexdigest()})
            finally:
                target.write_bytes(originals[relative])
    finally:
        for path, content in originals.items():
            (stage / path).write_bytes(content)
        for path, value in hashes.items():
            assert hashlib.sha256((stage / path).read_bytes()).hexdigest() == value, path
    results['restored'] = run('restored', [])
    results['restored_source_and_test_sha256'] = hashes
    (stage / 'summary.json').write_text(json.dumps(results, indent=2) + '\n')
    print('All three compiled omissions detected; every source and test restored.', flush=True)


if __name__ == '__main__':
    main()
