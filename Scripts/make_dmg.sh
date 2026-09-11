#!/bin/zsh
# Builds Taskfold.app and wraps it in a compressed disk image with an Applications shortcut.
#
#   Scripts/make_dmg.sh                 # distribution build (default): ad hoc signature, no profile, no expiry,
#                                       #   no widget extension; runs on any Mac after Privacy & Security ▸ Open Anyway
#   Scripts/make_dmg.sh --development   # team-signed build with the widget and App Group; runs only on Macs
#                                       #   registered to the team and expires with the seven-day profile
#   TASKFOLD_IOS_ROOT=/path/to/TaskFold-iOS Scripts/make_dmg.sh
#
# Output: dist/Taskfold-<version>.dmg. Developer ID signing and notarization need a paid developer account.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="distribution"; [ "${1:-}" = "--development" ] && MODE="development"
BUILD="${TASKFOLD_DMG_BUILD:-build/dmg-$MODE}"
DIST="dist"
IOS_ROOT="${TASKFOLD_IOS_ROOT:-$(pwd)/../taskfold-ios}"

restore_project() { python3 Scripts/generate_project.py >/dev/null; }
if [ "$MODE" = "distribution" ]; then
  echo "▸ Building Release (distribution: ad hoc signature, no widget extension)"
  TASKFOLD_WIDGETS=0 python3 Scripts/generate_project.py >/dev/null
  trap restore_project EXIT
  xcodebuild -project Taskfold.xcodeproj -scheme Taskfold -configuration Release -derivedDataPath "$BUILD" \
    TASKFOLD_IOS_ROOT="$IOS_ROOT" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO CODE_SIGN_ENTITLEMENTS=Taskfold/Taskfold-Distribution.entitlements \
    build -quiet
else
  echo "▸ Building Release (development: team signature with widget)"
  xcodebuild -project Taskfold.xcodeproj -scheme Taskfold -configuration Release -derivedDataPath "$BUILD" \
    TASKFOLD_IOS_ROOT="$IOS_ROOT" -allowProvisioningUpdates build -quiet
fi
APP="$BUILD/Build/Products/Release/Taskfold.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
codesign --verify --deep --strict "$APP"
if [ "$MODE" = "distribution" ]; then
  [ -e "$APP/Contents/embedded.provisionprofile" ] && { echo "unexpected provisioning profile in distribution build"; exit 1; }
  [ -e "$APP/Contents/PlugIns" ] && { echo "unexpected extension in distribution build"; exit 1; }
fi

echo "▸ Staging"
STAGE="$(mktemp -d)/Taskfold"
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
else
cat > "$STAGE/How to install.txt" <<'TXT'
Drag Taskfold onto the Applications folder. This development build runs only on Macs registered to the team.
TXT
fi

DMG="$DIST/Taskfold-$VERSION.dmg"
rm -f "$DMG"
echo "▸ Creating $DMG"
hdiutil create -volname "Taskfold" -srcfolder "$STAGE" -ov -format UDZO -imagekey zlib-level=9 -fs HFS+ "$DMG" -quiet
if [ "$MODE" = "distribution" ]; then codesign --sign - "$DMG"; else
  IDENTITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Apple Development.*\)$/\1/p' | head -1)"
  [ -n "$IDENTITY" ] && codesign --sign "$IDENTITY" --timestamp=none "$DMG"
fi
hdiutil verify "$DMG" -quiet && echo "▸ Verified"
rm -rf "$(dirname "$STAGE")"
echo "✓ $DMG ($MODE, version $VERSION, build $BUILD_NUMBER, $(du -h "$DMG" | cut -f1))"
