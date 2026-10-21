#!/usr/bin/env python3
"""Verify the real app embeds only its own credential-free native share extension."""
from pathlib import Path
import json, plistlib, subprocess, unittest
ROOT = Path(__file__).resolve().parent.parent

class ShareExtensionConfigurationTests(unittest.TestCase):
    def test_owned_target_sources_embedding_and_entitlements(self):
        path = ROOT / 'Taskfold.xcodeproj/project.pbxproj'
        objects = json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(path)]))['objects']
        app_id, app = next((key,value) for key,value in objects.items() if value.get('isa')=='PBXNativeTarget' and value.get('name')=='Taskfold')
        share_id, share = next((key,value) for key,value in objects.items() if value.get('isa')=='PBXNativeTarget' and value.get('name')=='TaskfoldShare')
        self.assertTrue(any(objects[dep].get('target') == share_id for dep in app['dependencies']))
        self.assertEqual(share['productType'],'com.apple.product-type.app-extension')
        sources = next(objects[phase] for phase in share['buildPhases'] if objects[phase]['isa']=='PBXSourcesBuildPhase')
        paths = {objects[objects[build]['fileRef']]['path'] for build in sources['files']}
        self.assertEqual(paths, {'TaskfoldShare/ShareViewController.swift','Taskfold/Core/SharedCapture.swift'})
        for relative in paths: self.assertTrue((ROOT / relative).is_file())
        embedded = [objects[objects[build]['fileRef']].get('path') for phase in app['buildPhases'] if objects[phase]['isa']=='PBXCopyFilesBuildPhase' for build in objects[phase]['files']]
        self.assertIn('TaskfoldShare.appex', embedded)
        app_configs = objects[app['buildConfigurationList']]['buildConfigurations']
        share_configs = objects[share['buildConfigurationList']]['buildConfigurations']
        for app_key, share_key in zip(app_configs, share_configs):
            parent = objects[app_key]['buildSettings']; child = objects[share_key]['buildSettings']
            self.assertEqual(child['PRODUCT_BUNDLE_IDENTIFIER'],parent['PRODUCT_BUNDLE_IDENTIFIER']+'.share')
            self.assertEqual(str(child['APPLICATION_EXTENSION_API_ONLY']),'YES')
            self.assertEqual(str(child['MARKETING_VERSION']),str(parent['MARKETING_VERSION']))
            self.assertEqual(str(child['CURRENT_PROJECT_VERSION']),str(parent['CURRENT_PROJECT_VERSION']))
        info = plistlib.loads((ROOT/'TaskfoldShare/Info.plist').read_bytes())
        extension = info['NSExtension']
        self.assertEqual(extension['NSExtensionPointIdentifier'],'com.apple.share-services')
        rules = extension['NSExtensionAttributes']['NSExtensionActivationRule']
        self.assertEqual(rules, {'NSExtensionActivationSupportsText':True, 'NSExtensionActivationSupportsWebURLWithMaxCount':1})
        ent = plistlib.loads((ROOT/'TaskfoldShare/TaskfoldShare.entitlements').read_bytes())
        parent_ent = plistlib.loads((ROOT/'Taskfold/Taskfold.entitlements').read_bytes())
        self.assertTrue(set(ent['com.apple.security.application-groups']) & set(parent_ent['com.apple.security.application-groups']))
        self.assertNotIn('keychain-access-groups', ent)
        self.assertNotIn('com.apple.security.network.client', ent)
    def test_configuration_is_idempotent(self):
        path = ROOT/'Taskfold.xcodeproj/project.pbxproj'
        before = path.read_bytes()
        subprocess.run(['python3',str(ROOT/'Scripts/configure_share_extension.py')],check=True)
        self.assertEqual(path.read_bytes(),before)

if __name__ == '__main__': unittest.main()
