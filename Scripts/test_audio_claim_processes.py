#!/usr/bin/env python3
"""Two independent Core clients, a start barrier, real file locks and receipts."""
import argparse,hashlib,json,subprocess,tempfile,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--scratch',required=True,type=Path);p.add_argument('--output',required=True,type=Path);a=p.parse_args()
repo=Path(__file__).resolve().parent.parent; products=a.scratch.resolve()/'debug'
with tempfile.TemporaryDirectory(prefix='taskfold-audio-claims-process-') as d:
 d=Path(d);(d/'store').mkdir(mode=0o700);exe=d/'probe'
 source=repo/'Scripts/fixtures/AudioClaimsProcessProbe.swift'
 cmd=['swiftc','-parse-as-library','-swift-version','5','-enable-testing','-I',str(products),'-L',str(products),'-lTaskfoldCore',str(source),'-o',str(exe)]
 compile_result=subprocess.run(cmd,check=True,text=True,capture_output=True,timeout=60)
 base=[str(exe),'',str(d/'store'),str(repo/'TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a')]
 def run(mode):
  args=base.copy();args[1]=mode;return subprocess.run(args,text=True,capture_output=True,timeout=30)
 seed=run('seed');assert seed.returncode==0,seed.stderr
 workers=[]
 try:
  for i in [1,2]:
   args=base.copy();args[1]=f'worker-{i}';workers.append(subprocess.Popen(args,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE))
   deadline=time.monotonic()+10
   while not (d/f'ready-{i}').exists() and time.monotonic()<deadline:
    assert workers[-1].poll() is None,'Worker stopped before source barrier'
    time.sleep(.01)
   assert (d/f'ready-{i}').exists(),'Source barrier missing'
  (d/'go').write_bytes(b'go')
  results=[];busy=0
  for i,w in enumerate(workers,1):
   out,err=w.communicate(timeout=30);code=w.returncode
   for attempt in range(10):
    if code!=75:break
    busy+=1;time.sleep(.02);r=run(f'worker-{i}');out,err,code=r.stdout,r.stderr,r.returncode
   assert code==0,(out,err,code);results.append(json.loads(out))
 finally:
  for w in workers:
   if w.poll() is None:
    w.terminate()
    try:w.communicate(timeout=5)
    except subprocess.TimeoutExpired:w.kill();w.communicate()
 verify=run('verify');assert verify.returncode==0,verify.stderr
 final=json.loads(verify.stdout)
 assert len({r['pid'] for r in results})==2 and all(r['savedID']==final['savedID'] for r in results)
 receipt={'seed':json.loads(seed.stdout),'workers':results,'verification':final,'busyRetries':busy,'sourceSnapshotsEstablishedBeforeRelease':True,'compilerWarnings':[x for x in compile_result.stderr.splitlines() if 'warning:' in x],'sources':{str(source.relative_to(repo)):hashlib.sha256(source.read_bytes()).hexdigest()},'scope':'Mac executable processes linking the owning repo actual Core; synthetic data, no microphone or playback; native/mobile acceptance is separate.'}
a.output.write_text(json.dumps(receipt,indent=2)+'\n');print('Two independent processes converged on one saved recording; source barrier and process IDs verified.')
