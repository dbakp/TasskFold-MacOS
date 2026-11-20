#!/usr/bin/env python3
"""Static check: no test, fixture or script can name the hosted backend without its guard.

Fails when
  * a Swift test/UI test mentions the hosted project but does not require TASKFOLD_ALLOW_HOSTED_TESTS,
  * a script mentions the hosted project but does not use the --remote / test_isolation guard,
  * anything under Scripts/Database names a real *.supabase.co project (those fixtures are local-only),
  * the hosted Backend.plist is not the only place a hosted URL is bundled for app targets.
See docs/TESTING_ISOLATION.md.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOSTED = 'zqxflydiyfjeedqvyova'
REFUSALS = ('XCTAssertNotEqual', '!==', '!=', ' not in ', 'NotEqual', '!origin.contains', '!contains')
SWIFT_GUARD = 'TASKFOLD_ALLOW_HOSTED_TESTS'
SCRIPT_GUARDS = ('test_isolation', 'remote-guard', '--remote')
FAKE_PROJECT = re.compile(r'\b(?!a{20}\b)[a-z]{20}\.supabase\.co\b')
problems = []


def mentions(text):
    return [line for line in text.splitlines() if HOSTED in line and not any(token in line for token in REFUSALS)]


for folder in ('TaskfoldTests', 'TaskfoldUITests'):
    for path in sorted((ROOT / folder).rglob('*.swift')):
        text = path.read_text(errors='ignore')
        if mentions(text) and SWIFT_GUARD not in text:
            problems.append(f'{path.relative_to(ROOT)}: names the hosted project without requiring {SWIFT_GUARD}')

for path in sorted((ROOT / 'Scripts').rglob('*')):
    if not path.is_file() or 'node_modules' in path.parts or path.suffix not in ('.py', '.sh', '.mjs', '.ts', '.swift', '.js'):
        continue
    if path.name in ('check_test_isolation.py', 'test_isolation.py', 'test_test_isolation.py'):
        continue
    text = path.read_text(errors='ignore')
    rel = path.relative_to(ROOT)
    if rel.parts[:2] == ('Scripts', 'Database') and FAKE_PROJECT.search(text):
        problems.append(f'{rel}: Scripts/Database fixtures must be local-only but name a *.supabase.co project')
    if path.suffix != '.ts' and mentions(text) and not any(token in text for token in SCRIPT_GUARDS):
        problems.append(f'{rel}: names the hosted project without the --remote / test_isolation guard')

for plist in sorted(ROOT.rglob('Backend.plist')):
    if '.worktrees' in plist.parts or '.build' in plist.parts:
        continue
    if str(plist.relative_to(ROOT)) != 'Taskfold/Backend.plist':
        problems.append(f'{plist.relative_to(ROOT)}: unexpected extra Backend.plist')

if problems:
    print('Test-isolation check FAILED:'); print('\n'.join('  ' + p for p in problems)); sys.exit(1)
print('Test-isolation check passed.')
