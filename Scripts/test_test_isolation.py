#!/usr/bin/env python3
import plistlib, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_isolation as iso

HOSTED = 'https://zqxflydiyfjeedqvyova.supabase.co'


class TestIsolation(unittest.TestCase):
    def test_hosted_detection(self):
        for url in [HOSTED, 'HTTPS://ABCDEFGHIJKLMNOPQRST.SUPABASE.CO/', HOSTED + ':443/x', HOSTED + '.', 'https://u:p@a.supabase.co', 'not a url supabase.co']:
            self.assertTrue(iso.is_hosted(url), url)
        for url in ['http://127.0.0.1:54321', 'https://localhost', 'https://synthetic.example', iso.BLOCKED_ORIGIN, 'https://supabase.co.evil.invalid', '']:
            self.assertFalse(iso.is_hosted(url), url)

    def test_require_remote_refuses_by_default_and_consumes_flag(self):
        with self.assertRaises(SystemExit) as raised:
            iso.require_remote(HOSTED, argv=['script'])
        self.assertIn('REFUSED', str(raised.exception))
        argv = ['script', '--remote', 'fixture.json']
        iso.require_remote(HOSTED, argv=argv)
        self.assertEqual(argv, ['script', 'fixture.json'])
        argv = ['script']
        iso.require_remote('http://127.0.0.1:54321', argv=argv)

    def test_plist_is_stubbed_unless_a_human_opts_in(self):
        for environ, expect_hosted in [({}, False), ({iso.OPT_IN: '0'}, False), ({iso.OPT_IN: '1'}, True)]:
            with tempfile.TemporaryDirectory() as d:
                plist = Path(d) / 'Taskfold/Backend.plist'; plist.parent.mkdir()
                plist.write_bytes(plistlib.dumps({'URL': HOSTED, 'Key': 'public'}))
                iso.isolate_backend_plist(Path(d), environ)
                value = plistlib.loads(plist.read_bytes())
                self.assertEqual(iso.is_hosted(value['URL']), expect_hosted)
                if not expect_hosted:
                    self.assertEqual(value['URL'], iso.BLOCKED_ORIGIN); self.assertNotEqual(value['Key'], 'public')

    def test_local_plist_untouched(self):
        with tempfile.TemporaryDirectory() as d:
            plist = Path(d) / 'Backend.plist'; plist.write_bytes(plistlib.dumps({'URL': 'http://127.0.0.1:54321', 'Key': 'k'}))
            self.assertFalse(iso.isolate_backend_plist(Path(d), {}))


if __name__ == '__main__':
    unittest.main()
