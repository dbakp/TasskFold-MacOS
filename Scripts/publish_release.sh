#!/bin/zsh
# Publish a new immutable version after its app/DMG have been verified.
# Usage: Scripts/publish_release.sh <release-notes-file>
set -euo pipefail
cd "$(dirname "$0")/.."
notes="${1:?Supply a reviewed release-notes file}"
[ -z "$(git status --porcelain)" ] || { echo "Commit the verified sources before publishing."; exit 1; }
Scripts/prepare_shared_core.sh >/dev/null
app="${TASKFOLD_DMG_BUILD:-$HOME/Library/Caches/TaskfoldBuild/dmg-distribution}/Build/Products/Release/Taskfold.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
dmg="dist/Taskfold-$version.dmg"
[ "$(cat "$dmg.inputs")" = "$(python3 Scripts/release_inputs.py)" ] || { echo "Release inputs changed; rebuild the DMG."; exit 1; }
codesign --verify --deep --strict "$app"
hdiutil verify "$dmg" -quiet
# A previous version must never be silently retagged or replaced.
tag="v$version"
if git rev-parse "$tag" >/dev/null 2>&1 || gh release view "$tag" >/dev/null 2>&1; then
  echo "$tag already exists; bump the version for a new release."; exit 1
fi
git tag "$tag"
git push origin "$tag"
gh release create "$tag" "$dmg" --verify-tag --title "Taskfold for macOS $version" --notes-file "$notes" --latest
