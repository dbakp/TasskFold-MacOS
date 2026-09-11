#!/bin/zsh
# Builds a Release Taskfold.app and wraps it in a compressed, signed disk image with an Applications shortcut.
#
#   Scripts/make_dmg.sh                       # uses ../taskfold-ios for the shared Core
#   TASKFOLD_IOS_ROOT=/path/to/TaskFold-iOS Scripts/make_dmg.sh
#
# Output: dist/Taskfold-<version>.dmg. The app is signed with the team's Apple Development identity, so on
# another Mac Gatekeeper asks for a right-click ▸ Open the first time; Developer ID signing and notarization
# need a paid developer account and are not part of this script.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${TASKFOLD_DMG_BUILD:-build/dmg}"
DIST="dist"
IOS_ROOT="${TASKFOLD_IOS_ROOT:-$(pwd)/../taskfold-ios}"

echo "▸ Building Release"
xcodebuild -project Taskfold.xcodeproj -scheme Taskfold -configuration Release -derivedDataPath "$BUILD" \
  TASKFOLD_IOS_ROOT="$IOS_ROOT" -allowProvisioningUpdates build -quiet
APP="$BUILD/Build/Products/Release/Taskfold.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
codesign --verify --deep --strict "$APP"

echo "▸ Staging"
STAGE="$(mktemp -d)/Taskfold"
mkdir -p "$STAGE" "$DIST"
cp -R "$APP" "$STAGE/Taskfold.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/.background-readme.txt" <<'TXT'
Drag Taskfold onto the Applications folder to install it.
First launch on another Mac: right-click Taskfold ▸ Open (the app is signed for development, not notarized).
TXT
chflags hidden "$STAGE/.background-readme.txt"

DMG="$DIST/Taskfold-$VERSION.dmg"
rm -f "$DMG"
echo "▸ Creating $DMG"
hdiutil create -volname "Taskfold" -srcfolder "$STAGE" -ov -format UDZO -imagekey zlib-level=9 -fs HFS+ "$DMG" -quiet
IDENTITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Apple Development.*\)$/\1/p' | head -1)"
if [ -n "$IDENTITY" ]; then codesign --sign "$IDENTITY" --timestamp=none "$DMG" && echo "▸ Signed image with $IDENTITY"; fi
hdiutil verify "$DMG" -quiet && echo "▸ Verified"
rm -rf "$(dirname "$STAGE")"
echo "✓ $DMG (version $VERSION, build $BUILD_NUMBER, $(du -h "$DMG" | cut -f1))"
