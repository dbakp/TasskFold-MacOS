#!/usr/bin/env python3
"""Actual repository Core journal in separate native processes; synthetic data only."""
import argparse, hashlib, json, subprocess, tempfile, uuid
from pathlib import Path
parser = argparse.ArgumentParser()
parser.add_argument('--scratch', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
products = args.scratch.resolve() / 'debug'
checks = {}
def check(name, actual, expected=True):
    assert actual == expected, name
    checks[name] = True
with tempfile.TemporaryDirectory(prefix='taskfold-publication-process-') as directory:
    folder = Path(directory); binary = folder / 'probe'
    source = repo / 'Scripts/fixtures/AudioCommentPublicationProbe.swift'
    result = subprocess.run(['swiftc','-parse-as-library','-swift-version','5','-enable-testing','-I',str(products),'-L',str(products),'-lTaskfoldCore',str(source),'-o',str(binary)], capture_output=True, text=True, timeout=60)
    if result.returncode: raise RuntimeError(result.stderr)
    compiler_warnings = [line for line in result.stderr.splitlines() if 'warning:' in line]
    config = {key: str(uuid.uuid4()) for key in ['account','source','revision','task','generation']}
    config.update(origin='https://publication.example.invalid',caption='  cafe\u0301\nمراجعة 🪴  ')
    input_file = folder / 'input.json'; input_file.write_text(json.dumps(config))
    def command(root, mode): return [str(binary),str(root),str(repo/'TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a'),str(input_file),mode]
    def run(root, mode, code=0):
        result = subprocess.run(command(root,mode),capture_output=True,text=True,timeout=10)
        check(mode+' expected exit '+str(code)+' '+root.name,result.returncode,code)
        return json.loads(result.stdout.splitlines()[-1]) if code == 0 else None
    root = folder/'rename'; root.mkdir(mode=0o700)
    run(root,'crash-after',77)
    seen = run(root,'show'); resumed = run(root,'prepare')
    check('restart after renamed write keeps operation',seen['operation_id'],resumed['operation_id'])
    check('restart preserves literal caption',resumed['caption'],config['caption'])
    run(root,'confirm-crash',77)
    published = run(root,'prepare')
    check('receipt survives process exit after rename',published['published'])
    check('confirmed restart keeps original operation',published['operation_id'],seen['operation_id'])
    check('confirmed journal releases duplicate audio',published['has_audio'],False)
    root = folder/'before';root.mkdir(mode=0o700);run(root,'crash-before',76)
    check('precommit stage is never a publication',run(root,'show'),{})
    check('next process can prepare after precommit death',run(root,'prepare')['has_audio'])
    root = folder/'concurrent';root.mkdir(mode=0o700)
    first = subprocess.Popen(command(root,'hold'),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try:
        check('first process holds actual file lock',first.stdout.readline().strip(),'LOCKED')
        run(root,'prepare',75)
        tail, error = first.communicate(timeout=10)
        check('owning writer completes',first.returncode,0)
        initial = json.loads(tail.splitlines()[-1]); reopened = run(root,'prepare')
        check('competing process reuses single frozen operation',initial['operation_id'],reopened['operation_id'])
        check('only one committed journal',len(list(root.rglob('*.bin'))),1)
    finally:
        if first.poll() is None:first.kill();first.communicate(timeout=5)
report={'checks':checks,'compilerWarnings':compiler_warnings,'sources':{name:hashlib.sha256((repo/name).read_bytes()).hexdigest() for name in ['Taskfold/Core/AudioCommentPublishing.swift','Scripts/fixtures/AudioCommentPublicationProbe.swift','Scripts/test_audio_publication_processes.py']},'scope':'Separate Mac native processes with real Core/POSIX journal, injected process exits and synthetic receipt/media. No hard-power-loss, real server, native UI, microphone or playback acceptance.'}
args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(report,indent=2)+'\n')
print(str(len(checks))+' real publication process checks passed')
