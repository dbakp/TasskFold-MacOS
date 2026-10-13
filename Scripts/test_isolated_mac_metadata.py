#!/usr/bin/env python3
"""Verify real prepared workspaces export isolated drag types without file takeover."""
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class IsolatedMacMetadataTests(unittest.TestCase):
    def test_all_variants_keep_exported_type_and_remove_production_associations(self):
        protected = [ROOT / 'Taskfold/Info.plist', ROOT / 'Taskfold/Workspace.swift']
        before = {p: p.read_bytes() for p in protected}
        variants = ('p0uitests', 'p0signeduitests', 'p0widgethosts', 'p0notificationtests', 'p0calendartests', 'backupcanceltests')
        with tempfile.TemporaryDirectory(prefix='taskfold-type-metadata-', dir='/private/tmp') as folder:
            for variant in variants:
                with self.subTest(variant=variant):
                    output = Path(folder) / variant
                    result = subprocess.run(['python3', str(ROOT / 'Scripts/prepare_isolated_mac_ui.py'), '--output', str(output), '--variant', variant, '--team', '3UZ4C73FM2'], check=True, capture_output=True, text=True)
                    receipt = json.loads(result.stdout)
                    info = plistlib.loads((output / 'Taskfold/Info.plist').read_bytes())
                    isolated_type = receipt['bundleID'] + '.task'
                    self.assertEqual(info['UTExportedTypeDeclarations'], [{'UTTypeIdentifier': isolated_type, 'UTTypeDescription': 'Isolated Taskfold task', 'UTTypeConformsTo': ['public.data']}])
                    self.assertNotIn('CFBundleDocumentTypes', info)
                    self.assertNotIn('UTImportedTypeDeclarations', info)
                    if variant == 'p0widgethosts':
                        self.assertEqual(info['CFBundleURLTypes'][0]['CFBundleURLSchemes'], ['taskfold-widget-host-test'])
                    else:
                        self.assertNotIn('CFBundleURLTypes', info)
                    source = (output / 'Taskfold/Workspace.swift').read_text()
                    self.assertIn('UTType(exportedAs: "' + isolated_type + '")', source)
                    self.assertNotIn('"com.dbakp.taskfold.task"', source)
                    self.assertEqual(receipt['replacements']['com.dbakp.taskfold.task'], isolated_type)
        for path, contents in before.items():
            self.assertEqual(path.read_bytes(), contents, str(path))


    def test_record_route_variant_registers_only_a_private_scheme_in_app_and_driver(self):
        with tempfile.TemporaryDirectory(prefix='taskfold-record-stage-', dir='/private/tmp') as folder:
            output = Path(folder) / 'record-routes'
            result = subprocess.run(['python3', str(ROOT / 'Scripts/prepare_isolated_mac_ui.py'), '--output', str(output), '--variant', 'backupcanceltests', '--team', '3UZ4C73FM2', '--record-route-testing'], check=True, capture_output=True, text=True)
            receipt = json.loads(result.stdout)
            info = plistlib.loads((output / 'Taskfold/Info.plist').read_bytes())
            self.assertEqual(info['CFBundleURLTypes'][0]['CFBundleURLSchemes'], ['taskfold-backup-route-test'])
            self.assertEqual(receipt['isolatedURLScheme'], 'taskfold-backup-route-test')
            self.assertFalse(receipt['embeddedWidgetExtension'])
            for relative in ['Taskfold/Core/Models.swift', 'Taskfold/Views/RootView.swift', 'TaskfoldUITests/TaskfoldMacUITests.swift']:
                source = (output / relative).read_text()
                self.assertIn('"taskfold-backup-route-test"', source)
                self.assertNotIn('"taskfold"', source)
            self.assertNotIn('CFBundleDocumentTypes', info)

    def test_record_route_registration_cannot_expand_to_another_variant(self):
        with tempfile.TemporaryDirectory(prefix='taskfold-record-reject-', dir='/private/tmp') as folder:
            output = Path(folder) / 'rejected'
            result = subprocess.run(['python3', str(ROOT / 'Scripts/prepare_isolated_mac_ui.py'), '--output', str(output), '--variant', 'p0signeduitests', '--record-route-testing'], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('requires --variant backupcanceltests', result.stderr)
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
