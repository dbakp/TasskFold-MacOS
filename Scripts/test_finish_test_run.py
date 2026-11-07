"""Real temporary-file tests for bounded cleanup and protected paths."""
import importlib.util
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import json
import sys

spec=importlib.util.spec_from_file_location('cleanup',Path(__file__).resolve().parent/'finish_test_run.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.home=Path(self.tmp.name);self.cache=self.home/'Library/Caches/TaskfoldBuild/daily-ios';(self.cache/'DailyProject/Taskfold.xcodeproj').mkdir(parents=True);self.scratch=self.cache/'Build/Intermediates.noindex';self.scratch.mkdir(parents=True);(self.scratch/'object.o').write_text('generated');self.product=self.cache/'Build/Products/Taskfold.app/Taskfold';self.product.parent.mkdir(parents=True);self.product.write_text('keep product');self.result=self.cache/'Logs/Test/proof.xcresult/evidence';self.result.parent.mkdir(parents=True);self.result.write_text('keep evidence')
        self.homepatch=patch.object(module.Path,'home',return_value=self.home);self.homepatch.start();self.addCleanup(self.homepatch.stop)
        self.diskpatch=patch.object(module.shutil,'disk_usage',return_value=SimpleNamespace(free=25*1024**3));self.diskpatch.start();self.addCleanup(self.diskpatch.stop)
    def test_apply_only_completed_compiler_scratch(self):
        with patch.object(module.subprocess,'check_output',return_value=''):
            r=module.finish(build_caches=[self.cache],apply=True)
        self.assertFalse(self.scratch.exists());self.assertTrue(self.product.exists());self.assertTrue(self.result.exists());self.assertEqual(len(r['actions']),1)
    def test_sdk_and_compilation_caches_share_the_completed_cache_budget(self):
        sdk=self.cache/'SDKExplicitPrecompiledModules';sdk.mkdir();(sdk/'module.pcm').write_text('generated')
        cas=self.cache/'CompilationCache.noindex';cas.mkdir();(cas/'cache.db').write_text('generated')
        dependency=self.cache/'SourcePackages/checkout/source.swift';dependency.parent.mkdir(parents=True);dependency.write_text('keep dependency')
        actual=module.allocated
        def measured(path):
            if path.resolve()==sdk.resolve():return 800*1024**2
            if path.resolve()==self.cache.resolve():return 800*1024**2+actual(path)
            return actual(path)
        with patch.object(module.subprocess,'check_output',return_value=''),patch.object(module.shutil,'disk_usage',return_value=SimpleNamespace(free=60*1024**3)),patch.object(module,'allocated',side_effect=measured):
            result=module.finish(build_caches=[self.cache],apply=True)
        self.assertFalse(sdk.exists());self.assertFalse(cas.exists());self.assertTrue(self.scratch.exists())
        self.assertTrue(self.product.exists());self.assertTrue(self.result.exists());self.assertEqual(dependency.read_text(),'keep dependency')
        self.assertEqual(len(result['actions']),2)
        self.assertLessEqual(result['skipped'][-1]['allocatedBytes'],768*1024**2)
    def test_module_trim_retires_stale_dependency_plan_and_preserves_objects(self):
        sdk=self.cache/'SDKExplicitPrecompiledModules';sdk.mkdir();(sdk/'module.pcm').write_text('generated')
        metadata=self.scratch/'XCBuildData';metadata.mkdir();(metadata/'build.db').write_text('references removed module.scan')
        actual=module.allocated
        def measured(path):
            if path.resolve()==sdk.resolve():return 800*1024**2
            if path.resolve()==self.cache.resolve():return 800*1024**2+actual(path)
            return actual(path)
        with patch.object(module.subprocess,'check_output',return_value=''),patch.object(module.shutil,'disk_usage',return_value=SimpleNamespace(free=60*1024**3)),patch.object(module,'allocated',side_effect=measured):
            report=module.finish(build_caches=[self.cache],apply=True)
        self.assertFalse(sdk.exists());self.assertFalse(metadata.exists())
        self.assertTrue((self.scratch/'object.o').exists());self.assertTrue(self.product.exists());self.assertTrue(self.result.exists())
        self.assertEqual([x['kind'] for x in report['actions']],['completedCompilerCache','completedBuildMetadata'])
    def test_dependency_plan_is_kept_on_dry_run_healthy_or_running_build(self):
        sdk=self.cache/'SDKExplicitPrecompiledModules';sdk.mkdir();(sdk/'module.pcm').write_text('generated')
        metadata=self.scratch/'XCBuildData';metadata.mkdir();(metadata/'build.db').write_text('keep plan')
        actual=module.allocated
        def measured(path):
            if path.resolve()==sdk.resolve():return 800*1024**2
            if path.resolve()==self.cache.resolve():return 800*1024**2+actual(path)
            return actual(path)
        with patch.object(module.subprocess,'check_output',return_value=''),patch.object(module.shutil,'disk_usage',return_value=SimpleNamespace(free=60*1024**3)):
            self.assertEqual(module.finish(build_caches=[self.cache],apply=True)['actions'],[])
            with patch.object(module,'allocated',side_effect=measured):
                self.assertEqual(len(module.finish(build_caches=[self.cache],apply=False)['actions']),2)
                with patch.object(module.subprocess,'check_output',return_value='xcodebuild -derivedDataPath '+str(self.cache)):
                    self.assertEqual(module.finish(build_caches=[self.cache],apply=True)['actions'],[])
        self.assertTrue(sdk.exists());self.assertEqual((metadata/'build.db').read_text(),'keep plan')
    def test_budget_includes_protected_products_and_never_deletes_them(self):
        actual=module.allocated
        def measured(path):return 900*1024**2 if path.resolve()==self.cache.resolve() else actual(path)
        with patch.object(module.subprocess,'check_output',return_value=''),patch.object(module.shutil,'disk_usage',return_value=SimpleNamespace(free=60*1024**3)),patch.object(module,'allocated',side_effect=measured):
            report=module.finish(build_caches=[self.cache],apply=True)
        self.assertTrue(self.product.exists());self.assertTrue(self.result.exists())
        self.assertFalse(report['skipped'][-1]['within768MiB'])
        self.assertIn('Protected products/evidence',report['skipped'][-1]['reason'])
    def test_dependency_plan_symlink_is_rejected_before_cleanup(self):
        outside=self.home/'unrelated';outside.mkdir();(outside/'keep').write_text('real data')
        (self.scratch/'XCBuildData').symlink_to(outside,target_is_directory=True)
        with patch.object(module.subprocess,'check_output',return_value=''),self.assertRaises(ValueError):
            module.finish(build_caches=[self.cache],apply=True)
        self.assertTrue((self.scratch/'object.o').exists());self.assertEqual((outside/'keep').read_text(),'real data')
    def test_budget_dry_run_and_healthy_symlink_never_remove_files(self):
        sdk=self.cache/'SDKExplicitPrecompiledModules';sdk.mkdir();(sdk/'module.pcm').write_text('generated')
        actual=module.allocated
        def measured(path):
            if path.resolve()==sdk.resolve():return 800*1024**2
            if path.resolve()==self.cache.resolve():return 800*1024**2+actual(path)
            return actual(path)
        with patch.object(module.subprocess,'check_output',return_value=''),patch.object(module.shutil,'disk_usage',return_value=SimpleNamespace(free=60*1024**3)),patch.object(module,'allocated',side_effect=measured):
            result=module.finish(build_caches=[self.cache],apply=False)
        self.assertTrue(sdk.exists());self.assertTrue(self.scratch.exists());self.assertEqual(len(result['actions']),1)
        self.assertGreater(result['skipped'][-1]['allocatedBytes'],768*1024**2);self.assertLessEqual(result['skipped'][-1]['projectedAllocatedBytes'],768*1024**2)
        (sdk/'module.pcm').unlink();sdk.rmdir();outside=self.home/'unrelated';outside.mkdir();(outside/'source').write_text('keep');sdk.symlink_to(outside,target_is_directory=True)
        with patch.object(module.subprocess,'check_output',return_value=''),patch.object(module.shutil,'disk_usage',return_value=SimpleNamespace(free=60*1024**3)),self.assertRaises(ValueError):
            module.finish(build_caches=[self.cache],apply=True)
        self.assertEqual((outside/'source').read_text(),'keep')
    def test_dry_run_and_active_compiler_preserve_files(self):
        with patch.object(module.subprocess,'check_output',return_value=''):
            module.finish(build_caches=[self.cache],apply=False)
        self.assertTrue(self.scratch.exists())
        with patch.object(module.subprocess,'check_output',return_value='/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -derivedDataPath '+str(self.cache)+'\n'):
            r=module.finish(build_caches=[self.cache],apply=True)
        self.assertTrue(self.scratch.exists());self.assertTrue(r['skipped'])
    def test_healthy_small_cache_is_retained(self):
        with patch.object(module.subprocess,'check_output',return_value=''),patch.object(module.shutil,'disk_usage',return_value=SimpleNamespace(free=60*1024**3)):
            r=module.finish(build_caches=[self.cache],apply=True)
        self.assertTrue(self.scratch.exists());self.assertEqual(r['actions'],[])
    def test_compiler_symlink_cannot_delete_other_data(self):
        (self.scratch/'object.o').unlink();self.scratch.rmdir();outside=self.home/'outside';outside.mkdir();(outside/'data').write_text('keep');self.scratch.symlink_to(outside,target_is_directory=True)
        with patch.object(module.subprocess,'check_output',return_value=''),self.assertRaises(ValueError):module.finish(build_caches=[self.cache],apply=True)
        self.assertEqual((outside/'data').read_text(),'keep')
    def test_unrelated_compiler_does_not_prevent_owned_cleanup(self):
        with patch.object(module.subprocess,'check_output',return_value='/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -derivedDataPath /tmp/UnrelatedProject\n'):
            r=module.finish(build_caches=[self.cache],apply=True)
        self.assertFalse(self.scratch.exists());self.assertTrue(self.product.exists());self.assertEqual(len(r['actions']),1)
    def test_reject_unmarked_directory(self):
        p=self.home/'important';p.mkdir();(p/'data').write_text('keep')
        with patch.object(module.subprocess,'check_output',return_value=''),self.assertRaises(ValueError):module.finish(build_caches=[p],apply=True)
        self.assertEqual((p/'data').read_text(),'keep')
    def test_shutdown_wallpaper_scratch_preserves_app_and_booted_device(self):
        def make(device):
            root=self.home/'Library/Developer/CoreSimulator/Devices'/device/'data';cache=root/'Library/Application Support/PRBPosterExtensionDataStore/61/Extensions/Poster/descriptors/id/versions/1/scratch/SnapshotCache.cachedb';cache.mkdir(parents=True);(cache/'image.atx').write_text('generated');app=root/'Containers/Data/Application/test/Taskfold.json';app.parent.mkdir(parents=True);app.write_text('keep tasks');return cache,app
        stopped,app=make('stopped');booted,_=make('booted')
        inventory=json.dumps({'devices':{'iOS':[{'udid':'stopped','state':'Shutdown'},{'udid':'booted','state':'Booted'}]}})
        def command(args,**kwargs):return '' if args[0]=='ps' else inventory
        with patch.object(module.subprocess,'check_output',side_effect=command):r=module.finish(simulators=['stopped','booted'],apply=True)
        self.assertFalse(stopped.exists());self.assertTrue(booted.exists());self.assertEqual(app.read_text(),'keep tasks');self.assertEqual(len(r['actions']),1);self.assertEqual(len(r['skipped']),1)
unittest.main()
