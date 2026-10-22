#!/usr/bin/env python3
"""Run isolated macOS Store cleanup with synthetic endpoint replies only."""
import argparse,json,plistlib,subprocess,time,re
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--app',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
p.add_argument('--team',required=True,help='Existing development team matching this isolated app')
COMMON = {"reservedRecoveryOnly", "staleConfirmationRefused", "ownerCacheRemoved", "outsiderCacheExact", "ownedRecoveryRemoved", "outsiderRecoveryExact", "privatePlacesScoped", "recoveryCommandFinished", "staleCacheWriteRefused", "encryptedRecoveryRoundtrip", "backupKeysExistBeforeRemoval", "ownedBackupKeyRemoved", "outsiderBackupKeyKept"}
CASES = {
    "failed-reply-retry": {"interruptedResultRefused", "failedRequestKeepsCache", "failedRequestKeepsSession", "originalAuthorizationDurable", "pendingWorkspaceQuiescent", "pendingWidgetPrivate", "sameAuthorizationRetried", "confirmedRemovalSignsOut", "lateRemovedAccountCannotReopen"},
    "late-account-switch": {"heldOriginalRequest", "otherSessionKept", "otherMemoryKept", "otherWidgetKept", "otherShareKept"},
    "expired-authorization": {"expiredAuthorizationRenewed", "confirmedRemovalSignsOut", "lateRemovedAccountCannotReopen"},
}
a=p.parse_args();app=a.app.resolve();bundle=plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleIdentifier']
if bundle!='com.dbakp.taskfold.mac.workflowtestsremoval':raise SystemExit('Only the dedicated account-removal proof app is accepted')
subprocess.run(['codesign','--verify','--strict',str(app)],check=True,capture_output=True)
details=subprocess.run(['codesign','-dvv',str(app)],check=True,capture_output=True,text=True).stderr
if not re.fullmatch(r'[A-Z0-9]{10}',a.team) or ('TeamIdentifier='+a.team) not in details or 'Signature=adhoc' in details:raise SystemExit('Build this isolated app with the existing Apple Development identity')
output=a.output.resolve();output.mkdir(parents=True,exist_ok=False)
root=Path.home()/'Library/Containers'/bundle/'Data/Library/Application Support'/('RemovalNativeProof-'+bundle)
for scenario in ['failed-reply-retry','late-account-switch','expired-authorization']:
 result=root/'result.json'
 # Retain earlier proof externally; remove only this exact synthetic result.
 if result.exists():result.unlink()
 args=['open','-n','-a',str(app),'--args','--account-removal-proof','--account-removal-proof-reset']
 if scenario=='late-account-switch':args.append('--account-removal-switch')
 if scenario=='expired-authorization':args.append('--account-removal-expired')
 launch=subprocess.run(args,text=True,capture_output=True)
 (output/(scenario+'-launch.txt')).write_text(launch.stdout+launch.stderr)
 if launch.returncode:raise RuntimeError('Isolated Mac launch failed: '+launch.stderr)
 deadline=time.monotonic()+60
 while not result.exists() and time.monotonic()<deadline:time.sleep(.25)
 if not result.exists():raise RuntimeError('Native proof has not finished; inspect the existing app without relaunching')
 proof=json.loads(result.read_text());(output/(scenario+'.json')).write_text(json.dumps(proof,indent=2)+'\n')
 if proof.get('status')!='passed' or proof.get('scenario')!=scenario or not (COMMON|CASES[scenario]).issubset(proof.get('checks',{})) or not all(proof['checks'].values()):raise RuntimeError('Native Store proof failed: '+json.dumps(proof))
 print('PASS '+scenario+' ('+str(len(proof['checks']))+' actual native checks)',flush=True)
 # The Debug-only proof exits by itself after writing its result.
 time.sleep(.5)
