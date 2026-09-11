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

## 2. Navigation — implemented

- [x] Introduce app-wide search for open/completed tasks and projects, with keyboard result navigation and clear empty states.
- [x] Add a command finder and recent destinations; keep filtering within a list available separately.
- [x] Restore scroll position per destination, including when the visible task disappears after sync.
- [x] Keep view options scoped to their destination instead of surprising users with inherited filters.
- [x] Validate navigation with long lists, deleted records, and switching between Calendar and tasks.

Acceptance: locate a task outside the current list without changing filters; Return opens it, Escape returns focus; revisiting a long list returns to the previous position.

## Requested account and comment improvements

- [x] Make account management, sign-in, settings, Todoist import, and invitations reachable from the sidebar and menu bar.
- [x] Paste clipboard images into comments as immediately saved attachments, preserving the text draft.
- [x] Verify selected-row text, priority, and action-button contrast.
- [x] Compare against the original apps and record remaining work in [the feature parity plan](FEATURE_PARITY.md).

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
- Navigation memory is session-only. Global capture remains in a subsequent milestone; see the newer verification entry below for navigation work.

## Verification — 10 September 2026

- Global search covers completed tasks without changing the current list filter; keyboard result selection, command execution, Escape, and caret restoration are covered by UI tests.
- Long-list checks compare the rendered viewport across Calendar navigation and after deletion. NSTableView accessibility can return stale/estimated row coordinates, so screenshots verify the visible result.
- Account, native login, and Todoist import entry points are covered in local mode. Live email/Google authentication, profile uploads, invitations, and confirmed Todoist imports still need a dedicated account-based integration check.
- Clipboard-image tests verify immediate persistence across relaunch, preservation of unfinished comment text, and ordinary text paste after image paste. The test restores the user's clipboard unless it changed independently.
- Selected-row contrast fixes remove a drag fade that left rows at 45% opacity and reset drag state after release; native selection and drag/drop remain in use.
- Calendar toolbar items are scoped to their destination, and one window-level title/subtitle follows navigation.
- Navigation memory is session-only; view options are saved per destination. Shared sources remain pinned to the clean iOS checkout above.

Commands (set the shared-source path to your clean iOS checkout):

```sh
xcodebuild -project Taskfold.xcodeproj -scheme Taskfold -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/taskfold-polish-build \
  TASKFOLD_IOS_ROOT=/absolute/path/to/TaskFold-iOS -allowProvisioningUpdates test
xcodebuild -project Taskfold.xcodeproj -scheme Taskfold -configuration Release \
  -derivedDataPath /tmp/taskfold-polish-release \
  TASKFOLD_IOS_ROOT=/absolute/path/to/TaskFold-iOS -allowProvisioningUpdates build
```

## Delivery verification — 11 September 2026

- The full regression run on 10 September passed ten functional tests; the optional screenshot report was skipped. Its drag regression exposed a cleanup race, fixed by handling release after AppKit's event processing instead of polling mouse-button state.
- The final targeted run passed day-to-day dragging with persistence and keyboard completion/undo: two tests, zero failures. An initial Xcode automation initialization timeout was resolved by restarting the test service.
- The final Release build succeeded and passed strict code-signature verification. Installed it at `/Applications/Taskfold.app`, preserving the prior app bundle at `/tmp/Taskfold-before-september11.app`.
- Verified the installed release opens, switches Calendar → Today with the correct title and toolbar, opens global search, and exposes General/Account/Import/Invitations. Import's sign-in action opens the native email/create-account/Google login sheet.
- Live provider sign-in and account-backed import remain unverified, as described in the parity plan. No real task data was changed during verification.

## Layout follow-up — 11 September 2026

- Moved the current-list text filter and view-options menu into the upper-right corner of the task content. Global search stays in the sidebar; ⇧⌘F focuses the content filter.
- Task-list and Calendar quick-add fields start hidden. The toolbar plus, ⌘N, or New Task command reveals entry. Escape hides it without discarding the draft; successful submission clears and hides it. Returning to a destination keeps entry hidden until reopened.
- Verified four UI regressions: scoped completed filters, finder focus/project navigation, per-destination draft restoration, and explicit quick entry with filtering. The new test initially queried a task's accessibility label instead of its value; the corrected query passed.
- Release build and strict signature verification passed. Installed `/Applications/Taskfold.app` and visually checked the content-corner controls and plus/Escape behavior without changing real tasks.

## Parity pass — 11 September 2026

Shared iOS checkout: `d7a8bec` (`TASKFOLD_IOS_ROOT`, default `../taskfold-ios`). Seven milestones, each committed and pushed:

1. Band ordering and constrained drops, group reordering, Priority sort removed.
2. Quick-entry chips in the quick-add bar (lists, Calendar) and the inspector title.
3. Links by page title with hover previews, context menu, inspector Links section, selection-safe clicks.
4. Account security actions and actionable reminders.
5. Plan Your Day and Review This Week.
6. Accent colours, date-line subtitle, recent searches.
7. Shortcuts intents and the Today widget extension (App Group on both targets).

Verification notes:

- New UI tests: `testDropStaysInsidePriorityBand`, `testDeclinedChipKeepsWordsInTitle`, `testLinkClickDoesNotSelectRow`, `testPlanSheetCompletesTask`.
- Results: all 16 functional UI tests pass (11 in the full run once the screen unlocked, the 6 that had hit the lock in an immediate rerun), plus the screenshot capture test; shared Core `swift test` passes 31 tests with 1 live-fixture skip. Full-suite runs that start while the screen is locked fail every test with "has not loaded accessibility"; that is the lock, not the app.
- Fixture launches register `ApplePersistenceIgnoreState`: force-quit runs left window-restoration state that restored an app with no windows, which made every fixture test fail before the fix.
- Table-backed lists claim clicks before forwarding them, so link clicks are intercepted by a local event monitor ahead of the table (`Views/Links.swift`). Arrow keys reach `onMoveCommand`, not `onKeyPress`, in the planning sheet.
- The planning sheet snapshots its queue when it opens; recomputing it from the live store skipped a card after a completion.
- Shared Core compiled unchanged. `canImport(ActivityKit)` is true on macOS, so a no-op `LiveActivityManager` stub in the Mac target satisfies the persist hook.
- Live account actions (email/password change, reset, delete), Shortcuts phrases in Siri, and widget rendering in Notification Center need a signed-in account and a manual check; the bundle carries `Metadata.appintents`, the embedded `.appex`, and the App Group entitlement, and code signing verifies.

## Distribution and onboarding — 11 September 2026

- `Scripts/make_dmg.sh` produces `dist/Taskfold-<version>.dmg` (UDZO, HFS+, Applications shortcut, hidden readme), signs the image with the Apple Development identity, and verifies it. Mounted the image and verified the embedded app's signature. Developer ID and notarization remain out of reach on the personal team, so first launch on other Macs needs right-click ▸ Open.
- Welcome tour (`Views/OnboardingView.swift`): five pages, skippable, keyboard-driven, Reduce Motion aware, built from live components (`QuickEntryChips`, `CheckMark`, `InsertionIndicator`, the accent swatches). Shown once on first launch (`onboardingSeen`), reopenable from Help and Settings. Fixture launches show it only with `--onboarding`.
- UI test `testOnboardingPagesAndDismisses` passes; tour pages are captured as `Screenshots/onboarding-1…5.png`.

## Distribution signing — 11 September 2026

- The first v1.0.0 image was a team-signed development build: its embedded profile listed one device and expired in seven days, so another Mac reported "can't be opened". Replaced it with a distribution build: ad hoc signature (`CODE_SIGN_IDENTITY=-`), no profile, `Taskfold-Distribution.entitlements` (sandbox, network, user-selected files), no base entitlements injected, widget extension omitted (`TASKFOLD_WIDGETS=0` during the build; the checked-in project is regenerated afterwards).
- Verified: `Signature=adhoc`, no `embedded.provisionprofile`, no `PlugIns`, the app launches locally, and the image verifies. First launch on other Macs needs Privacy & Security ▸ Open Anyway; the release notes and the in-image "How to install" say so.
- `--development` keeps the team-signed variant for local use.
