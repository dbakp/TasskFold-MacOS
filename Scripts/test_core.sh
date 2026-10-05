#!/bin/zsh
# Keep test products outside synced Documents folders to avoid signing resource forks.
# Usage: Scripts/test_core.sh [-c release] [additional swift test arguments]
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift test --scratch-path "${TASKFOLD_CORE_BUILD:-$HOME/Library/Caches/TaskfoldBuild/core}" "$@"
