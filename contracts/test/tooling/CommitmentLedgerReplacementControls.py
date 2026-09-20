#!/usr/bin/env python3
"""Require compiled defects in governed ledger replacement to be detected by its tests."""
import hashlib,json,os,re,shutil,subprocess,sys,tempfile
from pathlib import Path


def main():
    source=Path(sys.argv[1]).resolve()
    stage=Path(tempfile.mkdtemp(prefix='frv-ledger-replacement-controls-'))
    print('Control checkout:',stage,flush=True)
    shutil.copytree(source/'src',stage/'src')
    (stage/'lib').symlink_to((source/'lib').resolve(),target_is_directory=True)
    copied=set()
    def dependency(relative):
        if relative in copied:return
        assert relative.parts[0] in ('test','script') and 'audit-poc' not in relative.parts,relative
        copied.add(relative)
        content=(source/relative).read_text()
        target=stage/relative
        target.parent.mkdir(parents=True,exist_ok=True)
        target.write_text(content)
        for name in re.findall(r'import\s+(?:[^;]*?\s+from\s+)?["\x27]([^"\x27]+)["\x27]\s*;',content):
            if name.startswith('.'):
                child=((source/relative).parent/name).resolve().relative_to(source)
                if child.parts[0]!='src':dependency(child)
    dependency(Path('test/unit/CommitmentLedgerReplacement.t.sol'))
    (stage/'foundry.toml').write_text('''[profile.default]
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
    env=dict(os.environ,FOUNDRY_OUT=str(stage/'out'),FOUNDRY_CACHE_PATH=str(stage/'cache'))
    command=['forge','test','--offline','--match-contract',
             'CommitmentLedgerReplacementTest|Native(Cash|Pik)LedgerReplacementTest','--fuzz-runs','256','-vv']
    def run(label,success):
        proc=subprocess.run(command,cwd=stage,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,check=False)
        (stage/(label+'.log')).write_text(proc.stdout)
        assert 'Compiler run successful!' in proc.stdout or 'No files changed, compilation skipped' in proc.stdout,label+': compilation failed'
        assert re.search(r'Ran \d+ test',proc.stdout),label+': no tests ran'
        assert (proc.returncode==0)==success,label+': unexpected result'
        failures=sorted(set(re.findall(r'^\[FAIL[^\n]*',proc.stdout,flags=re.M)))
        assert success or failures,label+': no failing test'
        print(label,'pass' if success else str(len(failures))+' failing tests',flush=True)
        return {'exit_code':proc.returncode,'failed_tests':failures}
    manager='src/DefaultManager.sol'
    library='src/libraries/DefaultAccrualLib.sol'
    cases=[
        ('consumed-coverage-refusal-omitted',library,
         'if (consumed != 0) revert IDefaultManager.DefaultManager_CommitmentLedgerMigrationUnsafe(consumed);',
         'if (consumed == type(uint256).max) revert IDefaultManager.DefaultManager_CommitmentLedgerMigrationUnsafe(consumed);'),
        ('declared-principal-refusal-omitted',library,
         'if (declared != 0) revert IDefaultManager.DefaultManager_CommitmentLedgerMigrationUnsafe(declared);',
         'if (declared == type(uint256).max) revert IDefaultManager.DefaultManager_CommitmentLedgerMigrationUnsafe(declared);'),
        ('last-class-omitted',library,
         'for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {\n            declared += $.declaredDefaultedPrincipal[classId];',
         'for (uint256 classId = 1; classId < Config.NUM_CLASSES; ++classId) {\n            declared += $.declaredDefaultedPrincipal[classId];'),
        ('admin-gate-omitted',manager,
         'function replaceCommitmentLedger() external onlyRole(DEFAULT_ADMIN_ROLE) accrualIdle {',
         'function replaceCommitmentLedger() external accrualIdle {'),
        ('idle-gate-omitted',manager,
         'function replaceCommitmentLedger() external onlyRole(DEFAULT_ADMIN_ROLE) accrualIdle {',
         'function replaceCommitmentLedger() external onlyRole(DEFAULT_ADMIN_ROLE) {'),
        ('ledger-pointer-not-updated',library,
         '$.commitmentLedger = ICommitmentLedger(ledger);',
         '$.commitmentLedger = ICommitmentLedger(previous);'),
        ('new-ledger-owned-by-factory',library,
         'address ledger = address(CommitmentLedgerFactory(factory).create(address(this)));',
         'address ledger = address(CommitmentLedgerFactory(factory).create(factory));'),
        ('replacement-event-addresses-reversed',library,
         'emit IDefaultManager.CommitmentLedgerReplaced(previous, ledger);',
         'emit IDefaultManager.CommitmentLedgerReplaced(ledger, previous);'),
        ('first-installation-guard-inverted',library,
         'if (!replaceExisting && previous != address(0)) {',
         'if (!replaceExisting && previous == address(0)) {'),
        ('factory-call-omitted',library,
         'address ledger = address(CommitmentLedgerFactory(factory).create(address(this)));',
         'address ledger = factory;'),
        ('wrong-implementation-child-used',manager,
         'DefaultAccrualLib.installEmptyLedger(_storage(), address(commitmentLedgerFactory), true);',
         'DefaultAccrualLib.installEmptyLedger(_storage(), address(impairmentMath), true);'),
    ]
    originals={p:(stage/p).read_text() for _,p,_,_ in cases}
    reference=stage/'test/helpers/CommitmentLedgerReference.sol'
    reference_hash=hashlib.sha256(reference.read_bytes()).hexdigest()
    results=[]
    try:
        run('baseline',True)
        for label,path,before,after in cases:
            original=originals[path]
            assert original.count(before)==1,(label,original.count(before))
            changed=original.replace(before,after)
            assert changed!=original
            target=stage/path
            target.write_text(changed)
            assert target.read_text()==changed
            try:
                result=run(label,False)
                result.update(name=label,path=path,matches=1,
                              source_before_sha256=hashlib.sha256(original.encode()).hexdigest(),
                              source_after_sha256=hashlib.sha256(changed.encode()).hexdigest())
                results.append(result)
                (stage/'results.json').write_text(json.dumps(results,indent=2)+'\n')
            finally:
                target.write_text(original)
                assert target.read_text()==original
                assert hashlib.sha256(reference.read_bytes()).hexdigest()==reference_hash
        functions=set(re.findall(r'function (test\w+)\(', (source/'test/unit/CommitmentLedgerReplacement.t.sol').read_text()))
        detected={name for name in functions if any(name in line for result in results for line in result['failed_tests'])}
        assert detected==functions,('tests never shown to fail',sorted(functions-detected))
        restored=run('restored',True)
        (stage/'summary.json').write_text(json.dumps({'cases':len(results),'test_functions_detected':sorted(detected),
            'reference_sha256':reference_hash,'restored':restored},indent=2)+'\n')
        print('Verified controls:',len(results),'test functions:',len(detected),flush=True)
    finally:
        for path,original in originals.items():
            (stage/path).write_text(original)
            assert (stage/path).read_bytes()==(source/path).read_bytes()
        assert hashlib.sha256(reference.read_bytes()).hexdigest()==reference_hash


if __name__=='__main__':main()
