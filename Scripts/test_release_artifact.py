#!/usr/bin/env python3
"""Exercise real DMG mounts/signatures without launching an app or touching user data."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('release_artifact', Path(__file__).with_name('release_artifact.py'))
artifact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifact)


class ReleaseArtifactTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='taskfold-release-test-')
        cls.root = Path(cls.temp.name)
        cls.stage = cls.root / 'stage'
        cls.app = cls.stage / 'Taskfold.app'
        binary = cls.app / 'Contents/MacOS/Taskfold'
        binary.parent.mkdir(parents=True)
        source = cls.root / 'fixture.c'
        source.write_text('int main(void) { return 0; }\n')
        subprocess.run(['xcrun', 'clang', str(source), '-o', str(binary)], check=True, capture_output=True)
        cls.info = {'CFBundleIdentifier': 'com.dbakp.taskfold.mac', 'CFBundleExecutable': 'Taskfold',
                    'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.2.3', 'CFBundleVersion': '7'}
        cls.write_info()
        cls.dmg = cls.make_dmg('valid')
        artifact.run('python3', str(Path(__file__).with_name('release_artifact.py')), 'record', str(cls.dmg), '--mode', 'distribution', '--inputs', 'fixture-source')
        cls.receipt = json.loads(cls.dmg.with_suffix('.dmg.json').read_text())

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    @classmethod
    def write_info(cls):
        (cls.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(cls.info))
        artifact.run('codesign', '--force', '--sign', '-', str(cls.app))

    @classmethod
    def make_dmg(cls, name):
        dmg = cls.root / (name + '.dmg')
        artifact.run('hdiutil', 'create', '-srcfolder', str(cls.stage), '-format', 'UDZO', str(dmg))
        return dmg

    def test_actual_packaged_payload_survives_external_app_change(self):
        # Publishing must inspect the immutable DMG, not a later build beside it.
        self.info['CFBundleShortVersionString'] = '9.9.9'
        self.write_info()
        result = artifact.run('python3', str(Path(__file__).with_name('release_artifact.py')), 'verify', str(self.dmg), '--mode', 'distribution', '--inputs', 'fixture-source')
        self.assertEqual(result.strip(), b'1.2.3')

    def test_build_failure_restores_project_and_scheme(self):
        root = Path(__file__).resolve().parent.parent
        paths = [root / 'Taskfold.xcodeproj/project.pbxproj', root / 'Taskfold.xcodeproj/xcshareddata/xcschemes/Taskfold.xcscheme']
        before = {path: path.read_bytes() for path in paths}
        commands = self.root / 'commands'
        commands.mkdir(exist_ok=True)
        fail = commands / 'xcodebuild'
        fail.write_text('#!/bin/sh\nexit 71\n')
        fail.chmod(0o700)
        env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ['PATH'], TASKFOLD_DMG_BUILD=str(self.root / 'unused-build'))
        result = subprocess.run(['zsh', str(root / 'Scripts/make_dmg.sh'), '--development'], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 71, result.stdout + result.stderr)
        for path, contents in before.items():
            self.assertEqual(path.read_bytes(), contents, str(path))

    def test_reject_changed_bytes_inputs_and_mode(self):
        changed = self.root / 'changed.dmg'
        shutil.copyfile(self.dmg, changed)
        with changed.open('ab') as stream: stream.write(b'changed')
        for path, inputs, mode in [(changed, 'fixture-source', 'distribution'),
                                   (self.dmg, 'other-source', 'distribution'),
                                   (self.dmg, 'fixture-source', 'developer-id'),
                                   (self.dmg, 'fixture-source', 'development')]:
            with self.subTest(mode=mode, path=path.name, inputs=inputs), self.assertRaises(ValueError):
                artifact.verify_receipt(self.receipt, path, inputs, mode)

    def test_reject_wrong_app_inside_valid_dmg(self):
        self.info['CFBundleIdentifier'] = 'invalid.fixture'
        try:
            self.write_info()
            wrong = self.make_dmg('wrong-identity')
            with self.assertRaisesRegex(ValueError, 'identity'):
                artifact.inspect_dmg(wrong, 'distribution')
        finally:
            self.info['CFBundleIdentifier'] = 'com.dbakp.taskfold.mac'
            self.write_info()


if __name__ == '__main__':
    unittest.main()
