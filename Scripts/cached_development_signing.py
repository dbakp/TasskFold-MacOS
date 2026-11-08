"""Select existing, unexpired development profiles for this owner's daily copy.

No network access, profile creation, credential export or normal project mutation.
"""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess

from app_group_authorization import group_authorized


def select_profiles(profiles, *, platform, team, bundles, identities, device=None, now=None, required_groups=None):
    now = now or datetime.now(timezone.utc)
    choices = {}
    for bundle in bundles:
        matches = []
        for profile in profiles:
            entitlements = profile.get('Entitlements', {})
            app_id = entitlements.get('com.apple.application-identifier' if platform == 'mac' else 'application-identifier')
            expiry = profile.get('ExpirationDate')
            if not isinstance(expiry, datetime):
                continue
            expiry = expiry.replace(tzinfo=timezone.utc) if expiry.tzinfo is None else expiry.astimezone(timezone.utc)
            if app_id != team+'.'+bundle or profile.get('TeamIdentifier') != [team] or expiry <= now:
                continue
            if ('OSX' if platform == 'mac' else 'iOS') not in profile.get('Platform', []) or (platform == 'ios' and entitlements.get('get-task-allow') is not True) or (platform == 'mac' and not profile.get('ProvisionedDevices')):
                continue
            if device and device not in profile.get('ProvisionedDevices', []):
                continue
            if not isinstance(profile.get('UUID'), str) or not re.fullmatch(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', profile['UUID']):
                continue
            if any(not group_authorized(group, platform=platform, team=team, entitlements=entitlements)
                   for group in (required_groups or {}).get(bundle, [])):
                continue
            certificates = {hashlib.sha1(value).hexdigest().upper() for value in profile.get('DeveloperCertificates', []) if isinstance(value, bytes)}
            certificates &= identities
            if certificates:
                matches.append((expiry, profile['UUID'], profile, certificates))
        if not matches:
            raise ValueError('No unexpired cached development profile with an available signing identity for '+bundle)
        choices[bundle] = sorted(matches, key=lambda value: (value[0], value[1]), reverse=True)
    # Require one available private signing identity authorized by every selected
    # profile, rather than assuming a certificate name identifies one key.
    for identity in sorted(identities):
        if all(any(identity in item[3] for item in candidates) for candidates in choices.values()):
            return identity, {bundle: next(item[2] for item in candidates if identity in item[3]) for bundle, candidates in choices.items()}
    raise ValueError('Cached development profiles do not authorize a common available signing identity')


def configure_cached_profiles(project, *, platform, team, app_bundle, include_share=True, device=None, source_root=None):
    if not re.fullmatch(r'[A-Z0-9]{10}', team or ''):
        raise ValueError('Choose an existing development team for cached-profile signing')
    roots = [Path.home()/'Library/Developer/Xcode/UserData/Provisioning Profiles', Path.home()/'Library/MobileDevice/Provisioning Profiles']
    profiles = []
    for root in roots:
        for path in sorted(root.glob('*')):
            if path.suffix not in ['.mobileprovision', '.provisionprofile'] or not path.is_file():
                continue
            result = subprocess.run(['security', 'cms', '-D', '-i', str(path)], capture_output=True)
            if result.returncode == 0:
                try: profiles.append(plistlib.loads(result.stdout))
                except (ValueError, plistlib.InvalidFileException): pass
    inventory = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
    identities = {value.upper() for value in re.findall(r'\b([A-Fa-f0-9]{40})\s+"Apple Development:[^"]+"', inventory)}
    if platform == 'mac':
        hardware = json.loads(subprocess.check_output(['system_profiler', 'SPHardwareDataType', '-json'], text=True))
        device = hardware['SPHardwareDataType'][0].get('provisioning_UDID')
        if not isinstance(device, str) or not device:
            raise ValueError('The current Mac provisioning identifier is unavailable')
    bundles = [app_bundle, app_bundle+'.widgets']
    if include_share: bundles.append(app_bundle+'.share')
    project_data = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(project)], text=True))
    source_root = Path(source_root) if source_root else Path(project_data['objects'][project_data['rootObject']].get('projectDirPath') or project.parent.parent)
    required_groups = {}
    for target in project_data['objects'].values():
        if target.get('isa') != 'PBXNativeTarget': continue
        for key in project_data['objects'][target['buildConfigurationList']]['buildConfigurations']:
            settings = project_data['objects'][key]['buildSettings']; bundle = settings.get('PRODUCT_BUNDLE_IDENTIFIER')
            if bundle not in bundles: continue
            path = source_root / settings.get('CODE_SIGN_ENTITLEMENTS', '')
            if not path.is_file(): raise ValueError('Missing target entitlements for '+bundle)
            groups = plistlib.loads(path.read_bytes()).get('com.apple.security.application-groups', [])
            if not isinstance(groups, list) or not groups or any(not isinstance(g, str) for g in groups):
                raise ValueError('Missing shared-container declaration for '+bundle)
            if bundle in required_groups and set(required_groups[bundle]) != set(groups):
                raise ValueError('Debug and Release shared-container declarations differ for '+bundle)
            required_groups[bundle] = groups
    identity, selected = select_profiles(profiles, platform=platform, team=team, bundles=bundles, identities=identities, device=device, required_groups=required_groups)
    data = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(project)], text=True))
    objects, configured = data['objects'], set()
    for target in objects.values():
        if target.get('isa') != 'PBXNativeTarget': continue
        configurations = objects[target['buildConfigurationList']]['buildConfigurations']
        for key in configurations:
            settings = objects[key]['buildSettings']
            bundle = settings.get('PRODUCT_BUNDLE_IDENTIFIER')
            if bundle not in selected: continue
            managed = selected[bundle].get('IsXcodeManaged') is True
            settings.update(CODE_SIGN_STYLE='Automatic' if managed else 'Manual', DEVELOPMENT_TEAM=team,
                            CODE_SIGN_IDENTITY='Apple Development' if managed else identity,
                            PROVISIONING_PROFILE_SPECIFIER='' if managed else selected[bundle]['UUID'])
            settings.pop('PROVISIONING_PROFILE', None)
            configured.add(bundle)
    if configured != set(bundles):
        raise ValueError('Daily project targets do not match the explicitly selected profile identities')
    project.write_bytes(plistlib.dumps(data))
    return {'mode':'existing-development-profiles-only', 'identitySHA1':identity,
            'profiles':{bundle:{'uuid':profile['UUID'], 'expires':profile['ExpirationDate'].replace(tzinfo=timezone.utc).isoformat(), 'xcodeManaged':profile.get('IsXcodeManaged') is True} for bundle,profile in selected.items()},
            'profileCreationAllowed':False, 'networkProvisioningAllowed':False, 'appGroupDeclarationsAuthorized':True}


def verify_cached_profile_products(app, platform, signing):
    containers = [app] + list((app / ('Contents/PlugIns' if platform == 'mac' else 'PlugIns')).glob('*.appex'))
    actual = {}
    for container in containers:
        content = container/'Contents' if platform == 'mac' else container
        info = plistlib.loads((content/'Info.plist').read_bytes())
        bundle = info['CFBundleIdentifier']
        profile_path = content/('embedded.provisionprofile' if platform == 'mac' else 'embedded.mobileprovision')
        profile = plistlib.loads(subprocess.check_output(['security','cms','-D','-i',str(profile_path)],stderr=subprocess.DEVNULL))
        if bundle not in signing['profiles'] or profile['UUID'] != signing['profiles'][bundle]['uuid']:
            raise ValueError('Xcode did not embed the validated cached profile for '+bundle)
        actual[bundle] = profile['UUID']
    if set(actual) != set(signing['profiles']):
        raise ValueError('Signed bundle family differs from the validated cached profiles')
    signing['embeddedProfilesVerified'] = True
    from app_group_authorization import verify_app_group_products
    signing['appGroupAuthorization'] = verify_app_group_products(app, platform)
