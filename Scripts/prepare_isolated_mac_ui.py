#!/usr/bin/env python3
"""Prepare a separate Mac UI-test workspace without launching or installing apps.

Uses only this repository's sources. The copied debug app has a unique bundle ID,
sandbox, keychain service names and widget namespace; production URL/file type
registrations and the embedded widget extension are omitted by default. The
p0widgethosts variant retains an isolated extension, App Group and URL scheme for
Desktop acceptance. Preparation alone establishes no runtime or release acceptance.
"""
import argparse
import re
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
    parser.add_argument('--variant', choices=('p0uitests', 'p0signeduitests', 'p0widgethosts'), default='p0uitests',
                        help='Use p0signeduitests for app acceptance or p0widgethosts for an isolated app plus Desktop widgets')
    parser.add_argument("--team", help="Signing team for a macOS team-prefixed isolated widget App Group")
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[1]
    bundle = 'com.dbakp.taskfold.mac.' + args.variant
    widgets = args.variant == 'p0widgethosts'
    if widgets and (not args.team or not re.fullmatch(r'[A-Z0-9]{10}', args.team)):
        parser.error('p0widgethosts requires --team with the actual ten-character signing team identifier')
    app_group = args.team + '.' + bundle if widgets else 'group.' + bundle
    scheme = 'taskfold-widget-host-test'
    service = 'com.taskfold.mac.' + args.variant
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
    replacements = {'com.taskfold.ios.session': service + '.session',
                    'com.taskfold.recovery.v1': service + '.recovery.v1',
                    'group.com.dbakp.taskfold': app_group}
    if widgets:
        replacements.update({'taskfold://': scheme + '://', '"taskfold"': '"' + scheme + '"'})
    paths = list((output / 'Taskfold').rglob('*.swift'))
    if widgets:
        paths += list((output / 'TaskfoldWidgets').rglob('*.swift'))
    for path in paths:
        before = path.read_text(); after = before
        for old, new in replacements.items():
            after = after.replace(old, new)
        if after != before:
            path.write_text(after)
            changes[str(path.relative_to(output))] = {'originalSHA256': hashlib.sha256(before.encode()).hexdigest(), 'isolatedSHA256': hashlib.sha256(after.encode()).hexdigest()}
    assert 'Taskfold/Core/Backend.swift' in changes and 'Taskfold/Core/Backups.swift' in changes
    manifest = output / 'Taskfold/Info.plist'
    info = plistlib.loads(manifest.read_bytes())
    info['CFBundleDisplayName'] = ('Taskfold Widget Host Test' if widgets else
                                 'Taskfold P0 Signed Test' if args.variant == 'p0signeduitests' else 'Taskfold P0 Test')
    for key in ('CFBundleURLTypes', 'CFBundleDocumentTypes', 'UTExportedTypeDeclarations', 'UTImportedTypeDeclarations'):
        info.pop(key, None)
    if widgets:
        info['CFBundleURLTypes'] = [{'CFBundleURLName': bundle, 'CFBundleURLSchemes': [scheme]}]
    manifest.write_bytes(plistlib.dumps(info))
    entitlements = {'com.apple.security.app-sandbox': True,
                    'com.apple.security.network.client': True,
                    'com.apple.security.files.user-selected.read-write': True,
                    'com.apple.security.personal-information.calendars': True}
    if widgets:
        entitlements['com.apple.security.application-groups'] = [app_group]
        widget_entitlements = {'com.apple.security.app-sandbox': True,
                               'com.apple.security.application-groups': [app_group]}
        (output / 'TaskfoldWidgets/TaskfoldWidgets.entitlements').write_bytes(plistlib.dumps(widget_entitlements))
    (output / 'Taskfold/Taskfold.entitlements').write_bytes(plistlib.dumps(entitlements))
    env = dict(os.environ, TASKFOLD_WIDGETS='1' if widgets else '0')
    subprocess.run(['python3', str(output / 'Scripts/generate_project.py')], env=env, check=True, capture_output=True, text=True)
    project = output / 'Taskfold.xcodeproj/project.pbxproj'
    text = project.read_text().replace('PRODUCT_BUNDLE_IDENTIFIER = com.dbakp.taskfold.mac;', 'PRODUCT_BUNDLE_IDENTIFIER = ' + bundle + ';').replace('PRODUCT_BUNDLE_IDENTIFIER = com.dbakp.taskfold.mac.uitests;', 'PRODUCT_BUNDLE_IDENTIFIER = ' + bundle + '.runner;')
    assert text.count('PRODUCT_BUNDLE_IDENTIFIER = ' + bundle + ';') == 2
    if widgets:
        text = text.replace('PRODUCT_BUNDLE_IDENTIFIER = com.dbakp.taskfold.mac.widgets;',
                            'PRODUCT_BUNDLE_IDENTIFIER = ' + bundle + '.widgets;')
        assert text.count('PRODUCT_BUNDLE_IDENTIFIER = ' + bundle + '.widgets;') == 2
        assert 'TaskfoldWidgets.appex' in text
    else:
        assert 'TaskfoldWidgets.appex' not in text
    project.write_text(text)
    # A missing App Group must never fall back to the installed app's projection.
    for path in paths:
        body = path.read_text()
        assert '"com.taskfold.ios.session"' not in body and '"com.taskfold.recovery.v1"' not in body and '"group.com.dbakp.taskfold"' not in body
        if widgets:
            assert 'taskfold://' not in body and '"taskfold"' not in body
    receipt = {'sourceRepository': str(source), 'workspace': str(output), 'bundleID': bundle,
               'sandbox': True, 'productionURLAndFileRegistrationsRemoved': True, 'embeddedWidgetExtension': widgets,
               'isolatedURLScheme': scheme if widgets else None,
               'isolatedAppGroup': app_group if widgets else None, 'signingTeam': args.team if widgets else None,
               'namespaceOnlySourceChanges': changes, 'replacements': replacements,
               'launchArguments': ['--uitesting'],
               'limitations': ['Preparation only; no launch/install/runtime acceptance.', 'Unique keychain services; no production credential migration.',
                               'Production Push Notifications and keychain-group entitlements are absent only from the copied test app.',
                               'No signed-distribution, APNs or provider acceptance.',
                               'Cold OS launches omit --uitesting and use the isolated local workspace; fixture continuity must be verified separately.']}
    (output / 'isolation-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
