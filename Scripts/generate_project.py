#!/usr/bin/env python3
"""Regenerates Taskfold.xcodeproj/project.pbxproj.

The project references the iOS repository's Core files by relative path so both apps compile the
same Models, Store, and Backend sources. Run from the taskfold-mac directory after adding files.
"""
import hashlib, os, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
IOS = "../taskfold-ios/Taskfold"
TEAM = "3UZ4C73FM2"

def uid(name):
    return hashlib.md5(name.encode()).hexdigest()[:24].upper()

app_sources = sorted(str(p.relative_to(ROOT)) for p in (ROOT / "Taskfold").rglob("*.swift"))
app_sources += [f"{IOS}/Core/Models.swift", f"{IOS}/Core/Store.swift", f"{IOS}/Core/Backend.swift"]
app_resources = ["Taskfold/Assets.xcassets", f"{IOS}/Backend.plist", f"{IOS}/TaskfoldIcon.icon"]
test_sources = sorted(str(p.relative_to(ROOT)) for p in (ROOT / "TaskfoldUITests").rglob("*.swift"))
other_files = ["Taskfold/Info.plist", "Taskfold/Taskfold.entitlements"]

def file_type(path):
    if path.endswith(".swift"): return "sourcecode.swift"
    if path.endswith(".xcassets"): return "folder.assetcatalog"
    if path.endswith(".icon"): return "folder.icon"
    if path.endswith(".plist"): return "text.plist.xml"
    if path.endswith(".entitlements"): return "text.plist.entitlements"
    return "text"

lines = ["// !$*UTF8*$!", "{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {"]
refs = {}
def add_ref(path):
    rid = uid("ref:" + path)
    refs[path] = rid
    name = os.path.basename(path)
    extra = f' name = "{name}";' if path.startswith("..") else ""
    lines.append(f'{rid} = {{ isa = PBXFileReference; lastKnownFileType = {file_type(path)};{extra} path = "{path}"; sourceTree = "<group>"; }};')
    return rid
def add_build(path):
    bid = uid("build:" + path)
    lines.append(f"{bid} = {{ isa = PBXBuildFile; fileRef = {refs[path]}; }};")
    return bid

for p in app_sources + app_resources + test_sources + other_files: add_ref(p)
app_source_builds = [add_build(p) for p in app_sources]
app_resource_builds = [add_build(p) for p in app_resources]
test_source_builds = [add_build(p) for p in test_sources]

app_product = uid("product:app"); test_product = uid("product:tests")
lines.append(f'{app_product} = {{ isa = PBXFileReference; explicitFileType = wrapper.application; path = Taskfold.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
lines.append(f'{test_product} = {{ isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = TaskfoldUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};')

def group(name, children, gid=None):
    gid = gid or uid("group:" + name)
    lines.append(f'{gid} = {{ isa = PBXGroup; children = ({",".join(children)},); name = "{name}"; sourceTree = "<group>"; }};')
    return gid

products = group("Products", [app_product, test_product])
shared_core = group("Shared Core (taskfold-ios)", [refs[p] for p in app_sources if p.startswith("..")] + [refs[f"{IOS}/Backend.plist"], refs[f"{IOS}/TaskfoldIcon.icon"]])
views = group("Views", [refs[p] for p in app_sources if p.startswith("Taskfold/Views/")])
app_group = group("Taskfold", [refs[p] for p in app_sources if p.startswith("Taskfold/") and not p.startswith("Taskfold/Views/")] + [views, refs["Taskfold/Assets.xcassets"]] + [refs[p] for p in other_files])
tests_group = group("TaskfoldUITests", [refs[p] for p in test_sources])
main_group = group("Root", [app_group, shared_core, tests_group, products], uid("group:main"))

app_sources_phase = uid("phase:app:sources"); app_res_phase = uid("phase:app:resources"); app_fw_phase = uid("phase:app:frameworks")
test_sources_phase = uid("phase:test:sources")
lines.append(f'{app_sources_phase} = {{ isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(app_source_builds)},); runOnlyForDeploymentPostprocessing = 0; }};')
lines.append(f'{app_res_phase} = {{ isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(app_resource_builds)},); runOnlyForDeploymentPostprocessing = 0; }};')
lines.append(f'{app_fw_phase} = {{ isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};')
lines.append(f'{test_sources_phase} = {{ isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(test_source_builds)},); runOnlyForDeploymentPostprocessing = 0; }};')

common = f'SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; SWIFT_VERSION = 5.0; CLANG_ENABLE_MODULES = YES; DEVELOPMENT_TEAM = {TEAM}; CODE_SIGN_STYLE = Automatic; ENABLE_USER_SCRIPT_SANDBOXING = YES; COMBINE_HIDPI_IMAGES = YES; DEAD_CODE_STRIPPING = YES;'
app_common = ('PRODUCT_NAME = Taskfold; PRODUCT_BUNDLE_IDENTIFIER = com.dbakp.taskfold.mac; GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = Taskfold/Info.plist; '
              'CODE_SIGN_ENTITLEMENTS = Taskfold/Taskfold.entitlements; ENABLE_HARDENED_RUNTIME = YES; ASSETCATALOG_COMPILER_APPICON_NAME = TaskfoldIcon; '
              'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor; CURRENT_PROJECT_VERSION = 1; MARKETING_VERSION = 1.0.0; SWIFT_EMIT_LOC_STRINGS = YES; '
              'ENABLE_PREVIEWS = YES; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks"; ')
test_common = 'PRODUCT_NAME = TaskfoldUITests; PRODUCT_BUNDLE_IDENTIFIER = com.dbakp.taskfold.mac.uitests; GENERATE_INFOPLIST_FILE = YES; TEST_TARGET_NAME = Taskfold; '

def config(name, settings):
    cid = uid("config:" + name)
    lines.append(f"{cid} = {{ isa = XCBuildConfiguration; name = {name.split(':')[1]}; buildSettings = {{ {settings} }}; }};")
    return cid
def config_list(name, ids):
    lid = uid("configlist:" + name)
    lines.append(f'{lid} = {{ isa = XCConfigurationList; buildConfigurations = ({",".join(ids)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};')
    return lid

project_configs = config_list("project", [config("project:Debug", common + ' SWIFT_OPTIMIZATION_LEVEL = "-Onone"; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG; DEBUG_INFORMATION_FORMAT = dwarf; ONLY_ACTIVE_ARCH = YES;'),
                                         config("project:Release", common + ' SWIFT_OPTIMIZATION_LEVEL = "-O"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";')])
app_configs = config_list("app", [config("app:Debug", app_common), config("app:Release", app_common)])
test_configs = config_list("test", [config("test:Debug", test_common), config("test:Release", test_common)])

app_target = uid("target:app"); test_target = uid("target:test"); project_id = uid("project")
proxy = uid("proxy"); dependency = uid("dependency")
lines.append(f'{proxy} = {{ isa = PBXContainerItemProxy; containerPortal = {project_id}; proxyType = 1; remoteGlobalIDString = {app_target}; remoteInfo = Taskfold; }};')
lines.append(f'{dependency} = {{ isa = PBXTargetDependency; target = {app_target}; targetProxy = {proxy}; }};')
lines.append(f'{app_target} = {{ isa = PBXNativeTarget; buildConfigurationList = {app_configs}; buildPhases = ({app_sources_phase},{app_fw_phase},{app_res_phase},); buildRules = (); dependencies = (); name = Taskfold; productName = Taskfold; productReference = {app_product}; productType = "com.apple.product-type.application"; }};')
lines.append(f'{test_target} = {{ isa = PBXNativeTarget; buildConfigurationList = {test_configs}; buildPhases = ({test_sources_phase},); buildRules = (); dependencies = ({dependency},); name = TaskfoldUITests; productName = TaskfoldUITests; productReference = {test_product}; productType = "com.apple.product-type.bundle.ui-testing"; }};')
lines.append(f'{project_id} = {{ isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2600; TargetAttributes = {{ {app_target} = {{ DevelopmentTeam = {TEAM}; }}; {test_target} = {{ DevelopmentTeam = {TEAM}; TestTargetID = {app_target}; }}; }}; }}; buildConfigurationList = {project_configs}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base,); mainGroup = {main_group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({app_target},{test_target},); }};')
lines.append(f"}}; rootObject = {project_id}; }}")

out = ROOT / "Taskfold.xcodeproj" / "project.pbxproj"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text("\n".join(lines) + "\n")

scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{app_target}" BuildableName = "Taskfold.app" BlueprintName = "Taskfold" ReferencedContainer = "container:Taskfold.xcodeproj"/>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO" parallelizable = "NO">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{test_target}" BuildableName = "TaskfoldUITests.xctest" BlueprintName = "TaskfoldUITests" ReferencedContainer = "container:Taskfold.xcodeproj"/>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{app_target}" BuildableName = "Taskfold.app" BlueprintName = "Taskfold" ReferencedContainer = "container:Taskfold.xcodeproj"/>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{app_target}" BuildableName = "Taskfold.app" BlueprintName = "Taskfold" ReferencedContainer = "container:Taskfold.xcodeproj"/>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"/>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"/>
</Scheme>
'''
scheme_path = ROOT / "Taskfold.xcodeproj" / "xcshareddata" / "xcschemes" / "Taskfold.xcscheme"
scheme_path.parent.mkdir(parents=True, exist_ok=True)
scheme_path.write_text(scheme)
print(f"wrote {out} with {len(app_sources)} app sources, {len(test_sources)} test sources")
