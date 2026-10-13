#!/usr/bin/env python3
"""Reject obsolete/mismatched actual release-bundle metadata without launching apps."""
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('continuity_release', Path(__file__).with_name('verify_continuity_release.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ContinuityReleaseTests(unittest.TestCase):
    def setUp(self):
        self.policy = release.policy()
        self.temp = tempfile.TemporaryDirectory(prefix='taskfold-continuity-metadata-')
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / 'Taskfold.app'
        self.mac = self.policy['platform'] == 'macOS'
        self.contents = self.app / 'Contents' if self.mac else self.app
        self.widget = self.contents / 'PlugIns/TaskfoldWidgets.appex'
        self.widget_contents = self.widget / 'Contents' if self.mac else self.widget
        self.info = {'CFBundleIdentifier': self.policy['appBundleID'], 'CFBundleShortVersionString': self.policy['minimumVersion'], 'CFBundleVersion': str(self.policy['minimumBuild'])}
        self.write(self.contents, self.info)
        self.widget_info = dict(self.info, CFBundleIdentifier=self.policy['widgetBundleID'])
        self.write(self.widget_contents, self.widget_info)

    def write(self, contents, info):
        contents.mkdir(parents=True, exist_ok=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))

    def test_owned_project_and_generator_satisfy_floor(self):
        self.assertEqual(release.verify_project(self.policy)['version'], self.policy['minimumVersion'])

    def test_valid_actual_app_and_widget_metadata(self):
        self.assertEqual(release.verify_app(self.app, self.policy)['build'], str(self.policy['minimumBuild']))

    def test_old_packaged_build_rejected_even_when_version_matches(self):
        self.info['CFBundleVersion'] = str(self.policy['minimumBuild'] - 1)
        self.write(self.contents, self.info)
        with self.assertRaisesRegex(ValueError, 'predates'):
            release.verify_app(self.app, self.policy)

    def test_previous_version_with_large_build_is_still_obsolete(self):
        major, minor, _ = release.version_parts(self.policy['minimumVersion'])
        with self.assertRaisesRegex(ValueError, 'predates'):
            release.validate_version(f'{major}.{minor - 1}.99', '99999', self.policy)

    def test_newer_version_and_equivalent_version_spellings(self):
        major, minor, _ = release.version_parts(self.policy['minimumVersion'])
        release.validate_version(f'{major}.{minor + 1}.0', '1', self.policy)
        release.validate_version(f'{major}.{minor}', str(self.policy['minimumBuild']), self.policy)

    def test_malformed_versions_and_builds_are_not_candidates(self):
        for version, build in [('1.2-beta', '3'), ('1.2.0.1', '3'), ('1.2.0', '-1'), ('1.2.0', '0'), ('1.2.0', '3.1')]:
            with self.subTest(version=version, build=build), self.assertRaises(ValueError):
                release.validate_version(version, build, self.policy)

    def test_actual_wrong_app_and_widget_identity_rejected(self):
        self.info['CFBundleIdentifier'] += '.test'
        self.write(self.contents, self.info)
        with self.assertRaisesRegex(ValueError, 'identity'):
            release.verify_app(self.app, self.policy)
        self.info['CFBundleIdentifier'] = self.policy['appBundleID']; self.write(self.contents, self.info)
        self.widget_info['CFBundleIdentifier'] += '.test'; self.write(self.widget_contents, self.widget_info)
        with self.assertRaisesRegex(ValueError, 'Widget identity/version'):
            release.verify_app(self.app, self.policy)

    def test_actual_missing_and_mismatched_widget_rejected(self):
        self.widget_info['CFBundleVersion'] = str(self.policy['minimumBuild'] + 1)
        self.write(self.widget_contents, self.widget_info)
        with self.assertRaisesRegex(ValueError, 'Widget identity/version'):
            release.verify_app(self.app, self.policy)
        (self.widget_contents / 'Info.plist').unlink()
        with self.assertRaisesRegex(ValueError, 'requires its widget'):
            release.verify_app(self.app, self.policy)


if __name__ == '__main__':
    unittest.main()
