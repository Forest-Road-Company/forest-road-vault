#!/usr/bin/env python3
"""Compile deliberately changed native opening paths and verify named regressions fail."""
from pathlib import Path
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile


def sha(data):
    return hashlib.sha256(data).hexdigest()


def code_mask(source):
    pattern = r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\''
    return re.sub(pattern, lambda match: re.sub(r'[^\n]', ' ', match[0]), source)


def close_delimiter(masked, start, left, right):
    assert masked[start] == left
    depth = 0
    for i in range(start, len(masked)):
        if masked[i] == left:
            depth += 1
        elif masked[i] == right:
            depth -= 1
            if depth == 0:
                return i
    raise AssertionError('unclosed delimiter')


def fragment(source, name):
    masked = code_mask(source)
    starts = list(re.finditer(r'\bfunction\s+' + re.escape(name) + r'\s*\(', masked))
    assert len(starts) == 1, (name, len(starts))
    start = starts[0].start()
    opening = masked.index('{', starts[0].end())
    end = close_delimiter(masked, opening, '{', '}') + 1
    return start, end, source[start:end]


def replace_once(before, after):
    def change(part):
        assert part.count(before) == 1, (before, part.count(before))
        return part.replace(before, after)
    return change


def disable_condition(needle):
    def change(part):
        masked = code_mask(part)
        matches = []
        for match in re.finditer(r'\bif\s*\(', masked):
            left = masked.index('(', match.start())
            right = close_delimiter(masked, left, '(', ')')
            if needle in part[left + 1:right]:
                matches.append((left + 1, right))
        assert len(matches) == 1, (needle, len(matches))
        start, end = matches[0]
        return part[:start] + 'false && (' + part[start:end] + ')' + part[end:]
    return change


def copy_tests(source, stage):
    roots = [p for p in (source / 'test/unit').glob('NativeOpening*.t.sol')
             if p.name != 'NativeOpeningTooling.t.sol']
    roots.append(source / 'test/invariant/NativeOpeningInvariants.t.sol')
    pending = list(roots)
    seen = set()
    while pending:
        path = pending.pop().resolve()
        assert path.is_relative_to(source) and 'audit-poc' not in path.parts, path
        if path in seen:
            continue
        seen.add(path)
        text = path.read_text()
        relative = path.relative_to(source)
        if relative.parts[0] != 'src':
            target = stage / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
        for imported in re.findall(r'import\s+(?:[^;]*?from\s+)?["\']([^"\']+)["\']\s*;', text):
            if imported.startswith('.'):
                pending.append(path.parent / imported)
    return roots


def main():
    source = Path(sys.argv[1]).resolve()
    resume = len(sys.argv) > 2
    stage = Path(sys.argv[2]).resolve() if resume else Path(tempfile.mkdtemp(prefix='frv-native-opening-controls-'))
    print('Control checkout:', stage, flush=True)
    if not resume:
        shutil.copytree(source / 'src', stage / 'src')
        roots = copy_tests(source, stage)
        shutil.copy2(source / 'foundry.toml', stage / 'foundry.toml')
        (stage / 'lib').symlink_to((source / 'lib').resolve(), target_is_directory=True)
    else:
        roots = [p for p in (source / 'test/unit').glob('NativeOpening*.t.sol')
             if p.name != 'NativeOpeningTooling.t.sol']
        roots.append(source / 'test/invariant/NativeOpeningInvariants.t.sol')
        for path in (stage / 'test').rglob('*.sol'):
            assert path.read_bytes() == (source / path.relative_to(stage)).read_bytes(), path
        for path in (stage / 'src').rglob('*.sol'):
            assert re.sub(r'\s+', '', code_mask(path.read_text())) == re.sub(
                r'\s+', '', code_mask((source / path.relative_to(stage)).read_text())), path
    env = dict(os.environ, FOUNDRY_OUT=str(stage / 'out'), FOUNDRY_CACHE_PATH=str(stage / 'cache'),
               FOUNDRY_INVARIANT_RUNS='32', FOUNDRY_INVARIANT_DEPTH='64')
    tests = {p.relative_to(stage).as_posix(): sha(p.read_bytes()) for p in (stage / 'test').rglob('*.sol')}
    originals = {p.relative_to(stage).as_posix(): p.read_text() for p in (stage / 'src').rglob('*.sol')}
    declared = set()
    for path in roots + [source / 'test/unit/NativeAccrualSequences.t.sol']:
        declared.update(re.findall(r'function\s+((?:test\w+|invariant_\w+))\(', path.read_text()))

    migration = 'src/libraries/ReserveMigrationLib.sol'
    accrual = 'src/libraries/ReserveAccrualLib.sol'
    credit = 'src/libraries/ReserveAccrualCreditLib.sol'
    risk = 'src/libraries/DefaultAccrualLib.sol'
    cases = []

    def add(label, file, function, change, test, invariant=False):
        cases.append((label, file, function, change, test, invariant))

    add('opening-event-face-inflated', migration, '_begin',
        replace_once('m.expected, total);', 'm.expected, total + 1);'),
        'test_eventsDescribeTheOpeningSessionAndItsAccounting')
    add('admin-admission-omitted', 'src/ReserveManager.sol', 'prepareContinuousAccrualMigration',
        replace_once('onlyRole(DEFAULT_ADMIN_ROLE)', ''), 'test_adminOnlyAndActionEncodingCannotBypassPreparation')
    add('step-dispatch-changed', migration, 'prepare', replace_once('action == 0', 'action == 3'),
        'test_adminOnlyAndActionEncodingCannotBypassPreparation')
    add('preparation-lock-omitted', migration, 'prepare', disable_condition('s.busy'),
        'test_migrationAndActivationRefuseBothAccountingLocks')
    add('roster-count-limit-increased', migration, '_begin',
        replace_once('ids.length > AccrualBook.MAX_FACILITIES', 'ids.length > AccrualBook.MAX_FACILITIES + 1'),
        'test_oneHundredAndOneLiveRowsAreRefusedBeforeTheBookIsFrozen')
    add('roster-order-check-omitted', migration, '_begin', disable_condition('id == 0'),
        'test_rosterRequiresAllPositiveFaceExactlyOnceInOrder')
    add('complete-face-roster-check-omitted', migration, '_begin', disable_condition('total != native.totalDeployedPrincipal'),
        'test_rosterRequiresAllPositiveFaceExactlyOnceInOrder')
    add('oracle-readiness-omitted', migration, '_oracle', disable_condition('target.code.length'),
        'test_preparationRequiresReadyOracleAndEveryConsumerBinding')
    add('native-record-binding-omitted', migration, '_import', disable_condition('row.commitment !='),
        'test_nativeRecordChangesRefuseImportBeforeConsumption')
    add('opening-cutoff-binding-omitted', migration, '_consume',
        replace_once(' || asOf != cutoff', ' || (asOf != cutoff && false)'), 'test_openingFactBindsPayloadAndExactCutoff')
    add('opening-payload-binding-omitted', migration, '_consume',
        replace_once(' || payload != expected', ' || (payload != expected && false)'),
        'test_openingFactBindsPayloadAndExactCutoff|test_importCannotChangeTheQuorumSignedPikDate')
    add('replacement-approval-reference-discarded', migration, '_consume',
        replace_once('bytes32 expected =', 'opening.approvalRef = bytes32(0);\n        bytes32 expected ='),
        'test_revokedOpeningCanBeReauthorizedWithIdenticalBalances|test_openingFactBindsPayloadAndExactCutoff')
    add('recorded-fact-expiry-invented', migration, '_consume',
        replace_once('if (!satisfied', 'if (block.timestamp > uint256(cutoff) + 1 hours || !satisfied'),
        'test_recordedOpeningRemainsUsableAfterTheSignatureSubmissionDeadline')
    add('missing-opening-proof-accepted', migration, '_consume', disable_condition('!satisfied'),
        'test_batchFailureRollsBackEveryRowAndAttestationThenCanResume')
    add('session-nonce-not-advanced', migration, '_begin', replace_once('++m.nonce;', 'm.nonce += 0;'),
        'test_cancelRestoresAdmissionAndInvalidatesPreviousSessionSignature|test_nonceCannotWrapOrReuseAnOldSession')
    add('imported-session-cancellation-accepted', migration, '_cancel', disable_condition('m.imported != 0'),
        'test_cancelRestoresAdmissionAndInvalidatesPreviousSessionSignature')
    add('partial-nav-exposed', accrual, 'snapshot', disable_condition('s.migration.active'),
        'test_partialBookRefusesNavAndLifecycleUntilEveryRowIsImported')
    add('partial-admission-opened', accrual, 'requireIdle',
        replace_once(' || s.migration.active', ''), 'test_partialBookRefusesNavAndLifecycleUntilEveryRowIsImported')
    add('completion-totals-not-checked', accrual, 'enable', disable_condition('s.migration.expected == 0'),
        'test_activationProvesEveryStoredCompletionTotal|test_partialBookRefusesNavAndLifecycleUntilEveryRowIsImported')
    add('frozen-fee-not-checked', accrual, 'enable', disable_condition('s.migration.feeBps'),
        'test_feeConfigurationIsValidAtBeginAndUnchangedAtActivation')
    add('batch-limit-increased', migration, '_import',
        replace_once('openings.length > MAX_BATCH', 'openings.length > MAX_BATCH + 1'),
        'test_oneHundredLoansMigrateInBoundedBatchesWithoutPartialNav')
    add('row-order-check-omitted', migration, '_import',
        replace_once('id != m.facilityIds[m.imported] || ', ''),
        'test_emptyOversizedRepeatedAndOutOfOrderBatchesAreRefused')
    add('known-identity-check-omitted', migration, '_import',
        replace_once(' || s.identities[id].known', ''), 'test_knownIdentityCannotBeImportedAgain')
    add('cash-principal-guard-omitted', migration, '_loan', disable_condition('!f.pik &&'),
        'test_cashOpeningCannotEraseBackingOrInventPrincipalOrCapitalization')
    add('aggregate-exposure-budget-omitted', migration, '_importRow', disable_condition('effective >'),
        'test_aggregateExposureReservationCannotExceedTheArithmeticDomain')
    add('opening-sum-budget-omitted', migration, '_loan', disable_condition('opening.principal > AccrualLoans.MAX_BASIS'),
        'test_openingSumAndFutureCashCapacityCannotOverflow')
    add('native-grid-check-omitted', migration, '_loan', disable_condition('opening.principal %'),
        'test_everyOpeningAmountUsesTheNativeAssetGrid')
    add('unsupported-record-check-omitted', migration, '_row', disable_condition('row.recorded == 0'),
        'test_onlyLiveSupportedNativeRecordsCanEnterTheFrozenRoster')
    add('aggregate-work-budget-omitted', migration, '_begin', disable_condition('work >'),
        'test_completeRosterReservesTheAggregatePikMaintenanceBudgetBeforeImport')
    add('pik-note-ceiling-inflated', migration, '_loan', replace_once('ceiling = f.principal * 3;', 'ceiling = f.principal * 4;'),
        'test_pikOpeningCannotExceedOriginalNoteCeilingOrArithmeticCapacity')
    add('actual365-day-count-changed', migration, '_year', replace_once('return uint32(365 days);', 'return uint32(360 days);'),
        'test_actual365CashUsesTheSignedDayCountThroughMaturity')
    add('opening-native-face-inflated', migration, '_importRow', replace_once('native.deployed[id] += income;', 'native.deployed[id] += income + 1;'),
        'test_openingPostsNativeFaceAndBothFeesBeforeReceipts|testFuzz_batchPartitionDoesNotChangeTheCompletedBook')
    add('legacy-face-charged-again', migration, '_loan', replace_once('recordedFace: row.recorded,', 'recordedFace: 0,'),
        'test_zeroIncomeOpeningDoesNotChargeLegacyPrincipal|test_legacyCapitalizedIncomeIsNotChargedAgain')
    add('opening-protocol-fee-omitted', migration, '_import',
        replace_once('s.loans.initialize(m.cutoff, m.feeBps)', 's.loans.initialize(m.cutoff, 0)'),
        'test_openingPostsNativeFaceAndBothFeesBeforeReceipts|testFuzz_batchPartitionDoesNotChangeTheCompletedBook')
    add('default-opening-restarted', migration, '_loan', replace_once('bool stopped = _stopped(f);', 'bool stopped = false;'),
        'test_declaredOpeningPreservesRiskAndStopsIncomeBeforeCascade')
    add('contractual-maturity-extended', migration, '_loan',
        replace_once('ClaimBridge.Facility memory f = row.facility;',
                     'ClaimBridge.Facility memory f = row.facility; f.maturity += uint64(365 days);'),
        'test_maturedOpeningHasNoFurtherIncomeOrInventedCapitalization')
    add('opening-rate-changed', migration, '_loan', replace_once('rateBps: f.interestRateBps,', 'rateBps: f.interestRateBps + 1,'),
        'testFuzz_migratedDebtMatchesReferenceThroughMaturity|test_historicalCouponCursorContinuesWithoutResettingRounding|test_delayedActivationUsesKeeperAndRefusesStaleFinancialEntry|testFuzz_128NativeEventsPreserveIndependentAccounting|test_4096NativeEventsMeasureAccumulatedDrift|test_witnessCompletesEveryNativeAction')
    add('original-period-cursor-discarded', migration, '_loan', replace_once('periodStart: opening.periodStart,', 'periodStart: cutoff,'),
        'test_historicalCouponCursorContinuesWithoutResettingRounding|testFuzz_paymentBeforeMigrationPreservesUnpaidInterestAndItsOriginalBasis')
    add('frozen-pik-basis-discarded', migration, '_loan', replace_once('frozenPikBasis: opening.frozenPikBasis', 'frozenPikBasis: 0'),
        'testFuzz_paymentBeforeMigrationPreservesUnpaidInterestAndItsOriginalBasis')
    add('imported-servicing-date-not-synchronized', migration, '_importRow', disable_condition('row.facility.pik'),
        'test_importCannotChangeTheQuorumSignedPikDate|test_historicalCouponCursorContinuesWithoutResettingRounding')
    add('equal-servicing-date-written-again', credit, 'checkpoint', replace_once('item.nextDue > ', 'item.nextDue >= '),
        'testFuzz_paymentBeforeMigrationPreservesUnpaidInterestAndItsOriginalBasis')
    add('later-servicing-date-regressed', credit, 'checkpoint', replace_once('item.nextDue > ', 'item.nextDue != '),
        'testFuzz_paymentBeforeMigrationPreservesUnpaidInterestAndItsOriginalBasis')
    add('opening-risk-caller-check-omitted', risk, 'onOpening', disable_condition('reserve == address(0)'),
        'test_openingRiskCallbackRequiresTheBoundPreparingReserve')
    add('opening-risk-consistency-omitted', risk, 'onOpening', disable_condition('marked ||'),
        'test_defaultOpeningRefusesImpossibleRiskAndPreservesLegacyDrawnTotals')
    add('opening-declared-class-income-omitted', risk, 'onOpening',
        replace_once('$.declaredDefaultedPrincipal[f.classId] += income;', '$.declaredDefaultedPrincipal[f.classId] += 0;'),
        'test_declaredOpeningPreservesRiskAndStopsIncomeBeforeCascade')
    add('opening-marked-income-omitted', risk, 'onOpening',
        replace_once('$.pastDueContribution[id] += income;', '$.pastDueContribution[id] += 0;'),
        'test_pastDueOpeningUpdatesRiskAndCurePreservesEarning')
    add('opening-ledger-row-not-updated', risk, 'onOpening',
        replace_once('$.commitmentLedger.updatePrincipal(id, face);', ''),
        'test_declaredOpeningPreservesRiskAndStopsIncomeBeforeCascade')
    add('post-migration-amendment-rate-inflated', 'src/libraries/AccrualLoans.sol', 'amend',
        replace_once('loan.terms.rateBps = changed.rateBps;', 'loan.terms.rateBps = changed.rateBps + 1;'),
        'test_4096NativeEventsMeasureAccumulatedDrift')
    add('invariant-opening-rate-changed', migration, '_loan',
        replace_once('rateBps: f.interestRateBps,', 'rateBps: f.interestRateBps + 1,'),
        'invariant_migratedIncomeBackingAndOrderedLosses', True)

    def run(label, success, selected=None, invariant=False):
        command = ['forge', 'test', '--offline', '--match-contract', 'NativeOpening.*', '--fuzz-runs', '16', '-vv']
        if selected:
            command += ['--match-test', '^(' + selected + r')(\(|$)']
        if not invariant:
            command += ['--no-match-test', 'invariant_.*']
        result = subprocess.run(command, cwd=stage, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
        (stage / (label + '.log')).write_text(result.stdout)
        assert 'Compiler run successful!' in result.stdout or 'No files changed, compilation skipped' in result.stdout, label
        summary = re.search(r'Ran \d+ test suites? in .*: (\d+) tests passed, (\d+) failed, (\d+) skipped', result.stdout)
        assert summary, label + ': no completed compiled test run'
        counts = list(map(int, summary.groups()))
        failures = sorted(set(re.findall('^\\[FAIL[^\\n]*(?:\\n(?:\\t[^\\n]*| (?:invariant_|test)[^\\n]*))*', result.stdout, re.M)))
        assert (result.returncode == 0) == success, (label, counts)
        assert counts[2] == 0 and (success or counts[1] > 0), (label, counts)
        print(label, counts, flush=True)
        return {'exit_code': result.returncode, 'counts': counts, 'failed_tests': failures}

    previous = {row['name']: row for row in json.loads((stage / 'results.json').read_text())} if resume else {}
    results = []
    try:
        baseline = run('baseline', True)
        for label, relative, function, change, selected, invariant in cases:
            original = originals[relative]
            start, end, part = fragment(original, function)
            modified = change(part)
            assert modified != part, label
            changed = original[:start] + modified + original[end:]
            if label in previous:
                row = previous[label]
                assert row['source_before_sha256'] == sha(original.encode()), label
                assert row['source_after_sha256'] == sha(changed.encode()), label
                assert row['counts'][1] > 0 and row['counts'][2] == 0, label
                results.append(row)
                print(label, 'verified prior compiled control', flush=True)
                continue
            target = stage / relative
            target.write_text(changed)
            assert target.read_text() == changed and sha(changed.encode()) != sha(original.encode()), label
            try:
                row = run(label, False, selected, invariant)
                row.update(name=label, file=relative, function=function, matched_function=1, test_inputs_sha256=tests,
                           source_before_sha256=sha(original.encode()), source_after_sha256=sha(changed.encode()))
                results.append(row)
                (stage / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
            finally:
                target.write_text(original)
                assert target.read_text() == original
                for test, expected in tests.items():
                    assert sha((stage / test).read_bytes()) == expected, test
        # A resumed final case may have been reused after an earlier new case wrote
        # a shorter checkpoint. Persist the complete verified set before its summary.
        (stage / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        detected = {name for name in declared if any(name + '(' in line for row in results for line in row['failed_tests'])}
        assert detected == declared, ('new tests without a compiled failing control', sorted(declared - detected))
        restored = run('restored', True)
        restored_invariants = run('restored-invariants', True, 'invariant_migratedIncomeBackingAndOrderedLosses', True)
        (stage / 'summary.json').write_text(json.dumps({
            'cases': len(results), 'new_test_functions_detected': sorted(detected),
            'unchanged_test_sha256': tests, 'baseline': baseline,
            'restored': restored, 'restored_invariants': restored_invariants,
        }, indent=2) + '\n')
    finally:
        for relative, original in originals.items():
            (stage / relative).write_text(original)
            assert (stage / relative).read_text() == original


if __name__ == '__main__':
    main()
