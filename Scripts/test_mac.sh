#!/bin/zsh
# Match the distributed app's widget-free entitlements while retaining Debug fixtures.
# Usage: Scripts/test_mac.sh [test|build-for-testing] [additional xcodebuild arguments]
set -euo pipefail
cd "$(dirname "$0")/.."
shared="$(Scripts/prepare_shared_core.sh)"
action="${1:-test}"
[ "$#" -gt 0 ] && shift
restore_project() { python3 Scripts/generate_project.py >/dev/null; }
TASKFOLD_WIDGETS=0 python3 Scripts/generate_project.py >/dev/null
trap restore_project EXIT
xcodebuild -project Taskfold.xcodeproj -scheme Taskfold -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "${TASKFOLD_TEST_BUILD:-$HOME/Library/Caches/TaskfoldBuild/tests}" \
  TASKFOLD_IOS_ROOT="$shared" CODE_SIGN_ENTITLEMENTS=Taskfold/Taskfold-Distribution.entitlements \
  -allowProvisioningUpdates "$action" "$@"
