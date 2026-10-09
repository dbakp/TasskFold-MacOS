#!/bin/zsh
# Builds Taskfold.app and wraps it in a compressed disk image with an Applications shortcut.
#
#   Scripts/make_dmg.sh                 # distribution build (default): ad hoc signature, no profile, no expiry,
#                                       #   no widget extension; runs on any Mac after Privacy & Security ▸ Open Anyway
#   Scripts/make_dmg.sh --development   # team-signed build with the widget and App Group; runs only on Macs
#                                       #   registered to the team and expires with its provisioning profile
#   Scripts/make_dmg.sh --developer-id  # archive, export, notarize and package with widgets; see docs/MAC_RELEASE.md
#
# Outputs have separate development/developer-id suffixes. Public signing needs an existing Developer ID identity.
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  "") MODE="distribution" ;;
  --development) MODE="development" ;;
  --developer-id) MODE="developer-id" ;;
  *) echo "Usage: $0 [--development|--developer-id]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "Unexpected arguments" >&2; exit 2; }
if [ "$MODE" = "developer-id" ]; then
  : "${TASKFOLD_EXPORT_OPTIONS:?Supply the reviewed Developer ID ExportOptions.plist}"
  : "${TASKFOLD_NOTARY_PROFILE:?Supply an existing notarytool Keychain profile name}"
  python3 - "$TASKFOLD_EXPORT_OPTIONS" <<'PYOPTIONS'
import plistlib, subprocess, sys
with open(sys.argv[1], 'rb') as f: options = plistlib.load(f)
if options.get('method') != 'developer-id' or options.get('signingStyle') != 'manual':
    raise SystemExit('Export must use developer-id and existing manual signing inputs')
if not options.get('teamID') or not all(options.get('provisioningProfiles', {}).get(key) for key in ('com.dbakp.taskfold.mac', 'com.dbakp.taskfold.mac.widgets')):
    raise SystemExit('Supply the team and existing app/widget provisioning profiles')
identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
if '"Developer ID Application:' not in identities:
    raise SystemExit('No valid Developer ID Application identity installed; no build started')
PYOPTIONS
fi
BUILD="${TASKFOLD_DMG_BUILD:-$HOME/Library/Caches/TaskfoldBuild/dmg-$MODE}"
DIST="dist"
INPUTS="$(python3 Scripts/release_inputs.py)"

PROJECT_BACKUP=""; STAGE_ROOT=""
cleanup() {
  if [ -n "$PROJECT_BACKUP" ]; then
    cp "$PROJECT_BACKUP/project.pbxproj" Taskfold.xcodeproj/project.pbxproj
    cp "$PROJECT_BACKUP/Taskfold.xcscheme" Taskfold.xcodeproj/xcshareddata/xcschemes/Taskfold.xcscheme
    rm -rf "$PROJECT_BACKUP"
  fi
  [ -z "$STAGE_ROOT" ] || rm -rf "$STAGE_ROOT"
}
trap cleanup EXIT
notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$TASKFOLD_NOTARY_PROFILE" --wait --output-format json > "$2"
  python3 - "$2" <<'PYNOTARY'
import json, sys
with open(sys.argv[1]) as f: result = json.load(f)
if result.get('status') != 'Accepted': raise SystemExit('Notarization not accepted; inspect ' + sys.argv[1])
PYNOTARY
}
PROJECT_BACKUP="$(mktemp -d)"
cp Taskfold.xcodeproj/project.pbxproj "$PROJECT_BACKUP/project.pbxproj"
cp Taskfold.xcodeproj/xcshareddata/xcschemes/Taskfold.xcscheme "$PROJECT_BACKUP/Taskfold.xcscheme"
if [ "$MODE" != "distribution" ]; then
  TASKFOLD_WIDGETS=1 python3 Scripts/generate_project.py >/dev/null
fi
if [ "$MODE" = "distribution" ]; then
  echo "▸ Building Release (distribution: ad hoc signature, no widget extension)"
  TASKFOLD_WIDGETS=0 python3 Scripts/generate_project.py >/dev/null
  xcodebuild -project Taskfold.xcodeproj -scheme Taskfold -configuration Release -derivedDataPath "$BUILD" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO CODE_SIGN_ENTITLEMENTS=Taskfold/Taskfold-Distribution.entitlements \
    -jobs 2 build -quiet
elif [ "$MODE" = "development" ]; then
  echo "▸ Building Release (development: team signature with widget)"
  xcodebuild -project Taskfold.xcodeproj -scheme Taskfold -configuration Release -derivedDataPath "$BUILD" \
    -jobs 2 -allowProvisioningUpdates build -quiet
else
  echo "▸ Archiving and exporting Developer ID app with widgets"
  xcodebuild -project Taskfold.xcodeproj -scheme Taskfold -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$BUILD" -archivePath "$BUILD/Taskfold.xcarchive" -jobs 2 archive -quiet
  xcodebuild -exportArchive -archivePath "$BUILD/Taskfold.xcarchive" -exportPath "$BUILD/export" \
    -exportOptionsPlist "$TASKFOLD_EXPORT_OPTIONS" -quiet
fi
APP="$BUILD/Build/Products/Release/Taskfold.app"
if [ "$MODE" = "developer-id" ]; then
  APP="$BUILD/export/Taskfold.app"
  python3 Scripts/release_artifact.py check-app "$APP" --mode developer-id --inputs "$INPUTS" >/dev/null
  ditto -c -k --keepParent "$APP" "$BUILD/notarize.zip"
  notarize "$BUILD/notarize.zip" "$BUILD/app-notarization.json"
  xcrun stapler staple "$APP"
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
codesign --verify --deep --strict "$APP"
if [ "$MODE" = "distribution" ]; then
  [ -e "$APP/Contents/embedded.provisionprofile" ] && { echo "unexpected provisioning profile in distribution build"; exit 1; }
  [ -e "$APP/Contents/PlugIns" ] && { echo "unexpected extension in distribution build"; exit 1; }
fi

echo "▸ Staging"
STAGE_ROOT="$(mktemp -d)"
STAGE="$STAGE_ROOT/Taskfold"
mkdir -p "$STAGE" "$DIST"
cp -R "$APP" "$STAGE/Taskfold.app"
ln -s /Applications "$STAGE/Applications"
if [ "$MODE" = "distribution" ]; then
cat > "$STAGE/How to install.txt" <<'TXT'
1. Drag Taskfold onto the Applications folder.
2. Open Taskfold from Applications. macOS will say it could not verify the app.
3. Open System Settings ▸ Privacy & Security, scroll to Security, and click "Open Anyway", then confirm.

This happens once. The app is signed but not notarized with Apple, which needs a paid developer account.
TXT
elif [ "$MODE" = "development" ]; then
cat > "$STAGE/How to install.txt" <<'TXT'
Drag Taskfold onto the Applications folder. This development build runs only on Macs registered to the team.
TXT
else
  printf '%s\n' 'Drag Taskfold onto the Applications folder. Widgets are included.' > "$STAGE/How to install.txt"
fi

SUFFIX=""; [ "$MODE" != "distribution" ] && SUFFIX="-$MODE"
DMG="$DIST/Taskfold-$VERSION$SUFFIX.dmg"
[ ! -e "$DMG" ] || { echo "Artifact already exists: $DMG; move it explicitly before rebuilding."; exit 1; }
echo "▸ Creating $DMG"
hdiutil create -volname "Taskfold" -srcfolder "$STAGE" -ov -format UDZO -imagekey zlib-level=9 -fs HFS+ "$DMG" -quiet
if [ "$MODE" = "distribution" ]; then codesign --sign - "$DMG"; else
  IDENTITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Apple Development.*\)$/\1/p; s/^Authority=\(Developer ID Application.*\)$/\1/p' | head -1)"
  [ -n "$IDENTITY" ] || { echo "Missing signing authority"; exit 1; }
  if [ "$MODE" = "developer-id" ]; then
    codesign --sign "$IDENTITY" --timestamp "$DMG"
    notarize "$DMG" "$BUILD/dmg-notarization.json"
    xcrun stapler staple "$DMG"
  else
    codesign --sign "$IDENTITY" --timestamp=none "$DMG"
  fi
fi
hdiutil verify "$DMG" -quiet && echo "▸ Verified"

[ "$INPUTS" = "$(python3 Scripts/release_inputs.py)" ] || { echo "Sources changed during the build; rebuild before publishing."; exit 1; }
python3 Scripts/release_artifact.py record "$DMG" --mode "$MODE" --inputs "$INPUTS" >/dev/null
echo "✓ $DMG ($MODE, version $VERSION, build $BUILD_NUMBER, $(du -h "$DMG" | cut -f1))"
