#!/usr/bin/env python3
"""Prepare a separate Mac UI-test workspace without launching or installing apps.

Uses only this repository's sources. The copied debug app has a unique bundle ID,
sandbox, keychain service names and widget namespace; production URL/file type
registrations and the embedded widget extension are omitted. This cannot establish
Desktop widget, distribution-signing or real-provider acceptance.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    assert not output.exists(), 'Use a fresh task-owned workspace; never overwrite a checkout or installed app'
    assert str(output).startswith(('/private/tmp/', '/tmp/')), 'Prepare only in temporary task storage'
    output.mkdir()
    for name in ('Taskfold', 'TaskfoldWidgets', 'TaskfoldUITests', 'Scripts'):
        shutil.copytree(source / name, output / name, ignore=shutil.ignore_patterns('__pycache__'))
    (output / 'Taskfold.xcodeproj/xcshareddata/xcschemes').mkdir(parents=True)
    shutil.copy2(source / 'Taskfold.xcodeproj/xcshareddata/xcschemes/Taskfold.xcscheme', output / 'Taskfold.xcodeproj/xcshareddata/xcschemes/Taskfold.xcscheme')
    # Namespaces only: preserve app behavior, synchronization contracts and test actions.
    changes = {}
    replacements = {'com.taskfold.ios.session': 'com.taskfold.mac.p0uitests.session',
                    'com.taskfold.recovery.v1': 'com.taskfold.mac.p0uitests.recovery.v1',
                    'group.com.dbakp.taskfold': 'group.com.dbakp.taskfold.mac.p0uitests'}
    for path in (output / 'Taskfold').rglob('*.swift'):
        before = path.read_text(); after = before
        for old, new in replacements.items():
            after = after.replace(old, new)
        if after != before:
            path.write_text(after)
            changes[str(path.relative_to(output))] = {'originalSHA256': hashlib.sha256(before.encode()).hexdigest(), 'isolatedSHA256': hashlib.sha256(after.encode()).hexdigest()}
    assert 'Taskfold/Core/Backend.swift' in changes and 'Taskfold/Core/Backups.swift' in changes
    manifest = output / 'Taskfold/Info.plist'
    info = plistlib.loads(manifest.read_bytes())
    info['CFBundleDisplayName'] = 'Taskfold P0 Test'
    for key in ('CFBundleURLTypes', 'CFBundleDocumentTypes', 'UTExportedTypeDeclarations', 'UTImportedTypeDeclarations'):
        info.pop(key, None)
    manifest.write_bytes(plistlib.dumps(info))
    entitlements = {'com.apple.security.app-sandbox': True,
                    'com.apple.security.network.client': True,
                    'com.apple.security.files.user-selected.read-write': True,
                    'com.apple.security.personal-information.calendars': True}
    (output / 'Taskfold/Taskfold.entitlements').write_bytes(plistlib.dumps(entitlements))
    env = dict(os.environ, TASKFOLD_WIDGETS='0')
    subprocess.run(['python3', str(output / 'Scripts/generate_project.py')], env=env, check=True, capture_output=True, text=True)
    project = output / 'Taskfold.xcodeproj/project.pbxproj'
    text = project.read_text().replace('PRODUCT_BUNDLE_IDENTIFIER = com.dbakp.taskfold.mac;', 'PRODUCT_BUNDLE_IDENTIFIER = com.dbakp.taskfold.mac.p0uitests;').replace('PRODUCT_BUNDLE_IDENTIFIER = com.dbakp.taskfold.mac.uitests;', 'PRODUCT_BUNDLE_IDENTIFIER = com.dbakp.taskfold.mac.p0uitests.runner;')
    assert text.count('PRODUCT_BUNDLE_IDENTIFIER = com.dbakp.taskfold.mac.p0uitests;') == 2
    assert 'TaskfoldWidgets.appex' not in text
    project.write_text(text)
    # A missing App Group must never fall back to the installed app's projection.
    for path in (output / 'Taskfold').rglob('*.swift'):
        body = path.read_text()
        assert '"com.taskfold.ios.session"' not in body and '"com.taskfold.recovery.v1"' not in body and '"group.com.dbakp.taskfold"' not in body
    receipt = {'sourceRepository': str(source), 'workspace': str(output), 'bundleID': 'com.dbakp.taskfold.mac.p0uitests',
               'sandbox': True, 'productionURLAndFileRegistrationsRemoved': True, 'embeddedWidgetExtension': False,
               'namespaceOnlySourceChanges': changes, 'replacements': replacements,
               'launchArguments': ['--uitesting'],
               'limitations': ['Preparation only; no launch/install/runtime acceptance.', 'Unique keychain services; no production credential migration.', 'No Desktop-widget, signed-distribution or provider acceptance.']}
    (output / 'isolation-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
