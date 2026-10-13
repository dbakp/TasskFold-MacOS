#!/usr/bin/env python3
"""Check this repository's P0 release floor; signing and runtime acceptance are separate."""
import argparse
import json
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parent.parent


def policy():
    value = json.loads((ROOT / 'Config/continuity-release.json').read_text())
    if value.get('schema') != 1 or value.get('platform') not in ('macOS', 'iOS'):
        raise ValueError('Unsupported continuity release policy')
    return value


def version_parts(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', value):
        raise ValueError('Invalid release version')
    parts = tuple(int(part) for part in value.split('.'))
    return parts + (0,) * (3 - len(parts))


def validate_version(version, build, release_policy):
    parts = version_parts(version)
    floor = version_parts(release_policy['minimumVersion'])
    if not isinstance(build, str) or not re.fullmatch(r'[0-9]+', build) or int(build) < 1:
        raise ValueError('Invalid release build')
    if parts < floor or (parts == floor and int(build) < release_policy['minimumBuild']):
        raise ValueError('App predates the supported P0 continuity release floor')


def verify_project(release_policy):
    text = (ROOT / 'Taskfold.xcodeproj/project.pbxproj').read_text()
    versions = re.findall(r'\bMARKETING_VERSION\s*=\s*([^;\s]+)\s*;', text)
    builds = re.findall(r'\bCURRENT_PROJECT_VERSION\s*=\s*([^;\s]+)\s*;', text)
    # App/widget Debug/Release must each declare the same candidate version.
    if len(versions) != 4 or len(builds) != 4 or len(set(versions)) != 1 or len(set(builds)) != 1:
        raise ValueError('App/widget project release versions differ or are missing')
    validate_version(versions[0], builds[0], release_policy)
    generator = ROOT / 'Scripts/generate_project.py'
    if generator.exists():
        generated = generator.read_text()
        if set(re.findall(r'\bMARKETING_VERSION\s*=\s*([^;\s]+)\s*;', generated)) != set(versions) or set(re.findall(r'\bCURRENT_PROJECT_VERSION\s*=\s*([^;\s]+)\s*;', generated)) != set(builds):
            raise ValueError('Project generator would reset the release version')
    return {'version': versions[0], 'build': builds[0]}


def verify_app(app, release_policy):
    mac = release_policy['platform'] == 'macOS'
    contents = app / 'Contents' if mac else app
    info = plistlib.loads((contents / 'Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != release_policy['appBundleID']:
        raise ValueError('Unexpected release app identity')
    version, build = info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')
    validate_version(version, build, release_policy)
    widget = contents / 'PlugIns/TaskfoldWidgets.appex'
    try:
        widget_info = plistlib.loads(((widget / 'Contents' if mac else widget) / 'Info.plist').read_bytes())
    except FileNotFoundError:
        raise ValueError('P0 release requires its widget extension') from None
    if widget_info.get('CFBundleIdentifier') != release_policy['widgetBundleID'] or widget_info.get('CFBundleShortVersionString') != version or widget_info.get('CFBundleVersion') != build:
        raise ValueError('Widget identity/version does not match the release app')
    return {'version': version, 'build': build}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--project', action='store_true', help='Validate this repository and its project generator')
    source.add_argument('--app', type=Path, help='Validate metadata inside the actual exported .app')
    args = parser.parse_args()
    try:
        release_policy = policy()
        result = verify_project(release_policy) if args.project else verify_app(args.app, release_policy)
    except (ValueError, KeyError, OSError, plistlib.InvalidFileException) as error:
        parser.exit(1, f'Continuity release check failed: {error}\n')
    print(json.dumps({'platform': release_policy['platform'], **result, 'releaseFloorSatisfied': True, 'signingAndRuntimeAcceptance': 'separate required checks'}))


if __name__ == '__main__':
    main()
