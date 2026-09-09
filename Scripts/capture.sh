#!/bin/zsh
# Usage: Scripts/capture.sh <output.png> [launch arguments...]
# Launches the Debug build with the given arguments, images the main window, and copies the PNG out of the sandbox.
set -e
OUT="$1"; shift
APP="$(dirname "$0")/../DerivedData/Build/Products/Debug/Taskfold.app"
NAME="capture-$$.png"
pkill -x Taskfold 2>/dev/null || true; sleep 0.3
"$APP/Contents/MacOS/Taskfold" "$@" "--capture=$NAME" >/dev/null 2>&1 || true
cp "$HOME/Library/Containers/com.dbakp.taskfold.mac/Data/tmp/$NAME" "$OUT" && rm -f "$HOME/Library/Containers/com.dbakp.taskfold.mac/Data/tmp/$NAME"
echo "captured $OUT"
