# Taskfold for macOS

A native SwiftUI Mac app for Taskfold, built to feel like a first-class Mac citizen rather than a scaled-up phone app. It shares its data layer with [dbakp/taskfold-ios](https://github.com/dbakp/taskfold-ios): the `Core` sources (`Models.swift`, `Store.swift`, `Backend.swift`) and `Backend.plist` are referenced from that checkout, not copied, so backend access, the durable sync queue, undo history, recurrence, day placement, and quick entry stay identical across platforms.

## Layout

```
TaskFold-Mac/
├── taskfold-ios/      # git clone https://github.com/dbakp/taskfold-ios (source of truth for Core)
├── taskfold/          # git clone https://github.com/dbakp/taskfold (web app, layout reference)
└── taskfold-mac/      # this repository
```

Clone the iOS repository next to this one before opening the project. `Taskfold.xcodeproj` references `../taskfold-ios/Taskfold/Core/*.swift`, `../taskfold-ios/Taskfold/Backend.plist`, and the shared `TaskfoldIcon.icon`.

## Run

```sh
xcodebuild -project Taskfold.xcodeproj -scheme Taskfold -configuration Debug -derivedDataPath DerivedData -allowProvisioningUpdates build
open DerivedData/Build/Products/Debug/Taskfold.app
```

Requires Xcode 26 and macOS 15. Signing uses the personal team `3UZ4C73FM2` with automatic provisioning; the app is sandboxed with network client, user-selected files, and a keychain access group.

Sign in with email/password or Google (`ASWebAuthenticationSession` with PKCE, callback `taskfold://auth/callback`), or choose **Use on this Mac without an account** for a local workspace.

## What is here

- **NavigationSplitView** with a sidebar (Today, Inbox, Upcoming, Calendar, Browse ▸ All Tasks / Completed, Projects, Labels), a content list, and a trailing **inspector** that edits the selected task in place and saves as you go. No sheets for editing.
- **Keyboard**: arrow keys move selection, Space completes, Return edits (focuses the inspector title), Esc clears selection, ⌫ deletes, ⌘N new task (focuses the quick-add field, which understands the shared quick-entry grammar), ⇧⌘N new project, ⌘Z / ⇧⌘Z undo and redo through the system undo manager, ⌘F search, ⌘1…⌘5 sidebar sections, ⌥⌘I inspector, ⌘R sync. Every shortcut has a menu bar item.
- **Multi-select** with shift/⌘-click, right-click context menus for one or many tasks, and a **Task** menu with reschedule, move, priority, duplicate, and delete.
- **Drag and drop** with macOS drag sessions and a real drag image (title, priority ring, count badge for multi-drags). Drop between days, onto day headers, onto empty days, onto sidebar items (Today, Upcoming, Inbox, any project), and onto calendar days. Reordering within a day preserves the iOS `DayPlacement` semantics and is one undoable change. Trackpad feedback marks slot changes and drops.
- **Undo affordance**: a brief, non-blocking confirmation strip at the foot of the list ("Completed “…” · Undo ⌘Z") in addition to Edit ▸ Undo.
- **Calendar** with 3-day, 5-day, week, month, and year modes laid out for a wide window: day columns or a month grid with equal-height weeks (overflow collapses into "+n more"), and the selected day's tasks in a side panel that appears when the window is wide enough for it. Tasks open in the inspector; ← / → move between periods; ⌘T jumps to today.
- **Layout**: task lists read in a centered column (max 860 pt) the way Todoist lays out its lists; the search field sits in the sidebar as in Mail and Notes.
- **Motion**: `Views/Motion.swift` keeps the iOS spring vocabulary (layout, quick, lift, settle, track) tuned shorter and subtler for the Mac; `Views/Transitions.swift` translates the [transitions.dev](https://transitions.dev) token scale (durations, easings, distances, scales, blur) into SwiftUI recipes: text-state swap, icon swap, toast open/close, panel reveal, notification-badge pop, number pop-in, stroke-drawn success check, error-state shake, skeleton reveal, shimmer text, sliding tabs, and the hover-in/hover-out asymmetry. All respect Reduce Motion.
- Light and dark mode, system text scaling, VoiceOver labels, pointer cursors, hover states, resizable columns, window state restoration, a unified toolbar with the search field, a Settings window (⌘,), notifications for due tasks, collaborators, invitations, and Todoist import.

## Tests

The shared Core tests live in the iOS repository:

```sh
cd ../taskfold-ios && swift test
```

macOS UI tests cover keyboard completion with undo and a day-to-day drag:

```sh
xcodebuild -project Taskfold.xcodeproj -scheme Taskfold -derivedDataPath DerivedData -allowProvisioningUpdates test
```

UI testing on macOS asks once for Accessibility permission for the test runner. Passing `TEST_RUNNER_TASKFOLD_SCREENSHOTS=1` to `xcodebuild test` also renders the report screenshots (see `Screenshots/`) into the runner's temporary directory; the path is printed in the log.

Two macOS specifics worth knowing: rows use `itemProvider` (the table's own dragging) rather than `onDrag`, because a SwiftUI drag gesture on a List row swallows the click that selects it; and Space / Return / Escape are routed by `Views/KeyRouter.swift`, a local key-event monitor that steps aside whenever a text field is editing, because table-backed lists do not forward those keys to SwiftUI key handlers.

Debug-only launch arguments: `--preview` (illustrative tasks), `--uitesting` and `--day-drag-fixture` (test fixtures in a separate local namespace), `--section=<key>`, `--calendar-mode=<mode>`, `--appearance=light|dark`, `--select-title=<title>`, `--capture=<file>`. Release builds ignore them.

## Screenshots

| Today, light | Today, dark |
| --- | --- |
| ![Today light](Screenshots/today-light.png) | ![Today dark](Screenshots/today-dark.png) |

| Calendar week | Calendar month, dark | Calendar year |
| --- | --- | --- |
| ![Week](Screenshots/calendar-week-light.png) | ![Month](Screenshots/calendar-month-dark.png) | ![Year](Screenshots/calendar-year-light.png) |
