#!/usr/bin/env python3
"""Compile an actual selected previous private reader against explicit reset authority."""
import argparse,hashlib,io,json,re,subprocess,tarfile,tempfile
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--revision',required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
repo=Path(__file__).resolve().parent.parent
rev=subprocess.check_output(['git','rev-parse','--verify',a.revision+'^{commit}'],cwd=repo,text=True).strip()
payload=(repo/'TaskfoldTests/Fixtures/reset-location.json').read_bytes();fixture=(repo/'Scripts/fixtures/OldLocationResetReaderTests.swift').read_bytes()
a.output.parent.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='taskfold-reset-old-reader-') as name:
 root=Path(name); archive=subprocess.check_output(['git','archive',rev,'Package.swift','Taskfold/Core','TaskfoldWidgets','TaskfoldTests/Fixtures'],cwd=repo)
 with tarfile.open(fileobj=io.BytesIO(archive)) as data:
  for member in data.getmembers():
   path=Path(member.name)
   if path.is_absolute() or '..' in path.parts or member.issym() or member.islnk():raise RuntimeError('Unexpected archive path')
  data.extractall(root)
 source=(root/'Taskfold/Core/LocationPlaceStore.swift').read_bytes()
 if b'supersedesEarlierInstallations' in source:raise RuntimeError('Select a previous reader without reset-authority support')
 (root/'TaskfoldTests/OldLocationResetReaderTests.swift').write_bytes(fixture);(root/'TaskfoldTests/Fixtures/reset-location.json').write_bytes(payload)
 run=subprocess.run(['swift','test','--package-path',str(root),'--scratch-path',str(root/'build'),'--filter','OldLocationResetReaderTests'],capture_output=True,text=True)
 log=run.stdout+run.stderr;a.output.with_suffix('.log').write_text(log)
 if run.returncode or not re.search(r'Executed 1 test, with 0 failures',log):raise RuntimeError('Selected previous-reader check failed; inspect log')
 proof={'revision':rev,'oldPrivateSourceSHA256':hashlib.sha256(source).hexdigest(),'payloadSHA256':hashlib.sha256(payload).hexdigest(),'fixtureSHA256':hashlib.sha256(fixture).hexdigest(),'actualPassed':1,'checks':['New explicit reset archive refused','Ordinary consent edit refused without overwriting bytes'],'scope':'This selected previous committed prototype only; general older-client rollout remains deferred.'}
 a.output.write_text(json.dumps(proof,indent=2)+'\n');print(json.dumps(proof))
