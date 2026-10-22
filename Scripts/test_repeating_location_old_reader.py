#!/usr/bin/env python3
"""Compile a selected previous one-shot Core reader against a valid repeat fixture."""
import argparse, hashlib, io, json, re, subprocess, tarfile, tempfile
from pathlib import Path
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--revision', required=True)
parser.add_argument('--output', type=Path, required=True)
a = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
revision = subprocess.check_output(['git', 'rev-parse', '--verify', a.revision + '^{commit}'], cwd=repo, text=True).strip()
fixture = (repo/'Scripts/fixtures/OldRepeatingLocationReaderTests.swift').read_bytes()
payload = (repo/'TaskfoldTests/Fixtures/repeating-location.json').read_bytes()
a.output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='taskfold-repeat-reader-') as name:
    root = Path(name)
    archive = subprocess.check_output(['git', 'archive', revision, 'Package.swift', 'Taskfold/Core', 'TaskfoldWidgets', 'TaskfoldTests/Fixtures'], cwd=repo)
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        for item in source.getmembers():
            p = Path(item.name)
            if p.is_absolute() or '..' in p.parts or item.issym() or item.islnk(): raise RuntimeError('Unexpected archive path')
        source.extractall(root)
    old = (root/'Taskfold/Core/LocationReminders.swift').read_bytes()
    if b'every-visit' in old: raise RuntimeError('Select a previous reader without repeat support')
    (root/'TaskfoldTests/OldRepeatingLocationReaderTests.swift').write_bytes(fixture)
    (root/'TaskfoldTests/Fixtures/repeating-location.json').write_bytes(payload)
    run = subprocess.run(['swift', 'test', '--package-path', str(root), '--scratch-path', str(root/'build'), '--filter', 'OldRepeatingLocationReaderTests'], capture_output=True, text=True)
    log = run.stdout + run.stderr; a.output.with_suffix('.log').write_text(log)
    if run.returncode or not re.search(r'Executed 2 tests, with 0 failures', log): raise RuntimeError('Old-reader repeat check failed; inspect log')
    proof = dict(revision=revision, oldLocationSourceSHA256=hashlib.sha256(old).hexdigest(), fixtureSHA256=hashlib.sha256(fixture).hexdigest(), payloadSHA256=hashlib.sha256(payload).hexdigest(), actualPassed=2, checks=['opaque version7 row preserved through edits/record round-trip/recurring successor', 'no substitute planned-time alerts', 'private journal3 repeat ticket refused without overwrite'], scope='This selected previous prototype reader only; no general older-client rollout claim.')
    a.output.write_text(json.dumps(proof, indent=2)+'\n'); print(json.dumps(proof))
