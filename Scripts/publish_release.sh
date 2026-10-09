#!/bin/zsh
# Publish a new immutable version after its app/DMG have been verified.
# Usage: Scripts/publish_release.sh <release-notes-file> <verified-dmg> [--legacy-without-widgets]
set -euo pipefail
cd "$(dirname "$0")/.."
notes="${1:?Supply a reviewed release-notes file}"
[ -z "$(git status --porcelain)" ] || { echo "Commit the verified sources before publishing."; exit 1; }
dmg="${2:?Supply the exact verified DMG path}"
mode="developer-id"
case "${3:-}" in
  "") ;;
  --legacy-without-widgets) mode="distribution" ;;
  *) echo "Unknown release mode" >&2; exit 2 ;;
esac
[ "$#" -le 3 ] || { echo "Unexpected arguments" >&2; exit 2; }
[ -f "$notes" ] || { echo "Release notes do not exist" >&2; exit 1; }
version="$(python3 Scripts/release_artifact.py verify "$dmg" --mode "$mode" --inputs "$(python3 Scripts/release_inputs.py)")"
# A previous version must never be silently retagged or replaced.
tag="v$version"
if git rev-parse "$tag" >/dev/null 2>&1 || gh release view "$tag" >/dev/null 2>&1; then
  echo "$tag already exists; bump the version for a new release."; exit 1
fi
git tag "$tag"
git push origin "$tag"
gh release create "$tag" "$dmg" --verify-tag --title "Taskfold for macOS $version" --notes-file "$notes" --latest
