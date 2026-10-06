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

## Calendar, drag-and-drop, and capture follow-up — 11 September 2026

- Started from a fresh clone at `b760615`, preserving the newer release, widget, onboarding, accent, and priority-band work. Built against a separate clean iOS clone at `d7a8bec3f686679095092bcd03839e06866a8186`.
- Replaced the month grid's ambiguous trailing Divider with explicit vertical/horizontal cell borders. Verified the installed Calendar has no mid-cell horizontal lines.
- Connected native List move/insert handlers in day, Inbox/scope, project-section, and overdue groups. Added overdue groups to drag ordering, with separate placement keys so reordering does not change due dates. Dropping onto a date still reschedules.
- Prevented late drag callbacks from restoring an ended drag's indicator and reset header/end targets on drag completion. Screenshots taken immediately after Inbox and Upcoming drops show no remaining indicator.
- Overdue groups have explicit disclosure buttons and per-destination collapse preferences in task views, including Inbox, projects, labels, and All Tasks. Empty Inbox lists retain a drop target.
- Replaced inline capture with a native modal panel for task lists and Calendar: prominent focused input, destination, parsing chips, close action, and Add Task button. Escape preserves the draft; successful submission clears it. Removed the unused inline entry component.
- Five targeted UI tests passed: capture open/dismiss/save, day-to-day drag, priority-band behavior, Inbox order with persistence and multi-view collapse, and overdue reorder/reschedule. Final Release build and strict signature verification passed; installed `/Applications/Taskfold.app` and visually verified Calendar and capture without modifying real tasks.
- Additional modal compatibility checks passed for per-destination draft/selection restoration and finder/project navigation. These tests dismiss capture before navigating, then reopen its preserved draft.
- Parsed-chip rejection also passed in the modal. Its initial run could not activate the test app while another installed instance was open; the isolated retry passed. Eight relevant UI tests passed across the targeted runs.

## Expandable subtasks — 11 September 2026

- Added chevrons and indented rows for task → subtask → sub-subtask in task lists and the Calendar day panel. Expansion is remembered during the session; existing deeper data is preserved without offering deeper nesting.
- Nested rows use normal native list selection and the existing inspector. Checkbox/Space completion, reopening, inline metadata actions, edits, and undo save through the parent task's embedded JSON rather than creating duplicate backend task records.
- Subtask creation in the inspector opens the parent's disclosure. Sub-subtasks cannot create another level. Completing a child does not complete its parent or siblings, and completed children remain visible inside an expanded parent.
- Native drag index mapping accounts for expanded descendants, keeping the parent subtree together. Child rows cannot be reparented by dragging, so dragging cannot create deeper nesting.
- Fixed a native hit-testing issue by keeping indentation inside the accessible row's layout rather than wrapping its accessibility container in padding.
- UI checks passed for nested creation/depth limits, grandchild editing and persistence, completion/undo, and existing day-to-day dragging. Additional regression results and installation are recorded below.
- Six targeted UI checks passed across the final runs: hierarchy edit/completion/undo/persistence, nested creation with depth limit, expanded-parent drag/undo, day-to-day drag, Inbox reorder/overdue collapse, and inline date/undo. Visually verified the expanded tree with a selected grandchild in its inspector.
- Release build and strict code-signature verification passed. Installed and launched `/Applications/Taskfold.app`; its binary matches the verified release. Previous app bundle retained at `/tmp/Taskfold-before-subtasks.app`. No real tasks were created or changed for verification.

## Collaboration foundation — 11 September 2026

- [x] Verify shared access with isolated owner, member, outsider, and newly registered account identities.
- [x] Fix native project insertion, invitation acceptance, case-normalized recipient linking, ownership protection, and access after leaving.
- [x] Add task and nested-task assignments, member lookup, row reassignment, and Assigned to Me with parent context.
- [x] Persist per-field edit baselines; merge independent comments and nested edits atomically; present same-field conflicts for review.
- [x] Preserve teammates' independent comments when resolving conflicts or undoing local changes.
- [x] Clear obsolete assignments on project moves and membership removal.
- [x] Build, verify, install, and push this milestone.

Verification:

- Database fixtures passed inside rolled-back transactions. Covered pending/accepted access, outsiders, ownership, invalid assignees, concurrent stale edits, retry idempotence, nested edits, revocation, project moves, and signup invitation linking. No real task data was changed and no emails were sent.
- Shared Core: 35 tests, one optional live-account test skipped, zero failures. Added checks for RPC baseline transport and conflict propagation, older queue decoding, nested merge resolution, and undo preserving a remote comment.
- Mac UI: assignments through both nested levels, relaunch persistence, completion/undo, and conflict resolution passed. Clipboard image paste, expandable hierarchy editing, and day-to-day drag regressions passed.
- The assignment test caught an inspector project-change observer that cleared assignments on initial load. It now acts only on user changes, and the corrected persistence test passed.
- Release build and strict deep signature verification passed. Installed `/Applications/Taskfold.app`, verified its binary matches the release output, and checked Assigned to Me in the installed application. Previous app retained at `/tmp/Taskfold-before-collaboration.app`.
- Shared Core revision: `1c5290f614c5c594731ba2815eb52850de59fe64`, committed and pushed to TaskFold-iOS. Unrelated sibling iOS work was untouched.

The new merge transport is enabled on macOS. Existing web/iOS clients and old queued mutations still need adoption; do not claim cross-client conflict safety until that rollout is complete. Email delivery and two interactive signed-in sessions remain an integration follow-up. Permissions, mentions, activity notifications, recovery, and advisor follow-ups are prioritized in [COLLABORATION.md](COLLABORATION.md).

## Current parity milestone — 14 September 2026 (verified for 1.1.0)

- Implemented resolved account/member names and photos, persistent isolated identity caches, incremental refresh and retry/offline presentation.
- Added Appearance settings with Roomy/Compact, native custom color selection/save, bounded saved accents, and contrast-aware filled controls.
- Added shared persistent project-section collapse state and an optional native board with section-aware capture, moves, assignment, completion/undo and keyboard selection. Kept list default and grouped contextual view options.
- Added persistent invitation-link routing through sign-in; preserved existing invitation management.
- Pinned clean iOS Core `9960d97`; release scripts enforce the exact revision and reject local dependency changes. Prepared 1.1.0/build 2 consistently for app/widget generation.

Evidence so far:

- Shared Core: 42 tests, one optional live test skipped, zero failures.
- Rollback backend checks: existing collaboration coverage plus Google fallback/custom identity precedence passed. No migration redeployed and no emails sent.
- Debug compilation passed. Added targeted UI tests for density measurements/persistence, accent-page retention, collapse/board creation/moves, invitation intent, real remote avatar rendering/cache relaunch, and Upcoming viewport behavior; updated assignee/filter selectors while retaining assignment/conflict tests.
- Local UI Automation and Keychain authorization were completed. XCTest now executes normally, and the installed distribution app opened successfully. Earlier authentication timeouts were environment failures before test execution.
- `Scripts/test_mac.sh` builds Debug fixtures with distribution-style entitlements and no widget. This avoids the shared App Group snapshot stall in the widget-enabled fixture. Final test-target compilation passed.

Manual runtime evidence on isolated `--uitesting` fixtures:

- Real HTTPS image decoding/rendering passed, with Morgan Lee's photo and known name retained after relaunch. The assignee button reports “Photo loaded” and opens the accepted-member picker. Parent account/button accessibility identifiers remain stable after image loading.
- Actual native project row rectangles measured 57 → 51 points for Roomy → Compact; rows with notes measured 75 → 69. Both modes, wide/narrow windows, and light/dark screenshots were reviewed.
- Native Colors panel opened through the explicit Choose… button. RGB hex `FFD95A` saved and selected without leaving Appearance. This exposed faint accent text and incorrect selected-row foregrounds: accent shades now adapt locally for contrast, while native table selections use AppKit's selected text color. Light/dark bright-accent screenshots passed. System/Rose/Roomy were restored after checks.
- Board section-aware creation, move to Planning, undo back to Ready, completion/undo, and collapse/layout persistence passed manually. A selected column was obscured when the inspector resized the board; responding to actual viewport width changes now keeps it visible, verified in a narrow window.
- Upcoming's active Today header remained pinned while scrolling, then Tomorrow replaced it. Completion/undo preserved Task 019 at visible Y=20; switching Calendar → Upcoming preserved Task 062 at Y=25. Empty dates and a narrow window were reviewed. These checks did not justify changes to the existing sticky-date or scroll-memory implementation.
- Invitation fixture opened the signed-out Invitations destination, and the pending destination survived relaunch. Actual sign-in/email delivery and two-client interaction were not exercised.
- Native XCTest press-and-drag passed for day-to-day rescheduling, Inbox order/persistence, overdue reorder/reschedule with one-step undo/redo, parent/child movement, and priority-band placement. Immediate post-drop screenshots show no remaining indicators.

Final automated UI evidence: **16 distinct targeted tests passed** across focused runs. Coverage includes appearance/native row density and persistence, real remote photos/cache relaunch, invitation intent, project collapse/board creation/move/last-row completion/undo, project completion/navigation viewport, Upcoming viewport, assignment through both nested levels, conflict resolution, clipboard image attachment, expandable hierarchy, native drag/priority rules, and deletion/navigation bookmarks.

Test corrections were verified through reruns: native macOS title values may be truncated, so created tasks are resolved by stable identifiers; board tests use horizontal scrolling and confirm the plus button is hittable before clicking; viewport checks measure a fully visible task above the completed row rather than a following row that should move upward or one clipped by a pinned header. No speculative changes were made to sticky dates, scroll memory, or confirmation-bar layout. Temporary navigation tracing was removed.

Final passing result bundles are in `/tmp/taskfold-parity-native-tests/Logs/Test/`: `18-27-42` (drag), `18-29-19` (appearance/invitation/photo), `18-33-43` (eight collaboration/hierarchy/viewport regressions), `18-40-14` (overdue undo/redo), `18-44-16` (Upcoming), and `18-48-23` (board). Mixed earlier bundles contain the superseded test failures as well as passing cases; no single all-tests-green run is claimed. Final focused logs: `/tmp/taskfold-parity-focused-tests.log` and `/tmp/taskfold-board-native-scroll.log`.

Remaining integration limitations: live Google/email sign-in and custom upload/removal UI, invitation email delivery, and two independently signed-in interactive clients were not exercised. Backend transactions and real image loading were checked separately. Native table/sidebar selection follows macOS's selection styling, while app-owned accent controls use the local chosen accent. No widget/notarization claim is made for distribution.

Packaging: the latest 1.1.0/build 2 distribution was rebuilt with the runtime fixes. Strict app signature and `hdiutil verify` passed, with no provisioning profile/widget extension. DMG SHA-256: `8bb25d1f6a69e33b58df2e485195edb626348c2407cff7641074d3137b1394b4`. Installed this candidate at `/Applications/Taskfold.app`, retaining the prior app at `/tmp/Taskfold-before-parity-1.1.0.app`. The installed distribution process opened its Today window successfully after local Keychain authorization. Output lives under `~/Library/Caches/TaskfoldBuild`; publishing checks a fingerprint of build inputs to reject stale packages. Published [v1.1.0](https://github.com/dbakp/TasskFold-MacOS/releases/tag/v1.1.0) from merged commit `4c4f473`. GitHub reports the uploaded DMG SHA-256 matching the locally verified package. The installed executable also matches the packaged executable (`ebda65a2afbc73c2bd33969191150337b876b0c64d12f047cdbdb830ad229b62`). System/Rose/Roomy were restored and temporary test swatches removed; the installed app is open.

## Productive widget collection — 5 October 2026

Implemented Today, Focus, Week ahead and Quick capture in the development widget extension. Task and capture links now route on Mac; the seven-day chart opens Upcoming. Shared Core now includes undated open tasks in its App Group projection, republishes on account loading and clears on sign-out. The pinned dependency includes the current upstream iOS assignment/profile work and retains its removal of Live Activities.

Verification: iOS and macOS app/extension builds succeeded with signing disabled. The shared Swift suite passed 46 tests with one optional live-account test skipped, including four projection tests covering legacy snapshots, priority selection, date rollover and Copenhagen DST. Actual SwiftUI fixture views were rendered and inspected in light, dark and empty states using `Scripts/render_widget_previews.py`; dark accents were adjusted for readable contrast. No user data was used.

The installed WidgetKit gallery, tinted rendering, device notifications, account-change widget host behavior, and production signing/distribution remain unverified here. The existing ad hoc DMG still excludes the extension; this source change is not a new packaged release. The detailed public-documentation/source audit and migration backlog are in `TODOIST_PORT_PLAN.md`, including the source-confirmed REST v2 importer risk. No backend migration, provider integration, or Todoist feature port beyond the widget collection was deployed.


### 5 October — P0 import and planning foundations (in progress)

The deployed Todoist importer now uses the current API v1, source IDs and an authenticated transactional import RPC. Both native clients request JSON completion, show import warnings, and expose independent deadlines and duration estimates with row badges and quick-entry chips. Shared Core `561ee6b` includes fixed-time instants, travel/DST reminder handling, literal escaping and one-off deadline clearing on recurrence. This is a foundation milestone; saved filters, richer quick entry, hourly planning, multiple reminders, restore and the additional configurable widgets remain active work.

Evidence and remaining gaps are tracked in `P0_IMPLEMENTATION.md`. The iPhone quick-entry/relaunch/editor UI test passed and its screenshot was inspected. Unsigned native builds, 53 Core/widget tests (one optional live skip), 10 importer fixtures, rolled-back live SQL isolation/replay/atomicity checks, web production build and TypeScript check passed. Mac UI execution requires unlocking macOS; the test runner failed during LocalAuthentication initialization, before exercising the app. No new distribution was packaged or published, and no real provider-account import or two-device round trip is claimed.


### 5 October — saved filters and synchronized organization (in progress)

Pinned shared Core `250bddc` in a clean checkout. Native iOS/Mac saved filters now share a versioned query engine and editor, named targets/people, grouping and list/board layouts. Favorites, view preferences and manual order are account-owned and use the durable sync queue; legacy settings/order are migrated with synchronized rows taking precedence. New project creation through the native HTTP return-record contract is repaired without changing accepted collaborators' access. Filters preserve target IDs on rename, show repair errors when access is lost, and capture applies only explicit shared query defaults.

Verification and limitations are recorded in [P0_IMPLEMENTATION.md](P0_IMPLEMENTATION.md). The optimized/debug 65-test suite, three isolated SQL transaction suites, and two-session authenticated HTTP fixture round trip pass. Both temporary users and their rows were removed. The iPhone filter/board/favorite/default/relaunch and overdue collapse tests pass; inspected screenshots are in `docs/p0-previews`. Native app/extension builds and the Mac UI-test build pass. Mac test execution remains blocked by the locked desktop; no installed or packaged P0 release is claimed. Full P0/widgets remain active work.


### 5 October — hourly planner and calendar busy time (in progress)

Both native calendars now have the same hourly Day timeline, all-day tasks, overlap lanes, optional estimates, scheduling, resize/move undo and explicit fixed/floating time behavior. Local calendar grouping and date moves agree after travel. Working hours are validated and synchronized; selected device calendars are read-only, private by default and scoped to the signed-in Taskfold account. Partial/denied calendar availability never becomes an implicit free-time claim. Temporal equivalence in the authenticated task conflict RPC is repaired without disabling genuine conflicts.

Shared debug/optimized tests and rolled-back database fixtures pass; iPhone scheduling/relaunch, drag/resize/undo and working-day/relaunch/denied-calendar feedback walks pass. Runtime defects found during those walks were fixed. Final shared Core is pinned to clean revision `708d8936ef7ba74158b7370c530cd6ff256c6116`; both unsigned native app/extension builds pass with local-time task badges, date popovers and notification rescheduling aligned. Inspected timeline screenshots and full evidence/limitations are in [P0_IMPLEMENTATION.md](P0_IMPLEMENTATION.md). The signed Mac UI runner timed out enabling automation before test execution; native Mac execution, real calendar permission, iOS conflict review and two running native-device round trips remain requirements; no release package or complete P0 claim is made.

### 5 October — independent Mac and iOS repositories

At the user's request, Mac now owns its Core, filter/planner views, backend configuration, app icon and Core tests locally. Removed the iOS revision pin, dependency-fetch script and external Xcode source paths. Mac testing, packaging, publishing and HTTP-fixture configuration use only this repository's inputs. iOS retains its own code and records the independent ownership rule. Compatible data contracts and corresponding tests preserve parity; changes relevant to both apps are maintained and committed in both repositories.

The repository-local Mac app/widget build and 79 local Core/widget tests pass (one optional live fixture skipped). Test products use an external build cache to avoid synced-folder signing resource forks. See [repository ownership](REPOSITORY_OWNERSHIP.md). Earlier pinned-Core notes above record historical evidence; they no longer describe build requirements. Independent release verification is recorded in `P0_IMPLEMENTATION.md`; no new public release or successful Mac user walk is implied.

The optimized local 79-test suite also passes. A fresh isolated clone builds a verified universal Intel/Apple Silicon distribution DMG using only local source/configuration/icon inputs; strict signature, disk-image and matching-fingerprint checks pass. Its signed UI-test target also builds independently. The candidate was neither installed nor published. Full verification details and the existing SDK concurrency warning are recorded in `P0_IMPLEMENTATION.md`. iOS ownership documentation is pushed as `e35133b`.


### 5 October — scoped quick entry and stable label edits (in progress)

Both native repositories now own matching project/section/accepted-member reference parsing, multiword names, explicit collision feedback, escaped literals and dependent-chip decline rules. Capture and title edits preserve deadlines/estimates, clear incompatible assignments on project moves and retain additional labels. Mac capture previews the parsed destination; iPhone manual controls override accepted metadata, and More carries unsaved label names without registering them on Cancel. New label edits store IDs compatible with web and both native clients; old names and unknown legacy values stay readable.

Both app-owned 91-test suites pass in debug and optimized builds (one optional live fixture skipped per run). Four iPhone reference/collision/manual-override/More-label flows pass, including relaunch persistence and a strict keyboard-clearance assertion. The stale More sheet handoff and crowded composer found in user testing were repaired. Final Mac app/widget compilation and signed UI-test target compilation pass; the Mac flow is compiled but has not run because the automation runner times out before executing tests. Full evidence, inspected previews and remaining P0/runtime gaps are in [P0_IMPLEMENTATION.md](P0_IMPLEMENTATION.md). The updated Todoist plan respects independent repository ownership; no new public release or complete P0 claim is made.


The final label-lifecycle regression also passes: new/existing labels together, rename/relaunch, delete one label and retain the task under its other label. Legacy rename/delete operations now preserve unrelated IDs. A post-dismissal navigation timing assumption was corrected in the test; the isolated cache showed no data loss. The reference parser no longer falls back to partial hash capture inside a path. Both final app-owned debug/optimized 91-test runs and Mac app/widget/signed test-target builds pass. Full details are recorded in `P0_IMPLEMENTATION.md`.


### 6 October — productive deadline and time-budget widgets (in progress)

Both native repositories own configurable Deadline radar and A small window implementations, with small/medium views, palettes, task/project name privacy, explicit deadline versus planned-date behavior and honest unknown estimates. Widget fixed times now agree with the planner after travel and across repeated DST clocks; signed-out snapshots clear rows and old snapshots request refreshed planning data. Native Inbox/All routes make empty-state task editing reachable.

The final local 101-test suites pass in debug and optimized builds in both repositories (one optional live-account skip per run); native app/extension builds and the signed Mac UI-test target build pass. Light/dark/empty/private/legacy source previews were inspected. Source renders do not establish installed-host or accessibility behavior. Full evidence and the remaining selected-scope, interactive-completion and native-host requirements are tracked in [P0_IMPLEMENTATION.md](P0_IMPLEMENTATION.md). The apps retain independent source/release ownership; no public release or complete P0 claim is made.

The signed iPhone small-widget walk also passes gallery discovery, real App Group snapshot rendering and task-link opening into the correct editor. Both new kinds appear in the gallery. The intermediate duplicate-button test lookup was scoped to one installed container before the final passing run; no app data defect was found. Native widget settings/privacy/other sizes and Mac hosts still require verification.


### 6 October — versioned backups and recovery previews (in progress)

Both independent apps now own portable versioned/legacy backup support, validated merge previews, deterministic reference mapping and create-only sync retry protection. Native recovery menus retain up to 20 encrypted local copies, including a mandatory checkpoint before restore. Daily copies save while the app is running; portable exports support another device. The default merge preserves current edits and existing work absent from a backup.

Both debug and optimized 126-test suites pass (one optional live-account skip per run), as does the disposable two-session HTTP fixture for all eight work tables with verified cleanup. Three native iPhone Files/recovery/corrupt-file/dark-largest-text flows pass; testing fixed modal anchoring and picker callback ordering, and visual review fixed the truncated accessibility-size title. Final app/widget Release compilation and signed Mac UI-test-target compilation pass. The locked Mac desktop prevents a runtime walk; native paired recovery, external provider saves, offline/concurrent edits and iOS conflict review remain open. [P0 evidence](P0_IMPLEMENTATION.md) and [backup behavior](BACKUPS.md) record the exact scope. No new public release or complete P0 claim is made.


### 6 October — native conflict-review parity (in progress)

Both native apps now use guarded baseline task edits and own matching grouped review surfaces. The reviewed mutation is identified explicitly; stale reviews cannot resolve a different queued edit. Saved resolutions retain later offline changes, and unknown-baseline older edits require review before sending. Case-equivalent UUIDs retain one cache row during resolution. The iPhone banner is reachable without visiting settings.

Both final 132-test debug/optimized suites pass (two optional live fixtures skipped). Earlier opt-in live runs in each repository's debug/optimized suites prove independent fields/comments, retry deduplication, overlapping edits and a second edit during review through two native authenticated Backend instances; fixture cleanup is verified. Three iPhone review/relaunch/dark-largest-text walks pass and their screenshots were inspected. Final native Release app/widget and signed Mac UI-test-target compilation pass. Mac runtime remains pending on the locked desktop; complete native pair/offline/account/revocation evidence remains active. [P0 evidence](P0_IMPLEMENTATION.md) and [review behavior](SYNC_CONFLICTS.md) record scope. No new public release or full P0 claim is made.

## 6 October Multiple reminders and scheduling reliability

Both native editors now support fixed dates, planned-time offsets, per-task opt-out and retained future settings. Reminder choices sync through guarded task edits; delivery preference and permission belong to each workspace/device. The scheduler cancels stale reminders and snoozes, guards account actions and in-flight revisions, reports failures and capacity, and refreshes local workspaces periodically. Largest-text titles now wrap fully. Each repo owns its implementation and tests.

Both 148-test debug/optimized suites pass with three optional live skips. Separate two-session native transport fixtures pass in debug/optimized runs for both repos, and all fixture cleanup counts are zero. Three iPhone persistence/unsupported-settings/accessibility/system-permission walks pass; their screenshots were inspected. Native Release app/widget builds and the signed Mac UI-test target compile successfully. Mac interaction remains pending on the locked desktop. Remote delivery and physical/background/paired/native-account/offline evidence remain active P0 work. [P0 evidence](P0_IMPLEMENTATION.md) and [reminder behavior and delivery plan](REMINDERS.md) define the remaining steps. No new public release or full P0 claim is made.

## 6 October: reminder quick entry and accessible capture

Both independent native parsers accept multiple fixed and planned-relative reminder shortcuts: `!30m` and `!2h30m` are elapsed time from acceptance; `!30mb`/`!1h before` follow the plan; `!30ma`/`!45min after` follow it afterward; `!0mb` enables the planned setting; local clock, weekday, explicit-date and tomorrow expressions create fixed instants. `!later` is exactly four elapsed hours. Each reminder has its own stable chip/decline group. Invalid, duplicate, over-limit and independently recurring expressions stay literal with feedback. Escaped multiword reminders, quoted prose, embedded exclamations and URLs cannot silently turn into task dates/times. Existing opt-out, unknown versions and extra fields survive additions; current reminder rows are merged again at application rather than overwritten. See [the complete syntax and delivery contract](REMINDERS.md#reminders-in-quick-entry).

The iPhone capture body now scrolls independently of the date/priority/project and primary action row. Reminder chips have a bounded text width. A hide-keyboard action and interactive keyboard dismissal allow feedback to be reviewed at large text sizes; fixed-size action glyphs stay within 48-point frames. Both apps explain when shortcut reminders have delivery off on this device. No notification permission prompt is triggered by capture alone. Mac retains its native inspector/autosave and keyboard chip controls.

Each repo’s debug and optimized core suite passes **163 tests**, with three optional live fixtures skipped and zero failures. Fifteen new cases cover the from-now/before distinction, compound offsets, multiple reminders, independent decline, nested/escaped literals, URL boundaries, invalid clocks/dates, duplicate IDs/settings, preserved unknown/opt-out rows, bounds/reapplication, date-only 8 AM behavior, recurrence copying, and DST/travel. Logs: `/tmp/taskfold-quick-reminders-{ios,mac}-{debug,release}.log`. The current protocol uses the already verified reminder transport/backup contract; this slice does not claim a new paired native-device sync run or remote delivery.

The iPhone 17 Pro/iOS 26.5 run `/tmp/taskfold-quick-reminder-ios-accessibility-walk.xcresult` passes five user walks: combined reference/planning capture; More and label lifecycle; multiple reminders through More/save/relaunch; independently declined/invalid reminders in dark largest text with keyboard dismissal and the full warning readable above Add; and escaped reminder capture/relaunch with no planned date. Screenshot review is retained in each repo’s `docs/p0-previews/ios-quick-reminder-shortcuts.png`, `ios-quick-reminders-persisted.png`, and `ios-quick-reminders-dark-largest-text.png`. The first largest-text attempt exposed an overly wide chip and clipped controls; screenshot review exposed oversized action glyphs. Scrolling content, bounded chips, fixed glyphs, explicit keyboard dismissal and 48-point action frames repair those issues. A subsequent check confirmed the rendered Add target meets 44 points after sheet scaling.

The final source additionally preserves declined chip choices during manual capture controls, resetting them only when the input clears. `/tmp/taskfold-quick-reminder-ios-overrides-walk.xcresult` passes two more walks: decline an absolute reminder → manually replace the suggested project with Inbox → confirm the assignment is cleared and only the relative reminder remains; and keep “tomorrow” as prose → manually choose Today → save/relaunch → find the task in Today. These two walks and the final iOS Release build include that last correction; the preceding five walks use the same capture layout and parser. The project walk explicitly scrolls the horizontal control strip to its menu.

Final native compilation passes: iOS Release app/widgets for generic Simulator (`/tmp/taskfold-quick-reminder-ios-release-build.log`), universal arm64/x86_64 Mac Release app/widgets (`/tmp/taskfold-quick-reminder-mac-release-build.log`), and the signed Mac Debug UI-test target (`/tmp/taskfold-quick-reminder-mac-test-build.log`). Mac’s new reminder capture/relaunch test is compiled but remains unexecuted with the desktop locked. No release package was installed or published. Autocomplete, richer task/independent-reminder recurrence, remote reminder delivery, physical/background/paired-device checks, and remaining P0 requirements stay open.


## 6 October: bulk deadline editing

Both independent app repositories now own a native set/clear deadline preview. iOS exposes it under selection More; Mac exposes it from inspector Actions, task context menus and the Task menu with ⌘⌥⇧D. The editor captures IDs and workspace, previews current deadlines and projected planned dates/times, and reads current records again at Apply. Removed tasks are skipped and a workspace mismatch prevents application. Only changed deadline fields are committed; plans, fixed instants, estimates and reminder specifications remain unchanged. The whole batch is one undoable step; cancellation saves nothing and matching values produce no extra history. A persistence failure keeps the editor open with feedback. Mac uses its existing grouped root/subtask update path and native undo bridge.

Each repo’s final debug and optimized core suite executes **170 tests**, with three opt-in live fixtures skipped and zero failures. Seven new cases cover mixed deadline-only edits, unchanged fixed DST instants and reminder events, undo/redo preserving later unrelated fields, clear/no-op/deduplicated IDs, strict Gregorian validation (including valid past deadlines), durable queue round trips with baselines, and captured selection/account values. Logs are `/tmp/taskfold-bulk-deadlines-{ios,mac}-{debug,release}.log`. These are local core/queue checks, not new live or paired native sync evidence.

Two isolated iPhone 17 Pro/iOS 26.5 walks pass in `/tmp/taskfold-bulk-deadlines-ios-walk.xcresult`: preview → Cancel → set both deadlines → Undo → Redo → relaunch → matching values disable Apply → clear → relaunch, with planned-date/time labels preserved; and dark largest Dynamic Type → clear → scroll both task previews → reachable Apply → Undo. Inspected screenshots are [deadline preview](p0-previews/ios-bulk-deadlines.png) and [dark largest text](p0-previews/ios-bulk-deadlines-dark-largest-text.png), retained independently in each repo. The iOS validation document links these under `docs/p0-previews`.

Final iOS Release app/widget compilation and universal arm64/x86_64 Mac Release app/widget compilation pass; the signed Mac Debug UI-test target also builds. Logs are `/tmp/taskfold-bulk-deadlines-{ios,mac}-release-build.log` and `/tmp/taskfold-bulk-deadlines-mac-test-build.log`. The Mac inspector/set/undo/redo/relaunch walk compiles but remains unexecuted with the desktop locked. iPad, physical device, native paired/offline sync, account-switch interactions and the remaining P0 requirements stay open. No app was packaged, installed over the user’s Mac app or publicly released for this slice.


## 6 October: selected lists in productive widgets

Both native repos now own **My list** in small, medium and large sizes, plus optional project/label/saved-filter narrowing for A small window and Deadline radar. Each widget instance keeps its own account-bound selection, palette and name privacy setting. Rename retains the stable selection; deletion, invalid filter references and account mismatch produce explicit unavailable/choose guidance. Widget rows open tasks; the My list background opens the selected list, with new project/label native URL routes. Project/label membership uses native query semantics and default priority order; saved filters use their saved sort and show open tasks. Manual grouped ordering and direct completion remain pending.

The additive version-2 snapshot includes list display metadata and open-task IDs, with no raw filter documents, task descriptions, reminders, sessions or executable queue. The app’s existing evaluator materializes eight local days of saved-filter membership. Relative filter dates roll over at actual local midnights, including DST, while a changed time zone or exhausted dates requests a refresh. Project/label memberships remain cached until the app republishes. Sign-out clears all rows/list metadata. Old snapshots decode with no list choices. The system picker uses [Apple entity queries](https://developer.apple.com/documentation/appintents/entityquery); normal rows show their type, while same-name duplicates expose IDs to disambiguate.

Final independent debug and optimized suites execute **180 tests**, with three optional live fixtures skipped and zero failures. Ten new cases cover rename/account identity, project and legacy-label membership, completed-task exclusion, deleted/negated filter references, native evaluator agreement across DST dates, expired/travel refresh, signed-out/legacy snapshots, independent window/deadline scopes and unknown estimates, deduplicated/missing task IDs, minimal payload and escaped list links, and same-name/cross-kind disambiguation. Logs: `/tmp/taskfold-widget-lists-{ios,mac}-final-{debug,release}.log`.

The repository-owned renderer generated real SwiftUI small/medium/large, chosen-list window, choose/empty/unavailable, light/dark and name-hidden fixture views. Inspected images: [light](widget-previews/lists.png), [dark](widget-previews/lists-dark.png), [private](widget-previews/lists-private.png), [empty](widget-previews/lists-empty.png), [unavailable](widget-previews/lists-unavailable.png). Each repo owns the script and copies of its documentation images. These render checks do not prove installed WidgetKit behavior.

Native iOS Release app/widget and universal Mac Release app/widget builds pass (`/tmp/taskfold-widget-lists-ios-release-build.log`, `/tmp/taskfold-widget-lists-mac-selected-release-build.log`). The signed Mac Debug UI-test target compiles (`/tmp/taskfold-widget-lists-mac-test-build.log`); its app fixture is unchanged by the final extension-only picker subtitle refinement. No Mac runtime walk is claimed with the desktop locked.

The iPhone installed My list walk compiles and starts against isolated `--uitesting --widget-list-fixture` data. An initial test compile error from a local variable shadowing XCTest’s attachment method was repaired. The first runtime attempt selected a hidden same-name icon; the revised lookup selects the hittable icon. SpringBoard then stalled waiting for the long-press animation to finish. The exact Xcode job was stopped, the isolated simulator restarted, and a bounded repeat encountered the same SpringBoard stall before entering the gallery; that job was stopped too. Bundles/logs: `/tmp/taskfold-widget-list-{installed-walk,visible-icon,rebooted}.xcresult` and matching `.log` files. A separate stalled simulator screenshot process was stopped. No installed My list configuration, task link, rename/delete refresh, live privacy toggling, native widget account switch, direct completion, native paired sync or physical-host result is claimed. Existing A small window installed-host evidence predates this change. Those acceptance requirements and the full P0 goal remain active. No public package was installed or released.
