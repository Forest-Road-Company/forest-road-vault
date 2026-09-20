#!/usr/bin/env python3
"""Check that ledger accounting and read-cost tests detect specific compiled defects."""

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
    ethereum = (source / 'src/SGrove.sol').is_file()
    stage = Path(tempfile.mkdtemp(prefix='frv-ledger-controls-'))
    print('Control checkout:', stage, flush=True)
    shutil.copytree(source / 'src', stage / 'src')
    (stage / 'lib').symlink_to((source / 'lib').resolve(), target_is_directory=True)
    copied = set()

    def dependency(relative):
        if relative in copied:
            return
        assert relative.parts[0] == 'test' and 'audit-poc' not in relative.parts, relative
        copied.add(relative)
        contents = (source / relative).read_text()
        target = stage / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(contents)
        for name in re.findall(r'import\s+(?:[^;]*?\s+from\s+)?["\x27]([^"\x27]+)["\x27]\s*;', contents):
            if name.startswith('.'):
                child = ((source / relative).parent / name).resolve().relative_to(source)
                if child.parts[0] != 'src':
                    dependency(child)

    dependency(Path('test/unit/CommitmentLedgerResiduals.t.sol'))
    dependency(Path('test/invariant/CommitmentLedgerInvariants.t.sol'))
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
[profile.default.invariant]
runs = 16
depth = 64
fail_on_revert = true
''')
    env = dict(os.environ, FOUNDRY_OUT=str(stage / 'out'), FOUNDRY_CACHE_PATH=str(stage / 'cache'))
    command = ['forge', 'test', '--offline', '--match-contract',
               'CommitmentLedgerResidualsTest|CommitmentLedgerInvariants', '--fuzz-runs', '8', '-vv']

    def run(label, success):
        result = subprocess.run(command, cwd=stage, env=env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, check=False)
        (stage / (label + '.log')).write_text(result.stdout)
        assert ('Compiler run successful!' in result.stdout or
                'No files changed, compilation skipped' in result.stdout), label + ': compilation failed'
        assert re.search(r'Ran \d+ test', result.stdout), label + ': tests did not run'
        assert (result.returncode == 0) == success, label + ': unexpected test result'
        failures = sorted(set(re.findall(r'^\[FAIL[^\n]*', result.stdout, flags=re.M)))
        assert success or failures, label + ': no test failed'
        print(label, 'restored pass' if success else str(len(failures)) + ' failing tests', flush=True)
        return {'exit_code': result.returncode, 'failed_tests': failures}

    metadata = '$.eventMetadata[eventId]' if ethereum else '$.eventClass[eventId]'
    cases = [
        ('register-omits-class-total',
         metadata + ' = uint8(classId);\n        _setPrincipal($, eventId, remainingPrincipal);',
         metadata + ' = uint8(classId);\n        $.entries[eventId].remainingPrincipal = remainingPrincipal;'),
        ('update-omits-class-total',
         '_setPrincipal($, eventId, remainingPrincipal);\n        emit CommitmentPrincipalUpdated',
         '$.entries[eventId].remainingPrincipal = remainingPrincipal;\n        emit CommitmentPrincipalUpdated'),
        ('release-retains-class-total', '_setPrincipal($, eventId, 0);',
         '$.entries[eventId].remainingPrincipal = 0;'),
        ('class-total-halved',
         '$.remainingPrincipalByClass[classId] = $.remainingPrincipalByClass[classId] - previous + next;',
         '$.remainingPrincipalByClass[classId] = $.remainingPrincipalByClass[classId] - previous + next / 2;'),
        ('wrong-class-read', 'uint256 principal = $.remainingPrincipalByClass[classId];',
         'uint256 principal = $.remainingPrincipalByClass[1];'),
        ('past-due-curator-reused',
         '_min(principal, pool - curatorForPastDue)', '_min(principal, pool)'),
        ('getter-refusal-changed',
         'function remainingPrincipalForClass(uint256 classId) external view returns (uint256) {\n'
         '        if (classId == 0 || classId > Config.NUM_CLASSES) revert CommitmentLedger_InvalidClass(classId);',
         'function remainingPrincipalForClass(uint256 classId) external view returns (uint256) {\n'
         '        if (classId == 0 || classId > Config.NUM_CLASSES) revert CommitmentLedger_UnknownEvent(classId);'),
    ]
    if ethereum:
        cases += [
            ('unknown-sync-refusal-changed',
             'if (covered == 0) return false;\n        if ($.eventIndexPlusOne[eventId] == 0) revert CommitmentLedger_UnknownEvent(eventId);',
             'if (covered == 0) return false;\n        if ($.eventIndexPlusOne[eventId] == 0) revert CommitmentLedger_InvalidClass(eventId);'),
            ('sync-omits-class-total',
             '_setPrincipal($, eventId, remainingPrincipal);\n        emit CommitmentSynced',
             'entry.remainingPrincipal = remainingPrincipal;\n        emit CommitmentSynced'),
            ('zero-covered-sync-changes-principal', 'if (covered == 0) return false;',
             'if (covered == 0) { _setPrincipal($, eventId, remainingPrincipal); return false; }'),
            ('shared-reserve-reused-after-past-due', 's.reserve -= s.pastDueLayerTwo;',
             's.reserve -= 0;'),
            ('shared-reserve-halved', 's.reserve = ICascadeBackstop(s.backstop).coverageReserve();',
             's.reserve = ICascadeBackstop(s.backstop).coverageReserve() / 2;'),
            ('declared-curator-halved',
             'uint256 curatorForDeclared = _min(principal, pool - curatorForPastDue);',
             'uint256 curatorForDeclared = _min(principal, pool - curatorForPastDue) / 2;'),
        ]
        row_class = '$.eventMetadata[id] & CLASS_MASK'
    else:
        cases += [
            ('declared-curator-halved',
             'residual += principal - _min(principal, pool - curatorForPastDue);',
             'residual += principal - _min(principal, pool - curatorForPastDue) / 2;'),
            ('past-due-senior-halved', 'pastDueSenior += pastDue - curatorForPastDue;',
             'pastDueSenior += (pastDue - curatorForPastDue) / 2;'),
        ]
        row_class = '$.eventClass[id]'
    cases += [('row-walk-restored', 'uint256 principal = $.remainingPrincipalByClass[classId];',
               'uint256 principal;\n            for (uint256 row; row < $.eventIds.length; ++row) {\n'
               '                uint256 id = $.eventIds[row];\n'
               '                if ((' + row_class + ') == classId) principal += $.entries[id].remainingPrincipal;\n'
               '            }')]
    target = stage / 'src/CommitmentLedger.sol'
    original = target.read_text()
    reference = stage / 'test/helpers/CommitmentLedgerReference.sol'
    reference_hash = hashlib.sha256(reference.read_bytes()).hexdigest()
    results = []
    try:
        run('baseline', True)
        for label, before, after in cases:
            assert original.count(before) == 1, (label, original.count(before))
            changed = original.replace(before, after)
            assert changed != original and changed.count(after) >= 1, label
            target.write_text(changed)
            assert target.read_text() == changed, label + ': mutation not written'
            try:
                result = run(label, False)
                if label == 'row-walk-restored':
                    assert any('test_gasAtZeroFiftyAndTwoHundredRows' in x for x in result['failed_tests']), label
                result.update(name=label, source_before_sha256=hashlib.sha256(original.encode()).hexdigest(),
                              source_after_sha256=hashlib.sha256(changed.encode()).hexdigest(), matches=1)
                results.append(result)
                (stage / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
            finally:
                target.write_text(original)
                assert target.read_text() == original
                assert hashlib.sha256(reference.read_bytes()).hexdigest() == reference_hash
        functions = set(re.findall(r'function (test\w+)\(', (source / 'test/unit/CommitmentLedgerResiduals.t.sol').read_text()))
        detected = {name for name in functions if any(name in line for result in results for line in result['failed_tests'])}
        assert detected == functions, ('tests not shown to fail', sorted(functions - detected))
        assert any('invariant_classTotalsEqualTheSumOfLiveRows' in line
                   for result in results for line in result['failed_tests']), 'class-total invariant never failed'
        restored = run('restored', True)
        (stage / 'summary.json').write_text(json.dumps({'cases': len(results), 'test_functions_detected': sorted(detected),
            'reference_sha256': reference_hash, 'restored': restored}, indent=2) + '\n')
        print('Verified controls:', len(results), 'test functions:', len(detected), flush=True)
    finally:
        target.write_text(original)
        assert target.read_bytes() == (source / 'src/CommitmentLedger.sol').read_bytes()
        assert hashlib.sha256(reference.read_bytes()).hexdigest() == reference_hash


if __name__ == '__main__':
    main()
