#!/usr/bin/env python3
"""Build this owner's isolated combined-custody UI host; never installs normal Taskfold."""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import re
import subprocess
import sys

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--output', type=Path, required=True)
mode = p.add_mutually_exclusive_group()
mode.add_argument('--protected-recovery', action='store_true', default=True, help='Require an own development profile and private Keychain group (default)')
mode.add_argument('--unprovisioned-build-only', action='store_false', dest='protected_recovery', help='Compile/sign only; protected recovery cannot run without an own profile')
a = p.parse_args()
repo = Path(__file__).resolve().parent.parent
host = Path('/tmp/taskfold-owner-review-mac-host')
cache = Path('/tmp/taskfold-workflow-native-mac-build')
app = cache/'Build/Products/Debug/Taskfold.app'
output = a.output.resolve()
assert output.parent == Path('/private/tmp') and output.name.startswith('taskfold-') and output.suffix == '.json'
assert not output.exists() and not output.with_suffix('.log').exists()

def run(*args):
    return subprocess.check_output(args, text=True)

def digest(data):
    return hashlib.sha256(data).hexdigest()

def prepared(path):
    value = path.read_bytes().replace(b'backupcanceltests', b'workflowteststeameditbridge')
    if path.name == 'Backend.swift':
        for service in [b'com.taskfold.mac.session', b'com.taskfold.ios.session']:
            value = value.replace(service, b'com.taskfold.workflowteststeameditbridge.session')
    if path.name in ['Backend.swift', 'Backups.swift']:
        value = value.replace(b'com.taskfold.recovery.v1', b'com.taskfold.workflowteststeameditbridge.recovery')
    if path.name == 'Store.swift':
        assert value.count(b'group.com.dbakp.taskfold') == 1
        value = value.replace(b'group.com.dbakp.taskfold', b'group.com.dbakp.taskfold.workflowteststeameditbridge')
    return value

original_entitlement = None
report = {'buildOnly': True, 'nativeCombinedUIAccepted': False, 'normalAppUnchanged': True, 'networkBlockedSyntheticPeer': True}
try:
    run(sys.executable, str(repo/'Scripts/check_test_storage.py'), '--path', '/tmp')
    assert str(app/'Contents/MacOS/Taskfold') not in run('ps', '-axo', 'comm='), 'Close only the isolated app before replacing its product'
    sources = {str(path.relative_to(repo)): digest(path.read_bytes()) for path in sorted((repo/'Taskfold').rglob('*.swift'))}
    report['sourceSHA256'] = sources
    for relative in sources:
        target = host/relative; assert target.exists(), relative
        value = prepared(repo/relative)
        if target.read_bytes() != value: target.write_bytes(value)
    run(sys.executable, str(repo/'Scripts/prepare_project_adoption_native_test.py'), '--output', str(host), '--reuse-host', '--combined')
    packet = json.loads((host/'project-adoption-host-receipt.json').read_text()); assert packet['combined']
    identities = re.findall(r'\b([A-Fa-f0-9]{40})\s+"Apple Development:[^"]+"', run('security', 'find-identity', '-v', '-p', 'codesigning'))
    assert len(identities) == 1
    objects = json.loads(run('plutil', '-convert', 'json', '-o', '-', str(repo/'Taskfold.xcodeproj/project.pbxproj')))['objects']
    teams = {v.get('buildSettings', {}).get('DEVELOPMENT_TEAM') for v in objects.values() if v.get('isa') == 'XCBuildConfiguration'}
    teams = {v for v in teams if isinstance(v, str) and re.fullmatch(r'[A-Z0-9]{10}', v)}; assert len(teams) == 1
    entitlement = host/'Taskfold/Taskfold.entitlements'
    original_entitlement = entitlement.read_bytes()
    entitlements = plistlib.loads(original_entitlement)
    entitlements.pop('keychain-access-groups', None)
    if a.protected_recovery:
        entitlements['keychain-access-groups'] = ['$(AppIdentifierPrefix)com.dbakp.taskfold.mac.workflowteststeameditbridge']
    entitlement.write_bytes(plistlib.dumps(entitlements))
    report['protectedRecoveryRequested'] = a.protected_recovery
    command = ['xcodebuild', '-project', str(host/'Taskfold.xcodeproj'), '-scheme', 'Taskfold', '-configuration', 'Debug', '-destination', 'platform=macOS', '-derivedDataPath', str(cache), '-jobs', '1', '-disableAutomaticPackageResolution', 'ONLY_ACTIVE_ARCH=YES', 'ARCHS=arm64', 'COMPILER_INDEX_STORE_ENABLE=NO', 'OTHER_SWIFT_FLAGS=$(inherited) -driver-batch-count 2 -j 1', 'CODE_SIGN_STYLE=Manual', 'CODE_SIGN_IDENTITY='+identities[0], 'DEVELOPMENT_TEAM='+next(iter(teams)), 'build']
    if a.protected_recovery:
        command = [v for v in command if not v.startswith(('CODE_SIGN_STYLE=', 'CODE_SIGN_IDENTITY='))]
        command += ['-allowProvisioningUpdates', 'CODE_SIGN_STYLE=Automatic', 'CODE_SIGN_IDENTITY=Apple Development']
    with output.with_suffix('.log').open('w') as log:
        result = subprocess.run(command, cwd=repo, stdout=log, stderr=subprocess.STDOUT, timeout=900)
    report['xcodeExitCode'] = result.returncode
    if result.returncode != 0:
        diagnostic = output.with_suffix('.log').read_text()
        report['xcodeAccountUnavailable'] = 'No Accounts:' in diagnostic
        report['ownDevelopmentProfileMissing'] = "No profiles for 'com.dbakp.taskfold.mac.workflowteststeameditbridge'" in diagnostic
        raise RuntimeError('Isolated build failed; inspect its preserved build log. No normal app was replaced.')
    run('codesign', '--verify', '--deep', '--strict', str(app))
    info = json.loads(run('plutil', '-convert', 'json', '-o', '-', str(app/'Contents/Info.plist')))
    assert info['CFBundleIdentifier'] == 'com.dbakp.taskfold.mac.workflowteststeameditbridge'
    assert json.loads((app/'Contents/Resources/ProjectAdoptionNative.json').read_text()) == json.loads((host/'Taskfold/ProjectAdoptionNative.json').read_text())
    for relative, value in sources.items():
        assert digest((repo/relative).read_bytes()) == value
        assert (host/relative).read_bytes() == prepared(repo/relative)
    signed = plistlib.loads(subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(app)], stderr=subprocess.DEVNULL))
    report['signedKeychainGroups'] = signed.get('keychain-access-groups', [])
    if a.protected_recovery:
        assert report['signedKeychainGroups'] == [next(iter(teams))+'.com.dbakp.taskfold.mac.workflowteststeameditbridge']
        assert signed.get('com.apple.application-identifier') == next(iter(teams))+'.com.dbakp.taskfold.mac.workflowteststeameditbridge'
    report.update(sourceSHA256=sources, packet=packet, strictSignatureVerified=True, binarySHA256=digest((app/'Contents/MacOS/Taskfold.debug.dylib').read_bytes()))
except Exception as error:
    report['error'] = type(error).__name__+': '+str(error)
    raise
finally:
    if 'error' in report and original_entitlement is not None:
        entitlement.write_bytes(original_entitlement)
        report['preparedEntitlementsRestoredAfterFailure'] = True
    output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({k:report.get(k) for k in ['xcodeExitCode','error','strictSignatureVerified']}))
