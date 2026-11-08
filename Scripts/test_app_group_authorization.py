import copy
from datetime import datetime, timedelta, timezone
import hashlib
import unittest
from pathlib import Path
from app_group_authorization import group_authorized
from cached_development_signing import select_profiles


class AppGroupAuthorizationTests(unittest.TestCase):
    def allowed(self, group='group.com.example.tasks', groups=None, platform='mac', team='ABCDEFGHIJ'):
        entitlements = {} if groups is None else {'com.apple.security.application-groups': groups}
        return group_authorized(group, platform=platform, team=team, entitlements=entitlements)
    def test_signed_claim_alone_does_not_authorize_group_namespace(self):
        self.assertFalse(self.allowed()); self.assertFalse(self.allowed(groups=[]))
        self.assertFalse(self.allowed(groups=['group.com.example.other']))
        self.assertTrue(self.allowed(groups=['group.com.example.tasks']))
    def test_authorized_profile_prefix_obeys_literal_boundary(self):
        self.assertTrue(self.allowed(groups=['group.com.example.*']))
        self.assertFalse(self.allowed(groups=['group.com.examples.*']))
        self.assertFalse(self.allowed(groups=['group.com.exam*ple.*']))
        self.assertFalse(self.allowed(groups=['group.com.example.?asks']))
    def test_team_namespace_is_mac_only_and_must_match_real_team(self):
        self.assertTrue(self.allowed(group='ABCDEFGHIJ.com.example.tasks'))
        self.assertFalse(self.allowed(group='KLMNOPQRST.com.example.tasks'))
        self.assertFalse(self.allowed(group='ABCDEFGHIJ.com.example.tasks', platform='ios'))
        self.assertFalse(self.allowed(group='ABCDEFGHIJ.com.example.tasks', team='not set'))
    def test_malformed_claims_and_profile_types_cannot_authorize(self):
        for group in [None, '', 'group.*', 'arbitrary']:
            with self.subTest(group=group):self.assertFalse(self.allowed(group=group, groups=['*']))
        for groups in ['group.com.example.tasks', {}, [True], [None]]:
            with self.subTest(groups=groups):self.assertFalse(self.allowed(groups=groups))
    def test_cached_selection_ignores_newer_profile_missing_required_group(self):
        now = datetime(2026,11,8,tzinfo=timezone.utc); cert=b'synthetic public certificate'; identity=hashlib.sha1(cert).hexdigest().upper()
        old={'UUID':'11111111-1111-4111-8111-111111111111','Platform':['OSX'],'TeamIdentifier':['ABCDEFGHIJ'],'ExpirationDate':now+timedelta(days=1),'DeveloperCertificates':[cert],'ProvisionedDevices':['synthetic-device'],'Entitlements':{'com.apple.application-identifier':'ABCDEFGHIJ.com.example.tasks','com.apple.security.application-groups':['group.com.example.tasks']}}
        new=copy.deepcopy(old);new['UUID']='22222222-2222-4222-8222-222222222222';new['ExpirationDate']+=timedelta(days=1);new['Entitlements'].pop('com.apple.security.application-groups')
        before=copy.deepcopy([old,new]);args=dict(platform='mac',team='ABCDEFGHIJ',bundles=['com.example.tasks'],identities={identity},device='synthetic-device',now=now,required_groups={'com.example.tasks':['group.com.example.tasks']})
        self.assertEqual(select_profiles([old,new],**args)[1]['com.example.tasks'],old)
        self.assertEqual([old,new],before)
        with self.assertRaises(ValueError):select_profiles([new],**args)
    def test_every_group_and_every_bundle_requires_authorization(self):
        now=datetime(2026,11,8,tzinfo=timezone.utc);cert=b'synthetic public certificate';identity=hashlib.sha1(cert).hexdigest().upper()
        def profile(bundle):return {'UUID':'11111111-1111-4111-8111-111111111111','Platform':['iOS'],'TeamIdentifier':['ABCDEFGHIJ'],'ExpirationDate':now+timedelta(days=1),'DeveloperCertificates':[cert],'ProvisionedDevices':['synthetic-device'],'Entitlements':{'application-identifier':'ABCDEFGHIJ.'+bundle,'get-task-allow':True,'com.apple.security.application-groups':['group.com.example.tasks']}}
        app,extension=profile('com.example.tasks'),profile('com.example.tasks.widgets')
        args=dict(platform='ios',team='ABCDEFGHIJ',bundles=['com.example.tasks','com.example.tasks.widgets'],identities={identity},device='synthetic-device',now=now,required_groups={'com.example.tasks':['group.com.example.tasks'],'com.example.tasks.widgets':['group.com.example.tasks','group.com.example.other']})
        with self.assertRaises(ValueError):select_profiles([app,extension],**args)
        extension['Entitlements']['com.apple.security.application-groups'].append('group.com.example.other')
        self.assertEqual(len(select_profiles([app,extension],**args)[1]),2)



class SignedGroupProductTests(unittest.TestCase):
    def products(self, *, group='group.com.example.tasks', platform='mac', missing=None, wrong_team=None, omit_profile=False):
        import contextlib, tempfile, plistlib, subprocess
        from unittest import mock
        from app_group_authorization import verify_app_group_products
        stack=contextlib.ExitStack();self.addCleanup(stack.close)
        root=Path(stack.enter_context(tempfile.TemporaryDirectory(prefix='taskfold-group-products-')))/'Taskfold.app'
        prefix='Contents' if platform=='mac' else ''
        parent=root/prefix;parent.mkdir(parents=True)
        bundles=[root,parent/'PlugIns/TaskfoldWidgets.appex',parent/'PlugIns/TaskfoldShare.appex'];states={}
        for i,bundle in enumerate(bundles):
            content=bundle/prefix;content.mkdir(parents=True,exist_ok=True)
            (content/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.example.tasks'+['','.widgets','.share'][i]}))
            ent={'com.apple.security.application-groups':[group]}
            profile={'TeamIdentifier':['ABCDEFGHIJ'],'Entitlements':{'com.apple.security.application-groups':[] if i==missing else [group]}}
            path=content/('embedded.provisionprofile' if platform=='mac' else 'embedded.mobileprovision')
            if not omit_profile:path.write_bytes(plistlib.dumps(profile))
            states[str(bundle)]={'entitlements':ent,'team':'KLMNOPQRST' if i==wrong_team else 'ABCDEFGHIJ','profile':path}
        def output(args,**kwargs):
            if args[0]=='codesign':return plistlib.dumps(states[args[-1]]['entitlements'])
            if args[0]=='security':return Path(args[-1]).read_bytes()
            raise AssertionError(args)
        def run(args,**kwargs):return subprocess.CompletedProcess(args,0,'','TeamIdentifier='+states[args[-1]]['team']+'\n')
        stack.enter_context(mock.patch('app_group_authorization.subprocess.check_output',side_effect=output))
        stack.enter_context(mock.patch('app_group_authorization.subprocess.run',side_effect=run))
        return lambda:verify_app_group_products(root,platform)
    def test_every_signed_bundle_must_be_authorized_by_its_own_profile(self):
        self.assertTrue(self.products()()['verified'])
        for i in range(3):
            with self.subTest(bundle=i),self.assertRaisesRegex(ValueError,'does not authorize'):
                self.products(missing=i)()
    def test_different_signing_team_cannot_join_family(self):
        with self.assertRaisesRegex(ValueError,'same team'):
            self.products(wrong_team=1)()
    def test_macos_team_namespace_can_work_without_profile_but_ios_cannot(self):
        self.assertTrue(self.products(group='ABCDEFGHIJ.com.example.tasks',omit_profile=True)()['verified'])
        with self.assertRaisesRegex(ValueError,'does not authorize'):
            self.products(group='ABCDEFGHIJ.com.example.tasks',platform='ios',omit_profile=True)()
    def test_group_namespace_cannot_work_without_profile(self):
        with self.assertRaisesRegex(ValueError,'does not authorize'):
            self.products(omit_profile=True)()



class AppGroupConfigurationTests(unittest.TestCase):
    def configure(self, authorized):
        import tempfile, plistlib, json, subprocess
        from unittest import mock
        from cached_development_signing import configure_cached_profiles
        with tempfile.TemporaryDirectory(prefix='taskfold-group-config-') as tmp:
            root=Path(tmp);home=root/'home';profiles=home/'Library/Developer/Xcode/UserData/Provisioning Profiles';profiles.mkdir(parents=True)
            project=root/'Taskfold.xcodeproj/project.pbxproj';project.parent.mkdir()
            team='ABCDEFGHIJ';base='com.example.tasks';cert=b'synthetic public certificate';identity=hashlib.sha1(cert).hexdigest().upper()
            objects={'root':{'isa':'PBXProject','projectDirPath':str(root)}}
            for index,bundle in enumerate([base,base+'.widgets',base+'.share']):
                groups=['group.com.example.tasks'];entfile=root/('target'+str(index)+'.entitlements');entfile.write_bytes(plistlib.dumps({'com.apple.security.application-groups':groups}))
                keys=[]
                for config in ['debug','release']:
                    key=str(index)+config;keys.append(key);objects[key]={'isa':'XCBuildConfiguration','buildSettings':{'PRODUCT_BUNDLE_IDENTIFIER':bundle,'CODE_SIGN_ENTITLEMENTS':entfile.name}}
                objects['list'+str(index)]={'buildConfigurations':keys};objects['target'+str(index)]={'isa':'PBXNativeTarget','buildConfigurationList':'list'+str(index)}
                p={'UUID':str(index+1)*8+'-1111-4111-8111-111111111111','Platform':['OSX'],'TeamIdentifier':[team],'ExpirationDate':datetime.now(timezone.utc)+timedelta(days=1),'DeveloperCertificates':[cert],'ProvisionedDevices':['synthetic-device'],'Entitlements':{'com.apple.application-identifier':team+'.'+bundle}}
                if authorized:p['Entitlements']['com.apple.security.application-groups']=groups
                (profiles/(str(index)+'.provisionprofile')).write_bytes(plistlib.dumps(p))
            data={'rootObject':'root','objects':objects};original=plistlib.dumps(data);project.write_bytes(original)
            def run(args,**kwargs):return subprocess.CompletedProcess(args,0,Path(args[-1]).read_bytes(),b'')
            def output(args,**kwargs):
                if args[0]=='security':return identity+' "Apple Development: Synthetic"'
                if args[0]=='system_profiler':return json.dumps({'SPHardwareDataType':[{'provisioning_UDID':'synthetic-device'}]})
                if args[0]=='plutil':return json.dumps(plistlib.loads(project.read_bytes()))
                raise AssertionError(args)
            with mock.patch('cached_development_signing.Path.home',return_value=home),mock.patch('cached_development_signing.subprocess.run',side_effect=run),mock.patch('cached_development_signing.subprocess.check_output',side_effect=output):
                if not authorized:
                    with self.assertRaisesRegex(ValueError,'No unexpired cached'):configure_cached_profiles(project,platform='mac',team=team,app_bundle=base,source_root=root)
                    self.assertEqual(project.read_bytes(),original);return
                receipt=configure_cached_profiles(project,platform='mac',team=team,app_bundle=base,source_root=root)
            self.assertTrue(receipt['appGroupDeclarationsAuthorized']);self.assertEqual(len(receipt['profiles']),3)
            result=plistlib.loads(project.read_bytes())['objects']
            for i in range(3):
                for c in ['debug','release']:self.assertEqual(result[str(i)+c]['buildSettings']['PROVISIONING_PROFILE_SPECIFIER'],str(i+1)*8+'-1111-4111-8111-111111111111')
    def test_validated_profiles_configure_all_six_target_configurations(self):self.configure(True)
    def test_missing_group_refuses_before_mutating_project(self):self.configure(False)

if __name__=='__main__':unittest.main()
