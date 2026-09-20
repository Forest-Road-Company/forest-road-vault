#!/usr/bin/env python3
"""Demonstrate that opening-balance and continued-debt tests detect compiled defects."""
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
    stage = Path(tempfile.mkdtemp(prefix='frv-accrual-opening-controls-'))
    print('Control checkout:', stage, flush=True)
    shutil.copytree(source / 'src', stage / 'src')
    (stage / 'lib').symlink_to((source / 'lib').resolve(), target_is_directory=True)
    tests = ['test/unit/AccrualOpeningImport.t.sol', 'test/unit/AccrualOpeningSequences.t.sol',
             'test/unit/AccrualLoanSequences.t.sol', 'test/helpers/AccrualDebtReference.sol']
    for relative in tests:
        target = stage / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / relative, target)
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
               'AccrualOpening(Import|Sequences)Test', '--fuzz-runs', '64', '-vv']

    def run(label, success):
        result = subprocess.run(command, cwd=stage, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
        (stage / (label + '.log')).write_text(result.stdout)
        assert 'Compiler run successful!' in result.stdout or 'No files changed, compilation skipped' in result.stdout, label
        summary = re.search(r'Ran \d+ test suites? in .*: (\d+) tests passed, (\d+) failed, (\d+) skipped', result.stdout)
        assert summary, label + ': compiled tests did not finish'
        counts = list(map(int, summary.groups()))
        assert (result.returncode == 0) == success, label + ': unexpected result'
        failures = sorted(set(re.findall(r'^\[FAIL[^\n]*', result.stdout, flags=re.M)))
        assert success or failures, label + ': no test failed'
        assert counts[2] == 0 and sum(counts) == len(functions), (label, counts, len(functions))
        print(label, counts, flush=True)
        return {'exit_code': result.returncode, 'counts': counts, 'failed_tests': failures}

    loans = 'src/libraries/AccrualLoans.sol'
    book = 'src/libraries/AccrualBook.sol'
    cases = [
        ('historical-entitlement-subtracted-from-future-room', loans,
         'cap: _add(previous, f.balanceCeiling - face),',
         'cap: f.balanceCeiling - face + previous * 0,'),
        ('recognized-face-charged-again', loans,
         'income = _add(loan.principal, loan.unpaidInterest) - opening.recordedFace;',
         'income = _add(loan.principal, loan.unpaidInterest);'),
        ('opening-income-not-credited', loans,
         'if (income != 0) self.book.creditStoppedCorrection(facilityId, income, at);',
         'if (income == type(uint256).max) self.book.creditStoppedCorrection(facilityId, income, at);'),
        ('original-rounding-cursor-discarded', loans,
         'periodStart: opening.periodStart,', 'periodStart: f.fundedAt,'),
        ('frozen-pik-basis-replaced-with-principal', loans,
         'uint256 basis = f.pik && f.frozenPikBasis != 0 ? f.frozenPikBasis : f.principal;',
         'uint256 basis = f.principal;'),
        ('unpaid-opening-interest-discarded', loans,
         'loan.unpaidInterest = opening.interest;', 'loan.unpaidInterest = 0;'),
        ('declared-stop-ignored', loans,
         'bool active = !opening.permanentlyStopped && at < f.maturity;',
         'bool active = at < f.maturity;'),
        ('maturity-ignored-at-import', loans,
         'bool active = !opening.permanentlyStopped && at < f.maturity;',
         'bool active = !opening.permanentlyStopped;'),
        ('permanent-stop-flag-discarded', loans,
         'loan.permanentlyStopped = opening.permanentlyStopped;', 'loan.permanentlyStopped = false;'),
        ('zero-opening-face-accepted', loans,
         'if (face == 0 || face > f.balanceCeiling || opening.recordedFace > face) {',
         'if (face > f.balanceCeiling || opening.recordedFace > face) {'),
        ('opening-above-ceiling-accepted', loans,
         'if (face == 0 || face > f.balanceCeiling || opening.recordedFace > face) {',
         'if (face == 0 || opening.recordedFace > face) {'),
        ('opening-backing-reduction-accepted', loans,
         'if (face == 0 || face > f.balanceCeiling || opening.recordedFace > face) {',
         'if (face == 0 || face > f.balanceCeiling) {'),
        ('cash-frozen-basis-accepted', loans,
         'if (f.frozenPikBasis > MAX_BASIS || (!f.pik && f.frozenPikBasis != 0)) {',
         'if (f.frozenPikBasis > MAX_BASIS) {'),
        ('oversize-frozen-basis-accepted', loans,
         'if (f.frozenPikBasis > MAX_BASIS || (!f.pik && f.frozenPikBasis != 0)) {',
         'if (!f.pik && f.frozenPikBasis != 0) {'),
        ('future-cursor-accepted', loans,
         'opening.periodStart > at || opening.periodStart >= f.maturity || f.paymentInterval == 0',
         'opening.periodStart >= f.maturity || f.paymentInterval == 0'),
        ('cursor-after-maturity-accepted', loans,
         'opening.periodStart > at || opening.periodStart >= f.maturity || f.paymentInterval == 0',
         'opening.periodStart > at || f.paymentInterval == 0'),
        ('zero-opening-interval-accepted', loans,
         'opening.periodStart > at || opening.periodStart >= f.maturity || f.paymentInterval == 0',
         'opening.periodStart > at || opening.periodStart >= f.maturity'),
        ('due-after-maturity-accepted', loans,
         '(f.nextPaymentDue > f.maturity || f.paymentInterval > f.nextPaymentDue)',
         '(f.paymentInterval > f.nextPaymentDue)'),
        ('impossible-original-interval-accepted', loans,
         '(f.nextPaymentDue > f.maturity || f.paymentInterval > f.nextPaymentDue)',
         '(f.nextPaymentDue > f.maturity)'),
        ('unsettled-pik-boundary-accepted', loans,
         '(active && f.pik && f.nextPaymentDue != 0 && f.nextPaymentDue <= at)',
         '(active && f.pik && f.nextPaymentDue != 0 && f.nextPaymentDue < opening.periodStart)'),
        ('past-due-cash-refused', loans,
         '(active && f.pik && f.nextPaymentDue != 0 && f.nextPaymentDue <= at)',
         '(active && f.nextPaymentDue != 0 && f.nextPaymentDue <= at)'),
        ('opening-ceiling-bound-omitted', loans,
         '_validateCeiling(f.balanceCeiling);', '_validateCeiling(f.principal);'),
        ('opening-clock-replaced-with-book-clock', loans,
         'uint64 at = opening.terms.fundedAt;', 'uint64 at = self.book.total.at;'),
        ('work-admission-limit-doubled', loans,
         'if (requested > MAX_ANNUAL_WORK) revert AccrualLoans_WorkCapacity(requested);',
         'if (requested > MAX_ANNUAL_WORK * 2) revert AccrualLoans_WorkCapacity(requested);'),
        ('portfolio-capacity-increased', book,
         'if (self.registered == MAX_FACILITIES) revert AccrualBook_Capacity();',
         'if (self.registered == MAX_FACILITIES + 1) revert AccrualBook_Capacity();'),
        ('retired-identifier-reused', book,
         'if (e.known) revert AccrualBook_KnownFacility(facilityId);',
         'if (e.registered) revert AccrualBook_KnownFacility(facilityId);'),
        ('maturity-stub-capitalizes', loans,
         'loan.nextCapitalization = f.nextPaymentDue;',
         'loan.nextCapitalization = f.nextPaymentDue == 0 ? f.maturity : f.nextPaymentDue;'),
        ('binding-cap-time-backfilled', loans,
         'bool capPaused = prior.capReachable && prior.capHit <= at;',
         'bool capPaused = prior.capReachable && prior.capHit > at;'),
        ('interest-only-pik-boundary-omitted', loans,
         'if (loan.terms.rateBps == 0 || (!loan.pik && loan.terms.basis == 0)) return;',
         'if (loan.terms.rateBps == 0 || loan.terms.basis == 0) return;'),
        ('opening-rate-incremented', loans,
         'rateBps: f.rateBps', 'rateBps: f.rateBps + 1'),
    ]
    originals = {path: (stage / path).read_text() for _, path, *_ in cases}
    test_hashes = {path: hashlib.sha256((stage / path).read_bytes()).hexdigest() for path in tests}
    functions = set()
    for relative in (tests[0], tests[2]):
        functions.update(re.findall(r'function (test\w+)\(', (stage / relative).read_text()))
    results = []
    try:
        baseline = run('baseline', True)
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
                for relative, expected in test_hashes.items():
                    assert hashlib.sha256((stage / relative).read_bytes()).hexdigest() == expected
        detected = {name for name in functions if any(name in line for row in results for line in row['failed_tests'])}
        assert functions == detected, ('tests not demonstrated to fail', sorted(functions - detected))
        restored = run('restored', True)
        (stage / 'summary.json').write_text(json.dumps({
            'cases': len(results), 'test_functions_detected': sorted(detected),
            'unchanged_test_sha256': test_hashes, 'baseline': baseline, 'restored': restored,
        }, indent=2) + '\n')
    finally:
        for relative, original in originals.items():
            (stage / relative).write_text(original)
            assert (stage / relative).read_text() == original


if __name__ == '__main__':
    main()
