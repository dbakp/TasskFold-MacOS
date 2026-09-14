#!/bin/zsh
# Resolve the exact, clean shared dependency used by this release. Prints its absolute path.
set -euo pipefail
cd "$(dirname "$0")/.."
revision="$(cat SharedCoreRevision)"
source_dir="${TASKFOLD_IOS_ROOT:-$PWD/build/shared-ios}"
if [ ! -d "$source_dir" ]; then
  git clone --no-checkout https://github.com/dbakp/TaskFold-iOS.git "$source_dir" >&2
  git -C "$source_dir" checkout --detach "$revision" >&2
fi
actual="$(git -C "$source_dir" rev-parse HEAD)"
if [ "$actual" != "$revision" ]; then
  echo "Shared Core mismatch: expected $revision, found $actual at $source_dir. Use a clean checkout at the pinned revision." >&2
  exit 1
fi
if [ -n "$(git -C "$source_dir" status --porcelain --untracked-files=normal)" ]; then
  echo "Shared Core checkout has local changes. Preserve them and choose a clean TASKFOLD_IOS_ROOT." >&2
  exit 1
fi
(cd "$source_dir" && pwd)
