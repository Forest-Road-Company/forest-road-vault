#!/usr/bin/env python3
"""Check the local pinned-fork rehearsal with compiled defects and incorrect calldata."""
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
    endpoint = os.environ.get('ACCRUAL_LEDGER_FORK_RPC_URL')
    if not endpoint:
        raise SystemExit('ACCRUAL_LEDGER_FORK_RPC_URL is required for read-only fork access')
    stage = Path(tempfile.mkdtemp(prefix='frv-ledger-fork-controls-'))
    print('Control checkout:', stage, flush=True)
    shutil.copytree(source / 'src', stage / 'src')
    (stage / 'lib').symlink_to((source / 'lib').resolve(), target_is_directory=True)
    test = 'test/fork/CommitmentLedgerReplacementFork.t.sol'
    (stage / test).parent.mkdir(parents=True)
    shutil.copy2(source / test, stage / test)
    (stage / 'foundry.toml').write_text('''[profile.default]
src = "src"
test = "test"
libs = ["lib"]
solc_version = "0.8.30"
evm_version = "cancun"
optimizer = true
optimizer_runs = 100
deny_warnings = true
ignored_error_codes = [5574, 3860, 4591]
gas_limit = 4000000000
[rpc_endpoints]
ledger_rehearsal = "${ACCRUAL_LEDGER_FORK_RPC_URL}"
''')
    env = dict(os.environ, FOUNDRY_OUT=str(stage / 'out'), FOUNDRY_CACHE_PATH=str(stage / 'cache'))
    command = ['forge', 'test', '--offline', '--fork-url', 'ledger_rehearsal',
               '--fork-block-number', '25963259', '--match-contract',
               'CommitmentLedgerReplacementForkTest', '-vv']

    def run(label, success):
        result = subprocess.run(command, cwd=stage, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
        output = re.sub(r'https?://[^\s]+', '[URL REDACTED]', result.stdout.replace(endpoint, '[RPC REDACTED]'))
        (stage / (label + '.log')).write_text(output)
        assert 'Compiler run successful!' in output or 'No files changed, compilation skipped' in output, label
        assert re.search(r'Ran \d+ test', output) and '3 total tests' in output, label + ': incomplete test run'
        assert not re.search(r'\b[1-9]\d* skipped\b', output), label + ': fork test skipped'
        assert (result.returncode == 0) == success, label + ': unexpected result'
        failures = sorted(set(re.findall(r'^\[FAIL[^\n]*', output, flags=re.M)))
        assert success or failures, label + ': no test failed'
        print(label, 'pass' if success else str(len(failures)) + ' failing tests', flush=True)
        return {'exit_code': result.returncode, 'failed_tests': failures}

    cases = [
        ('upgrade-calldata-unexpectedly-repoints', test,
         'manager.upgradeToAndCall(address(next), data);',
         'manager.upgradeToAndCall(address(next), data.length == 0 ? '
         'abi.encodeCall(IDefaultManager.replaceCommitmentLedger, ()) : data);',
         'test_fork_implementationUpgradeAlonePreservesTheOldLedger',
         'implementation upgrade unexpectedly replaced the plain ledger'),
        ('replacement-writes-an-unrelated-slot', 'src/libraries/DefaultAccrualLib.sol',
         '$.commitmentLedger = ICommitmentLedger(ledger);',
         '$.commitmentLedger = ICommitmentLedger(ledger);\n        assembly { sstore(0xa11, 1) }',
         'test_fork_atomicUpgradeAndRepointPreserveAllOtherStorage',
         'replacement wrote an unrelated proxy slot'),
        ('row-walk-restored', 'src/CommitmentLedger.sol',
         'uint256 principal = $.remainingPrincipalByClass[classId];',
         'uint256 principal;\n            for (uint256 row; row < $.eventIds.length; ++row) {\n'
         '                uint256 id = $.eventIds[row];\n'
         '                if (($.eventMetadata[id] & CLASS_MASK) == classId) '
         'principal += $.entries[id].remainingPrincipal;\n            }',
         'test_fork_managerReadGasAtZeroFiftyAndTwoHundredRows',
         'populated manager read grows with declared row count'),
    ]
    originals = {path: (stage / path).read_text() for _, path, *_ in cases}
    reference = source / 'test/helpers/CommitmentLedgerReference.sol'
    reference_hash = hashlib.sha256(reference.read_bytes()).hexdigest()
    results = []
    try:
        run('baseline', True)
        for label, path, before, after, function, reason in cases:
            original = originals[path]
            assert original.count(before) == 1, (label, original.count(before))
            changed = original.replace(before, after)
            assert changed != original
            target = stage / path
            target.write_text(changed)
            assert target.read_text() == changed
            try:
                result = run(label, False)
                assert any(function in line and reason in line for line in result['failed_tests']), label
                result.update(name=label, path=path, matches=1, target_test=function,
                              source_before_sha256=hashlib.sha256(original.encode()).hexdigest(),
                              source_after_sha256=hashlib.sha256(changed.encode()).hexdigest())
                results.append(result)
                (stage / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
            finally:
                target.write_text(original)
                assert target.read_text() == original
                assert hashlib.sha256(reference.read_bytes()).hexdigest() == reference_hash
        functions = set(re.findall(r'function (test\w+)\(', (source / test).read_text()))
        assert functions == {row['target_test'] for row in results}, 'a fork test has no demonstrated failure'
        restored = run('restored', True)
        (stage / 'summary.json').write_text(json.dumps({
            'block': 25963259, 'cases': len(results), 'test_functions_detected': sorted(functions),
            'calldata_controls': 1, 'production_defects': 2,
            'reference_sha256': reference_hash, 'restored': restored,
        }, indent=2) + '\n')
        print('Verified fork controls:', len(results), flush=True)
    finally:
        for path, original in originals.items():
            (stage / path).write_text(original)
            assert (stage / path).read_bytes() == (source / path).read_bytes()
        assert hashlib.sha256(reference.read_bytes()).hexdigest() == reference_hash


if __name__ == '__main__':
    main()
