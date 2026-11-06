# Standard SwiftUI table warning reproducer

The native Taskfold warning stack is retained in `runtime-warning-attribution/table-reentry-native-stack.json`. A standalone app using only standard SwiftUI `NavigationSplitView`, `List` and `Text` reproduces the same warning on macOS 26.6.2 (25G83), built with SDK 27.0. It uses only numbered synthetic tasks. It contains no Taskfold store, account, widget, link renderer, scroll restoration or custom table delegate.

From the Mac repository, build into a new directory:

```sh
python3 Scripts/Diagnostics/build_table_layout_probe.py /private/tmp/taskfold-table-probe-new
open -a '/private/tmp/taskfold-table-probe-new/Taskfold Table Layout Probe.app' --stdout /private/tmp/taskfold-table-probe-new.log --stderr /private/tmp/taskfold-table-probe-new.log
```

The builder refuses an existing output directory and does not launch the app. In the launched app, select **All Tasks** in the sidebar. The content changes from 44 to 256 synthetic rows. Inspect the log for:

> WARNING: Application performed a reentrant operation in its NSTableView delegate. This warning will become an assert in the future.

Quit the diagnostic app afterward. Do not replace Taskfold's native list or suppress warnings based solely on this reproduction. It establishes that the warning can occur without Taskfold code; it does not establish that every historic instance has the same cause or remove the future-assert risk. The shipping link-accessibility cycle fix is separate. See `mac-table-reentry-evidence.json` for exact observations, rejected experiments, runtime provenance and data preservation.
