#!/bin/bash
# Own reusable Core products stay outside synced Documents and apart from other platforms.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Scripts/check_test_storage.py --path /tmp
exec swift test --scratch-path "${TASKFOLD_CORE_BUILD:-$HOME/Library/Caches/TaskfoldBuild/core-mac}" "$@"
