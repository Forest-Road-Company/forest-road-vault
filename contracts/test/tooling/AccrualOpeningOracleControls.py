#!/usr/bin/env python3
"""Verify the opening-attestation regressions with separately compiled changes."""
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
    stage = Path(tempfile.mkdtemp(prefix='frv-opening-oracle-controls-'))
    print('Control checkout:', stage, flush=True)
    shutil.copytree(source / 'src', stage / 'src')
    tests = ['test/unit/AttestationOracle.t.sol', 'test/unit/AccrualOpeningOracle.t.sol']
    price_test = 'test/unit/AccrualOraclePriceCompatibility.t.sol'
    if (source / price_test).is_file():
        tests.append(price_test)
    for relative in tests:
        target = stage / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / relative, target)
    shutil.copy2(source / 'foundry.toml', stage / 'foundry.toml')
    (stage / 'lib').symlink_to((source / 'lib').resolve(), target_is_directory=True)
    env = dict(os.environ, FOUNDRY_OUT=str(stage / 'out'), FOUNDRY_CACHE_PATH=str(stage / 'cache'))
    command = ['forge', 'test', '--offline', '--match-contract', 'AccrualOpeningOracleTest|AccrualOraclePriceCompatibilityTest', '--fuzz-runs', '64', '-vv']
    target = stage / 'src/AttestationOracle.sol'
    original = target.read_text()
    test_hashes = {p: hashlib.sha256((stage / p).read_bytes()).hexdigest() for p in tests}
    test_functions = set(re.findall(r'function (test\w+)\(', (stage / tests[1]).read_text()))
    if price_test in tests:
        test_functions.update(re.findall(r'function (test\w+)\(', (stage / price_test).read_text()))
    last = 'ReserveAssetPrice' if 'AttestationKind.ReserveAssetPrice' in original else 'TermsAmended'
    cases = [
        ('opening-default-threshold-omitted',
         'k <= uint8(AttestationKind.AccrualOpening)', 'k <= uint8(AttestationKind.' + last + ')', 1),
        ('opening-not-classified-as-financial', ' || kind == AttestationKind.AccrualOpening', '',
         original.count(' || kind == AttestationKind.AccrualOpening')),
        ('unset-threshold-accepted', 'if (required == 0) revert Oracle_BadThreshold();',
         'if (required == 0 && a.kind != AttestationKind.AccrualOpening) revert Oracle_BadThreshold();', 1),
        ('opening-fact-reuse-accepted', 'if (oneShot) {',
         'if (oneShot && a.kind != AttestationKind.AccrualOpening) {', original.count('if (oneShot) {')),
        ('signature-payload-binding-omitted', 'uint8(a.kind), a.payload, a.asOf',
         'uint8(a.kind), bytes32(0), a.asOf', 2),
        ('signature-facility-binding-omitted', 'ATTESTATION_TYPEHASH, a.facilityId, uint8(a.kind)',
         'ATTESTATION_TYPEHASH, uint256(0), uint8(a.kind)', 2),
    ]

    if price_test in tests:
        cases += [
            ('price-zero-accepted', 'if (p == 0) revert Oracle_ZeroPrice();',
             'if (p == 1) revert Oracle_ZeroPrice();', 1),
            ('price-live-record-floor-omitted', 'if (r.asOf > priceFloor) priceFloor = r.asOf;',
             'if (r.asOf < priceFloor) priceFloor = r.asOf;', 1),
            ('price-revocation-floor-omitted',
             'if (r.asOf > $.assetPriceWatermarks[facilityId]) $.assetPriceWatermarks[facilityId] = r.asOf;',
             'if (r.asOf < $.assetPriceWatermarks[facilityId]) $.assetPriceWatermarks[facilityId] = r.asOf;', 1),
        ]

    def run(label, success):
        result = subprocess.run(command, cwd=stage, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
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
        for label, before, after, count in cases:
            assert count > 0 and original.count(before) == count, (label, count, original.count(before))
            changed = original.replace(before, after)
            assert changed != original
            target.write_text(changed)
            assert target.read_text() == changed
            try:
                row = run(label, False)
                row.update(name=label, matches=count,
                           source_before_sha256=hashlib.sha256(original.encode()).hexdigest(),
                           source_after_sha256=hashlib.sha256(changed.encode()).hexdigest())
                results.append(row)
                (stage / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
            finally:
                target.write_text(original)
                assert target.read_text() == original
                for relative, expected in test_hashes.items():
                    assert hashlib.sha256((stage / relative).read_bytes()).hexdigest() == expected
        detected = {name for name in test_functions if any(name in line for row in results for line in row['failed_tests'])}
        assert detected == test_functions, sorted(test_functions - detected)
        restored = run('restored', True)
        (stage / 'summary.json').write_text(json.dumps({
            'cases': len(results), 'new_test_functions_detected': sorted(detected),
            'unchanged_test_sha256': test_hashes, 'baseline': baseline, 'restored': restored,
        }, indent=2) + '\n')
    finally:
        target.write_text(original)
        assert target.read_text() == original


if __name__ == '__main__':
    main()
