#!/usr/bin/env python3
"""Prepare a separately sandboxed Mac workflow app using only this repository.

Sign consistently with Apple Development from the first build. Use a new
namespace if changing signing identities; keep existing test containers intact.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--namespace', default='workflowtests2', help='Fresh namespace beginning with workflowtests')
parser.add_argument('--private-keychain', action='store_true', help='Opt in to the app-private Data Protection Keychain; requires a matching development profile')
parser.add_argument('--share-extension', action='store_true', help='Include an isolated native Share extension; requires --team')
parser.add_argument('--team', help='Ten-character development signing team for the isolated Share App Group')
args = parser.parse_args()
if not re.fullmatch(r'workflowtests[a-z0-9]*', args.namespace):
    parser.error('Use a workflowtests namespace; production identifiers are rejected.')
output = args.output.expanduser().resolve()
prepare = [sys.executable, str(Path(__file__).with_name('prepare_isolated_mac_ui.py')), '--variant', 'p0signeduitests', '--output', str(output)]
if args.share_extension:
    prepare.append('--share-extension')
if args.team:
    prepare.extend(['--team', args.team])
subprocess.run(prepare, check=True, stdout=subprocess.DEVNULL)
for path in output.rglob('*'):
    if path.suffix in ('.swift', '.pbxproj', '.entitlements', '.plist'):
        try:
            source = path.read_text()
        except UnicodeDecodeError:
            continue
        path.write_text(source.replace('p0signeduitests', args.namespace))
display_name = 'Taskfold Share Test' if args.share_extension else 'Taskfold Workflow Test'
infos = [output / 'Taskfold/Info.plist']
if args.share_extension:
    infos.append(output / 'TaskfoldShare/Info.plist')
for info in infos:
    value = plistlib.loads(info.read_bytes())
    value['CFBundleDisplayName'] = display_name
    value['CFBundleName'] = display_name
    info.write_bytes(plistlib.dumps(value))
if args.private_keychain:
    # Native calendar/removal recovery uses the Data Protection Keychain. Keep
    # this copied app's default access group private to its own signed identity.
    entitlement_path = output / 'Taskfold/Taskfold.entitlements'
    entitlements = plistlib.loads(entitlement_path.read_bytes())
    keychain_identity = '$(DEVELOPMENT_TEAM).com.dbakp.taskfold.mac.' + args.namespace
    entitlements['com.apple.application-identifier'] = keychain_identity
    entitlements['keychain-access-groups'] = [keychain_identity]
    entitlement_path.write_bytes(plistlib.dumps(entitlements))
receipt_path = output / 'isolation-receipt.json'
receipt = json.loads(receipt_path.read_text())
receipt['bundleID'] = 'com.dbakp.taskfold.mac.' + args.namespace
receipt['workflowNamespace'] = args.namespace
receipt['privateKeychainProfileRequired'] = args.private_keychain
receipt['displayName'] = display_name
if receipt['isolatedAppGroup']:
    receipt['isolatedAppGroup'] = receipt['isolatedAppGroup'].replace('p0signeduitests', args.namespace)
receipt['replacements'] = {old: new.replace('p0signeduitests', args.namespace) for old, new in receipt['replacements'].items()}
for relative, hashes in receipt['namespaceOnlySourceChanges'].items():
    hashes['isolatedSHA256'] = hashlib.sha256((output / relative).read_bytes()).hexdigest()
receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
print(output)
