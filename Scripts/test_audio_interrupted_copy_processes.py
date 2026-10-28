#!/usr/bin/env python3
"""Actual isolated processes exercise interrupted-copy journals; synthetic AAC only."""
from pathlib import Path
import argparse,subprocess,tempfile,json,hashlib
p=argparse.ArgumentParser();p.add_argument('--scratch',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
repo=Path(__file__).resolve().parent.parent; products=a.scratch.resolve()/'debug'
fixture=repo/'Scripts/fixtures/AudioInterruptedCopyProof.swift';media=repo/'TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a';runs=[]
with tempfile.TemporaryDirectory(prefix='taskfold-interrupted-copy-process-') as folder:
 root=Path(folder);executable=root/'copy-proof'
 compiled=subprocess.run(['swiftc','-parse-as-library','-swift-version','5','-enable-testing','-I',str(products),'-L',str(products),'-lTaskfoldCore',str(fixture),'-o',str(executable)],capture_output=True,text=True,check=True,timeout=60)
 for index,modes in enumerate([['prepare','finish','verify'],['prepare','lost-commit','finish','verify']]):
  store=root/str(index);store.mkdir(mode=0o700);steps=[]
  for mode in modes:
   result=subprocess.run([str(executable),mode,str(store),str(media)],capture_output=True,text=True,check=True,timeout=30);steps.append(json.loads(result.stdout))
  assert len({r['pid'] for r in steps})==len(steps)
  assert len({r['copyID'] for r in steps})==1 and len({r['operationID'] for r in steps})==1
  assert all(r['status']=='verified' for r in steps)
  assert len({r['originalSHA256'] for r in steps})==1
  assert steps[-1]['drafts']==2 and steps[-1]['pending']==0 and not steps[-1]['stagePresent'];runs.append(steps)
 sources=['Taskfold/Core/AudioCommentVault.swift','Scripts/fixtures/AudioInterruptedCopyProof.swift','Scripts/test_audio_interrupted_copy_processes.py']
 result={'status':'passed','separateProcesses':sum(map(len,runs)),'runs':runs,'compilerWarnings':compiled.stderr.splitlines(),'sources':{f:hashlib.sha256((repo/f).read_bytes()).hexdigest() for f in sources},'linkedCoreArchiveSHA256':hashlib.sha256((products/'libTaskfoldCore.a').read_bytes()).hexdigest(),'scope':'Real vault writes/journal recovery across process exit with synthetic audio and injected lost acknowledgement; no microphone, playback, network or real tasks.','ownedTemporaryDirectoryRemovedOnExit':True}
a.output.write_text(json.dumps(result,indent=2)+'\n');print('Seven independent processes retained original recording and finished one exact copy.')
