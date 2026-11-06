import copy
from datetime import datetime, timedelta, timezone
import hashlib
import unittest
from unittest import mock
from pathlib import Path
import tempfile
import sys
import build_daily
from cached_development_signing import select_profiles

class CachedDevelopmentSigningTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 11, 6, tzinfo=timezone.utc)
        self.cert = b'public synthetic certificate'; self.identity = hashlib.sha1(self.cert).hexdigest().upper()
        self.team = 'ABCDEFGHIJ'; self.bundle = 'com.example.app'; self.device = 'synthetic-device'
    def profile(self, platform='ios', bundle=None):
        return {'UUID':'11111111-1111-4111-8111-111111111111','Platform':['OSX' if platform=='mac' else 'iOS'], 'TeamIdentifier':[self.team], 'ExpirationDate':self.now+timedelta(days=1), 'DeveloperCertificates':[self.cert], 'ProvisionedDevices':[self.device], 'Entitlements':{('com.apple.application-identifier' if platform=='mac' else 'application-identifier'):self.team+'.'+(bundle or self.bundle), **({} if platform=='mac' else {'get-task-allow':True})}}
    def select(self, profiles, platform='ios', bundles=None, device=True):
        return select_profiles(profiles,platform=platform,team=self.team,bundles=bundles or [self.bundle],identities={self.identity},device=self.device if device else None,now=self.now)
    def test_exact_ios_identity_and_registered_device(self):
        p=self.profile();identity, selected=self.select([p]);self.assertEqual(identity,self.identity);self.assertEqual(selected,{self.bundle:p})
    def test_mac_per_device_profile_without_ios_debug_entitlement(self):
        p=self.profile('mac');self.assertEqual(self.select([p],'mac')[1][self.bundle],p)
    def test_expired_wrong_team_platform_bundle_or_device_never_substitute(self):
        for field,value in [('ExpirationDate',self.now),('TeamIdentifier',['KLMNOPQRST']),('Platform',['OSX']),('ProvisionedDevices',['other-device']),('UUID','-'*36)]:
            p=self.profile();p[field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):self.select([p])
        p=self.profile();p['Entitlements']['application-identifier']=self.team+'.*'
        with self.assertRaises(ValueError):self.select([p])
    def test_distribution_and_missing_private_identity_are_refused(self):
        p=self.profile();p['Entitlements']['get-task-allow']=False
        with self.assertRaises(ValueError):self.select([p])
        p=self.profile();p['DeveloperCertificates']=[b'other certificate']
        with self.assertRaises(ValueError):self.select([p])
        p=self.profile('mac');p['ProvisionedDevices']=[];p['ProvisionsAllDevices']=True
        with self.assertRaises(ValueError):self.select([p],'mac')
    def test_all_targets_must_have_profiles_and_one_authorized_identity(self):
        p=self.profile();widget=self.profile(bundle=self.bundle+'.widgets')
        with self.assertRaises(ValueError):self.select([p],bundles=[self.bundle,self.bundle+'.widgets'])
        self.assertEqual(len(self.select([p,widget],bundles=[self.bundle,self.bundle+'.widgets'])[1]),2)
        widget['DeveloperCertificates']=[b'other certificate']
        with self.assertRaises(ValueError):self.select([p,widget],bundles=[self.bundle,self.bundle+'.widgets'])
    def test_latest_usable_profile_wins_without_mutating_input(self):
        older=self.profile();newer=copy.deepcopy(older);newer['UUID']='22222222-2222-4222-8222-222222222222';newer['ExpirationDate']+=timedelta(days=1)
        original=copy.deepcopy([older,newer]);self.assertEqual(self.select([older,newer])[1][self.bundle],newer);self.assertEqual([older,newer],original)

class FailedDailyPreflightTests(unittest.TestCase):
    def test_missing_profiles_clear_stale_receipt_but_preserve_product_and_source(self):
        with tempfile.TemporaryDirectory(prefix='taskfold-profile-preflight-') as temporary:
            root=Path(temporary)/'repo';project=root/'Taskfold.xcodeproj';project.mkdir(parents=True)
            original=(b'CODE_SIGN_ENTITLEMENTS = Taskfold/Taskfold.entitlements;\n'*2)+b'projectDirPath = "";'
            (project/'project.pbxproj').write_bytes(original)
            cache=Path(temporary)/'cache';cache.mkdir()
            receipt=cache/('taskfold-daily-'+build_daily.PLATFORM+('-device' if build_daily.PLATFORM=='ios' else '')+'.json')
            receipt.write_text('{"old":true}')
            product=cache/'Build/Products/Taskfold.app/kept';product.parent.mkdir(parents=True);product.write_bytes(b'preserved old product')
            args=['build_daily.py','--derived-data',str(cache),'--cached-profiles','--team','ABCDEFGHIJ','--build-number','9999']
            with mock.patch.object(build_daily,'ROOT',root), mock.patch.object(sys,'argv',args), mock.patch.object(build_daily.subprocess,'check_output',return_value=''), mock.patch.object(build_daily.subprocess,'run'), mock.patch('cached_development_signing.configure_cached_profiles',side_effect=ValueError('No cached profiles')):
                with self.assertRaisesRegex(ValueError,'No cached profiles'):build_daily.main()
            self.assertFalse(receipt.exists())
            self.assertEqual(product.read_bytes(),b'preserved old product')
            self.assertEqual((project/'project.pbxproj').read_bytes(),original)

if __name__=='__main__':unittest.main()
