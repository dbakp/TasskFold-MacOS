#!/usr/bin/env python3
"""Bind release approval to the DMG bytes and inspect its actual read-only payload."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
MODES = ('distribution', 'development', 'developer-id')


def run(*args):
    return subprocess.check_output(args, stderr=subprocess.STDOUT)


def inspect_app(app, mode, require_notarization=True):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'com.dbakp.taskfold.mac':
        raise ValueError('Unexpected packaged app identity')
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+)*', version) or not re.fullmatch(r'[0-9]+', build):
        raise ValueError('Invalid release version/build')
    run('codesign', '--verify', '--deep', '--strict', str(app))
    signature = run('codesign', '-dvv', str(app)).decode()
    widget = app / 'Contents/PlugIns/TaskfoldWidgets.appex'
    if mode == 'distribution':
        if 'Signature=adhoc' not in signature or (app / 'Contents/PlugIns').exists() or (app / 'Contents/embedded.provisionprofile').exists():
            raise ValueError('Legacy distribution must be ad hoc and widget/profile free')
    else:
        widget_info = plistlib.loads((widget / 'Contents/Info.plist').read_bytes())
        if widget_info.get('CFBundleIdentifier') != 'com.dbakp.taskfold.mac.widgets' or widget_info.get('CFBundleShortVersionString') != version or widget_info.get('CFBundleVersion') != build:
            raise ValueError('Widget identity/version does not match the app')
        run('python3', str(ROOT / 'Scripts/verify_widget_catalog.py'), str(app), '--require-team')
        prefix = 'Developer ID Application:' if mode == 'developer-id' else 'Apple Development:'
        teams = []
        for bundle in (app, widget):
            signed = run('codesign', '-dvv', str(bundle)).decode()
            if f'Authority={prefix}' not in signed:
                raise ValueError(f'{bundle.name}: wrong signing identity for {mode}')
            team = re.search(r'^TeamIdentifier=(.+)$', signed, re.M)
            if not team or team.group(1) == 'not set':
                raise ValueError('Missing signing team')
            teams.append(team.group(1))
            raw = subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(bundle)], stderr=subprocess.DEVNULL)
            entitlements = plistlib.loads(raw)
            if entitlements.get('com.apple.security.app-sandbox') is not True:
                raise ValueError(f'{bundle.name}: sandbox entitlement required')
            if 'group.com.dbakp.taskfold' not in entitlements.get('com.apple.security.application-groups', []):
                raise ValueError(f'{bundle.name}: missing shared widget App Group')
            if mode == 'developer-id' and ('runtime' not in signed or entitlements.get('com.apple.security.get-task-allow')):
                raise ValueError(f'{bundle.name}: production hardened runtime required')
        if teams[0] != teams[1]:
            raise ValueError('App/widget signing teams differ')
        if mode == 'developer-id' and require_notarization:
            run('xcrun', 'stapler', 'validate', str(app))
            run('spctl', '--assess', '--type', 'execute', str(app))
    return {'version': version, 'build': build, 'widgets': widget.exists()}


def inspect_dmg(dmg, mode):
    run('hdiutil', 'verify', str(dmg))
    if mode == 'developer-id':
        run('xcrun', 'stapler', 'validate', str(dmg))
    with tempfile.TemporaryDirectory(prefix='taskfold-release-mount-') as mount:
        run('hdiutil', 'attach', str(dmg), '-readonly', '-nobrowse', '-mountpoint', mount)
        try:
            return inspect_app(Path(mount) / 'Taskfold.app', mode)
        finally:
            run('hdiutil', 'detach', mount)


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def verify_receipt(receipt, dmg, inputs, mode):
    if receipt.get('schema') != 1 or receipt.get('mode') != mode:
        raise ValueError('Wrong artifact schema or release mode')
    if receipt.get('inputs') != inputs or receipt.get('sha256') != sha256(dmg):
        raise ValueError('Release inputs or DMG bytes changed; rebuild and verify')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('record', 'verify', 'check-app'))
    parser.add_argument('dmg', type=Path)
    parser.add_argument('--mode', choices=MODES, required=True)
    parser.add_argument('--inputs', required=True)
    args = parser.parse_args()
    if args.action == 'check-app':
        print(inspect_app(args.dmg.resolve(), args.mode, require_notarization=False)['version'])
        return
    receipt_path = args.dmg.with_suffix(args.dmg.suffix + '.json')
    if args.action == 'verify':
        receipt = json.loads(receipt_path.read_text())
        verify_receipt(receipt, args.dmg, args.inputs, args.mode)
    details = inspect_dmg(args.dmg.resolve(), args.mode)
    if args.action == 'record':
        receipt = dict(schema=1, mode=args.mode, inputs=args.inputs, sha256=sha256(args.dmg), **details)
        receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    elif any(receipt.get(key) != value for key, value in details.items()):
        raise ValueError('Packaged metadata does not match verified receipt')
    print(details['version'])


if __name__ == '__main__':
    main()
