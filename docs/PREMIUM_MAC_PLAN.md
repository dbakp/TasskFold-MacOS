# Taskfold macOS polish plan

Current release-gate order and external dependencies: [P0_RELEASE_STATUS.md](P0_RELEASE_STATUS.md).

The goal is a calm, fast native Mac app: daily actions should take few steps, navigation should preserve context, and motion should explain changes without disrupting work.

## Delivery rules

- Build and validate each milestone, then commit and push completed changes to this repository. Installed-host and provisioned-release acceptance are separate gates; preserve the user’s existing installed Mac app.
- Preserve local iOS work. Each native repository owns its Core, app, widget, tests, resources and release inputs; keep compatible behavior without sibling build dependencies.
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


### 6 October: recurring completion and preserved undo

The Mac-owned Core now uses stable create-only recurring successors, correct Gregorian/source-zone recurrence, renewed checklist identities and advanced child plans. Whole-task guarded deletion prevents undo from removing a successor created or edited elsewhere. The inspector's sync review offers Keep task/Delete task/Later and shows the current contents. Both native clients use the deployed invoker/RLS deletion RPC. Independent Debug/optimized suites execute 195 tests with three optional live skips and no failures; universal Release app/widgets build. Signed UI-test compilation passes; its new keep-task/relaunch walk remains unexecuted on the locked desktop. Three iPhone deletion-review walks and rolled-back live SQL authorization/concurrency checks pass. [Full evidence and limits](P0_IMPLEMENTATION.md#6-october-recurrence-identity-and-guarded-deletion). Direct widget completion is still pending and the full P0 goal remains active.

## 6 October: durable My list completion

The Mac app now owns the same account-bound completion intent, credential-free process-locked handoff, private save receipts and opaque state tokens as iOS, with its own sources and release inputs. My list keeps the pastel surfaces and separate 44-point completion targets. Pending actions stay visible; locally saved changes awaiting upload have distinct status. Independent Debug and optimized 205-test suites and both process-concurrency scripts pass; native Release app/widgets and the signed Mac UI-test target build. Four isolated iPhone app-intent save/retry/undo/workspace walks pass. Dense, pending and sync-pending actual SwiftUI fixture views were inspected. The Mac generator deduplicates shared-source references and gives each target its own build-file identity.

[Detailed evidence and limits](P0_IMPLEMENTATION.md#6-october-durable-my-list-completion) distinguishes app-intent execution from installed WidgetKit routing. The locked desktop prevents a Mac runtime walk. A server completion revision is still required for unseen remote complete/reopen cycles; native paired/offline/physical/iPad acceptance, installed host behavior, account-cache recovery and the remaining P0 backlog stay active. The distributed ad hoc DMG still omits widgets. No public release or installed Mac replacement is claimed.


## 6 October: completion-cycle preservation

The deployed server-owned completion revision closes the unseen remote complete/reopen gap for the new native clients. Mac independently owns local counter prediction, confirmed-row replay, retained stale editor baselines, reviewed offline chains and recurring successor cancellation that keeps later drafts. Widget and notification actions invalidate after observed cycles; exports/restores respect server ownership. Existing deployed clients remain compatible with their legacy writes.

Final independent Debug/optimized suites pass 218 tests with three optional skips; earlier 216-test live runs in both repos pass two-session native HTTP cycle/review/retry checks with two optional skips. Rolled-back SQL authorization/concurrency fixtures pass and disposable account/session/task/profile cleanup is verified. Eight unique iPhone app-intent/review paths pass, with an additional final large-text frame/readability check and inspected screenshots. Final universal Mac/iOS Release app/widgets and signed Mac UI-test compilation pass. The Mac retained-draft/relaunch test is compiled, but the locked desktop prevents runtime evidence. [Full evidence and remaining gates](P0_IMPLEMENTATION.md#6-october-completion-cycle-revisions-and-retained-offline-work). Full P0, installed-host, native pair/offline/physical/provider acceptance and additional productive widgets remain active; no public package is released.


## 6 October: Day capacity

The Mac repository independently owns Day capacity with Today/Tomorrow, small/medium sizes, palette/privacy, whole-day task/calendar totals, explicit unknown/outside-plan work and one-hour calendar expiry. Calendar reads remain in the app and daily numeric totals reach the extension. The Day link preserves task plans. Both planner copies now stack all-day titles and scroll the summary at accessibility sizes; Mac calendar modes fall back to a native menu in narrow layouts.

Independent Debug/optimized suites pass 228 tests with three optional skips; 11 SwiftUI fixture sheets are rendered and inspected. Six distinct iPhone walks pass across focused runs, including capacity settings/completion/relaunch, maximum text/menu scrolling and planner/collapse regressions. Final universal Mac/iOS Release app/extensions and signed Mac test compilation pass. The Mac Day-link/relaunch test compiles but remains unexecuted on the locked desktop. [Detailed evidence and remaining acceptance](P0_IMPLEMENTATION.md#6-october-day-capacity-and-accessible-planning) records installed-host, calendar, physical/iPad and paired/offline gates. The remaining productive widgets, remote reminders and full P0 goal stay active. No public package or installed Mac replacement is claimed.


## 6 October: Inbox reset and native review

Mac independently owns the ninth widget kind, Inbox reset, with small/medium sizes, five/ten/all batches, per-instance palette/privacy and an account-bound review route. Its Inbox toolbar opens the same move/edit/complete/keep flow. Move preserves planning, deadline and reminder fields; Keep makes no mutation; failed saves do not advance. Undo checks the normal history receipt, next batches skip kept work, and Review again explicitly repeats it. The summary reports actual remaining Inbox work. Editor workspace guards prevent cross-account saves, and Mac Undo registration handles the history cap by identity.

Independent Debug/optimized core suites pass 240 tests with three optional skips; seven owned SwiftUI fixture sheets are rendered/inspected. Five distinct Inbox iPhone walks, two existing More-options editor regressions and a focused counter follow-up pass. A native test exposed a 20-point Undo target; full-width labels now provide real 44-point-or-larger targets, and maximum-text checks scroll whole buttons into view. Final iOS and universal Mac Release app/extensions and signed Mac UI-test compilation pass. The Mac review/relaunch walk compiles but stays unexecuted on the locked desktop. [Full evidence](P0_IMPLEMENTATION.md#6-october-inbox-reset-and-native-review) retains installed-host, Mac/account, native paired/offline/physical/iPad, distribution and all remaining P0 gates. Project pulse, Pinned note, Focus session and remote reminders remain active. No public package or installed Mac replacement is claimed.


## 6 October: readable pinned notes

Pinned note is the tenth owned widget kind, with soft adaptive small/medium/large layouts, per-instance palette/privacy and an explicit account-bound selection. The Mac toolbar opens a native pinned-note catalogue, full-text reader and existing task inspector. Creation and selection persist together; unpinning keeps the task's description; completed task notes remain available. Native Mac Undo registration uses the normal durable receipt identity. The catalogue reader now has an explicit Close control, and medium-widget spacing was corrected after inspecting source renders.

Independent 251-test Debug/optimized suites, nine rendered fixture sheets, seven distinct note iPhone walks, two creation regressions and rolled-back backend ownership/isolation checks pass. Final app/widget Release builds and signed Mac UI-test compilation pass. The Mac edit/unpin/Undo/relaunch walk compiles but is unexecuted on the locked desktop. [Full evidence](P0_IMPLEMENTATION.md#6-october-pinned-notes-and-private-widget-excerpts) keeps installed-host, Mac/native paired/offline/restore/account/physical/iPad and provisioned distribution acceptance open. Project pulse, Focus session, remote reminders and every remaining P0 requirement stay active.

### 6 October: Inbox widget count clarity

Inbox reset now reads “Review 5 of 6” for a partial batch and “Review all 6” when the selected batch covers the Inbox. Both independently owned native extensions build in Release; regenerated small/medium normal, dense and largest-text SwiftUI fixtures fit the copy. [Evidence and limits](P0_IMPLEMENTATION.md#6-october-inbox-widget-count-clarity). Installed WidgetKit and remaining P0 acceptance are still pending.


## 6 October: richer repeat rules

Mac independently owns richer weekday-set, monthly ordinal, yearly, completion-relative and bounded repeat rules, full quick-entry previews and native inspector controls. Declining a phrase keeps its whole text literal. Late scheduled completion skips past dates without consuming the remaining count; month-end/leap-day anchors and fixed source zones survive successor creation. The iPhone controls additionally stack at accessibility sizes and use verified 44-point hit areas. No backend schema or sibling build dependency was added.

Independent Debug/optimized 270-test suites pass with three optional integration skips. Five distinct new iPhone walks and two creation regressions pass across the six-pass baseline and final one-test touch-target refinement; the baseline's real target failure is recorded. Mac Release and signed UI-test compilation pass, while Mac runtime remains unexecuted on the locked desktop. [Detailed evidence](P0_IMPLEMENTATION.md#6-october-richer-repeat-rules-and-native-controls) and [repeat syntax](RECURRENCE.md) retain named/sub-day/independent-reminder grammar, autocomplete, paired/offline/account/physical/iPad/installed-host and release acceptance. Project pulse, Focus session, remote reminders and full P0 stay active.


## 6 October: reference suggestions in native entry

Mac independently owns cursor-local project, section, label and current-member suggestions in capture, Day capture and the inspector. Explicit choices distinguish same-name rows and retain existing stable IDs; deleted/revoked/renamed choices remain literal. Native rows wrap full names with 44-point targets. Inspector choices use normal autosave while other keyword feedback stays available. Capture and inspector mutations check workspace identity/generation before label registration or task saves. No backend schema or sibling build dependency was added.

Independent Debug/optimized suites execute 287 tests with three optional integration skips and zero failures. Five distinct new iPhone walks and three regressions pass across the seven-test baseline and four-test final refinement. The final checks verify Done selection/submission, More, existing-editor persistence and the entire largest-text suggestion row; recorded identifier/newline/visual defects were corrected. Final app/widget Release builds and signed Mac UI-test compilation pass. Mac keyboard/capture/relaunch runtime remains unexecuted on the locked desktop. [Detailed evidence](P0_IMPLEMENTATION.md#6-october-cursor-local-reference-suggestions) and [syntax/behavior](QUICK_ENTRY_SUGGESTIONS.md) retain date/repeat/reminder menus, richer grammar, native paired/offline/account/physical/iPad/installed-host and provisioned distribution acceptance. Project pulse, Focus session, remote reminders and full P0 remain active.


## 6 October: planning suggestions and retained dates

Mac independently owns supported date/time, repeat and reminder suggestions in capture, Day capture and the inspector. The actual parser supplies previews; choices remain editable with normal chips and save behavior. Directory and planning results share native wrapping rows, scrolling, 44-point targets and keyboard handling. Capture preview/Add share inherited defaults and the selected Day date. Both parsers now retain an existing planned date when adding only a time. Keeping one reminder literal or dismissing a partial second reminder preserves earlier accepted reminders. Persisted task fields/queue/sync/backup contracts are unchanged.

Independent Debug/optimized suites execute 304 tests with three optional integration skips and zero failures. Six distinct new iPhone user walks and two reference regressions pass across the recorded bundles, including a corrected compact-date test lookup and verified future-date/time persistence. Largest-text row/keyboard screenshots were inspected. Final app/widget Release and signed Mac UI-test builds pass. Mac native planning/keyboard/relaunch runtime remains unexecuted on the locked desktop. [Detailed evidence](P0_IMPLEMENTATION.md#6-october-planning-suggestions-and-preserved-plans) and [supported vocabulary](QUICK_ENTRY_SUGGESTIONS.md#dates-times-repeat-rules-and-reminders) retain richer grammar, independent reminder recurrence, Mac/hardware/paired/offline/account/physical/iPad/installed-host and provisioned distribution acceptance. Project pulse, Focus session, remote reminders and full P0 remain active.


## 6 October: durable native Focus sessions

Mac independently owns task-bound Focus start/pause/resume/end, replacement confirmation, wrapping timer cards, durable UTC timestamps, guarded shared state and conflict review. Backup exports pause a checkpoint; restore remaps identities and uses the current target revision. Deployed owner-scoped migrations retain a monotonic slot and reject unseen edits, completed-task resume and task-identity changes. Both clients now guard HTTP retries/token refreshes and queued edits against account switching.

Independent Debug/optimized suites execute 321 tests with three optional integration skips and zero failures. Eight distinct iPhone fixture paths pass across the recorded bundles, including corrected restart timing, process recovery, save failure, both conflict choices, largest text and a finished timer that leaves its task open. Rolled-back SQL ownership/concurrency checks pass. Release app/widget builds pass; signed Mac Focus UI-test compilation is recorded separately from its unexecuted runtime walk. [Detailed evidence](P0_IMPLEMENTATION.md#6-october-durable-native-focus-sessions-and-account-scoped-transport) and [contract](FOCUS_SESSIONS.md) keep dedicated timer widget/notifications, Project pulse, native paired/offline/account/restore/Mac/physical/iPad/installed-host, provisioned distribution and all remaining P0 requirements open. No installed Mac application or public release was replaced.


## 6 October: current-session Focus widget

Mac independently owns the eleventh widget kind, a small/medium current-session clock with palette/privacy, timestamp-based countdown, static paused/spent time, explicit unavailable/review/refresh states and native account-bound routing. Bounded credential-free projections clear stale conflict labels after resolution. The small view now reserves two title lines after an actual iPhone Home Screen screenshot exposed truncation. No sibling source/resource/release dependency or backend schema change was added.

Independent Debug/optimized 330-test suites pass with three optional skips; both native Release app/extensions and the signed Mac test target build. Twelve owned source fixture sheets were regenerated, with iOS sheets and selected Mac dark/privacy/largest sheets inspected. Three iPhone publication/route/relaunch/review fixtures and an installed small-widget gallery/background-countdown/open/pause/remove walk pass across overlapping bundles. [Detailed evidence and remaining acceptance](P0_IMPLEMENTATION.md#6-october-focus-session-widget-and-native-routes) distinguishes source renders and simulator hosts from the unexecuted Mac runtime. Full P0, Project pulse, finish notification, remote reminders, paired/offline/account/physical/iPad and provisioned distribution gates remain active.


## 6 October: Focus finish alert implementation

Both native repositories now independently own optional device-local Focus finish alerts, separate from task reminder delivery. The existing serialized scheduler reserves one of 60 slots for the current timer, validates guarded session/completion state, cancels obsolete work and routes the finish banner without completing its task. No remote-delivery worker or schema change is added. [Current evidence](P0_IMPLEMENTATION.md#6-october-optional-focus-finish-alerts) records 338-test Debug/optimized suites, the final three-pass iPhone pending-queue/largest-text/background-banner walk, task reminder regression and final independent builds. Mac UI-test compilation passes; runtime remains unexecuted on the locked desktop. Cold launch, physical/reboot/iPad/paired/offline/account acceptance and provisioned distribution remain open. Project pulse, remote task reminders, provider/import walks and the full P0 scope remain active.


## 6 October: Project pulse screen and activity foundation

Both native apps now own current project completed/total counts, needs-attention task links, honest local-calendar seven-day events and a sequence-ordered timeline. A deployed metadata-only transition ledger begins at a stated epoch; earlier work is not fabricated. Guarded current/recorded-scope access, revoked creator isolation, immutable server receipt/effective completion times, local atomic history, account-frozen keyset pages and archive-without-replay backups preserve provenance. [Contract](PROJECT_PULSE.md) and [detailed verification](P0_IMPLEMENTATION.md#6-october-project-pulse-screen-and-recorded-task-history) record the real cascade defect/fix, rolled-back SQL fixture, final 350-test Debug/optimized suites, four distinct iPhone walks across overlapping four-pass/one-pass bundles and independent Release builds. Signed Mac test compilation passes; locked-desktop runtime remains unexecuted.

The dedicated Project pulse widget is still pending; eleven existing widget kinds remain. Implement bounded per-project current/event/attention projections with stated coverage/window, stable project IDs and rename/removal/revocation states; per-instance palette/privacy; account-bound native pulse routing; exact freshness/expiry; source/family renders and installed configured/multiple-host checks. Native paired/offline/account/restore/Mac/physical/iPad acceptance, remote task reminders, provider/import/calendar checks and all remaining P0 gates stay active. No installed Mac replacement or public release was produced.


## 6 October: Project pulse widget implementation

Both native repositories now independently own the dedicated small/medium/large Project pulse widget, bringing the collection to twelve kinds. Stable account/project selections, per-instance appearance/privacy, bounded current/event/attention projections, explicit recording coverage, exact freshness/day rollover and guarded native routes are implemented. Current completed tasks and seven-day completion/reopen events remain visibly distinct. [Contract](PROJECT_PULSE.md#widgets) and [verification](P0_IMPLEMENTATION.md#6-october-dedicated-project-pulse-widget) record 358-test Debug/optimized suites, two passing actual-publication/route/relaunch iPhone paths, eleven source fixture sheets and final independent app/extension builds. Mac UI-test compilation passes; locked-desktop runtime and installed configured widget acceptance remain unproved.

Installed multiple-instance/privacy/refresh/account checks, native paired/offline/cache/restore/device acceptance, remote reminders, provider/import/calendar walks and remaining P0 gates stay active. The earlier eleven-widget/pending-Project-pulse entries describe their historical checkpoints. No Mac installation or public release was produced.


## 6 October: reminder device foundation

Private device registration and typed workspace-generation reminder scene routes are implemented independently in both native repos. The deployed registry and hardened legacy web cron are verified; [contract](REMOTE_REMINDER_DELIVERY.md) and [checkpoint](P0_IMPLEMENTATION.md#6-october-reminder-registration-and-guarded-scene-handoff) record 368-test Debug/optimized suites, one live Auth transport pass per repo, rolled-back SQL fixtures, five cron tests, three iPhone routes/permission passes and final app/widget builds. Mac UI-test compilation passes; runtime remains pending on the locked desktop.

Remote delivery remains unavailable: native lifecycle/opt-in/entitlements, occurrence jobs, provider setup, expiry/reinstall recovery, deduplication and cold/physical/paired/Mac acceptance are still required. All remaining P0 gates stay active.


## 6 October: canonical reminder jobs and DST correctness

Both native cores now agree with the private SQL occurrence projector on 27 fixtures. Half-hour clock gaps no longer move planned reminders to tomorrow; working hours and reminder shortcuts use the same valid-minute resolver. Legacy receipts/snoozes keep their scope and chosen times. The deployed service-only job APIs provide reconciliation, fenced leases/retries, pre-dispatch access checks, invalid-token retirement and maintenance. [Contract](REMOTE_REMINDER_DELIVERY.md#canonical-occurrences-and-private-delivery-jobs) and [verification](P0_IMPLEMENTATION.md#6-october-canonical-reminder-occurrences-and-private-delivery-jobs) record 374-test Debug/optimized suites, rolled-back SQL, a real concurrent lease race, six distinct iPhone paths across two passing bundles and final owned builds. Mac runtime remains pending.

Remote delivery remains unavailable. Restored task identities/accepted-event history and initial-enable/import/backdated catch-up eligibility are now implemented. Before provider integration, implement native lifecycle/entitlements/opt-in, the scheduled provider worker and local/remote authority. Cold/physical/paired/Mac and all other P0 acceptance gates remain active.


### Task recreation and stale drafts — 6 October

Mac independently owns immutable task generations, r4 reminder/Focus/widget action fencing, fresh backup/Undo/Redo recreation, create-only retries, generation-aware edit/delete baselines and full-row adoption during explicit conflict review. The inspector binds editing to the root generation even for nested tasks, preserves the current edited draft and cancels autosave on recreation; unedited fields can refresh. The iPhone editor's identity warning stays within the editor instead of dismissing the draft.

Deployed private eligibility and tombstones prevent restored/imported past plans or newly enabled delivery from replaying old alerts. Accepted receipts survive task deletion for eight days. The independent 379-test Debug/optimized suites and separate native Auth conflict/restore/review tests pass. Thirty-one native/SQL vectors and rolled-back queue/registration/generation fixtures pass; final Release app/widgets and signed Mac UI-test compilation pass. The final combined iPhone bundle passes all seven paths with zero failures/skips/runtime warnings. [Detailed evidence](P0_IMPLEMENTATION.md#6-october--task-generations-restore-safety-and-catch-up-eligibility) keeps Mac runtime, native paired/offline/physical/iPad/installed-host/distribution and the remaining P0 gates open. Provider/lifecycle/opt-in/local-remote authority remain required; no installed Mac app or public release was replaced.


### 6 October — APNs worker implementation, delivery disabled

Mac and iOS independently own the APNs adapter, bounded service worker, two exact deployed migrations, actual-role SQL fixtures and credential-free test script. Each script passes 23 tests with both entrypoints typechecking. JWT signature verification, scoped sandbox/production keys, headers/4-KiB payloads, large-title/private-note bounds, stale leases/held receipts, lost acknowledgements, retry floors and provider failure behavior are covered. Rolled-back queue tests retain all 31 projection fixtures and verify service-only new retry receipts and 15-minute server retry floors. Deployed HTTP authorization/method/disabled checks pass; cleanup confirms zero users/devices/jobs from fixtures. No APNs request, native app mutation, installed Mac replacement or release was made.

Remote delivery remains unavailable. Native lifecycle/entitlements/explicit opt-in, local/remote authority, durable cursor scheduling, credentials, hosted HTTP/2/APNs and physical/closed-app/paired/Mac acceptance remain open. Backend adapter implementation is now complete for this checkpoint; rollout acceptance is not. [Contract/evidence](REMOTE_REMINDER_DELIVERY.md#apns-adapter-and-disabled-worker--6-october) and [operations](APNS_WORKER_OPERATIONS.md) distinguish them.


### 6 October — inactive native reminder registration

Mac independently owns fresh APNs callbacks, public signed-entitlement detection, the inactive coordinator, secure retirement before sign-out and native setup feedback. It shares a compatible contract, not a source/build dependency, with iOS. Both repos pass 394 Debug/optimized core tests (four optional integration skips) and final Release app/widget builds. Mac app/widgets include both architectures; the signed Mac UI-test target compiles only. Three isolated iPhone permission/settings/largest-text flows pass. No Mac GUI, installation, provider or physical push delivery was exercised. [Evidence](P0_IMPLEMENTATION.md#6-october--inactive-native-reminder-registration) and [lifecycle contract](REMOTE_REMINDER_DELIVERY.md#inactive-native-registration-lifecycle--6-october) retain explicit opt-in, authority/deduplication, cursor scheduling, credentials and signed physical/paired/closed-app acceptance gates. Remote delivery stays disabled and the full P0 objective remains active.


### 6 October — durable reminder sweep, inactive scheduler

Both repositories own the deployed durable cursor/lease, current-sweep payload fence, inactive 30-second cron and Vault-backed service configuration. Interrupted runs retain unfinished devices; stale receipts cannot rewind later progress. Both 32-check Deno scripts, real 45-device/grant/expiry/payload SQL checks, marked concurrent database transactions and existing queue/registration regressions pass. Worker v5 and migration hashes match owned source; authenticated HTTP remains disabled and no APNs request occurs. [Evidence and remaining gates](REMOTE_REMINDER_DELIVERY.md#durable-sweep-coordinator-and-inactive-cron--6-october) retain volume/operational acceptance, explicit opt-in, one delivery authority, credentials, signed physical/paired/closed-app/Mac and the full P0 objective. Native app inputs were unchanged; no installed/public release was made.


### 6 October — compact planner and native iPad acceptance

The iPhone planner now scrolls its summary in compact height, fixing an all-day Schedule control previously below the usable viewport. Mac independently owns the guarded layout policy and retains its existing macOS behavior. Actual iPad tabs/sidebar/Files navigation and bounded control gestures now support portrait/landscape acceptance. The final iPad five-case and phone two-case bundles pass with zero failures/skips/runtime warnings. Additional passing cases cover backup choices/recovery, saved filters, unknown reminders, Project pulse and Focus restart; mixed intermediate failures are recorded separately. Both owned unsigned Release app/widget builds pass and Mac executables are universal. [Detailed evidence and native screenshots](P0_IMPLEMENTATION.md#6-october--compact-planner-and-native-ipad-acceptance) retain the unresolved filter-keyboard frame warning, locked Mac runtime, paired/physical/installed-widget/distribution and all remaining P0 gates. No installed Mac app was replaced and remote delivery stays disabled.


### 6 October — named dates and repeat boundaries

Mac independently owns named plans/deadlines, named start/end repeat boundaries, period-date autocomplete, strict calendar validation, source-zone/civil-day handling and future-year date previews. The persisted format is compatible with the independently implemented iOS app. Both packages pass 408 Debug/optimized tests (four optional integration skips, no failures/core warnings), both owned Release app/widgets build and Mac executables are universal. Four isolated phone and four tablet user flows pass, including full-phrase decline at largest text, invalid-date preservation and completion/relaunch. The owned Mac UI walk compiles with the established distribution entitlements; Mac interaction and provisioned widget acceptance remain unexecuted. [Detailed evidence and remaining gates](P0_IMPLEMENTATION.md#6-october--named-dates-deadlines-and-repeat-boundaries) preserves the full P0 objective, independent reminder recurrence, richer grammar, filter keyboard warning and paired/physical/provider/widget/distribution requirements.


## 6 October — saved-filter usability checkpoint

Filter validation now appears beside the corresponding input, and board columns scroll independently and widen in short windows so lower cards can be opened and completed. Native Mac app/widget Release and the new lower-card/relaunch UI test compile; Mac interaction remains pending while the desktop is locked. No installed app was replaced or opened. [Current evidence and remaining gates](P0_IMPLEMENTATION.md#6-october--saved-filter-keyboard-feedback-and-board-usability) distinguish iPhone/iPad runtime checks from Mac compilation. Each repo owns its own implementation and release inputs.


## 6 October — keyword filters and preserved unsupported queries

Mac independently owns keyword search, repeating-task, no-planned-time/no-label builder choices, stable project/label shorthands and strict metadata values. Unsupported saved documents stay intact with editing disabled; they cannot silently become Today. Both repos pass 420 Debug/optimized tests (four optional integration skips), authenticated REST stub body/readback and widget/backup privacy/remap checks. The independent unsigned app/widget Release builds pass; Mac executables are universal, and its new native user walk compiles only. [Detailed evidence](P0_IMPLEMENTATION.md#6-october--keyword-and-metadata-filters-with-query-preservation) and the [remaining filter port plan](TODOIST_PORT_PLAN.md#saved-filter-query-extension--6-october) retain actual paired/offline/account/revocation and locked Mac runtime gates. No installed Mac app was opened or replaced. Full P0, provisioned widgets/distribution and remote-delivery acceptance remain active.

The final Unicode correction preserves combining scalars beside spaces, quotes, colons and target prefixes in both owned parsers. Final 420-test Debug/optimized suites, app/widget builds and Mac test compilation pass. Keyword builder/expression/relaunch runs pass again on phone and tablet with zero runtime warnings; the other three native scenarios per device retain their recorded evidence with unchanged UI/preservation code. Exact isolated tablet-cache inspection also confirms the original unsupported document/value and no queued rewrite. See the checkpoint above for all remaining acceptance gates.

### 6 October — explicit date sources and relative saved filters

Mac independently owns planned-date comparisons, plan-first/deadline-fallback comparisons, relative civil-day phrases and native builder/inline validation. Existing saved planned-only predicates retain their meaning. Both packages pass 429 Debug/optimized tests (four optional integration skips); date-source/relative/backup/cache/widget regression checks and owned app/widget/UI-test compilation pass. Final phone and tablet bundles pass all three methods each, zero failures/skips/runtime warnings. Both own unsigned Release app/widget builds pass; Mac app/widgets are universal and its new UI walk compiles only. Real-user checks and screenshot review also produce shorter All/Any/date labels, compact date feedback and expandable syntax help. [Detailed evidence](P0_IMPLEMENTATION.md#6-october--explicit-date-sources-and-relative-civil-day-filters) and [compatibility/remaining filter work](TODOIST_PORT_PLAN.md#civil-day-date-sources--6-october) retain actual signed-in paired/offline/account/revocation and locked Mac runtime gates, full P0 and physical/provisioned/remote-delivery acceptance. No installed Mac app was opened or replaced.


## 6 October: observable civil-day refresh

Both independently owned native apps now observe the viewer's Gregorian day and time zone for open lists, saved-filter previews, capture defaults and date grouping. Clock notifications and foreground activation refresh synchronously; active timers follow civil midnight, restart on changed day/zone and provide a bounded fallback. Task/source-zone/query/queue/history data stay unchanged. Each core passes 432 Debug/optimized tests (four optional integration skips); own app/widget Release and native UI-test builds pass, with universal Mac binaries. Final phone and tablet bundles pass both clock-event walks with zero failures/skips/runtime warnings, and six unmodified screenshots record the visible membership/preview transitions. [Evidence and limits](P0_IMPLEMENTATION.md#6-october--observable-civil-day-refresh-in-native-views) and the [remaining filter plan](TODOIST_PORT_PLAN.md#civil-day-date-sources--6-october) retain Mac runtime, actual paired/offline/account/revocation/restore and installed/physical/distribution gates. No installed Mac app was opened or replaced. Full P0, richer filters, independent recurring reminders and remote-delivery work remain active.


## 7 October — independent calendar reminders

Mac independently owns version-2 local calendar reminders, native Repeats editing, `!every` capture/suggestions, retained source-clock/anchor/count semantics and historical notification/snooze validation. Undated tasks remain undated. Compact When labels, a separate wall-clock picker, wrapped rule summary, source-zone next preview and clear invalid-rule feedback preserve the native editor’s usability. Counts describe occurrences total from the original start.

Both own packages pass 443 Debug/optimized tests (four optional integration skips), own app/widget Release and native UI-test builds pass, and the real authenticated-role calendar-JSON transport fixture rolls back cleanly. Phone seven-method/tablet three-method Simulator runs pass, including actual phone background local delivery; final count-label editor runs are tracked in [detailed evidence](P0_IMPLEMENTATION.md#7-october--independent-calendar-reminder-schedules). Mac’s new editor/autosave/relaunch walk compiles only; no Mac GUI or installed app replacement occurs. Each repo owns its implementation/release inputs. Full P0, native paired/offline/account/revocation, physical/provisioned widgets/distribution and remote provider/authority/calendar-projection acceptance remain active.


## 7 October — calendar reminder parity and backend projection

Mac independently owns the civil-day/count/anchor correction, editor start-day retention and 33 native/SQL calendar fixtures. Both cores pass 445 Debug/optimized tests (four optional integration skips); own Release app/widgets and native UI-test targets build, with universal Mac binaries. The disabled v6 provider worker and six exact deployed migrations support bounded version-2/r5 projection. Whole-account/cohort, authority/opt-in/provider/physical and actual paired/Mac runtime acceptance remain open. [Detailed evidence](P0_IMPLEMENTATION.md#7-october--portable-civil-day-and-backend-reminder-validation). No installed Mac app was opened or replaced; full P0 stays active.


## 7 October — scheduled time filters and native accessibility acceptance

The independently owned Mac builder/expression engine now supports clock at/before/after and explicit planned/effective-due dated-clock boundaries, compatible with the iOS-owned implementation. Inline help stays concise and distinguishes minute/day boundaries and timed versus deadline-only work. Queues, backups and private widget membership preserve the canonical contract; date-only queries retain their meaning. [Behavior and rollout](SCHEDULED_TIME_FILTERS.md).

Both own Core packages pass 453 Debug/optimized tests (four optional integration skips, zero failures/core warnings). Final Release app/widget builds and UI-test compilation pass; Mac app and extension are universal. Four phone and four tablet scenarios pass against the final source, including dark largest text, exact results, validation, editing and relaunch. Six unmodified iOS/iPadOS PNGs per repository and exact bundle/log/input-manifest evidence are recorded in [the checkpoint](P0_IMPLEMENTATION.md#7-october--scheduled-clocks-and-explicit-date-at-time-filters).

Mac interaction remains compile-only under the no-GUI constraint. Installed Mac app, provider/backend settings and public distribution were not changed. Actual paired/offline/account/restore/revocation, physical/provisioned widgets, provider acceptance, richer/ordered/sliding filters and reminder delivery/preferences gates remain; the full P0 goal stays active.


## 7 October — readable planner and reachable scheduling

Mac independently owns inline bounded estimate feedback, Save gating and a readable agenda at accessibility text sizes. Task opening, schedule, completion and adjustment reuse the existing durable mutations and undo; the graphical timeline remains available. Native Mac calendar chrome is preserved. Its new estimate validation/Cancel/relaunch walk compiles only while Mac runtime remains restricted. Both own app/widget Release and native test-target builds pass, with universal Mac binaries; each planner core suite passes 10 tests. Final native phone/tablet acceptance, screenshots and the full remaining P0 gates are recorded in [detailed evidence](P0_IMPLEMENTATION.md#7-october--readable-planner-and-reachable-scheduling). No installed Mac app was opened or replaced. Full P0 and actual paired/provider/physical/widget/distribution acceptance remain active.


## 7 October — My list host evidence and signing prerequisite

Both own packages pass 68 widget-related tests. Each repo now owns a compiled-widget metadata and optional signing-team check. The installed iPhone walk reaches the real gallery, list choices and saved project, but linkd rejects its ad hoc app/widget identity and leaves the timeline unconfigured even after an isolated restart. Those native screenshots establish picker evidence only. The speculative source restructuring was discarded; native app/widget behavior and independently owned release inputs retain the preceding implementation. [Detailed evidence and final compilation checks](P0_IMPLEMENTATION.md#7-october--installed-my-list-picker-and-signing-diagnosis) retain provisioned/physical hosts, task routing/completion, independent instances and actual Mac/paired runtime gates. No Mac GUI or installed app replacement occurs. Full P0 remains active.

### 7 October: recorded creation-date filters

Mac owns Created on/before/after controls, canonical query fields, relative negative-day syntax and exact creation-only validation feedback, with the matching iOS implementation in its own repo. Both 460-test Debug packages and 84-test optimized filter/backup/widget suites pass. Mac unsigned universal app/extension Release and native UI-test compilation pass. [Contract](CREATION_DATE_FILTERS.md) and [P0 evidence](P0_IMPLEMENTATION.md#7-october--creation-date-filters-and-precise-feedback) preserve the distinction between local builds/fixtures and installed, paired-account or Mac runtime acceptance. Hierarchy, wildcard/collaboration queries, sliding time windows, ordered sections and native parity gates remain open.


## 7 October — wrapping task metadata and complete filter labels

Mac independently owns adaptive compact/wrapped task metadata, a full selected condition label at accessibility sizes and one complete accessible query-feedback message, preserving native selection colors, task actions and persistent contracts. Own unsigned universal app/widget Release and native test-target compilation pass. Eight distinct phone/tablet filter scenarios pass against the corresponding iOS presentation inputs; final helper regressions add two successful reruns. [Detailed checkpoint](P0_IMPLEMENTATION.md#7-october--full-deadline-and-filter-labels-at-large-text) records the iOS phone/tablet user-flow checks, screenshots, diagnostic failures and final verification separately from Mac compilation. Mac runtime and the broader P0/paired/provider/provisioned-widget acceptance gates remain active.


## 7 October — useful Focus selection in a large workspace

Mac independently owns a searchable native task sheet with full project/section/parent context, notes search, deterministic natural ordering, accessible selection and stale-generation Start gating. Selected/current/conflicting sessions retain readable context; Cancel keeps the prior choice. Both owned 467-test Core suites and 38-test optimized Focus checks pass, and own app/widget Release and native test compilation pass, with universal Mac binaries. Eight iOS/iPadOS search/Cancel/relaunch/recreation/timer user flows pass against final production inputs. After fixture-simulator reboot, the unchanged native landscape walk passes on phone/tablet too, bringing distinct successful flows to ten; earlier whole bundles retain historical orientation failures. [Detailed evidence](P0_IMPLEMENTATION.md#7-october--searchable-focus-task-selection) and the [Focus contract](FOCUS_SESSIONS.md#searchable-task-selection) keep runtime/build evidence separate. No Mac GUI or installed Mac replacement occurs; full P0, actual paired-account, native Mac, provisioned/physical widget/provider and distribution gates remain active.

## 7 October — full-device calendar projection budget

Mac independently owns the deployed private-zone-cache/bounded-history migration and actual-role cohort fixtures. Both owned eight-suite SQL sets and 35-test credential-free worker scripts pass. The five-zone 160-task/3,010-setting case queues exactly 30 calendar occurrences per device, retries without duplicates, excludes inactive/foreign recipients and completes every whole-device call below four seconds. [Detailed evidence](P0_IMPLEMENTATION.md#7-october--whole-account-calendar-reminder-budget) distinguishes this fixture from production-volume or OS/provider acceptance. Native sources and worker v6 are unchanged; no Mac GUI, installed replacement, delivery activation or release occurs. Full P0 and all remote authority/opt-in, physical/paired/Mac/provider/widget/distribution and operational gates remain active.


## 7 October: synchronized configurable snooze and native usability

Both independently owned apps now persist an account/workspace snooze delay, queue offline edits, subscribe to preference changes and include settings in portable recovery. Notification actions carry the displayed delay; existing snoozes retain their exact fire instant and legacy one-hour actions remain supported. The deployed `20261007065249_reminder_snooze_preferences` migration uses owner-only RLS and a semantic, row-locking update that preserves current extension metadata and rejects future-version downgrades. See [behavior and compatibility](REMINDER_SNOOZE.md).

Each app-owned core suite passes 477 tests with four optional live-account skips and zero failures. Each deployed owner/outsider SQL suite passes and rolls back; separate checks show zero fixture accounts/preferences and inactive `taskfold-native-reminder-sweep`. The final Debug app/widget/UI-test-target compilation and unsigned Release app/widget build pass for each platform. Mac Release is universal x86_64/arm64; no Mac runtime was opened. Each owned compiled catalogue verifier passes eight configurations, three entities, six enums and completion metadata.

The first native walk found a 34.5-point iPad picker target, corrected to a full-width menu with a minimum 44-point target. Screenshot review found inherited faint accent text, corrected to neutral primary/secondary text with an accent chevron. All four final user walks pass on iPhone 17 Pro and iPad Pro 11-inch (M5), iOS 26.5: light and dark largest text, delay selection and relaunch retention. The earlier row lookup failure was a test selector corrected to the existing settings accessibility identifier. Final result bundles are `/tmp/taskfold-snooze-phone-neutral.xcresult` and `/tmp/taskfold-snooze-ipad-neutral.xcresult`. Inspected screenshots are retained in the iOS repo's `docs/p0-previews/` as `ios-snooze-light.png`, `ios-snooze-dark-largest.png`, `ipad-snooze-light.png`, and `ipad-snooze-dark-largest.png`. Backup preview now names the added data as Reminder preferences.

The account table adds one expected authenticated GraphQL schema-discovery finding; anonymous discovery and other security/performance baseline counts remain unchanged. Owner/outsider tests verify actual row isolation. [Remediation reference](https://supabase.com/docs/guides/database/database-linter?lint=0027_pg_graphql_authenticated_table_exposed). Full P0 remains in progress: paired native/offline/account/access-revocation/restore, Mac runtime, notification-category/OS action and physical/background/remote provider acceptance, and provisioned widget hosts remain open. These tests do not prove those broader gates.


### 7 October — Simulator system snooze acceptance

The corresponding iOS implementation now passes six final phone/tablet user flows: light and largest-text settings/relaunch, plus actual OS 5-minute snooze actions, retained delivery after relaunch/settings changes, current 15-minute actions and correct task opening. [Detailed acceptance](REMINDER_SNOOZE.md#7-october--actual-system-snooze-action-and-retained-delivery) and own retained evidence distinguish iOS/iPadOS runtime from previous Mac compilation. Mac production sources and release inputs are unchanged. Physical/provisioned and cold-process delivery, paired native account/offline/restore, Mac runtime, remote authority/APNs/provider and broader full P0 gates remain open.


### 7 October — saved startup actions and closed-app local delivery

Both independently owned app delegates register the saved snooze choice at launch. Two final iOS 26.5 phone/tablet Simulator walks pass with the app terminated before both original and retained delivery; actual OS actions and task opening start new processes without test arguments. [Closed-app contract and evidence](REMINDER_SNOOZE.md#closed-app-notification-acceptance--7-october) distinguishes runtime acceptance from own universal Mac compilation. Physical/provisioned/locked, actual paired account/offline/restore, Mac runtime, remote/APNs/provider and broader P0 gates remain open. No Mac GUI or installed replacement occurs.


## 7 October — automatic timed-task reminder defaults

Each native repo now owns account-synced timed defaults, captured as ordinary
relative task reminders, with preserved manual choices/snoozes and semantic
offline preference replay. [Behavior and release contract](AUTOMATIC_REMINDERS.md).
Own Core suite: 487 tests, four existing environment skips, zero failures. Both
actual-role preference SQL fixture suites pass and roll back. Own Release and
Debug app/widget/test-target compile checks pass; the Mac executable contains
x86_64 and arm64. Six final isolated phone/tablet flows pass, including actual UN
trigger offset, capture/custom/off, retained task/fire instant, relaunch and
light/dark largest text. Four inspected, unmodified native captures and scoped
evidence are retained independently. Mac GUI and paired/physical/provider
acceptance remain open; full P0 is still in progress.


## 7 October — per-device delivery handoff

Both independently owned apps now implement explicit per-device consent, serialized local drain, nonce/cutoff activation, durable pending/offline/restart recovery and exact off/retirement confirmation before future local originals resume. Missing or mismatched secure installation/consent state fails closed. Existing snoozes and Focus stay local; consent is excluded from workspaces and backups. The two authority migrations are deployed with availability false and no pilots. Each owned Core suite passes 501 tests with four existing optional integration skips; ten owned actual-role SQL suites pass and roll back. Owned Release app/widget and Debug app/widget/test-target compilation passes, including both Mac architectures. See [contract, scoped verification and rollout gates](REMINDER_AUTHORITY.md). Eight final isolated iOS Simulator flows pass across iPhone and iPad, including handoff/relaunch/lost-response recovery and light/maximum-accessibility-dark presentation; this does not establish Mac runtime or real provider/paired-device acceptance. Provider ambiguity/privacy, provisioned/physical/Mac runtime, paired/offline/access-revocation, reinstall management and production-volume/operations acceptance remain open. Full P0 remains in progress.


## 7 October — dynamic name-pattern filters

Both independently owned apps now support project, section and label name patterns in the builder and expression editor, including `%home*`, `#*Work`, `/*Calls*` and explicit matching forms for spaces. Exact target conditions retain stored identities. Results follow the available account catalog through renames/new matches, reject unavailable references under negation/OR, and use the same catalog in app lists and eight-day private widget projections. Offline encoding and portable backup preserve patterns while exact target IDs remap. [Contract and compatibility](NAME_PATTERN_FILTERS.md).

Each own Core suite passes 508 tests with four existing optional integration skips and zero failures; optimized FilterTests/BackupTests passes 79 tests without skips/failures. Each owned actual-role SQL persistence/RLS fixture passes and rolls back to zero fixture users/views; JWT claims are simulated SQL authorization context, not native sign-in. No backend schema, RLS, provider or rollout changes were made. Own unsigned Release app/widget and Debug UI-test-target compilation pass; Mac Release contains x86_64 and arm64. Native app/widget capture bytes match the final inputs; the corrected iOS test-menu selector is separately captured/compiled and does not change Release app/widget inputs.

Four final isolated iOS 26.5 Simulator flows pass: light and dark Accessibility XXXL on iPhone 17 Pro and iPad Pro 11-inch (M5). They verify builder selection, blank-pattern Save rejection, exact project results, expression round trip, combined label/section results (including a legacy label alias), and persistence after process relaunch without fixture reinjection. Twelve unmodified captures are inspected and retained in `name-patterns/final/`. Largest text uses native scrolling: the phone builder capture shows a lower form viewport rather than the selected pattern; expression and result captures show the actual expression and two matching tasks. Long list titles truncate at this size. Functional assertions establish the selected condition. These captures are scoped evidence, not a full surface or VoiceOver audit. [Owned input hashes](name-pattern-inputs-sha256.json) and [evidence](name-pattern-evidence.json).

Initial selector failures and the terminal SDK-cache disk-space build failure remain preserved as diagnostics; final green runs supersede them. Mac GUI/runtime remains unrun. Actual paired-account/offline/access-revocation/restore, provisioned widget hosts, physical devices, remaining query grammar/hierarchy/named assignees/ordered query sections, and full P0 acceptance remain open.

## 7 October — assignment filters and readable condition choices

Both independently owned apps now support Assigned, Others and exact accepted collaborator names/emails. Named references resolve to stable identities; unknown or ambiguous names reject Save. Me/Unassigned/UUID conditions retain their meanings. Missing viewer identity excludes Me/Others even under NOT/OR. The same AST survives account-cache/queue encoding, widget membership and portable backup. [Contract](ASSIGNMENT_FILTERS.md).

All 45 conditions remain available once each in nine groups. Standard text uses shorter native menus in a fixed order. Accessibility text uses a navigated, scrollable chooser with wrapping labels and one Cancel action; condition rows use the native navigation arrow. This resolves clipped popup selection and duplicate controls found during native user-flow review.

Each own Core suite passes 512 tests with four existing optional integration skips and zero failures. Each owned actual-role SQL fixture passes and rolls back to zero fixture users/views; SQL JWT claims simulate authorization context, not native sign-in. Own unsigned Release app/widget and Debug UI-test-target compilation pass; Mac Release contains x86_64 and arm64. Core/SQL source bytes remain unchanged through native UI polish. No schema, policy, provider or rollout change is made.

All ten final isolated iOS 26.5 Simulator flows pass: five on iPhone 17 Pro and five on iPad Pro 11-inch (M5), zero failures/skips. Assignment and name-pattern cases cover light/dark Accessibility XXXL and relaunch persistence; the light keyword regression also passes. Fourteen unmodified final assignment captures are inspected and retained in `assignments/final/`. Largest text uses ordinary scrolling and partial viewports; long list titles can truncate. These checks do not constitute full VoiceOver or Mac GUI acceptance. Final runtime/capture evidence is recorded in [the evidence record](assignment-evidence.json), with independently owned [input hashes](assignment-inputs-sha256.json). Mac GUI runtime remains unrun. Real paired native online/offline/member-revocation/restore, physical/provisioned widgets, VoiceOver/full-surface acceptance, dynamic person-name patterns, assigned-by metadata, shared/personal scopes, hierarchy, remaining grammar and full P0 acceptance remain open.

## 7 October — ordered query sections

Both independently owned apps now accept top-level comma queries and render ordered separate lists/board columns, including overlapping tasks and empty query feedback. Completion visibility stays within each query; bulk actions and widget memberships remain unique. Canonical query identities retain manual order through query reordering and target renames. Restore remaps query/order/project/task identities while preserving Inbox’s sentinel. [Contract](QUERY_SECTIONS.md).

Each own Core suite passes 518 tests with four existing optional integration skips and zero failures. Owned actual-role SQL fixtures pass and roll back; no schema, policy, provider or rollout changes are made. Own unsigned Debug and Release builds pass; Mac Release contains both architectures. All eight final isolated iOS Simulator flows pass (four per device), including light/dark largest-text assignment regressions and query list/board completion/relaunch. Twelve unmodified query captures are visually inspected and retained independently. The expression input now precedes its shorter hint; accessibility boards widen and assignment headings describe states/names without changing stored identities. Scrolling/partial viewports, long navigation-title truncation and long expression-term wrapping remain at largest phone text. [The evidence record](query-sections-evidence.json) and owned input hashes scope these checks. Mac GUI, real paired native online/offline/member-revocation/restore, physical/provisioned widgets, VoiceOver/full-surface and full P0 acceptance remain open.


## 7 October — native Todoist import review

Both independently owned apps bind previews to the exact token/workspace, validate all six preview and ten receipt counts, show unsupported-data warnings before Import, and retain source-bound retry after an uncertain save response. Token editing is disabled while requesting; success clears it. iOS provides keyboard dismissal and an input-first form. [Contract](TODOIST_IMPORT_REVIEW.md).

Each own Core suite passes 524 tests with four existing optional integration skips and zero failures, including six new import regressions. Each owned rolled-back receipt SQL fixture passes under owner/foreign/anonymous roles and leaves zero fixture users/tasks/source mappings. Own unsigned Debug and Release builds pass; Mac Release contains x86_64 and arm64. The final Mac UI test compiles but is unrun because Mac GUI/runtime is prohibited. No schema, authorization policy, provider or rollout changes are made.

All four final isolated iOS 26.5 Simulator response-fixture walks pass: light standard text and dark Accessibility XXXL on iPhone 17 Pro and iPad Pro 11-inch (M5), zero failures/skips. Sixteen unmodified captures are visually inspected and retained independently in `todoist-import/final/`. The walks cover short/rejected tokens, malformed preview, warnings before action, lost-response retry, readable confirmed receipt, token clearing and empty reopening. Largest phone text uses scrolling/partial viewports and its initial large navigation title truncates. Each device summary records two source-unlocated “Invalid frame dimension” warnings at initial import navigation; their cause remains unresolved, so runtime is not described as warning-free. Earlier failures, source cohorts, process samples, logs and results remain preserved. [Evidence](todoist-import-review-evidence.json) records exact source/build/test/capture provenance.

These response fixtures never call Todoist or import task data. Actual source-ID replay/edit preservation comes from the separate current SQL fixture, not the native UI walk. The currently observed edge function is active version 41; historical version-39 evidence remains historical. Real isolated provider-account preview/import/retry and native persistence, paired/offline/member-revocation/restore, physical/provisioned widgets, Mac runtime, full VoiceOver/surface acceptance and full P0 remain open.


## 7 October — strict planned clocks and noon/midnight

Both repositories independently validate whole clock phrases, preserve invalid/ambiguous phrases as title text with feedback, and prevent explicit and elapsed clocks from overwriting their displayed chips. Noon/midnight capture, cursor suggestions and independent reminder shortcuts save existing canonical `HH:mm` values. Declined, quoted and escaped text stays literal; valid existing plans/deadlines and recurrence remain compatible. At this earlier checkpoint, same-day time-only behavior was retained; the natural-clock checkpoint below supersedes it with next-day rollover. Richer grammar remains open. [Contract](STRICT_CLOCK_CAPTURE.md).

Each own Core suite passes 532 tests with four optional integration skips and zero failures. Own unsigned Debug/Release builds pass; Mac Release includes x86_64/arm64 and its UI test compiles without runtime. All four final isolated iPhone/iPad light/dark-largest capture/save/More/decline/relaunch walks pass, zero failures/skips and no runtime warnings in these result summaries. Twelve inspected unmodified captures and bounded exact fixture-record evidence are retained. Application/Core/widget/Release bytes remain unchanged through UI-test-only fixture and scrolling corrections; those earlier failures, sources, products and results are preserved. [Evidence](strict-clock-evidence.json).

Largest phone text requires scrolling and the time-zone chooser truncates; horizontal chips/toolbars and largest iPad editor captures use partial viewports. No schema, authorization policy, provider or rollout changes are made. Mac GUI, actual paired native account/offline/member-revocation/restore, physical/provisioned widgets/delivery, VoiceOver/full-surface, richer grammar and full P0 acceptance remain open.


## 7 October — natural periods and next-day time-only capture

Both repositories independently accept morning (09:00), afternoon (12:00), evening (19:00) and night (22:00), with exact removable phrases and cursor suggestions. A passed time-only clock derives tomorrow in the planning/source zone; its chip identifies that day and declining it removes both derived fields. Existing valid plans, context defaults, explicit dates and accepted repeat first dates retain their meaning. Independent reminder period aliases retain their existing specification and future/anchor rules. Gregorian/DST/travel, invalid/quoted/escaped/declined text and ambiguity regressions pass. [Contract](NATURAL_CLOCK_CAPTURE.md).

Each own Debug and optimized Core suite completes 540 tests with four optional integration skips and zero failures. Own unsigned Debug/Release native builds pass; Mac Release contains x86_64/arm64 and Mac UI tests compile without prohibited runtime. All four final isolated iOS 26.5 iPhone 17 Pro/iPad Pro 11-inch (M5) light/standard and dark/Accessibility XXXL walks pass, zero failures/skips and no warnings in these result summaries. Twenty unmodified captures are inspected and retained independently, with bounded exact four final dark-case task records per device proving morning/next-midnight dates and literal unplanned retention. [Evidence](natural-clock-evidence.json).

Screenshot inspection caught wrapped chip text escaping its capsule despite passing walks; the initial height attempt also failed visual review. Both cohorts are preserved. Final iOS chips retain full single-line width in the horizontal scroll area, and final editor capture scrolling differs by device. Core and Mac native bytes remain unchanged through those iOS-only corrections. Horizontal controls/editor surfaces use partial viewports; the time-zone chooser truncates. This does not close full-surface/VoiceOver acceptance. No schema, policy, provider, rollout or sibling dependency changes are made. Richer grammar, real paired native account/offline/member-revocation/restore, Mac runtime, physical/provisioned widgets/delivery, distribution and full P0 remain open.


## 8 October — elapsed-time saved-filter windows

Independent native minute/hour references, foreground minute refresh and expiring widget projections are implemented. The existing version-1 document retains relative values; legacy civil-day predicates retain their meaning. Each own Debug/optimized Core suite passes 548 tests (four optional skips); unsigned native builds pass and Mac Release is universal. Four final isolated iOS walks and 24 inspected actual captures provide scoped native evidence; Mac UI tests compile without runtime. See [ELAPSED_FILTER_WINDOWS.md](ELAPSED_FILTER_WINDOWS.md), [evidence](clock-window-evidence.json) and [visual limits](clock-window-visual-review.json). Generic out-of-range feedback remains polish. Next-week/weekend preferences, hierarchy/collaboration grammar, real paired/mixed-version account acceptance, Mac runtime, provisioned hosts, delivery and distribution remain open; full P0 is active.


## 8 October — account-owned date phrase preferences

Independent iOS/macOS settings now define `next week`, `this weekend` and `next weekend`. Capture/deadline/repeat/reminder previews, rescheduling, relative filters, cache keys, grouping, widget results and backups use the same bounded version-1 preference. Accepted task dates remain concrete. Unsupported preferences fail closed; workspace bindings prevent stale settings edits. The nullable migration is deployed and the rollback-only owner/foreign/anonymous SQL fixture passes with zero retained users; existing advisor findings remain unchanged.

Each own Debug/optimized Core suite passes 556 tests (four optional integration skips), and unsigned native Debug/Release builds pass; Mac Release app/extension are universal. All four final isolated iPhone/iPad light-standard and dark-largest user walks pass. All 32 actual captures are inspected, with exact fixture-cache evidence for persistent choices/queries and fixed task dates. Mac UI tests compile without runtime. [Contract](DATE_PHRASE_PREFERENCES.md), [evidence](date-preferences-evidence.json), [visual limits](date-preferences-visual-review.json), [backend scope](date-preferences-backend-evidence.json).

Earlier test navigation/lazy-row failures are retained. The `this we` suggestion regression was reproduced and fixed. One verification-log filename collision is documented; a fresh full iOS Debug Core run passes with its distinct retained log. Largest settings/capture viewports require scrolling and the largest phone filter title truncates. Account preferences are implemented; configurable calendar week start, broader hierarchy/collaboration/natural grammar, real paired/mixed-version acceptance, Mac runtime, full-surface/VoiceOver, provisioned hosts, delivery and distribution remain open. Full P0 remains active.


## 8 October — Assigned-name filters: source checkpoint, storage gate

Both native repositories independently implement `assigned to: M* Smith` and explicit `assignee matching:"M* Smith"`, with an Assigned name matches builder condition. Exact quoted names/emails retain stable identity resolution. Current accepted names are bound to the task’s project directory; unknown, placeholder, malformed or oversized names stay excluded under NOT/OR. Cache keys, grouped results, private widget ID projections, offline query storage and backup restoration preserve those semantics. No backend migration was required; the own rollback-only SQL-role saved-view/RLS fixture passed and left zero fixture users/views.

**Current source:** each Debug Core suite completed 565 tests, four optional integration skips and zero failures. Optimized Core compilation and all four native builds terminated on `No space left on device`; logs and partial products are retained and not counted as passes. Earlier 564-test matrices/native builds passed before the final project-scoping correction. Earlier phone/tablet cohorts each passed dark-largest and failed the standard case on a test’s incorrect empty-default expectation. The corrected final walk explicitly clears the default `*`, verifies count/results/invalid feedback and relaunch, but has not run against the last source correction. No final visual/VoiceOver or Mac runtime acceptance is claimed.

[Contract, exact evidence and remaining acceptance](ASSIGNEE_NAME_FILTERS.md) records the retained source manifests, regression reproduction, failure cohorts and storage request. These are work-in-progress changes on `codex/assignee-name-filters`, separately in each repository. Release/main promotion and final native walks require additional storage. The full P0 goal remains active, including further hierarchy/shared-personal/assigned-by/date-repeat grammar and the existing paired, provider, physical, provisioned-widget and restricted-Mac acceptance gates.


## 8 October — assigned-name sequential verification follow-up

Current own Debug and optimized Core suites pass 565 tests with four optional integration skips; all four own native builds now pass with two jobs, run sequentially, and Release app/widget binaries include both architectures. The standard-text iPhone walk passes; the largest-text case fails finding the saved filter in Browse after its correct preview. Eight actual unmodified phone captures were individually inspected (six passing standard, two partial largest); tablet acceptance remains pending. Long/repetitive largest-text help, a truncated sort choice and the post-save failure remain usability work. [Current evidence and limits](ASSIGNEE_NAME_FILTERS.md) records storage pressure separately from the unresolved failure cause. Previous failures/artifacts remain intact. No Mac runtime/install/replacement, real paired-account, provider or provisioned-host acceptance is claimed. The feature branches and full P0 remain work in progress; more writable capacity is required before further runtime/build work.


## 8 October — obsolete build-cache pruning

User-authorized retirement of obsolete generated products/compiler/SDK caches reclaimed about 75 GiB, leaving about 77 GiB free. Sources, both repositories, logs/results/captures and current builds remain; protected evidence and current source manifests were checked. [Retention policy and exact receipt](BUILD_ARTIFACT_RETENTION.md) separate historical retired-product paths from retained evidence. Storage is available again; full P0 and the recorded failed-save/native/account/provider acceptance work remain unfinished.


## 8 October — filter save recovery and native visual review

Both own editors retain failed create/edit drafts with local feedback and a retry path; compact matching help and wrapped accessibility sort choices reduce the prior usability gaps. Four isolated phone/tablet standard and dark-largest walks pass, including injected failed writes, create retry, edit cancellation/relaunch and successful persisted edits. All 46 named PNGs were individually inspected. Largest-phone error alerts require scrolling to draft/retry guidance; largest navigation titles truncate. These visual gaps remain polish. Four native builds pass; unchanged Core package inputs retain their 565-test Debug/optimized evidence (four optional skips). Earlier failures and their diagnostic evidence remain. See [contract and scoped evidence](ASSIGNEE_NAME_FILTERS.md). Build caches were reused sequentially after actual terminal states, with distinct logs/results. Mac runtime, real paired/mixed-version and membership HTTP refresh, providers and provisioned/physical hosts remain separate; full P0 is unfinished.

## 8 October — compound civil-date boundaries

Both own cores support bounded day/week offsets such as `1 week after next week` in capture, deadlines, recurrence/calendar-reminder boundaries and relative date filters. Whole-phrase preview/decline/escape handling prevents the anchor leaking into a separate date chip. Preference changes invalidate dependent query caches while accepted task dates stay concrete; private eight-day widget membership uses the same interpretation. Both independent Debug/optimized Core suites pass 577 tests (four optional integration skips, zero failures), and all four native builds pass. Four isolated iPhone/iPad light-standard/dark-largest compound flows pass with relaunch/cache proof and 32 individually reviewed PNGs. Own rollback-only saved-view SQL-role fixtures pass and leave zero fixture users/views. No schema change or Mac runtime. [Contract](DATE_PHRASE_PREFERENCES.md), [evidence](compound-date-evidence.json). Largest capture chip/title viewports and phone navigation titles retain documented visual gaps; full P0 remains active.

## 9 October — readable planning previews

Each native app independently owns a wrapping preview layout. Complete dates, deadlines, estimates, repeats and references can use multiple rows; capture and editor/inspector no longer hide the remaining preview in a horizontal strip. iOS moves destination/planning controls into the draft scroll at accessibility sizes. More options has an explicit hit target, and the full editor provides a focus-aware Hide keyboard bar. Declining a planned date keeps its whole phrase in the name while the independent deadline, estimate and priority still save.

Both own unsigned Debug/Release native builds pass; Release app/widget products include arm64 and x86_64. Current own Core inputs are byte-identical to the recorded 577-test Debug/optimized checks (four optional integration skips, zero failures); no fresh Core execution is claimed. Eight selected native iPhone/iPad tests actually execute and pass, with zero failures/skips/runtime warnings: four compound preference/filter/relaunch cases and four compact/full-editor decline/save/relaunch cases. All 16 exported PNGs were individually inspected. Exact isolated caches retain the declined plan as literal text, no planned date/instant, and the independent 8 October deadline, 25-minute estimate and priority 2. These are DEBUG Simulator fixtures, not user tasks or cloud/paired-account evidence. [Source-bound evidence](readable-capture-evidence.json), [visual review](readable-capture-visual-review.json).

Earlier v28 runs passed functionally but emitted a frame warning during empty-editor presentation. Replacing the keyboard toolbar with the focus-aware safe-area dismissal bar removes that warning in the final v32 phone/tablet results. The earlier results remain retained; the exact cause inside the presentation system is not established. The own `Scripts/verify_ui_result.py` rejects zero selected cases, incorrect counts, failures/skips and runtime warnings by default; positive, zero-case and failing-result controls are recorded.

The final standard iPad compound case passed after repeated 60-second XCTest animation-idle waits. Its task was saved during the delay and a sampled main thread was in the UIKit run loop; the cause remains unproved. The delay and retained diagnostic sample are recorded separately from functional passing counts and do not establish clean performance.

Largest title inputs and long drafts still require scrolling. Ordinary compact controls remain a horizontal strip; the light compact sheet reveals a blurred pink control through its translucent surface. Large navigation titles and adjacent list-row viewports retain documented polish limits. Mac UI tests compile, but no Mac GUI/runtime/install is performed. Full P0 remains unfinished, including broader grammar/calendar week start, full-surface/VoiceOver, real native paired/mixed-version/offline/revocation/restore and Todoist-provider acceptance, provisioned/physical widgets, remote delivery and distribution.


## 9 October — relative day-window filters

Both apps independently implement future/past day ranges for planned dates, effective due and deadlines, with six visual conditions, explicit boundaries, strict counts and preserved older query meaning. Relative counts survive queued saved-view and backup round trips, update with the viewer day/zone, feed private widget day projections and never assign capture dates. [Contract and evidence](DAY_WINDOW_FILTERS.md).

Owned Core: 583 tests per app/configuration, four optional integration skips, zero failures in Debug and optimized builds. Both native Debug/Release builds pass; Release app/widget products contain arm64 and x86_64. Four actual isolated iPhone/iPad cases pass with zero reported runtime warnings, covering light/default and dark/largest editor validation, one-day range results, expression editing and relaunch. All 12 retained screenshots were individually inspected. Wider/past windows and backup/widget projections have Core evidence; Mac interaction and paired native/account/offline/revocation/mixed-version/physical/provider/delivery/distribution acceptance remain open. Largest-title truncation, scrolling and translucent-toolbar underlap remain full-surface polish work. Existing build warnings are preserved, not classified as clean-build acceptance. Full P0 remains active.

## 9 October — authenticated native continuity

The actual iOS phone/tablet login, relaunch and online task-edit round trip now passes with authenticated server checks; the Mac-owned transport independently reads the same edited record in a passing focused live test. The prior login failure was missing Simulator signing entitlements, not a server rejection. Disposable sessions/account/data were removed and verified absent. [Evidence and exact limits](NATIVE_CONTINUITY.md). Mac GUI, offline/concurrent/rich-data workflows and full P0 acceptance remain open.

## 9 October — offline queue and real conflict review

A controlled iOS transport outage now has native proof of a durable queued edit across relaunch, real overlapping server edit, deferral/relaunch and Keep my edit preserving independent tablet notes. Mac-owned transport reads the resulting title/notes. Both apps have clearer network-failure messages and correct singular pending counts, with focused Core checks, final iOS feedback UI verification and Debug app/widget builds passing. [Scope, evidence and remaining gates](NATIVE_CONTINUITY.md). Physical reconnection, Use synced/multiple pending edits, Mac GUI and full P0 acceptance remain open.

## 9 October — installed My list host path and title wrapping

The isolated iOS small My list widget now passes actual project configuration, scoped contents and native task routing with verified development-team signatures. Actual host captures motivated compact wrapping headings and three-line task titles in both independently owned widgets; final iOS and Mac Debug app/widget builds pass. [Exact evidence, Simulator signing prerequisite and remaining gates](WIDGET_HOST_ACCEPTANCE.md). Mac host runtime, physical devices, interactive completion/privacy and full P0 remain open.

## 9 October — release gates clarified and actual iOS completion

The current release-gate summary at the top of [P0_IMPLEMENTATION.md](P0_IMPLEMENTATION.md) distinguishes disabled remote delivery from remaining end-to-end acceptance. It removes stale signing/offline-blocker wording while preserving dated evidence. Actual iOS small My list completion now updates the Home Screen without foregrounding the app, survives relaunch and retains an unrelated open task. This is isolated local, warm/background evidence; no Mac runtime or physical/cold-launch claim. Mac production code is unchanged in this checkpoint; no redundant native/Core rebuild is needed for the documentation update.

The actual system privacy toggle also passes on/off verification, hiding both task/list names and their accessibility labels before restoring them. These are iOS host results; Mac host acceptance remains open.

## 9 October — Mac release artifact integrity and public widget path

Development/public DMGs now have distinct names, and release verification checks the actual read-only mounted payload plus DMG hash, mode and source fingerprint. Public packaging has an archive/export/notarization path requiring existing Developer ID credentials and profiles; it validates the widget, team/App Group, hardened runtime and tickets. Four packaging checks pass, using real disposable signatures/DMGs plus a forced build failure that restores the project and scheme; negative signing preflight also passes. Only an Apple Development identity is installed, so public export/notarization/install remains unproved. No Mac runtime, upload or publication occurred. [Workflow and precise evidence](MAC_RELEASE.md).

## 9 October — Use synced with later offline work

The paired iOS flow now accepts a competing server title without losing a later queued estimate on the same task or independent tablet notes. Both clients drain their durable task queues; the Mac-owned transport reads the same result in a passing focused live test. No Mac GUI/runtime or production code change. Fixture account/sessions/data and private device caches were removed. [Exact evidence and limits](NATIVE_CONTINUITY.md). Broader queues, rich workspace/restore/revocation/mixed-version and full P0 remain open.


## 9 October — real calendar integration and permission guidance

Both apps provide a Settings shortcut and visible permission-recovery instructions. Two final isolated iPhone tests pass against actual EventKit: system denial/Settings opening and local calendar selection/private titles/named titles/relaunch/disconnect. All five retained screenshots were inspected. Final iOS and Mac Debug arm64 app/widget builds pass; Mac runtime remains restricted. The iOS Settings URL opens the Settings root in this Simulator, so successful re-enabling of denied permission remains unverified. The unsuccessful Settings.bundle experiment was removed. Fixture calendar/event counts are zero and scoped permissions were reset. [Exact scope and evidence](CALENDAR_INTEGRATION.md). Physical/external-provider/Mac calendar acceptance and full P0 remain open.


## 9 October — installed widget cold completion

One isolated iPhone Simulator flow now passes actual completion from a terminated app, no foreground transition, unrelated-task preservation and persistence after another relaunch. The Debug Simulator harness preserves its disposable workspace across system launches; production behavior is unchanged. [Evidence and remaining limits](WIDGET_HOST_ACCEPTANCE.md). No Mac runtime or full P0 claim.


## 9 October — recurring widget completion

My list shows planned dates in both apps. One real iPhone Simulator cold-completion flow advances a daily task once, retains its repeat rule and survives relaunch; saved-state inspection confirms no extra occurrence or unrelated change. Final iOS/Mac Debug builds pass; Mac runtime remains unverified. [Evidence](WIDGET_HOST_ACCEPTANCE.md). Full P0 remains active.


## 9 October — real saved-filter continuity

Two signed-in iOS clients pass saved-filter create, rename/query edit and relaunch, with stable server IDs and drained queues. The Mac transport/evaluator reads the same result in one passing live test. All fixture account/session/data/cache/credentials were removed. [Exact evidence and remaining scope](NATIVE_CONTINUITY.md). No Mac runtime or full P0 claim.


## 9 October — synced deletion and accurate empty-filter wording

Native tablet deletion propagates to phone and survives relaunch, preserving the unrelated task and saved filter. Both caches and server IDs agree; the Mac transport reads the same state. Empty saved filters now say No matching tasks in both apps. Five initial and two final iOS checks, one Mac transport check and final native Debug builds pass. Fixture cleanup verified. [Evidence and remaining gates](NATIVE_CONTINUITY.md).


## 9 October — calendar permission recovery

The isolated iPhone Simulator passes actual denial, manual Settings navigation, Full Access confirmation, return/reconnect and disconnect, with zero failures/skips/reported runtime warnings. Screenshots were inspected; the local connected preference is cleared and scoped app permission reset. Test setup now tolerates a previous interrupted connection and removes fixture-reset arguments before permission-related process restart. No production code change or Mac runtime execution. See calendar-integration-evidence.json for exact evidence; physical/provider/Mac acceptance remains open.


## 9 October — offline deletion conflict preservation

Nine isolated native iOS cases and one live Mac transport check pass. Keep task preserves the concurrent title and notes, stable task identity, durable cache agreement and empty queues. Fixture cleanup verified; no production changes or Mac GUI execution. Deletion review currently buries changed contents behind alphabetical empty fields; that UI issue remains open. See docs/NATIVE_CONTINUITY.md (NATIVE_CONTINUITY.md in Mac docs) and offline-deletion-continuity-evidence.json.


## 9 October — changed contents first in deletion review

Both apps prioritize and identify fields changed since deletion. Two final iPhone UI cases pass Keep/Delete and relaunch, asserting changed notes are immediately visible. Both native Debug builds pass; Mac compile only. See deletion-review-evidence.json and the latest NATIVE_CONTINUITY.md entry.


## 9 October — explicit concurrent deletion

Nine native iOS checks and one Mac transport check pass for offline deletion versus a concurrent edit, explicit Delete task after review deferral/relaunch, server/cache agreement and no resurrection on tablet relaunch. No production changes; disposable fixture cleanup verified. See confirmed-deletion-continuity-evidence.json and NATIVE_CONTINUITY.md. Full P0 and Mac runtime remain open.


## 9 October — recurring completion continuity

Five distinct native iOS phases and one Mac transport test pass: a daily completion creates one next occurrence with stable identity, correct next date/count/end rule and retained estimate across phone/tablet relaunches. Server and caches agree; task queues drain. Earlier test-title/viewport failures are documented; fixture cleanup verified. See recurrence-continuity-evidence.json and NATIVE_CONTINUITY.md. No production change or Mac GUI execution.


## 9 October — installed Inbox batch configuration

One isolated iPhone Simulator host test passes five-of-six and all-six labels, actual system configuration and matching native review routes. Screenshots inspected; all eight fixture tasks retained and no pending mutations. Final iOS Debug build/signatures verified; no production source change or Mac execution. See widget-host-evidence.json and WIDGET_HOST_ACCEPTANCE.md for scope and earlier test failures.


## 9 October — offline recovery restore continuity

Seven native iOS cases and one Mac transport test pass for backup, tablet edit, offline recovery restore/restart and reconnection to both clients with original task identity and empty task queues. Screenshots inspected; disposable fixture and device recovery data cleaned up. No production source change or Mac GUI execution. See NATIVE_CONTINUITY.md and restore-continuity-evidence.json for exact scope and remaining gates.


## 9 October — working-week settings continuity

Six accepted native iOS cases and one Mac transport test pass working-week changes across phone/tablet, including offline persistence, reconnection and unchanged clock hours. Test navigation/driver assumption failures are recorded; no production changes. Screenshots inspected and disposable fixture cleaned. See NATIVE_CONTINUITY.md and settings-continuity-evidence.json. Mac GUI and broader settings acceptance remain open.


## 9 October — preserve newer planner settings when editing

Both apps previously rebuilt working_hours from four known fields when saving. This dropped any unknown nested fields and allowed an unsupported document to be overwritten by editable defaults. Both independently owned models now merge validated known fields into the existing supported document, preserving extensions. Unsupported or malformed documents cannot be saved; the settings form explains that Taskfold must be updated and disables Save. Missing preferences still initialize normally. The Store also requires the account/workspace binding captured when the form opened.

Each repository passes all 12 focused planner tests, including preservation through edit, durable cache and portable backup. Two actual isolated iPhone UI cases pass with zero failures/skips/reported warnings: unsupported settings stay read-only after relaunch, and supported extension settings retain a changed weekday. Independent saved-state inspection confirms the extra nested data, hours, weekdays and empty queue. The actual unsupported-state screenshot was inspected. iOS/Mac Debug arm64 app/widget builds pass; no Mac GUI ran. See planner-version-safety-evidence.json.

This fixes a specific mixed-version overwrite risk. It does not establish a live mixed-version pair or account-switch UI flow; the planner capacity display still uses its existing default fallback for unreadable hours outside this settings form. Other settings and full native acceptance remain open.


## 9 October — unavailable capacity for unreadable working hours

This closes the default-capacity fallback limitation recorded in the previous planner-settings checkpoint. Both stores distinguish an absent preference (normal defaults) from an unreadable document (no working hours). Native planners retain task estimates and the timeline, but show Capacity unavailable with update guidance instead of a fabricated working-day budget. Both widget publishers emit an explicit settings state, empty capacity days and no hours. Capacity widgets explain that Taskfold must be updated; other task data remains available.

Each repository passes 21 focused planner/capacity-widget tests, including today/tomorrow decoding without room calculations and retained task/workload data. One actual iPhone UI check passes the unavailable summary, 115 minutes of estimates and read-only settings across relaunch, with no failures/skips/reported warnings. Its screenshot was inspected. The actual App Group payload independently confirms the settings marker, empty days/hours and all four fixture tasks. Both Debug arm64 app/widget builds pass. See capacity-version-safety-evidence.json. Installed capacity-host rendering, Mac GUI, physical devices and a live mixed-version pair remain separate acceptance work.


## 9 October — recover a queued edit after shared-project access is revoked

A live disposable owner/member scenario exposed a production failure: a denied queued task edit aborted synchronization before refreshing project access, leaving the revoked project visible. Both apps now perform authenticated reads after a failed task PATCH/DELETE. Only confirmed absence of the project and its tasks permits recovery. The complete local snapshot is saved in the encrypted recovery vault before inaccessible project mutations are removed and remote state is merged. Unrelated pending edits remain queued; account changes, concurrent local edits, failed reads or failed backup writes prevent this recovery.

The original iPhone regression failed, then passed with the fix: reconnect removed the shared project/task; relaunch kept them absent; Backups & restore opened the Access removed copy in the native restore preview. Independent cache and App Group widget-payload inspection found no revoked content. The owner's server task remained Shared original with no membership. Mac authenticated transport also returned no project/task. Both repositories pass three focused queue/recovery tests and their Debug arm64 app builds. Both disposable accounts, sessions and fixture rows were deleted and verified absent; native fixture cache/vault and temporary credentials were removed. See revoked-project-evidence.json.

Scope: the installed regression covers an existing shared task title edit. Standalone queued task creation, project/section edits, locally moved-out tasks and other membership transitions remain acceptance work. Mac transport/build evidence does not establish the Mac GUI. The restore preview was opened, not applied. One empty-list screenshot was captured during navigation; it is functional evidence, not final visual acceptance.


9 October: revoked-project queue recovery now handles task/section creation, organization edits and move-out history. Six focused tests pass in each owning repo. Missing authenticated evidence, a visible affected record or an unacknowledged new local project preserves the queue. Native coverage remains the earlier existing-task title-edit workflow; see docs/NATIVE_CONTINUITY.md and revoked-project-evidence.json.


## 9 October — shared task creation recovery does not block personal work

A fresh disposable owner/member fixture passed a native offline creation workflow. The member created a shared task through the project creation menu, then a personal Inbox task. Both survived an offline relaunch. Independent cache inspection confirmed exactly two ordered task POSTs, shared first and personal second. After membership revocation, the shared POST was denied, encrypted recovery was created, inaccessible content disappeared across reconnect/relaunch, and the personal task synchronized with its original identity. The durable queue drained. The native recovery preview contained the missing project and both shared tasks while keeping the personal task. It was reviewed, not applied.

Three actual iPhone UI tests passed (login, offline creation, reconnect/recovery), with no skips or reported runtime warnings. The first preparation attempt used the wrong project creation selector and stopped with zero pending edits; the corrected test uses floatingAdd → New task. The server retained only the unchanged owner task and the member's personal task. Two Mac transport tests independently confirmed denied shared reads and the personal task. Final native cache and App Group payload contained only the personal task. The two retained screenshots were inspected. No production code changed in this checkpoint. Both accounts, sessions, profiles and fixture rows were deleted and verified absent; native cache/vault and private credentials were removed.

This adds actual native evidence for a queued shared POST followed by unrelated work. Organization edits, local moves, further membership transitions, Mac GUI and physical hosts remain separate acceptance work. See revoked-project-evidence.json.


## 9 October — independent installed Inbox widget instances

Two small Inbox reset widgets were configured on the isolated iPhone Home Screen. Both initially showed Review 5 of 6. Changing only the second to All Inbox tasks left the first at five; both retained the total six. Both links opened their corresponding native review progress (five left and six left). The initial combined run passed those assertions but failed its final immediate text check after returning Home: SpringBoard stopped exposing widget child accessibility elements while the rendered settings remained intact. Follow-up hierarchy inspection confirmed the containers remained present.

After restarting the isolated Simulator, the configurations still rendered independently. A focused resume test selected the two containers in the previously inspected left-column layout, tapped their review regions and asserted both native batch counts again. It passed, then removed the second widget. The original five-task widget remains. The two clear captures (configured state and after host restart) were inspected and retained; the final route-return capture caught an animation and is not visual acceptance evidence. Native cache inspection retained eight fixture tasks and an empty mutation queue.

Evidence: /tmp/taskfold-inbox-independent-v1.xcresult records successful configuration/routes before its final accessibility assertion failure; /tmp/taskfold-inbox-independent-resume-v5.xcresult contains one passing resumed route/cleanup test, with no skips or reported app runtime warnings. v2/v3/v4 resume attempts diagnosed missing child accessibility elements. SpringBoard animation waits were roughly 60 seconds per edit-menu action. The final iOS build-for-testing passed; production source was unchanged. The committed tests separate configuration from resumed routes rather than claiming a fresh all-green gallery run.

This establishes local small-widget batch independence and matching routes, including retained settings after host restart. It does not establish physical/Mac hosts, cloud/account switching, all widget families, or VoiceOver behavior.


## 9 October — bounded P0 acceptance audit

Reconciled the original acceptance conditions with current retained evidence in [P0_RELEASE_STATUS.md](P0_RELEASE_STATUS.md). The current checklist separates implemented capabilities, locally verifiable native gaps, external release prerequisites and later backlog work. Rich workspace handoff (especially pinned notes and Focus session) is the next missing device-switching workflow; no production source changed. Existing Mac GUI/install restrictions remain in force.


## 9 October — paired pinned-note and Focus continuity

Seven native phone/tablet UI phases passed: login on each device; phone creation of a pinned note and 25-minute Focus session; tablet offline note editing and timer pause across relaunch; reconnect; phone receipt, resume and end; and tablet receipt of the ended session across relaunch. Independent server and cache checks retained the original task/session identities, the complete edited note and empty final queues. Ending Focus left the task open. The offline checkpoint retained exactly two pending mutations while the server remained unchanged.

One Mac authenticated transport test passed against the same final state. This is data-layer evidence, not Mac GUI acceptance. Four inspected screenshots are retained in the iOS native-continuity-previews folder. All disposable backend account/session/profile/task/view/Focus rows were verified absent after cleanup; temporary credentials and scoped device cache/vault files were removed. See note-focus-continuity-evidence.json.

No production source changed. This closes the paired note/timer checkpoint, not the remaining organization/rich-task-field handoff, installed widgets, physical notification delivery, reboot, or Mac runtime requirements.


## 9 October — organized rich-workspace handoff and readable task metadata

The native phone created Handoff studio, its Next steps section, a Launch notes label and one task planned for 4 January 2028 at 09:00, with an independent 5 January deadline, a 25-minute estimate, two explicit before-time reminders and the default planned-time reminder. The project favorite and board layout persisted. The tablet received this workspace, edited the description and estimate to 26 minutes offline, relaunched offline, reconnected and drained its queue. The phone received the changed description and retained both explicit reminders. Authenticated server reads and independent caches confirmed original project/section/label/task IDs and relationships, all task fields, board/favorite records and empty final queues. A Mac authenticated transport test passed against the same workspace without launching the Mac app.

Evidence is composed, not a fresh all-green setup run: two initial login cases passed; the creation test performed the native writes but stopped on a Browse navigation assumption. A resumed configuration test initially skipped the board switch because its accessibility value was empty; the independent server check rejected that state. Corrected configuration, tablet offline and reconnect cases passed. The final phone receive case passed after the test learned to scroll to the off-screen board column using element bounds, avoiding XCTest's invalid hit-point query. The retained result bundles and exact phases are listed in workspace-handoff-evidence.json. No production sync defect was observed in this workflow.

Visual inspection found a real iOS usability defect: planned time, deadline, estimate and project were squeezed into one row, breaking short deadline words over several lines. iOS now uses the existing wrapping layout for these metadata items while retaining the accessibility-size vertical layout. Its final app/widget build and a focused native layout test pass; the inspected narrow-board screenshot shows a readable deadline, date/time, estimate and full project name. The Mac row already uses ViewThatFits with a vertical fallback, so no Mac layout change was necessary; Mac visual acceptance remains open.

The disposable account and private fixture are intentionally retained for the immediately following native export/restore workflow, avoiding repeated setup. They are not real user data and credentials are not committed. Ordering changes, account-switch isolation, full file-picker recovery, Mac GUI and physical delivery remain unproved. Existing note/Focus continuity evidence is reused.


## 9 October — native portable export and cross-account restore

The phone exported its verified rich workspace through the native Files save picker. The resulting 6,223-byte JSON was read independently and transferred byte-for-byte to the isolated tablet's Documents folder. The tablet signed into a second empty disposable account, selected the file through Files, reviewed Add 6 / Update 0 / Keep 0, and applied the restore. The six work records preserved the project/section/label/task relationships, planned time, independent deadline, 26-minute estimate, description, all reminders, favorite and board layout. Cross-account IDs changed consistently; donor records remained unchanged. A native recovery copy and the imported workspace survived relaunch. The repeated file import showed Add 0 / Update 0 / Keep 6 and a disabled Restore 0 records action. Server state stayed unchanged and the receiver queue was empty.

The initial restore UI case reached its success alert but failed its subsequent off-screen recovery-row assertion. A separate corrected scroll/relaunch verification and repeated-import case passed; export and receiver login also passed. This is composed evidence, not a fresh all-green full-driver run. Three actual restore/relaunch/repeat screenshots were inspected and retained. The final iOS build-for-testing passes; no production source changed.

Two Mac tests passed: the actual exported file parses and produces the same mapped IDs as iOS with a zero-change repeat plan, and authenticated transport reads the imported live workspace. No Mac GUI was launched. The test transferred the file between Simulator containers; it does not establish an external file-provider transfer, physical devices, or Mac native file dialogs. See portable-workspace-evidence.json and Scripts/test_portable_workspace_roundtrip.py in the iOS repo.

Both disposable accounts and sessions were deleted. Profiles, projects, sections, tasks, favorites and view settings were verified absent; the two fixture labels required explicit scoped deletion and were then verified absent. Scoped caches, recovery vaults, device export copies and temporary credential files were removed. The source export is retained only with the temporary test result artifacts; no credentials were committed. This completes the local recovery-boundary work package; external Mac/provider gates remain separate.


## 9 October — two installed My list widgets retain distinct selections

The isolated iPhone Home Screen now has two small My list widgets: a saved Widget Inbox filter (query inbox) above the Widget Studio project. Both were configured through the native widget editor. The inspected render shows Unrelated Inbox task only in the first and Sketch widget concept only in the second. Actual widget taps opened those exact native task editors independently. Relaunch completed; a settled post-test Simulator screenshot confirms both selections remain. Independent cache inspection retained both open tasks, the new saved filter and an empty queue.

One resumed configuration/routing UI test passed with zero failures/skips/reported app runtime warnings. The initial setup installed the pair but failed on my incorrect test assumption that My list offers a built-in Inbox entity; its documented choices are projects, labels and saved filters. The corrected test creates the Inbox filter through the app and reuses the installed pair. Full gallery setup was not rerun. The iOS build-for-testing and team-signature verification passed; production source was unchanged. Widget source files are byte-identical in both repositories; this does not establish a Mac host pass.

SpringBoard exposes widget containers without their child text and repeatedly waits about 60 seconds for menu animations. An isolated reboot preserved the widgets but did not remove this host limitation. Routing uses the inspected container positions; screenshots establish rendered contents, not VoiceOver coverage. The test's immediate final screenshot caught a Home animation and is excluded; a later settled simctl capture is retained. See widget-host-evidence.json / independentMyList.

Both My list fixtures remain installed for the next rename/deletion/account checks. The old Inbox reset fixture was removed. Launch with --uitesting without --widget-list-fixture to preserve Widget Inbox. Other sizes, physical/cloud hosts, Mac interaction and account isolation remain open.


## 9 October — installed My list rename, deletion and workspace exit

Three native iPhone Simulator UI cases pass with no skips or reported app runtime warnings. Renaming the selected project updates the installed widget heading and preserves its exact task route. Deleting that project moves both original open tasks into Inbox, surviving app relaunch with an empty queue; the saved Inbox widget updates its count from one to two. WidgetKit clears the removed project entity: that widget shows Choose your list and opens All tasks. This is actual host behavior, not a claim that the retained-missing-entity List unavailable branch ran.

Leaving the local workspace returns to authentication, including after relaunch without test arguments. Both installed widgets remove private list/task names; tapping one returns to sign-in. Independent App Group inspection finds only an empty account and task list in widget.json. Three settled Simulator screenshots were inspected and retained in the iOS repository. The initial rename attempt failed before mutation on an ambiguous Edit selector; the explicit project edit path resolved it. Final build-for-testing and real team-signature verification pass.

No production source changed. These results close the local small-widget rename/deletion/workspace-exit checks, not cloud account A-to-B isolation, other sizes, physical hosts, VoiceOver or Mac GUI acceptance. Both repositories retain the scoped evidence in widget-host-evidence.json / myListLifecycle. The phone is signed out with two empty My list widgets retained; no provider accounts were created.


## 9 October — deadline and time-budget widgets in the installed host

The isolated iPhone installed small Deadline radar and A small window widgets against native-created tasks. Deadline radar opened the missed cutoff first; completing that task refreshed it to today's cutoff. A resumed route/relaunch case passed. The time-budget widget was configured through the system editor for 45 minutes, All open tasks, Client Work. It displays the future 40-minute project task and opens that exact editor before and after app relaunch, excluding unrelated Inbox work. A subsequent missed-deadline task with a longer title becomes first and opens correctly. Three final UI cases pass without skips or reported app runtime warnings; independent cache inspection retains five tasks, one completed, and zero pending mutations.

Actual screenshots exposed two small-widget layout defects: the look-ahead caption truncated, and the task title collapsed to one line despite room for two. Both independently owned widget sources now shorten the small caption and preserve the two-line title height. Inspected after captures show Next 7 days fully and Submit client proposal on two lines with its missed-date badge. Final iOS app/widget test build, team-signature verification and Mac app/widget build pass. No Mac app was launched.

Evidence is composed: the initial deadline run completed the native action but expected Today approval instead of the parser's saved title approval. The initial time-budget run installed the widget but queried an enum menu button as static text. Corrected selectors/expectations resumed existing state; gallery setup was not repeated. SpringBoard menu idle waits remain a host limitation. See widget-host-evidence.json / planningWidgets for result bundles, scoped outcomes and six inspected captures retained in the iOS repo. Other sizes, physical hosts, account switching, VoiceOver and Mac native acceptance remain open.


## 10 October — cloud account isolation and offline queue ownership

A fresh five-phase native iPhone Simulator workflow passes: A login → offline edit/relaunch/sign-out → B login/relaunch → A return/sync → final sign-out/relaunch. Independent authenticated server and cache reads verify one task/project/saved view/favorite per account. A's pending edit remains queued while B is active and drains only on A's return; B's rows remain unchanged. Widget payloads contain only the active account, or nothing after logout.

Two final followups pass against the installed small-window and deadline widgets: both open B's exact task, and final logout clears private content. The small-window title now uses its available two-line height in both repos. iOS navigation paths, tab controllers, presentations and links reset on workspace changes; Mac also clears navigation memory at the generation boundary. This source-observed state-retention gap is independent of earlier blocked Browse taps: an actual failed recording shows an iOS Save Password overlay. Tests handle that prompt when present; the final pass did not log a dismissal.

Seven passing UI cases report no skips or app runtime warnings. One live Mac transport test passes A → B → A with correct ownership; no Mac GUI was launched. Final iOS build/team-signature checks and Mac app/widget build pass. Four inspected screenshots are retained in the iOS repo. Both disposable users/sessions and all seeded public rows were deleted and verified absent; their four scoped caches/vaults and two private credential files were removed. See account-isolation-evidence.json. This closes the tested account boundary, not every widget kind or host. Organization ordering, My list-specific cloud selection behavior, remaining widget hosts and external release gates remain.


## 10 October — native organization reorder controls and whole-move edits

Saved filters had an order_index contract but neither app exposed drag reordering. Both now do: iOS Browse uses its existing Edit mode, and the Mac sidebar supports filter drags. Project/section reorder loops previously called save once per row, producing separate local writes/history entries. All four organization families now build order-only patches and commit the drag once; unchanged positions are omitted, stale/duplicate/incomplete row selections are rejected, and stable ID ties keep independently fetched lists consistent. Section displays and pickers use the same tie-break. Mac favorite drags also register with the native undo manager. This is atomic local persistence, not a multi-row cloud transaction.

Three targeted Core tests pass independently in each repo, covering unrelated/future-field preservation, queued snapshot serialization, whole-move undo/redo, stale/out-of-scope inputs and tied-order determinism. One actual native iPhone UI test passes without skips or reported app runtime warnings: create two filters, drag Second queue above First queue, relaunch, confirm order and open Second queue. Independent cache inspection confirms positions 0/1 and no pending local mutations. The inspected capture is retained in the iOS repo. Final iOS build-for-testing/team signatures and Mac build pass. No Mac GUI was launched and no provider accounts were created. See organization-order-evidence.json. Live cloud ordering and native Mac acceptance remain open.


## 10 October — cloud organization-order round trip

Nine native UI checkpoints pass across isolated iPhone and iPad Simulators: both sign in to one seeded disposable workspace, the phone reorders projects/sections/filters/favorites, the tablet receives that order, changes it offline and relaunches, reconnects, and the phone receives the returned order. Both devices then sign out. Independent authenticated server/cache checks preserve all original identities, names, project descriptions, section relationships and filter documents/settings. Exactly eight order-only PATCH mutations remain durable offline while the server retains the prior order; reconnect drains the queue.

One Mac authenticated transport test reads the final order with the independently owned OrganizationOrder implementation and verifies metadata; no Mac GUI was launched. Final iOS build-for-testing/team-signature checks and Mac build pass. Three actual inspected captures are retained in the iOS repo. Stable accessibility identifiers now distinguish a favorite from its corresponding project row in each app. The ordering implementation was committed in the previous checkpoint.

Evidence is composed: the first phone gesture opened the row context menu; the first tablet gesture missed the handle on its wider row and scrolled. Inspected recordings and server/cache reads confirmed no reorder or pending work at either failed attempt. Corrected cell-edge gestures resumed only the unfinished phases; the original metadata baseline was retained. These are nine passing scoped checkpoints, not a fresh all-green full-driver run. The disposable user, sessions, identity and all seeded public rows were deleted and verified absent. Four scoped caches/vaults and the private credential file were removed; both devices are signed out with empty widget accounts. See organization-order-evidence.json / cloudContinuity and the iOS Scripts/test_organization_order_continuity.py. Cloud ordering is now verified for the paired native iOS clients and Mac transport; native Mac interaction and remaining release gates stay open.


## 10 October — installed Day capacity and Project pulse

An isolated local iPhone Simulator workspace now exercises actual small Day capacity and Project pulse widgets. Native configuration selects Tomorrow and Studio. A fresh installed capacity tap opens Tomorrow's planner with 90 estimated minutes and one unestimated task; enabling the day as a 09:00–17:00 workday yields 6h 30m after estimates, with calendar inclusion off and one overdue task outside the plan. Studio initially contains six tasks, one completed, two completion events, one reopen event and two tasks needing attention.

Native task editing increases the estimate to 95 minutes and completes two tasks. Independent cache/widget projection inspection confirms the same six task identities, three completed, no unestimated planned tasks, one overdue task outside the plan, four completion events, one reopen event and zero pending mutations. A resumed installed-widget checkpoint verifies Studio at 3/6 and Tomorrow at 6h 25m after app relaunch. Small capacity clipping is fixed in both independently owned widget sources: a compact heading keeps the day visible, and the budget qualifier and overdue explanation retain their two-line height. Project pulse's singular attention wording is also corrected.

Evidence is composed. The first post-configuration capacity tap failed; fresh settled taps pass, with no production routing change and no established cause for the initial failure. The first refresh case completed its native edits, then failed on a transient SpringBoard icon index that disappeared before frame sorting. The new query excludes absent elements and a resumed case verifies the durable changed state. These are scoped passing checkpoints, not a fresh all-green full driver. SpringBoard still lacks widget child accessibility text and repeatedly waits a minute on configuration-menu acknowledgement. Actual pixels and native outcomes are used; this is not VoiceOver acceptance. See widget-host-evidence.json / productivityWidgets. Other sizes, devices, cloud/account transitions and native Mac widget hosts remain open.

The native privacy checkpoint also passes without skips or reported app runtime warnings. Inspected hidden/restored captures confirm Studio’s name is hidden while pulse counts remain visible, and capacity details are concealed; both routes retain their updated fixture and both switches restore to false.

Final iOS build-for-testing/team signatures and Mac app/widget build pass. A final installed iPhone checkpoint passes after the singular-copy correction; its inspected capture shows 3/6, “1 needs attention”, Tomorrow 6h 25m and both capacity explanations without clipping. Four scoped native checkpoints pass without skips or reported app runtime warnings. The layout/privacy checkpoint is local only; no provider account was created and no Mac GUI was launched.


## Concurrent recurrence checkpoint — 10 October 2026

Fixed a real duplicate-successor risk when two clients complete the same recurring task. Both review choices now remove an unaccepted local successor insertion after the synced original is completed, retain a confirmed synced occurrence, and preserve later local edits as independent work. Completion review shows seconds and time zone.

Validation: 26 focused Core tests per repository; one authenticated Mac transport test covering different completion days, both review choices and repeated requests; nine composed phone/tablet native checkpoints covering offline completion/relaunch, competing completion review, one unchanged next occurrence, empty queues and sign-out isolation. The first five checkpoints are v1; the last four are v6. Two failed review attempts used the wrong test identifier and performed no resolution; this is not an uninterrupted fresh run. Final app/widget builds pass. See `docs/recurrence-continuity-evidence.json` / `concurrentCompletion` for receipts, inspected captures, cleanup and limits. The disposable account, sessions, tasks/activity and two owner caches were removed. Mac GUI, physical devices and full release acceptance remain open.


## Subtask accessibility and readability — 10 October 2026

Both editors now name each subtask in its completion/reopen action, expose its completion state, and let saved subtask titles wrap. The iOS checkbox has a 44-point target; Mac detail/remove actions identify the item. Two final isolated native phone/tablet tests pass at dark Accessibility XXXL: create two subtasks, complete one, save, terminate/relaunch, verify independent persisted states, then complete the second. Both final captures were inspected. An earlier green phone test still showed truncated titles; that visual defect was fixed before the two final runs. Final iOS/Mac app/widget builds pass.

See `docs/subtask-accessibility-evidence.json` for scoped receipts and source hashes. This verifies the editor semantics, native actions and specific largest-text layout; it does not close full VoiceOver, keyboard, Mac runtime or physical-device acceptance. No real or cloud task data was used.


## Installed Pinned note and medium Focus — 10 October 2026

Two scoped native iPhone Simulator workflows now pass: configure a small pinned note for the same task as a medium Focus session, open the full original instructions, pause, edit notes/rename through the native reader, save/relaunch and resume the original session. Independent payload inspection confirms the original pin/task/session identities, complete original instructions, open task and 25-minute duration are preserved. Settled final host captures show the renamed title, updated note preview, Paused 15:28 and then running 15:20.

The installed small note initially squeezed its title to one line. Both repos now reserve its intended title height and use tighter small-widget spacing; the final two-line title is visually checked. Configuration v1 passed before this layout change; final v3 refresh reused the installed pair. An immediate v1 pause capture still showed a prior running frame and is excluded as pause-render proof. Both final app/widget builds and the signed iOS catalog pass. `docs/widget-host-evidence.json` / `noteAndFocusHosts` records results, inspected captures, source hashes, original/final payloads and limitations.

This closes the scoped small-note/medium-Focus installation, route, edit/relaunch and pause/resume checks. Privacy, other sizes/instances, reboot/cloud-account lifecycle, VoiceOver, physical/iPad and Mac hosts remain open. The isolated phone retains this pair for those follow-ups; no real or cloud data was used. SpringBoard animation acknowledgement waits account for most of the 610-second configuration walk and are not app performance evidence.


## Note/Focus host reboot and cold routes — 10 October 2026

One additional native iPhone Simulator test passes after a real shutdown/boot of the isolated device. Both retained widget configurations survive; each widget opens its correct reader/session with Taskfold asserted not running beforehand. The full edited note and original final instruction remain available. Focus continues the original running session: inspected host/native frames show 9:51 and 09:41 rather than a restarted 25-minute timer. Independent pre/post comparison confirms the entire saved workspace and account/notes/Focus payload are unchanged. The three retained frames were inspected.

`docs/widget-host-evidence.json` / `noteAndFocusHosts` / `rebootColdRoutes` records the test, terminal boot receipt, unchanged-data hashes and input hashes. The existing DEBUG-only exact-bundle cold-launch marker was enabled for the disposable ui-testing account and verified reset to false afterward. The app remains terminated; the installed pair is retained. No production source or Mac runtime changed. Privacy, cloud/account lifecycle, other sizes/instances, expiry, VoiceOver, physical/iPad and Mac hosts remain open.

To repeat, prepare the existing native note/Focus fixture with a running session and at least three minutes remaining. Launch only the isolated `com.dbakp.taskfold.assigneepatterntests` bundle with `--uitesting --widget-cold-launch-testing`, retain its workspace/payload baseline, terminate it, then use `simctl shutdown`, `boot` and terminal-success `bootstatus -b` for the isolated device. Run `testInstalledNoteAndFocusColdRoutesAfterHostReboot()` with the signed test products, require one actual pass, inspect captures and compare saved data. Launch once with `--uitesting` without the cold flag, terminate, and verify the fixture marker is false. Never use a personal account/device for this fixture.
