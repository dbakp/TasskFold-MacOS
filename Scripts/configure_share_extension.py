#!/usr/bin/env python3
"""Add this repository's independently owned native share target, without rewriting unrelated targets."""
from pathlib import Path
import hashlib, json, re, subprocess, os

ROOT = Path(__file__).resolve().parent.parent
project = ROOT / 'Taskfold.xcodeproj/project.pbxproj'
if os.environ.get('TASKFOLD_SHARE', '1') == '0': raise SystemExit(0)
source = project.read_text()
objects = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(project)]))['objects']
if any(row.get('isa') == 'PBXNativeTarget' and row.get('name') == 'TaskfoldShare' for row in objects.values()):
    raise SystemExit(0)

def uid(name): return hashlib.sha256(('taskfold-share:' + name).encode()).hexdigest()[:24].upper()
lines = []
def add(key, value): lines.append(f'{key} = {{ {value} }};')
def append(key, field, value):
    global source
    pattern = r'(' + re.escape(key) + r'\s*=\s*\{[^\n]*?\b' + re.escape(field) + r'\s*=\s*\()'
    source, count = re.subn(pattern, lambda m: m[1] + value + ',', source, count=1)
    if count != 1: raise RuntimeError('Could not locate ' + key + '.' + field)

def reference(path):
    existing = next((key for key, row in objects.items() if row.get('isa') == 'PBXFileReference' and row.get('path') == path), None)
    if existing: return existing
    key = uid('ref:' + path)
    kind = 'sourcecode.swift' if path.endswith('.swift') else 'text.plist.entitlements' if path.endswith('.entitlements') else 'text.plist.xml'
    add(key, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = "{path}"; sourceTree = "<group>";')
    return key

app_id, app = next((key, row) for key, row in objects.items() if row.get('isa') == 'PBXNativeTarget' and row.get('name') == 'Taskfold')
project_id, proj = next((key, row) for key, row in objects.items() if row.get('isa') == 'PBXProject')
app_settings = objects[objects[app['buildConfigurationList']]['buildConfigurations'][0]]['buildSettings']
project_settings = objects[objects[proj['buildConfigurationList']]['buildConfigurations'][0]]['buildSettings']
mac = project_settings.get('SDKROOT') == 'macosx'
app_phase = next(key for key in app['buildPhases'] if objects[key]['isa'] == 'PBXSourcesBuildPhase')
for path in ['Taskfold/Core/SharedCapture.swift', 'Taskfold/Core/SharedCapturePlan.swift', 'Taskfold/SharedCaptureStore.swift', 'Taskfold/Views/SharedDraftsView.swift']:
    ref = reference(path)
    already = any(objects.get(key, {}).get('fileRef') == ref for key in objects[app_phase]['files'])
    if not already:
        build = uid('app-build:' + path); add(build, f'isa = PBXBuildFile; fileRef = {ref};')
        append(app_phase, 'files', build); append(proj['mainGroup'], 'children', ref)

paths = ['TaskfoldShare/ShareViewController.swift', 'Taskfold/Core/SharedCapture.swift']
refs = [reference(path) for path in paths]
info = reference('TaskfoldShare/Info.plist'); ent = reference('TaskfoldShare/TaskfoldShare.entitlements')
builds = []
for path, ref in zip(paths, refs):
    build = uid('extension-build:' + path); add(build, f'isa = PBXBuildFile; fileRef = {ref};'); builds.append(build)
product = uid('product'); target = uid('target'); phase = uid('sources'); framework = uid('frameworks'); config_list = uid('config-list')
add(product, 'isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; path = TaskfoldShare.appex; sourceTree = BUILT_PRODUCTS_DIR;')
add(phase, 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (' + ','.join(builds) + ',); runOnlyForDeploymentPostprocessing = 0;')
add(framework, 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
configs = []
for name in ['Debug', 'Release']:
    config = uid('config:' + name); configs.append(config)
    settings = {
        'PRODUCT_NAME':'TaskfoldShare', 'PRODUCT_BUNDLE_IDENTIFIER':app_settings['PRODUCT_BUNDLE_IDENTIFIER'] + '.share',
        'GENERATE_INFOPLIST_FILE':'NO', 'INFOPLIST_FILE':'TaskfoldShare/Info.plist',
        'CODE_SIGN_ENTITLEMENTS':'TaskfoldShare/TaskfoldShare.entitlements', 'SKIP_INSTALL':'YES',
        'APPLICATION_EXTENSION_API_ONLY':'YES', 'SWIFT_VERSION':'5.0',
        'MARKETING_VERSION':app_settings.get('MARKETING_VERSION','1.2.0'),
        'CURRENT_PROJECT_VERSION':app_settings.get('CURRENT_PROJECT_VERSION','3'),
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS':'$(inherited) TASKFOLD_SHARE_EXTENSION',
        'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/../Frameworks @executable_path/../../../../Frameworks' if mac else '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks',
    }
    if mac: settings['ENABLE_HARDENED_RUNTIME']='YES'
    else:
        settings['TARGETED_DEVICE_FAMILY']='1,2'
        settings['SUPPORTED_PLATFORMS']='iphoneos iphonesimulator'
        settings['IPHONEOS_DEPLOYMENT_TARGET']=app_settings.get('IPHONEOS_DEPLOYMENT_TARGET',project_settings.get('IPHONEOS_DEPLOYMENT_TARGET','18.0'))
    add(config, 'isa = XCBuildConfiguration; name = ' + name + '; buildSettings = { ' + ' '.join(f'{key} = {json.dumps(str(value))};' for key,value in settings.items()) + ' };')
add(config_list, 'isa = XCConfigurationList; buildConfigurations = (' + ','.join(configs) + ',); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
add(target, f'isa = PBXNativeTarget; buildConfigurationList = {config_list}; buildPhases = ({phase},{framework},); buildRules = (); dependencies = (); name = TaskfoldShare; productName = TaskfoldShare; productReference = {product}; productType = "com.apple.product-type.app-extension";')
proxy=uid('proxy'); dep=uid('dependency'); embed=uid('embed'); embed_build=uid('embed-build')
add(proxy, f'isa = PBXContainerItemProxy; containerPortal = {project_id}; proxyType = 1; remoteGlobalIDString = {target}; remoteInfo = TaskfoldShare;')
add(dep, f'isa = PBXTargetDependency; target = {target}; targetProxy = {proxy};')
add(embed_build, f'isa = PBXBuildFile; fileRef = {product}; settings = {{ ATTRIBUTES = (RemoveHeadersOnCopy,); }};')
add(embed, f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = ({embed_build},); name = "Embed Share Extension"; runOnlyForDeploymentPostprocessing = 0;')
append(app_id, 'buildPhases', embed); append(app_id, 'dependencies', dep); append(project_id, 'targets', target)
append(proj['productRefGroup'], 'children', product)
group=uid('group'); add(group, f'isa = PBXGroup; children = ({refs[0]},{info},{ent},); name = TaskfoldShare; sourceTree = "<group>";'); append(proj['mainGroup'], 'children', group)
source = source.replace('}; rootObject', '\n' + '\n'.join(lines) + '\n}; rootObject', 1)
project.write_text(source)
subprocess.run(['plutil','-lint',str(project)],check=True,stdout=subprocess.DEVNULL)
