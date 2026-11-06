#!/usr/bin/env python3
"""Exercise the real workflow preparer without signing, launching or registering apps."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WorkflowSharePreparationTests(unittest.TestCase):
    def prepare(self, output, *arguments):
        return subprocess.run([
            'python3', str(ROOT / 'Scripts/prepare_workflow_ui_test.py'),
            '--output', str(output), '--namespace', 'workflowtestsshareprep',
            *arguments,
        ], capture_output=True, text=True)

    def test_share_host_and_extension_use_one_private_group_and_accurate_receipt(self):
        protected = ['Taskfold/Info.plist', 'TaskfoldShare/Info.plist',
                     'Taskfold/Core/SharedCapture.swift', 'Taskfold/Taskfold.entitlements',
                     'TaskfoldShare/TaskfoldShare.entitlements', 'Taskfold.xcodeproj/project.pbxproj']
        before = {name: (ROOT / name).read_bytes() for name in protected}
        with tempfile.TemporaryDirectory(prefix='taskfold-workflow-share-', dir='/private/tmp') as folder:
            output = Path(folder) / 'host'
            result = self.prepare(output, '--share-extension', '--team', '3UZ4C73FM2')
            self.assertEqual(result.returncode, 0, result.stderr)
            receipt = json.loads((output / 'isolation-receipt.json').read_text())
            bundle = 'com.dbakp.taskfold.mac.workflowtestsshareprep'
            group = '3UZ4C73FM2.' + bundle
            self.assertEqual(receipt['bundleID'], bundle)
            self.assertEqual(receipt['isolatedAppGroup'], group)
            self.assertEqual(receipt['signingTeam'], '3UZ4C73FM2')
            self.assertTrue(receipt['embeddedShareExtension'])
            self.assertFalse(receipt['embeddedWidgetExtension'])
            self.assertEqual(receipt['replacements']['group.com.dbakp.taskfold'], group)
            for relative in ['Taskfold/Taskfold.entitlements', 'TaskfoldShare/TaskfoldShare.entitlements']:
                value = plistlib.loads((output / relative).read_bytes())
                self.assertEqual(value['com.apple.security.application-groups'], [group])
            for relative in ['Taskfold/Info.plist', 'TaskfoldShare/Info.plist']:
                info = plistlib.loads((output / relative).read_bytes())
                self.assertEqual(info['CFBundleDisplayName'], 'Taskfold Share Test')
                self.assertEqual(info['CFBundleName'], 'Taskfold Share Test')
            info = plistlib.loads((output / 'Taskfold/Info.plist').read_bytes())
            self.assertNotIn('CFBundleURLTypes', info)
            self.assertNotIn('CFBundleDocumentTypes', info)
            project = (output / 'Taskfold.xcodeproj/project.pbxproj').read_text()
            self.assertIn('TaskfoldShare.appex', project)
            self.assertIn(bundle + '.share', project)
            self.assertNotIn('p0signeduitests', project)
            for relative, hashes in receipt['namespaceOnlySourceChanges'].items():
                self.assertEqual(hashes['isolatedSHA256'], hashlib.sha256((output / relative).read_bytes()).hexdigest(), relative)
                self.assertEqual(hashes['originalSHA256'], hashlib.sha256((ROOT / relative).read_bytes()).hexdigest(), relative)
            source = (output / 'Taskfold/Core/SharedCapture.swift').read_text()
            self.assertIn(group, source)
            self.assertNotIn('"group.com.dbakp.taskfold"', source)
        for name, data in before.items():
            self.assertEqual((ROOT / name).read_bytes(), data, name)

    def test_default_workflow_host_keeps_extensions_and_groups_absent(self):
        with tempfile.TemporaryDirectory(prefix='taskfold-workflow-default-', dir='/private/tmp') as folder:
            output = Path(folder) / 'host'
            result = self.prepare(output)
            self.assertEqual(result.returncode, 0, result.stderr)
            receipt = json.loads((output / 'isolation-receipt.json').read_text())
            self.assertFalse(receipt['embeddedShareExtension'])
            self.assertIsNone(receipt['isolatedAppGroup'])
            project = (output / 'Taskfold.xcodeproj/project.pbxproj').read_text()
            self.assertNotIn('TaskfoldShare.appex', project)
            info = plistlib.loads((output / 'Taskfold/Info.plist').read_bytes())
            self.assertEqual(info['CFBundleDisplayName'], 'Taskfold Workflow Test')

    def test_share_without_valid_team_fails_before_creating_output(self):
        with tempfile.TemporaryDirectory(prefix='taskfold-workflow-reject-', dir='/private/tmp') as folder:
            for suffix, extra in [('missing', []), ('invalid', ['--team', 'bad'])]:
                output = Path(folder) / suffix
                result = self.prepare(output, '--share-extension', *extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('ten-character signing team', result.stderr)
                self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
