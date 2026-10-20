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
args = parser.parse_args()
if not re.fullmatch(r'workflowtests[a-z0-9]*', args.namespace):
    parser.error('Use a workflowtests namespace; production identifiers are rejected.')
output = args.output.expanduser().resolve()
subprocess.run([sys.executable, str(Path(__file__).with_name('prepare_isolated_mac_ui.py')), '--variant', 'p0signeduitests', '--output', str(output)], check=True, stdout=subprocess.DEVNULL)
for path in output.rglob('*'):
    if path.suffix in ('.swift', '.pbxproj', '.entitlements', '.plist'):
        try:
            source = path.read_text()
        except UnicodeDecodeError:
            continue
        path.write_text(source.replace('p0signeduitests', args.namespace))
info = output / 'Taskfold/Info.plist'
value = plistlib.loads(info.read_bytes())
value['CFBundleDisplayName'] = 'Taskfold Workflow Test'
value['CFBundleName'] = 'Taskfold Workflow Test'
info.write_bytes(plistlib.dumps(value))
receipt_path = output / 'isolation-receipt.json'
receipt = json.loads(receipt_path.read_text())
receipt['bundleID'] = 'com.dbakp.taskfold.mac.' + args.namespace
receipt['workflowNamespace'] = args.namespace
receipt['replacements'] = {old: new.replace('p0signeduitests', args.namespace) for old, new in receipt['replacements'].items()}
for relative, hashes in receipt['namespaceOnlySourceChanges'].items():
    hashes['isolatedSHA256'] = hashlib.sha256((output / relative).read_bytes()).hexdigest()
receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
print(output)
