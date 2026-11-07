import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest

from isolate_prepared_mac_app import BUNDLE, isolate, validate_location


class RegistrationIsolationTests(unittest.TestCase):
    def app(self, path, identity=BUNDLE):
        (path / 'Contents').mkdir(parents=True)
        (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identity}))
        return path

    def test_installed_copy_and_symlink_alias_refuse_before_any_command(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            installed = self.app(root / 'Applications/Taskfold.app')
            alias = root / 'Taskfold.app'; alias.symlink_to(installed, target_is_directory=True)
            def forbidden(*args, **kwargs): self.fail('Installed app registration must not be removed')
            for candidate in [installed, alias]:
                with self.assertRaises(ValueError): isolate(candidate, installed, runner=forbidden)
                with self.assertRaises(ValueError): validate_location(candidate, installed)

    def test_wrong_identity_refuses_before_any_command(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            candidate = self.app(root / 'cache/Taskfold.app')
            installed = self.app(root / 'Applications/Taskfold.app', 'another.app')
            def forbidden(*args, **kwargs): self.fail('An unexpected identity must not change routing')
            with self.assertRaises(ValueError): isolate(candidate, installed, runner=forbidden)

    def test_cache_registration_is_removed_and_missing_installed_registration_restored(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            candidate = self.app(root / 'cache/Taskfold.app')
            installed = self.app(root / 'Applications/Taskfold.app')
            contents = {p: (p / 'Contents/Info.plist').read_bytes() for p in [candidate, installed]}
            registered = {str(candidate.resolve())}
            def run(command, **kwargs):
                action = command[1]
                if action == '-dump':
                    return subprocess.CompletedProcess(command, 0, '\n'.join('path: ' + p + ' (0x1234)' for p in registered))
                if action == '-u': registered.discard(str(Path(command[-1]).resolve()))
                elif action == '-f': registered.add(str(Path(command[-1]).resolve()))
                else: self.fail('Unexpected operation')
                return subprocess.CompletedProcess(command, 0, '')
            result = isolate(candidate, installed, runner=run)
            self.assertFalse(result['candidateRegisteredAfter'])
            self.assertTrue(result['installedRegisteredAfter'])
            self.assertEqual(registered, {str(installed.resolve())})
            for p, data in contents.items(): self.assertEqual((p / 'Contents/Info.plist').read_bytes(), data)

    def test_missing_candidate_does_not_change_routing(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            def forbidden(*args, **kwargs): self.fail('Missing candidates need no registration change')
            result = isolate(root / 'cache/Taskfold.app', root / 'Applications/Taskfold.app', runner=forbidden)
            self.assertFalse(result['registrationChanged'])


if __name__ == '__main__':
    unittest.main()
