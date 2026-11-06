#!/usr/bin/env python3
"""Archive and read back this owner's verified daily app; never installs or publishes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import stat
import tempfile
import zipfile
import build_daily as daily


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024*1024), b''): value.update(chunk)
    return value.hexdigest()


def payload(root):
    result = {}
    for path in root.rglob('*'):
        relative = str(path.relative_to(root))
        if path.is_symlink(): result[relative] = ['symlink', os.readlink(path)]
        elif path.is_file(): result[relative] = ['file', digest(path), stat.S_IMODE(path.stat().st_mode)]
        elif path.is_dir(): result[relative] = ['directory', stat.S_IMODE(path.stat().st_mode)]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipt', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--baseline-receipt', type=Path, help='Preserved installed/current baseline; never modified')
    args = parser.parse_args()
    receipt = json.loads(args.receipt.read_text())
    if receipt.get('platform') != daily.PLATFORM or receipt.get('bundle') != daily.BUNDLE or receipt.get('simulatorOnly') is not False or receipt.get('signatureVerified') is not True:
        raise ValueError('An owning signed development-device/Mac build receipt is required')
    app = Path(receipt['app']).resolve()
    info = plistlib.loads((app/('Contents/Info.plist' if daily.PLATFORM=='mac' else 'Info.plist')).read_bytes())
    if info['CFBundleIdentifier'] != daily.BUNDLE or info['CFBundleShortVersionString'] != receipt['version'] or info['CFBundleVersion'] != receipt['build']:
        raise ValueError('The candidate was replaced after its build receipt')
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}',receipt['version']) or not re.fullmatch(r'[0-9]+',receipt['build']):
        raise ValueError('Unexpected version/build format')
    current = daily.fingerprint((daily.ROOT/'Taskfold.xcodeproj/project.pbxproj').read_bytes())
    if current != receipt['sourceFingerprint']: raise ValueError('App inputs changed after the candidate build')
    for name, expected in receipt.get('buildToolsSHA256',{}).items():
        if digest(daily.ROOT/'Scripts'/name) != expected: raise ValueError('Build tool changed after candidate creation: '+name)
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
    baseline = None
    if args.baseline_receipt:
        baseline = json.loads(args.baseline_receipt.read_text())
        if baseline['bundle'] != daily.BUNDLE or int(baseline['build']) >= int(receipt['build']): raise ValueError('The update must be newer than its own preserved baseline')
        if digest(Path(baseline['archive'])) != baseline['archiveSHA256']: raise ValueError('Preserved baseline archive changed')
    directory = args.output.resolve(); directory.mkdir(parents=True,exist_ok=True)
    label = 'mac' if daily.PLATFORM=='mac' else 'iphone'
    archive = directory/('Taskfold-'+receipt['version']+'-'+receipt['build']+'-'+label+'-development.zip')
    metadata = directory/('build-'+receipt['build']+('-iphone' if daily.PLATFORM=='ios' else '')+'.json')
    if archive.exists() or metadata.exists(): raise ValueError('Preserve previous candidate outputs; choose a new build number')
    with tempfile.TemporaryDirectory(prefix='.taskfold-package-',dir=directory) as temporary, tempfile.TemporaryDirectory(prefix='taskfold-code-readback-') as readback:
        folder = Path(temporary); packed = folder/'candidate.zip'
        subprocess.run(['ditto','-c','-k','--sequesterRsrc','--keepParent',str(app),str(packed)],check=True)
        with zipfile.ZipFile(packed) as contents:
            if contents.testzip() is not None: raise ValueError('Archive integrity check failed')
        extracted = Path(readback)
        subprocess.run(['ditto','-x','-k',str(packed),str(extracted)],check=True)
        restored = extracted/app.name
        if payload(app) != payload(restored): raise ValueError('Archive readback does not preserve the exact app payload')
        subprocess.run(['codesign','--verify','--deep','--strict',str(restored)],check=True)
        signing = receipt.get('cachedProfileSigning')
        if signing:
            from cached_development_signing import verify_cached_profile_products
            verify_cached_profile_products(restored,daily.PLATFORM,signing)
        if daily.PLATFORM=='ios' and receipt.get('developmentOnlyWidgetVariant'):
            profile=plistlib.loads(subprocess.check_output(['security','cms','-D','-i',str(restored/'embedded.mobileprovision')],stderr=subprocess.DEVNULL))
            devices=profile.get('ProvisionedDevices',[])
            if not devices: raise ValueError('Development phone profile has no registered device')
            daily.verify_widget_only_development(restored,devices[0])
        else:
            subprocess.run(['python3','Scripts/verify_continuity_release.py','--app',str(restored)],cwd=daily.ROOT,check=True)
        if daily.fingerprint((daily.ROOT/'Taskfold.xcodeproj/project.pbxproj').read_bytes()) != current or payload(app) != payload(restored):
            raise ValueError('Candidate/source changed during archive verification')
        result = dict(receipt,archive=str(archive),archiveSHA256=digest(packed),archivePayloadVerified=True,readbackMetadataIsolated=True,installed=False,published=False,
                      sourceWasDirty=bool(subprocess.check_output(['git','status','--porcelain'],cwd=daily.ROOT,text=True).strip()),
                      packagingToolSHA256=digest(Path(__file__)),installationNote='Prepared only; existing app session and data are preserved.')
        if baseline: result['installedBaseline']=baseline['version']+' ('+baseline['build']+')'
        if signing: result['developmentProfileExpires']=min(value['expires'] for value in signing['profiles'].values())
        packed.chmod(0o600)
        # Same-filesystem exclusive links publish verified results without
        # replacing another run's artifact. On failure remove only our own link.
        os.link(packed,archive)
        try:
            data=folder/'receipt.json';data.write_text(json.dumps(result,indent=2)+'\n');data.chmod(0o600);os.link(data,metadata)
        except BaseException:
            if archive.samefile(packed): archive.unlink()
            raise
    print(json.dumps({'platform':daily.PLATFORM,'version':result['version'],'build':result['build'],'archive':str(archive),'archivePayloadVerified':True,'installed':False}))

if __name__=='__main__':main()
