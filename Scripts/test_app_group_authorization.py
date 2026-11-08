import copy
from datetime import datetime, timedelta, timezone
import hashlib
import unittest
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

if __name__=='__main__':unittest.main()
