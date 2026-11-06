#!/usr/bin/env python3
"""Build the ordinary app for personal daily use; never installs or publishes it."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import platform
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
PLATFORM = "mac"
BUNDLE = "com.dbakp.taskfold.mac"


def fingerprint(project_bytes):
    digest = hashlib.sha256(project_bytes)
    for directory in ("Taskfold", "TaskfoldWidgets", "TaskfoldShare", "TaskfoldWatch"):
        for file in sorted((ROOT / directory).rglob("*")):
            if file.is_file():
                digest.update(str(file.relative_to(ROOT)).encode() + b"\0")
                digest.update(file.read_bytes())
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=Path, default=Path.home() / "Library/Caches/TaskfoldBuild" / ("daily-" + PLATFORM))
    parser.add_argument("--products-directory", type=Path, help="Choose the products folder while reusing the build cache; stop apps running from that cache first")
    parser.add_argument("--cached-profiles", action="store_true", help="Use only existing unexpired development profiles and local signing identities; no account/network provisioning")
    parser.add_argument("--allow-provisioning", action="store_true", help="Let Xcode update development profiles using its configured account")
    parser.add_argument("--team", help="Existing development team for the app and all extensions; defaults to the project's sole configured team")
    parser.add_argument("--build-number", type=int, help="Increment the app/extension build number together for a new daily update")
    parser.add_argument("--configuration", choices=("Release", "Debug"), default="Release", help="Optimized daily-use build by default; Debug is available explicitly for diagnostics")
    parser.add_argument("--simulator", action="store_true", help="iOS only: build an unsigned Simulator app")
    parser.add_argument("--device", help="iOS only: build for an already registered device identifier")
    args = parser.parse_args()
    if args.cached_profiles and (args.allow_provisioning or args.simulator):
        parser.error("Cached development profiles cannot be combined with network provisioning or Simulator signing")
    if PLATFORM == "mac" and (args.simulator or args.device) or args.simulator and args.device:
        parser.error("Choose a destination supported by this owning app")
    if args.build_number is not None and args.build_number < 1:
        parser.error("Build number must be a positive integer")
    # Xcode may retire earlier managed products even when a new products folder
    # is chosen. Never rebuild a cache whose app executable is still running.
    cache = str(args.derived_data.resolve()) + "/"
    running = subprocess.check_output(["ps", "-axo", "comm="], text=True).splitlines()
    if any(line.strip().startswith(cache) and ".app/" in line for line in running):
        raise SystemExit("Quit the app running from this build cache first. Installed apps can remain open.")
    probe = args.derived_data
    while not probe.exists():
        probe = probe.parent
    subprocess.run(["python3", "Scripts/check_test_storage.py", "--path", str(probe)], cwd=ROOT, check=True)
    project = ROOT / "Taskfold.xcodeproj/project.pbxproj"
    original = project.read_bytes()
    normal = b"CODE_SIGN_ENTITLEMENTS = Taskfold/Taskfold.entitlements;"
    daily = b"CODE_SIGN_ENTITLEMENTS = Taskfold/Taskfold-Daily.entitlements;"
    if original.count(normal) != 2 or original.count(b'projectDirPath = "";') != 1:
        raise SystemExit("Expected the ordinary app's two configurations; project left unchanged")
    before = fingerprint(original)
    teams = set(re.findall(rb'\bDEVELOPMENT_TEAM = ([A-Z0-9]{10});', original))
    if not args.team and len(teams) > 1:
        parser.error("Choose --team explicitly when the project contains several teams")
    team = args.team or (next(iter(teams)).decode() if teams else None)
    destination = "platform=macOS" if PLATFORM == "mac" else ("generic/platform=iOS Simulator" if args.simulator else ("id=" + args.device if args.device else "generic/platform=iOS"))
    args.derived_data.mkdir(parents=True, exist_ok=True)
    channel = PLATFORM + ("-simulator" if args.simulator else "-device" if PLATFORM == "ios" else "")
    receipt = args.derived_data / ("taskfold-daily-" + channel + ".json")
    # Never leave a previous successful receipt beside a failed new candidate.
    receipt.unlink(missing_ok=True)
    # Copy only project metadata. Sources/resources stay in this owning checkout;
    # normal project and release entitlement settings are never edited.
    daily_project = args.derived_data / "DailyProject/Taskfold.xcodeproj"
    shutil.copytree(project.parent, daily_project, dirs_exist_ok=True, ignore=shutil.ignore_patterns("xcuserdata"))
    configured = original.replace(normal, daily).replace(b'projectDirPath = "";', ('projectDirPath = ' + json.dumps(str(ROOT)) + ';').encode())
    (daily_project / "project.pbxproj").write_bytes(configured)
    cached_signing = None
    if args.cached_profiles:
        from cached_development_signing import configure_cached_profiles
        cached_signing = configure_cached_profiles(daily_project / "project.pbxproj", platform=PLATFORM, team=team, app_bundle=BUNDLE, include_share=True, device=args.device)
    # The relocated project uses the checkout as SOURCE_ROOT. Bind its scheme
    # references explicitly so Xcode cannot resolve them to the ordinary project.
    for scheme in (daily_project / "xcshareddata/xcschemes").glob("*.xcscheme"):
        tree = ET.parse(scheme)
        for reference in tree.iter("BuildableReference"):
            reference.set("ReferencedContainer", "container:" + str(daily_project.resolve()))
        tree.write(scheme, encoding="utf-8", xml_declaration=True)
    log = args.derived_data / ("taskfold-daily-" + channel + ".log")
    command = ["xcodebuild", "-project", str(daily_project.resolve()), "-scheme", "Taskfold", "-configuration", args.configuration, "-destination", destination, "-derivedDataPath", str(args.derived_data.resolve()), "-jobs", "1", "COMPILER_INDEX_STORE_ENABLE=NO", "OTHER_SWIFT_FLAGS=$(inherited) -driver-batch-count 2 -j 1", "build"]
    if PLATFORM == "mac":
        command.extend(["ONLY_ACTIVE_ARCH=YES", "ARCHS=" + platform.machine()])
    if args.products_directory:
        command.append("CONFIGURATION_BUILD_DIR=" + str(args.products_directory.resolve()))
    if args.allow_provisioning:
        command.append("-allowProvisioningUpdates")
    if team:
        command.append("DEVELOPMENT_TEAM=" + team)
    if args.build_number is not None:
        command.append("CURRENT_PROJECT_VERSION=" + str(args.build_number))
    if args.simulator:
        command.extend(["CODE_SIGNING_ALLOWED=NO", "ONLY_ACTIVE_ARCH=YES", "ARCHS=" + platform.machine()])
    with log.open("w") as output:
        result = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        errors = [line for line in log.read_text().splitlines() if ": error:" in line or line.startswith("xcodebuild: error:")]
        raise SystemExit("Daily build failed. See " + str(log) + "\n" + "\n".join(errors[-6:]))
    if fingerprint(project.read_bytes()) != before:
        raise SystemExit("App inputs changed during the build; no candidate receipt recorded")
    products = args.derived_data / "Build/Products" / (args.configuration + ("" if PLATFORM == "mac" else "-iphonesimulator" if args.simulator else "-iphoneos"))
    if args.products_directory:
        products = args.products_directory.resolve()
    app = products / "Taskfold.app"
    contents = app / "Contents" if PLATFORM == "mac" else app
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != BUNDLE:
        raise SystemExit("Unexpected app identity; no daily-use candidate recorded")
    plugins = contents / "PlugIns"
    for name in ("TaskfoldWidgets.appex", "TaskfoldShare.appex"):
        if not (plugins / name).is_dir():
            raise SystemExit("Missing extension: " + name)
    subprocess.run(["python3", "Scripts/verify_continuity_release.py", "--app", str(app)], cwd=ROOT, check=True)
    if not args.simulator:
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        entitlements = plistlib.loads(subprocess.check_output(["codesign", "-d", "--entitlements", ":-", str(app)], stderr=subprocess.DEVNULL))
        if any(key in entitlements for key in ("aps-environment", "com.apple.developer.aps-environment", "com.apple.developer.usernotifications.time-sensitive")):
            raise SystemExit("Daily candidate unexpectedly requests deferred notification capabilities")
    data = {"schema": 1, "configuration": args.configuration, "platform": PLATFORM, "bundle": BUNDLE, "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"], "app": str(app.resolve()), "sourceFingerprint": before, "sourceRevision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(), "simulatorOnly": args.simulator, "signatureVerified": not args.simulator, "widgetsIncluded": True, "shareIncluded": True, "omittedCapabilities": ["Remote push notifications", "Time Sensitive notifications"], "featureFlags": {key: value for key, value in info.items() if key.startswith("Taskfold") and key.endswith("Enabled")}, "installed": False, "published": False}
    if cached_signing is not None:
        from cached_development_signing import verify_cached_profile_products
        verify_cached_profile_products(app, PLATFORM, cached_signing)
        data["cachedProfileSigning"] = cached_signing
        data["buildToolsSHA256"] = {name: hashlib.sha256((ROOT / "Scripts" / name).read_bytes()).hexdigest() for name in ["build_daily.py", "cached_development_signing.py"]}
    receipt.write_text(json.dumps(data, indent=2) + "\n")
    print("Daily-use development candidate: " + str(app))
    print("Build receipt: " + str(receipt))
    # Preserve the verified product and receipt; bound completed compiler scratch.
    subprocess.run(["python3", "Scripts/finish_test_run.py", "--apply", "--build-cache", str(args.derived_data)], cwd=ROOT, check=True)


if __name__ == "__main__":
    main()
