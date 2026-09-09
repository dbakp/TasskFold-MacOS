# Taskfold macOS polish plan

The goal is a calm, fast native Mac app: daily actions should take few steps, navigation should preserve context, and motion should explain changes without disrupting work.

## Delivery rules

- Build and validate each milestone, install the verified app locally, then commit and push all changes to this repository.
- Preserve local iOS work. Shared Core comes from the iOS repository; use `TASKFOLD_IOS_ROOT` to build against a clean checkout when needed.
- Use native controls and the existing Store/Workspace undo paths. No backend or data model changes are required for the first milestone.
- Test changes with isolated fixtures. Never use real tasks as disposable test data.

## 1. Everyday editing — implemented and verified

- [x] Remove competing sidebar/calendar layout transitions.
- [x] Move focus into Calendar so its sidebar highlight matches the other destinations.
- [x] Remember unfinished quick-entry text, search text, and selected tasks for each destination during the session.
- [x] Keep the inspector out of the layout when nothing is selected; preserve the user's inspector preference.
- [x] Make existing date and project metadata actionable and add priority and task-action menus to rows.
- [x] Add a date popover with shortcuts, arbitrary dates, cancel, and one undoable commit.
- [x] Validate navigation restoration, date changes, completion/undo, and drag-and-drop; build and install Release.

Acceptance: navigating Today → Inbox → Today restores draft and selection; row edits do not require opening the inspector; rescheduling can be undone; no empty inspector occupies space.

## 2. Navigation

- [ ] Introduce app-wide search for open/completed tasks and projects, with keyboard result navigation and clear empty states.
- [ ] Add a command finder and recent destinations; keep filtering within a list available separately.
- [ ] Restore scroll position per destination, including when the visible task disappears after sync.
- [ ] Keep view options scoped to their destination instead of surprising users with inherited filters.
- [ ] Validate navigation with long lists, deleted records, and switching between Calendar and tasks.

Acceptance: locate a task outside the current list without changing filters; Return opens it, Escape returns focus; revisiting a long list returns to the previous position.

## 3. Capture from anywhere

- [ ] Add a compact quick-entry panel using the shared parser and undo/save behavior.
- [ ] Register a configurable global shortcut, detect shortcut conflicts, and provide a menu entry.
- [ ] Preserve unfinished capture input on dismissal and restore focus to the previous app after saving.
- [ ] Include destination/date previews without requiring the main window.

Acceptance: capture from another app, save once, verify the task appears in the intended destination, and return to the previous app without focus surprises.

## 4. Visual and interaction refinement

- [ ] Simplify inspector sections with progressive disclosure while keeping populated details visible.
- [ ] Refine typography, metadata density, and empty states across Today, Inbox, projects, and search.
- [ ] Maintain predictable keyboard selection after completion/deletion and reliable undo feedback.
- [ ] Audit animations for Reduce Motion, unnecessary relayout, and interruptibility.
- [ ] Profile scrolling, search, sidebar counts, and Calendar with thousands of fixture tasks; optimize measured bottlenecks.
- [ ] Validate light/dark appearance, narrow/wide windows, keyboard access, and VoiceOver labels.

Acceptance: common actions remain responsive with large datasets, keyboard navigation never unexpectedly edits or completes another task, and no animation causes repeated layout shifts.

## Verification — 9 September 2026

- Debug UI suite: four tests passed, zero failures. The optional screenshot report test was skipped.
- Covered draft/selection restoration, inline date change with undo, keyboard completion with undo, and day-to-day drag with persistence across relaunch.
- Release build succeeded; installed `/Applications/Taskfold.app` and verified its code signature and launch.
- Confirmed the empty inspector is absent and Calendar navigation works in the installed build.
- Shared iOS checkout: `9419eb230c7cd91bce0a213206ae84c2dc5deb70`.
- Navigation memory is session-only. Scroll restoration, global search, and global capture remain in subsequent milestones.

Commands (set the shared-source path to your clean iOS checkout):

```sh
xcodebuild -project Taskfold.xcodeproj -scheme Taskfold -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/taskfold-polish-build \
  TASKFOLD_IOS_ROOT=/absolute/path/to/TaskFold-iOS -allowProvisioningUpdates test
xcodebuild -project Taskfold.xcodeproj -scheme Taskfold -configuration Release \
  -derivedDataPath /tmp/taskfold-polish-release \
  TASKFOLD_IOS_ROOT=/absolute/path/to/TaskFold-iOS -allowProvisioningUpdates build
```
