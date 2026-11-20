"""Shared test-isolation helpers: scripts must not reach the hosted Taskfold backend by accident.

Rule (docs/TESTING_ISOLATION.md): anything that prepares or runs a test, fixture, preview or capture
uses 127.0.0.1 (local `supabase start`) or an unroutable stub. The hosted project
(zqxflydiyfjeedqvyova) and any *.supabase.co host are reachable only when

  * the script is run with an explicit `--remote` flag (scripts that talk to a remote service), and
  * for test hosts, a human exports TASKFOLD_ALLOW_HOSTED_TESTS=1.

Refusal is immediate, non-interactive and loud (exit status 2); there is no confirmation prompt.
"""
import os
import plistlib
import sys
from pathlib import Path
from urllib.parse import urlsplit

HOSTED_PROJECT_HOST = 'zqxflydiyfjeedqvyova.supabase.co'
OPT_IN = 'TASKFOLD_ALLOW_HOSTED_TESTS'
BLOCKED_ORIGIN = 'https://hosted-backend-blocked-in-tests.invalid'
_SUFFIXES = ('.supabase.co', '.supabase.in', '.supabase.red', '.supabase.net')


def is_hosted(url: str) -> bool:
    text = str(url).lower()
    try:
        host = (urlsplit(text).hostname or '').rstrip('.')
    except ValueError:
        host = ''
    if not host:
        return 'supabase.' in text  # unparseable: fail closed
    return host == HOSTED_PROJECT_HOST or host == 'supabase.co' or host.endswith(_SUFFIXES)


def opted_in(environ=None) -> bool:
    return (environ if environ is not None else os.environ).get(OPT_IN) == '1'


def require_remote(url: str, argv=None, what: str = 'this script') -> None:
    """Exit(2) unless `url` is local/stub, or `--remote` was passed (the flag is consumed from argv)."""
    argv = sys.argv if argv is None else argv
    flagged = '--remote' in argv
    while '--remote' in argv:
        argv.remove('--remote')
    if not is_hosted(url) or flagged:
        return
    sys.exit(f'REFUSED: {what} would contact a hosted backend ({urlsplit(url).hostname}). '
             'Use 127.0.0.1 (supabase start), or pass --remote deliberately. See docs/TESTING_ISOLATION.md.')


def isolate_backend_plist(root: Path, environ=None) -> bool:
    """Replace every Backend.plist under `root` that names a hosted project with the unroutable stub.

    Returns True when a plist was rewritten. A human may keep the hosted plist with TASKFOLD_ALLOW_HOSTED_TESTS=1.
    """
    if opted_in(environ):
        return False
    changed = False
    for path in Path(root).rglob('Backend.plist'):
        value = plistlib.loads(path.read_bytes())
        if is_hosted(value.get('URL', '')):
            path.write_bytes(plistlib.dumps({'URL': BLOCKED_ORIGIN, 'Key': 'blocked-by-test-isolation'}))
            changed = True
    return changed


def install_network_guard(argv=None) -> None:
    """Wrap urllib.request.urlopen so a script cannot reach a hosted backend without `--remote`.

    Call before the script parses its arguments and before it imports `urlopen` by name.
    """
    import urllib.request
    argv = sys.argv if argv is None else argv
    remote = '--remote' in argv
    while '--remote' in argv:
        argv.remove('--remote')
    original = urllib.request.urlopen
    if getattr(original, '_taskfold_guarded', False):
        return

    def guarded(target, *args, **kwargs):
        url = getattr(target, 'full_url', target)
        if not remote:
            require_remote(str(url), argv=[], what=Path(sys.argv[0]).name)
        return original(target, *args, **kwargs)
    guarded._taskfold_guarded = True
    urllib.request.urlopen = guarded
