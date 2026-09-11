#!/bin/zsh
# Builds the DMG and publishes (or replaces) the GitHub release for the app's version.
#
#   Scripts/publish_release.sh            # release v<CFBundleShortVersionString>, asset replaced if it exists
#   Scripts/publish_release.sh --latest   # also (re)point the rolling "latest" release at this build
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/make_dmg.sh
DMG="$(ls -t dist/Taskfold-*.dmg | head -1)"
VERSION="$(basename "$DMG" .dmg | sed 's/^Taskfold-//')"
TAG="v$VERSION"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
NOTES="Taskfold for macOS $VERSION.

Download \`$(basename "$DMG")\`, open it, and drag Taskfold onto Applications. The app is signed with an Apple Development identity and not notarized, so the first launch needs right-click ▸ Open.

Requires macOS 15 or later."
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "▸ Replacing asset on existing release $TAG"
  gh release upload "$TAG" "$DMG" --repo "$REPO" --clobber
  gh release edit "$TAG" --repo "$REPO" --notes "$NOTES" --latest
else
  echo "▸ Creating release $TAG"
  git tag -f "$TAG" && git push -f origin "$TAG"
  gh release create "$TAG" "$DMG" --repo "$REPO" --title "Taskfold for macOS $VERSION" --notes "$NOTES" --latest
fi
gh release view "$TAG" --repo "$REPO" --json url,assets -q '.url, (.assets[] | .name + " " + (.size|tostring) + " bytes")'
