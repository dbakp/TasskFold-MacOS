#!/usr/bin/env python3
"""Remove a prepared Taskfold copy from app routing; never launches an app."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess

TOOL = '/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister'
BUNDLE = 'com.dbakp.taskfold.mac'


def validate_location(candidate, installed=Path('/Applications/Taskfold.app')):
    candidate, installed = Path(candidate), Path(installed)
    if candidate.is_symlink() or candidate.resolve() == installed.resolve():
        raise ValueError('The installed app or an app symlink cannot be isolated')


def isolate(candidate, installed=Path('/Applications/Taskfold.app'), runner=None):
    runner = runner or subprocess.run
    candidate, installed = Path(candidate), Path(installed)
    validate_location(candidate, installed)
    if not candidate.exists():
        return {'candidateExists': False, 'registrationChanged': False}
    for app in [candidate] + ([installed] if installed.exists() else []):
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if app.name != 'Taskfold.app' or info.get('CFBundleIdentifier') != BUNDLE:
            raise ValueError('Only the expected normal Taskfold identity may be isolated/restored')

    def paths():
        result = runner([TOOL, '-dump'], capture_output=True, text=True, check=True)
        # macOS appends an internal string-table ID to each displayed path.
        return {re.sub(r' \(0x[0-9a-fA-F]+\)$', '', m.group(1))
                for line in result.stdout.splitlines()
                if (m := re.match(r'\s*path:\s*(.*?)\s*$', line))}

    candidate_path, installed_path = str(candidate.resolve()), str(installed.resolve())
    before = paths()
    if candidate_path in before:
        runner([TOOL, '-u', str(candidate)], capture_output=True, text=True, check=True)
    after = paths()
    if installed.exists() and installed_path not in after:
        runner([TOOL, '-f', '-R', '-trusted', str(installed)], capture_output=True, text=True, check=True)
        after = paths()
    if candidate_path in after or (installed.exists() and installed_path not in after):
        raise RuntimeError('Prepared app routing could not be isolated; do not present this candidate as ready')
    return {'candidateExists': True, 'candidate': str(candidate),
            'candidateRegisteredBefore': candidate_path in before, 'candidateRegisteredAfter': False,
            'installedExists': installed.exists(), 'installedRegisteredBefore': installed_path in before,
            'installedRegisteredAfter': installed_path in after, 'appLaunchRequested': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--installed', type=Path, default=Path('/Applications/Taskfold.app'))
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    result = isolate(args.candidate, args.installed)
    if args.report:
        with args.report.open('x') as output:
            output.write(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
