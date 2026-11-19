#!/bin/zsh
# Usage: Scripts/capture.sh <isolated Taskfold.app> <output.png> [launch arguments...]
#
# Images one window of an isolated Debug build and copies the PNG out of its sandbox.
# - Build the app from a workspace made by Scripts/prepare_isolated_mac_ui.py: it has its own bundle ID,
#   container, defaults and Keychain, so a capture never touches your installed Taskfold or its data.
#   The production bundle (com.dbakp.taskfold.mac) is refused.
# - The app opens as a new instance (`open -n`) and is quit only by its own PID. No other copy of Taskfold
#   is touched, so this is safe while you are using the app.
# - The widget setup banner is left as people see it. Pass --hide-setup-banner yourself only for a capture
#   that must omit it, and say so wherever the image is shown.
#
# Example: Scripts/capture.sh /tmp/tf-iso/DerivedData/Build/Products/Debug/Taskfold.app week.png \
#            --preview --section=calendar --calendar-mode=week --appearance=dark
set -euo pipefail
if (( $# < 2 )); then sed -n '2,13p' "$0" >&2; exit 64; fi
APP="${1%/}"; OUT="$2"; shift 2
PLIST="$APP/Contents/Info.plist"
[[ -f "$PLIST" ]] || { echo "Not an app bundle: $APP" >&2; exit 66; }
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")
EXEC=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")
if [[ "$BUNDLE" == "com.dbakp.taskfold.mac" ]]; then
  echo "Refusing to capture the production bundle ($BUNDLE). Use an isolated build from Scripts/prepare_isolated_mac_ui.py." >&2
  exit 65
fi
BINARY="$(cd "$APP" && pwd -P)/Contents/MacOS/$EXEC"
NAME="capture-$$.png"
SOURCE="$HOME/Library/Containers/$BUNDLE/Data/tmp/$NAME"

# Only PIDs running this exact binary are candidates; the new instance is the one that was not running before.
before=(${(f)"$(pgrep -f -x "$BINARY.*" || true)"})
open -n "$APP" --args "$@" "--capture=$NAME"
PID=""
for _ in {1..50}; do
  for candidate in ${(f)"$(pgrep -f -x "$BINARY.*" || true)"}; do
    [[ -n "$candidate" && ${before[(Ie)$candidate]} -eq 0 ]] && PID="$candidate"
  done
  [[ -n "$PID" ]] && break
  sleep 0.2
done
[[ -n "$PID" ]] || { echo "The isolated app did not start." >&2; exit 70; }

# The capture fixture writes the PNG and quits itself; stop this instance by PID if it is still running after that.
for _ in {1..150}; do
  [[ -f "$SOURCE" ]] && break
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.2
done
sleep 0.5
for _ in {1..25}; do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$PID" 2>/dev/null; then kill -TERM "$PID"; fi

# Reading another app's container needs the terminal to be allowed to access data from other apps
# (System Settings ▸ Privacy & Security). Without it the copy fails here rather than reporting success.
if ! cp "$SOURCE" "$OUT" 2>/dev/null; then
  echo "Could not copy $SOURCE. Allow this terminal to access data from other apps, or capture from a UI test instead." >&2
  exit 77
fi
rm -f "$SOURCE"
echo "captured $OUT"
