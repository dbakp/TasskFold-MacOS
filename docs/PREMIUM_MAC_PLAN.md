# Taskfold macOS polish plan

Current release-gate order and external dependencies: [P0_RELEASE_STATUS.md](P0_RELEASE_STATUS.md).

The goal is a calm, fast native Mac app: daily actions should take few steps, navigation should preserve context, and motion should explain changes without disrupting work.

13 October native follow-up: the six-chip capture layout is visually clear; exact project, section, label, deadline, priority and estimate survive normal Quit/relaunch. VoiceOver output remains unaccepted and its off state is restored. See [native capture evidence](mac-capture-layout-native-evidence.json).

13 October widget follow-up: My list now owns the acknowledgement expiry timeline entry; it was mistakenly scheduled by A small window. Both platform extensions and scoped tests pass. Installed automatic expiry is now accepted on phone and Mac My list within the scoped evidence. See [expiry evidence](widget-completion-expiry-evidence.json).

13 October companion acceptance finding: installed iPhone My list selection is not retained in two expiry attempts. Current Mac configuration acceptance remains open; no Mac regression is inferred. See [selection evidence](widget-selection-registration-evidence.json).

13 October companion diagnostic: separate iPhone identity and an isolated host-entity declaration do not resolve selected-list handoff. Diagnostic code was removed; production widget code remains as committed. See [handoff evidence](widget-selection-handoff-evidence.json).

21 October advanced backlog: the agreed P1 acceptance batch is complete. The remaining work is ranked in [P2_PLAN.md](P2_PLAN.md). Portable template files reuse the existing native library and definition preview; file review saves a private definition without creating tasks. Release/provider deferrals remain in force. Exact validation and limits are recorded with each milestone.

21 October share capture: the Mac owns its embedded native share extension and reviewed Shared drafts flow. Account-bound local drafts, create-only task saves and atomic receipts are implemented. Layout/listening and real source-app acceptance remain pending; see [P2_PLAN.md](P2_PLAN.md). No distribution or provider gate is marked complete by these source changes.

21 October note formatting: selection tools and a native readable preview retain portable source text and the existing durable save/Undo path. Core tests pass and the isolated Mac app builds. Native Mac editing, conflict/retry and VoiceOver acceptance remain pending; print/PDF is still planned. See [note evidence](p2-note-formatting-evidence.json).

21 October print/PDF: task lists and pinned notes open an immutable native PDF review with paper/content options and explicit Save/Print. The independently owned renderer has multiline/Unicode, bounded pagination and complete-source tests; production and isolated app inputs include the printing sandbox entitlement. Native Mac Save/Print, error recovery and VoiceOver remain pending while the Mac is locked. See [print evidence](p2-print-output-evidence.json).

22 October removal recovery: the Mac independently owns protocol-2 preparation,
private proof persistence and exact-command confirmation. Core account/removal
checks pass 50 cases; the complete isolated Mac source builds. The shared service
is deployed and real iPhone Simulator late-expiry relaunch acceptance passes.
This is not Mac runtime/Keychain or distribution acceptance; those remain deferred
with signing. See [account removal](ACCOUNT_REMOVAL.md) and its status-proof evidence.

22 October note recovery: both owned formatters now reserve a readable scrolling
warning area with Copy text reachable, and yield formatting tools while showing
a failure. The Mac already restores its previous inspector draft when Apply's
save is rejected; its current full app builds. Five scoped Simulator cases cover
iOS task-save failure/retry, ordinary Save and stale-Apply preservation, including
largest-text dark iPad. Native Mac editing/Undo/failure and spoken acceptance
remain open. See `p2-note-recovery-evidence.json`; rank 3/Px stays active.

22 October automation foundation: the Mac independently owns native secret/hash
and metadata types, account-fenced management transport and matching candidate
Edge/SQL controls. Both apps build; each owned Core account/automation suite passes
49 cases and the existing private-handoff suite 16, plus eight mocked HTTP cases
and local SQL checks. No migration/function/key/UI is enabled on the live service.
Task operations, native management and real acceptance remain in progress before
release; see `p2-automation-access-evidence.json` and the rank-6 plan.

23 October email journal: the Mac owns a disabled database candidate for atomic
receipt/task creation and account-bound route lifecycle. Local validation passes
119 functional, 32 real PostgreSQL concurrency and 43 existing fixture-compatibility
checks. No hosted migration, endpoint or native UI is enabled. Trusted gateway,
private native setup/recovery, source links, provider integration and real delivery
remain open; provider/domain configuration stays deferred. See
[email intake evidence](p2-email-intake-journal-evidence.json).

23 October email gateway: the independently owned, undeployed native-management
handler passes 22 gateway plus nine admission cases and 20 HTTP-to-PostgreSQL
checks with synthetic Auth. Address secrets remain out of management requests;
missing configuration preserves pause/revoke. Premium native setup, private
Keychain recovery and real provider/native acceptance remain next; this milestone
does not change app UI or enable email. See
[gateway evidence](p2-email-routes-gateway-evidence.json).

23 October native email setup: the Mac independently owns the gated account-settings
sheet, confirmed private-address vault, durable interrupted-action recovery and
bounded Backend transport. The Mac source builds, and scoped Core checks cover
privacy, account/session fencing, failed saves and cross-window recovery. Companion
phone/tablet fixture walkthroughs do not prove Mac runtime or real Keychain use;
those and hosted/spoken acceptance remain open. No release flag or live delivery
is enabled. See [native setup evidence](p2-email-native-setup-evidence.json).

23 October durable email domain: protocol 2 binds the private address, database
route and reviewed domain. Configuration cannot race a new enrollment or replace
a live/paused address's domain/provider. Legacy unknown-domain routes retire
without task/journal changes. The Mac independently owns matching SQL/gateway/Core
and native decoding; its app builds and scoped checks pass. Companion Simulator
walks do not establish Mac runtime/Keychain/spoken acceptance. No live service or
release flag is enabled; see [domain evidence](p2-email-domain-evidence.json).

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


## Note/Focus privacy and natural expiry — 10 October 2026

Two additional native iPhone Simulator checks pass. Actual widget configuration switches hide the selected task title and note text, both private widgets still open their original work, and restoring both switches reveals the selected details again. The inspected private frame shows generic note/task wording while retaining the Focus clock. Both settings finish off.

The retained timer expired naturally during the privacy walk. The installed medium widget reaches Time well spent / 00:00; its follow-up native route opens the same finished session, and Inbox still contains exactly one original open task. Independent comparisons before privacy, after private routes, after restoration and after the finished-session route confirm the entire saved workspace and note/Focus payload remain unchanged. Three final frames were inspected and retained.

See `docs/widget-host-evidence.json` / `noteAndFocusHosts` / `privacyAndNaturalExpiry` for scoped results, input/data hashes and limitations. No production source changed. The private view code matches in the independently owned repositories; no Mac host was launched. This verifies this small-note/medium-Focus pair, not other sizes, VoiceOver, cloud-account lifecycle, long outages, notifications or physical/iPad/Mac hosts. The isolated app is terminated; the pair remains configured with privacy off and the naturally elapsed session.


## Completion and undo usability — 10 October 2026

The iOS task-list completion control now has a 44-by-44-point target in both roomy and compact layouts. Dated-row options use the same target and a stronger secondary foreground; Undo has a minimum 44-point target. The task icon and compact vertical spacing retain their existing sizes. No persistence or synchronization contract changed, and the independently owned Mac desktop controls retain their native sizing.

The focused native workflow captures a tomorrow/10:30/priority-2/25-minute task, adds full instructions in More options, saves, completes, waits for actual row removal, undoes, terminates, relaunches without reseeding, and checks the open task, visible estimate, full instructions and dated-row options. Final phone/light/roomy and tablet/dark/largest-text/compact results, saved-data checks and inspected captures are recorded in `docs/completion-undo-evidence.json`.

Earlier tablet attempts failed to locate the editor estimate through Stepper/identifier/text queries; one intermediate phone attempt selected the duration icon instead of its text. These are retained as failed attempts, not accepted coverage. The final workflow checks the visible task-row estimate and independently validates the saved task. This does not establish editor estimate-control accessibility, VoiceOver, keyboard, physical-device, cloud handoff or Mac runtime acceptance. Existing estimate-editing and recovery evidence is reused. The isolated local fixture was replaced for this walk; the earlier note/Focus fixture is no longer the current workspace.


## Accessible estimate editing — 10 October 2026

At iOS accessibility text sizes, task estimates now use the existing wrapped repeat-control layout with separately named 44-point increase/decrease buttons. Normal iOS text sizes and the Mac inspector keep their native Stepper. Both apps expose “Time estimate in minutes” and the current numeric value. Persistence and the 1–10080-minute range are unchanged.

The scoped native workflow captures a 25-minute task, reopens the editor, checks the label/value and large-text action names/targets, changes 25 → 26 → 25 → 26 using the real controls, saves and relaunches without reseeding, checks 26 minutes in the task row, and reopens the reachable editor value. See `docs/estimate-accessibility-evidence.json` for phone normal/light and largest/dark runs, tablet largest/dark, both builds, signatures, inspected captures and saved-data checks. The first normal-phone attempt used an exact label assertion; the native Stepper combines the visible title with the added accessibility description. The final assertion requires that description without rejecting the native prefix.

This closes the scoped estimate-control gap left explicit by `completion-undo-evidence.json`. It does not establish full VoiceOver/keyboard journeys, physical-device or Mac runtime acceptance. The Mac change is build-verified only; no Mac app was launched. Existing estimate cloud-continuity evidence is reused because this change does not modify stored fields or synchronization.


## Capture keyboard and subtask target audit — 10 October 2026

Quick capture now explicitly resigns the iOS keyboard responder when Hide keyboard is tapped, matching the full editor. The subtask-add button has a 44-by-44-point iOS target; the Mac button is named Add subtask for accessibility. Five focused native phone/tablet cases pass, including actual keyboard disappearance, reachable Save/More options, preserved captures/estimates, subtask creation and independent completion after relaunch. Both apps build; the Mac GUI was not launched.

The unfiltered native accessibility diagnostic remains failing: ten normal-text findings and three largest-text findings, with zero insufficient-description findings across eight visible viewport checks. The remaining clusters and exact limits are documented in `docs/ACCESSIBILITY_FINDINGS.md`; raw reports and `docs/critical-accessibility-evidence.json` preserve the evidence. This is not full VoiceOver, keyboard, physical-device or Mac acceptance. Audit cases are explicitly opt-in, and skips are not treated as passes. Existing recovery/continuity evidence is reused.

10 October: Recorded iOS saved-preview touch activation evidence in `docs/preview-details-evidence.json`: three actual phone/tablet passes after relaunch, full notes retained, task remains open. Mac TaskRowView keeps a one-line preview and TaskInspector retains complete notes; source inspection only, no Mac runtime claim or production change. VoiceOver/keyboard acceptance remains open.

10 October: Recorded invalid Simulator hardware modifier input in `docs/keyboard-input-evidence.json`. Native select-all preflight fails; app hardware Save cannot be judged from that route. Mac autosave/Return handlers source-inspected only; no Mac runtime or production change. Existing keyboard acceptance gate stays open without adding a particular accelerator as a release requirement.


10 October: My list cloud-selection checkpoint is partial; see `docs/mylist-account-evidence.json`. Native isolated iPhone login, installed small project-A selection/exact task route, and B → A restoration of the same selection each pass one actual UI case with no skips/failures/reported runtime warnings. Mac-owned authenticated A/B/A projection passes one actual integration case, rejecting foreign list identity. No production code changed and no Mac GUI was launched. Foreign-account installed-widget routing was never reached: retained video pixels prove the iOS Save Password prompt blocked Browse. Final My list logout is unrun. Both disposable accounts had refresh sessions revoked and were deleted; database users/sessions/tasks/projects counts are zero; private credentials and fixture caches were removed. These results do not close the full widget lifecycle, accessibility, physical-host or Mac-runtime gates.

10 October follow-up: The remaining installed small My list account lifecycle now passes in three sequential native cases (foreign B, returned A, signed out), each one actual pass with zero skips/failures/reported runtime warnings. Test-only authentication handling now declines the actual SafariViewService password prompt. Inspected captures confirm no A names under B, safe B All tasks routing, original A selection/task restoration without reconfiguration, and no private content after logout. Both server workspaces remain unchanged and account queues are empty. Mac real authentication/projection passes again against the fresh fixtures. All disposable users/sessions/tasks/projects were removed after global session revocation; private credential files/caches were removed. No production app/widget changes and no Mac GUI launch. This supersedes the partial lifecycle status above, while other sizes/hosts and the full P0 gates remain open; see `docs/mylist-account-evidence.json`.

10 October: Fixed iOS accessibility-size new-subtask composing truncation. Native phone/tablet dark XXXL walks each pass one actual case with zero skips/failures/reported runtime warnings; inspected draft captures wrap complete titles, and saved snapshots retain both named subtasks and independent completion after relaunch. Normal single-line entry and stored contracts remain unchanged. Mac saved-subtask editing already wraps; desktop Return-to-add remains intact, source-inspected only. See `docs/subtask-draft-evidence.json`; full audit/VoiceOver/keyboard/native Mac acceptance remains open.


10 October: Installed iPad portrait medium/large My list checkpoint passes. Both repos now own explicit ready-list header links; small behavior and stored contracts remain unchanged. One actual header-route case passes across both sizes and relaunch; one actual terminated-app task-route case passes across both sizes, each zero skips/failures/reported runtime warnings. Inspected Home Screen shows complete two-row/five-row layouts; project and verified task-editor captures retained in the iOS repo. All stored fixture tables equal their pre-route baseline; six tasks, zero pending. Both builds pass; Mac GUI was not launched. Prior harness failures and scoped limits are retained in `docs/tablet-mylist-evidence.json`. Removed 14 retired isolated iPad test app/runner bundles after verifying fixture-only ownership and empty queues (507,452,242 logical file bytes); current installed pair retained. Full P0, VoiceOver/keyboard, physical and Mac runtime gates remain open.


## Editor Reminders and photo-picker return — 10 October 2026

One final native iPhone case completes both normal/light and XXXL/dark modes with zero skips/failures/reported runtime warnings. It opens Reminders and returns, opens/cancels the actual Photos picker, then saves/relaunches and verifies the complete title/instructions. Both action rows are at least 44 points. Pre-fix functional coverage passed but its inspected largest-text capture exposed “Re-” / “minders”; iOS now uses a text-only Reminders label at accessibility sizes. Final inspected capture shows the complete word on one line; normal sizes keep the bell. Choose a photo wraps completely. The final task remains open, has zero attachments and no queued changes. See `editor-picker-evidence.json`.

The final picker finished loading its Photos/Collections privacy notice; selection/import was not exercised. Mac desktop source was reviewed only, with no code or runtime change. This is touch/draft-preservation evidence, not a cleared unfiltered audit, VoiceOver/keyboard, photo import, external-provider or Mac acceptance result.


10 October: Native photo attachment workflow now passes one actual iPhone case: select the synthetic checker in Photos, save/relaunch, render all four checker quadrants in Quick Look, and close back to the persisted attachment. Zero skips/failures/reported runtime warnings. Saved PNG bytes exactly match the independent 166-byte fixture and pending queue is empty. One Mac-owned Core integration case reads that final native snapshot and preserves the complete attachment through portable cross-account restore and duplicate-free retry. No production changes or Mac GUI launch. See `photo-import-evidence.json`; cloud image handoff, external providers, physical hosts and full accessibility remain unverified.


10 October: Both apps now name task-row subtask progress, comments and attachments descriptively for accessibility; visuals and stored fields are unchanged. Two native iPhone cases pass with zero skips/failures/reported runtime warnings: the saved photo row exposes “1 attachment” and its preview/return still works; largest/dark subtask progress exposes “1 of 2 subtasks completed” after relaunch, then “2 of 2” after independent completion. Saved parent remains open, both subtasks completed, pending queue empty. Both apps build. Comment-count semantics are source/build verified only; Mac GUI, full VoiceOver/keyboard and the unresolved unfiltered audit remain open. See `metadata-accessibility-evidence.json`.


10 October: Installed iPhone medium Today, medium Week ahead and small Quick capture pass one native workflow with zero skips/failures/reported runtime warnings. Inspected captures show Today count 2 with complete overdue/today titles, Week ahead count 2 and one overdue, and readable Quick capture. Header/background routes open the intended Today/Upcoming scopes; Quick capture opens a blank composer, saves, and retains the task after relaunch. Four fixture tasks remain open and the queue is empty. Only this test’s three widgets were removed; existing fixtures retained. No production change. Mac widget/route source inspected only, with no runtime claim. See `daily-widget-evidence.json`; other sizes/hosts, cold widget launches and full accessibility remain open.


10 October: Fixed neutral external-capture date parity. iOS `taskfold://add` now opens an undated Inbox composer, matching Mac. A workspace-bound one-shot request also handles Inbox first appearance; native Today-screen adding keeps Today. Both widget sources clarify capture in Inbox. One native iPhone case passes URL delivery from a running app and after explicit termination with a Today default, saves both tasks, relaunches, and verifies Planned date stays off. Saved tasks are open, undated, in Inbox, with zero pending changes. Both app builds pass. Mac default behavior is source-verified only; GUI and physical acceptance remain open. See `external-capture-evidence.json`.


10 October: Installed small original Focus recommendation widget passes one native iPhone workflow: overdue → today → undated P1 → empty, with exact native task-editor routes after each completion and an initial terminated-app launch. Future P1 remains open and excluded; empty Focus opens undated Inbox capture. Inspected captures retain complete titles/status/footer. Saved state has three completed recommendations, one open future task and no pending changes. One independently owned Mac WidgetModel ranking case also passes. No production changes or Mac GUI launch. See `focus-recommendation-evidence.json`; other hosts/sizes, tinted rendering and full accessibility remain open.


10 October: One native iPhone case passes representative system Tinted acceptance with zero skips/failures/reported runtime warnings. Inspected Home Screen captures show readable populated small Focus and unconfigured small My list. Focus opens its exact task editor under tint. System Default is restored and the reopened fixture task completed again; four original IDs remain, three completed, future P1 open, pending queue empty. Earlier failures were Home/edit-panel navigation in the harness; final test explicitly dismisses panels and uses XCTest teardown restoration. No production change. Independent widget sources are byte-identical; no Mac runtime claim. See `tinted-widget-evidence.json` in docs. Other widgets/sizes/tints/hosts and full accessibility remain open.


10 October: Real authenticated photo handoff passes six native phone/tablet phases and one Mac-owned transport/cache integration case, with zero skips/failures/reported native runtime warnings. Native phone Photos selection/save/relaunch → tablet offline metadata edit/relaunch/image preview → reconnect → phone receives edit and previews offline. Exact 166-byte PNG, complete attachment object, original task/attachment IDs and one offline mutation are verified; both queues drain. Inspected final phone/tablet captures retain all four image quadrants. Disposable account/sessions/data and credential file removed; local widget fixtures restored. No production changes or Mac GUI launch. See `photo-handoff-evidence.json` in docs; native Mac attachment handling, physical and external-provider acceptance remain open.


10 October: Read-only release-environment recheck confirms locked Mac UI, zero online physical iOS devices (four paired devices offline), one Apple Development identity and no Developer ID Application/Apple Distribution identities. Unlock requested; prior native-launch/provider/provisioning inputs remain pending. Existing Simulator and transport passes retained; no substitute fixture matrix or production change. See `release-environment-check.json` in docs. Full goal remains unfinished.


10 October resumed: Mac is unlocked according to native UI automation. Prepared a separate Mac UI-test app/runner with unique bundle, sandbox, session/recovery keychain services and widget namespace. Production URL/file registrations and widget extension are excluded. Copied app sources differ only by verified namespace strings; production checkout/app untouched. Debug build-for-testing, signature and manifest checks pass. Existing Mac-launch permission remains outstanding; no GUI/runtime, Desktop-widget, provider or distribution acceptance. See `mac-ui-isolation-evidence.json` in docs.

### 10 October — authorized isolated native Mac checkpoint

Launch authorization is resolved. Capture, search/inspector editing, completion/reopen, native Edit Undo, persistence and Focus pause/relaunch/resume/end now have native CUA evidence; see `mac-native-runtime-evidence.json`. XCTest initialization timed out before cases, so the compiled suite is still unexecuted. The isolated debug bundle now uses private widget storage without fixture overlays. Direct row selection, keyboard Undo, full P0 native handoff and installed Desktop/distribution checks remain open. The user accepts Xcode Simulators for ordinary iPhone/iPad testing.

### Native Mac selection and planning correction — 10 October

The isolated Mac walk exposed stale inspector presentation on direct row selection. macOS now reads inspector visibility in the view body, establishing selection observation before constructing the presentation binding. With the temporary diagnostic removed, native direct selection, Space completion, Command-Z Undo, reselection and explicit inspector hide/show pass. Planned date/time, independent deadline, priority/estimate/notes and two custom relative reminders (alongside the planned-time default) survive quit/relaunch and were reinspected in the native editor. See `mac-selection-planning-evidence.json`. This supersedes the earlier unverified direct-selection/keyboard-Undo checkpoint for this local workflow. The existing keyboard regression test compiles; XCTest still has no passing execution receipt. No iOS code change is needed for this Mac presentation binding. Full native handoff, recovery/provider and installed-widget acceptance remain open.

### Native Mac recovery picker correction — 10 October

Native Export saves a readable portable backup. Restore from file initially did nothing in Mac Settings; the Mac-owned action now attaches an AppKit open panel to that window and retains the existing security-scoped read, workspace validation and restore preview. Native selection of the exported file and both review policies pass: Keep current edits produces zero changes; Use backup values previews one task and one Focus record update. Applying waits while saving its encrypted safety copy in a Keychain access call. SecurityAgent is running, and Codex computer use refuses that system app; a human handoff is pending. The edited fixture remains unchanged. Completed restore, repeated-import safety and encrypted-copy reopen are explicitly unverified. See `mac-native-recovery-evidence.json`. The app builds and the picker cancel/reopen regression source typechecks; that XCTest case has not executed. Existing iOS native Files workflows remain accepted; this picker implementation is Mac-specific.

### 10 October — Lock Screen readability and current acceptance

Both owned widget sources retain the improved Today accessory title wrapping, shorter subtitle and system privacy marker. The iPhone Simulator saved-host / terminated-app task-and-Today routes pass in one focused regression, with unchanged decoded workspace and three inspected captures; `lockscreen-widget-evidence.json`. The Mac Debug app/widget build passes; the accessory branch is iOS-specific and no Mac Desktop-host or system-redaction pass is claimed. The P0 checklist now reconciles native Mac capture/planning/recovery-preview evidence and the user's Simulator instruction. Mac GUI continuation still needs an unlocked desktop and the pending isolated recovery-key prompt.

### 10 October — native Mac recovery accepted locally

The desktop is accessible and the earlier recovery-key wait has resolved. Native portable restore, encrypted Before restore recovery of the later edit, repeated import without duplicates, quit/relaunch persistence, encrypted-copy reopen after relaunch, and picker cancel/reopen now pass through CUA. The original task/planning/reminder values are preserved; the Focus checkpoint retains its values under the intentional portable session-ID mapping. Final cache: one task, one Focus row, zero pending mutations. The native Focus sheet shows the restored ended session with 24:52 remaining. See `mac-native-recovery-evidence.json`. This verifies the existing implementation; no new source/build matrix or passing XCTest runner is claimed. Cloud/cross-account/provider workflows remain open.

### 10 October — account draft and quick-capture inspector follow-up

Native cloud sign-in exposed a stale local display-name draft; quick capture also left an already-open inspector blank until scope navigation. Account-owned name drafts now refresh safely in both repos, with three passing focused Core regressions per repo and passing Debug app builds. The Mac inspector content now follows selected IDs and has a two-capture native UI regression. Corrected native UI behavior and the richer Mac–iPhone handoff remain unverified because the desktop is locked; see `profile-draft-inspector-evidence.md`.

### 10 October — native Mac task received and revised on phone

The native Mac-created task and description reach the isolated signed-in iPhone Simulator. A focused UI test receives both, edits the title, relaunches and verifies notes preservation; one case passes without runtime warnings. Server and cache preserve the original ID, P1, estimate/date and notes, with an empty phone queue. The actual editor capture was inspected. `mac-phone-handoff-evidence.json` records the limited checkpoint. Mac return-leg and richer native handoff remain open while the desktop is locked.

### 10 October — inline Lock Screen Today acceptance

The installed iPhone Today inline accessory now has a saved native host and passing terminated-app Today route, with two inspected captures and an unchanged decoded account workspace/empty queue. See `lockscreen-widget-evidence.json` / `inlineToday`. Both owned widget sources remain identical; no new Mac runtime or Desktop-host acceptance is claimed. The Mac desktop is still locked and its native return leg remains open.

### 10 October — profile photo account-switch boundary

Source inspection found an unguarded asynchronous avatar result in both apps. Both pickers now capture workspace ownership before presentation; image/upload results and errors cannot cross the captured workspace. The uploader requires the original account and rejects session changes across refresh and response. Both own AccountTransport suites pass 18 cases, including four new upload race/success cases. See `profile-photo-ownership.md` for build results and exact limits. Native selection/account-switch UI acceptance remains open while the Mac is locked.

### 10 October — native phone profile photo acceptance

Three actual iPhone cases now verify picker Cancel/draft preservation, synthetic Storage upload/relaunch and profile removal/relaunch against the corrected code. Four captures were inspected, the fixture JPEG removed through authenticated Storage, the cleanup-only session revoked and original task data retained with an empty queue. See `profile-photo-native-evidence.json`. The Mac runtime and native in-flight account switch remain separate; the desktop is still locked.

## Native regression execution — 10 October 2026

Rebuilt the isolated test app from `b1cfa01`; the native XCTest runner now works. The two-capture inspector regression passes with no failures/skips/runtime warnings. Restore picker cancel/reopen and selected-row keyboard completion/Undo pass in a three-case run; the original Todoist label-only assertion failed because Mac exposes the message as an accessibility value. The corrected assertion and visible error/retry workflow now pass separately with no runtime warnings. Both app-owned views move the save error above retry; the final Mac capture shows both together. Inspected the selected-row capture: readable selected title/actions and populated matching inspector. See `native-mac-regression-evidence.json`. Production installation is untouched; the independent iOS repo receives the scoped acceptance notes, with no Mac build dependency.

## Native productivity and multiline editing — 10 October 2026

Reproduced Return unexpectedly closing the pinned-note details editor in native Mac computer use and XCTest. Replaced the Mac inspector's notes TextField with TextEditor, preserving its existing binding, delayed save and undo behavior. The native regression now passes newline editing, explicit Done, unpin/Undo and edited text after relaunch. Focus task search/context/cancel/pause/relaunch, project progress/history/relaunch and per-destination capture drafts also functionally pass after correcting test AXValue reads and scoping the project selector to its own popup. Retained note/Focus/pulse captures are inspected. XCTest priority-inversion warnings remain; clean-runtime acceptance is not claimed. See `mac-productivity-native-evidence.json`.

## Native Mac/phone round trip — 10 October 2026

Local-to-cloud profile-name refresh and native phone-edited task receipt now pass on Mac. Native Mac pin/Focus start/pause → iPhone pin receive/note edit/Focus resume/end/relaunch → Mac receive/relaunch completes in three cases with zero failures/skips/runtime warnings. Exact task/pin/Focus cache equality, zero pending changes, original IDs and unchanged non-note task fields are verified; scoped server reads confirm the same Focus session advances from paused revision 2 to stopped revision 4. Seven captures are inspected. See `mac-phone-note-focus-evidence.json`. Normal app-owned backends perform all task/pin/Focus writes; no task seeding through SQL/API. Native organization/planning/account races and external release gates remain open.


## Native organization and filter handoff — 10 October 2026

Created Continuity Studio, its Ready section, a handoff label and an @handoff AND p1 saved filter through the isolated native Mac UI; moved/labeled the original cloud task. Two native cases pass with zero failures/skips/runtime warnings: Mac project/section/notes/pin/filter persistence and iPhone project/section/label/filter routes plus full pinned notes, each before and after process relaunch. Both caches agree exactly across tasks, projects, sections, labels, saved_views, view_orders and focus_sessions; both queues are empty. Scoped server reads match all five queried organization/task tables. Only project_id, section_id and labels changed on the original task. Four captures are individually inspected. See `mac-phone-organization-evidence.json`. This closes this one-way native organization/filter receipt; reverse edits, native offline/concurrency, richer planning/account races, Desktop widgets and external release gates remain open.


## Native phone offline organization return — 10 October 2026

The phone now renames the Mac-created project, section and label through native editors while its isolated transport is disconnected. Renames and the original saved-filter match survive offline relaunch; the server and online Mac retain the old records until reconnect. All 11 queued writes (including per-keystroke section updates) drain on reconnect. Native Mac project/section/label/filter routes and relaunch then retain the returned names. Three cases pass with zero failures/skips/runtime warnings; four captures are individually inspected. Both caches agree exactly across seven task/organization/filter/pin/Focus tables, and all five scoped server tables match. Only the three organization names changed: original IDs, relationships, entire task, saved filter AST, pin and Focus records are unchanged. See `mac-phone-organization-offline-evidence.json`. This accepts this reverse rename/offline/reconnect workflow; concurrent native variants, richer planning/account races, installed Desktop widgets, VoiceOver and external release gates remain open.

### 10 October — rich planning native cloud return

Mac native daily capture and relaunch, phone original receipt/relaunch/completion, phone successor relaunch, and Mac original/successor receipt/relaunch now have scoped evidence in `mac-phone-planning-evidence.json`. Three focused cases pass without runtime warnings; the two earlier assertion failures remain disclosed. Exact seven-table parity and empty queues confirm persistence; the one-off deadline intentionally stays on the completed original. Two inspected copy issues remain actionable in that receipt. No app behavior was changed at this checkpoint; source changes add independently owned acceptance cases. Full release gates remain open.

### 10 October — resolved capture context and honest unavailable-reminder status

Mac and iOS independently correct the two copy findings from rich planning acceptance. Full directory/date context now reaches planning previews; 81 relevant Core cases pass in each repo, including the reproduced resolved-section regression. Remote-unavailable status is consolidated without changing registration, delivery authority, or persistence contracts. Both native builds pass and two phone cases pass without runtime warnings; source-owned Mac cases are compiled but await macOS approval to read the isolated `com.taskfold.mac.p0uitests.session` item after rebuild. The interrupted native run supplies no acceptance claim. See `planning-reminder-copy-evidence.json` for scoped evidence, unchanged data proof, inspected captures and the long-capture automatic-reveal polish follow-up.

### 10 October — iPhone import retry and largest reminder message

Three iPhone local-fixture checks pass functionally: normal and dark largest-text Todoist validation/failed-save/retry/receipt, and the updated largest-text local reminder sign-in message plus reachable delivery/save controls. The strict verifier rejects clean-runtime acceptance because each import case emits an invalid-frame warning when opening from Browse; the source is not symbolicated. Error appears above retry, but retained captures show the action partially below the visible area/tab bar, so full simultaneous visibility is not claimed. Explicit local-mode launch protects the existing cloud cache before fixture setup; all seven cloud tables remain exactly unchanged with three tasks and zero queued edits. The existing fixture persists local mode; relaunch with `-localMode NO` restores the cached cloud account without signing in. Four captures were inspected. Earlier failed navigation checks remain disclosed. See `ios-import-availability-evidence.json`. The isolated Mac process is launched but still awaits its private-session Keychain approval; full release gates remain open.

### 10 October — import recovery layout and clean native acceptance

The failed-save action now says Retry import in both independently owned apps, with Importing… while busy. iPhone uses an inline title, hides its tab bar within import, and exposes keyboard Done in the navigation bar. Moving the keyboard toolbar's construction to focus moved the invalid-frame warning from opening to focus; removing that toolbar path eliminates the warning in the final native run. Both builds pass. Two complete iPhone cases (normal and dark AccessibilityXXXL) now pass with zero failures/skips/runtime warnings: input validation, malformed response, approved preview, failed save, full visible retry button, successful skipped-ID receipt, Back/reopen and cleared token. Two inspected captures show the fixture's entire failure explanation and retry action together; this is not a guarantee for arbitrarily long provider errors. Seven cloud tables remain exactly unchanged, with three tasks and zero queued edits; the cached cloud account is reopened with the known local-fixture preference override. Historical failed/interrupted diagnostic runs remain disclosed. See `ios-import-action-evidence.json`; it supersedes the previous iPhone frame-warning/full-action visibility gaps in `ios-import-availability-evidence.json`. Native Mac label acceptance still awaits Keychain approval, and real provider/distribution/full P0 gates remain open.

### 10 October — native phone profile upload across account switch

A real synthetic photo upload response for the original disposable account is now held while native UI signs out and signs in to a second disposable cloud account. Releasing that response leaves the second account's dirty name draft, photo and error state untouched. Second-account relaunch retains only its saved profile; native return restores the first account's original profile. A final normal relaunch retains the original cloud Today task. One native case passes with zero failures/skips/runtime warnings; five captures were inspected. Both own 21-case account-transport/profile-draft suites and app builds pass. Source changes add a guarded Debug response hold in each repository and an iOS native acceptance case; production ownership behavior is unchanged. The exact JPEG existed under the first owner, while both server profiles remained unchanged. Seven original workspace tables and its profile cache remain exactly unchanged, with three tasks and empty queues. The synthetic object was deleted through its owner API; the cleanup-only original session was revoked locally, the second account's sessions globally revoked, then that account deleted. Scoped reads confirm zero second-account records/sessions/objects and no test photo. Private second-account credentials/barrier/cache were removed. See `profile-account-switch-native-evidence.json`. This closes this phone in-flight response/draft acceptance gap; Mac native profile/account-switch acceptance still awaits private-session Keychain approval, and broader P0 release gates remain open.


### 10 October — installed iPad note and Focus acceptance

Three isolated iPad Simulator native cases pass with zero failures/skips/runtime warnings: actual small Pinned note/medium Focus gallery installation and configuration, full note/current-session routes and pause; native note edit/rename/save/relaunch and Focus resume; Simulator reboot with each route from a terminated app. Six captures were inspected, including both renamed widgets, paused/running clocks and complete cold-opened notes/session. Original task/pin/Focus session IDs, full saved workspace and account/note/Focus payload remain unchanged across reboot. Only publication/calendar refresh timestamps change. Test changes identify widget sizes by width, force local mode before fixture loading, and use the native iPad Select All menu. Three unsuccessful refresh attempts are disclosed; final refresh and reboot passes reuse identical products. No product-source fix or native Mac acceptance is inferred. See `tablet-note-focus-widget-evidence.json`. iPad privacy/other sizes, installed cloud-account lifecycle, physical/Desktop hosts and full P0 gates remain open.


### 10 October — installed iPad widget privacy and natural expiry

Two additional isolated iPad native cases pass with zero failures/skips/runtime warnings. Actual note/Focus hiding switches are verified on/off; inspected installed widgets hide titles/text, retain their original native routes, then restore details. The same timer naturally reaches 00:00 / Time well spent in the widget and opens the original finished session. The original task remains open, with one task and zero queued changes. The complete local workspace matches the retained baseline, account/note/Focus payload is unchanged, and the original signed-in phone cloud cache remains exactly unchanged. Three captures were inspected. Test-only launch/size selection was hardened; no product-source fix was required. See `tablet-note-focus-widget-evidence.json` / `privacyAndNaturalExpiry`; this supersedes the preceding iPad privacy/expiry gaps for these sizes. Other sizes, installed cloud-account lifecycle, long outages, Desktop/physical and full accessibility/provider/release gates remain open. The Mac still waits in its private-session Keychain read, and native computer use currently reports a locked desktop. No prompt was automated or bypassed.


## 10 October — installed cloud note/Focus ownership and clock clarity

Six native scenarios pass in ten clean executions: install/select/open, switch A → empty B, return A, logout, final A sign-in, and ended-clock clarity. The account transitions pass again after the display fixes. Original note selection and session return without reconfiguration; foreign/signed-out widgets expose no original work and routes remain account-safe. All phases preserve the entire original cache and both seven-table server workspaces, with three original task records and zero pending changes. Both repositories pass their own real-auth projection check and app/widget builds. Native session clocks now label Time spent/Time remaining and show elapsed whole seconds after ending, matching the widget. Medium idle/refresh copy now wraps fully. Eight captures were inspected. The disposable B sessions were globally revoked before account deletion; scoped reads prove zero remaining records/sessions/objects, and its credentials/cache were removed. See `note-focus-account-widget-evidence.json`. This accepts these installed phone sizes and workflow; other hosts/sizes, native Mac runtime, full accessibility/provider/distribution gates remain open. The live isolated Mac still waits in its private-session Keychain read.

### 11 October — visible quick-capture suggestions with the keyboard open

iOS now reserves space for the active suggestion above the keyboard controls, separate from the scrolling draft, and explicitly selects the expanded sheet detent. Both independent apps size their suggestion lists to actual content, retaining the existing scrolling cap. Two final iPhone native cases pass at normal/light and largest/dark text with zero failures, skips or runtime warnings: the entire reminder option is visible without manual scrolling, selection preserves the resolved section/reminder chips, and Save remains reachable. Four captures are inspected. The complete original cloud cache equals its baseline; the preview is never submitted. Both app builds pass. This closes the documented phone suggestion-occlusion polish follow-up. Mac panel sizing is compile-verified only; its native inspection still requires the unlocked desktop/private-session approval. iPad and VoiceOver were not rerun for this follow-up; broader release gates remain open. See `capture-suggestion-visibility-evidence.json`.

### 11 October — installed small Focus session and cold route

One isolated iPhone native case passes with zero failures/skips/reported runtime warnings. It installs the small Focus family beside the existing medium instance and selected Pinned note, verifies the terminated-app route to the original ended session with Time spent / 00:03, then removes only the temporary small widget. Four captures are individually inspected: both widget clocks agree, small text/action fits, and the original note/medium selections remain. The entire original workspace cache is unchanged; widget account, Focus session, notes and zero pending sync are unchanged. No production code changes are needed. The gallery test helper now finds checked free wallpaper below occupied icons; three earlier pre-mutation failures remain disclosed. SpringBoard cleanup includes two animation-notification waits, but the final result reports no runtime warnings. See `small-focus-session-host-evidence.json`. This closes this small-family rendering/coexistence/cold-route checkpoint; other states/surfaces and full P0 remain open. No new native Mac acceptance is claimed.

### 11 October — one capture delivery guide and preserved Reminders route

Both apps suppress the automatic delivery-off line when custom-reminder capture already shows its explicit guidance. The automatic reminder explanation remains; no scheduling, persistence or auth behavior changes. Both app builds pass. Two iPhone native cases pass at normal/light and largest/dark text with zero failures/skips/runtime warnings: complete suggestion, reminder selection, one fully visible delivery guide, and its action preserving the draft title and reaching Reminders without saving. Four captures are inspected. The entire original phone cache equals its baseline, and the original Mac cloud cache hash is unchanged. A separate local-only Mac QA build loads its private fixture without the protected cloud-session read, but its native bulk test fails initial activation; subsequent computer use reports a locked desktop. It is not native Mac acceptance. The user-authorized local app is running. See `capture-delivery-guide-evidence.json`. Native Mac, broader provider/notification/distribution and full accessibility gates remain open.

### 11 October — medium Inbox batches and complete cloud-widget cleanup

Two native cases pass in separate bundles with zero failures/skips/reported runtime warnings: actual medium Inbox installation, six-total/five-of-six rendering, five-task cold review, configuration to all six, six-task cold review and settled all-six rendering; then final fixture reset and both original cloud note/ended-Focus cold routes. Only the temporary Inbox instance is removed. Seven retained captures are inspected. The complete original phone cache equals its baseline; widget account/note/Focus/pending fields are unchanged, queue is zero, persistent local mode and cold-fixture flags are off, and original Mac cache hash is unchanged. iOS Debug-only Simulator fixture binding/reset is corrected; no production widget or Mac behavior changes. Four SpringBoard animation-notification waits remain disclosed. Earlier failed/superseded runs are retained. Current checklist now separates accepted native handoff walks from the still-unverified Mac ordering/favorites/view-choice remainder and replaces stale environment claims. See `medium-inbox-host-evidence.json`. Native Mac, other named host/accessibility/provider/notification/distribution gates remain open.


### 11 October — source parity audit and Mac failed-pin retention

The two repos have 23 common Core files: 20 are byte-identical, and the three reviewed differences are guarded Debug fixtures. Their independently owned widget source is identical. Xcode file/group path inspection finds no external or sibling references; package target paths and Mac build-generation/release entry points were also reviewed. Source inspection confirms both editors expose the relevant task/planning/organization/note fields; it does not establish full native feature parity.

The Mac inspector previously cleared its pending note-pin choice even when the atomic task/pin save failed. It now clears that choice only after success, preserving the draft's pin request for the next save. The iOS editor already retains its selection on failure. The isolated Mac Debug build passes; each repo's existing PinnedNotesTests and BackupTests pass all 50 selected cases. Those Core tests do not exercise this inspector failure branch. Native failed-write/retry inspection remains within the existing critical usability/recovery work and awaits the unlocked desktop. The original Mac cloud cache matches its retained baseline; no native workspace data was edited. See `source-parity-evidence.json`. All broader P0 gates remain open.


### 11 October — installed medium Deadline radar accepted

One isolated iPhone Simulator case passes with zero failures/skips/reported runtime warnings: native capture of missed/today/future deadlines, actual medium gallery installation, terminated-app route to the missed task, native completion, and terminated-app advance to today. Inspected installed captures show all three full chosen titles and cutoff badges, then the two remaining rows with the updated count. The original selected note and Focus widgets stay installed; removing only the temporary radar restores their original cloud routes. The complete original cloud cache is unchanged, original widget account/note/Focus/pending fields match, both fixture preferences are off, and the original Mac cloud cache matches its baseline.

The initial run failed during task setup before installation because Add task matched the still-open capture action as well as the list action. The final test dismisses the keyboard, uses the specific capture identifier and waits for each save to close. Two SpringBoard animation-notification waits and ignored remote-hierarchy diagnostics remain disclosed. Duplicate exported failure diagnostics were pruned with a hash manifest while retaining both native results. No production code changes were needed. See `medium-deadline-host-evidence.json`; Desktop/other hosts and the broader P0 checklist remain open.


### 11 October — consecutive capture with keyboard open

Investigated the second-capture setup failure retained by `medium-deadline-host-evidence.json` without using the keyboard-dismissal workaround. One iPhone native case passes with zero failures/skips/reported runtime warnings: three consecutive title/deadline captures, Save enabled/hittable/inside the app while the keyboard stays open, one Save tap followed by a closed-sheet assertion for each, then all three full task names retained after process relaunch. Four captures are individually inspected. No production change was made. The earlier failure is not reproduced; this does not prove its cause or eliminate intermittent failures.

The complete original cloud cache and widget account/note/Focus/pending data remain unchanged, both fixture preferences are off, and the original cloud Today task is reopened. The original Mac cloud cache also matches its baseline. See `repeated-capture-evidence.json`. This accepts the named normal/light iPhone sequence only; Mac native interaction, accessibility and broader P0 gates remain open.


### 11 October — refreshed unfiltered accessibility diagnosis

The current normal/light capture/editor audit completes all four viewports and still fails its unfiltered assertion: eight findings (three unidentified capture clipping reports, three saved-row hit-region reports, and description/search clipping). Editor overview and editor subtask/action viewports report no findings. Four captures are inspected; the normal capture visibly leaves the Inbox chip partly outside its horizontally scrolling controls. Adaptive control visibility is the next concrete fix within the existing critical usability work. The untargeted audit nodes cannot be assigned to that chip conclusively. Intentional description truncation and native search findings remain unresolved pending semantic/VoiceOver inspection.

Largest-text refresh is incomplete: the first run audits three viewports with zero findings but saves an incomplete ~25 token during saved-list setup; the second stops at a new complete-input assertion. Their causes are not established, and neither is acceptance. The diagnostic now verifies complete input and settled touch geometry, explicitly selects the disposable local workspace, retains per-viewport hierarchies, and continues to reject every reported finding without whitelists. No production source was changed. The original cloud task and selected cold note/Focus routes pass a separate cleanup case with no reported runtime warnings; full original cloud/widget data and Mac cache remain unchanged. Duplicate diagnostic exports were pruned with hash receipts while all native results remain retained. See `accessibility-current-evidence.json` and `accessibility-audit-reports/current-normal.txt`. Full accessibility and broader P0 acceptance remain open.


### 11 October — capture field visibility correction

Normal-size iOS quick capture no longer partly hides Inbox in a horizontally scrolling strip. Fields and actions stay on one row when their intrinsic widths fit; otherwise the fields wrap above the action buttons. The existing accessibility-size draft controls remain separate. One focused native iPhone test passes with zero skips/runtime warnings: complete control bounds above the open keyboard, actual Today/Inbox menu selection, keyboard dismissal, More options with title/25-minute estimate retained, Save and relaunch. The existing three consecutive keyboard-open captures also pass with this layout. Four final screenshots were individually inspected.

The unfiltered normal accessibility audit completed all four viewports: capture 0 (previously 3), editor overview 0, editor subtask actions 0, saved list 5. It still fails, with no suppression: three saved-list hit-region findings and two text-clipped findings (description preview and native search). Largest-text setup, VoiceOver and complete accessibility acceptance remain open. The original cloud Today task, selected note and ended Focus cold routes pass after cleanup; the complete original cloud cache and original widget account/note/Focus/pending fields equal their baselines, pending sync is zero, both local/cold-fixture preferences are false, and the original Mac cache is unchanged. See `capture-controls-wrap-evidence.json` and `accessibility-audit-reports/capture-wrap-normal.txt`.

Mac source assessment: `TaskCapturePanel` has a destination header and parsed chips, with no equivalent horizontal field-control strip, so this fix changes iOS production code only. No new native Mac, iPad, largest-text or long-project-label acceptance is claimed. Intermediate selector/editor-label test failures are retained and disclosed in the evidence. All native result bundles remain; duplicate intermediate attachment exports were pruned (1,581,056 allocated bytes).


### 11 October — saved-row accessibility action correction

The iOS task-content area already opened details from a minimum 44-point area, but exposed description and metadata as separate tiny accessibility targets. Non-linked rows now combine title, complete description and metadata into one accessible details button with a default action and selection-aware hint. Completion stays separate, linked rows retain individual link elements, and the visual row stays compact. Mac uses native list selection and separate AppKit controls; no corresponding Mac code change or native Mac acceptance is claimed.

Two native phone preview workflows pass, normal/light and dark/largest, with zero skips/runtime warnings: notes/estimate capture, save/relaunch, a hittable details target at least 44 points high, full notes/estimate in its accessible label, editor opening from preview and lower metadata area, original title/notes retained and no accidental completion. The previous capture visibility and original cloud note/ended-Focus cold-route flows also pass unchanged (two more cases). Four functional and four flagged diagnostic screenshots were individually inspected.

Both unfiltered audits complete all four viewports and still fail. Normal has 3 text-clipped findings: Choose a photo in the editor, search and description preview in the saved list. Largest has 3: 25-minute capture suggestion, search and description preview in the saved list. Neither reports hit-region or insufficient-description findings; the prior three normal saved-row hit-region findings are absent. The photo finding was absent in the previous run; its cause is unestablished. Largest setup completed this time, which does not establish why prior input failed. Photo/suggestion text is legible in the inspected captures and the row preview intentionally ends in ellipsis; no finding is suppressed or declared false. Full accessibility and actual VoiceOver acceptance remain open. See `row-accessibility-evidence.json` and `accessibility-audit-reports/row-normal.txt` / `row-largest.txt`.

The entire original cloud cache and original widget account/note/Focus/pending fields equal their baselines; pending sync is zero, local/cold-fixture preferences are false, and the original Mac cache is unchanged. Mac UI access was rechecked and remains locked. Every native result bundle is retained; duplicate exports were pruned after preserving the inspected evidence. Full P0 scope stays active.

### 11 October — installed medium A small window accepted

The isolated iPhone medium widget now has native installation/configuration plus resumed privacy, completion-refresh and cleanup evidence. Five tasks were created through native capture: three Client Work estimates (10/25/45 minutes), one unestimated project task and an unrelated Inbox task. The configured 45-minute, Client Work, All open tasks widget shows the three matching tasks, explicit future inclusion and 1 unestimated. Its terminated-app header opens the earliest matching task; after native completion it opens tomorrow's 25-minute task, and the inspected widget retains the remaining two estimates and unknown count.

The native system configuration's fifth privacy row requires scrolling. The first run tapped it before revealing it; a second revealed it but tapped the full-row center and left it off. Both failures are retained. The passing resumed run scrolls within the card, targets the visible toggle and verifies values 1 and 0. The inspected private layout hides task and list names while retaining estimates, scope and unknown count; its cold route still opens the expected task. This is composed evidence from the initial installation run and the final passing continuation, not a claim that the initial complete case passed.

Only the temporary widget was removed. The original cloud Today task, full note and ended Focus routes pass, the original two widgets are restored, the entire original cloud cache and original widget account/note/Focus/pending fields match their baseline, both queues are empty and the original Mac cloud cache is unchanged. See `medium-window-host-evidence.json`. The final continuation has 1 passing test, no skips or reported runtime warnings; six 60-second SpringBoard animation waits remain diagnostic overhead. About 298 MiB of duplicate exports were pruned while retaining every native result bundle. No production code changed in either repository; their independently owned widget sources remain identical.

The Mac test app is still running; the latest attempt to open its window reports a locked desktop. Other widget hosts/conditions, current accessibility findings and actual VoiceOver/keyboard journeys, native Mac ordering/account/restore flows, provider migration, external calendars/files and delivery/distribution gates remain open. The full P0 objective remains active.

### 11 October — readable notes at accessibility text sizes

Both independently owned task-row implementations now let notes wrap vertically when an accessibility Dynamic Type size is selected. Standard-size rows retain the one-line preview. Mac linked notes also use unlimited lines with word wrapping in their native text container. No stored text, account contract or widget source changes.

Two native phone workflows pass at normal/light and largest/dark with zero skips or reported runtime warnings: capture notes and a 25-minute estimate, save, relaunch, verify the full-sized accessible details action retains the complete notes/estimate, open details from the row and lower metadata area, and preserve the full title/notes without completing the task. The normal preview stays compact; the largest preview has multiple lines and scrolls through the long note to its estimate. Long paragraphs still require scrolling; the inspected capture shows the tail, not the entire paragraph at once. Both app builds pass. Mac changed-row and linked-note interaction remain build-verified only, with the desktop still locked; the running local test process may retain the earlier binary until relaunched.

Both unfiltered audits complete all four viewports and still fail. Normal retains 3 text-clipped findings (photo label, search, compact notes preview). Largest drops from 3 to 2: notes clipping is absent; the 25-minute capture suggestion and native search remain flagged. Neither mode reports hit-region or insufficient-description findings. No warnings are suppressed or classified as false positives. The suggestion and photo labels are legible in the inspected captures, which does not resolve those audit findings. See `notes-wrap-evidence.json` and `accessibility-audit-reports/notes-wrap-normal.txt` / `notes-wrap-largest.txt`.

The original selected note and ended Focus cold routes pass a separate cleanup case. The whole original cloud cache and widget account/note/Focus/pending fields equal their baselines, pending sync is zero, local/cold-fixture preferences are false and the original Mac cache is unchanged. All native results are retained; duplicate exports were pruned after preserving eight inspected captures, all findings and viewport hierarchies in both repos. Actual VoiceOver/keyboard journeys, linked-note native interaction and the remaining P0/provider/distribution gates stay open.

### 11 October — durable completion before animation

Mac list completion now synchronously commits before success feedback and registers its existing Undo immediately. The former 420 ms delay could lose completion on early process exit. The independent iOS action is corrected too; its installed medium capacity continuation verifies native completion/relaunch, exact Tomorrow route and subsequent completion/Undo. Mac isolated Debug build passes, but changed Mac interaction remains unverified with the desktop locked. See `medium-capacity-host-evidence.json`; native Mac and full P0 acceptance remain open.

### 11 October — medium Project pulse host checkpoint

The independent widget sources remain identical. The installed iPhone medium pulse now passes project selection, private-name configuration, cold routes, completion/relaunch refresh and original cloud-widget cleanup with six inspected captures; `medium-pulse-host-evidence.json`. No Mac production change was required. Native Mac widget/runtime acceptance remains open with the desktop locked; large pulse and other named P0 gates are unchanged.


### 11 October — large Project pulse host checkpoint

The installed isolated iPhone large widget now passes native Studio selection, three complete attention titles, explicit recorded-history coverage, name privacy, cold routes and completion/relaunch refresh. Current progress advances from 1/5 to 2/5 while recorded completions advance from two to three; the two remaining attention titles stay visible. Six final captures and two setup-failure frames are inspected and retained in both repos; `large-pulse-host-evidence.json`. Five setup failures remain disclosed rather than counted as passing. The final case passes without failures/skips/reported runtime warnings, with eight SpringBoard animation waits retained.

Original cloud cache and widget account/note/Focus/pending fields equal their baselines, queues are empty, local/cold-fixture preferences are off and the original Mac cloud cache is unchanged. No production code changed and the independent widget sources remain identical. The latest isolated local Mac app was relaunched, but computer use explicitly reports a locked desktop; current native Mac interaction remains unaccepted. Desktop widgets, remaining usability/provider and distribution gates stay open.


### 11 October — linked notes touch journey

Normal/light and largest/dark iPhone linked-note workflows now pass: native capture, Save/relaunch, independent inline link → in-app browser → Close, title → complete unchanged editor, Save without completion, and original cloud return. Six captures are inspected; the synthetic unavailable host is intentional, and the largest paragraph still requires scrolling. A separate original selected note/ended Focus cold-route cleanup case passes. Whole original cloud cache and widget account/note/Focus/pending fields equal their baselines; queues are empty, local/cold-fixture preferences are off and the original Mac cache is unchanged. See `linked-notes-native-evidence.json`.

The first two cases failed only at cloud return because the agent disabled Xcode signing during the test build, dropping embedded Simulator entitlements. Restoring the normal build settings recovers the existing session; no product auth change or new login was required. The iOS signing tool now checks actual app/widget embedded Simulator application/App Group identity before and after signing, in addition to real-team signatures. All failed native bundles and two failure hierarchies remain retained. No production app code changed. Existing normal 3/largest 2 audit findings, VoiceOver/keyboard, native Mac linked-note interaction and broader P0 gates remain open.

### 11 October — real Todoist provider import and replay

With explicit user authorization, the existing Todoist account was used as a read-only source. Its existing API token was copied directly through native controls into the isolated Mac app; no token regeneration or Todoist task/project mutation was performed. The deployed importer remains version 41 and uses only GET requests to Todoist. A fresh authenticated Taskfold destination was verified empty before import.

The native preview and first confirmed receipt contain 23 projects, 88 sections, 5 labels, 252 root tasks, 24 subtasks and 94 comments. The 276 active source tasks exceed the 200-item page limit, exercising real pagination. A second native preview/import creates zero records and skips all previously imported projects/sections/labels/root tasks. Complete ordered database fingerprints for all four destination entity tables and 368 source mappings are identical before and after replay. Normal app quit/relaunch retains the authenticated destination and all six counts, with no pending sync changes. Success clears the transient token; the temporary clipboard was replaced. See `todoist-live-provider-evidence.json`.

The original Mac account's seven task/organization/filter/pin/Focus tables equal the established canonical phone baseline and its queue is empty. Its whole cache file differs from the older Mac hash after the running app caught up; byte-for-byte equality is not claimed. No private task content, source identity, credential or raw cache is committed.

This accepts real provider authorization, multi-page snapshot, native Mac import, unchanged duplicate-safe replay and normal-launch persistence. The repeated real import followed a confirmed success; actual lost-response recovery was not injected. iOS real-provider native interaction and paired imported-account sync remain unverified. The Mac accessibility tree combines count/receipt values under their first label even though all visual labels are present; actual VoiceOver acceptance remains open. Broader native Mac, accessibility, provider/delivery, widget host and distribution gates still apply; full P0 acceptance is not claimed.

### 11 October — independent importer accessibility rows

Both independently owned importer views now expose an explicit label/value for each of the six preview counts and ten receipt rows, plus separate warning elements. This fixes the live Mac observation where a grouped form merged all values under its first label. The final isolated Mac native computer-use walk verifies those elements, failed-save explanation, visible Retry and successful token clearing; three screenshots were inspected inline. Its automated XCTest attempt failed before executing the case because macOS timed out enabling automation mode. An intermediate static-text-trait variant reintroduced merging and was removed; no passing automated Mac result is claimed.

Normal/light and largest/dark phone walks pass all count/receipt labels and values, token validation, warnings, failed-save retry, clearing and empty reopening. The first largest run failed only because equal visual edges differed by floating-point rounding; the retained failure reports 700.3333333333334 versus 700.333333333333. A 0.001-point measurement tolerance fixes that test assertion, and the largest rerun passes. Eight captures are inspected and retained. At largest text, labels wrap and the long form requires substantial scrolling; the final receipt capture shows its last rows, not all ten simultaneously. See `import-count-accessibility-evidence.json`.

The original cloud note and ended Focus cold routes pass separately. The entire phone cloud cache and widget account/note/Focus/pending fields equal their baselines; both queues are empty, local/cold-fixture preferences are false and seven Mac shared tables equal the canonical account. Both final app/test builds pass. Temporary Mac build products and duplicate exports were pruned while every native result bundle remains retained. This is scoped native/AX acceptance; full VoiceOver, keyboard, real lost-response recovery, iOS real-provider/paired imported-account flows and broader P0 gates remain open.

### 11 October — Mac task-row focus, linked notes and durable completion

Native CUA testing caught white selected-row text on a gray background while the notes editor had focus. Mac task lists now pass their explicit focus state to task rows, combined with window activity. The first environment-only adjustment failed the focused-list visual check and was replaced before commit. Final native screenshots show readable white text on accent selection and dark text on gray inspector-focus selection. Each project board column and Calendar day list has the same focus wiring; those variants are compile-verified only. This is AppKit-specific; iOS code and persisted contracts remain unchanged.

The synthetic native task retains its exact raw linked note and 25-minute estimate across relaunch. Clicking its inline link reaches the link monitor while another task and inspector remain selected; the UI-test handler intercepts external opening, so actual browser handoff remains open. Clicking the title opens exact full details. Row completion, native Command-Z Undo, restored-task relaunch, subsequent completion/relaunch and Completed inspection all pass. This supersedes the earlier build-only checkpoint for changed Mac completion/Undo. Observation precedes quitting; arbitrary forced-kill timing is not claimed. See `mac-linked-completion-evidence.json`. Actual VoiceOver, broader keyboard, paired provider sync, other widget hosts and distribution remain open.

### 11 October — native Mac ↔ phone favorite and board preferences

The native Mac View Options menu now has verified favorite/board continuity: add favorite and select Board, quit/relaunch Mac, receive the same stable-ID favorite and Board setting in a separate signed-in iPhone Simulator app, relaunch phone, then remove the favorite and select List on phone. The Mac receives both changes and retains them after quit/relaunch. One actual native phone case passes with zero failures/skips/reported runtime warnings; three inspected captures are retained. Seven task/organization/filter/pin/Focus tables remain exactly equal to their pre-test baseline and match across devices. All view preferences match, favorites are empty again, and both queues are empty. A default-valued project preference row remains after the intentional layout changes. See `mac-phone-view-preferences-evidence.json`.

This accepts this favorite/layout round trip, not reordering or concurrent edits. The Mac uses its existing isolated binary; favorite/layout persistence paths match current source, while unrelated later focus/capture changes are outside this run. The phone uses a separate bundle, session service and App Group, preserving the primary Simulator test installation. Real imported-account sync remains open: interactive Simulator.app is absent, and an attempted existing-session read timed out without a usable fixture. XCTest native auth and UI remain available.

Visual review found an open premium usability defect: compact note previews can be blank when stored notes begin with a newline. Both Mac board and phone list show it for the synthetic continuity task; complete raw notes remain unchanged. Correct the preview in both independently owned apps without rewriting saved text. Broader P0 accessibility/provider/widget-host/distribution gates remain open.

## 2026-10-11 — leading-newline note preview corrected

Resolved `compact-leading-newline-note`: both apps now trim surrounding whitespace only for row display, so a leading newline cannot hide the first content line. Full stored/editor text stays exact. Standard previews remain one line; accessibility sizes wrap. Both native builds pass, with three actual iPhone UI cases passing and no failures, skips or reported runtime warnings. Plain-note relaunch and padded linked-note browser/details journeys were verified; eight inspected captures are retained. Native isolated Mac plain and linked previews, exact raw editor text after relaunch, and intercepted inline-link routing passed. Mac external browser delivery and actual VoiceOver remain unaccepted.

Every cached table in the original account matches the pre-test baseline on both Mac and phone, including tasks, planning, notes, Focus and view preferences; both pending queues are empty. See `note-preview-native-evidence.json`. This supersedes the previous open preview finding, without closing the remaining provider, accessibility, widget-host or distribution P0 gates.

### 11 October — explicit native organization ordering

Both independently owned apps now offer Move Up/Move Down in project, favorite and saved-filter context menus, alongside existing drag controls. Moves use the existing durable ordering transaction and disable at either end. Mac actions participate in native Undo/Redo. Two Mac drag attempts did not change project order; this records those attempts rather than claiming a general drag defect.

Native isolated Mac creation, all three ordering families, project Command-Z/Shift-Command-Z, independent favorite Move Down, boundary states and quit/relaunch persistence pass. Phone acceptance is composed: a first run verifies project/favorite menu changes and favorite relaunch persistence, then fails because the test queried virtualized offscreen project rows. The corrected continuation scrolls to projects and passes persisted orders, disabled boundary, Move Down and original cloud return: one actual case, zero failures/skips/reported runtime warnings. The full initial case has not passed end-to-end. Its earlier fixture-order assumption failure and both native result bundles remain retained. Repeated 60-second context-menu animation-idle waits are preserved as diagnostic overhead. Three captures are inspected.

Every cached table in the original account remains equal to its baseline on Mac and phone; queues are empty. See `native-menu-ordering-evidence.json`. This accepts local native menu ordering, not new cross-device ordering/concurrency or VoiceOver coverage. Existing real iOS provider/imported-account, external delivery, widget-host and distribution gaps remain open.

### 11 October — native iPhone real Todoist provider replay

The secondary isolated phone app signs into the existing Mac-imported disposable Taskfold account through native authentication, calls the real deployed provider route, verifies all six preview counts, replays import with zero additions and expected skip counts, and verifies cleared token/receipt after normal relaunch. One actual native case passes, with zero failures, skips or reported runtime warnings. The earlier navigation attempt failed before reaching the importer; ordinary list swipes replace the test's ineffective edge drags.

All four complete Todoist source collections (projects, sections, labels, tasks) retain equal canonical SHA256 fingerprints across this replay. Five destination table fingerprints are unchanged. Phone tasks/projects/sections/labels exactly match the pre-replay Mac workspace and its queue is empty. No source content or credentials are in the repository. Separate source comment/user fingerprints were not captured. This extends the earlier Mac first-import evidence; it does not prove a fresh first import on iOS, a lost real save response, or full VoiceOver. The refreshed imported-account Mac app is blocked at saved-session Keychain access pending human approval, so native Mac return remains open. See `todoist-ios-real-provider-evidence.json`.

The native imported-workspace receipt follow-up also passes: the same Mac-created synthetic task opens on phone with exact full notes and its 25-minute estimate. No task is edited. Native sign-in restores the secondary phone app's original account and normal relaunch retains it. All cached tables in the original account equal the baseline on both Mac and phone; the imported phone cache also equals its Mac baseline, with all checked queues empty. The first follow-up tapped the independent notes link at row center; the corrected test taps the title. Both successful runs contain one actual case each, with zero failures/skips/reported runtime warnings. The temporary provider token is removed and the computer-use runtime reset after verification. Duplicate exported recordings/events are pruned (100,769,906 bytes), while native result bundles and failure hierarchies remain retained. Native Mac return still awaits the pending OS approval.

### 11 October — native imported-workspace round trip

The user unlocked the Mac and approved its isolated app's Keychain prompt. Native Mac → phone → Mac notes handoff now passes in the real imported destination: full original notes and 25-minute estimate, Mac note edit/relaunch, exact phone receipt and return note save/relaunch, then native Mac full inspector receipt and final quit/relaunch. The phone case passes with zero failures/skips/reported runtime warnings and restores the original account through native authentication. All 14 imported cache tables match across apps; every imported/non-synthetic row remains unchanged, only the synthetic task description changes, and all four checked account/device queues are empty. Original-account cached tables are unchanged on both devices. No Todoist request occurs in this phase. See `imported-workspace-native-handoff-evidence.json`.

Computer use returned stale filtered-row accessibility IDs/content and one invalid element ID; visual task identity and exact inspector values were verified before accepting the return. Controls are explicitly rebound after process relaunch. This observation does not establish a VoiceOver pass or a product data-filtering defect. The earlier Keychain blocker and native imported-account return gap are resolved for this binary/workflow; real lost-save-response recovery and the other current P0 requirements remain open.

### 11 October — native Mac profile-photo workflow

The isolated signed-in Mac app now passes actual image-picker cancellation with an unsaved display-name draft, native synthetic checker selection/upload, visible loaded avatar, normal quit/relaunch persistence, native Remove Photo and a second quit/relaunch to the placeholder. Upload changes only the avatar field; it does not submit the name draft. Relaunch discards that unsubmitted draft as expected. The final complete profile equals its baseline, all 13 non-profile cached tables remain unchanged, and the pending queue is zero. The original Mac account cache also remains unchanged. The exact synthetic Storage object was removed through its owner-authenticated API, its absence verified, and only the cleanup session revoked. See `mac-profile-photo-native-evidence.json`.

Screenshots and the downloaded 512-pixel checker JPEG were inspected; no private source captures or raw caches are committed. No production code changes or new Mac XCTest result are claimed. Seven SwiftUI AttributeGraph cycle warnings occurred in the terminated process, without a visible failure during these actions; their cause remains unresolved. The desktop locked after the final native acceptance. Native Mac account switching during upload/dirty drafts, paired profile receipt, actual VoiceOver/keyboard and broader P0 acceptance remain open.

### 11 October — native Mac account switch with late photo response

The Mac now passes native dirty-draft account switching and a real photo upload whose response is held after HTTP completion: sign out of the original account, sign into the second account, create a second unsaved name, release the original response, and verify that the second avatar/draft stay intact. Return to the original account restores its original name and placeholder; normal quit/relaunch retains that account. The initial imported test account is restored afterward. Both accounts' complete 14-table caches equal their baselines and both queues are empty. Exact synthetic upload objects from both attempts were verified and removed using only their owners' authenticated Storage API. See `mac-profile-account-switch-native-evidence.json`.

The first attempt exposed a DEBUG test-harness issue: the sandbox denied the legacy `/private/tmp` marker write. Both repos now also accept a UUID marker basename resolved inside the app's own Application Support/Taskfold directory, retaining the same allowlisted test bundles, disposable email/account guard, launch flag and legacy Simulator path. Release behavior is unchanged. Both native builds and the secondary iOS strict signing checks pass; no new iOS runtime or Mac XCTest result is claimed. The held run had no AttributeGraph warnings; the normal relaunch reported seven, still unresolved. Cloud/cross-account restore and the broader P0 checklist remain open.

### 11 October — cloud restore acceptance

Native Mac export and cross-account cloud restore now pass with an encrypted safety copy, 14 additions, unchanged original/imported work, stable task references, duplicate-free repeat review and normal relaunch. Both apps independently fix merged restore accessibility counts. One dark largest-text iPhone regression passes with no failures/skips/reported runtime warnings. See `mac-cloud-restore-native-evidence.json` and the current P0 status. External provider transfer, actual VoiceOver and broader release gates remain open; seven Mac AttributeGraph warnings remain unresolved.

### 11 October — restored workspace reaches the native iPhone app

The Mac cloud restore now has actual native iPhone receipt of project/section, label, saved-filter membership, exact task notes/estimate, full pinned note and ended Focus, including normal relaunch and native original-account return. One case passes with zero failures/skips/reported runtime warnings. Both accounts' 14 shared tables remain unchanged on both devices and all queues are empty. Four captures were inspected; the pale next-session picker context is addressed by the focused fix recorded below. See `mac-cloud-restore-phone-evidence.json`. External provider transfer and the broader P0 gates remain open.

### 11 October — Focus task picker readability fixed

Both independently owned Focus views now give the selected task a neutral, appearance-aware title and context foreground, preventing inherited accent tint from washing out text on the rose button surface. Native Mac light/dark selection passes; cancelling a different task search retains the chosen Studio task. Two signed iPhone cases pass in light and dark largest text, including duplicate-title disambiguation, cancellation, start/pause and normal relaunch (zero failures/skips/reported runtime warnings). Four targeted captures were inspected; the two phone picker captures are retained in the iOS repo. At largest text, lower controls require scrolling and the test successfully reaches Start.

Both builds and strict iOS signing checks pass. Both Mac cloud caches remain exactly unchanged; after returning the secondary phone to cloud mode, both accounts' 14 shared tables match baseline and both phone queues are empty. No Todoist requests were made. See `focus-picker-contrast-evidence.json`. This closes the observed pale picker-text finding only. Full VoiceOver/keyboard acceptance, existing clipping findings, seven earlier cloud Mac Settings AttributeGraph warnings and broader P0 gates remain open; no new Mac XCTest pass is claimed.

### 11 October — Focus notification permission feedback

Native Mac testing reached the isolated app's actual OS authorization request, which remains pending. The disabled Focus alert toggle gave no explanation during that wait. Both apps now show “Requesting permission…” while the request is active. Both app builds and strict iOS Simulator signing pass. The existing native iPhone scheduling/pause/resume/relaunch/end workflow passes in 60.674 seconds with zero failures/skips/reported runtime warnings. The secondary phone returns to cloud mode; both accounts' 14 shared tables match baseline, both phone queues are empty and both Mac caches are exactly unchanged.

Mac delivery and notification actions remain unverified: computer use refuses the macOS UserNotificationCenter app, and a human permission handoff is pending. The rebuilt indicator's pending-state appearance has not been inspected; the original wait was observed in the preceding binary. No broader notification/VoiceOver acceptance is claimed. See `focus-alert-permission-evidence.json`.

### 11 October — native Mac/phone cloud project ordering round trip

The isolated Mac app created two empty projects in the synthetic continuity account, used native Move Up to show Beta/Alpha, and retained that order after normal quit/relaunch. The iPhone receives the same identities/order, retains them after normal relaunch, uses native Move Up to return Alpha/Beta and retains that return after another relaunch. One actual iPhone case passes in 184.771 seconds with zero failures/skips/reported runtime warnings; two 60-second Simulator animation-idle diagnostics remain disclosed. Three phone captures and one inline Mac capture were inspected. Mac receives the return through Command-R Sync Now and retains Alpha/Beta after a further normal quit/relaunch.

All 13 non-project tables and the original project are exactly unchanged; all project rows match across Mac/phone and both queues are empty. The only retained additions are two empty synthetic projects. See `native-project-order-handoff-evidence.json`. This accepts sequential native project ordering across Mac/phone; concurrent ordering, saved-filter/favorite ordering handoff and offline conflict variants remain open. No automatic-refresh timing, new Mac XCTest or VoiceOver acceptance is claimed.

### 11 October — Mac Focus authorization, pause/resume and background delivery

The human-approved permission request now completes successfully. Native Start Focus schedules exactly one OS alert; Pause removes it (zero pending), and Resume restores exactly one. A near-term fixture timer is then delivered while the app is hidden: macOS usernoted records actual alert/lock-screen/Notification Center delivery and banner presentation. A second near-term timer also produces a banner. Opening Focus manually after the first delivery shows Time well spent / Time remaining 00:00, and the task remains open with its original identity and zero queued mutations. See `mac-focus-alert-native-evidence.json`.

The notification's actual Open action remains unverified. Computer use exposes only the desktop calendar widget in Notification Center, and its key sender does not support the Fn modifier needed for [Apple's Notification Center shortcut](https://support.apple.com/en-ie/102650). A human click on the delivered alert is pending. Task reminder Complete/Snooze/Move to tomorrow, terminated-app delivery and physical/APNs acceptance remain open. This supersedes the earlier pending authorization boundary only; the newer permission-progress view's pending appearance is still uninspected.


2026-10-11 concurrent ordering: a real phone-offline/Mac-reorder/reconnect defect produced an order neither device selected. The Mac now owns the same complete ORDER command, atomic RPC migration, replay/Undo/Redo semantics and retry-identity tests as independently maintained iOS code. Both builds and core/server contracts pass; native post-fix concurrency awaits the rebuilt isolated app's Keychain approval. Do not close that gate from core tests. The user's Focus alert click launched a duplicate test build into the wrong test workspace; a single-build fresh alert is delivered and its Open check remains pending. See `atomic-organization-order-evidence.json` and `mac-focus-alert-native-evidence.json`.


### 11 October — current native accessibility diagnostic recheck

The current signed iPhone Simulator build completes four diagnostic viewports in normal/light and largest/dark appearance. Both opt-in audit cases fail, with two retained clipping findings each: native Search inbox and the normal one-line notes preview; native Search inbox and the largest estimate chip. Neither editor viewport reports a finding for the selected description/hit-region/clipping categories. The earlier photo-action warning did not recur. All eight captures were inspected and retained in the iOS repository. Visually complete text is not treated as proof that an audit finding is false or that VoiceOver passes. See `accessibility-recheck-evidence.json`.

A padding experiment did not reach its iOS audit because native input setup failed; its isolated Mac compile also failed signing configuration. Both source changes were reverted. No production fix or Mac runtime acceptance is claimed. The explicit primary cloud-return case passes, including normal relaunch, with no reported runtime warnings. Every prediagnostic cached row and both pending queues are preserved: primary queue zero, secondary queue one complete offline ORDER command. Primary also fetched two existing cloud test projects and one view preference; all 14 shared tables match the retained cloud baseline apart from the intentional offline project ordering. No Todoist calls were made. Full accessibility and broader P0 acceptance remain open.


### 11 October — complete project order survives native Mac/phone concurrency

After Keychain approval, Mac native Move Down twice produces Alpha/Beta/original while the phone retains its offline original/Beta/Alpha intent. Phone reconnect and normal relaunch now pass in one actual native case (25.856 seconds, zero failures/skips/reported runtime warnings). Mac receives original/Beta/Alpha through Command-R Sync Now and retains it after normal quit/relaunch. Both devices have identical unique project indices 0/1/2, empty queues, and all 14 shared tables match exactly; every original row and non-order field, including all three tasks, matches the pre-reproduction baseline. This closes the reproduced mixed-order defect for updated native clients. See `atomic-organization-order-evidence.json`.

The phone capture was inspected but precedes scrolling to project rows; it is not visual proof of their order. Actual native assertions, Mac AX inspection and complete persisted rows establish the order. The isolated Mac also shows a widget-completion permission error because this ad-hoc test variant lacks an App Group entitlement and its namespace no longer matches the private debug projection route; clean runtime and installed Mac widgets are not accepted by this run. Automatic-refresh timing, other concurrent organization lists, filter/favorite ordering handoff, legacy active-client behavior and the full P0 gates remain open. The Focus app still shows Inbox, with no new macOS notification-response receipt since the fresh alert; its Open action remains unverified.


### 11 October — native saved-filter and favorite ordering handoff

Mac creates two synthetic Planned today filters and two favorites of its existing empty test projects, then places Beta above Alpha in each list. Both orders survive normal Mac relaunch. The signed iPhone receives those exact identities/orders, retains them after relaunch, moves Alpha Up through each native context menu and retains both returns after another relaunch. One actual case passes in 310.241 seconds with zero failures/skips/reported runtime warnings; four 60-second animation-idle diagnostics remain disclosed. Six captures were inspected and retained. Mac already shows both Alpha/Beta returns before any successful manual refresh and retains them after normal quit/relaunch; refresh latency was not measured.

Both devices' 14 shared tables match exactly and both queues are empty. Every preexisting row/field is unchanged, including all task content and project ordering. All prepared relationships/content are preserved; only filter/favorite positions and the server-maintained timestamps of the two new filters change. Exactly two saved filters and two favorites remain as synthetic test additions. See `native-filter-favorite-order-handoff-evidence.json`. No production fix or Todoist call was needed. The isolated Mac widget-storage permission error, other concurrent/offline variants, actual accessibility and full P0 gates remain open.


### 11 October — isolated Mac widget projection routing

The local, import/accessibility and Focus native acceptance variants now join the original isolated bundle in the existing DEBUG-only private widget projection route. Their ad-hoc builds lack App Group entitlements; falling through to the system route caused the observed Group Containers permission error. Each variant keeps its projection beside its own sandbox cache without enabling a widget fixture overlay. Release behavior is unchanged.

The isolated Mac build-for-testing succeeds. The older cloud variant was quit normally and the rebuilt product is running, awaiting macOS Keychain approval. Runtime disappearance of the error, projection persistence and cloud-row preservation remain unverified until that approval. This does not accept installed Mac widgets or close broader P0 gates. The existing Focus fixture still shows Inbox; Notification Center exposes only its desktop calendar widget, so the actual notification Open check also remains unverified. See `isolated-widget-storage-evidence.json`.


### 11 October — recurrence/reminder native verification scope

The current Mac-owned sources build in a fresh local-only capture-grammar variant. Its three selected cases do not execute because XCTest times out enabling automation; this remains an open Mac acceptance gate. The corresponding native iPhone workflows now pass bounded recurrence/completion, multiple quick reminder shortcuts, and independent repeating-reminder retention when a task becomes undated, plus deletion/relaunch. Two test assumptions were corrected (stable task-details targeting and waiting for actual keyboard disappearance before a capture); no application behavior changed. Five phone captures were inspected and retained in the iOS repository. The phone returns to its original cloud account with an empty queue, all 14 shared tables equal the earlier accepted baseline and original task content unchanged. Both P0 checklists now reconcile the completed import/account-switch/restore/ordering checks instead of listing obsolete environment blockers as current. See `capture-grammar-native-evidence.json`; full P0 remains open.

### 11 October — pinned-note preview layout

The Mac-owned widget now trims blank preview edges and uses two medium lines with a visible full-note action. Stored notes and reader text are preserved. The independent iOS implementation passes installed small/medium rendering and exact cold-reader routes; privacy was exercised in the initial medium workflow. Final owned Mac widget sources type-check. The app-only isolated build did not compile the extension; the actual signed widget build fails because automatic signing lacks Mac App Development profiles for the app/widget. Desktop acceptance remains open. Native v2 exercised identical small/medium sizing; the final source restricts fixed height to those families to retain large-layout flexibility. See `medium-note-host-evidence.json`.

### 11 October — large-note phone host receipt

The identical committed preview implementation now has an actual installed iPhone large-host receipt for the original short cloud note: public/private rendering, exact terminated-app reader routes, relaunch and temporary-widget cleanup pass. The original first-page note/Focus selections remain, and all 14 shared tables match across both phone workspaces and Mac with empty queues. Initial Home-page displacement/helper failure and successful recovery are disclosed. No additional Mac source change or Desktop acceptance is inferred; signed-widget profiles and other P0 gates remain open. See `large-note-host-evidence.json`.


### 11 October — focused Repeat activation and native grammar receipt

The local-only native walk found and fixed Space completing the selected task while Repeat owned focus. The inspector now has a full-width focused button with explicit expanded/collapsed summary, and the AppKit monitor handles task shortcuts only for the focused task-list table. Repeat click/Space and preserved task identity pass; list Space creates one expected bounded successor, Command-Z restores it, Return edits and Escape clears selection. The earlier button-only/focus-only attempts failed and were undone on synthetic data. Updated application/XCTest sources compile; native CUA execution supplies the current acceptance, not a new XCTest result.

Mac bounded capture/deadline/estimate, three reminder shortcuts, independent rule validation and undated retention/removal now survive normal relaunches. Delivery is off in this isolated fixture. Both repos retain scoped evidence; the iOS app receives no AppKit implementation or new build dependency. See `mac-repeat-keyboard-native-evidence.json`. Broader keyboard/VoiceOver, board/calendar shortcuts, untested grammar variants and release gates remain open.

A separate warm cloud Settings/inspector diagnostic adds no AttributeGraph warnings (six before and after), with all 14 imported tables unchanged and an empty queue. Original warning cause remains open; `mac-settings-cycle-diagnostic-evidence.json`. The existing Focus app still shows Inbox after the latest unlock; notification Open is not accepted.


### 11 October — board/calendar task-table keyboard continuity

Focused board and calendar task tables now join the main task list in the native shortcut router, preserving the inspector Space fix. Calendar day-panel accessibility containment keeps its table identifier distinct. Actual board and visible calendar day-table Space completion, Command-Z restoration, Return editing and Escape clearing pass; inspector Repeat keeps its own Space expansion. Calendar grid/card keyboard journeys remain open. Current owned/staged sources match and the final app-only build succeeds. See `mac-task-surface-keyboard-evidence.json`.

A separate largest-text phone audit still reports estimate-chip and native-search clipping after an allocation-rounding experiment. That experiment is reverted in both repos; no layout fix or audit clearance is claimed. Original phone cloud return/relaunch passes with all 14 shared tables unchanged and an empty queue. Updated current counts are two normal/two largest. See `chip-rounding-audit-evidence.json`.


### 11 October — readable attachment previews and local file lifecycle

Native file import revealed internal UUIDs leading Quick Look titles. The Mac inspector now places the sanitized original filename inside a unique temporary directory; iOS owns the same behavior independently. Native Mac picker cancellation, exact PNG import, normal relaunch, preview/return, removal and second relaunch pass, with all local tables restored and no pending mutations. The strengthened iPhone title/removal/relaunch case and original cloud return also pass; 14 shared tables remain unchanged. See `attachment-preview-filename-evidence.json`. Native Mac cloud attachment handoff and external file-provider acceptance remain open. The existing Focus fixture still shows Inbox after the latest unlock, so notification Open remains unaccepted.


### 11 October — reliable caret after reference selection

Native Down/Return reminder selection exposed the caret remaining inside the inserted token; continued typing removed the reminder. The Mac modifier now moves the insertion point after native text storage updates, guarded against a changed draft. Native keyboard selection/typing/save, normal relaunch and retained reminder/estimate pass. Mouse-selected quoted project completion also preserves following typing. iOS owns the same correction independently, with four normal/XXXL phone/tablet regressions passing and original cloud return preserving 14 shared tables. See `capture-suggestion-caret-evidence.json`. All preexisting Mac local records are unchanged; the named synthetic capture is retained. Cloud Mac attachment handoff still waits on its existing Keychain prompt; no restart, full accessibility or notification Open clearance is claimed.


### 11 October — iPad long-note host acceptance and plan accuracy

Installed iPad medium/large Pinned note now passes a scoped local long-note workflow: exact 1,855-character reader text from a terminated app, retained task after relaunch and removal of temporary instances. Four native captures were inspected; original local records are unchanged and the queue is empty. The final run explicitly resumes medium after three disclosed test-setup failures and freshly installs large; animation/AX diagnostics remain. See `tablet-long-note-host-evidence.json`. No Mac application code or build dependency changed.

The P0 work summary now reflects previously accepted concurrent project ordering and filter/favorite handoffs. Existing Focus inspection after the latest go/unlock reply still shows Inbox, so actual notification Open is unverified. Native cloud Mac work still waits on the existing Keychain prompt; full P0, installed Mac widget and distribution gates remain open.


### 11 October — capture and inspector chip keyboard fidelity

Fixed native focus return selecting and replacing the entire draft after a chip action. Both Mac title editors now restore an insertion point after AppKit focus updates; native Delete/forward Delete decline the focused chip. Inspector Tab now reaches a suggestion before applying it, with parsing deferred until focus leaves the title/chip region. Native multi-chip isolation, Space/Delete/Escape, continued typing, inspector literal-title save, ordinary priority parsing and normal relaunch pass. Final app-only build and two regression cases compile. All preexisting records are unchanged; one named local synthetic task is retained. See `mac-chip-keyboard-evidence.json`. iOS keeps its separate implementation and receives evidence updates only. Full VoiceOver, existing clipping, rapid-quit autosave timing and wider P0 gates remain open.


### 11 October — normal Quit preserves pending inspector work

Fixed an actual edit-loss window before the inspector's 600ms autosave: AppDelegate requests synchronous durable saves from open inspectors and cancels termination when a dirty draft remains. Native rapid Quit, real local permission failure with retained draft, permission restoration, successful retry and normal relaunch pass. All five saved tasks and all nine complete tables are restored exactly to baseline. Both final builds pass and a normal-Quit regression compiles; no new XCTest runtime is claimed. See `mac-quit-save-evidence.json`. iOS retains its independently owned explicit Save behavior and receives status evidence only. Forced termination, multi-window and authenticated handoff of this change remain unverified; wider P0 gates stay open.


### 11 October — import save uncertainty and genuine replay recovery

Both own import flows explain an interrupted save as uncertain and keep its approved source retryable. Own Mac importer tests pass eight cases; the app-only Mac test build and Release Core build pass. The real iPhone walk discards one actual HTTP 200 replay response and verifies native safe retry, token clearing/relaunch, unchanged destination/source and original-account return; `import-lost-response-evidence.json`. Its complete imported cache equals the established Mac baseline, retaining native Mac edits. The DEBUG discard helper is independently owned and absent from Release. Native Mac discard/retry and a first import whose new records commit before response loss remain open; no new Mac runtime pass is claimed. Wider P0 and external gates remain open.


### 11 October — compact Mac calendar card focus

Native testing reproduced two defects: compact cards ignored Return/Space without the day-panel table, and their combined accessibility element inherited completion as its primary action. Mac cards now own focus, select on primary activation, expose separate inspector/completion actions, and support Return, Space, arrows and Escape. Native compact Week/3 Days/5 Days, completion/Undo, hidden-inspector reopening, capture text isolation, normal relaunch and wide-layout Return pass. All five task business records are preserved; one completion revision advances and four expected completion/Undo activity rows remain. The final app-only test build succeeds and a regression compiles; no new XCTest runtime pass is claimed. See `mac-calendar-card-keyboard-evidence.json`.

The DEBUG local grammar fixture also avoids loading a cloud session at startup; normal/Release/authenticated launches retain their existing path. iOS receives documentation only and retains its independently owned implementation. Month/year grid navigation, full VoiceOver, existing clipping/widget warnings and wider P0 gates remain open. Existing Focus inspection after unlock still shows Inbox without a finished-session panel, so notification Open remains unverified.


### 11 October — compact month task access

Native month testing at 1080pt found a dead end: the day list was hidden and date activation only selected a date. The Mac now opens that date's existing day planner when the adjacent list is unavailable. Wide windows retain month selection and its side list; all dates expose selected state and a named Open day action. Native year → populated month → day → exact task/estimate, completion/Undo, an empty date, wide selection, named action and normal relaunch pass. All five task business records are preserved; one completion revision and two expected activity rows advance. The final app-only test build succeeds and the regression compiles, with no new XCTest runtime pass. See `compact-month-task-access-evidence.json`. iOS already keeps its own day panel below the grid and receives documentation only. Full grid keyboard/VoiceOver journeys and wider P0 gates remain open.


### 11 October — widget warning recovery

Fixed a real local retry defect in both independently owned Stores: consuming widget actions cleared internal status but left its old banner visible because local sync returned early. Retry now clears only the matching prior widget notice, and the error text no longer claims a completion is queued when checking an empty queue fails. Mac local warnings use a generic decorative icon. The grammar DEBUG bundle also uses private sandbox widget storage.

Native Mac reversible lock-file failure/recovery, immediate banner removal and normal relaunch pass with the entire five-task/nine-table cache unchanged and original permissions restored. The signed iPhone regression passes a queued recurring completion, failed durable save, same-process retry and relaunch; exactly one successor/receipt remains and the queue is empty. Native original-cloud return also passes with all 14 shared tables unchanged and no pending changes. Both builds pass; the Mac regression compiles without a new runtime claim. See `widget-warning-recovery-evidence.json`. Installed Mac widget, authenticated cloud-variant warning clearance, full accessibility and wider P0 gates remain open.


### 11 October — estimate chip touch target and literal title

Native iPhone testing found a 42.25pt normal-size estimate chip despite its 44pt layout minimum. iOS now uses a 48pt minimum, matching the composer’s other actions; the rendered target measures 46.09pt. Two signed native tests pass at normal/light and largest/dark text: complete accessibility strings and visible label, decline, exact literal title through save/relaunch, and reopening with the estimate still off. Final captures were visually inspected. The original cloud workspace return passes; all 14 shared tables are unchanged with no pending changes. Initial failures and the typing-harness correction are retained in `estimate-chip-reading-evidence.json`.

This does not clear the retained clipping audit: no unfiltered audit rerun or suppression occurred, and its 2 normal/2 largest findings remain open. Actual VoiceOver and wider P0 gates remain open. Mac receives evidence/status only; its desktop controls retain their independent implementation. The existing Mac Focus process was also inspected after the user’s unlock reply: Inbox remains visible without a finished-session sheet, so notification Open is still unverified.


### 11 October — Mac Month-grid keyboard navigation

A native date-selection walk found that Right Arrow paged the month instead of moving to the next date. The Mac Month grid now has focused-date navigation: Down enters the grid, arrows move by day/week, Return opens the exact day, and Escape returns to period navigation. Explicit calendar focus recovery handles native collection focus and recreated month grids. Complete date/task-count labels, selected state and primary/Open day actions remain available.

The final isolated normal/light wide-window walk passes keyboard entry, day/week movement, October 31 ↔ November 1, Escape/period navigation, and opening October 11 with its expected task and 25-minute estimate. All five tasks and nine complete raw tables remain unchanged with no pending mutations. The final build and new regression compilation pass; no XCTest runtime pass is claimed. See `month-grid-keyboard-evidence.json`. iOS retains its independent touch calendar and receives documentation only. Compact pointer, Year-grid keyboard, actual VoiceOver, iOS hardware-keyboard and wider P0 acceptance remain open.


### 11 October — Year-grid navigation and VoiceOver attempt

The Mac Year grid now selects months with the keyboard: Down enters navigation, Left/Right move one month, Up/Down move four months, Return opens the month, and Escape restores year paging. The selected month has a visible outline, selected accessibility state and an Open month action. Native normal/light wide-window checks pass month/row movement, December ↔ January, opening the populated current month, and Escape/year paging. Final relaunch and visual inspection pass. Both independently owned calendars also prevent a duplicate today outline in an adjacent month’s trailing cells; Mac rendering is inspected and iOS is build verified. Both builds succeed; the new Mac regression compiles without a new XCTest runtime claim. All nine raw local tables and five tasks remain exactly unchanged, pending queue empty. See `year-grid-keyboard-evidence.json`.

The authorized VoiceOver attempt verified off → on, passed the welcome prompt, closed the tutorial and attempted screen-reader navigation. Its output window timed out and app captures did not expose a reliable caption/cursor, so spoken-output and full journey acceptance remain open. VoiceOver was restored to off and verified in System Settings; the existing enabled caption-panel preference was not changed. Compact pointer, iOS hardware-keyboard, retained clipping findings and wider P0 gates remain open.


### 11 October — current capture/editor audit after chip sizing

Reran the unfiltered native iPhone audit against the current signed build after the estimate-chip touch-target change. Both cases complete all four viewports, then fail on two findings each: normal Search inbox/one-line notes preview; largest 25 min chip/Search inbox. Editor overview and subtask-action viewports have no findings in the selected categories. The larger chip target does not clear its text-clipping warning. All eight captures were inspected and retained with full reports/hierarchies in `accessibility-final/`; no suppression or false-positive classification was added. The harness now explicitly sets normal text and types the title one character at a time while asserting the complete value.

The build and strict Simulator signing pass. Native original-cloud return and normal relaunch pass; all 14 shared tables (and the full raw cache) remain exactly unchanged, pending queue empty and local mode off. Apple accessibility-framework duplicate-class and debugger-lookup console diagnostics remain disclosed despite no structured runtime-warning entries. About 238 MB of redundant attachment exports were pruned; original result bundles are retained. See `accessibility-final-evidence.json`. Actual VoiceOver, these retained findings and wider P0 acceptance remain open; another unchanged audit rerun is not the next action.

## 11 October — iOS Year calendar at largest text

A native phone walk exposed clipped month names and cropped rows in the four-column Year view at accessibility XXXL. iOS now uses scrollable full-width month rows at accessibility sizes, with wrapping full month names, counts and retained heatmaps. Scrolling those rows keeps Year expanded. Selected-month outline/semantics and an Open month action align with the independently owned Mac implementation. No persistence contract changed.

Normal/light and largest/dark Year → current Month → exact existing task → Cancel → normal relaunch pass. The final largest-text case verifies all twelve target rows fully inside the scroll viewport; their captures were inspected. All three local fixture tasks remain open with original IDs, titles and estimates. Native original-cloud return passes, with all 14 shared tables and the full raw cache exactly equal, empty queues and local mode off. See [ios-year-route-evidence.json](ios-year-route-evidence.json) for initial failures, strengthened tests, signing, captures and preservation.

This accepts the tested phone Year layout and route. Full Month-grid largest-text rendering, iPad Year layout, spoken VoiceOver and broader P0 acceptance remain open. The prior unfiltered accessibility audit still reports two normal and two largest clipping findings. The post-relaunch Today capture proves the native assertions' task state, not general large-text task-list layout acceptance. Mac receives this scoped evidence only; its independently implemented desktop Year navigation remains unchanged.

## 11 October — readable phone Month dates and return to today

The native largest-text Month baseline exposed dates clipped to their first digit, a truncated period heading and 38-point empty-date targets. iOS now presents full-width weekday/date rows at accessibility sizes, retains selection/task counts, reveals the selected date on entry and makes Today return to its row even when today is already selected. Normal Month retains its grid with 48-point date targets and enough height for six weeks. The accessibility period heading wraps above navigation, the collapsed calendar presents a measured full date with previous/next-day controls, and the selected-day summary uses concise readable text. A captured floating-button overlap prompted the final empty-day wording, No tasks.

Native normal/light Month and largest/dark Year pass in v3; the final affected largest/dark Month case passes in v4. First/last dates, fully visible Today return without extra scrolling, collapsed date navigation, exact existing task opening, Cancel/relaunch and retained open tasks pass. All twelve Year month rows pass native hit/viewport checks. Native original-cloud return passes; the entire cache, all 14 shared tables and empty pending queue are exactly preserved, with local mode off. The three fixture tasks retain their IDs, titles, estimates and open states. See [ios-month-route-evidence.json](ios-month-route-evidence.json) for signing, initial failures, build scope, captures and preservation.

This accepts the named phone Month/Year routes, not all calendar accessibility. iPad, spoken VoiceOver, other period modes and broader task-list layouts remain open, alongside the four prior unfiltered capture/editor clipping findings. Mac source remains independent and unchanged; this checkpoint updates shared acceptance evidence and the Mac plan.

## 11 October — iPad Year viewport correction

The normal-text iPad Year grid could grow beyond its fixed pager: wide month heatmaps cropped the first and last rows. The iOS fix bounds each heatmap, allows its seven cells to shrink below SwiftUI's default ten-point minimum, and sizes the card/pager around a scaled heading. Native tests now require every normal-text month card to fit completely inside the actual calendar pager and above the collapse handle. The initial green test did not check that viewport and is superseded. See `tablet-calendar-evidence.json` and the before/after captures in `tablet-calendar/`.

This is independently owned iOS UI code. The Mac Year grid uses a scrolling container rather than the clipped fixed-height iOS pager; no Mac production change or shared build dependency was added. No persistence or synchronization contract changed. The initial landscape attempt was unaccepted: requested rotation still reported an 834 × 1210 portrait window, including after foreground activation; diagnostics are retained and the orientation assertion is not bypassed. The clean-device landscape follow-up below supersedes this limitation for its named routes. Full VoiceOver spoken-output acceptance remains open.

Accepted scope: four iPad portrait workflows (normal/largest Month and Year) and the final-build normal iPhone Year regression pass. All 26 protected iPad files and 43 protected iPhone files retain the exact original file sets and hashes. Both dedicated local fixtures retain their three open tasks, exact IDs/titles/estimates and empty queues. The collapsed Month capture includes an animation transition; the normal phone capture still shows add-button overlap on the second task row. These captures do not establish full visual or accessibility acceptance.

## 11 October — clean iPad landscape calendar routes

Three native landscape workflows now pass on a fresh disposable iPad Simulator: normal Year and accessibility XXXL/dark Month and Year, including actual wide-window assertions, complete target containment, selection, Today return, collapsed day navigation, exact task opening and normal relaunch. The existing iPad was preserved; its stuck portrait state and empty Control Center remain unexplained. A fresh device rotates correctly. Full-screen landscape captures replace demonstrably cropped/offset XCTest app-only images, and the final three cases pass again with that capture change. See `tablet-calendar-landscape-evidence.json` and `tablet-calendar-landscape/`.

The original iPad's 26 protected files and iPhone's 43 retain their exact file sets and hashes. The clean local fixture retains all three open tasks, exact IDs/titles/estimates and no queued edits. No backend, Todoist, persistence, Mac production code or shared build contract changed. The largest-text sidebar has awkward word wrapping, and a collapsed-date capture is mid-transition; those remain explicit polish findings. This accepts these three iPad calendar routes, not full navigation or VoiceOver. iPhone landscape, normal iPad Month landscape and other calendar periods remain open.

## 11 October — readable 3-day, 5-day and Week dates

A native iPhone accessibility-XXXL baseline failed full-target containment: a 120-point date control overflowed the 92-point pager. Its inspected capture shows the 11th rendered as a clipped 1 and following dates cut in half. At accessibility sizes, iOS now presents these periods with the same full-width, wrapping weekday/date/count rows as Month. Vertical scrolling stays in the date list; selection and Today reveal their date. Month and the short periods share that implementation, while normal-size date strips keep their existing layout.

The Mac owns a different wide-window day-column layout, with independently scrolling task columns rather than the phone's clipped 92-point pager. This correction changes iOS UI code only; no data contract, persistence or synchronization changes or sibling dependencies were added. Native acceptance and retained intermediate failures are recorded in `short-calendar-evidence.json`; this checkpoint does not establish spoken VoiceOver, phone landscape, or the Day hourly-planner layout.

Acceptance: five scoped case/device pairs pass, covering normal phone short periods, largest phone/tablet short periods and largest Month regressions on both devices. All fifteen date rows per largest short-period walk fit completely in their scroll viewport, with first/last selection, Today return, collapse, exact task and relaunch checks. Both original account file sets/hashes remain exact (26 iPad, 43 phone); both isolated fixtures retain three open tasks, exact IDs/titles/estimates and empty queues. The initial post-fix largest runs failed their scroll-driver checks and remain disclosed; final affected cases pass with smaller drags and virtualization-aware direction. Full P0 acceptance remains open.

## 11 October — reachable phone landscape calendar

A fresh disposable phone confirmed a compact-height defect: largest-text period controls were above the screen, and normal Year cards overflowed the pager. iOS now lets the calendar and shared task rows scroll vertically at compact height, with a shorter accessibility date viewport. Landscape Add moves into the toolbar so it cannot cover month cards; a plain button style and explicit outer frame fix its measured 36-point height to at least 44×44. Portrait/iPad retain their existing layout; no persistence or synchronization contracts changed. Mac owns its independent column layout and receives evidence only.

Three final landscape journeys pass: normal Year, largest Year and largest Month, including all twelve Year targets, Month first/last selection, original task, toolbar Add/date and relaunch. Focused normal/largest Add checks and portrait Month/three short-period regressions pass too. Six accepted native cases cover nine workflows; build/source limits and all failed intermediate runs remain explicit in `phone-compact-calendar-evidence.json`. Original iPad/phone protected file sets and hashes remain exact, and all three isolated fixtures retain three open tasks with exact IDs/titles/estimates and empty queues.

This does not accept all landscape usability: the largest Add capture partly hides date controls while the keyboard is visible, and nested-scroll ergonomics need further user testing. Other landscape periods, Day, full VoiceOver, the retained clipping findings and broader P0 gates remain open. The original phone still did not rotate in its attempted run; no reset or unsupported diagnosis was applied.

## 11 October — concise P0 gate tracking

Added `P0_PROGRESS.md` with a compact implemented/proven/remaining summary and bounded next execution order. `P0_RELEASE_STATUS.md` retains the detailed scoped evidence. Feature buildout is largely complete; notification delivery/actions, remaining native importer/provider boundaries, installed Mac widget/distribution gates and critical accessibility remain unaccepted. New iPhone capture verification is isolated from Mac code and real user data.

Follow-up: two native iPhone landscape capture cases pass date/project changes, save and persisted-record relaunch checks. No product change was required. Largest Today landscape visible-row acceptance and keyboard-visible composer polish remain open. Both protected account file sets/hashes are unchanged; see `landscape-capture-evidence.json`.

## 11 October — task Search and largest landscape reachability

TaskScreen now exposes on-demand Search with one native text field across orientations, an explicit Close action, keyboard submission/dismissal and the existing recent-query storage/menu. This frees the short task viewport and avoids failed minimized-native Close/conditional-search rotation candidates. Dated query changes scroll to the first match. Mac retains its independent Finder search; no persistence, synchronization or sibling dependency changes.

Four final native cases pass on one isolated iPhone: normal/light and largest/dark complete Today targets, exact editors/Cancel, relaunch, matching-result containment below Search, keyboard submission, Close/full-list return, recent reuse and portrait-query → landscape continuity; both landscape capture persistence regressions pass. Original 26/43 protected file sets/hashes remain exact; final local fixture retains three original open tasks, exact IDs/titles/estimates and no queued changes. See `landscape-today-evidence.json`, including failed candidates and their limits.

This accepts the named task/query targets. The saved-capture screenshot still has a partly hidden long row: capture persistence is proven, general long-row visibility is not. iPad/other scopes, actual hardware keyboard/VoiceOver, retained audit findings and wider P0 gates remain open.

### 11 October — real first-import response-loss recovery on iPhone

A fresh confirmed-empty disposable destination received 252 root tasks, 24 subtasks, 94 comments, 23 projects, 88 sections and 5 labels through the real Todoist importer. The Debug-only hook discarded that genuine HTTP 200 response. A host snapshot captured the committed five import tables before native Retry; all complete records remained exactly equal afterward. The native uncertainty/retry/receipt, empty importer after relaunch and original-account return passed in one 180.389-second iPhone case (zero failures/skips/structured runtime warnings).

Both repos pass eight focused import tests and Release core builds; response-loss controls are absent from both Release Backend objects. Source fingerprints and both existing accounts remain unchanged. This closes the iPhone first-import boundary only. Native Mac discard/retry remains open: its running local-test binary predates the hook and needs a controlled rebuild. See `first-import-recovery-evidence.json` for proof and limits.

### 11 October — Mac import retry build ready; system launch wait

The existing isolated Mac stage now builds current import Backend/flow/view and Models, with its own session service preserved. Native discard/retry has not executed. A development-team signing attempt triggered macOS existing-container identity consent; it was stopped and the prior ad-hoc Debug identity restored without changing sandbox entitlements. The current live process remains in sandbox initialization, before Store/sign-in. Dismissing any old prompt with Don’t Allow was requested; no new Keychain prompt or native pass is claimed. Both cached accounts and the imported account’s 15 server tables remain exactly unchanged; transient Todoist input was cleared.

Read-only revalidation still shows native reminder rollout off, zero active pilots, native sweep inactive and one local Apple Development identity, with no Developer ID/Apple Distribution identity. The existing web due-task cron is active and unchanged. APNs secrets were not inspected. See `mac-import-retry-readiness.json` for precise scope and the live launch handle.

### 12 October — bounded saved-capture evidence; P0 still open

Two strengthened iPhone capture cases pass functional access/editor-title assertions; one intermittent runtime publishing warning is retained and a clean unchanged largest repeat does not erase it. Original phone/iPad file sets are unchanged. The authorized VoiceOver attempt restored the observed off state but established no spoken pass. Mac retry remains before initialization in sandbox setup. Current main checklist now correctly records iPhone first-import recovery as accepted. See `saved-capture-access-evidence.json` and `P0_PROGRESS.md`.

### 12 October — iPhone presented Search accessibility correction

The actual open iPhone Search field now uses a short visible placeholder and retains its scoped accessibility name. Two unfiltered native cases pass across four normal/largest placeholder/query viewports, no warnings/skips. The refreshed broad audit still fails four other reports; inspected captures do not establish four visible defects. Protected device data is unchanged. Mac Finder code and release inputs remain independently owned and unchanged; native notification Open/import launch gates remain open. See `presented-search-audit-evidence.json`.

### 12 October — native paired profile handoff

The Mac now saves a test display name and selects/uploads a synthetic checker photo through its native picker; the dedicated signed-in iPhone receives and visibly renders both before and after normal relaunch. The phone changes the name and removes the photo; both survive its relaunch, Mac Sync Now and a normal Mac quit/relaunch. One focused iPhone case passes in 59.525 seconds with zero failures/skips/runtime warnings, alongside observed native Mac actions. The first attempt failed because the test driver placed its cursor mid-name; native Select All plus an exact pre-save assertion corrects that driver, and the full focused case passes. No production fix or automated Mac XCTest pass is claimed.

All 14 non-profile server tables stay equal at every phase. Owner-authenticated cleanup restores the exact original profile, including its timestamp, and removes/verifies absence of the two exact synthetic objects; all 15 server tables then equal baseline. Both final caches retain the original profile with zero pending changes. Protected primary phone/iPad file sets remain exactly unchanged (43/26 files). The Mac profile UI and both avatar-upload functions match owned sources; broader staged importer/recovery build acceptance is not inferred. The new Mac relaunch log has no AttributeGraph warning; the prior seven warnings remain unresolved because this does not establish their cause. See `profile-pair-evidence.json`. This closes the named sequential paired-profile receipt gate; concurrency/offline/mixed-client variants and other P0 gates remain open.

### 12 October — native Mac import replay recovery accepted

A fresh app-only acceptance workspace now copies all 61 current independently owned Mac Swift files with documented namespace substitutions. Its new fixed bundle/container and Keychain services use the existing Apple Development identity, avoiding the obsolete ad-hoc container's sandbox wait. Native sign-in, real provider preview, replay save, deliberate loss of the genuine successful HTTP 200 response, visible uncertainty/Retry, successful native Retry and automatic token clearing pass. Actual normal quit/relaunch preserves the session and leaves the importer token empty. The first Quit attempt exposed the first-run welcome sheet without terminating; Skip followed by normal Quit produces exit 0, which is the relaunch evidence. No automated Mac XCTest pass or warning-free run is claimed.

All 15 destination server tables equal their baseline before the discarded response, before Retry and afterward; all 14 native cached tables remain exact through relaunch, with 256 task rows, 368 mappings and zero pending operations. The two old Mac account caches and protected phone/iPad file sets remain unchanged. Todoist's projects/sections/labels/tasks GET fingerprints remain exact; comments are not independently fingerprinted. The preview counts 252 parent tasks and 24 embedded subtasks, explaining the provider's 276 task records. Transient token/clipboard contents are removed. The obsolete waiting process is retired only after the replacement is accepted, and 271,429,842 bytes of its reproducible build cache are pruned while original containers/logs remain. No further approval is needed for that retired import launch.

Eight Mac importer Core cases and current Debug/Release app-only builds pass. Both Release architectures exclude the response-discard marker. The preparation script retains its default variant and adds the fixed signed variant; only exact Debug bundle allowlists change app code. One NSTableView reentrancy warning occurred during initial cloud load and remains unexplained; the relaunch log is clean, and prior AttributeGraph warnings remain unresolved. See `mac-import-retry-native-evidence.json`. This closes the named Mac replay response-loss/Retry gate. iPhone first-import loss retains separate accepted evidence; no Mac first-import loss pass, installed Mac widgets, notification actions, APNs, external-provider, VoiceOver or distribution acceptance is inferred.

### 12 October — authenticated native Mac attachment handoff accepted

Native Mac selection of the repository checker PNG is received and previewed on the dedicated iPhone. One focused native test passes in 82.059 seconds with zero failures, skips or runtime warnings: the phone relaunches, edits the exact notes, saves and relaunches again, retaining its 64×64 Quick Look preview. Mac foreground sync receives the edited notes, then a normal quit (original PID absent) and relaunch retain both notes and the same native Quick Look image. Attachment metadata and all 166 bytes remain exact on the server. Both attachment UIs match their independently owned sources; no production fix or automated Mac XCTest pass is claimed.

Native undoable deletion removes only the newly created synthetic task and embedded attachment. All 14 non-activity server tables equal their baseline, all original activity rows remain unchanged, and exactly two synthetic created/deleted ledger entries remain in the owner-read-only ledger. The Mac queue is empty. Protected primary phone/iPad file sets remain exactly unchanged (43/26 files). This closes authenticated native Mac attachment receipt for the small embedded PNG; external provider transfer and remaining concurrency/legacy-client variants stay open. See `attachment-handoff-evidence.json`.

### 12 October — compact landscape keyboard-visible capture correction

Full-screen native evidence exposed the largest-text draft being cut through a line above its action bar. The independently owned iPhone composer now uses one native scrolling editing line while focused in compact height; regular height and unfocused capture keep the existing four-line maximum. Native normal/light and accessibility XXXL/dark cases verify the entire editing field inside its viewport, Save/More/Hide Keyboard above the keyboard with at least 44-point targets, exact title/25-minute estimate through More and normal process relaunch. Both pass (64.104/62.617 seconds), with zero failures, skips or runtime warnings. The final largest capture visibly shows the end caret. Earlier failed estimate queries/scroll gestures remain disclosed in `keyboard-capture-evidence.json`.

All 15 server tables and the authenticated dedicated-phone cache remain unchanged; protected primary phone/iPad file sets remain exact (43/26 files). Only the disposable local fixture changes. No Mac composer change or Mac native acceptance is inferred. The four prior clipping reports, earlier project-menu publishing warning, spoken VoiceOver and other release gates remain open.

### 12 October — current release prerequisite revalidation

Fresh development builds fail before compilation: without automatic provisioning, neither app nor extension profile is available. With `-allowProvisioningUpdates`, Xcode obtains the widget profile but explicitly rejects the containing app because team `3UZ4C73FM2` is a Personal Team and does not support its Push Notifications capability. One Apple Development identity, no Developer ID Application identity and no Apple Distribution identity are installed. No production entitlement was removed; no app was installed or replaced. See `release-environment-check.json` for build errors/hashes and scope. An enrolled team is the concrete next prerequisite for this build, separate from notarization and actual APNs delivery.

The existing Focus process remains alive at Inbox with no finished sheet, so notification Open is still unverified. Old checklist statements about unavailable Todoist access, first-import/replay response loss and current Keychain launch waits are reconciled with their later accepted evidence. This checkpoint changes status documentation only; it does not claim another functional gate passed.

### 12 October — native shared-access loss recovery

A genuine owner/member revocation now passes in the isolated native Mac app: four queued offline title/notes edits survive a normal relaunch, real HTTP denial saves an encrypted Access removed copy, unrelated personal work syncs, and native preview/apply restores the shared project/task as two member-owned copies. The original owner's task is unchanged. Both apps now retain an account-scoped device-local recovery notice across successful sync and relaunch until explicit dismissal, with a direct Backups & restore action. The Mac banner occupies workspace layout rather than covering the sidebar. Largest-text iPhone layout is separately exercised with an encrypted local fixture; this does not claim another server denial on iOS. See `access-recovery-evidence.json` for final test/build receipts and scope.

All 14 non-activity server tables in both disposable accounts match their original baselines; every original activity row is preserved. Twelve synthetic activity entries remain in the read-only ledger. Primary phone/tablet files and the imported Mac account cache are unchanged. Broader organization/new-creation/account-switch recovery variants and external file providers remain open. The Mac NSTableView warning remains; the misleading initial offline “Up to date” caption is recorded for follow-up.

12 October: native VoiceOver was temporarily enabled for the isolated signed app and restored to its original off setting. The VoiceOver output surface timed out; no spoken-output or traversal acceptance is claimed. See `critical-accessibility-evidence.json`.

12 October: sidebar sync status now requires a successful sync before showing its checkmark/time, shows Sync needs attention after interruption even with no pending edits, and wraps to two lines. Native offline/reconnect evidence is in `sync-status-evidence.json`.


### 12 October — system calendar events delivered to SwiftUI on the main queue

The retained saved-capture publishing warning is traced to the actual midnight notification, not the project menu: the historical runtime stack contains `__postAndResetMidnight`, Foundation Notification subscription and SwiftUI subscribers on a worker queue. Both apps now schedule day, time-zone, significant-time (iOS) and EventKit publishers before `.onReceive`. The Mac synchronous termination-save protocol is unchanged. A DEBUG isolated fixture posts day/zone notifications from an asserted background queue without changing system time.

The new iPhone regression reproduces the warning before the fix. Afterward it and the affected largest-text landscape capture pass (2 tests, no failures/skips/structured runtime warnings). Native Mac saved-list day/zone membership refresh passes with no publishing-warning records. Both Debug/Release builds pass. Mac cloud account caches and protected phone/iPad files remain unchanged. See `background-calendar-evidence.json`; existing clipping, spoken VoiceOver, other runtime warnings, notification actions, widget hosts and distribution gates remain open.


### 12 October — real Mac Focus delivery after normal Quit

A real local Focus alert now passes delivery to Notification Center after normal Quit: macOS records app exit at 02:56:17, before timer end and delivery at 02:56:26. The app remains stopped; explicit fixture-preserving relaunch retains the finished session, exact open task and zero pending alerts. The existing Do Not Disturb setting delays the banner and mutes sound, so visible-banner and Open acceptance are not inferred. The already-authorized binary is reused; Focus model, scheduler/view, delegate notification handlers and Store/Root notification sections match owned source, but newer unrelated code and pending-inspector Quit handling are not in that binary.

No production fix/build rerun was needed. See `mac-focus-terminated-evidence.json`. Open/actions/account-change/APNs and other P0 gates remain open. The relaunched isolated app is left on Today with no Focus sheet for the pending human notification click.


### 12 October — Focus chooser keyboard selection

12 October: fixed native Mac Focus chooser keyboard selection: Up/Down and Return now choose the correct filtered task/context. Empty-result Return and Escape are safe; mouse selection and paused-session normal relaunch pass. Debug/Release builds and test compilation pass; the automated Mac runner fails initialization before executing tests, so no XCTest runtime pass is claimed. Both cloud caches and all non-Focus fixture tables are unchanged. See `focus-keyboard-evidence.json`. iOS code is unchanged.


### 12 October - isolated Desktop widget host setup

12 October: the new isolated Mac app **and embedded widget extension** now provision/build/sign successfully with a separate App Group and URL scheme. This removes production Push provisioning as a prerequisite for isolated desktop-host testing. The native launch is live but the Mac is locked; no installed-host or rendered-widget pass is claimed. Production APNs/distribution gates remain open. See `mac-widget-host-setup-evidence.json`.
The Mac-owned preparation script now supports `--variant p0widgethosts`; it retains independently signed widgets, a private App Group and a private callback scheme while removing only the copied test app production Push/Keychain-group entitlements. Existing app-only variants remain available. Both staging modes pass isolation assertions, and all Swift files in the scripted widget stage match the successfully built stage. Native host testing waits for unlock; no product-runtime gate is closed.

Reproduce with a fresh temporary directory (preparation does not build or launch):

```sh
python3 Scripts/prepare_isolated_mac_ui.py --variant p0widgethosts --team 3UZ4C73FM2 --output /private/tmp/taskfold-widget-host-fresh
xcodebuild -project /private/tmp/taskfold-widget-host-fresh/Taskfold.xcodeproj -scheme Taskfold -configuration Debug -destination platform=macOS -derivedDataPath /private/tmp/taskfold-widget-host-products CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=3UZ4C73FM2 -allowProvisioningUpdates build
```

For cold widget routes, launch the isolated app in its local workspace and create test tasks through the native UI. Do not assume `--uitesting` survives an OS URL launch. Preserve the current development app while native acceptance is pending; do not replace production installations or use their App Group. An enrolled production team is still required for release capabilities.

### 12 October - compact landscape editor acceptance

The independently owned iOS TaskEditor now keeps its active input and caret above the onscreen keyboard at normal/largest text. Two native insertion/Save/relaunch cases pass without runtime warnings, with inspected captures and protected-data preservation. This is an iOS-specific layout change; Mac code is unchanged. See `landscape-editor-evidence.json`. Installed Mac widget and notification-action gates remain open; computer use timed out on the existing isolated host during this follow-up.

## 12 October - classified retained clipping reports

The four retained reports are now classified individually in `accessibility-clipping-classification.json`. The normal note is an intentional one-line ellipsis with full content retained and native editor activation verified. The normal photo label, largest 25 min chip and largest wrapped note are visibly complete in their exact audited captures; source layout and independent native action/persistence checks support scoped false-positive classifications. All original reports remain unchanged, and the diagnostic audit still records two failed cases. No whitelist, warning suppression or broad audit pass is claimed. These four reports no longer represent unclassified usability blockers. Spoken VoiceOver, other layouts and the remaining release gates are still open.


### 12 October — medium Focus recommendation widget

Fixed a real installed-host defect: long medium Focus titles were truncated. The final layout keeps the complete tested title, header, status, project and action inside the card. Native iPhone installation, overdue ranking, both exact terminated-app task routes, completion refresh, relaunch and cleanup pass (one test, zero failures/skips/reported runtime warnings). Earlier functional passes with truncation/overflow were rejected. Both independently owned widget implementations build in Debug/Release; no installed Mac pass is claimed. Authenticated caches and protected phone/tablet files are unchanged, and the test marker is reset. See `medium-focus-host-evidence.json`. Remaining P0 gates are unchanged.


### 12 October — Today and original Focus privacy redaction

Fixed missing `privacySensitive` annotations in both owned widget implementations. A before-render reproduces visible task title/time/project under explicit SwiftUI privacy redaction; the corrected small/medium Today and Focus renders conceal those details while retaining public headings and actions. Normal before/after images are byte-identical, and both repos produce identical normal/private outputs. Unsigned iOS Simulator/macOS widget targets build in Debug/Release. See `widget-privacy-redaction-evidence.json` and the independently owned `Scripts/render_privacy_widget_previews.py --output <directory>`. This is source-render acceptance only: actual system-selected locked-device redaction, native Mac hosts and other P0 gates remain open.


### 12 October — notification Move to tomorrow

Fixed both independently owned action handlers: undated work now receives tomorrow’s plan, and future work moves to the receiving device’s actual tomorrow rather than one day after its old plan. Existing date-placement rules retain local clock/DST behavior and unrelated fields. Fifteen planner tests pass per repo; both Debug/Release app builds pass. An actual iPhone system alert reproduces the old undated no-op, then the corrected native action/relaunch/editor/cleanup passes with no reported runtime warnings. Only `due_date` changes in the retained task; reminder specs and identity remain exact. Protected devices and authenticated caches are unchanged. See `notification-tomorrow-evidence.json`. Two earlier fixture/helper failures are retained and excluded as product reproduction. Mac action runtime, account changes, other notification actions and broader P0 gates remain open.


### 12 October — real notification Complete action

An actual background-delivered local iPhone alert now has scoped Complete acceptance: the original undated task completes, survives normal relaunch and opens from Completed; its future reminder is absent from the real pending registry before reminders are disabled. One native test passes with no skips/failures/reported runtime warnings. Only `completed`, `completed_at` and `completion_version` change; reminder rule, original ID and plan are exact, with no successor or pending edits. Authenticated caches and protected phone/tablet files are unchanged. See `notification-complete-evidence.json`. This is test/evidence work; production code is unchanged. Cold-process/account-switch variants, cancellation timing before foreground inspection, Mac actions and other P0 gates remain open.


### 12 October — native notification workspace exit

Fixed an iOS usability defect: Account settings remained presented over the sign-in screen after leaving the workspace. The settings sheet now dismisses when sign-in ends. One corrected native iPhone case passes without failures/skips/reported runtime warnings: real local alert delivery, actual workspace exit, empty pending and delivered system registries, signed-out normal relaunch and exact full fixture snapshot preservation on reopening. Debug test build and Release app build pass. Authenticated caches and all 69 protected device files are unchanged. The first failed native run retains the stale-sheet evidence and does not establish alert retirement. See `notification-signout-evidence.json`. This closes local workspace exit only; account A → B/callback races, cold Complete, Mac actions/APNs and the other named P0 gates remain open. Mac production code is unchanged. The isolated Mac host is now responsive after manual unlock; opening the desktop widget gallery remains a computer-use boundary, not an installed-host pass.


### 12 October — native Mac failed pin save and retry

The retained inspector pin-save fix now has native Mac acceptance. A simulated persistent write failure reports an error, keeps the requested pin on in the open inspector and leaves the complete saved snapshot unchanged. After allowing saves again, Return in the unchanged title saves that original pin request without toggling it again. Only the intended `view_orders` pin entry is added; all three task records and previous pins remain exact. Normal Quit/relaunch shows the same task pinned. Native unpin cleanup returns the complete seeded snapshot, and all seven pre-session isolated caches are restored/equal after final Quit; protected phone/iPad files are unchanged. See `mac-pin-retry-evidence.json`. The misleading Debug “Fail next save” control now accurately says “Fail saves” and offers “Allow saves” in both independently owned apps. Both Debug builds pass; this is manual native Mac acceptance, not a Mac XCTest runtime pass or a new release-code fix. Installed Mac widgets, spoken VoiceOver, provider, notification/account/APNs and distribution gates remain open.


### 12 October — terminated-process iPhone notification Complete

The actual local Complete action now passes with the app terminated before delivery. Delivery leaves the app stopped; tapping the system action starts a different process without test launch arguments. The original undated task completes, its future reminder is absent before reminders are disabled, and normal relaunch/Completed/editor retain the exact task and rule. One native test passes with zero failures/skips/structured runtime warnings; both selected captures were inspected. Only task completion fields change, plus the expected completion activity/receipt; five protected app containers retain their exact file sets/hashes. See `notification-cold-complete-evidence.json`. Production code is unchanged. The independently isolated fixture App Group and signing allowlist are strengthened in the iOS-owned scripts. Mac host/Open/actions, account transitions, spoken VoiceOver, external providers, APNs/distribution and other named gates remain open. The unlocked retained Mac Focus app currently shows Today; the earlier notification click is not accepted as Open evidence.


### 12 October — Mac desktop widget installation exposes App Group rejection

The user-opened native gallery now exposes the isolated Mac catalogue separately from iPhone widgets; medium Today installs on the desktop. The host initially showed a fallback while its shared file contained seven tasks. Actual macOS logs identify rejected App Group access: the development profile omits group authorization and the non-team-prefixed identifier is rejected. The real staged decoder can read that payload outside the sandbox. The Mac-owned preparation script now requires `--team` for widget fixtures and uses the supported macOS team-prefixed group in copied sources and both entitlements. The rebuilt app/extension pass strict signature checks, the extension runs, and the installed widget footer changes from fallback to TASKFOLD. All isolated cache JSON files and seven projected tasks remain unchanged. See `mac-widget-host-access-evidence.json`.

This is partial installed-host/data-access evidence, not full Mac widget acceptance. Computer-use Capture clicks have no verified route; a manual click request remains pending. A subsequent app capture attempt hit ScreenCaptureKit -3812, so edit/refresh is unaccepted. Finder screenshots omit widget layers; no rendered desktop visual pass is claimed. The corrected test host and medium widget remain live for continuation. Production capabilities, APNs/distribution and other P0 gates remain open.


### 12 October — honest Today fallback and native Mac live refresh

Fixed the independently owned Today views in both apps: missing shared data now shows an unavailable count and “Open Taskfold / Refresh your tasks”, instead of claiming zero tasks and “All clear”. iOS accessory wording follows the same state. Debug/Release widget target builds pass for each platform. Actual owned SwiftUI light/dark previews fit all three home sizes; all eight loaded-empty/populated before/after images across both platforms are byte-identical. This is preview/build evidence, not installed-host fallback or accessory visual acceptance. See `today-widget-unavailable-evidence.json`. Inactive generated products are pruned (598,642,167 logical bytes); source, logs and captures remain.

Separately, the retained development-signed Mac host now passes native app capture → installed medium Today refresh, inspector Complete → zero, Undo → original title, and Quit/new-process relaunch → retained task/widget. Original eight tasks remain exact; only the synthetic task, expected activity and activity epoch change, with zero pending edits. After normal menu Quit, both original isolated cache JSON files are restored exactly; relaunch shows Today zero in app and desktop widget and retains the exact baseline. See `mac-widget-live-refresh-evidence.json`. This host predates the fallback fix. Desktop screenshot layers remain unavailable, so AX and saved data establish only the stated behavior.

The user’s first Capture click is followed by a New Task sheet labeled Today, rather than expected Inbox; prior sheet state makes attribution uncertain. Capture routing is not accepted. The sheet is closed and a clean-state manual click is requested. Other Mac widget actions/configurations, system privacy, account boundaries and remaining notification/provider/accessibility/distribution gates remain open.


### 12 October — provider preflight and fixture count correction

The native signed isolated Mac app exports its synthetic workspace through the save panel to a local temporary JSON file, then reads it through Restore from file and shows eight tasks plus one project. Review is canceled without applying; both original cache JSON files remain exact. iCloud Drive is available in both native pickers, but approval to upload this reviewed synthetic file is pending; no provider transfer is accepted yet. See `provider-transfer-preflight-evidence.json`. Seed rows use non-UUID IDs and intentionally remap on restore (Add 9); this is a file-read preflight, not same-workspace replay proof.

Rechecking the previous widget preservation receipt corrects its wording: there are eight saved baseline tasks, seven open. All eight original records match the post-Undo snapshot exactly, and only the one native-created synthetic task is added. The count correction changes documentation, not the verified preservation outcome. The clean-state automated desktop Capture click still has no observed app route; browser custom-URL dispatch is policy-blocked and is not used as a workaround. Manual widget click, native Mac notification actions and remaining P0 gates stay open.


### 12 October — installed iPhone Today empty versus signed-out state

The owned unavailable-state fix now passes one actual installed medium Today workflow on an independently namespaced iPhone Simulator app: valid empty data shows 0 / All clear, actual workspace exit changes the widget to a dash / Open Taskfold / Refresh your tasks, and normal signed-out relaunch retains that state. The unavailable count has its expected accessibility label. All four gallery/installed captures are inspected; the temporary widget is removed and the disposable Simulator returns to shutdown. Six protected app containers retain all 100 file sets/hashes exactly. See `today-widget-host-evidence.json`.

The native case passes in 195.235 seconds with no failures/skips/reported runtime warnings. Two SpringBoard animation-notification waits, one recovered hit-point attempt and eighteen ignored remote-hierarchy diagnostics remain disclosed. Debug test build, real team signing and catalogue checks pass. An initial universal Simulator build passes but is rejected by the single-slice signing inspector; the arm64 device build resolves that test-input boundary before native execution. Existing build warnings are retained in the receipt. This run adds iOS-owned fixture/test inputs; no production code changes are needed. Mac receipt mirrors the scoped iOS result. Other Today families/conditions, native Mac routes/privacy, authenticated account transitions, provider/VoiceOver/notification/APNs/distribution gates remain open.


### 12 October — current Mac widget host ready for native unavailable-state test

Rebuilt and development-signed a fresh independently staged Mac app and extension with the committed Today unavailable-state fix. Strict signatures, actual team/group prefix and exact widget source namespace transformation pass. The isolated v2 process is stopped by targeted SIGTERM for build replacement (not native Quit acceptance), v3 app/extension are running, and only the v3 plugin remains registered. Both fixture cache JSON files remain exact. Inactive v2 products are pruned (356,114,427 logical bytes), retaining both staged sources, logs/signatures and the active v3 products. See `mac-widget-current-build-evidence.json`.

Computer use confirms the Mac is locked on the new handle. Native current-build/signed-out widget inspection awaits manual unlock; no visual, route or new native state pass is claimed. Earlier v2 edit/Complete/Undo/relaunch refresh evidence remains historical and scoped. Provider upload approval and other named P0 gates remain open.


### 12 October — authenticated iPhone reminder sign-out and reentry

The retained disposable cloud account now passes actual local notification delivery → native Sign out → empty pending/delivered registries → sign-in → unchanged inspected task/reminder fields and only the remaining future occurrence → native task deletion and final sign-out. A separate native normal-relaunch case uses no workspace/seed/session override and retains the sign-in screen with empty alert registries. Both final tests pass without failures/skips/structured runtime warnings; five selected captures are inspected. See `notification-authenticated-signout-evidence.json`.

The first full run fails only at its cleanup selector (task-details Button queried as StaticText); corrected native cleanup passes before the final full run. Across both synthetic create/delete walks, only `task_activity` changes; all other 13 checked server tables and all 100 files in six protected containers are exact. The isolated queue is empty, both temporary tasks are absent, reminders are off, persisted localMode is false, and the disposable Simulator returns to shutdown. Inactive generated products are pruned (417,338,197 logical bytes), retaining source/results/logs/signatures.

This adds iOS-owned DEBUG inspection/tests and scoped evidence; release behavior and Mac code are unchanged. The inspection controls crowd the toolbar, so these captures are not a production toolbar visual pass. Authenticated A → B/delayed-callback journeys, Mac Open/actions/widgets, external provider/VoiceOver/APNs/distribution and the other named gates remain open. The current Mac widget app is checked again but native computer use still reports the Mac locked; no widget Capture route is accepted.


### 12 October — Mac capture request survives the Inbox view transition

Found and fixed a concrete Mac presentation race: external capture switches to Inbox and increments its request counter together, while the section-keyed Inbox view mounts with the new value and an ordinary change listener misses it. A real SwiftUI listener-pattern probe reproduces the lost presentation, then proves the corrected transition, already-mounted request and no reopening after a consumed request/remount. The app now retains a request bound to its destination and workspace incarnation, consumes it once on initial/subsequent listener execution, and cancels it on navigation/account reset. Both task-list and Calendar listeners use the handoff; signed-out capture is rejected.

Four independently owned Mac core tests and unsigned Debug/Release app builds pass. See `capture-view-handoff-evidence.json` and `Scripts/verify_capture_view_handoff.py --output <new-directory>` in the Mac repo. iOS already retains its external Inbox request and consumes it on appearance/change; its earlier native external-capture acceptance remains scoped and its code is unchanged. Inactive compile products are pruned (1,024,402,922 logical bytes); source, probe receipts and build/test logs remain.

This is framework/model/build proof, not an installed widget or full native capture pass. The existing v3 Mac widget process/window is preserved for inspection and predates this fix; computer use still reports the Mac locked. No blocked browser protocol route is dispatched. Actual widget click → Inbox capture/save/relaunch, Mac notification actions, authenticated A → B/callbacks, external providers/VoiceOver/APNs/distribution and other named P0 gates remain open.


### 12 October — signed Mac capture-fix build prepared

A fresh isolated Mac app and widget extension now build with the committed capture handoff fix. Strict app, extension and deep signature checks pass with the actual development team, sandbox and isolated team-prefixed App Group; the staged capture queue source is byte-identical to the committed source. See `mac-capture-signed-build-evidence.json`. The preserved v3 window is inspected as Today with no sheet; a later manual click opens Inbox in an older cold-launched binary. v4 then exposes repeated new-window/fixture reset. Both old builds are retired; the subsequent v5 fix and native acceptance are recorded below. This historical preparation alone establishes no native route pass.


### 12 October — real reminder callback across authenticated account switch

One native iPhone Simulator test now passes the actual system Complete response held across A → B, released under B, and followed by return to A. B remains empty; A’s original task stays open with identical inspected planning/reminder fields and only the future occurrence pending. Native cleanup/sign-out/normal relaunch retain empty alert registries. The final run passes in 321.165 seconds with no failures/skips/structured runtime warnings; four behavioral captures are inspected. See `notification-account-switch-evidence.json`.

The first run fails at overlapping DEBUG inspection controls; a corrected layout and native cleanup pass precede the accepted rerun. B’s 14 checked server tables are exact, A’s other 13 tables and original activity are exact, and all 100 protected files in six containers match. Only four synthetic task create/delete activity rows are added. B sessions are globally revoked before narrowly guarded account deletion; scoped checks show zero remaining records, and its private credentials/cache are removed. The disposable Simulator is shut down and 420,849,427 logical bytes of inactive products are pruned. This adds iOS-owned DEBUG harness/tests, with no release behavior change; DEBUG controls still overlap headings and are not a production visual pass. Mac actions/account switching, other named conditions and full P0 release acceptance remain open.


### 12 October — installed Mac widget capture stays open and survives relaunch

The user’s report exposes a second concrete issue: widget URLs create new windows in the same process, and per-window DEBUG fixture setup renews the shared workspace and resets navigation to Today, dismissing capture. The main scene now prefers its existing window for external events; fixture setup is guarded once on the shared Workspace. Native medium Today “+” now opens a stable Inbox sheet, accepts input and saves the intended undated task. The Window menu lists only one window. Native menu Quit is verified by process exit; same-fixture relaunch without reseeding retains all nine exact task records and the native Inbox row. See `mac-widget-capture-native-evidence.json`.

Native cleanup deletes only the synthetic task; all eight original tasks and every non-activity table remain exact, with zero pending edits. Expected create/delete activity and epoch changes remain. All 100 protected files match. Two inspected app captures show the Inbox sheet and saved task; desktop widget layers remain outside visual acceptance. Development-signed Debug and production unsigned Release builds pass, as do strict app/extension/deep signatures and team/catalogue checks. Old v3/v4 and inactive Release products are pruned, retaining stages/logs/receipts and the active v5 app. This closes this named installed Mac capture/save/relaunch journey; other widget conditions, Mac notification/account actions, external providers/spoken VoiceOver/APNs/distribution remain open.


### 12 October — installed Mac Today workspace exit and normal relaunch

Native Leave Local Workspace reaches the auth screen and clears the shared projection. After normal Quit/no-argument relaunch, installed medium Today shows Task count unavailable / Open Taskfold / Refresh your tasks. A same-build retained-fixture return (no reseeding) restores the original Inbox and valid 0 / All clear widget. Repeating native exit changes that same installed widget back to unavailable, and a final normal signed-out relaunch preserves it. See `mac-widget-signout-evidence.json`. No product or test-harness source change is needed.

The first exit initially leaves stale All clear despite a correct cleared projection; chronod records extension creation/Unknown extension process failures. This immediate refresh attempt is not accepted. The later repeat passes without rebuilding or changing registration. Taskfold-only desktop accessibility establishes the stated host behavior; desktop pixel/privacy/all-family acceptance remains open. The complete saved fixture snapshot and all eight tasks are exact, the six-file isolated set is unchanged (only JSON encoding differs in one file), and all 100 protected files in six containers match. The isolated app is left normally signed out; saved work and current products remain available.


12 October: fresh retained-process Focus alert delivery confirmed in owned logs without DND suppression. Task data remains exact; Focus is closed before delivery. Actual notification Open is pending. See `mac-focus-open-preflight-evidence.json`; no current-source build or production change is claimed.


12 October: actual warm-process Focus notification Open now passes: exact system foreground response, unchanged PID, native finished-session sheet and pending count zero. Inspected screenshot and task preservation receipt in `mac-focus-open-native-evidence.json`. Cold-process Open and Mac task-reminder/account actions remain open.


12 October: normal local cold Focus delivery passes after native Quit, using regular native task/chooser/duration controls and no fixture launch arguments. Actual cold notification Open and scoped test cleanup are pending; see `mac-focus-cold-open-evidence.json`.


12 October: actual cold Focus Open passes with OS-launched new PID and no arguments, exact scheduled snapshot and inspected native finished-session result. Native test cleanup returns the local task list to empty and alerts off; stopped session/activity and an expected daily backup remain. Protected 100 files and original ui-testing cache are exact. See `mac-focus-cold-open-evidence.json`. Mac task-reminder/account and other named release gates remain open.


12 October: native normal local task reminder scheduling/terminated delivery passes; actual Complete remains pending (`mac-task-reminder-preflight-evidence.json`). Current-source `p0notificationtests` stage builds/signs and remains unlaunched. Prepare with `python3 Scripts/prepare_isolated_mac_ui.py --variant p0notificationtests --output /private/tmp/taskfold-notification-fresh`; launch without fixture arguments so OS cold actions receive the same local workspace. Its namespace is independent from the historical Focus app, which remains stopped with the pending alert. See `mac-notification-current-build-evidence.json`.


12 October: actual terminated task-reminder Complete/save/normal relaunch and native cleanup pass (`mac-notification-complete-evidence.json`), with only completion fields changed, reminder specs retained and100protected files exact. Current-source notification build stays unlaunched for remaining Open/Snooze/Move to tomorrow/account tests. Future-occurrence cancellation/independent registry inspection are outside this one-shot pass.


12 October: current-source notification harness's normal first local launch exposes and fixes the missing DEBUG bundle allowlist entry for sandbox-local widget projection. Four starter tasks/project and parsed snapshot are preserved; native permission error clears. v2 Debug/signatures pass, inactive v1 products are pruned (108,895,377 logical bytes), and normal v2 permission approval is pending. See `mac-notification-disk-fix-evidence.json`. Production behavior is unchanged.


12 October: both apps' Task reminders Settings now explain pending system authorization and prevent repeat toggles. Current Mac signed Debug/iOS arm64 Simulator Debug compile checks pass; actual pending-state rendering remains unaccepted. Existing Mac v2 prompt/process is preserved, v3 is ready but unlaunched, and inactive iOS compile products are pruned. See `settings-permission-progress-evidence.json`.


### 12 October — current-source Mac reminder permission and cold delivery

The approved system request now resolves: native Task reminders is on. A normal native Inbox capture creates one disposable undated task with an independent fixed reminder; the editor confirms one upcoming alert. Native Quit stops PID15247 before the actual 10:11:41 delivery, which leaves the complete saved snapshot unchanged and the process stopped. All100protected files remain exact. See `mac-notification-tomorrow-preflight-evidence.json`. Actual Move to tomorrow is pending a manual Notification Center action; no action/relaunch pass is claimed. The four starter tasks/project are retained. Earlier approval-pending notes are historical; the newer Settings-progress build remains unlaunched.


### 12 October — native Mac Move to tomorrow and system registry inspection

The actual 10:18:23 system `taskfold.tomorrow` action starts a new no-argument process after terminated delivery. The originally undated task gains only `due_date = 2026-10-13`; identity, completion and every reminder rule remain exact. Native Inbox/editor show 13 October with no time, and normal Quit/relaunch retains the complete applied snapshot. This accepts the named current-handler local Move to tomorrow journey; see `mac-notification-tomorrow-evidence.json`.

Native cleanup turns delivery off and reversibly deletes only the synthetic task. All four starter tasks/project and non-activity tables are exact, prior activity is retained with three expected create/update/delete entries, and all100protected files match. A Mac-owned read-only inspector, restricted to DEBUG and the exact isolated notification bundle, now reads actual macOS pending/delivered requests and action identifiers. Its signed Debug build and strict signatures pass; normal v4 native inspection after cleanup reports both registries empty. This is post-cleanup registry evidence, not cancellation timing before disabling delivery. iOS already owns independent registry inspection and receives the shared acceptance receipt. Inactive v2/v3 Build products are pruned (217,843,318 logical bytes), retaining staged sources/logs and active v4. Snooze/task Open/account transitions, other widget/provider/VoiceOver/APNs/distribution gates and full P0 acceptance remain open.


### 12 October — native Mac Snooze, redelivery and cold task Open

Actual `Remind me in 5 minutes` cold-starts the isolated app. Direct macOS inspection shows one snoozed request, preserving task/spec/signature/original instant and scheduling five minutes after the handler runs. Normal Quit/relaunch retains that exact request and the full task snapshot. After another native Quit, the snoozed alert actually redelivers at10:45:28. Its body click cold-launches v5 without arguments and selects the exact undated task with its inspector open. See `mac-notification-snooze-evidence.json`. These named local Snooze/redelivery/Open journeys pass.

The walk exposes transient stale status: Settings initially says zero upcoming despite the real snooze; an ordinary later refresh corrects it. Both independently owned action handlers now publish the successful Snooze report count immediately. Mac signed Debug/strict signature and iOS arm64 Simulator Debug builds pass. The new status branch is source/build verified; v5 Open does not constitute a repeated Snooze callback.

Native cleanup restores delivery off and the original one-hour Snooze preference, deletes only the synthetic task, and verifies empty actual pending/delivered registries. All four starter tasks/project, prior activity and100protected files remain exact; only two expected create/delete activity rows and the explicit restored preference row remain. Inactive v4 and iOS compile products are pruned (273,072,459 logical bytes); sources/logs and active v5 remain. Mac account-transition acceptance, other named P0 gates and full release acceptance remain open.


### 12 October — Mac local notification retirement and Settings recovery

Native local exit with one delivered and one future alert clears both actual macOS registries. Normal signed-out relaunch stays empty; local return restores only the exact future request. Cleanup disables delivery before its fire time and reversibly removes only the synthetic task. All non-activity tables, prior activity and 100 protected files remain exact. See `mac-notification-local-exit-evidence.json`.

Mac Settings now reports “No workspace open”, disables the signed-out reminder toggle and rebuilds date/reminder preferences after reentry. Native v6 verifies corrected signed-out copy and enabled controls, including opening Snooze without changing its value. The full clean snapshot remains exact. Both independent Debug builds pass; iOS receives its own toggle guard (compile verification only). Inactive v5/iOS compile products are pruned; active v6 and logs remain. Authenticated Mac account-switch/delayed-response and other named release gates remain open.


### 12 October — authenticated Mac notification sign-out and return

Native cloud-account sign-out now retires one delivered and four pending system alerts. A normal signed-out relaunch preserves empty registries; signing into the same account restores the exact four future requests without resurrecting the delivered occurrence. The complete saved account snapshot remains exact across sign-out and return. See `mac-notification-authenticated-exit-evidence.json`.

Native cleanup restores delivery off and deletes only the disposable task with Undo available. All 13 non-activity server tables are exactly restored, all 24 prior activity rows remain, and only the two expected create/delete records are added. All 100 protected files remain exact. This closes authenticated Mac sign-out/reentry; Mac A → B delayed-callback isolation and the other named P0 gates remain open. No source changes or new builds were required.


### 12 October — Mac delayed notification callback preflight

Mac now owns opt-in DEBUG support to hold one actual system response before its unchanged production handler, then release it after a native account switch. It requires the exact isolated bundle and an explicit launch flag. Signed v7 Debug/strict signature pass; native controls reach Armed and two disposable reminder occurrences are genuinely scheduled. See `mac-notification-hold-preflight-evidence.json`. Both reserved accounts and protected files have private baselines. Actual callback/account-switch acceptance remains pending; this is test preparation, not a pass. Inactive v6 products are pruned; active v7, logs and sources remain. iOS retains its independent existing harness.


### 12 October — actual Mac delayed Complete across A → B → A

The actual Notification Center Complete response is held for A, then released after native sign-out/sign-in to B with delivery enabled. The unchanged production handler returns under B; B tasks, pending edits and both notification registries remain empty. Returning to A preserves its complete scheduled snapshot, still-open task and exact four future requests. See `mac-notification-account-switch-evidence.json`. This closes the named Mac delayed Complete isolation journey; it does not expand acceptance to every action/timing permutation.

Native cleanup restores delivery off in both accounts and reversibly deletes only the synthetic A task. Cloud comparison proves A non-activity tables and prior activity exact, B all 14 tables exact, and 100 protected files exact. The empty reserved B account/0600 credentials remain for final fixture cleanup. Other named P0 release gates remain open. The earlier callback preflight is superseded by this actual result.


### 12 October — installed Mac Today task cold-route preflight

The existing v5 host now has one disposable Today task in its previously empty normal local workspace. Native Quit from Completed leaves PID10361 stopped, with the exact saved task and zero pending edits. The installed widget task-title click is awaiting manual input because desktop-widget observation times out. See `mac-widget-task-route-preflight-evidence.json`. No cold-route pass is claimed; the original fixture cache is retained.


12 October: notification switch fixture cleanup is complete. Disposable B sessions revoked, account deleted and 17 database checks return zero; its local cache, membership cache, encrypted recovery copy, exact isolated Keychain key and private credentials are removed. Nine unrelated local files remain hash-exact. Account A is retained. This supersedes the earlier retained-B cleanup note in `mac-notification-account-switch-evidence.json`. Pending desktop widget click remains undisturbed.


### 12 October — installed Mac task route exposes stale list context

A real Today widget title click cold-launches PID29369 without arguments and opens the exact task inspector, preserving the full snapshot. Native AX and inspected pixels expose an inconsistent background: Completed / 0 completed. Mac external task URLs and reminder opens now select the task’s Inbox/project/Completed context and clear a stale list search before selecting the task. iOS already uses a separate task sheet and needs no sidebar fix. See `mac-widget-task-context-evidence.json`.

Isolated v6 app/extension Debug build and strict deep signatures pass. Normal launch preserves the snapshot; native Quit is confirmed. The corrected installed cold route awaits a manual widget click. Inactive v5 products are pruned (125,670,357 logical bytes); v6 and logs remain. No corrected-runtime or broad widget pass is claimed yet.


### 12 October — fixed installed Today task cold route accepted

The second real desktop title click starts v6 PID30403 without arguments and opens Inbox / 1 task, the exact selected row and its inspector. Native AX and inspected pixels agree; the full saved task snapshot is unchanged. See `mac-widget-task-context-evidence.json`. Native reversible deletion restores the empty local task list and zero pending edits. Five original fixture files and all 100 protected files are hash-exact; local activity retains the two synthetic create/delete records. This closes the named Today task cold route to Inbox; other widget families/actions and the untested helper branches remain scoped separately.


12 October: next installed Mac widget journey is My list completion. A single disposable undated Inbox task is saved in the normal local v6 host; actual App Group projection contains its matching identity and completion token, with no pending edits. Desktop installation/Inbox selection is awaiting user interaction because system widget controls are inaccessible. See `mac-mylist-preflight-evidence.json`; no installed completion pass is claimed.


12 October: installed My list completion/persistence is accepted for the single local project task. Added a saved-only, account/list-scoped brief Completed row, with hidden-title handling and a task-open link; matching independent iOS implementation. Focused tests and Debug builds pass, source renders inspected; native feedback timing remains pending. See `widget-completion-feedback-evidence.json`.


12 October: installed My list Completed acknowledgement and explicit dismiss are accepted on v8. Task remains completed; cleanup and 100 protected-file checks pass. Timed expiry is best-effort, direct Undo is not implemented. See `widget-completion-feedback-evidence.json`.


### 12 October — native Mac calendar selection and accessible labels

Actual Mac EventKit connection, calendar selection, normal relaunch and disconnect now pass in a separate development-signed app. Native inspection found that calendar switches exposed only their source; both apps now explicitly label them with calendar title and source. All ten Mac switches expose corrected names with independent values. Event titles remain off, one selected sports calendar survives relaunch, and Disconnect removes its device preferences. No calendar events were changed. See `mac-calendar-selection-evidence.json`.

Mac signed Debug/strict signatures and iOS arm64 Simulator Debug pass; iOS native labels were not rerun. The test app's initial missing App Group entitlement was corrected and its warning disappears in v2. All 100 protected Simulator files remain exact; four starter tasks/project remain and pending edits are zero. Whole-cache identity is not claimed. Inactive products totaling 276,064,120 bytes were pruned. Mac actual event rendering/privacy, denial/recovery, spoken VoiceOver and remaining release gates stay open.


### 12 October — actual Mac calendar event privacy and capacity

Read-only native comparison with Apple Calendar now verifies a 105-minute sports event through Taskfold's real EventKit provider. Titles off shows Busy; titles on shows its name, and reversing the switch hides it again. Extending only the isolated workspace's working hours to cover the event gives 840 − 105 = 735 minutes; original hours exclude it correctly. Calendar selection, title preference, working hours and named event survive normal relaunch. Disconnect removes the event. See `mac-calendar-selection-evidence.json` / `eventAcceptance`.

The walk also fixes the Mac sheet title leaking into the parent window: an in-sheet accessible heading retains the label while Save/Cancel immediately return to Calendar. Final Mac signed Debug/strict signatures and iOS Simulator Debug pass; final header/private event captures inspected. Both owned source copies retain native iOS navigation titles. Cleanup restores 09:00–17:00 weekdays and removes device calendar preferences. The explicit default working-hours row is the only changed table; all original tasks/projects/activity and 100 protected files are exact, pending edits zero. No source calendar/event was modified. Inactive build products totaling 277,629,445 bytes were pruned. Mac denial/recovery and other existing P0 gates remain open.


### 12 October — Mac calendar denial and recovery accepted

Actual System Settings revocation for the distinctly named isolated calendar app now produces an honest incomplete-capacity state after verified Quit/relaunch. Disconnect/Connect returns readable denial guidance. The app's recovery button starts System Settings at General; the displayed manual Privacy & Security → Calendars route reaches the correct entry. All workspace tables and 100 protected files remain exact; pending edits zero. See `mac-calendar-permission-evidence.json`.

The user restored Full Access without quitting. Connect recovered immediately in the running app, exposed ten calendars and rendered the selected real event privately as Busy. Normal Quit/relaunch retained the selection and event. Disconnect cleared device calendar preferences; all workspace tables and 100 protected files remain exact, pending edits zero. The named Mac denial/recovery gate is closed. Mac test preparation now gives CFBundleName the isolated display name; the active wrapper was also renamed after quitting. Signed Debug/strict signatures, script syntax and fresh preparation pass. Existing cached system labels and unsuccessful preliminary reset/read attempts are recorded, not counted as acceptance. Product behavior is unchanged.


### 12 October — Mac iCloud backup transfer and restore accepted

With explicit user approval, the prepared synthetic export was uploaded to iCloud Drive, its local download removed in Finder, and the cloud-only file opened through Taskfold’s native restore picker. The downloaded bytes match the original exactly. Preview/apply restored eight tasks and one project, retained all existing records and relationships, saved an encrypted safety copy, and survived normal Quit/relaunch. The isolated cache baseline was restored after testing; all 100 protected Simulator files remain exact. Only the synthetic cloud file was moved to the recoverable Bin. See `mac-provider-transfer-evidence.json`. iOS provider-picker and offline/download-failure acceptance remain open; no production change or new build was needed.


### 12 October — coordinate external backup reads

Both owned apps now coordinate external backup reads with NSFileCoordinator while holding the picker’s security scope. A real file-presenter regression demonstrates stale content from the old direct read and current content after coordination; provider-save errors propagate instead of reading stale data. Missing-file retry and oversized-file rejection also pass. All 43 backup tests pass per repo (86 total). Mac signed Debug/deep strict verification and iOS arm64 Simulator Debug builds pass. No app was installed or replaced; inactive build products were pruned. This is a production reliability fix with local Foundation evidence, not new native iOS provider/offline acceptance. See `provider-coordination-evidence.json`.


### 12 October — iPhone backup picker cancellation and provider prerequisite

The coordinated reader now has native iPhone coverage: corrupt-file error/recovery, cancelled reviews with current work retained, and picker cancellation followed by a valid preview. Two corrected native cases pass, and the final provider observation passes separately, all with zero reported runtime warnings. iCloud Drive shows **Sign in to iCloud** in the disposable Simulator; no sign-in was attempted, so external iOS transfer remains open with a concrete provider-session prerequisite. Initial failures were outdated accessibility queries and are retained in `ios-provider-picker-evidence.json`. Nine original app files and four widget-group files were restored exactly, 100 protected phone/iPad files are unchanged, and the disposable Simulator is shut down. Xcode ad-hoc signing is explicitly scoped to these native tests. No production code changed this turn.


### 12 October — My list privacy accessibility fix

A synthetic native SwiftUI host reproduced task/list/completion names leaking through accessibility during privacy redaction, with dates and mutation controls still visible. Both owned widget views now show a generic “Tasks are private” card and omit those controls. Small and medium private accessibility trees contain no sensitive fixture content; normal medium content is byte-identical. All three captures were inspected. Both Mac and iOS widget targets pass Debug and Release; independent preview scripts pass syntax checks. See `widget-list-privacy-evidence.json`. This verifies the owned view under explicit privacy redaction, not installed system privacy, spoken VoiceOver or native iOS UI acceptance. No real data or installed widget changed. Stopped preview apps and this turn’s inactive build products were pruned; source, logs and evidence remain.


### 12 October — Today and Focus private accessibility

The native synthetic host reproduced Today’s visually redacted title/time leaking through its accessibility link. Focus exposed unreadable redaction glyphs. Both owned implementations now provide readable generic private content and a Today root route. Normal medium accessibility content is byte-identical; small and medium corrected layouts were inspected. Four widget-target Debug/Release builds pass. Today accessories now have compact private states, compile-verified only. See `today-focus-privacy-evidence.json`. This is explicit-redaction view acceptance, not installed system privacy or spoken VoiceOver. All preview apps were quit and inactive products pruned; no real Taskfold app or data changed.


### 12 October — remaining widget private states

Native synthetic inspection found exposed task links in Deadline radar/Small window and retained counts/progress/timing in other private views. Both independent implementations now give Deadline radar, Small window, Day capacity, Inbox reset, Pinned note, Focus session, Week ahead and Project pulse explicit readable private cards. Normal medium accessibility content matches after numeric element-ID and live Focus countdown normalization in all four pairs. The raw comparison correctly detected the countdown changing from 19:52 to 19:53 between hosts. All eight private views pass medium/small accessibility inspection, four compact captures were inspected, and all four widget-target Debug/Release builds pass. Week remains medium-only; its forced small preview is not supported-family acceptance. Quick capture contains only static public content. See `remaining-widget-privacy-evidence.json`. System-selected privacy, spoken VoiceOver and native iOS privacy remain open. All preview apps were quit and inactive products pruned; no real app/data or installed widget changed.


### 12 October — cancellable external backup reads

Both owned apps now display Opening backup with an enabled Cancel action while a provider prepares a file. Cancellation clears the wait state, cancels active coordination and prevents late preview/error delivery; operation identity also prevents an old read clearing a newer read’s busy state. Workspace changes cancel pending reads. A real NSFilePresenter regression withholds its save callback: cancellation returns before that callback is released, preserves the source exactly, and a fresh read succeeds. Pre-cancel/retry also passes. All 45 backup tests pass per repo (90 total), and both final unsigned Debug app targets build. See `backup-read-cancellation-evidence.json`. Native progress/Cancel/late-result workflow acceptance and actual offline provider transfer remain open. No app was installed or launched, and inactive build products were pruned.


### 12 October — native iPhone backup wait cancellation accepted

The isolated native iPhone test passes Opening backup → Cancel → same-file Retry → restore review → Cancel → original task retained, with zero failures/skips/reported runtime warnings. The spinner/message and enabled Cancel are visible while restore controls are disabled. A registered test-only NSFilePresenter holds the actual selected-file coordination, so this exercises the real read/cancel path; it does not simulate an actual offline cloud service. All three screenshots were inspected, persisted fixture has one task/zero pending edits, and 45 backup tests pass per repo. See `ios-backup-cancellation-evidence.json`. The isolated app and test runner were removed, disposable Simulator shut down, inactive derived data pruned and all 100 protected files remain exact. Mac native cancellation, account-switch races and external offline transfer remain open.


### 12 October — backup footer and session cleanup

Provider wait progress and Cancel now remain in a fixed footer outside the scrolling settings form in both owned apps. The final native iPhone case passes Cancel → same-file Retry → cancelled review → original work retained, with zero failures/skips/reported runtime warnings; all three captures were inspected. Mac footer visibility is confirmed, but its enabled Cancel is still not hittable after ten seconds and AX reports the app/window disabled. Mac native cancellation/retry/relaunch remains **open**; the cause is undiagnosed, and a speculative picker callback change was removed after failing. The isolated Mac runner and synthetic regression are retained to reproduce this gate. See `backup-footer-evidence.json`. Six leftover Mac app sessions were quit, all new test apps are stopped, the disposable iPhone app/runner removed and Simulator shut down, and 100 protected files remain exact. Inactive products were pruned; installed widget extensions and original app/data remain intact.


### 12 October — native Mac backup cancellation accepted

The Mac cancellation gate now passes: a real button-frame click cancels held file coordination, same-file Retry opens review, cancelling review preserves the entire persisted workspace, and normal Quit/relaunch retains it exactly. The native picker Cancel/reopen case also passes: two cases, zero failures/skips/reported runtime warnings. Separate native CUA interaction independently verified the same journey. XCTest’s `isHittable` assertion was misleading; the test now performs a real click and asserts its effects. Ordering out NSOpenPanel before subsequent UI follows Apple guidance but did not itself fix that test assertion. iOS already dismisses its UIKit picker before reading and its prior native Cancel/retry acceptance remains valid. See `mac-backup-cancellation-evidence.json`. Test apps are closed, 100 protected files remain exact, and inactive products were pruned. Account-switch-during-read and actual remote provider failure remain open; this does not close all P0.


### 12 October — backup navigation and local workspace return

A native iPhone regression reproduced a held backup read surviving a popped Data & Sync page and local workspace exit/return; same-file Retry then hung. Both independent apps now cancel an active read when its presentation disappears. Final native checks pass: three Mac cases and two iPhone cases, zero failures/skips/reported runtime warnings. Retry opens review after returning, and cancelling review plus relaunch preserves the entire saved workspace exactly. Three new journey captures per platform were inspected. See `backup-navigation-evidence.json`. This closes local workspace exit/return, not authenticated A/B switching during a read or actual remote provider failure. All Taskfold app sessions/runners are stopped; system-managed widget extensions remain. The disposable app/runner were removed and Simulator shut down, 100 protected files remain exact, and 1,083,322,406 logical bytes of inactive build products were pruned.


### 12 October — full Mac restore review reachability

A full-sheet native capture resolves the apparent clipping in earlier parent-window screenshots: the complete review fits the visible display, Restore and Cancel are hittable, and the warnings are readable. The strengthened real Cancel/retry test passes with zero failures/skips/reported runtime warnings; exact saved workspace is retained after cancelling review and normal Quit/relaunch. No product layout change was required. See `mac-restore-review-fit-evidence.json`. This is current-display acceptance, not all window sizes or new iOS/restore-apply coverage. All new test sessions are closed, 100 protected files are unchanged and inactive products were pruned. Other named P0 gates remain open.


### 12 October — current offline conflict review retention

Both local conflict fixtures now capture task-generation identity; the Mac fixture includes the later 45-minute edit already intended on iOS. Visual inspection caught the first green Mac run lacking that estimate, so it is superseded. Final native runs pass two cases per platform with zero failures/skips/reported runtime warnings. Mac Use synced drops only the reviewed comment mutation, retains the exact later estimate mutation and all other task fields, displays 45 minutes and preserves the whole resolved workspace after normal Quit/relaunch. Its Keep my edit comment regression also passes. iPhone verifies both choices with exact later mutation, estimate, independent teammate comment and whole-cache relaunch preservation. Nine captures were inspected. See `offline-conflict-review-evidence.json`, including the initial under-scoped run and driver failures. This verifies local review; other live concurrency/legacy and release gates remain open. All test sessions are closed, the disposable app/runner removed and Simulator shut down, 100 protected files unchanged, and 691,420,782 logical bytes of inactive products pruned.


### 12 October — deletion review contents and session cleanup

Both owned apps now hide internal task-generation identity from conflict review content. Final native checks pass one Mac case and two iPhone cases with zero failures/skips/reported runtime warnings: Keep task preserves newer contents and relaunch, and iPhone explicit Delete task persists. The iOS debug fixture now seeds after loading the workspace; the earlier stale delete review is retained as a failed run, not acceptance. Five captures were inspected. See `deletion-review-content-evidence.json`. VoiceOver was temporarily enabled under existing approval, but spoken-output access still times out; it is restored off and its utility closed. Installed desktop-widget controls also time out, so those gates remain open. Release signing is deferred at the user's request. All Taskfold app sessions/runners are closed, installed system widgets preserved, disposable app/runner removed and Simulator shut down, all 100 protected files exact, and 689,857,180 logical bytes of inactive products pruned.


### 12 October — authenticated iPhone backup navigation accepted

The native iPhone A → B → A journey passes with zero failures/skips/reported runtime warnings. A held real file read is cancelled when navigating to Account; after actual sign-out/sign-in, B opens a fresh review of the same file, Cancel preserves B, and returning/relaunching A preserves both entire saved workspace dictionaries exactly. All 28 read-only backend table comparisons and 100 protected files remain unchanged. Three captures were inspected. The first two attempts were blocked by iOS's Save Password prompt; video inspection identified it, and the final driver chooses Not Now and enters the password through a restored clipboard. No Taskfold product defect was found. Both own test builds pass; the Mac app's strict deep signature passes, but its native launch failed while the Mac was locked. Mac same-page sign-out while reading and external callback/provider-failure variants remain open. See `backup-account-switch-evidence.json`. All app/runner sessions are closed, disposable iPhone app/runner removed and Simulator shut down. 421,334,524 logical bytes of inactive iOS products were pruned; only the current Mac products needed after unlock are retained. Release signing remains deferred.


### 12 October — Mac pending-backup sign-out accepted

Native Mac A → B → A now passes with an actual coordinated file read still pending at same-page Sign Out. B inherits no busy operation or restore review, independently opens the same file, and Cancel preserves its entire saved workspace. A return and ordinary quit/relaunch preserve both complete saved workspace dictionaries. All 28 read-only backend table comparisons and 100 protected files remain unchanged. Three final journey captures were inspected. No production app code changed: native driver corrections handle clipped controls and the real confirmation sheet; isolated packaging now retains the production task-type declaration. The final test has one pass, no failures/skips, and one unresolved main-thread warning, so this is workflow acceptance, not clean-runtime acceptance. External auth callbacks and remote provider failures remain separate open gates. All app/runner sessions are closed; 272,983,202 logical bytes of inactive Mac products were pruned, preserving the installed widget host and private results. See `backup-account-switch-evidence.json`. Release signing remains deferred by the user.


### 12 October — session persistence stays off the UI thread

Both apps now await serial background session writes and clearing. A delayed acceptance cannot revive a signed-out account, requests cannot use the previous credentials during a transition, and failed Keychain deletion is reported while retaining the current in-memory session. Sign-out shows progress and prevents edits until clearing completes. Four new regression cases per repo verify delayed acceptance, failure preservation, responsive/off-main ordered persistence, and a newer sign-in superseding delayed sign-out. The final Mac and iPhone authenticated backup account-switch/retry/cancel/return/relaunch journeys pass strict native verification with no reported runtime warnings; both saved workspace dictionaries, all 28 server-table comparisons and 100 protected files remain exact. Six captures were inspected. This closes the named session-write warning from the previous Mac run. Startup reads and separate reminder-registration Keychain paths are outside this change. The first Mac launch attempt never obtained a process ID; exact-path launch and a process sample narrowed that boundary, and the unchanged build passed the retry. The final Mac driver scopes scrolling to Account after two failed attempts targeted an app-wide scroll area. See `session-persistence-evidence.json` for final counts, zero-warning Release compilation and cleanup. All test app/runner sessions are closed; 988,396,465 logical bytes of inactive Release products were pruned, retaining current Debug products for continuing P0 checks. Broader P0 gates and user-deferred distribution signing remain open.


### 12 October — obsolete sign-in responses cannot replace the chosen account

Two held password responses reproduced sign-in reviving a cleared session and an older sign-in replacing a newer account. Both owned backends now bind authentication to its originating attempt, invalidate obsolete responses on sign-out/new acceptance and guard Google callback/token exchange; browser cleanup belongs to its attempt. Both forms disable Use locally during sign-in and ignore obsolete cancellation errors. Final native Mac and iPhone pending/relaunch checks each pass with no failures/skips/reported runtime warnings; four captures were inspected. These use a synthetic local HTTP hold, not real Google or provider-failure acceptance. Core suites execute 660 Mac/636 iOS cases with 26/6 skips and zero failures. Independent Release builds pass with retained existing warnings outside the auth change. See `auth-attempt-isolation-evidence.json`, including failed reproduction, driver corrections and exact limits. All 100 protected files remain exact, test sessions are closed, disposable app/runner removed and Simulator shut down; 988,316,033 logical bytes of terminal Release products were pruned. Real external OAuth callbacks, installed Mac widget conditions, spoken VoiceOver and broader P0 gates remain open. Release signing stays user-deferred.


### 12 October — safely leave pending sign-in for local work

Both native forms now keep local entry available during a pending sign-in, await ordered credential clearing before entering the workspace, prevent duplicate submissions and skip Keychain for ordinary unauthenticated local entry. Clearing the password before leaving also removed the iPhone Save Password overlay observed in the first run. This supersedes the disabled Use locally behavior in the previous auth-attempt receipt; its obsolete-response guards remain unchanged. Final native Mac and iPhone checks each pass one case with zero failures/skips/reported runtime warnings: local entry, actual task capture, ordinary relaunch and exact whole-workspace retention. All 24 account-transport cases pass per repo, independent Debug test builds pass, and the Mac deep signature passes. Six final captures were inspected. The runner could not write the Mac app sandbox during fixture restoration; cleanup now runs externally and removes only the verified synthetic local cache, with no claim of original cache-byte restoration. Test apps/runners are closed, disposable app/runner removed and Simulator shut down; all 100 protected files remain exact. See `auth-local-escape-evidence.json`. Release was not rebuilt for this UI change. External OAuth/provider, installed widget-host, spoken VoiceOver and other P0 gates remain open; release signing stays user-deferred.


### 12 October — actionable backup-provider read failure and safe retry

A native Mac reproduction showed only “NSURLErrorDomain error -1009” when coordinated backup reading failed. Both owned readers now explain how to make the file available and choose it again, with explicit unchanged-work reassurance; cancellation and parsing/size-validation behavior remain separate. A first-read-only isolated presenter reports failure through the actual file coordinator. Final native Mac and iPhone journeys each pass one case with zero failures/skips/reported runtime warnings: error dismissal, enabled Retry through the native picker, same-file review, Cancel and ordinary relaunch with exact whole-workspace preservation. All six coordinated-read cases pass per repo; independent Debug test builds and Mac strict signature pass. Eight before/final captures were inspected. Mac driver corrections account for value-based text and the Touch Bar duplicate of OK. See `backup-provider-failure-evidence.json`. All app/runner sessions are closed, the disposable iPhone app/runner removed and Simulator shut down, and 100 protected files remain exact. This accepts controlled coordinator failure recovery, not an actual remote provider outage or new restore-apply coverage. Desktop widget observation still times out; external OAuth/provider, spoken VoiceOver, APNs and other P0 gates remain open. Release was not rebuilt for this message change; signing stays user-deferred.


### 12 October — real native Mac/iPhone task conflict and return

Six ordered native phases pass against one synthetic task in the existing disposable account: two distinct Mac offline edits and normal Quit/relaunch; an independent iPhone title/notes edit; Mac Later/relaunch/Use synced; phone receipt/relaunch; native Mac deletion; phone cleanup receipt. The synced title and independent notes survive alongside the later offline Priority 1. Both resolved saved workspace dictionaries remain exact across relaunch. Twelve non-activity server-table comparisons match their baselines, filtering only the synthetic task before deletion; all original activity rows remain. No new production behavior was required. Both repos own their DEBUG offline guards and native tests independently. See `live-native-task-conflict-evidence.json` and nine inspected captures.

The Mac preparation passes functionally but reports one internal QoS warning during title input, so clean-runtime acceptance remains open; the other five phases have zero reported runtime warnings. The failed launch/selector attempts and an accidental online inspection/reset of only the synthetic task are documented. All 24 account-transport cases pass per repo, independent Debug test builds and strict Mac signature pass. VoiceOver's original off state was restored after inspection timed out; no spoken acceptance is claimed. Test apps/runners are closed, the disposable app/runner removed and Simulator shut down, and 100 protected files remain exact. Pruned 8,594,944,145 logical bytes of inactive build intermediates/caches and duplicate exports while retaining app/extension products, current Debug caches and all native results. Remaining widget/privacy, external provider/OAuth, accessibility, mixed-client, delivery and other named P0 gates stay open; signing remains user-deferred.


### 12 October — one clear conflict-review Later action

Both owned conflict reviews now show one persistent Later action, removing the duplicate seen in the real conflict receipt. Resolution controls alone are disabled for a stale review, so its dismissal remains available; the existing cancel shortcut is retained. Final native checks pass one Mac and three iPhone cases with zero failures/skips/reported runtime warnings: unique enabled Later, cancelled review with whole-workspace equality, Use synced/independent comments/later 45-minute estimate and relaunch on both platforms, iPhone Keep my edit, and reachable 44-point actions at dark largest text. Nine captures were inspected; the three changed review layouts are retained. See `conflict-review-actions-evidence.json`. Stale-while-open behavior is source-verified only. The earlier live Mac title-input QoS warning remains open. All test sessions are closed, the disposable phone app/runner removed and Simulator shut down, 100 protected files remain exact, and the isolated Mac fixture bytes are restored. Independent Debug test builds and strict Mac signature pass; Release was not rebuilt. Broader P0 and user-deferred signing remain open.


### 12 October — new offline task survives revoked shared access

Native Mac Add Task created a shared-project task offline; the owner confirmed it had never reached the server, then revoked membership. Native recovery saved the unsynced work in the encrypted vault, previewed Add 2 / Update 0 / Keep 20, and restored an owned project/task copy with the complete notes and 25-minute estimate. Normal Mac Quit retained the copy; another native restore after synthetic cleanup reused its mapped IDs. The phone opened that exact copy, retained sign-in on normal relaunch, reopened its full editor, and received final synthetic cleanup. All preexisting rows across both accounts' 15 tables and all 100 protected local files were preserved. No product behavior changed in this checkpoint; each repo owns its native test source.

Five native phases functionally pass; four pass strict warning checks. The offline Mac phase retains one internal QoS warning and is explicitly excluded from clean-runtime acceptance. Failed/interrupted drivers remain diagnostic evidence, including the rejected phone v5 relaunch screenshot; corrected v6 checks the signed-in screen as well as disk persistence. This closes the named Mac new-creation case only. The phone's own genuine access-loss creation/restore and broader P0 gates remain open; release signing remains user-deferred. See `new-task-access-recovery-evidence.json` and its three inspected app-scoped captures.

Test apps and runners are closed; the disposable phone app/runner are uninstalled and its Simulator is shut down. Duplicate exports and redundant private credential copies totaling 21,229,154 bytes were pruned; native result bundles and installed system widget extensions were preserved. Free storage is approximately 98 GiB.


### 12 October — phone-native new-task access recovery accepted

The phone now independently passes native shared-project capture offline, genuine owner revocation before the first POST, encrypted recovery preview/apply, and signed-in relaunch with the task reopened. Full notes, priority 2 and the 45-minute estimate survive in an owned project/task copy. Native preview shows Add 2 / Update 0 / Keep 20. Mac receives the same mapped identities and fields, opens its inspector, retains the copy after normal Quit and receives synthetic cleanup. All four phases pass strict XCTest checks with zero runtime warnings; the earlier Mac QoS warning remains separately unresolved.

No product behavior changed: each repo owns its native regression source. All preexisting rows across both accounts' 15 tables and all 100 protected local files are preserved. The exact encrypted recovery file is retained privately; three inspected app-scoped captures accompany `phone-new-task-access-recovery-evidence.json`. This closes the phone-own case left open by the previous Mac recovery checkpoint. Organization/account-switch access-loss variants and the other current P0 gates remain open; release signing remains user-deferred.

Final cleanup: main Taskfold apps and UI test runners are closed; the disposable phone app/runner are uninstalled and its simulator is shut down. All 100 protected files remain byte-identical. Removed 2,863,507 bytes of duplicate capture exports and credential copies, retaining the four native result bundles and encrypted recovery proof. Available storage: approximately 97.8 GiB. Existing widget hosts are preserved.


### 12 October — live Keep my edit cross-device return

A real native Mac offline title edit plus later Priority 1 now competes with native phone title/notes edits. Direct Mac computer use verifies Later, normal Quit/relaunch, Keep my edit, full inspector reopening and native synthetic deletion. The Mac title, independent phone notes, later priority and original 25-minute estimate survive; the full Mac saved snapshot is unchanged across each relevant relaunch. Three iPhone native phases pass strict checks without runtime warnings, including signed-in editor reopening and deletion receipt. See `keep-local-conflict-evidence.json` and its inspected phone capture.

Both independent Debug test builds and the Mac strict signature pass. Two Mac XCTest attempts fail before app cases while enabling automation; direct CUA acceptance is functional and does not establish a clean Mac test runtime. The earlier QoS warning is unresolved. All 13 non-activity tables exactly match the 15-table baseline after native cleanup; all preexisting activity/epoch rows and 100 protected local files are preserved. Test sessions are closed and the disposable phone app/runner are removed. No product fix was needed; both repos own their regression helpers. Other P0 gates remain open and release signing remains user-deferred.


### 12 October — offline section and task recovery

Native phone creation now covers a new section and its task while offline. Actual owner revocation occurs before either POST reaches the server. The encrypted safety copy previews Add 3 / Update 0 / Keep 20, then restores a new owned project/section/task graph with exact parent relationships, complete notes, Priority 2 and 45 minutes. Signed-in phone relaunch and direct native Mac grouping/inspector/normal Quit-relaunch preserve the graph. See `section-access-recovery-evidence.json` and two inspected app-scoped captures. Each repo owns its parser regression; iOS also owns the phased native helpers. No production fix was needed.

The initial capture attempt failed before task Save: More options retained literal references. At that checkpoint its cause remained unexplained; the 13 October stable-capture receipt below supersedes that open finding. The instrumented retry passes; separate draft-only checks then pass three normal/light repetitions and one largest-text/dark case without observation pauses around Hide keyboard → More options. All six successful native runs report zero runtime warnings. These do not prove the original failure fixed or establish a clean Mac XCTest runtime.

Synthetic cleanup restores all 13 non-activity server tables exactly and retains all original activity/epoch rows across both disposable accounts. All 100 protected local files are unchanged. Main apps/runners are closed, disposable phone app/runner uninstalled and simulator shut down. Pruned 65,676,945 bytes of duplicate exports/credential copies; retained original native results and the private encrypted proof. Free storage is about 97.1 GiB. Account-switch recovery, remaining widget/privacy, spoken VoiceOver, external provider/mixed-client and delivery gates remain open; signing stays user-deferred.


### 12 October — native iOS accessory privacy

The iOS Today circular, rectangular and inline views now pass a native in-memory host check under explicit SwiftUI privacy: expected normal content, native privacy selection, readable generic private accessibility with no synthetic task details/counts or task buttons, three inspected private captures, then return to normal. One accepted iPhone case passes with zero failures/skips/reported runtime warnings. The first host-switch driver failed before private checks; a test-only explicit button and visible-state waits correct it. No production code changed. See `ios-accessory-privacy-evidence.json`.

This closes the compile-only runtime gap for those iOS accessory branches; it does not establish installed WidgetKit/system-selected locked-device privacy or spoken VoiceOver. The iOS repo owns its reproducible generator/fixtures; Mac receives scoped evidence only. Both generated Debug test builds pass. All 100 protected files are exact, main apps/runners closed, disposable app/runner uninstalled and simulator shut down. Pruned 311,881,986 bytes of inactive products/duplicate exports, retaining native results and system widget hosts; about 97.2 GiB free. Other current P0 gates and user-deferred signing remain unchanged.

### 13 October — stable capture controls

The previously unexplained fresh-section capture failure now has a native reproduction and scoped fix. Content-driven sheet resizing moved capture actions into preview chips. iOS now opens at a stable large height, offers manual medium sizing, keeps the footer uncompressed and updates live chips without reflow animation. Each repo independently preserves the flow layout's offered width; parser/store/backend contracts are unchanged.

Seven native iPhone executions pass with zero failures/skips/reported runtime warnings: three rapid fresh-project/section → Hide keyboard → More → Save/relaunch repetitions, a separate stationary-target/clearance/persistence case, largest-text reference selection, and both existing normal/largest landscape keyboard Save/More/relaunch cases. Exact title/parents/Priority 2/45 minutes and whole-workspace preservation pass. Earlier one-off passes were rejected by repetition; failed product attempts and observer corrections remain in `capture-control-stability-evidence.json`. Four public synthetic captures and both landscape keyboard captures were inspected. Scroll-clipped preview tails are not classified as visible control overlap.

Both apps compile independently in Debug and Release, with retained warnings outside these changed product files. This closes the named iOS capture failure, not broad P0 or native Mac acceptance of the layout change. All 100 protected files are unchanged; main apps/runners are closed, disposable app/runner removed and Simulator shut down. Pruned 1,309,446,817 logical bytes of inactive products/duplicate exports; about 96.9 GiB free. Broader gates and user-deferred signing remain open.


### 13 October — companion entity identity diagnostic

13 October entity identity follow-up: runtime identifiers match the packaged metadata keys. A unique extension module and then unique list entity/query/configuration names with a fresh installation both still fail to expose the selected task. The latter video shows overlapping unselected/private widget states; serialization alone is not proven as the cause. No diagnostic type rename was promoted. See `widget-entity-identity-evidence.json`. Next: a minimal constant-entity widget to separate framework/installation behavior from Taskfold projection. Automatic expiry remains unaccepted. The Mac widget implementation is unchanged; these are iPhone Simulator diagnostics, not new Mac host acceptance. All test main apps/runners are closed, disposable phone app/runner removed and simulator shut down; 100 protected and 36 retained fixture files remain exact.


### 13 October — companion installed automatic expiry accepted

13 October installed-widget acceptance: the constant-entity control fails on the retained iOS 26.5 Simulator but passes unchanged on a fresh iOS 26.2 Simulator. The real medium My list then passes selection, last-task completion, visible acknowledgement, automatic All clear without dismiss, unrelated task retention and completed-state relaunch. Both passing runs satisfy the strict native verifier. This closes the named iPhone automatic-expiry journey on iOS 26.2; it does not close iOS 26.5 registration, Mac installed expiry or broader P0. See `widget-configuration-control-evidence.json`. The tested extension source is byte-identical to this independently owned Mac copy; that establishes source parity, not Mac installed-host acceptance. Native logs retain remote AX/animation-idle messages despite zero structured runtime warnings. Production code and release signing are unchanged.


### 13 October — companion iOS 26.5 signing setup corrected

13 October signing correction: the iOS 26.5 selection failure was in the isolated test setup. Its products were ad hoc because the existing team-signing helper excluded backupcanceltests. With that identity explicitly allowlisted and real team signatures verified in installed app/extension, the same current widget passes selection, completion, automatic All clear without dismiss, unrelated task retention and normal relaunch on the retained iOS 26.5 device. One strict native test passes with zero failures/skips/structured runtime warnings. No production entity rename or fallback was needed. See `widget-team-signing-evidence.json`. Mac installed expiry and broader P0 remain open. This changes iOS-owned test infrastructure only. Mac widget code remains independently owned; its installed automatic expiry still needs a native receipt.


### 13 October — bounded current P0 checklist

Reconciled the progress snapshot with the original Todoist port priorities. Replaced the accumulated 483-line historical snapshot with a current feature/acceptance checklist, preserving detailed attempts and limits in P0_RELEASE_STATUS and scoped receipts. Later-phase parity stays in the port backlog; passing native journeys are reused rather than reopening an exhaustive platform matrix. The signed current-source Mac widget host is running with its synthetic task still open while the manual automatic-expiry observation is pending. No new desktop acceptance, product change or release signing is claimed by this documentation update. Both repositories own the current checklist independently.


### 13 October — backup picker callback ownership

The Mac native panel now captures an immutable request and workspace generation, rejecting stale selection/cancellation before a coordinated read. Both repos independently own the lifecycle guard and eight new regressions; all 14 selected backup tests pass per repo. Mac Debug compilation passes; current Mac native panel runtime is not claimed because the installed widget test remains untouched while its user observation is pending. Three actual iPhone Files retry/cancellation/navigation cases pass with whole-workspace preservation; see `backup-picker-session-evidence.json` for the separate platform/signing limits. No backup schema or backend changes.


### 13 October — native Mac backup callback-fix regression

Current-source team-signed isolated host passes the real native file-picker/provider-wait Cancel/retry/review/Cancel journey, with full workspace equality and a verified stopped-process boundary before fixture-preserving relaunch. Actual task receipt is visible afterward. Direct CUA screenshots/AX were inspected; no Mac XCTest runtime or real remote-provider race is claimed. The temporary backup app is closed, its 28 original data/preference files restored, and primary data plus the pending widget snapshot preserved. See `mac-backup-picker-session-evidence.json`. No additional product change was needed.


13 October: guarded unknown filter settings against lossy editing; native Cancel/Quit/relaunch preserves the snapshot. Unsupported-filter empty-state/count and sheet-title presentation remain open; see `filter-future-settings-evidence.json`.

13 October follow-up: unsupported filters now have an honest unavailable state; native Mac Cancel retains the correct main window title. Phone largest-text explanation/action/Cancel/relaunch passes. Evidence: `filter-unavailable-presentation-evidence.json`.

13 October: two retained QoS diagnostics traced to AppKit Services-menu accessibility scanning, with UUID-correct stack relocation. No speculative app scheduling fix. Older notes/table/profile-cycle findings and actual spoken accessibility remain open. See `mac-runtime-warning-attribution-evidence.json`.

13 October: fixed independent label loss during Keep my edit, later offline replay and Undo/Redo. Companion iOS owns the same membership behavior independently. 54 affected tests per repo, guarded-request regression and final native Debug builds pass; live paired label acceptance remains. See `label-conflict-preservation-evidence.json`.

13 October — native label continuity: current Mac app/tests compile with stable label-toggle identifiers. Mac runner fails automation initialization before executing app steps; subsequent CUA is blocked by the locked Mac. No paired Mac pass claimed. iPhone native label save/live sync/relaunch passes; original isolated Mac files restored and unused process closed. Pending desktop widget host untouched. See `native-label-continuity-evidence.json`.

13 October: reserved Mac 1.2.0 (3) and iOS 1.4.0 (19) as the first P0 continuity candidates, with independent owned metadata policies/checkers and matching app/widget versions. Sixteen metadata regressions and five actual Mac DMG integration cases pass, including rejection of an obsolete signed fixture payload in a valid mounted DMG. Xcode Release settings match; no release build or distribution is claimed. Mac publication checks the owned project and packaged minimum build; iOS operators have explicit project/exported-app checks. Older active writers remain unsupported and must be upgraded/retired; the server still permits legacy direct writes. Remaining native/service gates and user-deferred signing stay open. All 100 primary, 28 isolated Mac and 36 retained widget files plus the pending desktop fixture remain exact. See `CONTINUITY_RELEASE_POLICY.md` and `continuity-release-boundary-evidence.json`.

13 October: read-only runtime/prerequisite audit inventories the original table warning and six cloud launch cycle logs. Bare warning IDs do not identify a causal view; current deferred selection pruning predates the table warning, so no speculative production fix is claimed. Every remaining checklist gate now maps to its missing external observation/input. Native access failed across three consecutive goal turns, while earlier turns made independent phone/release progress. Full completion remains unproven; the audit supports blocking automatic work pending changed prerequisites. No native launch/build/test, provider request or product change occurred. Protected 100/28/36 file sets and the open pending widget fixture remain exact. See `p0-prerequisite-audit-evidence.json`.

13 October after unlock: actual Mac-offline/iPhone-independent/Mac-Keep label journey now retains all four memberships and phone notes, with selected controls and whole-cache normal relaunch proof on both. Four native cases pass; a review-driver String cast failed after actual settlement, then the corrected NSNumber verifier passes final Mac retention with zero runtime warnings. The first queue case’s missing exported drag-type warning was isolated-preparation metadata: shipping declares the type, and all six prepared variants now use a matching private type without file associations. Both final native builds pass; both review captions now mention independent labels. Synthetic task/four labels removed, all original rows in 14 tables preserved, 42 prior activity entries unchanged and two synthetic ledger entries retained. Protected 100/28/36 file sets and pending widget host remain exact; unused sessions closed. Other P0 gates remain open. See `live-label-pair-evidence.json`.

13 October runtime follow-up: a fresh read-only cold-cloud/Settings/picker-Cancel/relaunch case passes with zero structured runtime warnings and exact preservation of 14 cache/server tables. Its three-task workspace, ignored OS restoration and closed Settings window do not cover the original large import or restored-profile cycle triggers. The exact pinned-note edit/Undo/relaunch case passes functionally but again reports one QoS warning; the new archive captures that event, with UUID-matched AppKit Services/Data Detectors menu accessibility frames (40/59 symbolicated). The old missing event remains missing. No speculative product fix or warning suppression. VoiceOver caption/copy probes still yield no identifiable speech; verified settings restored, local draft cleared, human listener availability pending. Protected 100/28/36 file sets and pending widget fingerprint remain exact; unused test apps closed. See `mac-runtime-followup-evidence.json`. Original table/profile and spoken acceptance gates remain open.

13 October original imported-workspace follow-up: fresh native sign-in to the original disposable Taskfold import owner (256 tasks, 24 current projects) now passes Account-during-startup, Settings-left-open Quit, relaunch with OS restoration enabled, explicit Account reopening and All Tasks. One strict native test passes with zero runtime warnings; raw table-reentrancy and AttributeGraph counts are zero. All 14 cache tables survive relaunch exactly, and all 15 server tables including 368 import mappings and 258 activity rows remain exact. Account controls were not automatically restored; no automatic Settings-restoration pass is claimed. The original table warning still lacks a causal stack, and historical profile/avatar/restore cycle triggers remain unaccepted. No speculative product fix. Protected 100/28/36 files and pending widget fingerprint remain exact; extra test app closed. See `mac-imported-runtime-evidence.json`.

13 October profile runtime follow-up: the actual local Account → cloud Account transition, unsaved display-name draft through Sync Now and normal Quit/relaunch now pass in a guarded native Mac case, with zero structured runtime warnings and zero raw table-reentrancy/AttributeGraph cycles. Draft remains exact through sync, no profile save occurs, saved sign-in identity returns after relaunch, all cache tables including project rosters remain exact and all 14 owner server tables are unchanged. Two test-only expectation failures are retained: nullable profile name fallback, then omitted roster tables. Final case passes; no production change or historical causal fix claimed. Protected 100/28/36 file sets and pending widget remain exact; isolated app closed. See `mac-profile-runtime-evidence.json`.

13 October repeat-restore follow-up: native CUA opens the original checksummed synthetic backup in the 256-task imported workspace, verifies Add 0 / Update 0 / Keep 14 with disabled Restore, cancels, normally quits/relaunches and repeats successfully. Full cache and all 15 server tables remain exact. Four native runner attempts fail and remain recorded; the transient probe was not promoted, and no strict XCTest pass is claimed. Fresh normal-launch output reproduces four AttributeGraph cycles. A third process separates the observations: zero before CUA, four immediately after reading the main-window accessibility tree before Settings, still four after opening General. Account/repeat-review add none in the prior checkpointed process. The trigger is linked to main-window accessibility inspection; a causal stack and actual spoken impact remain unknown. Earlier clean XCTest cases do not establish clean ordinary launch. No speculative app fix or warning suppression. Protected 100/28/36 files and pending widget remain exact; extra app closed. See `mac-repeat-review-runtime-evidence.json`.

13 October human VoiceOver follow-up: actual foreground Add Task name/role and real Control-Option-Space capture now have listener confirmation plus saved-task proof. Title speech is clear, and the edited name was already autosaved before Return. Mac inspector now says “Changes save automatically”; Debug build, native layout/AX inspection and full local-cache relaunch pass. iOS retains its explicit Save action. Initial ChatGPT speech is excluded. Completion is saved and reported clear, but the reported Command-Z leaves it completed; ordinary main-window Edit → Undo then reopens it, so no spoken shortcut Undo pass or causal fix is claimed. Recovery/picker cancellation is reported clear and Account returns; exact live picker route was not sampled and final focus is Export. VoiceOver off and welcome dialog on are verified restored. Protected 100/28/36 files and pending widget remain exact; extra app/Utility closed. See `mac-human-voiceover-evidence.json`. Broader spoken and existing runtime gates remain open.

13 October keyboard Undo follow-up: an independently owned native Mac case now corroborates the listening-session sequence in durable data: capture → title autosave → Space completion → acknowledgement expiry → Command-Z → redo → Undo → normal Quit/relaunch, with whole-cache equality. Two functional cases pass, one with VoiceOver off and one on, each asserting the actual public system mode before/after. Both retain one QoS warning and are rejected by the strict clean-runtime verifier; captured UUID-matched stacks attribute both to AppKit Services/Data Detectors menu accessibility inspection. Three failed setup/capture/relaunch attempts remain recorded. No application shortcut defect is reproduced, and no speculative product fix is made. This is functional keyboard evidence, not a retroactive pass for the earlier manual event or new speech. VoiceOver off/welcome on restored; protected 100/28/36 files and pending widget exact; extra app/Utility closed. See `mac-keyboard-undo-evidence.json`.

13 October link-renderer follow-up: a symbol-only stack now identifies `LinkText.updateNSView` replacing attributed text during a table accessibility traversal. The local 256-task copy reproduces four cycles without cloud sync. Coalescing later text updates after the SwiftUI update clears the four cycles across four observed processes, including normal relaunches; the final launch/relaunch preserve the whole cache exactly. Link-click regression passes cleanly; title/completion/Undo/redo/relaunch passes functionally with one retained QoS warning. One table re-entry warning recurs on the final first launch, so runtime acceptance stays open. Original authenticated repeat review on the repaired binary is still pending. All protected data restored; extra diagnostic app closed. See `mac-link-accessibility-cycle-evidence.json`.

13 October table warning diagnosis: the actual Today → All Tasks warning now has a symbol-only native stack through nested AppKit row-height caching and SwiftUI list diffing; no app callback appears beyond entry points. An off-view link-measurement experiment fails and is reverted. Excluding custom link rows still reproduces it. A standalone standard-SwiftUI list app with synthetic text reproduces the same warning twice on macOS 26.6.2 / SDK 27.0, with a separated second run quiet before navigation and warning after All Tasks. The Mac repo owns the small reproducer and builder. This classifies a framework-level reproduction, not a clean-runtime pass or proof every historical warning has the same cause. Shipping sources restored/build successful; protected data exact; extra diagnostic apps closed. See `mac-table-reentry-evidence.json`.

13 October authenticated renderer verification: the original 256-task cloud account now passes fresh sign-in, Account during startup, normal Quit/relaunch and exact 14-cache-table preservation in a native case with zero failures/skips/runtime warnings. Its launch driver now uses the existing Dock-style reopen helper; one initial auth-field readiness failure is retained. Two normal OS-launched CUA processes select the original synthetic backup, show Add 0 / Update 0 / Keep 14 with Restore disabled, Cancel and normal Quit/relaunch. Full-cache and all 15 server tables remain exact. Both full-tree journeys now have zero AttributeGraph cycles; each retains one table warning present before CUA, adding none during recovery. Account is reopened explicitly; no automatic Settings-restoration claim. Protected data restored and extra app closed. See `mac-renderer-cloud-replay-evidence.json`.

13 October queued collection preservation: a concrete later-edit defect is reproduced independently in both apps: after a conflict choice, a later comments/attachments/subtasks replacement drops remote-only items from the local projection and can resurrect the discarded first edit. Both clients now rebase each later collection delta and reconstruct its original guard; independent remote work survives, while overlapping later changes still require review. Three new regressions cover 15 parameterized scenarios, including queue persistence, both choices, subsequent remote updates and nine guarded stub requests. Each repository passes 111 affected tests; Mac skips two unrelated native-fixture checks. Both native app builds succeed (iOS includes widgets). No live paired walkthrough is claimed; that exact sequence is the next distinct continuity check. Protected 28/100/36 files and pending widget data stay exact. See `queued-collection-preservation-evidence.json`.

13 October live comment continuity: both real paired choices now pass on the repaired sources. iPhone queues title/first-comment and later-comment edits offline with exact-cache relaunch; Mac commits its competing title, independent notes and comment; actual phone Review/Later/relaunch then Use synced or Keep my edit produces the expected two or three comments. Both clients retain each resolved whole task across relaunch; Keep preserves exact original comment IDs/authors/timestamps. Eight functional native cases pass, six clean and two with separately captured AppKit Services-menu QoS warnings. Two driver failures are retained: Mac Tab inserted into notes, and iOS Command-A failed to replace a title. The latter completed failure then stalled in Simulator diagnostic collection; only that finalization job was cancelled. Corrected native Select All validates input before Save. Only the two prepared tasks are removed; all original 15-table rows preserved, protected 28/100/36 files and pending widget exact, extra apps closed and Simulator shut down. Comments are the accepted live collection scope. See `live-comment-pair-evidence.json`.

13 October conflict guidance: both apps now direct blocked edits to Review without also offering generic Retry. Offline status and ordinary error retry remain eligible; no new UI acceptance is claimed for those separate branches. Isolated native Mac Review/Later/Use synced and both iPhone choices preserve independent comments, the later estimate and whole-workspace relaunch. Final results: Mac 1 and iOS 2 passing cases with zero failures/skips/structured runtime warnings; an initial Mac pass is retained before strengthening link-role assertions. Protected data restored, extra test app closed and disposable Simulator shut down; pending desktop widget host untouched. See `conflict-guidance-evidence.json`.

13 October system widget privacy prerequisite: actual disposable iOS 26.5 Settings now has a read-only native observation. Passcode is present at the root but opens a blank page with only Back, no content/switches. Search had reported no results because of a recorded system search error; public authentication availability also returns true, so neither is used as privacy acceptance. The final diagnostic passes with no runtime warnings; its earlier incorrect page-title assertion failure is retained. Actual host-selected redaction/routing stays open until a supported environment exposes those controls and a verifiable locked transition. Ordinary app testing remains in Simulator. No app/security/account data changed; test sessions removed and protected files exact. See `system-widget-privacy-prerequisite-evidence.json`.

13 October known-empty collection preservation: both clients reproduced a supported null/omitted-list defect (three regressions, 48 assertion failures each), then a nested child-record variant (one regression, 42 failures each). The merger now applies typed deltas to known-empty top-level and nested collections, including inverse guards for later queued edits; unknown/malformed baselines remain guarded. Six new methods cover 60 parameter cases, the extended guarded-request test covers 12 cases/18 stub requests, and 120 affected tests pass per repo. Final native Mac and iPhone each pass both review choices with zero failures/skips/runtime warnings, exact later estimate and whole-workspace relaunch. Native scope is comments; nested/attachment boundaries remain core evidence. One new backup expectation was corrected to the existing empty-subtask graph normalization; no backup product behavior changed. Protected data exact, test apps closed and disposable Simulator shut down; pending desktop host untouched. See `legacy-empty-collection-evidence.json`.

### 13 October — original-scope requirements audit

Reconciled ten requirement families against the original P0 plan and current sources. Eight retained native bundles (ten cases) reverify their original passing counts with no structured runtime warnings; this is read-only inspection, not ten new executions. Current collection source/tests match the latest repair evidence and the renderer is unchanged from authenticated replay. Both complete-order implementations match the accepted atomic contract; actual-role SQL covers all four organization tables. Per-list native permutations stay explicit limits rather than an ever-growing gate matrix. The named renderer cycle is fixed; table/QoS framework findings remain recorded release risks, with no historical warning relabeling.

The current progress summary now separates five remaining acceptance/prerequisite groups: installed Mac widgets, genuine system privacy, remaining spoken critical controls, actual iOS external provider boundaries, and remote delivery/distribution/old-writer rollout. Full P0 is not complete. Both owned release policies now list the completed identified-collection and known-empty/nested safety capabilities; these declarations are informational. Existing project metadata checks and eight release regressions pass per repo; no candidate signing/runtime proof or version/rollout change is inferred. Added the missing iOS-owned repository ownership page so the current summary's link resolves in each independent repository. No app launched or user/backend data changed. See `p0-requirements-audit.json`.


### 13 October — human Mac last-task automatic clear

The existing installed My list widget was configured for the earlier test list. After the user selected Widget Studio, Sketch widget concept appeared and its completion feedback cleared automatically to All clear without ×. The isolated cache confirms saved completion and zero pending work before/after normal Quit. No exact delay or relaunch pass is inferred. All Taskfold main apps are closed, while the installed widget/build is retained. The named automatic-expiry gap is closed; other Mac widget and P0 boundaries remain in the current progress checklist. See `widget-completion-expiry-evidence.json`.


### 13 October — workspace-bound widget record routes

Task, project, label and saved-filter widget links now retain their workspace. Both native app handlers reject stale wrong-workspace links before resolving a reused record ID, with useful feedback. Four new model methods join 44 passing affected tests per repo. One actual Mac and one iPhone URL/relaunch journey pass with zero failures/skips/runtime warnings: all four wrong-owner record kinds reject, matching project/task routes open correctly, and the full saved workspace remains unchanged. The named handler extraction preserves the previous routing statements. This is generated-link and native handler evidence, not a new installed-widget/cloud-account switch pass. Existing unscoped shared links remain compatible; older widget frames must refresh to acquire ownership. All test main sessions are closed, the phone test app/runner removed, Simulator shut down, protected 100/28/36 file sets exact, and the human-completed Mac fixture unchanged. Pruned 716,132,352 bytes of inactive unsigned compile products. See `widget-record-route-evidence.json`.


### 13 October — current Mac widget host prepared with normal local work

Built and development-signed current Mac source 38893b2 as isolated v10, verifying all 63 app/widget Swift files differ only by namespace. Only its widget extension is registered. Prepared Desktop widget workshop through normal app UI with a tomorrow/25-minute task, pinned three-line instructions and an unrelated undated Inbox task; no seed arguments are needed on a widget cold launch. Both tasks remain open with zero pending changes. The prior preparation app was quit normally; obsolete extension stopped and 372,752,384 bytes of inactive old build products removed. Current local snapshot, the earlier human-completed fixture and all 100 protected primary files remain exact. CUA then reported the Mac locked; no v10 main process started, and no new installed-host acceptance is claimed. Manual unlock requested before inspecting the new build and configuring the real widget. See `mac-widget-normal-workspace-evidence.json`.


### 13 October — installed Mac My list normal-workspace cold task route

After manual unlock, current v10 normally launches without fixture arguments as PID20026. Native inspection confirms the saved project, tomorrow date, 25-minute estimate, enabled note pin and exact three-line instructions; the whole local snapshot is unchanged. Returned to Inbox with the inspector closed, then normal Quit left no main process. The user configured the actual My list instance for Desktop widget workshop and clicked Prepare the design review. Before CUA app binding, PID20280 was already running from v10 without arguments. Native inspection shows the project selected and exact task inspector, notes/date/estimate/pin, with full snapshot equality and unrelated Inbox task retained. This accepts the named installed My list configured-project cold task route in a normal local workspace; the widget size was not newly inspected, and other kinds/account/privacy conditions are not inferred. App quit normally again. Pinned note installation/cold route requested next; build remains untouched. See `mac-widget-normal-workspace-evidence.json`.


### 13 October — installed Mac Pinned note edit, refresh and cold reopen

The user added/configured a medium Pinned note desktop widget for Prepare the design review and clicked it while the current v10 main app was quit. PID21495 was observed before CUA app binding, without fixture arguments; the native reader showed all three original instruction lines. Edit details opened the correct task. Changed only the first note line to “Review the updated desktop widget layout.”; the complete saved workspace differed only in that task description, with date/estimate/pin and unrelated work retained. Published note text and the native reader updated exactly. After normal Quit, the user confirmed the updated widget preview and clicked again. PID21966 was already running before CUA binding without arguments; the full edited instructions and complete edited workspace were exact. One transient accessibility-tree failure during sheet transition resolved by refreshing the same binding, without restart. This accepts the named medium installed note workflow, without broader privacy/account/other-family claims.

Next, prepared a 25-minute Focus session for that same synthetic task through native controls and paused it after 3.373 seconds. Only focus_sessions changed from the edited-note baseline, with no pending changes; finish alerts remain off. Main app quit normally before requesting the installed medium Focus widget click. All 100 protected primary files and the prior human-completed widget fixture remain exact. See `mac-widget-normal-workspace-evidence.json`.


### 13 October — installed Mac Focus paused-session cold route

After the request to add/click a medium Focus session widget, the user replied go. Before CUA app binding, PID24758 was already running from unchanged v10 with no fixture arguments. Native inspection showed the exact saved paused session for Prepare the design review in Desktop widget workshop at 24:57; the complete paused workspace was unchanged. The native panel screenshot was inspected. Resume then Pause worked, and End session showed Session ended / Time spent 00:06. Durable elapsed time is 6,400 ms, status stopped, and the published widget clock agrees. Only focus_sessions changed: task/project/note data, the unrelated Inbox task, pending changes and completion feedback were exact. Finish alerts remained off. Normal Quit left zero Taskfold main processes; all 100 protected primary files remain exact. This accepts the installed Focus cold route and subsequent native controls, not independent desktop-family/layout, account-switch or privacy coverage. Ended-state widget preview/cold reopen observation requested next. See `mac-widget-normal-workspace-evidence.json`.


### 13 October — Focus ended preview and preserved cold launch

The user explicitly confirmed the desktop Focus widget said ended. PID25661 was already running from unchanged v10 without launch arguments before CUA binding; native Focus showed Session ended for Prepare the design review / Desktop widget workshop and Time spent 00:06. The whole ended workspace was exact. This is consistent with the requested widget click, but the user did not explicitly confirm clicking and the trigger was not independently observed. Record the preview confirmation and actual cold-launch state without stronger click attribution. Native Project pulse preparation then selected Desktop widget workshop: 0 of 1 completed, 1 open, no overdue plans/near deadlines, 0 completion/reopen events and 1 added event. Whole workspace remained exact after normal Quit, with zero Taskfold main processes and all 100 protected primary files unchanged. Installed Project pulse configuration/click requested next; no new Pulse installed acceptance. See `mac-widget-normal-workspace-evidence.json`.


### 13 October — installed Project pulse cold route and completion refresh

PID26288 from unchanged v10 was observed before CUA binding, without launch arguments; the user then confirmed clicking the configured Project pulse widget. Native overview selected Desktop widget workshop, 0 of 1 completed and 1 open; whole saved workspace was exact. Completed only Prepare the design review through its inspector: native overview and published projection changed to 1 of 1, and the user confirmed the installed widget showed 100%. Native Command-Z restored the task and native/published totals to 0 of 1. History correctly retained 1 completion and 1 reopen event, separate from current totals. Only task completion fields and task_activity changed; after Undo the task differs from the original solely by completion_version=2, with notes/date/estimate/project and unrelated work unchanged. Normal Quit left no main app sessions; all 100 protected primary files remain exact. Installed reverse-refresh observation requested. CUA screenshot was white/unusable, so readable visual desktop-family/layout acceptance is not inferred from the correct accessibility tree. See `mac-widget-normal-workspace-evidence.json`.


### 13 October — installed Project pulse reverse refresh accepted

The user confirmed the desktop Project pulse widget returned to 0 of 1 completed after native Undo. The full restored workspace remains exact to the post-Undo baseline and no Taskfold main app session is running. All 100 protected primary files remain exact. This completes the named installed project selection → cold overview → completion refresh → Undo reverse-refresh journey. Existing visual-family, account and system-privacy limits remain; the full P0 objective is not complete. See `mac-widget-normal-workspace-evidence.json`.


### 13 October — normal signed-out widget host prepared

Through current v10 native Account controls, chose Leave Local Workspace and confirmed the explicit promise that saved tasks/pending changes stay on this Mac. Account then showed Not signed in / No workspace open, disabled backup controls and the main sign-in screen. The full local cache remains exact to the post-Undo baseline. Published widget payload is account empty, updated 0 and tasks empty, without any test task/project/note content. Closed Settings and quit normally; no Taskfold main process remains. Requested one grouped human observation of installed My list/note/Focus/Pulse content removal plus a Project pulse click. This is native sign-out/cache/publication evidence; actual installed refresh/safe cold routing remain pending. No real account or Todoist data changed.


### 13 October — four installed widget kinds clear and recover with workspace access

The user confirmed installed My list, Pinned note, Focus session and Project pulse stopped showing workspace content after native Leave Local Workspace. Before the follow-up click no main app was running. User then explicitly clicked Project pulse; PID27993 was observed before CUA binding from unchanged v10 without launch arguments. It opened only the native sign-in screen, without test project/task/note content. Reopened through Use on this Mac without an account: the entire post-Undo workspace was exact, with the open task, tomorrow date, 25-minute estimate and edited three-line note visible natively. Published note, ended Focus and 0-of-1 Pulse returned. After normal Quit, the user confirmed all four installed widgets again showed the expected content. All 100 protected primary files and the earlier human-completed fixture remain exact; no Taskfold main sessions remain. This accepts the named normal-local leave → content clear → safe signed-out cold route → preserved return journey. Cloud-account-to-account transitions and actual system-selected privacy remain separate. See `mac-widget-normal-workspace-evidence.json`.


### 14 October — selected note unavailable condition prepared

Unpinned only Prepare the design review through the native Pinned note reader. The native pinned-notes list shows its useful empty state, and published notes are empty. Only the pin selection in view_orders changed; all task records/text, other tables, pending changes and completion feedback are exact to the post-Undo baseline. Normal Quit left no main process. Installed Note unavailable preview/cold route observation requested before repinning the same task. This prepares the distinct selected-record-unavailable condition; it is not yet installed acceptance. All 100 protected primary files remain exact.


### 14 October — unavailable-note click safe; preview report under investigation

The user reported the widget still showed instructions after unpinning and clicked it. PID31652 was observed before CUA binding from unchanged v10 without arguments. It opened the safe empty Pinned notes list, without exposing the unpinned text in the reader; whole unpinned workspace and empty published notes remain exact. Targeted host logs record successful note timeline reloads without matching errors, including after the click. The current installed note instance is logged as systemLarge: earlier medium wording came from the requested setup, not an independently inspected family, and must not be treated as medium-layout acceptance. The possible missing-entity-resolution cause is unproven; no speculative product patch was made. Requested exact current widget text to distinguish stale task instructions from unavailable-state guidance. Main app quit normally; note remains temporarily unpinned until observation resolves, task/text retained. See `mac-widget-normal-workspace-evidence.json`.


### 14 October — unpin report resolved as empty selection; pin restored

The user clarified the exact installed note-widget text: Keep a thought close, with no note. This confirms old note content was gone; it does not establish a stale-content defect. The observed empty-selection wording differs from the requested Note unavailable wording, which is not claimed. The prior real cold click safely opened the empty Pinned notes list. Restored Show notes in widgets on the same retained task through the native inspector. The entire saved workspace is now exactly equal to the post-Undo baseline, and the published note contains the exact edited three-line instructions. Main app quit normally; all 100 protected primary files remain exact. Installed restored-preview observation requested. No product-code patch or new build was needed; earlier hypothesis remains unproven. See `mac-widget-normal-workspace-evidence.json`.


### 14 October — repinned selection title recovered

The user reports the Pinned note desktop widget again shows Prepare the design review, the expected task/note title. This confirms selection recovery from the empty message after repinning. The user did not newly confirm the instruction body; do not infer that observation from the title. The full saved workspace is still exactly equal to the post-Undo baseline, and the published note has the expected title plus exact edited three-line body. No main app session remains; all 100 protected primary files remain exact. The named unpin → safe empty click → repin selection-recovery check is complete within this scope; no stale-content defect was established or product patch needed. See `mac-widget-normal-workspace-evidence.json`.


### 14 October — retained authenticated widget-host driver and first phase

The note-specific second-account fixture was cleaned up, but another retained backup fixture contains two existing distinct disposable identities. Both authenticated successfully; saved read-only baselines of 14 visible workspace tables per account. Added a guarded native driver to operate normal Leave/Sign In/Sign Out/local-return controls against the retained installed v10, without seed arguments or task edits. Build-for-testing passed; retargeted the runner to the unchanged existing app and removed 40,964,217 bytes of duplicate app/extension products. First phase passes: real native local → authenticated transition, three synced tasks, no pending changes, exact normal-local cache and normal Quit. Structured result verification: 1 pass, 0 failures/skips/runtime warnings. Both server baselines remain exact afterward. Installed authenticated content/heading route is pending human observation; second/local driver branches are compiled only. Existing installed iOS cloud-account evidence remains separately scoped. VoiceOver checks are user-deferred until later. See `mac-widget-cloud-workspace-evidence.json`.


### 14 October — installed authenticated widget cycle verified with direct desktop reads

The user's My list heading click cold-launched existing v10 as PID78299, observed before CUA binding without arguments, into All Tasks for the first disposable account, without the old local project. Finder Desktop now exposes widget accessibility text directly: the local My list/note selections are empty, Pulse unavailable, and unconfigured Today/Focus correctly show the current cloud account's own work. The user's “most cleared” report is resolved within this directly inspected scope; current-account aggregate content is expected, not a local-content leak.

Ran the retained guarded native driver through the second existing account and return to normal local mode, using real Sign Out/Sign In/Use locally controls and no seed arguments. All three phase results have 1 actual pass each, zero failures/skips/structured runtime warnings. Direct installed desktop reads in the second account show empty local selections and idle Focus, without local or first-account Focus content. After local return, direct reads show My list's original project/task, the Pinned note's exact edited three-line body, ended Focus at 00:06, and Pulse 0 of 1 with one completion/reopen event. Original local snapshot, both 14-table server baselines, 100 protected primary files, prior human-completed fixture and retained app/widget binaries are exact. Main app quit normally; all test phases are terminal.

A direct AX click on the second account's unavailable My list text returned without launching; Finder screenshot omits the widget layer. No second-account click or pixel-layout acceptance is claimed, and no repeat manual click was requested. Reading desktop text now removes the need for routine human text observations; manual requests should be limited to distinct inaccessible interactions. Pruned 295,353,973 bytes of inactive compile products, retaining host/runner/results.

Direct Today text also exposed “1 scheduled tasks”. Both owned widget sources now use singular task at count 1; zero/plural and unavailable wording remain. Both WidgetModel builds and the full Mac widget extension build pass. This source-only wording fix was not installed into the retained host; no new installed wording or VoiceOver speech claim is made. VoiceOver remains user-deferred. See `mac-widget-cloud-workspace-evidence.json`.


### 14 October — desktop action automation bounded diagnostic

Direct CUA desktop text reads remain reliable for the installed test widgets, but ready task-link activation returned without launching and desktop context-menu access failed with AXError.illegalArgument. Tried two guarded native Xcode approaches against the retained host, without launching the main app first. Both driver builds succeeded. Finder's query located the task button and passed frame/hit checks, but XCTest mistook the system-owned widget window for an interrupting notification banner and failed its default banner-dismissal handler before launch. A second query targeted the observed Notification Center owner; that application does not expose the matching task button, so existence failed before any click. Each diagnostic has 0 passes, 1 failure, 0 skips; the failed results/private source are retained, without relabeling them as product-test passes.

Stopped after these two approaches and removed the experimental test from the repo exactly to its preceding committed source. No product code changed. Full normal local cache, all 100 protected primary files and retained app/widget binaries remain exact; direct desktop text still shows the local task, edited note, ended Focus and original Pulse state. No Taskfold main session remains. Removed 81,915,318 bytes of duplicate compile app/extension products and 92,886,218 bytes of inactive intermediates. Routine content checks remain automated; do not repeat unchanged action attempts or routine manual click requests. Distinct remaining installed planning configuration/actions need a supported interaction surface. VoiceOver remains user-deferred. See `mac-widget-desktop-automation-evidence.json`.


### 14 October — isolated iOS File Provider feasibility diagnostic

Investigated a genuine replicated File Provider in Simulator to reduce dependence on Apple-account sign-in and manual checks. This is a standalone synthetic app/extension, outside both production targets, with one harmless JSON file and no network or user-file access. Development signing plus linked Simulator identity/app group allows domain registration. Native Files exposes the fixture; its unnamed switch is accessible within the named location row. Opening the location requires a separate first-use Turn On confirmation. After accepting that confirmation for this fixture only, direct getUserVisibleURL lookup changes from domainDisabled (-2011) to operation not permitted (POSIX 1). No coordinated read completed, and no Taskfold backup/provider/offline/callback gate is closed. This direct-lookup failure does not prove that system-picker selection is unsupported. The next distinct approach is actual picker selection.

Two setup attempts selected a nonexistent generated xctestrun filename and executed no tests. Correcting the filename allowed four native diagnostic runs, each with 0 passes, 1 failure, 0 skips and no structured runtime warnings; failure evidence is retained. Builds retain SDK/minimum-version and metadata warnings. Private source and final products are retained for a distinct follow-up; no failing experiment was added to production tests. Uninstalled only the synthetic probe/runner, closed their sessions and Files, and shut down the disposable Simulator. All 164 protected files remain exact. Pruned 206,248,345 bytes of inactive compile products. No Apple account or real Taskfold/Todoist data changed. See `ios-fileprovider-feasibility-evidence.json`.


### 14 October — real picker diagnostics and file-access recovery guidance

The standalone replicated provider now reaches the real system picker, but its item is absent. File Provider's own log shows POSIX 1 while creating the item's filesystem metadata (cannotSetMetadata). A fresh iOS 26.2 Simulator reproduces the same failure as 26.5. A separate nonreplicated test provider gets further: its file is visible and selectable, but the coordinated client read reports NSCocoaErrorDomain 260, and no startProvidingItem callback is observed in retained logs. Adding download metadata/placeholder support did not complete the read. Initial nonreplicated diagnostics were interrupted by the obsolete same-identity fixture's replicated-domain/class mismatch; that app was removed before later attempts. All eight new native diagnostics retain failures, not passes. They used a standalone SwiftUI fileImporter, not Taskfold's UIDocumentPickerViewController path. No Taskfold restore, download, offline or late-callback gate is closed; the next distinct approach is the production-equivalent picker with verified materialization. See `ios-fileprovider-feasibility-evidence.json`.

This exposed a concrete reader UX gap: when coordination succeeds but file metadata/bytes cannot be read, both apps passed through the raw system error. Both independent readers now use the existing download/availability/retry guidance for file-access failures, with parser errors outside that catch. A real local filesystem regression fails before repair in each repo (one failed case, three assertions); all eight focused cases now pass independently in each repo, including retry, cancellation, presenter coordination, size rejection and specific invalid-version guidance. The full iOS Debug Simulator app build passes with retained warnings in unchanged sources; no warning-free or native restored-provider acceptance is claimed. See `backup-file-access-guidance-evidence.json`.

All 164 protected files remain byte-exact; the prior human-completed Mac fixture is byte-exact and the normal Mac local JSON matches its full baseline. Both temporary provider apps/runners are uninstalled from the original Simulator, which is shut down. Public removal on reinstallation reports providerNotFound (-2001); explicit successful domain removal is not claimed. Xcode could not fully delete the newly created Simulator data (Cocoa 513/POSIX 1); the device remains listed as shut down, but a later boot attempt reports deleted. Its residual directory is retained without permission overrides. Pruned 817,120,560 bytes of inactive build files, retaining diagnostics and useful final probe products. No Taskfold main session remains; VoiceOver remains user-deferred.


### 14 October — actual iPhone external-provider transfer, restore and relaunch accepted

Closed the named download/restore/relaunch step using a real public File Provider extension and Taskfold's existing native picker. The provider fetches a bundled synthetic two-task backup from a loopback-only server in its actual startProvidingItem callback. Native Files controls activate only that fixture. Taskfold selects the external URL, coordinates the read, presents its normal restore preview and applies it. The final case passes once with 0 failures/skips/structured runtime warnings. After cold relaunch, native controls show the added task's description, 25-minute estimate and 25 Oct deadline, while the existing task retains its newer title. The complete existing task record matches the seed export with only its intended newer title, the materialized provider file is byte-exact, and the saved snapshot has two tasks and no pending changes. The isolated encrypted-vault index contains a Before restore copy for the original one-record workspace. See `ios-external-provider-transfer-evidence.json`.

Retained six failed diagnostics with their actual limits: static-title/rich-label lookups, an immediate history-UI assertion, a correctly rejected cached-file false pass, and failed redownloads from an invalid fixture domain mapping. The fixture declared a synthetic relative domain directory but returned URLs from its parent. Corrected that mapping using the SDK contract, and publish fresh file identities with proper enumeration notifications so each accepted run requires a new network delivery. Earlier standalone picker results do not establish a general SwiftUI/native-picker or Simulator limitation. No Taskfold picker/reader workaround or read-result injection was added. The reusable provider/server/installer and guarded native test live only in the iOS repo, separate from all shipping targets and the Mac build.

All 164 protected files remain byte-exact, the prior human-completed Mac fixture is byte-exact, and the full normal Mac local JSON is unchanged. Test main apps and the loopback server are closed; the original Simulator is shut down. Pruned 1,131,668,371 bytes of obsolete builds/intermediates, retaining final products, source and diagnostics for the next cases. The earlier replicated-device deletion residual remains stopped without permission overrides. Offline/unavailable recovery and delayed/cancelled workspace callbacks are still open; source endpoints alone do not accept them. VoiceOver and release signing remain user-deferred. The full objective remains incomplete.


### 14 October — iPhone external-file failure/retry and delayed workspace return accepted

The two remaining representative iOS external-file cases now pass against the real independently owned File Provider: 2 native passes, 0 failures/skips/structured runtime warnings. The unavailable case receives an actual HTTP 503 and the system picker's server/network alert; OK then Cancel returns to an enabled, reachable Restore control with the full cache unchanged. Bringing the same file online, without rotating its identity, produces actual 200 deliveries and the normal restore preview. Cancelling that preview and relaunching preserves the entire saved workspace. This is a system-picker error/recovery observation, not a new Taskfold error-alert claim.

The delayed case holds an actual provider request, cancels through the system picker, leaves the local workspace through real controls, then releases the provider response while the sign-in screen is visible. No old restore preview or saved mutation appears. Returning locally, retrying a valid external file, cancelling review and cold relaunch all preserve the full canonical cache. No claim is made that UIKit delivered a late URL callback to Taskfold; the observed provider response is genuinely late and system cancellation is part of the result. Existing held-read/auth-account evidence separately covers the app-owned asynchronous read guard. These cases, plus the accepted download/restore/relaunch, close the named representative external-file acceptance group. See `ios-external-provider-recovery-evidence.json` and `ios-external-provider-transfer-evidence.json`.

Only the guarded iOS native driver and documentation changed; shipping app/provider logic is unchanged. The final workspace contains exactly its original current task and no pending changes; its entire task record agrees with the seed export plus intended newer title. All 164 protected files and prior human-completed Mac fixture remain byte-exact; full normal Mac local JSON is exact. Test apps/server are closed and the shared original Simulator is shut down. Pruned 112,221,518 bytes of inactive intermediates while retaining useful final products/evidence. The earlier stopped replicated-device deletion residual is unchanged. Remaining Mac widget/system-privacy and user-deferred spoken/signing/rollout requirements remain open; the full objective is not complete.


### 20 October — automated installed refresh and overdue accessibility wording

Direct desktop accessibility reads verify the retained v10 host's normal refresh: Today and My list show the existing overdue task, Pinned note shows the exact edited three-line instructions, Focus shows its ended session, and Project pulse shows 0 of 1. Its seven-day window is now 14–20 October; the old completion/reopen events correctly age out. The complete local cache is canonically equal to the fresh pre-launch copy; serialized bytes differ. No seeded launch or task edit was used.

Fixed the current Mac Overdue accessibility heading's “1 tasks” wording. The independent Mac Debug arm64 build passes. It was not installed, so no new native fixed-label or spoken acceptance is claimed. iOS has no equivalent task-noun label to repair. Desktop widget actions remain inaccessible: direct action does not change the host route, the desktop screenshot omits widgets, Notification Center binding times out, and background context-menu action returns noWindowsAvailable. Desktop & Dock inspection exposes no gallery entry and changes no settings. No new action/layout/account-route acceptance is claimed. Routine human widget checks should not be repeated.

Retain the existing installed v10 build and persistent baseline/build log; remove the unused compile directory. VoiceOver remains off and its remaining human checks stay deferred, as does release signing. See `mac-widget-refresh-recheck-evidence.json`.


### 20 October — current Simulator privacy prerequisite remains unavailable

Used the retained native diagnostic once on the newer iOS 27.0 (24A434) iPhone 18 Pro runtime. Its actual Passcode row opens a blank page with only Settings back; screenshots and AX agree. One diagnostic passes with zero failures/skips/structured runtime warnings. The log retains a duplicate system accessibility-class console warning. Public authentication availability still reports true but does not prove usable privacy controls. No permission, passcode or app data changed. Removed only the isolated app/runner and shut down this previously stopped Simulator; the other already booted Simulators are untouched. No build was repeated. Genuine host-selected widget privacy remains open; do not repeat this unavailable Settings path. See `ios27-widget-privacy-prerequisite-evidence.json`.


### 20 October — installed Mac planning/aggregate group accepted

The human installed medium Day capacity and clicked it with the unchanged v10 host confirmed quit. It cold-opens Calendar in Day mode on 20 October; native 0m estimates, 480m capacity and disconnected calendar match the installed 8h/0m/unknown-calendar card. The human confirms readability. The first Inbox reset instance was registered to regular Taskfold and is excluded; after adding the isolated test instance, its Review all 1 opens the exact one-task Review Inbox sheet from a confirmed quit state. Native progress is 0 reviewed / 1 left, with Keep the workshop notes and all expected actions. Closing review returns to Inbox without decisions. Corrected Inbox text is directly readable in AX; there is no separate replacement-layout observation. Existing representative readable kinds plus Day capacity cover the bounded layout requirement without a per-kind matrix. This closes the named remaining Mac planning/aggregate group, not system privacy or universal family/account combinations.

The whole local cache remains canonically unchanged through both cold launches and final Quit; no main Taskfold app remains. The VoiceOver retry produced no intended hint speech; its switch was initially On with only Quickstart running, and final verification is Off with no screen-reader process. Neither a spoken pass nor an app navigation defect is inferred. No Restore activation attempt was made in this session. Keep the remaining speech, actual system privacy and user-deferred signing/distribution/rollout requirements open. See `mac-widget-planning-aggregate-evidence.json`.

20 October cleanup: removed 1,041,909,480 bytes of unused build intermediates/indexes after confirming no build was active. All files in the 17 retained final-product directories remain exact; test results, installed widget app and workspace data are retained. See `acceptance-cache-cleanup-2026-10-20.json`. Remaining acceptance prerequisites are unchanged.


### 20 October — genuine autosave and Restore spoken follow-ups accepted

Resolved the immediate test-environment startup obstacle by ordinary Quit of the old VoiceOver Quickstart helper in Activity Monitor after turning VoiceOver Off. A fresh start exposes the welcome window; Use VoiceOver launches the actual VoiceOver process and output helper, independently verified. The welcome checkbox stays unchecked. This corrects the earlier false assumption that the Settings switch alone established a running screen reader.

With genuine VoiceOver running, the human reports the autosave cue clearly. Native keyboard preparation focuses Restore from file; the human hears its name and activates it with Control–Option–Space. The actual open-panel sheet is sampled live, with Cancel enabled, Open disabled and no file selected. Human Escape closes it; native Account focus and human speech both identify Restore from file. That return to the initiating control is expected, not a navigation defect. The full saved local cache remains canonically unchanged. VoiceOver is restored off; temporary Activity Monitor search is cleared and that app plus the test app are closed. No product source changed and no new universal speech/runtime acceptance is claimed. Original spoken Undo and broader phone/critical-flow coverage retain their limits. See `mac-voiceover-live-followup-evidence.json`.


### 20 October — completion confirmation speech repaired

A separate human completion/Undo check reproduced a real feedback gap: Space saved completion but VoiceOver only said No row selected. Human Command-Z then announced Undo complete task and independently saved reopened state, closing the old uncorroborated shortcut follow-up. ConfirmationBar now posts its existing result as a high-priority accessibility announcement while the app is active with VoiceOver enabled, keyed by confirmation identity. The normal visual bar, Undo and persistence are unchanged. iOS independently owns equivalent toast speech, with a separate full task-name announcement for successful completion. No background/core Store speech hook was added.

The fixed fresh isolated Mac app was built without replacing the retained widget host. The human now hears No row selected followed by Completed spoken completion proof. The task is durably completed; native Undo reopens it, normal Quit/relaunch retains it, and the full post-Undo cache remains equal across relaunch. All unrelated task records/tables are exact, with only the intended completion version/activity/widget receipts changed. Both independent native builds pass with retained warnings; iOS has no new spoken acceptance. The first Mac invocation selected the shipping project and failed its development-certificate prerequisite before compiling, with no production signing or installed app change. Its failure log remains. Final VoiceOver is Off and both test main apps are closed. Unused compilation outputs are pruned while retaining the fixed Mac product, source, snapshots and logs. See `spoken-completion-feedback-evidence.json`.


### 20 October — named Mac filter/planner validation speech accepted

With the actual VoiceOver engine running, the human clearly hears Add a condition after the operator in a new unsaved filter containing today AND (. Save is natively disabled. Cancel discards the draft. Calendar Day opens a scheduling draft for a synthetic starter task; estimate 0 disables Save and the human clearly identifies Minutes and the 1-minute-to-7-days validation message through VoiceOver. No scheduling or filter changes are saved. The complete local workspace remains canonically equal before/after cancellation and normal relaunch. Restore original Week mode and Inbox, then quit; VoiceOver is verified Off and main test/screen-reader processes are absent. No product/test source or runtime warning assessment changed. Together with the recorded capture/edit/complete/Undo/recovery journeys, this closes the named representative Mac spoken scope; genuine iOS speech remains unverified. See `mac-spoken-filter-planner-evidence.json`.

### 20 October — real iOS VoiceOver service and explicit planner units

Xcode 27's public XCUIVoiceOverService returns genuine spoken utterances on iOS 27 Simulator, so critical iOS speech can be tested without requiring a physical device. The independently owned iOS test app reads its actual unsaved capture title and Add task button, then discards the draft and verifies the complete saved cache through relaunch. The first planner speech attempt reproduces an iOS field-name gap: VoiceOver says 0 Text field without Minutes, although its validation warning is clearly spoken. Both repositories now give that estimate field an explicit Minutes accessibility label; its visual layout, validation and persistence stay unchanged. The isolated Mac build passes with existing warnings. This is a Mac compile/label change, not a new Mac listening assertion. Failed iOS attempts are retained and do not become passes; final scoped results and remaining speech work are recorded in `ios-voiceover-service-evidence.json`. No installed Mac widget host or real workspace is changed.

### 20 October — genuine iOS task speech workflow accepted; native picker input remains open

The independently isolated iOS 27 Simulator task case passes through capture, Save, editing, completion, persistent Undo, restored-task speech and exact whole-cache relaunch. Original fixture task records and existing tables remain exact. The actual system announcement-finished callback reports successful Completed “VoiceOver action proof revised” output while foreground with VoiceOver running. This is genuine system evidence; the observer only exists in the copied debug test app and cannot post announcements or invoke cancellation. Shipping Mac/iOS source and data guards are unchanged in this follow-up.

The v7 bundle overall remains 1 passing task case plus 1 failing recovery case. Native filter warning, Restore control and actual picker are genuinely read, but the picker remains hittable with its host blocked after automated Cancel/keyboard attempts; no UIKit cancellation callback reaches the app. Do not call this an app guard defect or accept the missing Cancel/return. An explicit human-readiness-only test is prepared/compiled, not executed. Preserve prior driver failures and runtime/compiler warning scope; optional verbose simulator sysdiagnose collection was stopped after the known cursor-driver failure, without hiding its ordinary failure report. See `ios-spoken-workflows-evidence.json` and the current P0 tracker. The Mac test main app remains closed; no installed widget replacement or new release is made.

Human iOS picker follow-up: Human Cancel now reaches the actual accepted UIKit callback with VoiceOver on; the picker dismisses and Restore becomes hittable. Actual returned speech is Settings Back button, outside the recovery-specific test expectation. The test therefore fails and teardown deliberately closes the app and disables VoiceOver. No crash is established. No file was selected; post-test inspection finds both original fixture tasks open, no pending writes, and the cache modification time predates picker readiness. Whole-cache equality and relaunch assertions were not reached in this case; retain that limitation. Dedicated Simulator and temporary Device Hub are closed; keyboard capture and Xcode Settings are restored. No new shipping Mac change or acceptance claim.

### 20 October — iOS Restore focus repair with native cancellation regression

iOS now uses its own SwiftUI VoiceOver focus binding to return to Restore from file after native Cancel dismissal, subject to current workspace/presentation guards. The app and widget/UI-test build succeeds; ordinary native Cancel/retry and exact whole-cache relaunch pass 1/0/0. This regression has VoiceOver off and does not accept the current-build spoken return. Preserve the earlier human Settings Back button result and failure. Mac already returns to Restore from file in the accepted live human/AX check, so its platform source is unchanged. The dedicated Simulator is shut down, its test app is closed and no Mac test app is opened. See `ios-restore-focus-evidence.json`.

### 20 October — actual iOS Cancel ordering defect repaired

Human testing reproduced Settings Back button on the first focus repair, while proving whole-cache equality after actual Cancel with VoiceOver on. Native read-only lifecycle tracing then showed sheet dismissal preceding the Cancel callback in both attempts, so the first implementation never emitted a focus request. Current iOS source waits for both events in either order and consumes the request once, retaining workspace and presentation guards. The strengthened native Cancel/retry/relaunch case passes 1/0/0 with no structured runtime warnings: two accepted native callbacks, two focus events and two Restore-binding applications, plus full cache equality after each Cancel and ordinary relaunch. VoiceOver is off in that regression; a current-build spoken return is still unverified. Mac native behavior already has human/AX acceptance, so only its evidence/plan change here. The dedicated iOS Simulator is shut down; Device Hub window cleanup is limited by the locked Mac. See `ios-restore-focus-order-evidence.json`.

Cleanup follow-up: the Mac became available; Device Hub’s original iPad selection and keyboard-capture Off state are restored, and its app menu Quit is verified by a fresh isRunning false inventory. The earlier locked-window cleanup limitation is resolved. No new app/Simulator launch or acceptance claim.

### 20 October — named iOS spoken recovery gate accepted

Current-source iOS spoken recovery is accepted in its named representative scope. The human activates real native picker Cancel with VoiceOver on and reports Restore from file; the actual Xcode VoiceOver service returns Restore from file Button. The real UIKit callback is accepted, the picker stops accepting input and the Restore control is usable. The entire saved cache equals its pre-picker baseline after Cancel and again after ordinary terminate/relaunch. Final case passes 1/0/0 with no structured runtime warnings. VoiceOver is restored off, the test app and dedicated Simulator stop, and Device Hub closes with its original selection restored. Prior failed inputs/first focus repair and compiler/console warnings remain retained; no every-device/gesture or universal clean-runtime claim. The corrected iOS source is unchanged from fa83873; this is real current-build human/system verification, not a new Mac source change. Both independently owned apps now have named representative spoken recovery acceptance. See `ios-spoken-recovery-evidence.json` and the updated P0 tracker.

### 20 October — physical iOS widget installed; locked title hidden

20 October physical widget result: after the first free-profile-limit installation failure, the user requested a retry and the same signed isolated app installed successfully. The actual iPhone 16 Pro / iOS 27.0.1 rectangular Today Lock Screen widget showed Privacy check sample while authenticated. With Lock Screen Widgets changed from its original On to Off and the padlock closed, the user confirmed the sample was hidden. Further private-presentation/tap/authentication checks were deferred by the user; no route or full privacy acceptance is claimed. The entire diagnostic saved JSON is unchanged before/after (two tasks, zero pending writes). The isolated host is terminated; its app/widget remain installed. Restoring the original On setting was requested but is not confirmed. Earlier Simulator privacy settings were unusable, so previews cannot close this remaining native check. Production APNs/release inputs remain unchanged. See `physical-widget-privacy-preparation-evidence.json`.

### 20 October — Today accessory background declaration

The user’s actual iPhone gallery screenshot exposes a missing background declaration in the accessory branches. Both independently owned widget sources now declare a transparent widget container for normal and private accessory layouts. The macOS typecheck passes; these branches are iOS-only, with no Mac runtime change. Post-fix gallery and locked-route acceptance remain separate. See `accessory-widget-background-evidence.json`.

Corrected physical iOS build, strict signatures, configuration metadata and installation pass. Both synthetic tasks remain open; later reschedule history prevents an exact earlier-cache comparison. Host remains stopped; no post-install gallery observation is claimed.

### 20 October — actual Simulator gallery acceptance

20 October actual gallery verification: the corrected real WidgetKit extension now renders circular and rectangular Today previews in the actual iOS 27 Simulator Lock Screen gallery. Final native test passes 1/0/0 with no structured runtime warnings; the retained screenshot is visually inspected: readable 4 due count and two-line task title/subtitle, no background API warning. Entire synthetic workspace equals its baseline. Two earlier harness failures remain retained; Apple accessibility/compiler/console warnings remain documented. A fresh --gallery-testing preparation reproduces all 64 staged files byte-for-byte. This closes the reported gallery warning in its representative Simulator scope; physical system privacy/authentication and deferred release/delivery/rollout remain open. See `accessory-widget-background-evidence.json`.

### 20 October — locked warning diagnosis remains open

20 October locked-state warning follow-up: user resumed physical testing and reports normal 1 due while unlocked, but a warning while locked with only Plea… readable. Its full message is unconfirmed. A current-source real WidgetKit gallery with explicit diagnostic privacy injection renders the circular lock icon and rectangular Tasks are private correctly (1/0/0; no structured runtime warnings; screenshot visually inspected). Entire synthetic cache stays exact. This does not reproduce the phone failure or accept genuine locked privacy. No speculative shipping patch or phone app replacement is made. A fresh wider rectangular phone widget is requested to identify the message and replace a possibly cached older instance. See `locked-widget-warning-followup-evidence.json`.

### 20 October — stable Today background across privacy changes

20 October physical privacy repair: the user confirms the locked rectangular widget warning begins Please adopt… even after replacing the old instance. Both owned Today implementations now register a single container background outside privacy-dependent content. Normal Today rendering remains byte-identical in six three-size light/dark state composites; Mac typecheck and iOS Simulator/physical builds pass. Explicit private-gallery before/after captures both render correctly, so these are regression checks rather than a claimed Simulator reproduction. After normal isolated build 20 installs, the real iPhone check reports Private/blank; no access before unlocking. That accepts warning-free private presentation and OS-protected tapping in this named case, without claiming a delivered URL callback. Original-On restoration and normal authenticated return are awaiting the final human observation. Whole physical diagnostic JSON equals its immediate pre-install baseline; regular Taskfold and release inputs are untouched. See `locked-widget-warning-followup-evidence.json`.

### 20 October — genuine physical privacy gate closed

20 October physical system privacy accepted: after the stable-root background repair, the real iPhone 16 Pro / iOS 27.0.1 rectangular Today widget is private/blank with no background API warning under the actual locked setting, and its tap exposes no content before authentication. The user then restores Lock Screen Widgets to its original On setting and confirms Normal count/task returned with the padlock open. The entire saved diagnostic JSON equals its immediate pre-install baseline after installation and again after the human lock/tap/unlock cycle (two tasks, pending zero). The exact isolated host is terminated and its absence reverified; the test app/widget remain installed. This closes the named representative system-privacy gate, without claiming every family/device combination or an app-received private URL callback. Explicit Simulator privacy remains regression evidence, not a substitute for this human system check. Only deferred signing/provider/distribution and old-active-writer rollout remain. See `locked-widget-warning-followup-evidence.json`.

### 20 October — project workflows scope

Release/delivery/older-client rollout are explicitly tabled by the user. Implement reversible project archiving, cycle-safe subprojects, reusable templates and reviewed multi-line capture in both apps, including persistence, backups and native usability. This phase is not yet accepted.

## 20 October — project workflow expansion

The independently owned Mac app now implements project hierarchy and archive/restore, private reusable project/section/task templates, and reviewed multi-line capture. Native Edit menu Undo/Redo covers batches and workflow creation. Archive filtering includes daily queries, task reminders, widget content and new Focus choices; preserved work remains accessible from the archive. See [contracts and usage](PROJECT_WORKFLOWS.md) and [verification evidence](project-workflows-evidence.json).

The user has explicitly deferred remote reminder delivery, old-client safeguards and distribution verification. They are not active blockers for this feature expansion and have not been relabeled as accepted release work.

- 2026-10-20: Workflow cloud transport acceptance now covers Mac creation → iOS reuse/batch → Mac receipt with actual owned cores and the real backend. All three phases passed; synthetic account removed. Evidence: `project-workflows-cloud-evidence.json`. This adds transport evidence to the representative native workflow checks, without asserting a new native realtime handoff.

- 2026-10-20: Native iPhone cloud workflow follow-up passes with Mac-owned source creation and return verification, saved session and second relaunch. Four projects/four tasks/one template, zero native pending writes; synthetic data removed. See `project-workflows-native-cloud-evidence.json` for the native/core boundary.

## 20 October — P1 implementation begins

The user requested ranked P1 implementation. See `P1_PLAN.md`. The first item is nested subtask editing/organization, with a local draft, explicit Save/Cancel, whole-branch moves and identity-aware collection rebase. Implementation is present; final native acceptance is in progress. The three release gates remain deferred.

20 October P1 organizer acceptance: nested names/completion, add-child, branch moves, confirmed deletion, local Cancel, native Cmd-S/Undo/Redo and normal Quit/relaunch pass with isolated data. Progress badges count all levels. Both owned cores pass real-service move/reorder conflict/review/retry checks; the deployed structural review guard prevents a reproduced silent reorder loss. Owned Mac app/widgets Debug build passes independently. `P1_PLAN.md` keeps full child-detail parity and the remaining P1s open; evidence and retained limits are in `p1-subtasks-evidence.json`.


20 October P1 child-details continuation: organizer actions explicitly save before opening the native inspector. Child project context is inherited, unsupported independent repeats/reminders are hidden, and notes/planning edits preserve the parent and other child fields. Native testing reproduced and fixed the old two-level reference limit; third-level edits now save and survive a normal Quit/relaunch with exact saved-snapshot equality. No new database migration or release-gate claim. Final phone/tablet acceptance is tracked in `P1_PLAN.md` and the child-detail evidence.

20 October P1 child-details acceptance complete for the embedded checklist contract: both core suites and representative native iPhone/iPad/Mac flows pass. Mac supports the full readable child-reference depth instead of the previous two-level cutoff, with bounded visual indentation. `p1-child-details-evidence.json` records exact checks and limits. `P1_PLAN.md` marks rank 1 delivered and template management next. Release gates remain deferred.


20 October P1 template management: definition editing, reviewed source replacement, local-draft comparison, protected sync/delete and explicit recovery are implemented. Both cores and both real-service two-client tests pass. Signed isolated Mac build succeeds; native walkthrough is pending while the Mac is locked. `P1_PLAN.md` and `p1-template-management-evidence.json` preserve that acceptance boundary. The three deferred release gates remain open.


20 October P1 widget ordering: My list now publishes saved project-section, label and filter-group order, with priority bands, explicit sort overrides, unique first membership and compact private captions. Both owned core suites pass (737 iOS / 761 Mac reported, zero failures); the independent Mac app/widget target builds. Native acceptance is in progress, and Mac UI remains pending manual unlock. See `p1-widget-ordering-evidence.json`.

21 October widget acceptance continuation: installed iPhone/iPad medium My list cases now pass with readable group captions and correct saved order before/after completion and host relaunch. Exact fixture caches and real Simulator team/App Group identity are verified. iPad gallery automation was fixed to pan from the accessible preview and stop if its page number does not advance. Independent Mac build/core checks pass; desktop interaction is still pending unlock, so no new Mac runtime acceptance is claimed.


21 October P1 Insights and goals: the sidebar opens personal daily/weekly progress and scoped recorded-history charts. Draft goal editing supports rest days, saved zone/week start, validation, explicit stale-choice review and guarded account-owned sync. Backup transfer uses the same guarded contract. Both independently compiled cores and both live two-client tests pass; the final Mac core suite reports 791 cases, 30 environment skips and zero failures. The current-source isolated Mac app builds and signs. Interactive Mac acceptance remains pending manual unlock; no VoiceOver or release acceptance is inferred. See `P1_PLAN.md` and `p1-insights-goals-evidence.json`.

21 October Insights native acceptance: two phone and two tablet cases pass with zero runtime warnings, covering Save/Cancel, persistence, scope/windows, completion/Undo and largest-text validation/day lists. Mac independently builds and signs; its interactive acceptance remains pending unlock. Only synthetic fixture data was used. Superseded failed artifacts were pruned and isolated Simulator apps closed/removed. Detailed results are in `p1-insights-goals-evidence.json`.


21 October advanced recurrence: native monthly date selection and a source-zone upcoming-occurrence preview are implemented. Each app owns its calendar engine, local reminder projection, tests and matching SQL migration. Both compiled cores and real-service two-session continuity checks pass; private server date/signature checks and existing reminder regressions pass without activating dispatch. Phone/tablet native acceptance is in progress, and Mac interaction is still unavailable because the desktop is locked. See `P1_PLAN.md`; sub-day/holiday repeat policies and the three deferred release gates remain separate.

21 October monthly-date acceptance: both full core suites, both real-service two-session checks, four native phone/tablet functional cases and two final render cases pass. Visual review corrected selected-date wrapping/contrast and the iPad capture helper's sheet targeting. The current Mac app builds/signs independently and remains closed; native Mac acceptance is pending unlock. Exact evidence and deferred limits are in `p1-monthly-dates-evidence.json`. Four obsolete iOS test-build caches and superseded result bundles were pruned.


### P1 direct calendar foundation — 21 October 2026

Rank 6 is in progress. The owned Google/Outlook read layer and workspace-bound staged connection state pass 25 focused checks and the full Mac core suite (831 reported, 31 environment skips, no failures). The isolated app/widget build succeeds. Existing calendar UI is unchanged; the native OAuth/Keychain bridge, planner integration, provider settings and real-account/native acceptance are still pending. See `P1_PLAN.md` and `p1-direct-calendar-foundation-evidence.json`. No distribution or deferred P0 gate is closed.


### P1 direct calendar integration — 21 October 2026

The Mac app now owns the AppAuth/system-browser bridge, private device-only credential vault, provider/calendar settings and planner/capacity combination. Device permission remains separate from direct account consent, and incomplete sources cannot claim complete free time. The exact SDK pin and its privacy/license resources are included. Core and isolated builds are checked independently; native Mac interaction, actual Keychain access and provider consent remain pending while the Mac is locked and registrations are unconfigured. The mirrored 21-check offline SDK proof was run in the iPhone Simulator, not on Mac. See `CALENDAR_CONNECTIONS_SETUP.md` and the current P1 evidence.


Calendar integration checkpoint: both owned cores pass (Mac 844 reported, 31 skips, zero failures; 44 focused calendar cases), and the isolated Mac app/widget build succeeds. Phone/tablet settings acceptance passes in five native cases with no runtime warnings, plus 21 offline SDK checks and three synthetic OS Keychain operations on each Simulator. These are iOS runtime results. Mac native/provider acceptance remains pending unlock and configured registrations. Screenshot review exposed overlapping calendar/task labels in the graphical timeline; fix and verify that next. This checkpoint is not complete rank 6 acceptance.


21 October calendar timeline follow-up: timed tasks and read-only calendar events now share collision lanes, with readable minimum widths, a pinned clock and horizontal scrolling for dense clusters. All-day calendars use the All day section; normal-size list choice and workspace-bound event details are available. Both owned suites pass seven focused timeline checks and their full suites (827 iOS / 851 Mac reported, zero failures). Three phone and two tablet geometry/functional cases pass, including the existing task drag/resize/Undo regression; two final normal/largest-text presentation cases pass on each device, with zero runtime warnings. Screenshots were reviewed. The independently signed Mac app/widget build succeeds, but the Mac is still locked and no native Mac/provider acceptance is claimed. See `p1-calendar-timeline-evidence.json`; provider registrations/consent and the three deferred release gates remain open.


21 October project activity continuation: Project pulse now shows stable-ledger attribution, an own-changes filter, request-bound member refresh and task links resolved against the current accessible task/project context. Missing/inaccessible tasks cannot reuse a historical title or route. Both full core suites pass (856 Mac reported, 31 environment skips, zero failures; five focused current-context checks each). Four local-fixture phone/tablet normal/largest-text cases pass with no runtime warnings; Mac builds/signs independently and strict signature verification passes, with no new source warning. Native Mac interaction remains pending unlock. Shared comment authoring and the Mentions inbox are next; no new server policy or message delivery is introduced. See `p1-project-activity-evidence.json`.


21 October shared-comment server contract: the independently owned migration is deployed; rollback-only actual-role tests pass before/after deployment for authenticated authorship, explicit recipient membership, private moves, departure/rejoin, archive, moderation, deletion/generation protection, stale edits and idempotent comment/read-unread retries. No real rows are modified and push is not enabled. Legacy comment/attachment JSON is untouched. Public wrappers are invoker and private writers are scoped to auth/current access. Advisor deltas and the deliberately incomplete native/HTTP acceptance are recorded in `p1-shared-comment-server-evidence.json`. Native models, authoring, Mentions UI, durable queue/conflict behavior and backup preservation follow.


21 October shared-comment native contract: the Mac app independently owns validated lossless comment/mention records, versioned intent envelopes, explicit RPC arguments and revision/identity-bound replies. Backend guards reject stale accounts before refresh and cancel held responses across session changes. Both owned core suites pass, including 15 focused contract cases (Mac 871 reported / 31 environment skips / zero failures). The isolated app/widget target builds and strict signature verification passes with no new source warning. This is transport/model acceptance, not native authoring/inbox/outbox/backup acceptance. See `p1-shared-comment-native-contract-evidence.json`; end-user workflow integration and real HTTP/two-client checks follow.


### P1 shared conversations and Mentions — 21 October 2026

The Mac app owns the conversation editor, explicit member picker, revision/draft review, owner moderation, paged Mentions inbox, recipient counts and read/unread state. A separate account-bound queue persists before send, preserves exact retries and keeps blocked text for review. Original task generation/project and current workspace bind every route and response. Portable restores archive text without replaying authenticated writes or recipients. The summary migration and actual-role fixture are independently owned; Realtime changes enable in-app refresh only. Both cores and genuine HTTP/two-account/three-session proofs pass; all disposable data and credentials were removed. The isolated Mac app/widget builds and signs. Interactive Mac acceptance remains pending unlock; iOS screen evidence must not be claimed as Mac runtime acceptance. See `P1_PLAN.md` and `p1-conversation-summary-server-evidence.json`. The three deferred release gates stay deferred.

Conversation checkpoint: both owned cores pass (Mac 883 reported / 32 environment skips / zero failures; 26 focused conversation cases). Genuine HTTP passes independently from both clients. All four native UI cases pass on each iPhone/iPad Simulator with no Xcode-recorded runtime warnings; saved task/comment/outbox state and representative normal/largest-text screenshots were checked. These eight iOS cases do not close Mac runtime acceptance. The independent Mac build and strict signature verification pass; the desktop is still locked. See `p1-native-conversations-evidence.json`.


Conversation polish follow-up: Cancel now compares text and recipient selection with the loaded draft, avoiding a warning when nothing changed while preserving confirmation for edits. Offline read/removal rows name the intended action. The owned Mac source builds and verifies with strict codesign; native Mac interaction is still unavailable because the desktop is locked. Four additional Simulator UI checks pass (two phone/two tablet) with no recorded runtime warnings, exact draft preservation and acknowledged pending-action cleanup. These are iOS runtime results. `P1_PLAN.md` now separates chronological notes from current remaining acceptance, and calendar guidance follows the user’s Simulator preference while retaining genuine provider sign-in/credential requirements. See `p1-conversation-polish-evidence.json`.


21 October user decision: Google/Microsoft native calendar registrations and genuine-provider acceptance are deferred until the user configures them. Keep providers unavailable without configuration and retain all unverified consent/credential cases for later. These are no longer current work blockers to pursue; native Mac P1 walkthroughs remain blocked by the locked desktop. The three previously deferred release items are unchanged.


21 October P1 Mac continuation: unlocked desktop allowed the saved-template walkthrough to resume. Create/edit/confirmed discard/normal Quit and relaunch preserve template/source separation. Fixed a native comparison render collision by scoping each preview’s row identities, independently in both apps. Local-only DEBUG workflow fixtures skip cloud-session Keychain reads; normal/authenticated launches remain on their existing path. The isolated host reports a widget-container permission error, so no desktop widget acceptance is claimed. Full template reuse/source replacement and the remaining P1 Mac walkthroughs are still pending; see `p1-template-preview-followup-evidence.json`.


21 October native acceptance continuation: representative Mac templates and Insights/goals walkthroughs pass. Templates create/edit/reuse/review-discard/later-edit isolation/relaunch and Insights scope/window/validation/Cancel/rest-day/reopen/Undo/relaunch have exact snapshot evidence in `p1-mac-templates-insights-evidence.json`. No main test app remains running. Remaining Mac P1 work is widgets, monthly date sets, calendar screens/timeline, activity and conversations/Mentions; genuine calendar providers and the three release gates remain deferred.


21 October native continuation: monthly date sets pass capture/edit/preview/Undo/Redo/completion/count/Undo/relaunch. Synthetic calendar settings and timeline pass privacy, explicit selection, independent disconnect, incomplete-data and recovery checks; no genuine provider acceptance is claimed. Exact observations/snapshots: `p1-mac-recurrence-calendar-evidence.json`. The main test app is closed. Remaining current Mac acceptance: installed widget ordering and project activity/conversations/Mentions. All explicit provider/release deferrals remain unchanged.


21 October conversations/activity continuation: native Mac drafts, explicit mentions,offline/relaunch/read intent/retry acknowledgement,edit/remove and conflict review pass with exact saved snapshots. Project pulse attribution/filter/current completed-task route pass. Fixed Mentions/activity task opening to use matching project/Inbox/Completed context; build/signature and open-project/completed runtime checks pass. See `p1-mac-conversations-activity-evidence.json`. Main app closed. Remaining current P1 acceptance: installed Mac widget ordering; explicit provider/release deferrals unchanged.


21 October widget-order readiness: fixed a fresh-generation missing-AppAuthCore failure in the Mac generator; exact package/linkage/license/calendar settings retained. Three isolation checks,fresh app/widget build and strict signature pass. Current correctly entitled host and extension publish native-matching Design review/Ready to ship ordering. Installed widget view/action remains pending user check because both system-host inspection attempts time out. One required isolated widget host remains running; no other main test sessions. See `p1-mac-widget-order-readiness.json`.


21 October installed widget observation: user confirms the large My list Widget Studio order and group captions match. The reported checkbox click has not changed saved completion,projection or action queue. Inspected logs show configuration resolution without an observed completion intent; no code defect is inferred yet. Installed order accepted; checkbox persistence pending one out-of-edit-mode retry. Current host left intact. Evidence: `p1-mac-widget-order-readiness.json`.


21 October final current P1 acceptance: installed large My list grouped/manual order user-confirmed; subsequent actual checkbox completion persists with exactly one receipt,empty queue,unchanged saved order and only the approval task completed. Normal Quit/relaunch and native remaining project order pass. No main Taskfold app remains running. Current agreed P1 batch complete; evidence/audit in `p1-mac-widget-order-accepted-evidence.json` and `p1-completion-audit.json`. Genuine calendar registrations/provider acceptance,remote reminders,older-client rollout and distribution remain explicitly deferred and unverified.


### Project-tree saved filters, 21 October 2026

Added a native Project and subprojects condition and matching expression grammar, preserving exact-project filters. Preview, cache, separate query groups and widget membership share accessible parent metadata and fail closed for invalid branches. Independent Mac core and isolated signed app verification are recorded in `p2-project-tree-filters-evidence.json`. Native Mac layout/VoiceOver and real cloud acceptance remain open; phone/tablet acceptance is tracked separately. Other rank-3 scopes remain in `P2_PLAN.md`.


### Parent/child query and edit foundation, 21 October 2026

Added an independently owned bounded hierarchy index and child edit planner. Stable filtered identities resolve to real root subtree patches; stale workspace/root/path/content checks, concurrent-field preservation, coalesced sibling changes, Undo/redo and offline persistence pass the scoped core tests. The new foundation is not yet connected to native filtering or command controllers. Mac flat-result navigation/actions, iOS editing parity, mixed-selection handling, widget actions and native acceptance remain required before exposing the feature. See `p2-task-hierarchy-foundation-evidence.json` and `P2_PLAN.md`; no full rank-3 completion claim.


### Native child action bridge, 21 October 2026

Both owned cores now translate contextual native drafts into guarded child edits, and both Stores reject direct synthetic task-row writes. The Mac Store has the selection/commit adapter for upcoming flat-result controls; existing Mac nested inspectors retain their current path. The iOS action bridge has its own native acceptance record in `p2-child-editor-bridge-evidence.json`; that proof does not count as Mac controller acceptance. Public parent/child grammar, Mac flat-list navigation/actions, mixed selections and widget/output integration remain open before rank 3 can close.


### 21 October — saved hierarchy filters and mixed actions

Added Main tasks, Subtasks and Tasks with subtasks to the saved-filter builder/expression grammar. Flat Mac results include parent context; completion, dates, deadlines, priority, branch duplication/deletion and mixed selections use guarded real-root transactions and existing Undo. Child project moves stay unavailable. Both owned full core suites pass (954 iOS / 978 Mac, 12 / 32 optional skips, zero failures); the isolated Mac builds and both products pass strict signature verification. Public saved-filter creation, child details, completion/Undo and ordinary relaunch pass on phone and tablet, with normal-light captures inspected and actual saved root/child data checked. These are iOS native acceptance results, not Mac interaction proof. Child widget routing/completion, output context and broader native/layout/accessibility/account acceptance remain gates. See `p2-hierarchy-query-actions-evidence.json`; rank 3 and all user-deferred release/provider work remain open.


### 21 October — hierarchy widget and filtered output integration

Saved child filters now publish a separate display catalog, parent context, exact case-sensitive path actions and account/root-incarnation-bound links. Main Today/Inbox counts retain the existing root catalog. Own-node completion preserves independent parent checkboxes, real-root patches, receipts and Undo; missing catalogs refuse false All clear. Mac links expand ancestors and select the root’s containing list even when only a child is completed. Hierarchy Print/PDF includes matched rows and ancestry without expanding unmatched descendants, with appropriate Print options.

Current core suites pass (963 iOS / 987 Mac, 12 / 32 optional skips, zero failures). Current isolated app builds and strict signatures pass; the independently owned Mac widget target builds for arm64/x86_64. Compiled app/widget intent metadata agrees. Phone/tablet saved-filter, cold child route/edit/reopen and wrong-account checks pass; tablet ordinary root routes also pass. A4/Letter output and light/dark/private SwiftUI widget previews are visually inspected. Installed WidgetKit/Mac-native interaction acceptance, native hierarchy Print/Save, broader layouts/accessibility/account cases, the rest of rank 3 and all user deferrals remain open. See `p2-hierarchy-widget-output-evidence.json`.


### 21 October — shared/personal saved filters

Added Shared projects (`shared`) and Personal work (`personal`) to the native condition builder and expression grammar, with accepted-membership semantics. Pending/declined invitations and ancestor sharing do not count. Personal includes the current Inbox and owned unshared projects; task authorship does not override project state. Missing/unsupported catalogs request sync instead of becoming personal under negation. Membership-derived references invalidate cached results independently of task edits and drive previews/groups, nested scopes and widgets; raw memberships/emails are not published.

Both current owned core suites pass (971 iOS / 995 Mac, 12 / 32 optional skips, zero failures), including eight new cases and 5,000-project classification. Native expression/builder/result/relaunch flows pass on phone and tablet with actual saved/widget-file proof; tablet continued the same live run through six XCTest animation waits. The Mac app builds and both current products pass strict signature checks. Live schema/RLS/enum/FK and saved-query-envelope inspection was read-only; no backend or permission changes. Mac interaction remains unaccepted because the desktop was locked. Genuine paired membership/revocation/offline/accessibility/installed-widget checks remain open. Assigned-by requires actual recorded provenance; the existing activity ledger cannot supply it. See `p2-sharing-filter-evidence.json`; all user deferrals and remaining backlog remain active.


## Recorded assignment-actor foundation (rank 3, unfinished)

The backend now records actual authenticated assignment transitions in a separate read-only `task_assignment_provenance` table. Reads follow current task access and root incarnation, including accepted membership and revocation; clients cannot write the table or call its private trigger. New assignment events are distinguished from unrelated edits, child reparenting and same-recipient retries. Stable child removal/Undo preserves the original assignment; explicit unassignment and reassignment creates a new event. Unsupported historical trees never acquire invented identities. No existing task data or historical actors were backfilled.

Legacy/missing history, system actions without an actor, removed actor accounts and recognized recurring successors remain explicitly unknown. Recurrence markers supplied by a client do not attest another person's authorship. A restored root is a new incarnation. Imports/new copies record only their new Taskfold assignment action, never an inferred external historical actor. The client resolver checks current recipient, root generation and exact nested path; portable exports exclude this metadata and generic client write paths refuse it. The catalog is not yet synchronized or used by saved filters.

The actual migration and rolled-back disposable fixture pass both independently owned local PostgreSQL checks and the real backend's current policies/triggers. The hosted check leaves zero fixture accounts/tasks. Full core suites report 978 iOS / 1,002 Mac cases, with 12 / 32 existing integration skips and zero failures. Both isolated native apps build and pass strict deep signature checks; compilation is not native acceptance. The signed-in schema-discovery advisory for the intentionally readable table is documented with the actual RLS tests; existing unrelated advisories remain unchanged. See `p2-assignment-provenance-evidence.json`.

Assigned-by remains unfinished: connect capability-aware account-safe synchronization and local/offline recording; verify trusted recurring inheritance; add strict predicates/unknown Boolean behavior, directory/cache/preview/grouping integration and native controls/widget membership; then complete genuine HTTP and native/accessibility acceptance. No full rank or deferred rollout/distribution/provider gate is closed by this foundation.


## Assigned-by saved filters and synchronization (rank 3, acceptance in progress)

Both apps now connect the recorded assignment actor to **Assigned by** controls and strict `assigned-by:me`, `assigned-by:others`, `assigned-by:unknown` or exact-person expressions. Preview, saved/grouped/independent queries, nested results and widget membership share the same current catalog. Unknown historical attribution stays distinct from unassigned work and unconfirmed data; negation does not turn unknown into another person. The query captures no actor or invented assignee defaults.

Optional account-incarnation-fenced reads distinguish unavailable from synchronized empty data without blocking core task sync. A fresh task read without corresponding history clears the old catalog. Optimistic transitions, including new assignments and A→B→A cycles, remain unconfirmed through queue replay/acknowledgement until fresh server evidence arrives. Explicit local-workspace recording preserves real actions, moves and Undo without fabricating legacy or recurring history; portable backups exclude the catalog. Immutable metadata participates in query cache identity, with timestamps parsed once for responsive large lists.

Independent core checks, genuine disposable owner/member/outsider HTTP checks and actual phone/tablet native builder/expression/save/relaunch acceptance pass. Actual saved JSON and published widget membership agree for Me/Others/Unknown, with no raw actor metadata exposed. Exact counts, artifacts, resource-signature repair and acceptance limits are recorded in `p2-assigned-by-filters-evidence.json`; the contract is in `ASSIGNED_BY_FILTERS.md`. This supersedes the initial unsynchronized/unexposed foundation restrictions above. Native Mac/layout/accessibility, exact-person picker and installed-widget/wider concurrent/offline acceptance remain open. Trusted recurring inheritance remains separate; copies stay explicitly unknown. The rest of rank 3, the overall backlog and all user deferrals remain unchanged.


### Row gesture follow-up — 21 October 2026

iPhone/iPad gesture preferences pass scoped phone/tablet native checks and visual review; the Mac implementation has since been added below, with live acceptance still open. Preserve SwiftUI List scrolling, selection, keyboard actions and mouse drag reordering; no private table-delegate replacement or advertised control without working gestures. See `ROW_GESTURES.md`. Existing task data contracts and user-deferred release/provider/push/old-client rollout acceptance remain unchanged.


### Owned Mac row gestures — implementation, live acceptance pending

The Mac now implements device-local trackpad action choices, deliberate reveal by default, guarded completion/scheduling/edit/delete and interruption-safe row targeting. It preserves the app-owned scroll-memory bridge and does not replace SwiftUI delegates. Scoped Core/AppKit/render verification and the cross-platform RTL fix are recorded in `p2-mac-row-gestures-evidence.json`. The Mac remains locked: physical input, full native settings/selection/Undo/drag interactions and VoiceOver are still gates. Existing release/provider/push/older-client deferrals remain unchanged.


### Reviewed voice drafts — 21 October 2026

The Mac independently owns device-only Speech/AVFoundation input, bounded correction/review and an explicit append-to-draft handoff to existing multiline capture. Permission requests require Start; unsupported on-device recognition has no server fallback. Workspace/request/original-text tokens prevent late retargeting, and the existing task preview/Add/Undo owns persistence. Core/controller checks and offscreen light/dark component previews are recorded in `p2-voice-drafts-evidence.json`; real microphone/TCC/audio/VoiceOver and full native interaction remain unverified while locked. Cloud AI and all explicit user release/provider/push/older-client deferrals remain unchanged.


## 21 October — elapsed reminder foundation

Rank 5 begins with independently owned elapsed scheduling: fixed-instant anchor, 5-minute through 7-day intervals, inclusive end/count caps, no catch-up burst, bounded seeking and exact receipt membership. The app and Core package compile the source; native editor/persistence/notification integration is still required before exposure. `ADVANCED_REMINDERS.md` defines the behavior and remaining travel/holiday/location/urgent order. Exact checks are in `p2-interval-reminder-foundation-evidence.json`. No real task, notification permission, installed widget host or release input is changed. Mac live acceptance remains unavailable while locked; broader Px and user deferrals stay open.


## 21 October — interval reminder integration

Interval reminders now have owned native editing, explicit count/end limits, upcoming instants, versioned saved settings, backup/queue preservation, duplicate handling, per-occurrence notifications and exact stale-response protection. Source/account/task-incarnation guards protect the presented draft. The actual Mac editor is rendered offscreen in light/dark using the tested owned Core; the render caught duplicate field labels, now corrected. Current build verification and remaining native editing/VoiceOver/OS-action gates are in `p2-interval-reminders-evidence.json`. A selected previous Mac Core reader proves opaque row preservation. No new server delivery, release claim or installed desktop-widget changes are included.


## 21 October — saved reminder zones and travel comparison

Added an owned native named-zone chooser and source/device clock comparison for the next five calendar reminders. Explicit zone changes keep picker civil date, authored clock and limits, with skipped dates refused; preview remains read-only. Core civil/date/offset/identity checks and actual editor/picker component rendering are recorded in `p2-reminder-time-zones-evidence.json`. The Mac is still locked in the current surface check; full native keyboard/VoiceOver acceptance remains open. No new persistent envelope, server delivery, provider access or release assertion is included.


## 21 October — opt-in Time Sensitive presentation

Added native reminder-level presentation and an independent default-off device/workspace allowance. Actual system support is read before queue construction; unavailable/disabled support keeps normal content. Pending/snoozed requests update without shifting dates, while a task presentation edit invalidates old actions. Version-4 local-only settings are preserved opaquely by the selected previous reader. Current Mac provisioning cannot sign this new capability; unsigned compilation and offscreen production-view checks are explicitly separate from genuine native capability/Focus/distribution acceptance. Exact evidence and broader open work are in `p2-reminder-presentation-evidence.json` and `REMINDER_PRESENTATION.md`.


## 21 October — reviewed holiday calendar reminders

Added owned bounded calendar-file parsing, reviewed source/year/region and explicit Skip/Move/weekend policies for independent calendar reminders. Scheduling keeps source clocks, original count/end limits and task planning separate; shifted collisions coalesce and exact receipt validation includes the policy. Both apps preserve unknown previous-reader settings and portable backup/queue data. The native review keeps source labels visible and uses ordinary navigation. Exact Core/native/render outcomes and remaining Mac/file-provider/VoiceOver/notification acceptance are in `p2-holiday-reminders-evidence.json`; the contract is in `HOLIDAY_REMINDERS.md`. No country provider, remote reminder, release signing or role policy is enabled.


Holiday reminders now offer automatic country/year calendars first, with explicit regional Public filtering, reviewed offline snapshots and optional all-day calendar-file import. Both production Core and native Mac editor compile independently. Offscreen component rendering is separate from native interaction; the locked Mac and deferred Time Sensitive signing still prevent that acceptance. Provider commercial sponsorship is a release dependency. See `HOLIDAY_REMINDERS.md` and `p2-holiday-reminders-evidence.json`; rank 5 and remaining Px work stay open.


Location reminder work now has an independently compiled device-private data/lifecycle foundation. The iOS system location-notification trigger is unavailable on macOS: the intended Mac UI must preserve and explain phone/tablet references without requesting Mac location permission. No app UI or OS trigger is enabled yet. See `LOCATION_REMINDERS.md` for the complete storage, shared-budget, save/Cancel, native response and acceptance requirements, and `p2-location-reminder-foundation-evidence.json` for current checks.


## 22 October — protected private place storage

The Mac now owns the protected, account-scoped place/journal file store independently of iOS, including bounded reads, atomic coordinated writes, backup exclusion, stable installation identity and stale-edit/journal protection. Native Mac location UI/permission requests remain absent because the system trigger is unavailable here. The iOS picker is tested only through its isolated debug entry; complete mobile reminder wiring, every-visit mode and private desktop-to-phone authoring remain open. See `p2-location-place-storage-evidence.json` for filesystem/build checks and their limits.


## 22 October — iOS native location adapter boundary

The iOS repository now owns its system location-trigger adapter and native format/unavailable-device checks. The Mac's independently owned shared model/store and opaque version-6 behavior are unchanged; this is a documentation-only Mac update, with no Mac location permission, iOS source dependency or release assertion. iPad keyboard place editing is verified, while direct Search taps and positive geofence registration/delivery remain open. Normal consent/task/action wiring, shared notification admission, every-visit mode and desktop-to-phone authoring remain unfinished. See `p2-location-system-adapter-evidence.json`.


### 22 October — shared notification admission

Both independently owned schedulers now coordinate an optional location engine with the existing time/Focus queue. Cleanup precedes additions; durable location intents reserve at most 20 slots; Focus and explicit snoozes have priority; all other native pending requests consume capacity. Account/installation changes fence late work, and a full native queue produces waiting feedback instead of false snooze success. Normal Store location bootstrap/consent/task/action wiring remains unfinished and the location editor stays hidden. Every-visit mode, private desktop-to-phone authoring and positive capable-device location delivery remain open. See `LOCATION_REMINDERS.md` and `p2-notification-admission-evidence.json`; this milestone does not complete rank 5 or Px.


### 22 October — private consent and normal workspace lifecycle

The iOS Store now loads the protected private archive, installs the shared location engine during ordinary scheduling refreshes and rechecks account, workspace session, task and saved-place bindings around submissions. Account changes invalidate old work immediately; leaving and returning to the same account cannot acknowledge an old in-flight addition. Concurrent refresh callers wait for the latest hydration/admission pass. Both independently owned private stores persist explicit account consent in a version-2 private archive; legacy version 1 and a fresh identity start with consent off. Consent stays outside shared tasks, widgets and portable backups. Normal iOS cleanup handles revoked/unreadable/reset private state and preserves unrelated notification requests.

The Store allowance API refuses unsupported or unapproved native delivery and never prompts automatically. Public consent controls and task location editing are still absent; version-6 task rows remain opaque. The isolated normal-Store checks and precise remaining scope are recorded in `p2-location-workspace-evidence.json` and `LOCATION_REMINDERS.md`. Every-visit mode, private desktop-to-phone authoring, native response actions and positive capable-device location delivery remain open. Full rank 5 and Px remain incomplete.

The Mac change owns private-consent compatibility and workspace fencing independently. Native bootstrap and system location cleanup are iOS-specific; no Mac location service or permission request is introduced.


### 22 October — reviewed location task drafts

Added the iOS reviewed Arrive/Leave/place/area editor and parent task Save/Cancel bridge behind the exact isolated DEBUG route. A memory-only review cannot arm an alert before a successful task save; ordinary builds still expose no location authoring. Normal iOS mutations now retire removed/undone location intents, including preparations that have not reached the OS. Private journal version 2 adds monotonic receipt revocations so restoring an old row cannot authorize a deliberately retired alert. Both repos own their compatible models and tests; Mac adds lossless phone/tablet reminder presentation without location permission.

This milestone is not full location-reminder or Px completion. Native actions/categories, durable recovery between a task commit and private retirement, capable-device delivery/permission acceptance, every-visit mode, private desktop-to-phone authoring and broader accessibility remain open. `LOCATION_REMINDERS.md` and `p2-location-task-drafts-evidence.json` separate the implemented editor from those remaining gates. User-deferred remote/release/older-client/provider work stays deferred.


### 22 October — durable location cancellation handoff

The iOS task-cache writer now atomically saves pending location cancellations with the task change, including sync/recovery writes. Outstanding cancellations survive snapshot replacement and Undo; acknowledgement is saved only after private-journal retirement. Relaunch replays either side of that handoff idempotently. Missing private authority and unreadable authority are treated separately; unreadable files retain their jobs and suppress location admission. Both repos own compatible, validated optional outbox models and independent tests; Mac adds no native location service. No names/geometry enter the outbox, widget projection or portable workspace export.

Exact verification is recorded in `p2-location-retirement-outbox-evidence.json`. This closes the volatile task-to-private-retirement gap for process termination; it does not claim power-loss durability, native location notification actions, repeated visits, private desktop-to-phone authoring or capable-device delivery. The reviewed editor stays experimental and rank 5/Px remain incomplete. User-deferred remote/release/older-client/provider work stays deferred.


### 22 October — location notification actions and durable explicit snoozes

Connected iOS Open/Complete/Tomorrow/Snooze routing, strict native boundary/followup decoding, fresh protected-state validation and atomic mutation receipts. A separately versioned local time-snooze namespace shares time/Focus/location capacity, preserves its target while waiting, reserves before OS submission and recovers without silently replaying consumed/ambiguous opportunities. Snoozing a snoozed alert creates a new explicit intent without rearming its boundary. The row shows the saved snooze date/time. Both repos own compatible ledger/queue models and tests; Mac gains no native location service.

Native integration exposed that calling Start local in an already-open readable local workspace reset its session and cleared native alerts. Both Stores now make that call idempotent; real workspace changes keep their cleanup. Evidence and precise limits are in `p2-location-notification-actions-evidence.json` and `LOCATION_REMINDERS.md`. Region-delivery/OS-origin boundary acceptance, repeated visits, private desktop-to-phone authoring, public setup/accessibility and safe action-history reclamation remain open. Normal authoring remains gated and rank 5/Px are incomplete; user deferrals remain unchanged.


### 22 October — explicit every-visit location reminders

The isolated iOS reviewed editor now offers Every visit until completed, defaulting to off. Version 7/reference 2/r10 and native v2 receipts distinguish it from unchanged one-shot rows. Both repos independently own journal-3 recovery epochs, repeated-trigger retention, per-delivery replay keys, compatible explicit time snoozes and cancellation/Undo fences. Mac describes the phone/tablet choice without gaining a location service.

Evidence is in `p2-location-repeat-evidence.json` and the current section of `LOCATION_REMINDERS.md`. Simulator drafts, response fixtures and genuine native time snoozes pass; these do not establish real region delivery or background/locked/cold callbacks. Normal authoring remains hidden. Public setup, private desktop-to-phone authoring, accessibility and history reclamation remain open. Rank 5/Px and other documented P2 gates remain incomplete; user deferrals are unchanged.


### 22 October — explicit ended location-action cleanup

Added a confirmed maintenance action in the experimental iOS editor to clear receipts whose exact private intent is permanently denied. Ordinary writes still preserve missing receipts, and active/actionable/unknown/other-account histories remain protected. Both repos independently own the policy and tests; Mac adds no location UI/service. A retired private tombstone continues rejecting old responses after cleanup and task Undo.

See `p2-location-action-cleanup-evidence.json` and `LOCATION_REMINDERS.md` for native save-failure/retry, cancellation/replay and UI evidence. This recovers capacity from known retired actions; unknown/previous-installation history, active-repeat rollover and full private identity-reset recovery remain gates. Public authoring, capable-device delivery, desktop-to-phone authoring and wider P2 acceptance remain incomplete. User-deferred remote delivery, general older-client rollout, distribution and genuine OAuth provider work stay deferred.


### 22 October — recoverable private location reset

Added a confirmed whole-device private reset to the experimental iOS Places flow. It writes a fresh consent-off private identity and durable reset receipt before clearing old action records; normal hydration finishes cleanup after a failed cache save or relaunch. A private writer lock and identity revalidation prevent stale reset proofs from deleting newer receipts. Tasks and unrelated time/Focus alerts are retained; old references require review. Both repos independently own the private archive-3 format and policy; Mac adds no location service or reset UI.

Exact native process-loss, selected previous-reader, Core and screenshot evidence is in `p2-location-reset-evidence.json` and `LOCATION_REMINDERS.md`. This closes the explicit reset/capacity-recovery implementation gap, not public authoring or genuine physical delivery/permission/account-switch acceptance. Wider location/P2 work and all user deferrals remain open.


### 22 October — normal place-reminder setup preview

Normal iOS Notifications and task Reminders now link to central Place reminders setup. It provides explicit separate consent, actual device-capability/status feedback, saved-place/reset/history management and refresh after system settings. Capable devices expose reviewed task authoring as a preview; raw restored rows still cannot prepare alerts. Unsupported devices retain time delivery and can revoke existing private consent. Revocation write refusal has explicit session-only feedback and an off-retry action. Exact test-only producers remain separately isolated. Mac adds read-only phone/tablet setup guidance.

See `p2-location-setup-evidence.json` and the current `LOCATION_REMINDERS.md` section for normal Simulator navigation/no-write/large-text, real private-file lock refusal/retry, editor regression and Mac build scope. Positive capable-device permission/delivery/callback acceptance, spoken accessibility, private desktop-to-phone authoring and wider P2 work remain open; this does not complete rank 5/Px or reopen user-deferred release/remote/provider work.


### 22 October — durable waiting snoozes

Ordinary explicit snoozes now save their exact fire instant before queue admission. Added bounded local recovery, durable submission reservations, monotonic cancellation/Undo protection and separately stored delivery epochs; Mac hydration/admission is coalesced to avoid treating an in-flight reservation as a failed restart. Current native/Core checks and precise limits live in `p2-time-snooze-recovery-evidence.json` and `REMINDER_SNOOZE.md`. Live Mac Notification Center/physical interaction remains unverified while the desktop is locked. No visual redesign, remote activation or release/provider work is implied.


### 22 October — checklist recovery review

Added a native grouped-form review to recover damaged/duplicated checklist references while preserving recognized content and ordering. Original data stays available and unknown formats are not guessed. Work runs off the UI actor; normal inspector save/Undo and workspace/source guards own persistence. Child lookup/replacement now refuse ambiguous references, and inline edits/addition cannot coerce legacy/unknown structures. See `CHECKLIST_RECOVERY.md` and `p2-checklist-recovery-evidence.json` for independently owned tests, offscreen production component layouts, build scope and still-open live Mac/accessibility acceptance. Wider Px and all user deferrals stay open.


### 22 October — private desktop-to-phone transport foundation

Added an account-private, bounded place-draft protocol and deployed its unexposed table/RPC/retention migration. Authenticated project collaborators cannot read each other's private drafts. Fixed expiry, immutable retry contents, one-device review claims, terminal geometry removal and task-incarnation/access checks are covered by independent client and local/hosted SQL checks. Normal app code makes no upload or import call, and existing device-private places stay local.

`PRIVATE_LOCATION_HANDOFF.md` and `p2-location-handoff-transport-evidence.json` distinguish this foundation from the still-required native sending/review UI, durable private nonce, atomic task import receipts, relaunch/Undo recovery and paired-device acceptance. Mac gains no native location service. This does not complete desktop authoring, rank 5 or Px; real location delivery and all user-deferred release/remote/older-client/provider work remain open.


### 22 October — durable receiving commands and interrupted-save recovery

Both repos now own protected review-ticket persistence and a monotonic local import ledger. The iOS Store reserves the nonce before Claim, revalidates the server before a reviewed Save, saves a stable private pin, and atomically writes the task mutation with its receipt under the private writer lock. Normal hydration can finish an interrupted private-intent preparation only for that exact saved task and consent epoch. Task completion/removal/Undo, private reset and off/on consent changes prevent rearming. Finish acknowledgement retries preserve the original nonce and never repeat task creation; unavailable acknowledgement does not hide other drafts.

This closes the deterministic reservation/task-receipt/preparation recovery implementation gap. It does not expose sending or receiving screens, establish real Auth/PostgREST paired-device behavior, or prove a native geofence alert. `PRIVATE_LOCATION_HANDOFF.md` and `p2-location-handoff-recovery-evidence.json` record exact tested scope, bounded storage and remaining gates. Rank 5/Px and all user deferrals remain open.


### 22 October — native private place-draft handoff

Connected Mac saved-task authoring/search/map/review/send/status/pending-discard and the iOS signed-in Place drafts inbox with map review, Not now/resume, explicit Save and confirmed discard. No bulk place upload or permission activation. The receiving UI uses durable reservation/task-receipt/consent-epoch recovery; Mac retry keeps one immutable proposal. Native Simulator tests cover postponing/relaunch, failed Save/retry, missing Finish acknowledgement/relaunch and largest-text dark iPad discard. An isolated Mac app passes seven actual Store/Backend command checks; live Mac interaction stays unverified while locked.

`PRIVATE_LOCATION_HANDOFF.md` and `p2-location-handoff-screens-evidence.json` distinguish those client/fixture checks and form layouts from genuine Auth/PostgREST paired transport, physical geofence delivery and spoken/live Mac acceptance. Both app/extension builds and full Core suites pass; old Mac calendar-grid type inference was factored without changing behavior. All user deferrals, history-maintenance gates and wider Px remain open.


### 22 October — bounded share intake and Apple Maps compatibility

Continuing the highest outstanding share-capture acceptance work uncovered an actual Apple Maps compatibility issue: its separate opaque preview previously rejected otherwise readable text and URL providers. Both apps now leave that exact ancillary preview unread, accept only its valid text/link companion, and explain the omission in review. Unknown attachments still refuse the whole selection. One 20-second provider budget spans every attachment; cancellation and late responses cannot revive a dismissed review. Neither mailbox version nor task schema changes.

`SHARE_CAPTURE.md` and `p2-share-provider-evidence.json` record the independent Core suites, real source-app checks and remaining native/account/accessibility gates. This increment does not close all of rank 2/Px or any user-deferred release, provider, older-client or remote-reminder work.


### 22 October — iPad share review and large-text acceptance

Actual iPad Apple Maps capture now passes from the source extension through editable review, save with Taskfold quit, host review, explicit Add and relaunch with one durable task/receipt. Normal light and largest accessibility text in dark appearance both pass; screenshots verify readable preview-omission text and reachable Save/destination/Add/Cancel. The same current test helper passes on iPhone. Both apps own nonvisual review-form identifiers so tests scroll the actual modal rather than the source app or background list. The Maps test now targets its exact place-card Share control and waits for onboarding, avoiding the unrelated Share My Location action.

`p2-tablet-share-evidence.json` records current source fingerprints, actual native results, failed initial onboarding/selector iteration and cleanup. Core/task/mailbox contracts are unchanged; this does not close cloud/offline/account-switch, live Mac or spoken-accessibility acceptance, all of rank 2/Px, or any user-deferred release/provider work.


### 22 October — genuine cloud share isolation and offline return

Two fresh real Auth accounts now pass actual iPhone Safari share intake, an open review across A → B, and offline Add across A → B → A. A stale review is refused without creating a draft/task in either account. An offline Add commits one private task/receipt and one pending command; the server remains empty while B is active. Returning to A sends exactly one task and drains its queue, with no remaining draft after relaunch. Independent authenticated server reads and private caches agree. The outage is an exact Debug-bundle/disposable-account URLSession failure, not a claim of physical airplane-mode acceptance.

Actual screenshot review found save errors hidden behind the keyboard. Both apps now pin source-share errors below the header; native visibility/keyboard checks are recorded in `p2-share-cloud-evidence.json`. Mac native sharing/VoiceOver and wider device/network variants remain open. The live endpoint inventory also uncovered a separate P0 account-removal gap; `ACCOUNT_REMOVAL.md` is now the next priority. No user-deferred release/provider/remote work is reopened.


### 22 October — account-removal service candidate and hosted rollback proof

Both repositories now independently own the authenticated, bounded, retryable server deletion candidate and matching migration/SQL fixtures. Twelve mocked-HTTP cases per repository and both local SQL suites pass; the exact candidate also passes against actual hosted guards in a fully rolled-back synthetic transaction. Another account's tasks/membership survive, shared comments retain anonymous attribution, and stale JWTs cannot upload/overwrite after removal starts. Both Core account suites pass 33 cases, including explicit completion acknowledgement and delayed account/session-switch rejection. `ACCOUNT_REMOVAL.md` and `p0-account-removal-service-evidence.json` distinguish these results from still-required deployment, genuine Auth/Storage/native deletion and current-device cleanup. No persistent hosted change or real account removal occurred; this P0 and the full Px objective remain open.


### 22 October — durable native account-removal recovery and scoped device cleanup

Both apps now save private retry authorization before deletion, retain confirmed progress for interrupted cleanup, bind confirmations to the opening workspace and erase only the confirmed account's device cache/queue, private places/receipts, sharing/widget state, calendar credentials and recovery backups/key. Pending edits/sync are fenced; delayed writers and a late accepted sign-in cannot recreate the deleted cache. A different active account stays signed in with its saved work. Definite authorization refusal can renew only the same account/server. Normal sign-out keeps its separate unfinished command. Accurate confirmation copy excludes user exports/other devices and explains anonymous retained shared history.

Three actual iPhone Simulator Store cases pass: failed reply/retry, held A response across A → B, and expired authorization/conditional renewal. Checks include real encrypted backup roundtrip and Keychain key deletion, outsider preservation, private pending widget publication and stale confirmation/reopen refusal. Both full Core suites pass (iOS 1,303 reported / 13 skipped / 0 failures; Mac 1,335 / 33 / 0), including 45 account/removal cases without skips; both full apps build. `ACCOUNT_REMOVAL.md` and `p0-account-removal-recovery-evidence.json` preserve exact scope and failed harness iterations.

Mac runtime reached the missing private-Keychain capability; enabling it requires a development profile deferred with signing. Existing fixture defaults stay unchanged, with explicit opt-in preparation for that future check. No weaker credential mechanism or Mac runtime pass is substituted. The service remains undeployed; real Auth/Storage byte cleanup and actual native confirmation UI/live-account tests remain required. Physical location delivery is deferred at the user's request; Simulator/Core work continues. No real account was deleted, and the full Px objective remains active.


### 22 October — reviewed account-removal UI and accessible recovery

Replaced the iOS destructive popover with a scrollable review and explicit Cancel, preserved deletion errors across intentional workspace dismissal, and made recovery available from Settings. Both independently owned apps use a concise adaptive recovery card; Mac's failed sheet retries the durable command. Final native Simulator acceptance: four phone cases (including actual VoiceOver) and one largest-text dark iPad case pass without failures/skips. Screenshot review found and corrected banner/navigation overlap before the final repeat. Both app builds pass; Mac runtime/profile and live server/Auth/Storage deletion remain open.

See `ACCOUNT_REMOVAL.md` and `p0-account-removal-ui-evidence.json` for exact synthetic scope, failed iterations, speech limits and cleanup. Test apps/runners are closed/uninstalled, VoiceOver is restored, and 386,741,583 logical bytes of obsolete artifacts are pruned. No real task/account or hosted configuration changed. Full P0/Px and all user deferrals remain unchanged.


### 22 October — deployed account removal and genuine iOS/server proof

Deployed the shared migration and endpoint once, with independently owned version-matched files in both repos and an explicit version-1 client requirement before privileged calls. Real Auth/Storage/REST deletion and original-token success retry pass; another account’s task/file bytes and anonymous shared history survive. A timed pending-account Storage request waits 4.2 seconds for the account lock then refuses. First-authorization/full endpoint race variants remain distinct and open.

A normal isolated iPhone Auth → Account review → live deletion → cache erasure → signed-out normal relaunch passes, followed by independent server/outsider verification. Both apps build; 45 account Core cases and 13 handler cases per repo, both local SQL suites and all three current native Store proofs pass. `p0-account-removal-deployment-evidence.json` records the exact scope, failed orchestration attempts and cleanup. All ten disposable identities/content and temporary credentials are gone; four completed hash receipts expire normally. Mac runtime/profile and genuine native network-fault variants remain open, alongside the wider Px backlog and all user deferrals.


### 22 October — real discarded-reply recovery and bounded review copy

Two genuine iPhone Auth → Account → server deletion cases now pass after deliberately discarding the first real success acknowledgement: visible Retry and an ordinary no-fixture relaunch. A separate server observer verifies deletion and outsider preservation while the complete native cache is still retained; both recoveries use the same original authorization and erase the cache only afterward. Both app builds and 45 Core account cases per repo pass. The final seven-day review wording also passes native Cancel/cache/relaunch inspection.

`p0-account-removal-lost-reply-evidence.json` states the client fault-injection scope, real backend checks, actual successful cron tick, separately aged/manual-cleaned receipt and cleanup. Late-expiry recovery of an unconfirmed attempt remains an explicit P0 gap; current code preserves local copies but cannot recover an already deleted Auth account after its receipt expires. Mac runtime/profile and wider fault/concurrency acceptance, the wider Px backlog and all user deferrals remain open. No backend configuration changed; all four disposable identities and temporary credentials are cleaned up.


### 23 October — private automation recurrence planner

Both repos independently own the unapplied server-side recurrence planner and the
same 316 golden inputs/expected dates, stable occurrence identities and carried
rules. Each app's actual native completion agrees with the planner; all 40 related
Core cases pass per repo, as do both PostgreSQL/PGlite planner and combined
credential/migration suites. Explicit-zone arithmetic fixes the historical skipped
calendar-day mismatch found during comparison; count/end limits, month clamping,
selected dates, fifth weekdays, DST and rule metadata are covered.

The candidate remains inactive/private. This is next-date/identity/rule planning,
not a full successor write or a usable task API. No new app UI/runtime, hosted
change or Mac signing/runtime acceptance is claimed. Full task access, immutable
request claims, recurrence child/reminder copying, native management and genuine
HTTP/Simulator acceptance remain required. No manual widget/VoiceOver/phone check
was requested; the user's physical location-delivery check stays deferred. See
`p2-automation-recurrence-evidence.json`. The full Px goal remains active.


### 23 October — scoped automation reads and permanent atomic request journal

Both repos independently own a private, inactive get/list task-read candidate,
custom-key HTTP handler and atomic write-journal helpers. Reads honor existing
accepted-project/Inbox access, including lost access to owned shared tasks, with
same-transaction key checks and task/membership locks. The permanent journal
prevents a request from becoming a duplicate task or later completion cycle;
replays reauthorize before disclosing even a minimal historical result. It stores
no task text, bodies, full responses or credentials and cascades only with its
requesting Auth account. Deferred checks roll back unfinished claims and effects.

89 local PostgreSQL assertions per repo pass with actual native guarded edit,
delete, generation and completion routines in a harness-only service pipeline;
the previous credential fixture passes afterward. Nine mocked HTTP cases and
lint pass independently. The private trigger privilege fix is verified under the
actual local service/Auth cascade boundaries. Production mutation RPCs, full
recurring successor/default-reminder behavior, real HTTP/lock races and premium
native management remain required. No live deployment or new Mac runtime/build
pass is claimed; native app runtime code is unchanged. No manual phone, widget or
VoiceOver request was needed. See `AUTOMATION_API.md` and
`p2-automation-task-access-evidence.json`. The full Px objective remains active.


### 23 October — shared recurrence ownership and write-semantics alignment

Direct, widget and bulk completion now create recurring successors for the acting
workspace, preserving their source creator/project. This fixes the collaborator
INSERT-policy mismatch. Both repos independently own the source and faithful local
INSERT-policy fixture. The private candidate carries full checklist/reminder/
metadata/default semantics and native first-fold/first-valid-minute clocks.
Only pure input-time helpers get narrow native DML-role grants; no hosted change.

150 selected Core cases per repo pass, including 316 old date and 49 new full
write goldens. Each new SQL suite passes 84 assertions, including native-role
INSERT controls and normalization; the preceding 89 journal/read checks pass.
Isolated iPhone build-for-testing and unsigned Mac Debug build succeed. This is
not Mac GUI, installed shared-cloud, real HTTP or release acceptance. No test app
host was launched. Full writes/reopen, preference reads, reviewed cascade locks,
real races and premium native management remain required; automation stays off.
Preserve native/backup series links rather than silently dropping the inspected
cascade contract. See `p2-automation-write-semantics-evidence.json`. All user
deferrals and the full Px goal remain unchanged.


### 23 October — atomic task mutation candidate and real local HTTP pipeline

The inactive candidate now implements create/update/complete/reopen/delete, with
verified native actor context, field-level guards, locked reminder preferences,
full successors, reviewed cascade deletion and current-access replay. Opaque
HMAC revisions protect delete reviews without publishing hidden row data.
Scope explanations now describe Inbox access, checklist edits and reopening.

Each repo independently passes 101 SQL assertions, 18 loopback HTTP-through-real-
handler-to-SQL assertions, 17 mocked handler tests, lint and 49 selected Core
transport tests. iPhone build-for-testing and unsigned Mac Debug build pass.
These are synthetic local checks; no app host was opened. Three fixture lint
issues were corrected before the final passes. Hosted metadata confirms the
feature remains undeployed. Native key management, metadata discovery, portable
advanced reminders, rejected-traffic controls and hosted/concurrent/native-flow
acceptance remain. See `AUTOMATION_API.md` and the new mutation evidence. The full
Px goal remains active; all user deferrals remain unchanged.


### 23 October — native automation access and private enrollment recovery

Mac now owns its Account entry, permissions/expiry composer, hidden one-time
review, inactive history, paging and confirmed revoke controls. Before registration,
a dedicated app-only device Keychain envelope retains the exact draft. Lost replies
resume the same ID/hash; saved acknowledgement or confirmed revocation clears it.
Workspace/session leases fence late replies. Another window cannot erase newer
recovery or silently register changed permissions, and saved/revoked review retires
other windows’ reveal state. Confirmed account removal cleans its private item.

63 Core/transport checks pass independently per repo, including 14 new enrollment
cases. Isolated iPhone build-for-testing and unsigned Mac Debug build succeed.
Two actual-Keychain, synthetic-protocol UI scenarios pass on each iPhone and iPad
Simulator with no failures/skips. Masked review and dark largest-text layouts are
visually inspected; concrete Delete switches toggle on/off and Cancel leaves no
enrollment. These are iOS reference checks, not Mac UI, hosted Auth/SQL or clipboard
expiry acceptance. Mac native interaction, independent-process coordination,
clipboard lifecycle, safe uncertain-request cancellation, metadata discovery and
advanced reminders remain before enablement. The entry stays hidden in normal
builds; the API remains undeployed. See `AUTOMATION_ACCESS.md` and the native
management evidence. Full Px and all user deferrals remain unchanged.


### 23 October — durable key discard and independent-process coordination

Uncertain setup can now be discarded without creating a key first. The candidate
service revokes an existing owned key or records a permanent private owner/ID
block against late creation. It discloses no foreign key state and consumes no
issuance allowance. Unknown cancellation history is separately bounded to 100/day;
existing retries and owned-key revocation remain available at that bound.

Both native apps save a version-2 private discard intent before contacting the
service. Reply loss/relaunch retries Discard, never Create; stale Save cannot clear
the intent, and the exact prior private reader refuses it. Stable empty files
coordinate all private enrollment operations across processes, with short bounded
waits, cancellation checks and no-follow regular-file validation. Receipt and
foreground checks refresh recovery; reveal state belongs to a specific key ID.

74 Core checks pass independently per repo, including real independent-process
competition/crash/symlink cases against an owned synthetic adapter. Each repo also
passes 55 cancellation SQL assertions, the updated credential regression, 101
mutation plus 18 loopback assertions and ten management handler tests/lint. Both
app builds pass. Three actual-Keychain/local-protocol scenarios pass on each iPhone
and iPad Simulator, including failed creation, lost discard reply and relaunch
without another creation. Recovery layouts have one clear action and were visually
inspected. This is not actual multi-process Mac Keychain/UI, hosted Auth/SQL races,
clipboard lifetime or release acceptance. Candidates remain unapplied/undeployed
and normal entry hidden. See `p2-automation-enrollment-cancellation-evidence.json`.
The full Px goal and all user deferrals remain active/unchanged.


### 23 October — automation destination discovery checkpoint

The inactive API now discovers accessible projects and sections, with native order,
archive availability, explicit Inbox routing and hidden-parent privacy. Both read
pages and cursor continuation reauthorize current access; sections cannot cross
project boundaries. The native permission summary includes project/section names.
Each repository independently passes 72 destination SQL, 101 mutation SQL, 25 real
loopback HTTP, 21 handler and 92 selected Core checks, plus lint. No live migration,
key, task or API deployment changed. Hosted/race acceptance and portable advanced
reminder authoring remain open. Real iPhone location delivery remains deferred;
these Core reminder checks do not close it. See
`p2-automation-destinations-evidence.json`. The full Px goal remains active.


### 23 October — portable advanced reminder authoring checkpoint

The inactive automation candidate now creates/edits/removes native calendar,
elapsed interval and holiday schedules, including Time Sensitive wrappers and
child reminders. Supported-row edits retain unknown extension values; future and
private location rows require exact carry-forward. Task recurrence stays separate,
with native root/child successor behavior. Each repo passes 131 native-reader
goldens inside 221 portable SQL assertions, 101 mutation and 31 real loopback
HTTP checks, 170 selected Core tests and lint. No live keys/tasks or deployment
changed. API-specific metadata bounds and remaining hosted/race/native-UI gates
are explicit in `p2-automation-portable-reminders-evidence.json`. The full Px goal
and all user deferrals remain active; abuse controls and hosted acceptance follow.


### 23 October — durable rejected-request admission checkpoint

Both inactive automation handlers now gate requests before Auth, body parsing or
task work. Independent task/management route limits count global/IP/full-credential
attempts, including invalid requests, using short-lived keyed fingerprints only.
Separate commits survive later task rollback; negative-only caches reduce repeated
limiter calls. Each repo passes 157 admission SQL, 221 portable and 101 mutation
assertions, 140 actual loopback HTTP checks, 40 Deno tests and lint. No live
candidate or proxy mode was enabled. Actual hosted header trust, concurrent locks,
Auth/timeout/native acceptance and provider-level network controls remain open.
See `p2-automation-ingress-evidence.json`. Full Px and user deferrals remain active.


### 23 October — actual proxy identity and PostgreSQL contention

Hosted signed diagnostics rejected the unstable final proxy hop and verified a
matching first-XFF/CF client identity from two sources. The candidate now requires
that pair; the prior mode is refused. All diagnostic endpoints were deleted,
existing functions are unchanged, and the mode/API/migrations stay disabled.
Both repos independently pass 20 real PostgreSQL 17.6 contention assertions,
including three 12-backend final-slot races and a genuine bounded advisory wait,
plus 221 portable/101 mutation/140 loopback assertions, 46 Deno tests and lint.
Owned temporary databases are removed and Docker is restored to its initial Off
state. `p2-automation-hosted-ingress-evidence.json` distinguishes actual hosted
header proof and local independent-connection proof from remaining task-effect/
hosted Auth/PostgREST/timeout/native/clipboard acceptance. Full Px remains active.


### 23 October — actual task-write contention and retry semantics

Each repo passes 99 real PostgreSQL 17.6 checks with observed lock barriers and
independent backends: exact retries, conflicting identities/fields, recurring
completion, both revoke/write orders, membership removal, replacement generations,
linked deletion review and minute/day/account quotas. Actual HTTP exercises a
40P01 rollback and exact 503 → 409 retry while preserving replacement content.
The gateway now returns a safe one-second retry hint without private SQL details;
SQL identity/access/journal safeguards remain unchanged. Existing 221 portable/
101 mutation/140 HTTP regressions, 48 Deno tests and lint pass. Owned local test
hosts/databases are closed and Docker restored Off. Main API/migrations stay off.

A data-excluding hosted acceptance branch was created, but its older migration
replay stopped after 28 entries. Repair that staging setup before hosted account
checks, then delete the branch; never merge it. Exact branch identity, proof and
remaining gates are in `p2-automation-task-concurrency-evidence.json`. This is
progress toward full Px, not a claim of hosted or release completion.


23 October hosted automation checkpoint: both repo-owned backend sources pass
42 real Auth/Edge/PostgREST checks each. The branch-only historical replay repair
allowed all 82 baseline and nine candidate migrations to pass. Test users, tasks,
keys, journals and temporary endpoints are removed; branch deletion and private connection export removal verified.
Main remains unchanged and the native entry stays gated. Mac native Keychain,
clipboard and UI lifecycle plus hosted timeout/cancellation are still required.
Evidence: `p2-automation-hosted-lifecycle-evidence.json`.


23 October credential clipboard follow-up: the Mac app compiles its own guarded
clipboard probe; no Mac runtime/Keychain/pasteboard pass is claimed. Actual iPhone
and iPad UI acceptance passes two cases each: real one-minute expiry, newer-copy
preservation, background hiding and finish/relaunch recovery cleanup. The Mac
profile/runtime dependency stays deferred. Exact scope is in
`p2-automation-native-clipboard-evidence.json`; normal product entry remains off.


23 October automation deadline checkpoint: each independent server source passes
80 actual hosted checks, plus 53 Deno/55 cancellation/221 portable/101 mutation/
140 HTTP checks and lint. Management has explicit 3s lock/10s statement budgets;
caller cancellation reaches readers and Auth/RPC. Unknown write replies preserve
the same retry intent. Both hosted disconnect cases committed, and exact retries
produced a single effect; disconnection never implies rollback. Main remains off.
The empty test branch is retained only for immediate phone/tablet native hosted
acceptance, then deleted; no Mac app launched and signing-dependent runtime stays
deferred. Exact identity, cleanup and limits: `p2-automation-timeout-evidence.json`.


23 October signed-in native hosted checkpoint: both iPhone and iPad pass two UI
scenarios each (four passes, zero failures/skips) through real Auth, canonical
Edge Functions and PostgREST with the normal Store/Backend/Simulator Keychain.
Ordinary cold relaunch preserves sign-in and recovers the same private enrollment;
acknowledgement removes pending recovery, revocation persists, and A → B → A
keeps unfinished setup with its owning account. Independent hosted readback passes
eight checks, requiring exactly two new A keys per device, zero B keys and every
key revoked. One earlier fully revoked tablet key is an explicit baseline, not a
retry duplicate. Final harness refinements handle only tablet system-password
interruptions, scrolling and navigation; production app sources did not change.

The retained acceptance branch is now deleted (absence verified), canonical test
endpoints/users removed, and SQL confirms zero users/tasks/profiles/keys/journals/
deadline controls. Private native credentials and the connection export are
removed. This supersedes the preceding retained-branch checkpoint. Exact native
results, harness hashes, failed iterations and limits are recorded in
`p2-automation-native-hosted-evidence.json`. Mac signing-dependent private-Keychain/
runtime remains deferred. Main API/migrations and the ordinary native entry stay
off. Next independent feature work is webhook delivery, followed by verified email
intake, advanced teams and wearables; full Px remains active.


23 October webhook transport checkpoint: each repo independently passes 11 local
tests (seven TLS/HTTP substeps), lint/types/format checks and nine actual hosted
checks. Delivery pins a checked public IP, then upgrades that socket with the
original TLS hostname; signed bodies, bounded responses, retry hints and encrypted
receiver-secret envelopes work in the hosted runtime. A locally passing Node HTTPS
approach was rejected after hosted handshake failure; the direct path replaces it.
No native app UI or production schema changed. The temporary branch and private
acceptance token are removed, and main has no webhook endpoint or migration.

This completes the transport foundation only. Next: authorized subscriptions,
recipient verification and a durable task-change outbox/dispatcher, then native
setup, delivery status and recovery controls. Full automatic webhooks and the
remaining email/team/wearable backlog are still open. Complete requirements and
limits: `WEBHOOKS.md`; exact proof: `p2-webhook-transport-evidence.json`.


23 October webhook subscription checkpoint: private account-bound setup and
receiver-secret proof are implemented independently in both repos. Echo endpoints
cannot connect; verification needs an HMAC proof not present in its request.
Fresh session/project checks, expiry, superseded attempts and revocation guard
activation. Setup/discard history is permanent for the Auth lifetime; removal
blocks survive receipt pruning and physical Auth deletion cleans the private rows.

Pause/Resume now has a revision baseline and durable command identity. A delayed
old Pause retry cannot override a newer Resume. Per-source checks pass: 83 SQL,
43 actual PostgreSQL 17.6 assertions with eight observed barriers, and 26 Deno
tests (seven TLS/HTTP substeps), plus lint/types/format. Main schema/endpoints remain
off. These scoped local checks do not replace hosted Auth/PostgREST/receiver or
native UI acceptance. Temporary databases/TLS files are removed; Docker stays on
because it is serving another project. No Taskfold host was launched.

Next: the actual task-change outbox and leased dispatcher, including large-task
payloads, current-permission revalidation, retries and failure history; then native
setup/status/recovery and hosted acceptance. Full webhooks/Px remain unfinished.
Details: `WEBHOOKS.md`; evidence: `p2-webhook-subscriptions-evidence.json`.


23 October webhook outbox checkpoint: each repo now owns transactional capture,
immutable complete snapshots/multipart frames, bounded per-subscription queues,
leases, final after-TLS authorization, dispatcher, retry/history APIs and payload
retention cleanup. Local source checks pass 143 SQL assertions, 35 actual PostgreSQL
17.6 assertions with five observed barriers, and 40 Deno tests/eight TLS substeps.
Task edits remain responsive during outstanding network leases; old workers cannot
acknowledge a recovered lease, and lost access/removal blocks final sending.

No real tasks changed and no remote schema, endpoint or scheduler was deployed.
Owned PostgreSQL containers/TLS fixtures are removed. No Taskfold app was launched;
Docker remains on for unrelated workloads. Next: native setup/status/recovery UX
(including quota-gap guidance), secure scheduling and hosted end-to-end acceptance.
Full webhooks/Px remains active; email intake, advanced teams and wearables follow.
See `WEBHOOKS.md` and `p2-webhook-outbox-evidence.json` for limits and exact proof.


## Native task connections — 23 October (acceptance in progress)

Each app independently owns a gated **Task connections** screen in Account.
Setup reviews a receiver name/address, Inbox/one-project/all-accessible reach,
event choices and expiry, with explicit trust consent before creating a setup.
The review explains full-note/checklist delivery, shared work included in broad
scope, and bounded paused capture. The receiver secret starts hidden, can be
revealed/copied with device-only clipboard options, and is retired after explicit
save acknowledgement. Receiver verification is a separate action; setup alone
never means connected. Pause/Resume and Revoke have their own controls, with
revocation confirmation explaining the in-flight request boundary.

Interrupted setup is retained exclusively in an app-private secure-item envelope,
coordinated across processes. Exact settings/ID/secret retry, durable discard
before cancellation, original-server binding and account-removal cleanup are
implemented. View/workspace/backend-session leases fence late results; inactive
root and modal screens cover private content. One unfinished setup per account
prevents competing windows from silently replacing a secret.

Delivery history pages only redacted metadata. It shows status, part progress,
attempts, last issue, optional event/task references and reviewed manual retry.
Uncertain state/retry actions preserve their command identity until retry or an
explicit reload of server state. Queue-gap warnings explain that missing changes
require fresh task reconciliation by the receiver; Resume cannot replay them.
Counts are cumulative. There is no automatic resync or warning-dismissal claim.

The native client uses its fixed account server, authenticated session fence,
no cookies/redirects, no-store policy, a 25-second request timeout and a 256,000-byte
response bound. No native app receives service/master/worker credentials. Both
ordinary entries remain off behind a separate `TaskfoldWebhooksEnabled` gate.
Local source checks and Simulator view fixtures do not prove hosted receiver
integration, OS Keychain recovery or Mac runtime behavior. Secure scheduling and
hosted/native end-to-end acceptance remain required before enablement; full
webhooks and the remaining Px backlog stay active. Exact verification is recorded
in `p2-webhook-native-evidence.json` after this milestone’s checks.


Native checkpoint verification: 44 focused Core tests pass per owned repository;
11 webhook cases were rechecked after the final wording change. Both complete app
inputs build. Four scoped UI tests pass on iPhone 18 Pro and iPad Pro 13-inch (M5),
iOS 27 Simulator: reviewed setup/secret/verification and failed-delivery retry,
plus largest-text dark Cancel. The phone now scrolls from secret acknowledgement
to its connection. Final screenshots are visually reviewed; toolbar labels fit
ordinary phone width. These are synthetic in-memory service/storage checks, not
hosted or OS Keychain acceptance. An unrelated recovery banner in the unsigned
Store host remains outside this accepted scope. Clipboard expiry, spoken checks,
live account/relaunch/Keychain and native Mac runtime remain open.

Both disposable Simulator apps and runners are closed and uninstalled. About
1.05 GB of redundant artifacts from these attempts is removed; current useful
build caches, final accepted results, screenshots and text logs are retained.
No real tasks or hosted services changed. Main webhooks stays disabled. Next:
genuine private-storage/native service acceptance and secure hosted scheduling/
delivery checks, then email intake, advanced teams and wearables. Evidence:
`p2-webhook-native-evidence.json`; full Px stays active.


## Signed private-storage recovery — 23 October

The opt-in native check now uses the production `Backend.webhookReceipt`,
URLSession and `Store.webhookEnrollmentVault` with the actual private OS Keychain.
The synthetic HTTP peer intercepts only the fixed owned test URL; its persistent
file contains metadata and one-way intent hashes, never receiver secrets. This
extends the earlier in-memory view check rather than substituting a mock vault
for recovery. The ordinary feature entry remains disabled.

Eight scoped checks pass across signed iPhone 18 Pro and iPad Pro 13-inch (M5),
iOS 27 Simulator. Lost-create recovery keeps the same setup ID, settings and
secret across a process restart and creates one connection. Saved acknowledgement
and revocation clear the private draft across a fresh successful read. A durable
discard survives a lost cancellation reply; another fixed account cannot see it,
and returning to the first account restores Retry discard. A final restart after
retry has no setup. Signatures and embedded Simulator application/App Group
identities are verified with the existing development certificate.

The correctly signed host also has no account-removal recovery banner. The banner
visible in the historical unsigned screenshots is not a product-state acceptance
finding. Both independent app inputs build; no Mac runtime or hardware Keychain
security is inferred from Simulator tests. Live Auth account changes and hosted
receiver integration are still unaccepted. Exact proof and limits:
`p2-webhook-keychain-evidence.json`.

The disposable Simulator apps/runners are closed and removed. Superseded owned
source/results are pruned; useful current caches and accepted results are kept.
No real tasks, hosted services, release signing or device privacy settings changed.
Next: secure hosted scheduling and end-to-end native Auth/webhook delivery, plus
remaining clipboard/spoken checks. Full webhooks/Px and the email/team/wearable
backlog remain open; user release/provider/reminder deferrals stay in force.


## Hosted delivery acceptance — 23 October

All 61 checks pass independently for each repository’s service source. Format,
Node syntax and receiver Deno type checks pass. No native app build was needed
for these diagnostic-only additions.

The owned diagnostics now exercise actual password Auth, scoped task writes,
Edge management, PostgREST, private outbox capture and pinned TLS delivery on a
no-data disposable preview branch. Both repositories own their runner, receiver
and SQL fixtures. The receiver checks exact HMAC bytes, stable message IDs,
immutable retries and absence of native Authorization/API-key/cookie headers.

The runner covers create/update/complete/reopen/delete, full Unicode multipart
notes and checksum reassembly, pause/resume replay, retry/backoff, sign-out,
receiver refusal and explicit recovery, pending versus accepted project access,
membership removal, retained owner access and account-removal cancellation.
Project memberships are service-seeded synthetic fixtures: invitation acceptance
through the native app is outside this milestone. Branch history lacks the
main database's independently installed native base, so a guarded fixture bridge
supplies inspected base fields/grants/helpers. Common feature migrations from
6 October onward are hashed unchanged; earlier platform histories differ.

Run `prepare-webhook-hosted.mjs <owner-private-connection-json> <schema-receipt>`,
then `test-webhook-delivery-hosted.mjs <connection> <receipt> <result>` from this
repository's Scripts/Diagnostics. Setup checks API and database hosts against the
same owned, nonpersistent, no-data branch and refuses main. The runner deploys
only the five test functions, uses random ephemeral secrets and synthetic users,
and removes them in finally. Delete the owned preview branch afterward and remove
the private connection file. Do not run overlapping tests on the same branch.
The private JSON uses Supabase branch connection fields SUPABASE_URL,
SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY and POSTGRES_URL; never commit it.

This is hosted service acceptance, not an app-native UI walkthrough or secure
scheduled invocation. Main schema, endpoints and ordinary app feature gates stay
disabled. Secure scheduling, native hosted account/relaunch acceptance and the
remaining clipboard/spoken checks are next. Remote-reminder, old-client and release
signing/distribution deferrals are unchanged. Full webhooks/Px remains unfinished.
Exact results and limitations: `p2-webhook-hosted-delivery-evidence.json`.


## Signed automatic dispatch — 23 October

Both repo-owned service copies pass 73 hosted checks, including actual minute
dispatch, one-use proof admission, transport health and no delivery on the next
tick after disable. Each also passes 42 local SQL checks and 45 worker/transport
tests (8 real TLS steps). Main remains unchanged.

The candidate `20261023074744_webhook_scheduler.sql` owns a disabled minute
job and operator-only configuration/state. No migration enables delivery.
The scheduler resolves `taskfold_webhook_worker_token` from Vault at each tick,
binds its HMAC to the project, timestamp and random nonce, and enqueues only a
90-second signed proof. The Edge worker verifies it before service-only atomic
admission; a consumed nonce cannot start another run. Disable/reconfigure clears
pending proofs. An already admitted worker may finish its bounded run; use
subscription pause/revoke for the existing per-delivery authorization fence.
The existing private bearer path remains for trusted operator
invocation, but the cron request never contains that reusable credential.

This design accounts for a hosted platform constraint: pg_net's queue/result
objects have PUBLIC grants owned by supabase_admin. A postgres REVOKE reports
success with a warning but cannot remove those grants. They are not exposed by
the Data API by default; do not expose the net schema or grant untrusted database
login access. A copied signed tick cannot change the destination, extend its
validity or bypass its one-use admission. SQL login roles remain a trusted
infrastructure boundary. See Supabase's [pg_net permission guidance](https://supabase.com/docs/guides/troubleshooting/revoking-access-to-pg_net-objects-has-no-effect-0bbc16).

Only the database operator can call configure_webhook_scheduler(project_ref,
true/false). Enabling requires the matching dedicated 64-character lowercase hex
worker credential in Vault and the Edge worker environment. Disable requires no
credential. The job uses a fixed HTTPS Supabase dispatch path, a 60-second network
timeout and a 55-second enqueue interval floor; durable outbox leases protect
actual delivery. State retains request ID, queue time and prior transport status,
never response bodies or task content. A network timeout is not a delivery receipt:
inspect per-event history for confirmation. Health is refreshed on the next tick;
it can lag by a minute, and pg_net response retention is finite.

Use the existing hosted runner's fourth argument `--scheduler` to test actual
minute dispatch and the next disabled tick, in addition to the full delivery
suite. It generates its credential inside Vault without a secret SQL literal,
arms only the owned no-data branch, then disables cron and removes the credential
in finally. Clean the branch afterward even if a run is interrupted. Ordinary
native feature entries and the main service remain disabled pending native
hosted acceptance. No reminder scheduler or deferred release capability is armed.
Exact results and limits: `p2-webhook-scheduler-evidence.json`.


## Native hosted receiver acceptance — 23 October

The signed iPhone/iPad Simulator app now exercises real password Auth, the
production Store/Backend transport and private OS Keychain, the hosted receiver
proof, native task capture, signed minute dispatch and the real history response.
The controller configures the app-generated receiver secret through an owner-only
local channel. It never supplies a mock UI response or intercepts app HTTP.
Normal relaunch keeps the same unfinished setup; acknowledgement, verification,
delivery history and revocation complete through the actual service. Switching
A → B → A hides A's unfinished setup in B and recovers it only in A.

Four scoped native cases pass across iPhone 18 Pro and iPad Pro 13-inch (M5),
iOS 27 Simulator: one delivery/relaunch and one account-isolation case per device.
The controller confirms both exact native-created task titles at the HMAC-checked
receiver. Phone and tablet runs are sequential because this disposable receiver
uses one configured secret at a time. The final tablet screen also confirms the
wording fix: “1 of 1 part · 1 attempt”. Both independent app inputs build.

This round uses the iOS app and iOS-owned service source. It is not Mac AppKit
runtime or hardware Keychain acceptance; that remains deferred with signing.
Nor does ordinary successful-create relaunch prove genuine native HTTP-loss,
offline, token-expiry or master-key recovery. Earlier lost-reply Keychain checks
used a synthetic HTTP peer and remain separately scoped. Those native fault
variants and clipboard/spoken checks remain open before normal enablement.
Email intake, advanced teams and wearables remain on the full Px backlog.
Main schema, endpoints and ordinary feature gates stay disabled; no real tasks
or deferred reminder/distribution capabilities changed.

The no-data branch's recorded web base omits native table grants. The fixture
bridge now mirrors the inspected main CRUD grants on tasks/projects/memberships,
sections/profiles/labels; it changes no RLS policies and never runs on main.
The temporary apps/runners, accounts, functions, Vault worker credential and
preview branch are removed after proof. Typed-password action logs are redacted;
raw Xcode result archives are pruned after exporting summaries and safe images.
Exact scope, versioned runs, source hashes and cleanup:
`p2-webhook-native-hosted-evidence.json`.


## Native clipboard and spoken secret review — 23 October

Six scoped cases pass: three each on iPhone and iPad Simulator.

The receiver-secret Reveal and Copy controls now use independent button targets
inside the Form. Previously, tapping Copy could also activate Reveal and expose
the raw value in the accessibility tree. The regression checks both directions:
Reveal must leave the clipboard untouched, and Copy must keep the value masked.
Backgrounding conceals a revealed value; continuing setup requires another
explicit Reveal.

The local acceptance host uses a synthetic in-memory service and enrollment
vault. Clipboard and VoiceOver observations use the real Simulator OS services,
not substitute clipboard or speech implementations. The Debug-only probe is
restricted to exact isolated bundle IDs and explicit test arguments. It observes
the real one-minute expiry, preserves newer clipboard content, and reports only
fixed outcome strings. It never exports a receiver secret.

The spoken check traverses the masked value and Reveal/Copy buttons with the
actual VoiceOver service, activates Copy, and revisits the updated Copied control.
This verifies its spoken label; it does not claim an automatic announcement on
label change. The test restores VoiceOver's original state afterward.

This is separate from the earlier hosted Auth/receiver/Keychain acceptance.
Mac source has the same button fix and compiles independently; Mac pasteboard
and spoken runtime acceptance remain open. Hardware clipboard handoff, native
HTTP-loss/offline/token-expiry/master-key recovery, and the wider consent/history
spoken walkthrough remain outside this round. Normal feature entries and main
webhook schema/endpoints remain disabled. Exact results and cleanup:
`p2-webhook-clipboard-speech-evidence.json`.


## Hosted native recovery acceptance — 23 October

Two scoped native cases pass, one per device. The tablet retry keeps the exact
saved intent after an interrupted UI run; the hosted fingerprint stays unchanged.

This runtime/controller round uses iOS-owned app and diagnostic inputs. The
commands below describe that iOS verification; Mac runtime remains unaccepted.

The isolated native recovery runner now covers a committed create whose reply
never reaches the enrollment model, a retry during a controlled webhook-service
outage, and normal recovery after terminating/relaunching the app. The successful
create is real HTTPS through Auth, Edge and PostgREST; the Debug-only hook throws
`networkConnectionLost` after decoding that actual account-bound receipt. It does
not replace the API with a fixture peer. The outage hook refuses webhook calls
locally before sending; ordinary Auth and task sync still use their real service.
These are controlled client fault injections, not physical radio loss or a TCP
reset at the server. Both hooks require an exact isolated bundle, explicit flags,
a disposable UUID email account and a non-main Supabase origin. They are absent
from Release. The fault proof contains only account/setup UUIDs and a boolean.

A private controller inspects the hosted subscription at commit, after the
outage and after normal retry. There must be exactly one subscription for the
disposable account, with the same ID, revision, settings, encrypted secret,
creation time and expiry. Receiver proof and an actual native-created task then
exercise the recovered secret through scheduled delivery, native history and
revocation. The Mac app owns its matching hook source and builds independently;
Mac Keychain/AppKit runtime acceptance is still deferred.

The existing `--native` mode continues to require its four normal delivery and
account-isolation cases. `--native-recovery` instead requires the recovery case
on both phone and tablet, using the same guarded no-data branch setup, private
controller files, signing helper and cleanup procedure. Run
`testHostedWebhookLostCreateResponseRecoversAcrossRelaunch` sequentially on both
devices before finishing that controller.

The walkthrough also exposed a presentation follow-up: an error notice can sit
above the automatically scrolled pending setup. Bring new failures into view
before enabling this feature; that round explicitly scrolled to inspect it.
The persistent-feedback milestone below resolves this presentation issue on iOS;
Mac source compiles but its runtime acceptance remains open.
Session-expiry recovery, server master-key failure/recovery and the wider
consent/history spoken walkthrough remain open before normal enablement.
Email intake, advanced teams and wearables remain on the full Px backlog.
Remote reminders, older-client safeguards, distribution/OAuth registration and
physical location acceptance remain deferred. Main schema/endpoints and normal
feature entries remain disabled. Exact outcomes and cleanup:
`p2-webhook-native-recovery-evidence.json`.


## Persistent connection feedback — 23 October

Eight scoped iPhone/iPad Simulator cases pass on the final source. Actual
VoiceOver reads the pinned failure after scrolling, and its original Off state
is restored. Screenshots at largest text and in history were visually reviewed.

Connection-action and delivery-history errors now sit below the navigation bar
in a safe-area banner, outside the scrolling form/list. Pending-setup restoration
and ordinary scrolling cannot move the message offscreen. The banner reserves
space instead of covering the retry/review controls, uses system text/background
styles, wraps at large text sizes, and exposes the message as one readable text
element. Only the decorative icon has a size cap; message text keeps the full
accessibility scale. History uses an explicit compact title on iOS. There is no programmatic keyboard or VoiceOver focus change.

Successful retry or reload removes the banner through the existing model state.
Unconfirmed setup still says its draft was kept; history/control errors without
a pending setup instead ask the user to reload the latest status or retry the
same action. This does not claim that an unconfirmed request failed on the server.
The enrollment, secret-review and idempotency contracts are unchanged.

The local Debug fixture deliberately loses two create replies after storing one
in-memory row, then succeeds, and refuses the first history load before recovery.
It requires the exact isolated bundle, local test mode and explicit notice flag.
It does not exercise hosted Auth, HTTP, Keychain or server recovery; those results
remain in the earlier hosted evidence. This round accepts presentation only.
Mac owns the same view/model change and compiles independently; Mac runtime,
automatic spoken announcements and the wider spoken walkthrough remain open.
Normal feature entry and main webhook service remain disabled.

Exact layout/retry checks, source revisions and cleanup:
`p2-webhook-notice-evidence.json`.


## Independent key-review actions — 23 October

Four scoped cases pass on the corrected source: two each on iPhone/iPad
Simulator. The unchanged baseline failed before the button-style correction.

The API-key review row now gives Reveal/Hide and Copy independent borderless
button targets in each app. The unchanged iOS baseline failed the strengthened
regression: tapping Reveal started the clipboard probe. This confirmed that the
Form row could invoke Copy as well. The fix changes only that row's button style;
it preserves enrollment, permissions, secret storage and clipboard policy.

The native regression now requires Reveal to leave the clipboard probe untouched,
backgrounding to conceal the raw value after an actual background/suspended state,
and Copy to leave every accessible label/value free of the raw key prefix. It
rechecks masking after the real one-minute pasteboard expiry or preservation of
newer clipboard content. Acknowledgement and normal relaunch still check actual
private OS Keychain cleanup. The API peer is synthetic and exact-host guarded;
these runs issue no hosted credential and modify no real task or account.

The earlier clipboard milestone did not assert action independence or masking
immediately after Copy. Its historical green results therefore do not prove those
properties. This round's scoped outcomes and baseline failure are recorded in
`p2-automation-review-controls-evidence.json`. Mac source builds independently;
Mac gesture/pasteboard/Keychain runtime acceptance remains open.
Normal feature entry and main API enablement remain unchanged and disabled.
The full Px objective and its existing user deferrals remain in force.


## Hosted session and encryption recovery — 23 October

Both independently owned server sources pass 50 hosted checks each, plus 29
handler/dispatcher tests each. Cleanup readback confirms zero synthetic users,
tasks, subscriptions and queued events, no owned functions or secrets, and an
inactive scheduler; both preview branches and private connection files are removed.

The hosted delivery runner now supports `--service-recovery` in each repository.
It uses that repository's handler, dispatcher and migrations on a separate,
non-persistent preview with no copied data. Temporary fault entrypoints use the
real factories with an empty master catalog or a one-bit change to each master.
They require the exact acceptance project at runtime. Production sources gain no
fault flag, and normal app entries and the main service stay disabled.

The runner expires a disposable account's actual server session through its
`not_after` value. List, create and revoke must refuse the existing token; a new
password sign-in must reconfirm the same enrollment without replacing its
ciphertext, identity or expiry. This checks server session expiry, not elapsed
JWT lifetime, native refresh-token handling or a user-facing reauthentication flow.

Missing and incorrect masters must refuse receiver verification, preserve the
pending enrollment and keep authenticated metadata/cleanup available. Restoring
the original master must finish the same unexpired verification attempt. New
creation with no master must leave no row, and discarding it must remain possible.

For delivery, each fault defers one actual task event for the real five-minute
backoff without contacting the receiver. History must show a pending event and a
safe configuration issue, with no task text. Pause/resume keeps the event's payload
fingerprint, and the normal dispatcher must not immediately release the queue.
The runner waits for the original real deadline;
the normal dispatcher must then deliver each original event once to the HMAC-
checking TLS receiver. The complete received bytes must match the original
payload SHA-256, and history must confirm delivery. The encrypted secret
and its original validity period must not change. Revoke must still work while a
master is unavailable. This is restoration of the original key, not recovery of
an irretrievably lost key or a key-rotation implementation.

The first draft of this test incorrectly expected a terminal failure; inspection
confirmed the existing SQL intentionally retains a pending event for five minutes.
The corrected test checks that contract without changing the SQL or shortening its
clock. A second test-setup correction gives the two delivery scenarios separate
accounts: pausing intentionally retains new events, so sharing an account had
correctly queued an extra event. Both preliminary failures are harness assumptions,
not product regressions; their synthetic resources were cleaned before rerunning. Exact independent runs, source hashes and cleanup are recorded in
`p2-webhook-service-recovery-evidence.json`. Native reauthentication, Mac runtime,
wider consent/history speech, email intake, advanced teams and wearable clients
remain open. Existing user deferrals remain in force; full Px is not complete.


## Concealed review after an unconfirmed action — 23 October

Both apps now remove the previous secret-review confirmation when a connection
operation reports an error. The exact private enrollment stays in its existing
account/server-bound vault; an uncertain webhook control keeps its original
retry intent. Successful control retry alone does not reveal the secret again.
Continuing enrollment can reconfirm the same setup, and its native Reveal/Copy
state resets so the raw value requires another deliberate Reveal tap.

Connection requests still attempt one automatic credential renewal. A repeated
401 on the two management routes, or a documented invalid/expired refresh-session
code, now produces a fixed sign-in message instead of server details. The notice
says a private setup was kept only when one exists. Rate limiting, server failures
and unknown refresh errors are not treated as confirmed session expiry. A rejected
refresh from a superseded account/session becomes cancellation, so it cannot
request sign-in for the newly active account. This does not log out the user,
remove tasks or erase recovery.

The regression failed on the unchanged iOS key and webhook models (two cases,
five failed assertions). Both full Core suites now pass (iOS-owned: 1,365 cases,
13 optional skips; Mac-owned: 1,397 cases, 33 optional skips; no failures).
Four iPhone/iPad native checks pass, with no skips, and their normal/largest-text
screenshots are visually inspected. Exact results and the verification limits are
recorded in `p2-connection-review-failure-evidence.json`. Native cases use the
production view/model with an exact isolated Debug-only, in-memory service refusal;
transport cases separately exercise real URLSession through a synthetic peer on
the Mac-hosted Core test target.
They do not claim hosted native expiry/refresh acceptance or an in-place sign-in
sheet. That end-to-end recovery walkthrough, wider consent/history speech, Mac
runtime, email intake, advanced teams and wearables remain open. Normal automation
entries and main services stay disabled, and all user deferrals remain unchanged.


## In-place connection sign-in recovery — 23 October

Automation keys and task connections now offer **Sign in again** after a confirmed
session refusal. The native sheet renews only the current account, on the same
server and session incarnation. A response for a different account is rejected
before credentials are saved. Stale contexts and late cancelled requests cannot
replace the active session; cancelling an older sheet cannot cancel a newer sign-in.
Cancel remains available while the request is pending and is disabled only during
the serialized credential save. Password errors stay visible above the form,
including at the largest accessibility text size.

Successful renewal rebuilds the connection manager against the new session and
its existing private enrollment vault. It deliberately avoids the full account-entry
Store reset, preserving the current workspace and Undo state by construction.
Continuing setup retries the original enrollment; it returns to a masked review
and never reveals a secret automatically. The native synthetic peer rejects any
changed enrollment body, including changed private material. Delivery-history
notices also offer the same recovery action after dismissing history.

Both independent Core suites pass (iOS-owned: 1,372 executed, 13 optional skips;
Mac-owned: 1,404 executed, 33 optional skips; no failures). Subsequent focused runs
cover the final concise feedback copy and an additional foreign-origin/signup guard.
iPhone/iPad native results and reviewed screenshots are recorded in
`p2-connection-reauthentication-evidence.json`. Each app owns its source and project
inputs; the Mac app compiles independently.

The native fixture uses the production Backend and real URLSession through a
synthetic HTTP peer, with memory-only credentials and enrollment storage. It does
not establish genuine hosted Auth, Keychain persistence, Google account-selection,
cached/queued-work or Undo runtime acceptance. Those remain separate acceptance
work, alongside Mac runtime and wider consent/history speech. Normal feature
entries and main services remain disabled. Email intake, advanced teams and
wearables remain open; full Px is not complete. Remote reminders, older-client
rollout safeguards, distribution verification, OAuth registration/provider
acceptance and physical location-reminder delivery remain deferred by the user.


## Hosted sign-in recovery and profile continuity — 23 October

A real no-data preview Auth response exposed a wire-format gap: a refused refresh
returned HTTP 400 with numeric `code: 400`, `error_code: "session_expired"` and a
message. The client previously checked only string `code`, which classified that
response as a generic failure and omitted **Sign in again**. Both apps now prefer
a nonempty `error_code`, falling back to the normalized string `code` format.
Only the existing four recognized session reasons and allowed error statuses
request sign-in; unknown reasons, throttling and server failures retain their
separate classification. Message text never determines session expiry.

Optional profile hydration now saves updated user details without entering the
full sign-in acceptance path. It keeps the current account/session incarnation,
open connection leases and pending explicit authentication attempt. After awaiting
persistence it rechecks the account incarnation and updates only profile metadata
on the latest live credentials, preserving tokens renewed during the save.
Full sign-in, sign-out and account changes retain their original invalidation.

The old profile path failed a regression with three assertions. The old raw Auth
parser failed five assertions, including a conflicting-field case. Both independent
transport suites now pass 55 cases. The full suites passed after the profile fix
(iOS-owned: 1,376 executed, 13 optional skips; Mac-owned: 1,408 executed, 33 optional
skips; zero failures); the final localized wire-parser change is covered by the
subsequent full transport suites. Both native app targets compile independently.

The iOS repo owns `--native-reauthentication` in its guarded hosted controller and
`testHostedWebhookReauthenticationPreservesSetupWorkAndUndo`. It uses actual
password Auth, HTTPS management, OS Keychain, native task capture, Undo/Redo and
normal relaunch. The controller expires only disposable users' server sessions via
`not_after`; it does not mint or edit JWTs, advance device clocks, or claim natural
wall-clock access-token expiry. It compares the complete original connection and
saved-task fingerprints, verifies a new real server session, and checks persisted
Undo/Redo. Its app-specific lost-reply flag discards one actual successful setup
response; all subsequent replies are real. The mode leaves the webhook scheduler
inactive. Exact runs, corrections, cleanup and acceptance limits are recorded in
`p2-hosted-connection-reauthentication-evidence.json`.

This does not close the full advanced backlog. Native API-key hosted renewal,
queued-edit recovery across renewal, real Google selection, Mac runtime/Keychain
and wider spoken consent/history remain separate checks. Email intake, advanced
teams and wearables remain open. Normal feature entries and main services remain
disabled; all existing user deferrals remain unchanged.


## Queued task sync after sign-in renewal — 23 October

Both apps now offer **Sign in again** directly beside a confirmed expired-session
sync warning, explaining that edits remain saved on the device. The action uses
the existing same-account sheet and avoids the full workspace-entry reset. Success
retries the saved queue; a workspace-bound deferred retry also handles renewal
finishing during an older sync. Account changes, sign-out and account removal
invalidate recovery. Renewal in connection settings also retries task sync.

Actual hosted iPhone and iPad Simulator checks pass without skips: a native create
stays queued through refused refresh, restart, wrong password and Cancel, then
automatically syncs with its original ID/generation after renewal. The original
saved task's complete server fingerprint stays unchanged, the server contains
only one matching queued task, and normal relaunch uses renewed Keychain
credentials. Only the local Debug refresh-due timestamp is controlled; this does
not claim natural JWT expiry or exactly one network invocation. Both independent
Core suites pass (iOS: 1,378 executed, 13 optional skips; Mac: 1,410 executed,
33 optional skips; zero failures), and both app targets compile.

See `p2-queued-sync-recovery-evidence.json` for exact runs, reviewed images, the
diagnostic-only startup-log correction, cleanup and limits. The temporary branch,
credentials and installed test apps are removed. Mac runtime, queued edit/delete
and held-sync variants, API-key-specific hosted renewal, Google selection and
wider spoken checks remain open. The advanced backlog is not complete; all user
deferrals remain unchanged. Normal automation/webhook feature entries stay gated.


## Hosted API-key sign-in recovery — 23 October

The remaining API-key-specific native renewal check now passes on iPhone and
iPad Simulator (one test each, no failures or skips). Actual Auth, HTTPS and OS
Keychain are used. After synthetic server-session expiry, wrong password and
Cancel preserve setup; same-account renewal and Continue return to the original
concealed key. Server comparisons verify one key with unchanged ID, secret hash,
permissions, expiry and counters, plus an unchanged complete saved-task
fingerprint. Normal relaunch recovers that setup with renewed credentials; native
acknowledgement and revocation persist through another relaunch.

No product defect was found, and Release behavior is unchanged. The iOS repo
extends its exact Debug host allowlists and owns the native test/controller; both
repos retain independent unchanged production services. This does not claim Mac
runtime, Google selection, natural JWT expiry, all queued-edit variants or wider
spoken acceptance. Exact runs, reviewed masked screenshots, source fingerprints
and verified test-app/preview cleanup are in
`p2-hosted-api-key-reauthentication-evidence.json`. Core and Mac app code are
unchanged; their previous committed suite/build evidence remains applicable.

Next feature implementation: idempotent email-to-task intake, followed by advanced
teams and wearable clients. Provider/domain configuration remains undecided; live
mail delivery must stay gated until configured and verified. Full Px remains
active, and all existing user deferrals stay unchanged.


## Email intake preparation — 23 October

Provider/domain configuration is deferred by the user; feature preparation
continues. This repo now independently owns the bounded content/retry component
and its ten passing Deno tests plus lint, with no app, database or live delivery
change. `EMAIL_CAPTURE.md` orders the remaining journal/route permissions, provider
bridge and native setup/recovery work. Keep native setup consistent with the
existing app, and do not display an address as usable before verified provider
configuration. Full intake and Px remain open.


## Email recovery controls — 23 October

The Mac-owned email view now keeps recovery messages and Retry/Discard or Sign in
actions in a persistent adaptive panel. The isolated Debug fixture can use the
actual device-only vault; its source is independently owned in this repository.
The current Mac Debug app compiles successfully. Companion iPhone/iPad Simulator
Keychain recovery and visible-action checks pass, with safe evidence and reviewed
screenshots retained locally in this repo. These are not Mac runtime or Mac
Keychain acceptance. `p2-email-keychain-recovery-evidence.json` records the exact
scope. Provider/domain configuration is deferred, delivery remains disabled, and
the full Px backlog and user release deferrals remain active.


## Email inactive-account maintenance — 23 October

This repo now independently owns the disabled, operator-only scheduled retention
candidate and its actual PostgreSQL/pg_cron acceptance. Seventy database checks,
fourteen timer/deadline/mode checks and forty-three intake-concurrency regression
checks pass. Task snapshots remain unchanged; only eligible retry metadata is
pruned. The actual engine test found that background-worker mode cannot inherit
a deadline set within its job command, so that mode is explicitly refused while
libpq mode is accepted. No global scheduler settings or hosted jobs are changed.
App/UI sources are unchanged; no new Mac runtime claim is made.
`p2-email-maintenance-evidence.json` retains exact evidence. Provider/domain setup
and full email/Px acceptance remain open with the existing user deferrals.


## Hosted email management recovery — 23 October

This repo's unchanged gateway source and common email migrations now pass 36
actual hosted management/session-recovery checks on an owned no-data preview.
Actual password sign-in and server-session renewal preserve the original full
route fingerprint and saved synthetic task. Pause/resume, rotation/retry, terminal
revocation, account boundaries and direct native RPC denial pass. The harness and
evidence are independently owned here. No Mac app source changes or Mac runtime/
Keychain acceptance are claimed; native hosted UI recovery is next. The owned
preview and synthetic resources are removed; main, provider configuration and
release flags stay unchanged. See `p2-email-hosted-management-evidence.json`.


## Email same-account recovery correction — 23 October

The independently owned Mac view now records the accepted backend session before
resetting its sign-in sheet/model, preventing a late observer from clearing the
restored screen. It uses the established workspace-bound sync-resume path. The
current Mac Debug app compiles. Companion iPhone and largest-text dark iPad
complete genuine hosted Auth/Keychain/relaunch/account-isolation/revocation
workflows with no failures or skips; sixteen server assertions preserve complete
task fingerprints and original address identity. This remains iOS runtime proof,
not Mac Keychain/runtime acceptance. Diagnostic cleanup is restricted to the exact
isolated Simulator bundle and never appears in shipping Mac flows.

Both final concealed screenshots are reviewed; test-only cleanup/resource evidence
is in `p2-email-native-hosted-recovery-evidence.json`. Provider/domain setup, Mac
runtime, spoken/wider variants and the full teams/wearables backlog remain open.
The original app email flag and main service stay disabled/unchanged.


### 23 October — independent email MIME preparation

The Mac repository now owns its bounded RFC822/HTML decoder and frozen dependency
lock. It passes 18 new MIME checks plus 41 existing email checks without runtime
permissions, alongside lint/types/format. This changes server preparation only;
no native UI or Mac runtime result is claimed. Provider/domain configuration and
real signed delivery remain deferred/open, with production capture disabled.
See `p2-email-mime-evidence.json` and `EMAIL_CAPTURE.md`.


### 24 October — companion Watch candidate owned by iOS

The iOS repository starts rank 7 with its own Watch target, native candidate screens
and protected outbox. The iPhone projection and atomic save/receipt bridge are next;
no paired task save is claimed. The Mac app has no new dependency or changed code.
Future iPhone saves will use ordinary guarded task sync. This documentation update
does not claim Mac runtime acceptance or close the remaining Px objective.


### 24 October — monotonic private wearable receipts

Mac now independently owns the compatible private cache metadata and preservation
guard. Its four new receipt cases and full 1,442-case suite (33 optional skips)
finish without failures; the actual Mac app/widget build also passes. It gains
no Watch transport or target dependency. The 26 iPhone local native assertions
are companion evidence, not a Mac runtime or cloud-account result. Paired receiver
authority/projection and complete wearable acceptance remain open; see
`p2-watch-phone-save-evidence.json` and the full ranked backlog.


### 24 October — iOS-owned Watch connection candidate

The companion repo now implements paired authority, Today projection and receiver
lifecycle hooks. Its 40 focused checks and 53 signed local iPhone assertions pass;
the native OS peer boundary is injected, so real paired/background/cloud delivery
is still open. The Watch flag remains off and target unembedded. Mac source and
build ownership are unchanged; prior receipt compatibility evidence is not a new
Mac runtime result. The full ranked backlog and all user deferrals remain active.


### Watch review candidate — 24 October

The iOS-owned companion now offers explicit edited Inbox copies of parked Watch
actions, retaining immutable originals and fencing changed destinations. Fifty
focused cases and an isolated 42 mm native Save/repeat/relaunch check pass. Mac
code, release inputs and native behavior are unchanged; this is progress tracking
only. Watch remains disabled/unembedded pending paired/hardware/cloud, capacity
recovery and wider native acceptance. No full rank/Px completion is claimed.


### Watch capacity recovery compatibility — 24 October

Mac independently decodes and monotonically preserves the private Watch history
generation during normal cache saves, Undo and restore; it has no Watch reset UI
or iOS build dependency. Nine receipt cases and all 1,447 Mac cases (33 existing
optional skips) finish without failures; the actual Mac target builds. The
companion's explicit atomic reset/reconnect/review flow passes 19 signed local
iPhone assertions plus native confirmation/cancellation checks. Watch remains
disabled/unembedded pending genuine paired/cloud/hardware/native acceptance.
Existing rollout, distribution and other user deferrals remain in place.


### Watch capture continuity — 24 October

The iOS-owned companion now retains private unsent capture drafts, explicitly
reviews changed destinations and moves a draft into its outbox atomically. Seventy
focused cases, 15 native client/archive assertions and two 42 mm prepared-sheet
renders are recorded. Manual navigation/edit/dictation/spoken checks remain open
because the Mac stayed locked. Mac source/build inputs are unchanged in this
milestone; no new Mac runtime or full-suite result is claimed. Watch stays
disabled/unembedded, and all broader Px gates and user deferrals retain scope.


### Email adapter preparation — 24 October

The Mac repo independently owns the signed-envelope/composition module and its
PostgreSQL pipeline harness. Its 114 Deno cases and 27 real PostgreSQL checks pass;
no public entrypoint, durable email admission, provider configuration, native UI or
deployment is added. Source links/additional senders, genuine provider acceptance,
remaining native checks, Watch/team work and existing user deferrals stay open.


### Watch freshness compatibility — 24 October

The iOS-owned Watch candidate now refreshes offline date eligibility on a native
minute schedule and shows its original update time. Its focused 77 checks,
Debug/Release Watch and Debug iPhone builds pass; isolated 42 mm scheduled expiry
preserves exact private archive bytes. This adds no Mac runtime code, resource,
target or cross-repo build dependency. No new Mac runtime/test pass is claimed.
Full paired/native Watch, teams/email work and all existing deferrals stay open.


### Independently owned Watch icon — 24 October

The iOS repo now owns the Watch's circular layered Taskfold icon, resource phase
and primary-icon configuration. Watch Debug/Release Simulator builds compile it,
and installed assets match the built archive. Mac runtime/build/resources are
unchanged. Native launcher/Settings/notification and older Watch/hardware checks
remain open, alongside paired delivery, broader Px and existing user deferrals.


### Paired Simulator and Watch startup fix — 24 October

The iOS-owned candidate now has actual paired Simulator Connect/capture/completion/
replay, normal foreground relaunch and durable offline Watch relaunch evidence.
Phone cold return uncovered a pre-activation peer-retirement bug; its publication
readiness fix passes 31 native checks, including four new guards. Fixed paired
phone-reboot delivery still needs a fresh retake. Mac runtime/build/resources and
shared data contracts are unchanged; this claims no new Mac runtime pass. All
hardware/background/cloud/input/spoken, broader Px and deferred gates stay open.


### Watch ready-update recovery — 24 October

The iOS-owned Watch now retries original unacknowledged work on fresh ready
publications, with bounded overlap handling and no loop on deferred receipts.
Eighty-eight focused cases pass. Actual paired Simulator cold capture return after
a real SDK failure passes 17 independent checks, preserving the original binding,
old work and receipts while saving only the original new command. No Mac runtime,
build or stored contract changes; no new Mac runtime pass is claimed. Paired
offline completion, hardware/background/cloud, native/spoken, remaining Px and all
user-deferred gates remain open. Watch shipping remains off/unembedded.


### Disabled team lifecycle foundation — 24 October

Mac now independently owns the team schema/RPC and 144-check PostgreSQL harness,
covering verified invitations, current roles/sessions, explicit ownership transfer,
archive/delete, retry/revision conflicts and ownership-aware account removal.
Official advisors report no team findings; fixture baseline warnings are recorded.
No Mac UI/build behavior or hosted project access changes. Team enrollment stays
off pending full project/task/service/storage permissions and premium native team
flows, followed by backup/activity/widget privacy and cross-client acceptance.
See TEAM_ORGANIZATION.md and p2-team-foundation-evidence.json. Wider Px and user
deferrals remain open; this is a foundation milestone, not team completion.


### Team content survives account removal — 24 October, disabled candidate

Mac independently owns the creator-identity/custody migration and 93-check owned
PostgreSQL acceptance suite. Team work/history/generations survive creator removal
and ownership transfer while personal cleanup remains intact. Pending file cleanup
keeps access closed and blocks team deletion. Direct/native guarded/service API
checks and three real transaction overlaps pass; advisors report no new findings
for custody/helpers. Original native/wire creator fields remain stable.

No hosted changes, new Mac runtime build or enabled team UI is claimed. Actual
Storage delivery, reviewed admission/current role permissions and premium native
team/folder/admin controls plus backup/activity/widget acceptance remain open.
See TEAM_CONTENT_CUSTODY.md and p2-team-content-custody-evidence.json. Wider Px
and the existing user deferrals retain scope.


### Team project roles and independent read client — 24 October

Mac owns current-member project visibility/roles and reviewed access/folder/new
project management, with creator-independent privacy and workspace-link guards.
Its 145-check real PostgreSQL suite and 48-check selected SwiftPM suite pass;
8 native cases cover role/schema validation, SQL response compatibility, response
bounds and account-switch fencing. Xcode registers the independently owned core
source. No native team UI, hosted delivery or app-runtime pass is claimed.

The read flag remains off and editing capabilities remain false. Current-role
write/assignment/structural adapters and premium team/folder/admin/invitation UI,
cache/filter/widget and backup/account/activity acceptance are still required.
See TEAM_PROJECT_ACCESS.md and the two project evidence files. Full Px and all
existing user deferrals remain unchanged.


### Guarded team task edits — 24 October

The independently owned Mac candidate now includes the disabled existing-task
edit RPC and explicit native queue adapter. Locked live role checks, narrow task
scope, generation/completion review and durable replay receipts protect team
work without widening direct writes. Undo/review retain their workspace;
unavailable-project recovery cannot discard a newer team draft.

Mac passes 70 real PostgreSQL checks and 59 selected SwiftPM tests (11 new), with
no failures/skips. Advisors report no errors/new warnings; the owned fixture is
removed. Store syntax and project lint pass. This is not a native runtime/app
build or hosted-delivery claim. Catalog editing stays false pending remaining
write/workspace/role-refresh adapters and premium team UI/acceptance. See
TEAM_TASK_EDITS.md and task-edit evidence. Full Px and user deferrals stay open.


### Team task lifecycle — 24 October

Mac now independently owns the disabled task create/delete/Undo adapter. Whole
baselines, current roles, content-certified restoration and fresh generations
preserve authors, changed tasks and later recurrence occurrences. Shared comments
and linked delete batches stay protected pending their recovery adapters. Legacy
team queue denials require review without losing the draft.

Mac passes 89 PostgreSQL lifecycle checks, 70 current edit regressions and 137
selected SwiftPM tests (10 new), with no failures/skips. The unsigned Debug app
and embedded extensions build; this does not claim runtime or distribution.
Advisors show no errors/new warnings and owned containers/build outputs are
removed. See TEAM_TASK_LIFECYCLE.md and lifecycle evidence. Team UI remains off;
remaining role/workspace/editor/service/privacy flows, full Px and user deferrals
stay open.


### Team discussion recovery — 24 October

The independent Mac candidate now preserves discussion text/read history across
team task deletion and Undo, with fresh identities, current recipient access and
private encrypted recovery. Expiry and account/team cleanup remove the recovery
copy; failed restores retain task data and Undo authority atomically. The Mac
explains expired recovery without exposing server details.

Mac passes 240 database checks (70 new recovery, 89 lifecycle, 70 edit and 11 real
Cron worker checks) and 167 selected SwiftPM tests, with no failures/skips/new
advisor errors or warnings. Owned containers/Cron staging files are removed.
See TEAM_CONVERSATION_RECOVERY.md and evidence. This does not claim a new native
app build/runtime or enabled team UI. Linked batches, remaining permissions and
premium team/workspace acceptance, full Px and user deferrals remain open.


### Atomic team selections — 24 October

The independent Mac candidate now groups linked task deletion and Undo as one
persisted/atomic action, with cross-project role checks, fresh generations and
full rollback of tasks, discussions and receipts. Store captures the whole
selection before removal and keeps request lineage through Undo/Redo. The old
linked-selection hold is replaced by this adapter.

Mac passes 301 database checks and 177 selected SwiftPM tests (10 new), with no
failures/skips/new advisor errors or warnings. The unsigned Debug app/embedded
extensions build, including the platform-specific Store and new model source.
Owned fixtures/build folders/registrations are removed. See TEAM_TASK_BATCHES.md
and evidence. Team UI stays off pending remaining editing/workspace/review flows
and privacy/recovery acceptance. Full Px and user deferrals remain open.


## Team task planning — 24 October, rank 6 in progress

The guarded team edit adapter now supports assignment, labels, same-project
sections and portable reminders. Live recipients/current roles, locked section
references, durable retries and final merged-value validation protect shared work.
Recorded retries cannot reassign departed recipients. Private/unknown reminder
choices and future extensions survive supported edits; oversized concurrent merges
roll back. Each app independently persists these intents and preserves Undo/Redo.

Each repo passes 363 database checks (132 planning/edit + 72 batch + 89 lifecycle
+ 70 discussion), 182 selected Swift tests (five new) and unsigned Debug app/
embedded-extension builds. Advisors have no new warnings/errors; owned containers,
build outputs and temporary Mac registration are removed. See
TEAM_TASK_PLANNING.md and the planning evidence files. No hosted/runtime/
distribution acceptance or enabled team UI is claimed.

Next: checklist/recurrence completion and comment/mention/file/service adapters,
current-role workspace refresh and premium native team organization/review UI,
then full privacy/recovery acceptance. Full Px and existing user deferrals retain
scope.


## Team checklist editing — 24 October, rank 6 in progress

Nested team checklists now edit, merge, complete, delete and recover through the
existing guarded task RPC. Item epochs/revisions fence completion cycles and old
text/delete callbacks after restoration. Receipt-bound recovery preserves original
discussions, files, private reminders, unknown fields and server timestamps; private HMAC/tombstone
metadata prevents history forgery or identity reuse. Whole-task Undo preserves its
certified tree exactly. Each app owns preparation, persistence and Undo context.

Each repo passes 452 database checks (221 checklist/planning/edit, 89 lifecycle,
72 batch and 70 discussion), 196 selected Swift tests (14 new), and unsigned Debug
app/extension builds. Advisors show no new errors/warnings; owned containers,
derived builds and temporary Mac registration are removed. See
TEAM_CHECKLIST_EDITS.md and checklist evidence. Team editing stays disabled;
there is no hosted/native-runtime/distribution acceptance claim.

Next: atomic recurring completion/Undo, comment/mention/file/service adapters,
current-role workspace refresh and premium native team organization/review UI,
then full privacy/recovery acceptance. The full Px goal and user deferrals remain
unchanged.


## Atomic team recurring completion — 24 October, rank 6 in progress

Team completion and next-occurrence creation now share one guarded transaction.
Actor-bound retries, source/series generations and durable write epochs protect
concurrent edits, Undo and Redo. Undo preserves later work; native acknowledgment
keeps provisional drafts when another generation wins. Both independent apps own
the persisted command, projection, transport and history integration.

Each repo passes 583 database checks (131 completion + 452 existing regressions),
262 selected Swift tests (17 new completion tests; broader recurrence coverage),
and unsigned Debug app/extension builds. Owned test containers/build products and
temporary Mac registration are removed. See TEAM_RECURRING_COMPLETION.md and the
completion evidence files. Native team editing stays disabled; no hosted/runtime/
distribution acceptance is claimed.

Next: dedicated review and current-role workspace refresh, remaining team
structural/comment/mention/file/service adapters, premium native organization UI
and full privacy/recovery acceptance. Cross-project existing series occurrences
currently fail safely and require explicit UX acceptance. The full Px scope and
user deferrals remain unchanged.


## Team completion outcome review — 24 October, rank 6 in progress

Both native apps now read and display a saved completion's authoritative outcome.
Recorded actions can resume sync without another write when acknowledgment is safe;
unrecorded actions retain their exact nonce and allow checking/retrying. The native
sheet compares current task/next-occurrence content and protects edited provisional
drafts. Read access, live sessions and frozen identities are checked before receipt
lookup; nonce locking resolves in-flight requests without implying cancellation.

Each repo passes 67 review database checks + 131 completion regressions, 271
selected Swift tests (nine new review tests), and unsigned Debug app/extension
builds. See TEAM_COMPLETION_REVIEW.md and review evidence. Owned containers,
temporary builds and Mac registration are removed. Team editing stays disabled;
no hosted/runtime/visual/accessibility/distribution acceptance is claimed.

Next: explicit rejected-action cancellation/rebase and provisional-draft
reconciliation, current-role workspace refresh/privacy, remaining team adapters,
premium organization UI and full native acceptance. Full Px scope and existing
user deferrals remain unchanged.


## Durable completion cancellation — 24 October, rank 6 in progress

Use synced task now cancels an unrecorded completion/Undo through its durable nonce
before removing an untouched local projection. The original workspace and queue
are saved in encrypted Recovery first. A racing recorded completion is reviewed;
lost responses, failures, permission changes and newly authored dependent work keep
the appropriate queue/drafts. Unrelated optimistic completion cycles are no longer
replayed twice, and related later atomic batches stay together for review.

Each repo passes 259 database checks (61 cancellation, 131 completion and 67 review
regressions), 328 selected Swift tests (13 new; includes 44 backup tests), and
unsigned Debug app/extension builds. Owned containers/builds and temporary Mac
registration are removed. See TEAM_COMPLETION_CANCELLATION.md and cancellation
evidence. Team editing stays disabled; no hosted/runtime/visual/distribution
acceptance is claimed.

Next: explicit rejected-action rebasing and edited-provisional-draft reconciliation,
current-role workspace refresh/privacy, remaining team adapters, premium native
organization UI and complete native acceptance. Full Px scope and the user's
release/provider/hardware deferrals remain intact.


## Explicit completion rebase — 24 October, rank 6 in progress

The native review can now complete the currently reviewed task or explicitly
reopen its current completion while preserving its existing next occurrence.
A Recovery copy and durable cancellation precede a fresh, persisted guarded
request. Updated content requires another visible review; current edit/series
capabilities disable unavailable actions and default closed for older servers.
New history belongs to the fresh action, and unrelated queued work stays intact.

Each repo passes 319 database checks (60 rebase/capability + 259 regressions),
338 selected Swift tests (10 new; includes 44 backup tests), and unsigned Debug
app/extension builds. See TEAM_COMPLETION_REBASE.md and rebase evidence. Owned
containers/builds and temporary Mac registration are removed. Team editing stays
disabled; no hosted/runtime/visual/distribution acceptance is claimed.

Next: explicit reconciliation of authored provisional drafts/related cohorts,
current-role workspace refresh/privacy, remaining collaboration adapters, premium
native organization UI and consolidated native acceptance. Full Px scope and the
user's existing release/provider/hardware deferrals remain intact.


## Saved provisional drafts — 24 October, rank 6 in progress

A recorded completion that adopted another occurrence can now park direct edits,
local deletion and comment drafts from its unused provisional generation. A full
Recovery copy and separate encrypted draft precede a durable generation fence;
only then are selected callbacks removed and the current shared rows acknowledged.
The Saved team drafts shelf exposes task details and copy/share controls without
automatic replay or retention eviction. Scope/cleanup gates protect private files.
Purely provisional history cannot poison fresh canonical creation or valid Undo.

Each repo passes 375 database checks (56 retirement + 319 regressions), 351 selected
Swift tests (13 new; includes 44 backup tests), and unsigned Debug app/extension
builds. Owned containers/builds and temporary Mac registration are removed. See
TEAM_PROVISIONAL_DRAFTS.md and provisional evidence. Team editing stays disabled;
no hosted/runtime/visual/distribution acceptance is claimed.

Next: unrecorded and compound/root/batch draft cohorts, explicit full-detail
reapplication, current-role workspace refresh/privacy, remaining collaboration
adapters, premium native organization UI and consolidated native acceptance. The
full Px goal and existing user release/provider/hardware deferrals remain intact.


### Completion recovery workspace preflight — 24 October

The Mac review now explains when its project is missing from the current workspace
and offers a new completion/reopen only after that project is present. Keeping
the synced task remains available; project removal during review never discards
the saved queue. The independent Mac completion suite passes 65 tests, including
three new regressions. See p2-team-rebase-project-evidence.json for full build
verification. Rank 6 and broader Px work remain in progress; team editing is still
disabled, without hosted or native runtime/visual acceptance.


### Reviewed saved-draft copies — 24 October

The encrypted draft shelf now has a grouped native review for a separate task
copy, including checklist order/notes/planning, fresh history and explicit
assignment/reminder choices. Long previews disclose their limits; full content
is retained. A durable request and server cancellation fence prevent duplicate
creation during retry or choice changes. The original archive and shared tasks
are retained. Independent verification is recorded in TEAM_DRAFT_COPY.md and
p2-team-draft-copy-native-evidence.json. Rank 6 remains in progress, team editing
is disabled, and hosted/native runtime/visual/release acceptance is not claimed.


### Current-role refresh and private presentation — 24 October

The Mac now brackets refresh with an authenticated access boundary, preserves
blocked drafts/cohorts with encrypted Recovery and filters inaccessible working
content. The presentation is masked before Keychain/backup waits, with a small
account-bound access fence surviving relaunch. Templates/portable export and
widgets use the filtered projection; personal child actions remain available.
Repeated quarantine does not repeatedly create backups. Malformed primary cache
bytes are retained for repair rather than silently overwritten. See
TEAM_WORKSPACE_ACCESS.md and native/database evidence for checks and remaining
work. Native open-window/thread/readonly-control acceptance and premium team UI
remain in progress; team editing is disabled and no hosted/release acceptance is
claimed. Existing user deferrals remain unchanged.

Verified with 653 selected core tests (27 workspace tests), 57 database checks
and a complete unsigned Debug app/extension build. Owned temporary builds and
database containers were removed; native interface acceptance remains pending.


### Preserve and reopen an unreadable workspace — 24 October

Backups & restore now explains the protected-file state and offers a confirmed
recovery action. The complete original is encrypted and verified before the
working cache is replaced; a separate original-file list supports private export
for repair. Manual/daily copies and portable export refuse an unreadable primary.
See RAW_WORKSPACE_RECOVERY.md and platform evidence for verified scope; native
interface acceptance and broader rank-6 work remain tracked separately.

Verified: 88 focused core cases and an unsigned Debug app/extension build pass.
Mac runtime/VoiceOver acceptance is still pending; iPhone/iPad Simulator flow
acceptance belongs to the independently tested iOS app. Temporary builds and
registration were removed.


### Current-access discussion presentation — 24 October

Shared discussion screens and composers now use current visible rows and access
revisions. Stale requests cannot repopulate shared text after revocation, and
private authored drafts remain available. Native team sending remains gated.
See DISCUSSION_ACCESS_REFRESH.md and per-platform evidence; ordinary inspector
invalidation/unsent editing recovery and Mac runtime acceptance remain open.

Independent verification: 105 selected core tests and a complete unsigned Debug
app/extension build pass. iPhone/iPad runtime proof is scoped to the iOS app; Mac
runtime and spoken acceptance remain open. Temporary builds/registration are
removed. Ordinary inspector recovery remains the next part of this work.


### Saved editor checkpoints and reviewed recovery — 24 October

Encrypted editor checkpoints and native Inbox-copy review are implemented in this
repo with independent source, tests and build verification. The current Mac
inspector does not yet hand unsent edits to this vault automatically. Admission,
autosave cancellation, pending-save/quit protection and native runtime/VoiceOver
acceptance remain next; the broader rank-6 and Px scope stays open. See
EDITOR_RECOVERY.md and per-platform evidence for the verified boundary.

Verification: 111 relevant core tests pass in this repository, with a successful
Debug app/extension build. Mac runtime and VoiceOver acceptance remain open.
Live editor capture/invalidation and inspector autosave handoff remain unfinished.


## Live editor sessions and pending-save handoff — 24 October, rank 6 in progress

Store-owned recovery sessions now retain edits independently of the editing view.
The iOS task editor and Mac inspector pause on source/workspace/access changes;
Mac delayed saves stop and quit verifies retained checkpoints. iOS backgrounding
also flushes checkpoints. Note-formatting and checklist organizers register their
own unsent text/tree state. Successful saves/discards close a session and fence
late writers, while failed checkpointing retains the in-memory draft for retry.
See EDITOR_RECOVERY.md and p2-live-editor-evidence.json for exact verification.
The full role/account/child-flow acceptance matrix and native Mac/VoiceOver checks
remain open; team-native writes stay disabled and the full Px goal stays active.

Verification: 115 relevant core tests pass in this repository; the independent
Debug app/extension build passes. Mac runtime and spoken acceptance remain open.


## Nested editor source custody — 24 October

TaskEditorSourceContext separates the persisted access root from the record being
edited. Nested note formatting and checklist organizers now receive the complete
edited record plus its actual root ID. A recovered child retains its own title,
notes and checklist, rather than the root title/notes or unrelated siblings.
Only root/path/generation/project identifiers enter the recovery source identity.

Admission rechecks the captured root generation, owner and project, and resolves
the exact captured child path. Ordinary text updates and sibling reordering are
allowed. Missing/moved paths, ambiguous child UUIDs and changed child creation or
generation stamps refuse continuation. A new child cannot retarget a newly
persisted matching UUID. Root access checks remain separate from these identity
checks; no new team write adapter or organization permission is enabled.

Core and native scope are recorded in p2-editor-context-evidence.json. The broader
account/role transition matrix, additional draft cohorts, native Mac/VoiceOver
acceptance, remaining adapters and premium organization UI remain in progress.
Existing user deferrals remain unchanged; the full Px goal is still active.

Verification: 119 relevant core tests pass independently in each repository,
with successful Debug app/extension builds. Mac runtime/VoiceOver and the broader
role/account matrix remain open; Simulator acceptance is not Mac runtime proof.


## Editor opening admission and queued capture — 24 October, rank 6 in progress

Editor requests now capture their workspace incarnation and source root at the
opening action. Existing tasks require a matching stored source; deleted or
replaced records cannot silently become new tasks. New tasks require their
creating account and an unused identity. Nested opening values retain the
parent's workspace/root rather than resolving them again in another account.
Calendar, list, widget/notification, Inbox-review, pinned-note and nested editor
routes use the captured admission. Current Store write permissions are checked
separately before controls or mutation paths are admitted.

Quick Add → More checkpoints the authored task before deferred presentation. Its
Store-owned session and device vault remain bound to the original account while
the sheet is queued. A blocked presentation can preserve/close that original
checkpoint without writing in the current account. An unchanged, unsaved new
task is still an authored draft; it no longer disappears merely because it was
unchanged since More. Successful Save or explicit discard retires its session.
Private preservation is allowed while ordinary editing is paused (including an
unreadable cache or sign-out in progress); removal fences still prevent account
recreation. Recovery status directs the user to the original workspace.

See p2-editor-admission-evidence.json for core/build and synthetic native scope.
The test identities are local-only, not evidence of live cloud Auth, service role
transitions or Mac runtime/VoiceOver. Those checks, remaining draft cohorts,
scoped adapters and premium organization UI remain in progress. The ranked
backlog and every explicit user deferral remain intact; full Px is not complete.

Verification: 124 relevant core tests pass independently in each repository;
Debug app/extension builds pass. Mac native runtime, real cloud transitions
and VoiceOver remain open. Simulator proofs do not establish those gates.

24 October team overview: the Mac owns a gated native organization browser with
active/archived teams, clear roles, folders and permission-filtered directories.
The account sheet presents it in its own navigation stack. Sensitive presentation
is ephemeral and fenced by workspace/session/access changes. It is read-only;
team rollout and management actions remain pending. See
[p2-team-overview-evidence.json](p2-team-overview-evidence.json) for exact checks.

24 October reviewed team administration: native team naming, archive/reopen and
folder controls now open a scoped confirmation sheet. Exact requests are retained
privately before sending; retry and local clearing have distinct controls and
meaning. The app never substitutes a fresh command for an uncertain result.
Live team rollout and remaining membership/invitation/ownership flows stay open.
See [command evidence](p2-team-commands-evidence.json) for verification limits.

24 October membership administration: native invitation responses, visible role
choices with permission explanations, removal, ownership offers/acceptance,
leave and exact-name deletion reviews are wired through private stable requests.
Recovery remains available where allowed during setup pauses or archiving.
Verified leave/delete navigation no longer waits for background task sync. See
[membership evidence](p2-team-members-evidence.json) for exact runtime limits;
live team rollout and the remaining access/identity/task gates remain open.


## Scoped team directory presentation — 24 October 2026

The independently owned Mac directory now presents saved profile names and
confirmed emails for owners/admins, with duplicate-name disambiguation and full
account references in management reviews. Identity is presentation only, stays
ephemeral and does not enter command bodies/recovery or task/widget storage. The
source-only service wrapper respects existing session/team locks and role scope.
See TEAM_ORGANIZATION.md and p2-team-directory-evidence.json for exact verification.
Native Mac/spoken and live-service acceptance remain open; Teams is disabled.


Verification: 91 relevant core cases and 213 owned PostgreSQL checks pass in each
repository, with successful independent Debug app/extension builds. The phone and
tablet pass directory → exact member review → Cancel → lower-role view → owner
relaunch in normal and Accessibility XXXL sizes. Saved-state checks show no peer
mutation file or pending command. All eight screenshots are visually inspected;
large-text roles stack below names and the review email uses a separate full-width
line to avoid the standard label's truncation. Native Mac/spoken and live-service
acceptance remain open. Temporary test apps/builds/results were removed after
evidence preservation; approximately 1.08 GiB reclaimed. No Mac test app launched.


## Native project management — 24 October 2026

The gated Teams surface now leads to permitted projects, new empty project
creation, visibility/folder settings and member project-access reviews. Separate
private stable-request recovery protects uncertain results and relaunch; the
existing team journal stays byte/key compatible. The form distinguishes a reset
that restores Editor access from one that removes access. Source-only manager
directories return bounded profile names and no email; team admin email remains
separately scoped. Full team task editing, workspace transition acceptance and
Mac/runtime/spoken checks remain open, and rollout stays disabled. See
TEAM_PROJECT_ACCESS.md and p2-team-project-management-evidence.json.


Verification: 109 relevant core tests (including 10 new project-management cases)
and 152 owned PostgreSQL checks pass independently in each repo, with successful
Debug app/extension builds. Actual SQL fixtures cover 13 accepted receipts across
all four actions. The Mac canonical directory migration also passes its 213-check
regression run with unchanged SQL bytes. iPhone and iPad native tests pass create,
visibility/folder changes, lost reply/relaunch/same-request retry, guest Viewer
access, reset/removal and final relaunch. Saved records show one project, revision
4, four unique writes and no pending request. Accessibility XXXL create/settings/
access cancellation creates no peer file or pending command before the lifecycle.
All twelve screenshots are inspected. Native testing uses synthetic peer/private
IO, not genuine cloud Auth/Keychain. Mac runtime/spoken and broader live workspace/
editor/widget acceptance remain open; rollout/task-write flags stay disabled.
Owned test apps/builds/results are removed; approximately 1.11 GiB reclaimed.


## Reviewed project rename, archive and reopen — 24 October 2026

The gated project surface now offers Rename, Archive and Reopen, with explicit
active/own-archive/inherited-archive status. Older services without the versioned
state fields remain unknown and do not receive these new controls. A structural
review shows the complete affected project count and explains preservation before
confirmation. Cancel creates no command. The server rejects a branch if the
actor cannot manage every child, or if a reviewed branch changed. No child names
are disclosed by that review. Reopening a parent preserves individually archived
children; reopening under an archived parent requires reopening the parent first.

All seven project commands use the existing separate private project journal.
The archive review token/count, account, backend, IDs, revisions and request ID
survive uncertain results and relaunch. Exact retries return the original minimal
receipt without applying the operation again, including an old archive retry
after a later reopen. Fresh archive is available as a narrowing/recovery action
while setup is paused or the team is archived/at its budget; rename/reopen retain
the normal setup/team/budget restrictions. Requests expire after 15 minutes.

The canonical source-only migration is 20261024172109_team_project_archiving.sql
in each repo. A private, transaction/actor/team/root/project/operation scope lets
only the reviewed project metadata fields change. Existing task/comment/file
write guards stay untouched. The real legacy hierarchy cascade derives inherited
archive state while retaining child own flags. Team and hierarchy locks serialize
reviews against branch changes; affected project locks serialize against task
writers. Every affected binding revision and access boundary changes on apply.
The existing trusted whole-team cleanup scope remains separate. No hosted schema
or native rollout/task-write flag was changed.

Verification: 114 focused Swift tests, 93 owned PostgreSQL metadata checks and the
152-check project access regression pass independently in each repo. Actual SQL
review/command fixtures are decoded by each native core test suite. The database
suite covers lost responses/replay, stale branch/revisions, explicit manager and
lower roles, private/foreign/personal children, corrupt cycles/depth, paused/team
archive/quota recovery, unchanged task/discussion/file/custody/grant rows, epochs,
concurrent writes and project locks, direct-write rejection, exact scope rejection
and existing empty whole-team cleanup. Both Debug app/extension builds succeed.
See p2-team-project-archiving-evidence.json for native results and limitations.

This advances rank 6; it does not complete team collaboration or the full Px
objective. Live Auth/RLS/Keychain acceptance, Mac runtime/spoken checks, broader
workspace/editor/widget transitions, scoped team task/comment/file adapters,
project deletion with retained custody/Storage API cleanup, project adoption/
templates/subprojects and remaining ranked work remain open. All user-deferred
provider/device/release work stays deferred.

Native verification: iPhone and iPad each pass the two final normal/Accessibility
XXXL workflows. The saved peer contains one project at revision 4, exactly three
unique accepted changes (rename/archive/reopen), and no pending request. Sixteen
screenshots are visually inspected. Accessibility-size review titles shorten to
fit; long body copy remains in the scrollable form. The test waits for a control’s
center to be visible before tapping. Intermediate failed UI trials are described
in the evidence and are not counted as acceptance. Native tests use a one-project
synthetic file peer; task/content and descendant preservation are real owned-SQL
checks. Mac runtime/spoken and genuine hosted Auth/Keychain acceptance remain open.

Owned isolated test apps/runners and temporary host/build/result/attachment folders
were removed after preserving evidence; approximately 1.22 GiB of allocated artifacts removed. No Mac test app launched. Persistent core caches and unrelated apps, containers and runtimes remain intact.


## Paired offline Watch completion — 24 October, rank 7 in progress

The iOS-owned Watch client now uses its pending/review status for automatic
transport outages. Automatic activation/foreground refresh no longer leaves an
obsolete connection alert after a saved action. Explicit Refresh still reports
unavailability; validated phone updates clear that temporary error without
clearing unrelated save/protocol failures. No stored/wire fields changed.

A real iPhone Air/42 mm Watch Simulator pair passes 47 checks across three
independent offline completions: normal delivery plus ordinary phone Undo and
exact replay; an already-completed task; and a deleted/restored task with a new
incarnation. Each original pending command survives an offline Watch relaunch,
then the same Watch process receives the actual saved/stale receipt on phone
return. Normal replay leaves the task open with its one retained mutation proof.
Rejected replay and explicit local discard preserve every actual phone-cache
byte and add no mutation proof. No peer/packet or authority is injected. A
read-only observer verifies no obsolete connection error in the original process.
The final initial Watch viewport is visually reviewed: 2 due, matching the two
open phone tasks, with no obsolete alert. This is not native input/VoiceOver proof.

The paired fixture now isolates backend/session/recovery configuration, and its
fresh preparer is byte-compared with compiled inputs. Current phone/Watch Debug
and Watch Release compile; real-team signatures/native identities pass, and
Release excludes completion fixture/transport diagnostics. The 88 iOS Watch/
receipt cases and 9 Mac receipt-compatibility cases pass. The initial observer
trial ended before genuine delayed delivery; its result was observed saved before
a corrected fixture/feedback retake. It is not counted as full acceptance.

See p2-watch-offline-completion-evidence.json in the iOS repo and WATCH_COMPANION.md
there for exact scope. The Mac implementation has no Watch target or iOS build
dependency; only the unchanged private receipt contract is checked here. Genuine
cloud/hardware/background/system launch, account/phone/reinstall and native
controls/spoken/layout/icon acceptance remain open. Watch stays disabled and
unembedded in shipping sources. Rank 6 and the full ranked/Px objective remain
active; all user-deferred release/provider/device work stays deferred.

The disposable phone/Watch apps are closed and uninstalled; the selected Air/42 mm pair is restored to Shutdown. Both owned native build caches and prepared copies were removed after evidence preservation (approximately 1.3 GiB allocated). Existing phone/tablet boot states, core caches, user data, unrelated apps and runtimes remain intact. No device was erased or unpaired.

The [iOS-owned paired acceptance record](https://github.com/dbakp/TaskFold-iOS/blob/ed0c1189a4021079b89b83aed0d7be4cc461e0c3/docs/p2-watch-offline-completion-evidence.json) is committed at `ed0c118`; this is not a Mac runtime claim.


## Team subprojects and branch moves: service and command foundation — 24 October 2026

The next rank-6 stage adds source-only `review_hierarchy`, `move` and
`create_subproject` service operations, with independent native command/read
implementations in both repositories. It does **not** expose the new app controls
yet. The destination picker, branch confirmation, synthetic UI peer and native
phone/tablet/Mac acceptance are the next stage. Teams and task writes stay gated;
no migration is deployed and no real workspace or rollout setting is changed.

A hierarchy review binds the exact source branch, its per-project revisions and
archive settings, and the destination ancestry/revision to a digest. The caller
must manage every affected project and the destination. Cross-creator branches
and branches whose creator has left are valid; private parent identity is hidden
when unreadable. New subprojects are attributed to their actual creator, with an
explicit manager grant and separately chosen visibility/folder. Destination
permissions and folder settings do not propagate into the moved branch.

The separate transaction/actor/team/root/project/destination scope permits only
reviewed parent and derived archive changes. Source creators, own archive flags,
tasks, discussions, sections, Storage rows, file custody and grants stay intact.
Moving into an archived destination is explicit in the review and retains each
project's own archive flag. The legacy personal ownership guard remains intact;
only bound team rows use the new team-aware organization guard. Live Auth/session
and role checks, team serialization, bounded branches/depth, request fingerprints,
15-minute request expiry, operation budget and exact replay apply. A failure after
the root write rolls the entire operation back, including scope and receipt rows.

The optional versioned hierarchy projection distinguishes team-level placement
from an inaccessible parent, and rejects partial/contradictory values. Native
reviews/commands/receipts bind account, backend, team, action, source, destination,
revisions, count and archive states. An HTTP review must return the requested
destination. Both new commands reuse the private project journal, keeping their
exact reviewed intent across a lost response and relaunch. Existing controls
explicitly decline hierarchy actions until the reviewed native flow is ready.

Verification in each repo: 121 focused Swift tests; 95 real owned-PostgreSQL
hierarchy checks; the existing 93 archive and 152 access checks with the new
migration loaded. Native core tests decode each repository's independently
produced SQL reviews/receipts, including archived-root moves. Checks include
concurrent requests, destination revocation while waiting on a lock, stale branch
and destination ancestry, full rollback, exact scope misuse, hidden parents,
departed creators, 20-level depth and 1,000-project limits, direct-write rejection,
unchanged content/custody/grants and unchanged personal creator isolation.
Security/performance advisors report no new warnings (the existing fixture's
`auth_rls_initplan` baseline remains). Debug app/extension compilation is recorded
in `p2-team-project-hierarchy-foundation-evidence.json`; build success is not
native interaction, spoken, hosted Auth/Keychain or rollout acceptance.

Reproduce with `node Scripts/Database/test-team-project-hierarchy.mjs <report.json> <native-fixtures.json>`.
Run the two existing service suites under `TASKFOLD_TEST_PROJECT_HIERARCHY=1` to
load this migration as well. Their deliberate corruption fixtures conditionally
bypass both organization triggers; production guards are not weakened to seed
those fixtures. All service runtimes are owned local containers removed in finally
blocks. No cross-repository build input is introduced.

This completes the hierarchy service/typed-command foundation only. The ranked
Px objective, team hierarchy UI/acceptance, scoped task/comment/file integration,
project adoption/templates/deletion, Watch acceptance and the other remaining
ranked work stay open. Existing user deferrals stay deferred.

Both Debug app/extension builds passed. No native app was installed or launched in this foundation stage; no Taskfold processes remained at cleanup. The owned copies/native caches were removed after preserving evidence (approximately 1.01 GiB allocated across both platforms). Existing core caches, booted phone/tablet states, user data and unrelated runtimes remain intact.


## Team subprojects and move review — 24 October 2026

The gated project surface now offers New subproject and Move project when the
service supplies versioned hierarchy metadata and the actor can manage the
project in an active, unpaused team. Older services keep their existing controls.
Each repository owns its implementation; no cross-repository build dependency
was introduced. No hosted migration or team/task-write rollout flag changed.

New subproject reviews a fresh project identity under the chosen parent before
opening the draft. Its own visibility defaults to Private and its folder to No
folder; the parent is not treated as permission or folder inheritance. Move
loads a separate, fully paginated, access-fenced catalog. It offers managed
projects and, where applicable, Team level. It removes the source, known
subprojects, current parent and known cycles from presentation; the service
still verifies the entire private branch and destination independently.

The review names the destination and affected project count, explains retained
tasks/discussions/files and per-project settings, and warns when a destination
is archived. Change destination returns to the picker without creating a command.
Cancel creates no pending request. Confirm uses the typed source/destination
review from the preceding service foundation; no private child names are added
to the review. Late account/workspace or stale source/team/destination results
are declined. Enter/Done in the name editor dismisses its keyboard without
submitting the draft. Large review titles shorten; body copy wraps and scrolls.

A saved uncertain command shows its branch and retained destination intent and
reuses the exact private request after relaunch. Destination display names remain
presentation only. Successful creation offers Open subproject. Catalog rows show
known parent context or an unavailable-parent status, and a permitted subproject
can open its parent. Task editing remains disabled in this gated preview.

The synthetic native peer now models real parent links, mixed creators, derived
archive state, per-project revisions and separate lost replies for both new
commands. It runs only in the existing exact isolated DEBUG namespace with
explicit test arguments. Its file-backed journal replaces Keychain only for
synthetic acceptance; no real Auth, task, mail or storage service is involved.
Real SQL authorization/custody preservation remains separately proved by the
95-check service foundation and its archive/access regressions, not by this peer.

Two additional native-core cases cover destination filtering, including source,
current parent, descendants, lower roles, paused/old services, archived targets,
known cycles and cross-origin catalog rows. The focused 123-test Swift suite
passes independently in each repo, and each Debug app/extension build passes.
Native acceptance results are recorded separately below; these builds do not
imply Mac runtime, spoken, hosted Auth/Keychain or rollout acceptance.


Native iPhone and iPad acceptance now passes all six project workflows per
device: the new largest-text hierarchy cancellation/change-destination checks,
subproject creation and interrupted-reply recovery, branch move and interrupted
recovery, correct parent navigation, return to team level, saved child navigation,
and existing creation/settings/access/rename/archive/reopen regressions. Final
saved peer state has four projects and exactly three distinct accepted hierarchy
requests (create/move/move), with no pending journal. Creators, grants/folders,
per-project own archive flags and final inherited projections are verified.
Cancelled hierarchy reviews leave no peer or command files. Twenty-six new
screenshots are visually inspected and preserved in the iOS repo; standard
single-line name-field horizontal editing/truncation remains native behavior.

The passing retake uses the observed native BackButton identifier and targets
the active sheet collection viewport for visual checks. Superseded runs are not
counted as final acceptance. See `p2-team-project-hierarchy-ui-evidence.json` and
the iOS-owned native result/state/screenshot records for precise scope. Mac core
checks and Debug build pass independently; no native Mac runtime/spoken, hosted
Auth/Keychain or full team-rollout acceptance is claimed. Rank 6 and the full Px
objective remain active, including remaining task/adoption/template/deletion and
broader access/role/account integration. Existing deferrals remain unchanged.

The isolated apps and runners are closed and uninstalled from both Simulators. Owned native caches, prepared copies, result bundles and scratch files are removed after preserving evidence (approximately 1.34 GiB allocated). No Taskfold process remains. Baseline phone/tablet boot states and unrelated caches, runtimes and user data are preserved.

The [iOS-owned hierarchy UI acceptance record](https://github.com/dbakp/TaskFold-iOS/blob/53fefac03030df75bc7ff1ea714763faf14dbb0f/docs/p2-team-project-hierarchy-ui-evidence.json) is committed at `53fefac`. This is a reference to iPhone/iPad Simulator acceptance, not a Mac runtime claim.


## Captured native team-task draft boundary — 24 October 2026

The next editor stage adds an opening-time `TeamTaskEditorDraft` and explicit
Store capture/save entry points in each independent repository. It freezes the
account/workspace incarnation, backend, session incarnation, source task/project/
creator/generation and opaque access-boundary token. Editing requires the existing
organization client flag and current server send capability for an unarchived
project in an active team. A creator UUID is never an authority shortcut; retained
work from another creator can be edited under current editor/manager authority.
Changed rights, access remove/restore, session, workspace, backend or task identity
require reopening the task. This authority value is deliberately not Codable.

The builder creates only an explicit scoped PATCH. It compares the complete draft
with its opening source, rejects unsupported changes as a whole and does not strip
unknown fields or quietly convert project moves, recurrence, attachments, comments,
root completion or metadata into ordinary edits. Those fields require their own
commands. Supported planning/checklist fields use the existing scoped validators.
Unchanged fields and no-op saves create no mutation. Opaque stored fields remain
in the task, without entering an unrelated patch.

Authored values retain the opening baseline even if another person edited that
field locally during the open sheet. The dedicated team service remains responsible
for field conflicts and merge rules; the builder does not turn a newly observed
value into its own baseline. Existing Snapshot checklist projection retains another
child's concurrent edit. Existing history builds a fresh scoped Undo restoring the
observed pre-commit state, while transport retries retain the committed nonce.
Store hands the validated mutation to the existing durable commit/outbox path and
never falls back to a personal task write. Ordinary team writes stay rejected.

Ten new cases cover current-role authority with a different creator, disabled and
viewer access, archived-team contradictions, access ABA, session/account/workspace/
backend transitions, removed/recreated/rebound tasks, authored and untouched fields,
whole-draft rejection, no-ops, concurrent checklist items, persisted scoped payloads,
Undo and the actual SQL-produced four-field planning body/reply through the dedicated
HTTP adapter. The access boundary and HTTP transport in that final client test are
synthetic; it is not a hosted authorization test. Each repository reads its own
previously generated SQL fixture. No migration, server grant or provider setting
changed in this stage.

The focused Swift suite passes 109 tests per repo, with no failures. Both unsigned
arm64 Debug apps/extensions build, including Store. No native app is installed or
launched. The current editor admission gate is intentionally unchanged: the new
Store entry points still need to be connected to captured editor requests and
verified through the native UI, including the remaining field-specific adapters,
role/account transitions, recovery and permissions. Build and core checks are not
interactive, spoken, Keychain, hosted or team-rollout acceptance. Rank 6 and the
full remaining Px objective stay active; all existing user deferrals remain.

Owned prepared copies/build caches and scratch files are removed after evidence preservation (approximately 1.02 GiB allocated). No Taskfold process remains. Persistent core caches, baseline Simulator boot states and unrelated data/runtimes are preserved. See `p2-native-team-editor-draft-evidence.json`.


## Captured native team editor bridge — 24 October 2026

The captured draft now travels with existing-root editor admission. iOS Save uses
its explicit scoped Store path before personal label creation, reminder defaults
or personal task merging. The Mac inspector retains autosave and captures its
context once when opened; it renews the baseline only after a successful durable
save. An explicit denied admission cannot acquire fresh authority on appearance.
Note formatting and checklist sheets inherit the same context. Admission rejects
another root/workspace's context; secondary sheets cannot reset its baseline.

Title, notes, planning and checklist controls use this bridge. Project moves,
assignments, labels, recurrence, reminder management, root completion/deletion,
attachments, legacy comments and note pins are withheld where they still need
separate native team adapters. Quick entry and reference suggestions respect the
same limits. Ordinary personal Store writes still cannot infer a team scope.
The iOS Form is split into typed sections to keep SwiftUI compilation bounded;
its native layout and explicit Save remain in place.

Each repository passes 111 focused team/edit checks and 69 backup/recovery checks,
with no failures. Both native Debug app builds pass. The iOS widget extension also builds; the
isolated Mac helper omits its widget target. The isolated iPhone and
iPad each pass title editing, note-formatting application, exact scoped PATCH and
opening baseline persistence, different-creator/opaque-field preservation,
relaunch retention, and edit-to-viewer loss with a privately encrypted unsent draft
and no task write. The iPhone also passes the existing personal checklist
cancel/move/save/relaunch workflow. A separately selected personal-root test is
skipped because its exact namespace guard excludes this fixture; it is not counted
as a pass. The initial team-save attempts failed because simulated Command-A did
not select text. The test now uses the native Select All menu and asserts the
replacement before saving. Six final screenshots were inspected and retained in
the iOS repository. The native test backend rejects every HTTP request locally;
this proves client/UI/durable-disk behavior, not hosted authorization or delivery.

The Mac bridge is independently compiled; Mac runtime/autosave, hosted multi-actor
conflicts, broader account/role transitions, team checklist interaction and the
remaining field-specific adapters still need acceptance. Computer use reported
the Mac locked again, so no additional manual unlock was requested. Teams remain
disabled in both shipping Info.plists; only the reserved isolated copy enables the
switch. No schema, hosted service, provider, release setting or real data changed.
Rank 6 and the full Px objective remain active, with all user deferrals preserved.
See `p2-native-team-editor-bridge-evidence.json`. Reproduce the isolated copy with
`Scripts/prepare_team_editor_native_test.py --output <new-temporary-directory>`;
launch with `--team-editor-testing`, adding `--team-editor-reset` only to seed the
synthetic workspace.

Both isolated Simulator apps/runners are uninstalled. Owned temporary builds,
results, prepared copies and scratch files are removed (1.18 GiB allocated
across both repos). No Taskfold native app/test process remains; baseline Simulator
boot states and persistent core caches are preserved.

The iPhone/iPad runtime records and six screenshots belong to the independent
iOS repository at commit `8bdcd1913607526bb8ed2a01115f9f87b5212c19`. They do not
substitute for Mac runtime acceptance or create a build dependency.


## Native team checklist custody and acceptance — 24 October 2026

A real iPhone/iPad check found that a role downgrade removed the editable parent
form and dismissed its checklist sheet. The screen then showed only the parent’s
paused message, losing the checklist’s own recovery feedback. Both native editors
now own checklist presentation outside the editable form. One transient request
carries the local binding and frozen admission together. iOS also hosts child
Details outside the organizer’s editable branch, so a paused child retains its own
private draft and recovery state. No sheet opening refreshes team authority.

Checklist recovery now shows Preserving until the encrypted revision is verified,
then identifies its original workspace and Unsent task edits. An unchanged iOS
child closes directly on Cancel; edited children still require Discard changes.
The existing organizer layout, local review and parent Save flow are preserved.

Final iPhone acceptance passes six tests; iPad passes five, with no failures or
skips. The cases verify unchanged/edited child cancellation, organizer cancellation
with exact saved-cache preservation, child Save held locally until parent Save,
one scoped parent PATCH with the opening checklist baseline, preserved opaque child
fields and a concurrently observed sibling edit, relaunch, and role loss while
editing either the organizer or child Details. Role-loss cases verify the saved
private-draft message, unchanged stored checklist and no queued task mutation.
Existing team title/notes formatting Save/relaunch passes on both, and the existing
personal organizer cancel/move/save/relaunch passes on iPhone. All ten final
screenshots were inspected; six new checklist/recovery captures and one diagnostic
before-fix frame are retained in the iOS repository. Initial test selector and
DEBUG-toolbar ambiguities were corrected before relying on these final checks.

Each repository passes 143 focused workspace/checklist/tree/recovery tests. The
iOS app, widget extension and UI runner build; the independent Mac app builds with
its isolated helper’s widget target omitted. Mac interaction remains open: computer
use still reported the Mac locked, and no further unlock question was sent. The
native tests use synthetic accounts, a synthetic access boundary, a simulated
concurrent sibling observation and a Backend configured to reject HTTP. Hosted
multi-actor authorization, broader account/read-loss transitions, VoiceOver and
Mac runtime are separate acceptance work. Team rollout remains off in both source
Info.plists. No schema, hosted configuration, provider or real data changed.

Assignments/labels and other field-specific native team controls, independent child
records, wider native/live acceptance and the full Px objective remain open. All
user-deferred release/provider/device work stays deferred. Reproduction uses each
repo’s `Scripts/prepare_team_editor_native_test.py` and the four `testTeamChecklist`
methods in the iOS native suite. See `p2-native-team-checklist-evidence.json`.

Owned temporary copies/builds/results, frame-extraction cache and scratch files
are removed (1.28 GiB allocated across both repos). Both isolated iOS
apps/runners are uninstalled. No Taskfold native app/test process remains; baseline
Simulator boot states and persistent core caches are preserved.

The independent iOS runtime summaries and inspected captures are recorded at
`TaskFold-iOS` commit `b1ca194e50ffcebf8fbc1a7445a835e2eff078c8`. This is an
evidence reference only; the Mac app has no build dependency on that repository.


## Project-scoped team assignments — 24 October 2026

The gated team editor now offers Unassigned, You and teammates with current
editing access to the exact project. iOS retains the choice in the task draft
until Save; the Mac inspector uses its existing scoped autosave path. The picker
uses native rows, search, selection feedback and explicit refresh/error states.
It keeps display names only in memory and never loads the manager directory or
uses a retained task creator as authority. Personal assignment controls are
unchanged. Team quick-entry assignment remains excluded until it has its own
scoped adapter.

A source-only recipient RPC returns a bounded, account/project/access-fenced
catalog with IDs, project roles and sanitized display names. It discloses no
emails, invitations or organization-wide directory. Live actor/session and access
checks reject viewers, unrelated projects and disabled/archived contexts. New
recipient membership/access is checked on selection. Connectivity failure may
retain an already reviewed choice as a frozen offline intent; authentication,
malformed responses and access loss never use that fallback. The write service
still independently validates the recipient. Self and Unassigned remain usable
without a directory request. Closed or retargeted pickers ignore late replies.

Both repositories independently pass 34 synthetic PostgreSQL checks with no new
advisor warnings/errors. Each owns its migration, lookup/client/model/view, SQL
fixture and nine new core tests. Full core suites passed before the final bounded
transport refinement (iOS 1,707 tests, 13 environment-gated skips; Mac 1,739 tests,
33 environment-gated skips). After that refinement, all 76 focused recipient,
workspace, edit and project-access tests pass in each repository without skips.
The Mac isolated app compiles unsigned; its helper omits the widget target.
Native iPhone/iPad results and exact evidence are recorded in
`p2-team-assignment-evidence.json`. Initial native harness failures were corrected:
use a measured short drag to reveal the full row above the tablet sheet edge
(the broad swipe overscrolled), scope child controls to the child
form, and assert the parent’s actual absent assignment rather than assuming an
explicit JSON null. These did not require changing the saved-task implementation. The initial iOS compile caught a helper placed
on the presentation wrapper; it was moved to the editor before native testing.

No hosted migration, team rollout switch or real account/task changed. Native
checks use an exact DEBUG bundle/argument fixture; only its synthetic recipient
RPC is answered locally, and all other requests fail without network. Mac
interactive/spoken acceptance, hosted multi-actor acceptance, remaining native
field adapters and the full rank-6/Px scope remain open. All user deferrals stay
in place.

Final assignment acceptance passes four tests on iPhone and four on iPad,
with no failures or skips. The four new picker/recovery screenshots were inspected
and retained in the iOS evidence directory; both displays show readable, complete
rows and status text. Native Mac interaction remains a separate open gate.

Stage cleanup removed 1,318,117,376 allocated bytes of owned temporary builds,
results and scratch files across both repositories. Both isolated apps/runners
are uninstalled, with no Taskfold native app/test process left. Baseline Simulator
boot states and persistent core caches are preserved.

The independent iOS Simulator evidence is recorded at `TaskFold-iOS` commit
`8e27b0147691d7ec3af4cf2822f2a2e05ec9ee33`. This is an evidence reference; the Mac build owns all its inputs.


## Shared task labels — 24 October 2026

Gated team Details now opens a dedicated shared-label editor. It supports adding
and removing portable label names, existing legacy entries, and suggestions from
visible tasks and nested children in the same project. Personal catalogs and
other projects never supply those suggestions. Apply returns the choice to the
iOS task draft (or the Mac inspector’s scoped autosave); Cancel keeps the task
unchanged. Captured editor scope and the original label baseline remain in charge.
The sheet stays present after access loss, keeps its edit in the private encrypted
recovery vault and blocks callbacks into the wrong task/workspace.

A team label is text, not a lookup into an individual’s label table. Scoped task
mutations now preserve that text without personal name-to-ID normalization.
Personal label rename/delete only considers personal task records, including when
a shared task has the same label name. Team quick-entry no longer resolves label
references through personal IDs; its separate shared-label adapter remains open.
Personal editing retains the previous normalization behavior.

New names allow 1–100 characters (at most 400 UTF-8 bytes), with no controls,
bidi overrides or UUID-shaped catalog IDs. Existing nonempty strings up to the
service’s 1,024-byte limit remain exact, ordered and removable; unsafe names/IDs
appear as Saved label instead of being resolved through personal data. Duplicates
remain until explicitly removed. A future/unsupported list is read-only and
preserved. No list is silently truncated. Project suggestions inspect at most
2,048 nodes/4,096 values and offer up to 200 names, keeping large projects bounded.
The service’s 256-label task limit and guarded replacement baseline still apply.

Both repositories pass 71 focused team/model checks and 140 label/conflict/
quick-entry/recovery regressions. After tightening the suggestion work bound,
all seven new model cases pass again. These cover text/legacy preservation,
invalid/future/oversize values, Unicode, project-only suggestions, frozen scoped
mutations/relaunch encoding, personal normalization and shared-task exclusion.
The existing server planning validator/contract is unchanged; this stage adds
no migration, hosted configuration, permissions or new network endpoint.
Native phone/tablet and build results are recorded in `p2-team-labels-evidence.json`.

Each app owns its code, model and tests independently. Team rollout stays off.
Mac interactive/spoken and hosted multi-actor acceptance, remaining field adapters,
independent child records and the wider ranked/Px work stay open. All existing
user deferrals are preserved.

Final native acceptance passes five tests per device on iPhone and iPad, with no
failures or skips. Four label cases cover typed-text Apply, scoped Save/relaunch,
unchanged personal catalogs, Cancel, encrypted access-loss recovery, child labels
and actual personal label rename/reset/delete without changing shared tasks. The
existing assignment Save/relaunch regression passes too. Six new label/recovery
screenshots were inspected and retained with both summaries in the iOS repository.
The initial native reveal helper imposed a 60-point margin on a fully visible
last debug row; its label-form margin is now 12 points. Review also fixed Apply
dropping unsubmitted name text; the final native Save case types without Add.

Stage cleanup removed 1,278,590,976 allocated bytes of owned temporary builds,
results and scratch files. Both isolated apps/runners are uninstalled, with no
Taskfold native app/test process left. Baseline Simulator boot states and
persistent core caches remain intact.

The independent iOS runtime evidence is at `TaskFold-iOS` commit
`80dff267d9bda5fafba2559e57b90ae3e2735ffd`. This is an evidence reference only; Mac build inputs remain independent.


## Shared reminder controls — 25 October 2026

Gated team task Details now opens Shared reminders. The existing native settings
editor is reused for relative/planned, fixed-time, repeating calendar, elapsed
interval, reviewed holiday and Time Sensitive choices. Apply returns the complete
list to the iOS parent task draft; the Mac inspector uses its scoped autosave.
The shared sheet has no notification-permission, remote-delivery or private-place
setup controls. Device delivery stays opt-in separately. Existing private/future
and non-local-channel rows are shown generically and retained unchanged; their
names, geometry and hidden payloads are not displayed or resolved.

A bounded task-local review preserves unique reminder identities and the existing
20-choice service limit. Unknown list shapes stay read-only. Only recognized,
local portable rows can be changed or removed. Appending to an implicit empty
list retains the existing planned alert; removing the last editable choice adds
an explicit disabled planned row so it cannot reactivate an implicit alert.
Duplicate enabled schedules and stale child-editor row snapshots are rejected
without a partial change. Future row/rule/interval/holiday/origin extension fields
survive known-setting and schedule-kind changes, matching the current service
contract. No server migration, permission or endpoint changes are introduced.

The shared list owns a private editor checkpoint. The nested settings editor
reports its unfinished fields (including text that does not yet parse) to that
same checkpoint. On access loss it hides editing controls, blocks Done/time-zone/
holiday callbacks and retains the settings sheet with verified preservation
feedback. Cancel during ordinary editing clears only the child draft; Cancel on
the shared list leaves the parent task unchanged. Changed reminder/label sheets
block interactive dismissal, and access-loss Close requires a successful flush
rather than assuming an absent first revision means no preservation failure.
Empty unchanged sheets close their unused editor session. Recovery remains a
private record/export; it never grants authority or automatically replays reminder
settings into a shared task.

Each independent repository passes 157 reminder/planning checks (eight new cases)
and 131 label/workspace/checklist/recovery regressions. The model checks exercise
portable variants, extension retention, locked rows, legacy defaults, limits,
identity/shape failures and atomic stale-input rejection. Build and native device
results are recorded in `p2-team-reminders-evidence.json`. Initial native harness
corrections use the Time Sensitive switch thumb plus a value-change assertion,
and keep phone task-editor taps clear of the isolated debug bottom toolbar.

Team rollout stays off. Source/native tests use synthetic accounts and intercepted
networking; no real task or provider configuration changes. Mac interaction and
VoiceOver, broader live account/concurrency/fault and nested holiday/time-zone
acceptance, remaining task field adapters, independent child records and the full
ranked/Px objective stay open. All user-deferred release/provider/device work
remains deferred.

Native acceptance: all five selected checks pass without skips on both iPhone
and iPad Simulator. Six reminder screenshots were inspected and retained with
result summaries in the iOS repository. The Mac app builds independently; Mac
runtime and spoken checks are not claimed. Temporary host apps/runners and stage
build/results are removed after preserving evidence; baseline simulator states
and reusable core caches are retained.


## Shared task repeat controls (rank 6, acceptance scoped)

The team task's Repeat action now opens the complete existing native recurrence
controls in a review sheet. It supports daily/custom intervals, selected weekdays,
monthly dates or ordinal weekdays, yearly dates, completion-based scheduling,
end dates, occurrence limits and the existing upcoming-occurrence preview.
Apply changes the iOS parent draft; its ordinary Save remains responsible for the
scoped durable mutation. The Mac inspector commits the reviewed fields through
its existing scoped autosave path. Cancel keeps the parent unchanged. Personal
Repeat controls keep their existing flow. Unfamiliar or malformed source rules
are shown as saved/read-only instead of being rewritten by incomplete controls.

A repeat edit captures the original rule, legacy end date, planned date/time and
zone, completion state/time and completion revision as one review context.
The native scope rejects missing/stale context; the server repeats that check
under the existing task lock. An intervening complete/reopen cycle is detected
by its revision even if its visible state returned to the original. Unrelated
notes may still merge. Completing and editing a repeat rule are separate actions;
series parent links, generations and completion bookkeeping remain server-owned.
Undo/redo carry the applied/original contexts through the existing history path.
Stable-request retries acknowledge an already accepted edit without replaying it.

The sheet registers a private recovery session before editing. Access loss stops
Apply, keeps the unsent rule with its source workspace, and requires a verified
flush before Close. Changed sheets resist interactive dismissal; a clean cancelled
sheet releases its unused session. Recovery remains a private record/export and
does not restore authority or automatically replay the rule to a shared task.

`20261024222451_team_task_repeat_edits.sql` is source-only in each repository.
It extends the existing private reviewed edit function and adds two private pure
validators. No new public endpoint, table, grant, rollout switch or hosted change
is introduced. Existing role/session/lock/retry/checklist behavior stays in the
same function. Provider, remote-delivery, old-client and distribution dependencies
remain deferred. The full ranked/Px objective is still open; scoped test results
must not be read as live multi-account, Mac runtime, VoiceOver or release proof.

Verified stage evidence: each repository passes 53 new PostgreSQL checks plus
221 existing team edit/planning/checklist checks against the new migration,
including advisor checks. Full suites ran 1,732 iOS Core cases (13 optional skips)
plus 79 Watch cases, and 1,764 Mac cases (33 optional skips), with no failures.
After one additional review-boundary test, the final focused suite passes all
191 selected cases with one optional live-concurrency fixture skipped; all ten
new repeat cases pass. Both native apps build independently. The final iPhone
and iPad runs each pass five native checks without skips, covering saved rule/
legacy end date, queue/relaunch, Cancel, private role-loss recovery, future-rule
preservation and the existing reminder-Cancel regression. Six captured images
were inspected and retained with result summaries in the iOS repository.

The initial iPad helper rejected a visible first switch by one point at its
scroll boundary; its three reveal assertions failed while subsequent state
assertions passed. The corrected helper passes the final runs. Xcode's optional
diagnostic collection after the completed failed run was stopped before its
replacement run. Exact source hashes and limits are in the stage manifests.
Owned temporary apps/runners and stage builds/results are removed after evidence
capture; baseline Simulator states and reusable Core caches are retained.


## Reviewed native shared-task deletion (rank 6, acceptance scoped)

Single shared task deletion now opens a review showing the current captured task,
project and deletion scope. The details editors and ordinary list actions use the
same explicit scoped Store path. The Mac selection command routes a single root
through a workspace sheet and registers the existing Edit-menu Undo; the iOS list
uses its existing confirmation/Undo toast. Existing independent occurrences stay
in place. Checklist items remain part of their parent and cannot accidentally open
a parent deletion review. Native team batch/child deletion and broader layout/
accessibility/live acceptance remain open rather than falling back to personal
writes.

The review retains its opening `TeamTaskEditorDraft` and one operation nonce.
Every confirmation revalidates the account, workspace/session incarnation, backend,
access fence, current role and exact saved task contents. It sends the whole frozen
source to the existing lifecycle service; it never substitutes a newer observed
row, strips unfamiliar values or truncates an oversized request. A refused or
failed durable save leaves the review, task, queue and history intact. A retry uses
the same intent; successful deletion dismisses once. Existing restore receipts,
fresh task generations, scoped history, linked-occurrence preservation and server
conversation archives own Undo. The current session's device history and current
server permissions still bound recovery; this is not a new permanent trash bin.

Unsent parent task fields, comments, checklist input and note-pin changes prevent
deletion from details. iOS paused-editor Close now also verifies an open recovery
session contains the actual latest task and extras before flushing; an absent,
closed or failed first revision cannot be mistaken for a protected edit. The
failure message offers Retry. Personal and nested Mac deletion feedback and iOS
personal list feedback now appear only after their durable commit succeeds.

When the review becomes unavailable, its old task/project content is hidden and
confirmation is disabled. The review never reacquires authority after a role,
workspace, session or backend change. No new server endpoint, migration, grant,
provider registration or hosted data change is introduced. Team rollout stays
off; all user-deferred release/provider/remote-delivery dependencies remain as
recorded. The full ranked/Px objective is still active.

Verification: both repositories pass 230 focused Core cases without skips or
failures, including eight new whole-source/authority/Undo/payload-boundary cases.
Each owned PostgreSQL fixture passes 70 conversation lifecycle/recovery checks
using the current workspace/lifecycle loader. The existing fixture still leaves
linked batch completion unclaimed. Both independent apps build. All seven native
flows pass on both iPhone and iPad: changed source, Cancel, failed save/retry,
actual TaskScreen context-menu/Undo toast, deletion/Undo/relaunch, role loss and
unsent-title/private-recovery Close. The context-menu case includes two long
XCTest idle waits but finishes successfully; no live run was restarted.

Visual inspection caught a destructive action that looked active while disabled.
Its label now uses an explicit semantic secondary color when paused. Both apps
were rebuilt; the paused-state case passes once more on each device. Eight
representative review/failure/recovery images and complete summaries are retained
in the iOS repository; the final paused images replace the pre-polish versions.
Mac runtime/keyboard, VoiceOver, wider native/account/concurrency/fault/large-text
acceptance and the remaining ranked/Px work stay open. Owned temporary apps,
runners, prepared hosts, build/results and scratch files are removed after evidence
capture. Baseline Simulator states, reusable Core caches and unrelated files stay.


## Full shared-task creation — 25 October 2026, rank 6 in progress

Shared projects now enter the complete task editor through an explicit creation
admission. iOS project + opens Add Task; Mac Quick Add opens the full inspector
as a creation sheet. Notes, planning, scoped assignment, shared labels/reminders,
Repeat and checklists remain available. Secondary Apply stages this new task;
only Add creates it. The existing Mac inspector still autosaves existing tasks.
Mac creation failures stay in a sheet-local alert and preserve the draft.

Creation captures the actor, project/team, access token, session and workspace at
opening. It requires a fresh identity and zero completion state, rejects copied
private content/bookkeeping and unsupported changes as a whole, then emits one
insert-only scoped lifecycle command. Existing task edits keep their current-row
requirement; creation cannot upgrade into PATCH or deletion after an ID collision.
Nested editors inherit the same admission. Private recovery records preserve text,
not authority. Personal writers and catalogs cannot infer a shared destination.
No migration, hosted configuration or distribution setting changed. Rollout stays
off and every user-deferred dependency remains deferred.

Both owned repositories pass 106 focused cases (eight new creation cases) without
failures/skips. Full suites pass: iOS 1,749 Core cases (13 optional skips) plus 79
Watch cases; Mac 1,781 cases (33 optional skips), all without failures. Each owned
PostgreSQL lifecycle fixture passes 89 checks with conversation regression enabled,
removes its own container, and makes no hosted change. Both Debug arm64 apps build.
Five native flows pass on each iPhone/iPad Simulator: actual project + entry,
Cancel, notes/labels staging and single insert/relaunch, role loss, and failed
Store save/retry. Eight screenshots and both summaries are retained by iOS.
The first diagnostic runs corrected two test-harness issues (AX field type and a
missing toolbar hook); final acceptance uses the fixed fixture. Failed diagnostic
collectors were stopped only after every case ended and sampling confirmed their
collector state. No active scenario was replaced or restarted.

Mac runtime/keyboard, spoken feedback, wider native field/account/fault/layout and
hosted/concurrency acceptance remain open. Moves/adoption, linked native batches,
templates/conversations/files and the rest of ranked Px remain in scope. Watch
navigation was not accepted: the native-control tool again reported the Mac locked
after the unlock reply; no repeated manual unlock was requested. Disposable apps,
runners and owned temporary builds/results are removed after evidence capture;
Core caches, baseline Simulator states and unrelated files remain intact.


## Reviewed atomic shared-task deletion — 25 October 2026, rank 6 in progress

Both apps now route shared root-task selections through an explicit review of
every selected title and project. One immutable command deletes 2–100 tasks from
one team, including linked repeat occurrences, through the existing atomic batch
service. Projects and retained creators may differ. Single-task deletion keeps its
separate review. No ordinary personal writer infers shared permission.

Opening-time rows, member nonces, group nonce and access context remain frozen.
Changed/missing/recreated tasks, role/token/session/workspace changes, duplicate or
mixed selections, selected cycles and oversized requests stop the entire action.
The review never drops a missing member, adopts a newer baseline, chunks a large
selection or falls back to single-task writes. Both list entry points detect a
previously known shared ID even after its row disappears, before any personal or
nested recursive writer can run. A failed durable save keeps every task and the
review intact. Failure messages are consumed inside the review, preserving retry.

The existing atomic local projection, persisted queue, one RPC and receipt-scoped
Undo/Redo own delivery. The actual native list check deletes a selected parent and
occurrence while retaining an unselected occurrence, then restores the selected
links with fresh generations through Undo. Queue identities and restored contents
remain exact after relaunch. Task/project text is hidden when review is paused.

Both independently owned repos pass 319 focused team Core cases with no failures
or skips, including ten new selection/custody/bounds/linked-Undo cases. Each owned
PostgreSQL fixture passes all 72 existing batch checks against the current complete
workspace loader, including rollback, permissions, replay and discussion recovery;
the fixtures remove their containers. No hosted schema/configuration or migration
changed. Both Debug arm64 apps build; the Mac test helper omits widgets.

Five new production-list scenarios plus the existing single-task failed-save
regression pass on each iPhone/iPad Simulator: linked deletion/Undo/relaunch,
Cancel, changed member, role loss, and failed save/retry. Eight screenshots are
visually reviewed and retained with both complete six-test summaries by iOS. The
initial native diagnostic used an identifier stripped by the system Menu; it now
selects the real “Select tasks” label. Its failed collectors were terminated only
after all cases ended and process samples confirmed diagnostic collection. An
initial unit fixture also needed canonical sorting of randomly generated project
IDs; no app validation was weakened. Final runs pass normally. Full non-team
suites were not repeated after the immediately preceding creation milestone.

Mac runtime/keyboard and spoken acceptance, wider native mixed/account/large-text/
fault/concurrent cases and hosted lifecycle acceptance remain open. Task moves/
adoption, templates/conversations/files, independent child records, remaining
Watch/Wear OS and the full ranked Px objective stay in scope. Team rollout remains
disabled; every user-deferred release/provider/remote-delivery dependency stays
deferred. Owned test apps/runners and temporary builds/results are removed after
evidence preservation; baseline Simulator states and Core caches remain intact.


## Shared-task move service and client recovery — 25 October 2026, rank 6 in progress

Both repositories independently own a disabled same-team task-move service and
its typed client/recovery foundation. This stage does **not** add a native Move
screen or complete task moves, personal-project adoption, or rank 6.

A review identifies the exact source/destination, literal task, destination
visibility, discussion count and assignments to clear/restore. Its short-lived
server proof binds task/discussion epochs and the workspace-access boundary.
The transaction preserves identity, creator, generation, notes and other task
fields; moves comments with incremented revisions; retains mention read history;
updates custody; and clears section/root/child assignments. Undo/Redo restore
reviewed placement through encrypted, 30-day recovery with existing cleanup and
account-removal lifecycles. Receipt/key locking and a final key check prevent
using a recovery copy erased while Undo waited. Provider-bound attachments stop
for their own transfer review; cross-team moves and personal destinations stop.

The client saves one exact IDs/proof-only request privately per account/server
before sending. Lost replies, write/remove faults, foreign acknowledgements,
account switches and another window's changed request preserve safe recovery.
An expired saved request may still reach the server for acknowledgement of a
previously accepted action; the service rejects its first application after
expiry. No ordinary task writer gains a shared-project move path. Account
removal erases the separate move vault.

Each repo passes 334 focused team Core cases (15 new move cases), 90 owned
PostgreSQL move checks, and the existing 72 batch checks with this migration
loaded. No focused failures or skips remain. Both isolated Debug arm64 apps
build; the Mac helper omits its widget extension. The batch regression exposed
an unsafe trigger branch for linked-task detach updates; type-specific nested
branches fix it and the complete 72-case run passes on each current schema.
Advisors report no new warnings; known fixture-policy performance notices remain.

Next: native reviewed destination selection with queued-edit/session/workspace
fencing, durable retry/clear, fresh cache reconciliation and linked Undo/Redo;
phone/tablet/Mac layout, runtime, keyboard and spoken acceptance; broader hosted
lifecycle/concurrency acceptance; and a separately reviewed personal-project
adoption workflow. Per-task provider file custody, templates/conversations/files,
independent child records, remaining Watch/Wear OS and wider Px work stay open.
No hosted migration/configuration or rollout switch changed. All user-deferred
release, older-client rollout, remote-delivery, OAuth/provider and real location
dependencies remain deferred. See `p2-team-task-move-foundation-evidence.json`.


## Reviewed native shared-task moves — 25 October 2026, rank 6 in progress

Both apps independently own the native same-team Move flow from existing task
inspectors and single-task list moves. The destination picker admits only active,
writable projects in the same team. Confirmation identifies the literal task,
source/destination, destination visibility/audience, discussion count and assignment
changes. Opening-time task contents, workspace/session and access token are frozen;
changed source/access or queued local writes stop preparation. Existing personal
writers remain separate. Mixed/shared batches, cross-team moves and personal-project
adoption are not silently treated as a sequence of single-task actions.

Recent moves are reachable from task-list options and team-project management.
One private atomic envelope owns pending delivery and the 20 most recent move
chains. Accepted delivery cannot erase its retry request before durable history is
saved. Reviewed Undo/Redo stay in one chain across relaunch; a delayed earlier
acknowledgement cannot rewind later history. This is explicit move history, separate
from the app's general local Undo/Redo stack. It contains IDs/proofs rather than
notes or discussion text, preserves the previous one-command journal's exact nonce,
and participates in account-removal fencing and cleanup. Clearing a retry keeps
accepted history and does not cancel or undo an accepted server move.

A confirmed receipt triggers a fresh normal workspace sync rather than projecting
an old task reply over local changes. Refresh failure keeps accepted history and
offers explicit refresh. Closing an uncertain result keeps the saved retry;
closing a confirmed screen completes its inspector/list presentation once.

Both repositories pass 340 focused team Core cases, including 21 move cases.
The new cases cover atomic journal failure, old-envelope migration, linked durable
history, stale acknowledgements, scoped removal, corrupt/foreign history and full
source/access/queue admission. Both isolated Debug arm64 apps build; the Mac helper
omits widgets. There are no schema or hosted-configuration changes in this stage;
prior owned move/batch PostgreSQL evidence remains in the foundation evidence.

Six scenarios pass on each iPhone/iPad Simulator through real native controls:
actual-list selection and Move, Cancel, changed source, role loss with hidden review
contents, lost reply/relaunch/exact-nonce retry, and move/Undo/Redo/relaunch with
normal Done cleanup. The native peer is a separate file-backed synthetic server,
with its accepted request identities checked independently from the actual saved
Store cache. All HTTP stays intercepted. An initial exact-Undo assertion exposed an
omitted section field in the fixture; seeding SQL's explicit null fixed the fixture
without weakening the whole-record comparison. Final runs pass all six cases.
Screenshots and complete summaries are retained by iOS. No Mac runtime, genuine
hosted or spoken acceptance is inferred from these Simulator checks.

Next: personal-project adoption with a separate ownership/audience/contents review;
shared batches and broader task-move history/keyboard integration; Mac runtime and
keyboard, spoken/large-text/dark/account-switch/private-save and simultaneous-window
acceptance; provider-bound per-task file transfer, templates/conversations/files,
independent child records, remaining Watch/Wear OS and the rest of ranked Px.
Rollout remains disabled. All user-deferred release, older-client, remote delivery,
OAuth/provider and physical-location dependencies remain deferred. Owned apps,
runners and temporary builds/results are removed after evidence capture; baseline
Simulator states and Core caches stay intact. See `p2-team-task-moves-native-evidence.json`.


## Project-adoption ownership boundary — 25 October 2026, rank 6 in progress

Both repositories independently own the source-only transaction boundary needed
for personal-project adoption. The transfer API/client/native screens are still
unimplemented; this milestone does not complete adoption or rank 6. The full
intended protocol, access decisions, forest/linked-work preservation and required
commit ordering are recorded in `TEAM_PROJECT_ADOPTION.md`.

Identity-only per-row epochs detect authored edit/revert and project delete/reuse
without serializing unrelated task edits on one project counter. Private deferred
realm tickets reject a personal task edit/insert, discussion, subproject or pending
invitation acceptance that would otherwise finish after team custody changes.
Shared/exclusive try-locks avoid waiting while holding rows needed by the other
side. Unrelated projects keep saving. The private binding writer can approve only
its own transaction's deliberate cutover, never another writer's ticket.

Exact private project/parent/visibility/folder scopes permit a future reviewed
forest admission. Deferred placement verification still checks the final binding
and parent after temporary scope rows are erased. Personal invitation retirement
skips automatic assignment clearing only in an exact private adoption scope; this
keeps eligible assignment provenance intact. The future service must explicitly
compute and apply every ineligible assignment change. Ordinary collaboration
removal still clears departed assignees, and native owner/member team-project
creation remains accepted. No new public adoption or scope-authority API exists.

Each independent owned PostgreSQL fixture passes 52 new ownership-boundary checks,
90 existing task-move checks, 95 project-hierarchy checks and 72 batch checks with
this migration loaded: 309 checks per repo, no final failures. The focused fixture
loads actual assignment-provenance code and inspected invitation/assignment-cleanup
definitions, and verifies mention read epochs and personal Auth cleanup. Advisors
show no new warning categories beyond known auth-initplan policy notices. Current
app code is unchanged, so no new native build/runtime acceptance is claimed.

The first diagnostic fixtures corrected a missing-row JSON-null helper and an
unsupported direct comment write by the authenticated fixture role; the latter is
now explicitly a privileged synthetic write, not a claimed native API. That early
control failure exposed a test-helper cleanup gap. Cleanup now removes its owned
container even when the control session has already failed, retains SQLSTATE and
preserves the primary error. The one leaked diagnostic container was inspected and
removed. A dedicated failed-control case verifies the repaired helper.

Next is the reviewed inspect/review/adopt controller with exact immutable manifests,
collaborator/effective-access decisions and durable retries, followed by native
review/recovery on both platforms. Storage custody, paused personal integrations,
shared batch/history/keyboard work, remaining Mac/spoken/layout/account/window and
hosted acceptance, independent child records, remaining Watch/Wear OS and wider Px
remain open. No hosted schema/configuration or rollout switch changed. Every
user-deferred release, general older-client, remote-delivery, OAuth/provider and
physical-location dependency stays deferred. See
`p2-project-adoption-fences-evidence.json` for exact scope and cleanup.


### 2026-10-25 — Reviewed project-adoption service (source only)

Implemented inspect/review/adopt for owned personal project branches. The review
binds all selected descendants, complete content/row epochs, destination ancestry,
team/access state and explicit collaborator decisions. It distinguishes retired
personal grants from access supplied by team visibility/admin status and counts
exact ineligible root/checklist assignment clears. Inline and nested attachments,
completed work, archived projects, discussions, mention read history and eligible
assignment provenance remain accounted for; there is no automatic custody Undo.

The atomic commit keeps original identities/creators, closes personal invitations,
places the branch under the reviewed team parent/folder/visibility and saves an
identity-only durable receipt. Exact retries work after expiry, access loss,
disabled rollout and subsequent task moves without rewinding later work. Source
changes, forged decisions, request collisions and live-session loss are rejected.
A disabled-by-default `native_project_adoption_enabled` flag gates new commits.

Personal service authorization rechecks custody after its row lock, and personal
webhook capture excludes team custody and exact adoption scopes, including global
subscriptions enrolled later. Old snapshot-isolated personal writers cannot
bypass the commit ownership check. These are cutover safeguards; broader deferred
old-client rollout work is still separate. No provider/network/rollout is enabled.

Both independent fixtures pass 148 SQL checks with real email/domain, webhook/
outbox, hierarchy, assignment-provenance and guarded task-move migrations loaded.
Checks include mid-transfer rollback, a late old-client task, a waiting personal
service caller, normal post-adoption moves/workspace refresh, uppercase legacy
assignees, a full 1,000-collaborator transfer, 32 MiB contents/256 KiB command bounds,
quotas and exact receipt recovery. Advisors add no new warning categories. No new
native app build/runtime or hosted acceptance is claimed. Test sessions and owned
artifacts are cleaned; details are in `p2-project-adoption-service-evidence.json`.

Still required: private native command/recovery, premium Mac/iPhone/iPad review
screens and draft-preserving refresh; explicit file-custody and personal integration
pause/retarget adapters. Affected transfers currently fail atomically with a clear
review requirement. This does not complete rank 6 or the wider Px scope. Remaining
shared batch/history/keyboard, Mac/spoken/layout/account/window/hosted acceptance,
independent child records, Watch/Wear OS and all other open plan items remain open.
Every user-deferred release, provider and physical-device dependency stays deferred.


### 2026-10-25 — Native project-adoption review and recovery (source)

Implemented each app's independent typed adoption client, private recovery journal
and native branch/location/contents/access/final-review flow. The UI defaults to
private visibility, requires an explicit decision for each accepted collaborator,
shows resulting effective access, affected descendants, own/inherited archive
outcomes and exact assignment/invitation counts, and explains custody/Undo before
confirmation. Unsupported file-custody and integration cases remain blocked.

Requests persist only UUIDs, role choices, proofs and expected receipt counts/IDs
before sending. No task text, project names, invitation emails or file bytes enter
the private retry. Account/origin/process/removal/lease fences protect it, and the
adoption envelope supports 1,000 decisions while other reviewed team commands keep
their prior default bound. Lost applied replies retry the exact same request after
relaunch/expiry; foreign/stale/closed callbacks and failed cleanup keep recovery.
Unreadable recovery blocks fresh authoring. An account-level Saved project transfer
entry remains reachable after team-access loss or ordinary team navigation changes.

New authoring requires current owner-only personal custody, an empty outbox, no
unresolved sync conflicts and closed affected task editors. Context/access/content
changes invalidate the review. Accepted replies invoke normal workspace boundary
refresh and draft/Recovery handling; they never overwrite tasks with old response
contents. The UI provides an explicit success focus target and recovery/refresh
controls. Native HTTP uses the exact operation/body RPC contract, current session
fencing, no-store/cookie/redirect protections and a streamed 3 MB response cap.

Both repos pass 361 focused Team Core checks (21 adoption cases), with no failures
or skips, using independently generated actual SQL inspect/review/adopt fixtures.
Both isolated Debug app builds pass with signing disabled: iOS Simulator and Mac.
No app was installed/launched, no system settings or hosted configuration changed,
and no installed UI/layout/keyboard/spoken/live-Keychain acceptance is claimed.
Owned temporary builds are pruned; baseline Simulators and Core caches are kept.
See p2-project-adoption-native-evidence.json for exact checks and cleanup.

Next is installed native acceptance and the file-custody/personal integration
pause/retarget adapters, followed by genuine hosted acceptance. This does not
complete rank 6 or the wider Px scope. Shared batch/history/keyboard, remaining
Mac/layout/account/window/accessibility/hosted checks, independent child records,
Watch/Wear OS and other open plan items remain open. All user-deferred release,
provider and physical-device dependencies stay deferred. Rollout remains disabled.


### 2026-10-25 — Installed project-transfer recovery proof and Account entry fix

The iOS isolated host now passes five distinct installed cases on both iPhone and
iPad across corrected runs: archived branch review/commit with normal sync, Cancel,
local-source invalidation, lost applied reply with relaunch/Close/reopen/exact retry,
and the same expired request after simulated destination-access loss. Saved-state
assertions verify task text/completion preservation, assignment clearing, an empty
queue and removal of inaccessible cached work. The peer is SQL-contract-derived
and intercepts all HTTP; it is not live hosted adoption. Real Simulator Keychain
works with Xcode local Simulator signing; release signing remains deferred.

Relaunch exposed an actual empty SwiftUI Group preventing the recovery-loading task
from running. Each app now has a stable Account Project transfers entry whose label
changes when a saved transfer needs attention. It remains reachable without normal
team navigation. Both independently exported archived/member-owned contracts pass
361 Team Core checks per repo, and both isolated Debug app builds pass. The Mac app
was not launched in this batch; no Mac OS Keychain/native/spoken acceptance is
claimed. Diagnostic test failures and corrected runs are retained explicitly in
p2-project-adoption-installed-evidence.json rather than called green suites.

Owned apps/runners and temporary roots are cleaned after evidence capture; baseline
Simulators and Core caches are preserved. No real tasks, system settings, hosted
configuration or normal rollout switches changed. Next: remaining Mac/native
acceptance and file-custody/personal integration pause/retarget adapters, then hosted
acceptance. Rank 6, remaining shared batch/history/keyboard, independent child
records, Watch/Wear OS and the wider Px work remain open. Every user-deferred
release/provider/device dependency remains deferred.


### 2026-10-25 — Project connection cutover coordination (source only)

Added the coordination required before reviewed personal email/webhook pause or
retarget during adoption: closed connection-owner Auth cohorts, nonblocking account
and row fences, deferred personal-realm tickets and authored binding epochs. Review
now fingerprints affected queued events and counts active send permits without
exposing payloads, endpoints or credentials. Dispatcher/ack contention is a review
conflict; unrelated connections and project edits still work.

A private identity-only permit survives connection revocation, queue cancellation
and pruning for 60 seconds after first final write authorization, covering the
current 55-second worker/10-second socket deadlines. Existing authorized leases are
conservatively seeded at migration. A live permit blocks new custody cutover, while
an exact already-applied receipt still confirms. Finite deadlines and bounded,
nonblocking 256-row cleanup avoid unbounded work while service locks are held.

Both independent fixtures pass 55 new SQL cases, all 148 existing adoption cases
and 21 client Core cases with regenerated actual SQL contracts. Advisors show only
known fixture auth-initplan notices. No current app source/build/runtime, system
setting, hosted schema/configuration, real task or rollout switch changed. Owned
containers and temporary artifacts are cleaned; Core caches remain intact. See
p2-project-adoption-connections-evidence.json for exact scope and cleanup.

Next: explicit policy/native review for personal connection pause/retarget, queued
update retirement and destination reauthorization, plus file custody and remaining
Mac/native/provider acceptance. Those transfers remain blocked; this does not
complete adoption, rank 6 or the wider Px backlog. All user-deferred items remain
deferred.


### 2026-10-25 — Reviewed connection pause policy and native consent

Implemented optional explicit personal-connection pause during project adoption.
The reviewed action and five exact counts are proof-bound, persisted privately and
confirmed in the receipt. It keeps personal addresses and verified project hooks
paused, cancels unfinished project setups, retires only selected queued payloads
and preserves global/unrelated settings and work. No credential is retargeted into
the team. File/wire/stale/late-fault refusal remains fully atomic. Exact retries
confirm original counts without rewinding later changes; legacy no-policy recovery
remains compatible.

Both native clients default consent off, explain the effects, show accessible
label/value count rows and expose the saved actions during recovery. Both repos
pass 55 new SQL cases, 148 adoption regressions, 55 fence cases and 367 Team Core
checks, including 27 adoption cases and an actual SQL connection-settings receipt.
Both isolated Debug builds pass. Installed iPhone/iPad default light flow passes
consent gating, numeric accessibility metadata, confirmation and normal refresh
with a SQL-derived network-intercepted peer. No Mac runtime/Keychain, spoken or
hosted/provider acceptance is claimed. Final queue status uses an existing enum
value so old edge/client metadata validation continues working.

Source rollout/configuration and real user data remain unchanged. Owned test apps,
containers and temporary builds are cleaned after evidence capture. See
p2-project-adoption-connection-policy-evidence.json for exact runs and limitations.
Next: personal settings destination/resume/verification gates, supported destination
reauthorization/retarget, persistent busy-send preparation, file custody and the
remaining native/hosted acceptance. Stage scroll/focus and wider Px items remain
open. All user-deferred release/provider/device dependencies stay deferred; rank 6
and adoption are still in progress.


### 2026-10-25 — Personal connection destinations and recovery controls

Personal email and webhook setup now filters team/unconfirmed destinations and
retains personal collaborator projects. Historical team custody remains excluded
after access loss. Existing rows explain why a destination cannot resume; Resume,
verification and email rotation are disabled while Pause/Revoke/history and exact
saved-action recovery remain available. “All personal tasks” accurately excludes
team projects. Stale composer selections cannot create a new connection.

See p2-personal-connection-settings-evidence.json for independently run Core checks
and the Mac Debug compile. No new installed Mac, spoken or hosted/provider
acceptance is claimed. Supported retarget/reauthorization, file custody, persistent
busy-send preparation and the remaining Px/native acceptance stay open. Normal
rollout and all user-deferred distribution/provider/device items remain deferred.


### 2026-10-25 — Reviewed atomic shared planning

Shared date/removal and priority selection actions now open a native contents
review before saving. A frozen 1–100-task command persists and sends as one batch,
with complete source checks, one atomic local projection and linked Undo/Redo.
The service applies supported planning fields through the established guarded
editor; a busy/changed/unauthorized member or late fault refuses the whole group.
Already-correct date members remain in the selection. Personal task flows retain
their existing behavior. No rollout or hosted schema is enabled.

The Mac root’s new sheet uses a small presentation modifier to keep the root view
within the compiler’s type-checking budget. See p2-team-planning-batches-evidence.json
for exact checks/build status and limitations. Installed native, keyboard/spoken,
large-text/dark/contrast and hosted multi-actor acceptance remain open; deadline/
estimate bulk entry and other shared bulk commands are still separate work.
All user-deferred release/provider/device dependencies stay deferred, and the
full rank-6/Px objective remains active.


### 2026-10-25 — Shared planning sparse-row compatibility

Remove Date now validates older saved rows whose unused clock fields are absent,
while keeping every frozen source field and the whole-row/access checks intact.
The regression was reproduced before the fix; SQL checks verify null semantics,
all-member removal and unchanged notes. Debug-only review controls are reserved
for the isolated team-editor host. No ordinary rollout, hosted schema or Mac app
launch occurs in this stage. See p2-team-planning-selection-native-evidence.json for final
Core/build and phone/tablet acceptance scope; Mac runtime/spoken and broader Px
work remain open. All existing user deferrals remain unchanged.


### 2026-10-25 — Phone/tablet planning acceptance and Mac contract verification

Four distinct installed iPhone/iPad scenarios now verify reviewed priority Cancel/
Save/Undo and exact relaunch state, Tomorrow and Remove Date, whole-selection stale
source refusal and local-save failure/retry. Default-light review/error/refusal
screenshots are inspected. This uses the isolated synthetic iOS host and normal
Store/private cache with intercepted HTTP; it is not Mac runtime or hosted/Auth/
Keychain delivery proof. Both repo-owned contracts pass 422 focused Core checks,
67 real SQL planning cases and app builds. The nullable-clock compatibility fix
keeps original frozen source fields intact.

See p2-team-planning-selection-native-evidence.json for the successful case mapping, the
retained initial phone assertion diagnostic and source/cleanup details. Mac
window/runtime, keyboard/spoken, large-text/dark/contrast, live acceptance and
bulk deadline/estimate entry remain open. User-deferred work and the wider Px
objective retain their scope; rollout remains disabled.


### 2026-10-25 — Bulk deadline and estimate choice/review

Shared deadline/estimate actions now capture opening source/access admission
before presenting native pickers. Explicit Set/Clear, numeric validation, minute
presets and original-value previews precede the existing complete selection
review. Back retains the typed choice; Cancel saves nothing; Save/Undo keep the
whole shared command. Deadline rows retain their planned-date context.

Personal selections gain estimates through the existing personal selection
writer, with a captured workspace/session/origin and current source/custody check.
Mac list, inspector selection and Task menu entries are independently owned.
Validation stays in Store rather than exposing its private cache-readability flag.
The focused Core suite passes 493 tests per repository; final five installed
iPhone and iPad scenarios pass independently. The Mac build passes; this is not
an installed Mac runtime claim. No schema or rollout change occurs.
See p2-bulk-planning-pickers-evidence.json for
scoped Core, build and installed iOS evidence; Mac runtime/window, keyboard/spoken,
larger text/dark/contrast and genuine hosted acceptance remain open. The wider
Px plan and all user-deferred release/provider/device dependencies remain active
or deferred as agreed.


### 2026-10-25 — Reviewed shared assignments

Task menu, list selection menu and multi-task inspector now open a frozen shared
assignment picker. Eligible choices are the intersection across selected projects;
review shows the complete cohort and named choice or Unassigned before one atomic
Save/Undo. The Mac owns its model, presentation and menu code independently.
Normal deadline/estimate and personal selection paths retain their contracts.
Both repositories pass 96 isolated SQL and 502 focused Core checks; the final
23-case batch rerun includes sparse assignment Undo. Source/advisor/Core/build
and installed iOS acceptance scopes are recorded in
p2-shared-bulk-assignment-evidence.json. Compilation is not Mac installed/runtime,
spoken or wider account/window acceptance. Rollout, full rank 6/Px and user-deferred
release/provider/device work remain open or deferred as previously agreed.


### 2026-10-25 — Shared workflow capture into private templates

Shared-source template capture now reviews the full reusable contents and editable
name before Save. Portable shared labels, including nested labels, no longer pass
through the personal catalog. Opening source/access admission is rechecked before
the existing private-template save, with a hidden preview when it becomes stale.
The Mac owns its Core, view, Store and Undo path independently. See
p2-shared-template-capture-evidence.json for exact Core/build and installed iOS
scope; compilation is not Mac runtime/window or spoken acceptance. Team-owned
templates, shared run destinations and wider rank-6/Px work remain open. Existing
user-deferred release/provider/device work stays deferred.

Capture verification: 87 focused Core cases in each repository, both independent
app builds and three installed scenarios on each iPhone/iPad pass. Four standard-
light preview/refusal screens are inspected; the wider gates above remain open.


### 2026-10-25 — Team template library service foundation

The Mac repository owns its gated library migration and fixture runner separately.
Owner/admin curation, full-member reads, versioned bounded storage, stable receipts,
revision-checked edits/deletion, coherent catalog continuation and account/team
cleanup pass 96 isolated SQL/advisor checks. See
p2-team-template-library-service-evidence.json. No app code changed in this stage;
Core/native transport, premium library/review/recovery UI and real runtime/live
acceptance remain next. This does not close the full team-template or Px scope.
No deployment or hosted gate change occurred; user deferrals remain unchanged.


### 2026-10-25 — Team template catalog client foundation

Each app now owns its typed library metadata/page/detail reader, bounded private
HTTP transport and fenced browser. All pages must share the original account,
origin, team, role/state and library revision before any names are published; a
workspace boundary surrounds the read. Failed continuations, late account replies
and overlapping older refreshes cannot publish stale contents. Invalidation clears
metadata and definitions synchronously. Opaque future documents remain intact and
read-only; current definitions require the full workflow validator before use.

Both repositories pass 50 focused Core checks (23 library, 27 adoption regression),
with no failures or skips. Independent Debug app builds pass with signing disabled,
including an incremental build after the last source edit. HTTP checks exercise the
actual Backend with an intercepted synthetic transport. Initial fixture failures
and final logs are retained in team-template-reader; exact scope/hashes are in
p2-team-template-reader-evidence.json. No app was installed or launched, no hosted
service/configuration or real data changed, and the library stays disabled. Owned
temporary builds/logs were removed after proof retention; source caches and the
baseline Simulators were preserved. Native Watch controls still reported the Mac
locked, so no new Watch navigation acceptance is claimed.

Next: encrypted publication/replacement/deletion recovery and exact retries, then
premium native library/detail/publication review and private-copy/export flows.
Installed layout, spoken, account/window and hosted acceptance, shared run
destinations and the wider ranked Px scope remain open. All user-deferred release,
provider and physical-device dependencies remain deferred.


### 2026-10-25 — Native team template publication and private recovery (source)

Each app independently owns the library catalog/detail, audience/contents/name
publication review, replacement/rename and removal review, plus Account recovery
for an original request after team/rollout loss. Current team audience and catalog
are read inside the same boundary. Unsupported future definitions remain read-only
and can be removed using reviewed metadata. Saved request text/definitions are not
shown from recovery without current access. Team deletion now explains library
removal and preservation of prior copies/work.

The exact supported definition/name, original CAS revision and stable nonce persist
before HTTP in one bounded AES-GCM file per account/origin. Only the existing backup
key is in Keychain; full definitions do not enter the small Keychain command store.
The private directory/file use 0700/0600 permissions, file protection and backup
exclusion. Account removal removes the nested files/key and blocks recreation.
Lease, process/removal and session fences preserve uncertain requests; retries do
not rebase or mint identities. Stop retrying explicitly does not undo server work.
Replayed receipts acknowledge the original change without claiming current contents.

Source review adds a single-submit guard and checks the frozen name/document again
after durable save. Account/phase/access changes mask the native review, and source
changes refuse the send. Draft state remains in memory while its review is paused.
These UI interactions still require installed acceptance; compilation is not proof
of buttons, layout, focus, speech or multiple-window behavior. Private-copy/export
and shared run destination flows also remain open.

Both repos pass 106 focused Core tests (22 command, 24 catalog, 27 adoption,
22 project management and 11 account-removal), with no failures/skips. Independent
arm64 Debug app builds pass with signing disabled, including final incremental
builds after the last source edit. Actual Backend requests use intercepted synthetic
URLSession peers; journal tests use real temporary files and synthetic keys. Initial
test-fixture compilation and build-argument mistakes are retained alongside final
proof in team-template-publication; see p2-team-template-publication-evidence.json.
No app was installed/launched, no real data, hosted schema/configuration or rollout
changed. Owned temporary builds/logs were pruned after retention; source caches and
baseline Simulators remain. Next is isolated installed review/recovery acceptance
and private-copy/export, then shared run destinations and the wider ranked Px work.
Every user-deferred release, provider and physical-device dependency stays deferred.


### 2026-10-25 — Team template copy/export and installed client acceptance

Both independent apps now offer full-content private-copy/export review, with a
fresh exact-definition/account/origin/workspace/session check before creating an
artifact. Private copies get a new personal identity and preserve the definition;
portable exports remap internal references through the existing workflow format.
A changed/removed/unsupported definition cannot silently become an artifact.
“Review latest definition” preserves the typed name and the reserved private-copy
identity while explicitly presenting the latest supported contents. Errors and
refresh actions are at the top, the name keyboard closes before save, and status
has an accessibility focus target. iOS revokes temporary exports on context loss
or dismissal; Mac uses its native file-save panel and normal private-template Undo.
Publication source selection now has a full-row active area and keeps custom names.

Each repository passes 111 focused Core tests: 31 catalog/transfer, 22 command,
47 workflow and 11 account-removal cases. Both arm64 Debug app builds pass. The
installed iPhone/iPad app uses only an exact reserved DEBUG namespace and a local
synthetic HTTP peer. Four scenarios are accepted per device: changed private source
and revoked access; real local encrypted-request lost-reply/relaunch/retry plus
replacement/removal; copy/export preparation/temporary cleanup/future read-only
behavior; and external definition change, refusal, preserved-name refresh and save.
The final transfer-only rerun passes two cases per device after setup/presentation
changes. Earlier signed full runs pass 4/4 on phone and 3/4 on tablet; the tablet
setup failure is retained and superseded by the external-peer update case. We did
not rerun unchanged curation scenarios after the transfer-only presentation fix.

Signing-disabled Simulator builds lacked the identity entitlements needed by
Keychain and count only as compile evidence. Signing-enabled builds plus the
existing development identity pass: actual installed signatures/Mach-O identities
and main/debug binary hashes match the final products. The cold app relaunch
restores the original request through the normal Simulator Keychain/file path;
no client pending request or receipt is injected. An iPad fixture change control
missed its action; the final test changes the synthetic provider file directly,
which represents an external teammate edit. Initial failures and final reports
are retained in team-template-transfer; scoped proof is in
p2-team-template-transfer-evidence.json. Curated phone/tablet screenshots are saved,
including the now-visible error/refresh card. No real tasks/accounts, hosted
schema/configuration or rollout changed.

Export acceptance covers preparation, portable file contents and cancellation
cleanup, not external share-provider delivery. Mac runtime/dialog/keyboard/spoken/
window and native account-switch acceptance, hardware protected storage, genuine
hosted acceptance, shared run destinations and wider ranked Px remain open.
Source build caches and baseline Simulators are preserved; owned temporary builds/
results/source copies are removed after evidence retention, and both isolated
app/runner installations are closed/uninstalled. Release/distribution, remote
reminders, old-client rollout, provider and physical-device deferrals are unchanged.

### 2026-10-25 — Template transfer validation and native share cancellation

Copy/export names now show a bounded-name validation hint and disable submission
before any read when empty or too long. Both independent Debug app builds pass.
The installed signed iPhone/iPad checks pass invalid-name/no-extra-read coverage,
and the final native share test passes open/cancel/reopen/cancel, byte preservation
and Done cleanup. Earlier test failures were automation assumptions: iOS 27 uses
an outside-dismissed popover, and a failed prior run left a different temporary
export directory. The corrected test tracks exactly its newly created directory.
Retained logs include those failures; no production cleanup bypass was added.

The system share previews were inspected on both sizes. Installed app signatures
and binary hashes match the tested products. External share-provider delivery,
Mac runtime/accessibility, shared run destinations, genuine hosted acceptance and
the wider Px goal remain open. No hosted service/configuration, rollout or real
user data changed. See p2-team-template-handoff-evidence.json. Owned temporary
builds/results and isolated app/runner installs are removed after retaining proof;
repo build caches and baseline Simulators remain intact.

### 2026-10-25 — Shared workflow run materialization (Core foundation)

A frozen shared-run plan now prepares new team project hierarchies or task/section
runs into an existing project, without returning personal write mutations.
It preserves sections, explicit group order, relative schedules and label spelling
(including differing case and child-specific labels), removes history through the
existing workflow instantiator, and gives shared checklist children stable fresh
completion epochs. Per-task/checklist and complete payload limits are checked.
Existing-project previews require scoped editor/manager access, current revision,
archive/hierarchy metadata and an active unpaused team. New projects include their
reviewed team/private visibility. Source, destination, team revision, workspace
generation and session are frozen and compared in full on explicit revalidation.
Readable sources in another team retain their separate source scope.

Both independent Core packages pass 102 focused cases (10 shared-run, 47 workflow,
31 template-library and 14 checklist). No app runtime, SQL/service or shared-save
acceptance is claimed here. The plan is not exposed in the app yet: the atomic
service, durable reviewed command/retry and native destination/content review
must be connected before it creates shared work. Folder/subproject destination
choices and existing destination order admission also remain part of that work.
See p2-team-workflow-run-plan-evidence.json and TEAM_WORKFLOW_RUNS.md. Rollout and
the full rank-6/Px goal remain open; all user deferrals remain unchanged.

### 2026-10-25 — Atomic shared workflow service (source, disabled)

Both repos own the same independently generated workflow-run migration. One
account/session-checked request creates the complete project branch, sections,
tasks and actor list order in one transaction. Current readable source contents,
shared source revision and destination/team/parent revisions are rechecked.
New team/private branches support folder and parent selection. Existing sections
append without reordering prior sections. List-order compare-and-append preserves
later work; stale reviews fail without partial creation. Permanent identity and
nested-receipt checks prevent existing work from being claimed as a fresh run.
A private HMAC receipt acknowledges exact retries without restoring deleted work
or overwriting later edits; source/destination access is checked again on replay.

Independent isolated PostgreSQL suites pass 93 checks per repo with advisors,
including duplicate/concurrent requests, role/source/archive changes, lost-reply
retry, late-failure rollback, quota, folders/hierarchy/sections, large order/note
payloads, no direct private-table reads and soft-team-deletion receipt cleanup.
Both Core packages pass 105 cases and arm64 Debug app builds succeed (unsigned
compile evidence only). A workflow emitted by each repo's actual Swift planner
is accepted by its database fixture, including relative dates and checklist
metadata. This caught and corrected a checklist wire mismatch: shared children
exclude whole-task-only fields; repeating children are refused without changing
the saved template rather than losing their repeat rule.

Only hosted column/primary-key metadata was read to verify inspected base types;
no user rows or hosted schema/configuration changed. SQL fixtures are synthetic
and removed. The new service defaults off and has not been deployed. Durable
client request storage/receipt handling, native destination/content reviews,
runtime/account-window/spoken and genuine hosted acceptance still remain.
See p2-team-workflow-run-service-evidence.json. Shared runs, rank 6 and wider Px
remain open; all release/provider/device deferrals remain unchanged.

### 2026-10-25 — Durable shared workflow client requests (source)

Both apps now own a typed workflow command, exact identity/generation receipt
validator, encrypted per-account/origin recovery file and reviewed retry model.
The original request is durable before dispatch. Relaunch and lost-reply retry
keep its original identity, content, dates, destination and list-order baseline.
Another window's request cannot be overwritten or cleared; stopping retry does
not undo cloud work. A late account/window reply leaves recovery on disk and
clears presentation. Invalid receipts and failed cleanup retain the request.

The file uses the existing backup device key and account-removal/process locks.
Its plaintext is not stored in Keychain or written to disk. The shared file engine
retains the existing template filename, prefix and AAD: an independently sealed
legacy ciphertext compatibility test passes. Store factories and account-removal
cleanup are connected. The dedicated HTTP endpoint uses no-store, no cookies,
redirect refusal and a streamed 1 MB reply cap, exact account/origin/session
checks and sanitized errors. Tests exercise actual URLSession interception and
reject a reply after Backend sign-out; no genuine hosted call is made.

Each Core suite passes 137 focused cases (13 command/recovery, 13 run planner,
22 existing template-command, 31 library, 47 workflows, 11 account removal).
Both arm64 Debug app builds pass with signing disabled. This is compile and
synthetic transport/model/file acceptance, not native save/Keychain/spoken/window
acceptance. Native destination/content/recovery views and actual Store runtime
flows remain to be connected and verified. The prior isolated service proof
still stands; SQL, hosted schema/configuration and rollout are unchanged.
See p2-team-workflow-run-client-evidence.json. Rank 6 and wider Px remain open.


### 2026-10-25 — Native reviewed shared workflow runs (in progress)

Both apps independently own the destination/content/recovery screen. Shared and
private templates enter the same explicit review: team and editable project, or
new project audience/folder/parent, optional start date, complete generated
projects/sections/tasks/checklists, notes, labels, dates and recurrence. Creation
requires acknowledgement of the contents and audience. A fresh source, coherent
paginated destination catalog and current actor order are checked again before
the immutable request is saved and sent. A changed source/access/order refuses
that send and requires another review. No shared work enters the private writer.

Account/session/workspace and inactive-scene changes mask the review. Saved
requests have a separate entry in Account and remain recoverable without new
shared-authoring admission. Retry confirms the original request; Stop retrying
explains that already-created cloud work is retained. Successful confirmation
asks Store to sync. Actual hosted Store refresh and Mac runtime/spoken/account-
window acceptance remain open; the local native peer does not prove them.

Fresh private-source and actor-order reads use filtered REST requests with
no-store, cookies disabled, redirect refusal, bounded streaming and current
account/session checks. Destination reads publish only complete, coherent pages;
unknown archive/hierarchy/name metadata cannot become a selectable destination.
See p2-team-workflow-run-native-evidence.json for final verification scope.
Rank 6 and wider Px remain open. No hosted schema/configuration or rollout changed.


Verification: each independent Core suite passes 146 cases (including nine fresh
read/catalog tests); both final own arm64 Debug app builds compile. Four native
scenarios pass on each signed iPhone/iPad Simulator host. After adding the
online/sync-idle/no-pending-edit authoring guard, the complete creation/lost-reply/
termination/relaunch/Account-entry/exact-retry scenario passes again on each
device. Recovery remains available while new authoring is paused. The original
request is unchanged, with one synthetic receipt and two service calls. Source
and final installed binary/signature parity are recorded. Light-mode review,
warning, recovery and confirmation screenshots were inspected. This does not
prove genuine cloud Store sync, Mac runtime, spoken output or hosted permissions.

The first native attempt found a hidden recovery entry that never started its
disk check. Keeping it mounted fixes the workflow entry and the equivalent
template entry. Test corrections handle nested confirmation-button wrappers and
iPad lazy Form rows. Earlier failed/aborted attempts remain in the evidence.
No rollout flag, hosted data/schema/configuration or real task changed.


### 2026-10-25 — Branch locations and prepared Mac workflow acceptance

Shared-workflow reviews now show full generated project paths on task rows,
new-section rows (including empty sections), and parent captions on subprojects.
An existing selected parent is included for a newly created branch. This makes
similarly named subprojects/sections distinguishable before Create. Path walking
is cycle-bounded and reuses one project lookup per rendering pass. The request,
source, audience and creation/recovery contracts are unchanged.

The Mac repository now owns four native cases using its exact reserved sandbox
and synthetic HTTP peer: review/Back with no request, changed-source refusal,
private-template creation, and lost-reply/relaunch/Account-entry exact retry.
They compile in a consistently Apple Development-signed app. The first runner
attempt failed before Taskfold launch because macOS reported system authentication
in progress; computer use independently reported the Mac locked. No scenario
passed or actual Mac Keychain recovery is claimed by that attempt. The ready
isolated build is retained for the requested manual unlock; no test app is left
running. The iOS native results in the preceding stage remain scoped to that
stage, not this new project-path visual change.

See p2-team-workflow-branch-review-evidence.json for current compile/test scope.
Mac runtime, spoken/account/window and genuine hosted acceptance remain open;
rank 6, wider Px and all user-deferred work remain unchanged. No cloud/rollout
configuration or real task was changed.


### 2026-10-25 — Reviewed shared bulk labels (rank 6 in progress)

Both apps independently implement Add, exact Remove and explicit Clear all for
one captured shared selection. New names use the existing bounded name rules and
trim outer whitespace. Removal matches saved readable names literally, including
spaces, case and older longer names. Suggestions come only from selected tasks;
private label catalogs and IDs never normalize shared values. Existing opaque
values, duplicates and order survive unrelated edits. Unknown/missing label
shapes pause the whole selection until refreshed so Undo has an exact baseline.

The editor shows current labels and selected projects; the complete review shows
every resulting label set, including already-correct members. Back keeps the
choice, Cancel writes nothing, and Save uses one durable linked batch/RPC. Undo
restores each task's own original labels and refuses changed source/access. Root
labels alone change; notes, plans, assignments, conversations, children, other
labels and unselected tasks remain under their existing contracts.

The source-only migration admits labels to the existing frozen edit batch. Live
Auth/session/team/project/task checks, bounded envelopes, canonical locks, quotas,
whole-source comparisons, HMAC receipts, exact replay and all-or-nothing rollback
are retained. Existing single-task validation checks each label array. No table,
RPC, grant, hosted schema/configuration or rollout flag is added/enabled.

Each independent repository passes 124 isolated PostgreSQL checks with advisors
and fixture removal, plus 500 selected Core regression cases. Six new bulk-label
cases cover per-member add/remove/clear, exact whitespace/case/legacy behavior,
limits, malformed source/name refusal, durable encoding, Undo/Redo and stale
inverse protection. Final app builds compile. Native results and their scoped
limits are recorded in p2-shared-bulk-labels-evidence.json; no live hosted or Mac
spoken/account/window acceptance is implied. Rank 6 and wider Px remain open,
with all release/provider/device deferrals unchanged.


Native verification: three scenarios pass on each signed isolated iPhone/iPad
Simulator host. Tests exercise exact Remove/Clear with Undo, Add review/Back/
Cancel/Save/Undo/normal relaunch, invalid-name refusal and source-change masking.
They compare complete saved rows (including unselected work) and the one linked
queue entry, not just visible text. Final installed binaries/signatures match the
tested products; preparation-only namespace changes are hashed against source.
Light-mode label-set, Clear and paused-state screenshots were inspected. The
initial lazy-Save test failure is retained with the test correction. Native tests
intentionally skip cloud sync; the 124 real local
PostgreSQL transaction checks are separate. Mac runtime still awaits unlock.


### 2026-10-25 — Bind feedback Undo to its exact change

Toast, confirmation and planner feedback now capture a logical history entry,
workspace and session, rather than using the undo-stack count. At the 30-entry
limit a newer edit no longer makes an old feedback button target that newer edit.
A supplied stale request is refused before either stack or saved work changes.
Undo/Redo retain the logical entry identity while transport mutations retain their
existing fresh request identities. This metadata is local and ephemeral; persisted
formats and service authorization are unchanged. A confirmed shared move has no
local inverse and therefore offers no unrelated Undo action.

Each repository passes 545 selected Core regressions, including seven new logical
entry/direction/workspace/session checks. Mac Debug compilation passes. Native
iPhone/iPad acceptance and the attempted Mac runner are scoped in
p2-history-binding-evidence.json. Initial fixture/locator failures are retained.
Mac native runner initialization was denied by system authentication before the
app launched; computer use independently reported the Mac locked after the user
unlock reply. No Mac runtime or spoken acceptance is claimed. Existing native
UndoManager grouping, failure/retry and window/text routing still need their own
acceptance; this change does not close all history integration work.

Rank 6, Watch/Wear OS navigation and the remaining ranked Px scope stay open.
Release, hosted rollout, provider credentials and physical-device deferrals remain
unchanged. No hosted configuration, service schema or real task data changed.

Final native result: all three selected iPhone cases passed, with zero skips and
zero runtime warnings. The actual Store proof confirms depth 30, a newer logical
entry, stale-request refusal and unchanged snapshot/stack identities. It then
undoes the newer edit, applies the exact original feedback Undo, and Redoes it.
Shared-label review/Back/Cancel/Save/Undo/relaunch and planner scheduling/Undo/
relaunch also pass. Both installed hosts match signed build hashes.

The final iPad run is explicitly unaccepted: planner Save reported hit point
{-1,-1}, then the label test stalled on invalid form-scroll geometry. That exact
run was interrupted (exit 75), with log, partial summary and screenshot retained;
the history-limit case was not reached. No app change or repeated run was made
to disguise those input failures. Earlier v2 label regression passes remain
separately recorded. Current iPad and Mac runtime acceptance remains open.


### 2026-10-25 — Native shared-task checkbox admission

The regular list checkbox previously sent an ordinary personal mutation for a
known team task. The existing workspace guard refused that write. Both native
apps now explicitly capture the visible root task, current workspace/session,
team role/access token and service origin before preparing its completion.
Calendar/other native callers of Store.toggle use the same admission. Mac shared
roots use it before the hierarchy-filter path; personal writers stay separate.

Completion prepares the existing single TEAM_COMPLETE command, including a
recurring successor and its original action identity when appropriate. Reopen
uses the existing scoped revision-checked edit and preserves later occurrences;
Undo alone can remove its own unchanged provisional successor. A stale visible
row, missing incarnation, changed workspace/session/access, viewer role or
disabled rollout refuses the action. Unknown repeat semantics are preserved
without forecasting a successor. No scope is inferred for ordinary editor saves.

Both independent Core suites pass 551 selected regressions, including six new
cases for this native admission, source/context refusal, recurrence/Undo and
reopen preservation. Final Debug app builds pass. Initial test snapshots omitted
the required project row and failed; the fixture was corrected and the initial
logs retained. See p2-native-completion-evidence.json for exact native scope.

This fixes single native root gestures; atomic multi-task completion, other
remaining shared adapters, native Mac/spoken/window/hosted checks and the full
ranked Px objective remain open. No hosted schema/configuration, rollout, real
task data or user-deferred release/provider/device work changed.

Installed verification: two actual scenarios pass per signed iPhone/iPad, with
zero failures, skips or runtime warnings. The real checkbox writes one captured
completion; Undo writes its linked inverse and survives normal relaunch with the
complete cache unchanged. Unselected rows remain equal. The 30-entry history/
Redo regression now passes on both devices. Actual final caches, history proofs,
logs, summaries and matched installed binary hashes are retained. Phone/tablet
completion feedback renders without clipping; the iPad relaunch capture includes
a navigation transition and is not stable-layout acceptance. No cloud/Mac runtime
or installed recurrence/reopen acceptance is implied. The earlier iPad planner
input failure remains open. Next: atomic reviewed shared multi-task completion.


### 2026-10-25 — Atomic shared completion selection service (source only)

Both repos independently own an atomic completion/Undo/Redo endpoint candidate:
`taskfold_complete_team_tasks(_action, _body)`. One group contains 1–100 distinct
root tasks, one team, a group nonce and each existing complete-task envelope.
The body is bounded to 2 MB and each member to 128 KB. History carries
`related_request` for the original group and the corresponding `undoes`/`redo_of`
for every original member. Partial, substituted or reused history is refused.
Replies have `batch_protocol: 1`, the original group identity, operation, relation,
all sorted per-task receipts and an explicit replay bit; responses are bounded.

The transaction reserves recipients, team/config/project rows, request identities
and every known source/series/planned/adopted successor in canonical order. It
rechecks permissions after waiting. A successor discovered only after the lock
wait produces a retry conflict before any delegated operation. Each existing
completion routine retains its source, revision, generation, role, recurrence,
retirement, successor ownership and receipt checks. No loop of client RPCs is
used. A late failure rolls back every task, successor, history link and receipt.

The existing private batch ledger and member links bind the action identities.
A private transaction-scoped table admits only the exact group members and
relations; RLS and revoked grants prevent caller insertion or settings-based
forgery. Single-task RPCs cannot replay/Undo/Redo bound members individually.
Access checks run before private history inspection. HMAC fingerprints bind actor,
operation and the frozen group intent. Lost replies can acknowledge an exact
recorded group without reapplying; pruned or incomplete receipts stop safely.
Whole-group Undo/Redo lineage is consumed once, and actor/team deletion uses the
existing cascading ledger cleanup. Existing single-task SQL differs only by the
private batch-history guard; its retirement-aware implementation is retained.

Each independent repository passes 243 actual isolated PostgreSQL checks, including
110 batch-specific checks. Coverage includes cross-project permission/archive
loss, all-or-nothing completion and inverse failures, exact concurrent retries,
overlapping different groups in reversed order, convergence, fresh successor
generations on Redo, expired sessions, request/response identities, payload limits,
RLS/grants, forged context refusal, source/receipt replacement and cleanup.
Official read-only advisors run on each owned fixture: only the pre-existing
auth_rls_initplan warnings are allowed. Owned containers are removed. Initial
argument-limit, SQL-name ambiguity and lock-observation fixture failures are
retained with the final verified run; see p2-completion-batch-service-evidence.json.

Not yet connected to native multi-selection. Next: typed durable group commands
and whole-receipt validation, transactional local apply/confirmation and linked
history, then native review/Cancel/Save/Undo/Redo/relaunch and recovery acceptance
in both apps. Preserve original group intent through lost replies and access
changes; never decompose a saved selection into individual retries. Current
native single-checkbox acceptance is unchanged. Broader rank 6, child records,
Watch/Wear OS and all remaining Px stay open. No hosted schema/configuration,
rollout, real task data or user-deferred release/provider/device work changed.


### 2026-10-25 — Durable completion selection client (Core stage)

Each app independently extends the existing TeamTaskBatch carrier with complete
and undo_complete. Mutation's outer format is unchanged; the internal restores
reference maps to related_request for completion history. Member TeamCompletion
commands retain their frozen clocks, sources, scopes, generations and nonces.
Body validation rejects mixed contexts, nested groups, reused identities, invalid
relations, unbounded content and independent multi-completion queue writes.
Old deletion/restoration/planning selections retain their existing contracts.
Updated clients are required for the new operation values; this is not older-
client rollout or upgrade acceptance.

Local projection uses a temporary snapshot and publishes only after every source
and member applies. One history entry contains the complete inverse selection.
Actual Undo/Redo obtain fresh group/member request identities and current source
revisions; frozen transport retries retain their original logical payload.
Recurring Redo chooses fresh successor incarnations; converging members share
one projected future occurrence. The existing recursive team-access mask knows
every member/source/proposed successor and refuses the whole unavailable group.
Shared groups are excluded from ordinary personal conflict/project recovery.

Backend uses one taskfold_complete_team_tasks RPC, with origin/account/session
fences, no-store/no-cookie transport, redirect refusal, 25-second timeout and a
4.3 MB streamed reply bound. It validates the whole reply before exposing a saved
receipt: exact group identity/operation/relation, complete sorted member list,
per-member completion proofs and consistent replay bits. Errors retain saved
intent and do not expose server detail or fall back to individual task calls.
A late reply cannot cross another account or a new session for the same account.

For a front-of-queue group with no touching later work, complete acknowledgement
merges all receipts on a temporary snapshot and removes the group only after all
members succeed. Unrelated queued work remains unchanged. Missing projects,
invalid/partial/foreign/reordered replies and authored provisional-row conflicts
keep the entire original snapshot/queue. Touching later cohorts (including queued
completion → Undo → Redo) currently refuse acknowledgement and stay durable.
They still need full cohort reconstruction before the native bulk entry is added;
no claim of finished offline batch history or native bulk completion is made.

Both repos pass 564 selected Core regressions, including 13 new completion-batch
cases, and independent final arm64 Debug app builds with signing disabled. Actual
SQL-generated complete/Undo/Redo/recurring envelopes and replies come from each
repo's independently accepted 243-check service fixture. HTTP tests exercise the
actual Backend with synthetic intercepted requests. Initial byte-order retry
assertions were corrected to compare JSON values: object-key order may differ
while every request identity, field and array order is frozen. Initial failures
and final logs/hashes are retained in p2-completion-client-evidence.json.

Next: reconcile complete dependent cohorts transactionally, preserve authored
provisional edits through adoption/recovery, then add captured native selection
review/Cancel/Save/Undo/Redo/relaunch acceptance in both apps. Mac runtime/spoken/
window and hosted acceptance, other rank-6 work, Watch/Wear OS and the full Px
objective remain open. No UI control, hosted migration/configuration, rollout,
real task or user-deferred release/provider/device setting changed.


### 2026-10-25 — Completion receipt reconciliation across queued cohorts

A front completion batch can now confirm while dependent edits remain queued.
An identity adjacency index finds the complete connected cohort, including an
earlier edit to another task that a later mixed selection joins. Saved baselines
reconstruct the pre-action state; replay of every selected command must explain
the current optimistic rows before any confirmed state is published. The group
receipt is then merged on a separate copy and all dependent intent is replayed
in its original order. Only the confirmed front request leaves the queue.

Completion → Undo → Redo retains the correct current counters and successor
incarnations. Later scoped root/provisional edits, mixed planning selections,
scoped deletion and deletion/restoration can survive confirmation without new
nonces or rewritten bodies. Timestamp/null normalization affects temporary
projections only. Unrelated tasks, queued actions and non-task snapshot state
remain intact. Confirmed remote fields can survive beside independent local
edits; conflicting changed-field baselines, replacement generations and authored
provisional content that would be displaced refuse the complete acknowledgement.
An unedited projection may adopt the confirmed occurrence; an authored draft
never silently changes incarnation. Observed loss of access on the original or
an added cohort member, project/ancestor archive and missing projects keep the
original action and complete cohort. Unsupported/inconsistent cohorts also stay
durable for review. No personal writer gains shared scope during reconstruction.

Both independent repositories pass 587 selected Core regressions, including 36
completion-batch cases (23 added here plus the preceding 13), and final arm64
Debug app builds with signing disabled. The complete/Undo/Redo sequential test
uses each repo's actual independently generated SQL bodies and receipts. Other
checks cover recurring Undo/Redo, authored latest occurrences, adoption refusal
and safe adoption, remote-field preservation/conflict, mixed cohort ordering,
whole-selection deletion, restored incarnations, duplicate-row refusal, role loss
and archive races. Full pending commands are compared, not just task counts.
See p2-completion-cohort-evidence.json for current hashes and retained logs.
Service SQL is unchanged; no new hosted or native runtime acceptance is claimed.

Next: captured native bulk completion review/Cancel/Save/Undo/Redo/relaunch,
visible whole-cohort conflict recovery, and runtime acceptance in both apps.
Confirmation work also needs large-selection responsiveness checks and an
appropriate snapshot/generation fence if moved off the UI thread. No bulk entry
point is enabled here. Mac installed/spoken/window and genuine hosted acceptance,
independent child records, remaining Watch/Wear OS and the wider Px goal remain
open. All user-deferred release/provider/device work stays deferred. No hosted
schema/configuration, rollout, real data or external account was changed.


### 2026-10-25 — Captured native shared bulk completion review

Complete selection now opens a native grouped review for shared roots. The
opening captures exact source rows, workspace/session/access authority and one
frozen completion envelope. It lists all selected roots (already-completed roots
stay unchanged), the active count and next repeat occurrences. Cancel makes no
saved changes. Revalidation never creates new requests or acquires new sources;
changes to a selected row, its series/occurrences or permission pause the entire
review and hide the captured contents. Shared mixed/nested unsupported selections
refuse rather than reaching a personal writer. Mac review saves through native
history; iOS uses its existing bound Undo feedback. All members persist together.
The sheet uses existing forms, spacing, typography and feedback. Grouping its
presentation with selection sheets keeps the Mac root view within SwiftUI's
compiler limits.

Both independent repos pass 594 selected Core cases, including 43 completion-batch
cases and seven new capture/authority/lifecycle checks. The final isolated iOS
app/test products build and are signed with preserved Simulator identities; the
final arm64 Mac app build passes with signing disabled. On both phone and iPad,
one actual UI test passes with no runtime warnings: Cancel leaves the entire
cache unchanged, Save queues one TEAM_BATCH for both selected roots, untouched
work is preserved, linked whole-group Undo restores both roots (with monotonic
completion revisions), and normal relaunch preserves the exact final cache and
queue. Installed executable, debug library and Info.plist hashes match the tested
products. Review screenshots are readable without clipped text. These native
fixtures are ordinary roots; recurring preview behavior is covered by Core.

See p2-native-bulk-completion-evidence.json and native-bulk-completion/. The Mac
runtime remains unverified in this stage: desktop control still reports locked.
Native Redo/window/spoken acceptance, visible whole-cohort conflict recovery,
large-selection responsiveness and genuine hosted acceptance remain open. This
is not full rank-6 or Px completion. Teams rollout remains off; no hosted schema,
configuration, real tasks/accounts, release signing or deferred provider/device
work changed. Existing personal selection behavior stays on its original path.


### 2026-10-25 — Whole-selection completion recovery service

Added source-only review/cancellation RPCs for the exact saved completion or
Undo/Redo batch. A group has one terminal status: unrecorded, recorded or
cancelled. Every selected project/series must still be readable before any
private receipt is inspected. Group and member identities, actor, action,
history links and the complete original body are checked together. Nonce and
task locks follow the existing writer's canonical order; current task rows are
locked before gathering member observations.

Review does not create ledger entries. Recorded groups return a complete replay
receipt assembled from the existing strict member receipts. Cancellation of a
recorded group returns that proof and does not Undo it. Cancellation of an
unrecorded group atomically reserves its header/member nonces, links and private
cancellation marker; task content is untouched. A completion that wins a race is
returned as recorded; a cancellation that wins prevents all later exact or
isolated-member execution. Retrying after a lost response recovers the same
proof. Partial/pruned receipts refuse rather than inventing success. Viewers and
archived projects can retire their own unrecorded intent with current read access;
this confers no editing capability. Cancelling an unrecorded Undo does not consume
the original completion's history link.

Both independent repositories pass 348 actual isolated PostgreSQL checks: the
prior 243 plus 105 recovery/cleanup checks. These cover exact read/retry proof,
changed remote content, actor/role/session boundaries, malformed/partial requests,
recorded completion/Undo/Redo, retired Undo and fresh Undo, late cancellation fault
rollback, real completion-versus-cancellation contention, concurrent identical
cancellations, private second-project refusal without partial content, read-access
loss while waiting, archive/write-pause recovery, aggregate/request byte bounds,
RLS/grants, pruned ledger refusal and actor/team deletion cleanup. Official
Supabase advisors report no new warnings (existing auth_rls_initplan warnings
remain). Both owned containers were removed. Actual own generated request/review
examples are retained for the forthcoming native client parser.

See p2-completion-batch-recovery-evidence.json and completion-batch-recovery/.
This stage changes candidate SQL and its independent harnesses, not native app
behavior. Whole-cohort local draft preservation, native review/refresh/retry/
recorded-acknowledgement/cancellation UI, native Redo and Mac runtime acceptance,
large-selection responsiveness and genuine hosted acceptance remain open. No
schema was deployed, no rollout flag enabled, no real task/account changed and no
user-deferred release/provider/device work resumed. The full Px goal stays open.


### 2026-10-25 — Native whole-selection sync recovery

Both independent clients now parse the versioned group review against the exact
saved completion/Undo/Redo envelope. They reject partial, reordered, contradictory,
foreign, oversized or mismatched observations and receipts. The private transport
uses account/origin/session fencing, no cookies/cache, redirect refusal and bounded
streaming. A native grouped review shows every member and offers Later, Check
again, exact retry, recorded acknowledgement and Keep synced tasks. Refresh updates
the existing presented review rather than leaving an obsolete copied sheet.

Recorded acknowledgement reuses the connected-cohort reconciler off the main actor,
then verifies the complete snapshot and session before persisting. Keep synced
tasks first saves an encrypted recovery copy, obtains terminal whole-group
cancellation proof, and atomically adopts only the completion-owned rows. Separate
series parents remain untouched. Independent pending work is retained byte for byte.
Dependent edits, conversation drafts or unexplained source edits refuse cancellation
before any server request; their entire queue remains saved. A recorded winner is
reviewed rather than undone. Persistence failure rolls back the in-memory projection.

Verification: 605 Core cases passed per repo, then all 55 completion-group cases
passed per repo after the final separate-series preservation regression (606 unique
cases in this stage). The final class run also includes strengthened byte-limit
assertions. Both app builds succeeded. Three actual native tests passed separately
on iPhone and iPad with no runtime warnings: Later/refresh/exact retry preserves
saved bytes; recorded acknowledgement removes one whole group; cancellation saves
an encrypted backup and keeps synced roots through relaunch. Installed executable,
debug library and Info hashes match the signed tested build on both devices.
Screenshots were inspected for readable controls. Runtime fixtures use two ordinary
synthetic roots and an isolated local transport peer; the parser additionally uses
each repo's own previously generated PostgreSQL wire fixtures. These are not hosted
acceptance tests. The last separate-series-only safeguard followed these native
runs and is covered by the final Core regression, not a second native run.

See p2-native-completion-group-review-evidence.json and native-completion-group-review/.
A new Mac attempt after the user unlocked timed out enabling XCTest automation
before any case ran, including on the preserved older workflow checkpoint. This is
not Mac runtime acceptance. Native recovery with dependent authored cohorts, recorded
acknowledgement after role/archive/write-pause changes, missing incarnations,
recurring-group/Undo/Redo UI, native storage faults/account-race/spoken acceptance,
large-workload responsiveness and genuine hosted acceptance remain open. Teams
rollout stays off. No hosted schema/configuration, real tasks/accounts or deferred
release/provider/device work changed. The full rank-6/Px goal remains active.


### 2026-10-25 — Preserve connected edits during selection recovery

Keep synced tasks can now save connected typed task work as a permanent encrypted
selection draft before retiring the original completion group. This covers scoped
edits/deletes, transitive mixed selections, recurring completion/Undo/Redo histories
and supported task-comment drafts. The whole connected cohort is reconstructed and
compared against the actual local projection before any write. Unsupported scopes,
unexplained changes, indirect preference references and wrong-generation comments
leave the original queue intact. Independent pending work and comment drafts remain
unchanged. A read-only preview never authorizes dropping intent; only the terminal
whole-group cancellation proof can publish the rollback.

The Store saves and reads back the encrypted draft before requesting cancellation,
then rechecks the entire captured snapshot, account generation and current review
after every suspension. A recorded winner stays in review. Network/disk failure or
a changed workspace leaves the queue saved; persistence failure rolls back memory.
The saved archive remains available after these failures and retries deduplicate
identical work. Account-removal fences cover writes and late key-backed reads.

Saved team drafts now includes saved selections. Their native details show authored
task text, checklist state, earlier title/notes changes and comment drafts, including
the last known content of a queued deletion. Users can copy/share the full text or
export connected details as a JSON review file; it is explicitly not a workspace
backup or automatic replay. Exports exclude unrelated rows/outboxes, the private
workspace/access snapshot and device receipts. Full raw recovery context remains
encrypted internally. Explicit drafts have no retention eviction; ordinary backup
rotation cannot remove them. Each draft is limited to 16 MB, with 20 drafts / 64 MB
per account/origin; reaching a limit refuses to discard queued work.

See p2-completion-selection-drafts-evidence.json and completion-selection-drafts/.
These are independent client-only changes; no SQL, hosted schema/configuration,
rollout switch, real task/account or user-deferred release/provider/device work
changed. Read-permission/archive acknowledgement for recorded groups, explicit
missing-incarnation recovery, unsupported cross-table cohorts, native recurring/
Undo/Redo/spoken/storage/account-race acceptance, Mac runtime, large-workspace
performance and genuine hosted acceptance remain open. The full rank-6/Px goal
remains active.

Final lock-order check: selection enumeration, load, save and deletion all acquire
the account disk fence before the shared process lock. A coordinated reader/saver
regression proves that a reader waiting on that fence does not block an in-fence
save. Each repo passes all 68 completion-group checks after this follow-up. The
broader selected run passes 712 of 713 cases with one live shared-conversation test
skipped; including the new lock-order case gives 713 unique passing Core cases
and one explicit live-service skip. Both final Debug builds succeed.

Native acceptance: the final exact signed isolated iOS build passes the new
end-to-end draft/relaunch/JSON-sharing/popover-cancellation scenario separately
on iPhone and iPad, with no runtime warnings and matching installed binary hashes.
Screenshots were inspected for readable saved text/actions and the actual return
from sharing. Actual encrypted selection-file hashes/sizes and recovery index
metadata are retained without keys. Three earlier recovery scenarios also pass
per device in the initial four-case runs; their failed fourth case and subsequent
picker/selector attempts remain visible in evidence. Final export uses in-memory
Transferable JSON sharing, which avoids the system picker's unreliable Cancel
proxy; no actual external delivery is claimed. This is not Mac runtime acceptance.


### 2026-10-25 — Acknowledge recorded selections with current read access

An explicit recorded group review can now acknowledge its already-synced result
when the user is a viewer, the project is archived or native editing is paused.
A private read authority binds the validated full group receipt to the account,
backend, active team and currently readable source/series projects. Every connected
later typed task cohort must remain readable too. Missing/foreign/inactive/disabled
boundaries and forgotten historical custody refuse without changing the snapshot.
The ordinary send/acknowledgement path keeps its edit-access checks.

The reviewed path reconstructs and validates the entire local projection even
without a later task cohort. Untracked authored fields refuse; supported later edits
and Complete/Undo/Redo histories keep their exact typed bodies/nonces. Displaced
incarnations cannot orphan comment drafts or indirect preference intent. The result
persists the captured current read boundary and historical team/task custody rather
than an older writer cache. Later queued changes remain blocked by their real
permissions; acknowledgement grants no write capability. The Store checks account
generation, complete snapshot, read revision, full current access cache and visible
review after detached reconciliation and before publishing/persisting. Failure
keeps the selection and queued drafts. Native copy distinguishes queued later work
from a separate draft saved by the Keep synced tasks path.

Each independent repo passes 723 of 724 selected Core cases, with one live shared-
conversation integration case explicitly skipped for lack of disposable service
accounts. This includes 78 completion-group cases (10 new read-recovery cases),
actual previously generated SQL complete/Undo/Redo wire fixtures, recurring
histories, transitive mixed-project cohorts, separate cross-project series parents,
read loss, write pause/archive/viewer states, historical custody, untracked content
and orphaned drafts. Both Debug app builds succeed.

Three actual installed UI cases pass separately on each iPhone and iPad with no
runtime warnings: viewer with a later edit, archived project without reopening it,
and paused editing with a later edit. They start with an older writer cache on disk
and a newer read-only access mask, then prove recorded acknowledgement persists the
current read boundary, leaves rows and pending values intact, and survives relaunch.
Before/after snapshots and semantic comparisons retain every value while treating
only Codable Set identifier lists as unordered. Earlier raw-cache assertions failed
on process-dependent Set ordering; failed-run summaries/logs are retained, and the
final tests compare all actual saved values. Runtime fixtures are synthetic ordinary
roots and a local protocol peer; this is not hosted service or Mac runtime proof.

See p2-recorded-completion-read-recovery-evidence.json and recorded-completion-read-recovery/.
Missing-incarnation authored recovery, unsupported cross-table cohorts, native
recurring/Undo/Redo and spoken/storage/account-race acceptance, Mac runtime, large-
workload responsiveness and genuine hosted team acceptance remain open. No SQL,
hosted schema/configuration, rollout flag, real task/account or user-deferred
release/provider/device work changed. The full rank-6/Px goal remains active.

This stage covers an explicit existing recorded review. Automatic discovery of
that review when the app starts with its head already blocked remains the next
source integration task; no cold-start discovery acceptance is claimed here. After
the final text-only queued-edit/draft distinction, the viewer/later-edit/relaunch
case passed once more per device with no runtime warnings. Final installed hashes
match that signed build; the earlier three-mode acceptance remains separately
retained and the other two modes were not repeated for the wording change.


### 2026-10-25 — Discover recorded blocked selections on startup

The normal sync loop now checks a blocked completion-group head before sending it
or merging remote tables. Discovery requires a fresh readable account/backend/team/
source/series boundary, a blocked exact queue head and unique pending identities.
It freezes the full snapshot/access observation off the main actor and rechecks
account generation, snapshot, read revision, current access and competing reviews
before/after the status RPC. A matching recorded proof opens the existing review
and returns before writers or workspace merge. Discovery never acknowledges a
command or changes task rows; explicit Continue remains required. Unrecorded,
cancelled, unsupported or unreadable heads do not gain permission or disappear.

The same read eligibility is shared with explicit recorded-review acknowledgement.
Every saved group nonce, member body, completion time and independent tail remains
unchanged. A late head/body/snapshot/access change discards discovery. Normal writable
heads retain their existing path. Cold single-task completion discovery and other
terminal-state recovery are not introduced by this group-only stage.

Each independent repo passes 728 of 729 selected Core cases with one live shared-
conversation test explicitly skipped for lack of disposable accounts. This includes
83 completion-group cases and five new discovery cases covering viewer/archive/
write-pause eligibility, foreign/missing/disabled/inactive access, malformed and
unrelated heads, recorded versus unrecorded/cancelled status, late context changes,
and complete/Undo/Redo envelopes with independent tails. Both own Debug builds pass.

Three actual UI tests pass on each iPhone and iPad with no runtime warnings. Each
quits while a recorded selection is still queued, relaunches into the production
sync loop under a fresh viewer/archive/write-pause boundary, discovers review and
proves no tasks/queue changes before approval. Every captured trace contains exactly
two POST reads: taskfold_workspace_boundary and taskfold_review_team_completion_batch.
There is no completion writer or workspace-table fetch before review. After explicit
Continue, the exact later-edit tail/current read-only permissions and all task values
survive a second launch. Only Codable Set identifier ordering is canonicalized in
whole-snapshot comparisons. Installed binary/library/Info hashes match the signed
isolated build; screenshots were inspected for readable review presentation.

The reserved DEBUG peer enables the actual sync loop only with its explicit test
flag and answers only synthetic access/status reads; all other HTTP remains blocked.
Fixtures contain ordinary roots; Core covers Undo/Redo discovery. This is not hosted
service, recurring native-history or Mac runtime acceptance. See
p2-cold-completion-discovery-evidence.json and cold-completion-discovery/.

No SQL, hosted schema/configuration, rollout flag, real task/account or deferred
release/provider/device work changed. Single-task/cancelled-head discovery, authored
missing-incarnation and cross-table recovery, native recurring/Undo/Redo/spoken/
storage/account-race acceptance, Mac runtime, large-workload and genuine hosted
acceptance remain open. The full rank-6/Px goal remains active.

## 25 October 2026 — Individual completion discovery after reopening

The normal sync loop now inspects an access-blocked individual completion as well
as a completion selection before a workspace merge. Discovery captures the full
snapshot, head request, account/origin and current read boundary. Only a matching,
validated recorded response opens the existing completion review. It neither
resends nor acknowledges the action. Writable heads use their existing send path;
unrecorded, cancelled, unreadable, malformed and unrelated heads remain protected.

Accepting an individual recorded review now retains the current read boundary on
disk rather than restoring earlier writer access. Fresh read access must cover the
source and repeat-series projects. Connected later edits retain their exact typed
commands and nonces; malformed/foreign scopes, lost cache custody and comment or
other pending references to a displaced occurrence refuse acknowledgement. Existing
single-action reconciliation handles its supported recurring complete/Undo/Redo
history; mixed connected groups still need the broader cohort work. No refusal
removes the saved action or authored work.

Native refresh and Continue capture the complete snapshot/access/account context;
late changes discard their result. Final reconciliation runs away from the main actor
and is rechecked before persistence. A failed refresh keeps the review available.
The existing premium completion review explains that later edits stay queued until
current project access permits syncing.

Each independent repo passes 735 of 736 selected Core cases, with one live shared-
conversation test skipped because disposable accounts are not configured. Seven new
cases cover cold eligibility and exact status, stale snapshots/access/envelopes,
malformed and unrelated heads, view/archive/pause recovery with typed edits,
recurring Undo/Redo and independent tails, lost custody and displaced comment drafts.
Actual recorded/Undo wire fixtures from the existing SQL tests are reused. SQL and
local date/time representations are compared semantically; authored values and
queued commands remain exact. Both final Debug app builds pass.

Five actual UI tests pass on each iPhone and iPad with no runtime warnings:
three individual cold-recovery cases (viewer/archive/write pause), a grouped
cold-recovery regression and a refresh case that changes the observed instructions.
Each cold case verifies unchanged task/queue values before review, exactly two POST
reads (workspace boundary and the matching single/group status endpoint), explicit
Continue, current restrictions and exact remaining commands after a second launch.
The refresh case verifies newer instructions are displayed before acceptance,
without changing the queue/task projection, then saved on Continue. All retained
cold snapshots compare equal after sorting only Codable Set identifier arrays.
Installed binary/library/Info hashes match the signed final test products. Phone
individual-review and iPad refreshed-review screenshots were inspected for readable
presentation. Initial four-case runs per device also passed; final five-case runs
cover the final source. Mac runtime is not claimed.

The native individual command is seeded from one actual captured completion member
inside the reserved DEBUG fixture, with the other synthetic members restored before
testing. Native wire delivery is through the isolated local HTTP peer, not a hosted
service. See p2-single-completion-discovery-evidence.json and single-completion-discovery/.

The reserved DEBUG peer and fixture use synthetic ordinary roots. Native recurring
history, Mac runtime/window/spoken checks, storage/account-race acceptance, other
terminal-state discovery, authored missing-incarnation/cross-table recovery,
large-workload and genuine hosted acceptance remain open. No SQL, hosted schema,
service configuration, rollout or real account/task changed. All user-deferred
release/provider/device work remains deferred; the full rank-6/Px goal stays active.


## 25 October 2026 — Mac completion recovery harness ready; runtime pending

The Mac repo now owns a reserved DEBUG-only recovery peer, synthetic completion
seeding and controls that open the real individual/group review screens. The
fixture can exercise the actual normal sync loop after a saved blocked action is
reopened. Network access outside the synthetic peer remains denied. Its app ignores
stale window restoration only in the reserved debug fixture, so a forced test quit
can be followed by a new main window. Production release behavior is unchanged.

Seven native cases compile in the current, separately sandboxed Mac app: individual
and group recovery after viewer/archive/write-pause changes, and refreshed current
instructions before acceptance. The cases assert exact saved tasks/queue before
review, two read requests, exact later commands/current restrictions after Continue
and relaunch, plus one main window. They use the existing production Store methods
and review views; the peer only answers synthetic ordinary-root access/status reads.

The final app and test runner build and pass strict/deep verification with the
existing Apple Development identity. Own-source namespace transformations,
synthetic backend, private service/App Group identifiers and seven compiled test
methods were checked. Initial signing configuration and an overwritten App Group
literal were corrected before launch, then the final isolated products rebuilt.

No runtime case was executed: native computer use reports the Mac locked on both
inspections, and the requested unlock is pending. The signed host and test build
are preserved, with no test app process running, so the same build is ready for
actual desktop acceptance after unlock. These compiled assertions do not close Mac
runtime, window, keyboard or spoken acceptance. iOS app code is unchanged this stage.
See p2-mac-completion-recovery-preparation-evidence.json; the Mac repo also retains
mac-completion-recovery/ build, signature and source-isolation evidence.

No service/schema/configuration, rollout, real account/task or user-deferred
release/provider/device work changed. All broader rank-6/Px requirements remain
open as listed above; this checkpoint is test preparation, not feature completion.

## 25 October 2026 — Discover and retire already-cancelled completions safely

Cold discovery now recognizes both durable terminal states: recorded and cancelled.
Individual/group status reads still own the exact head, complete snapshot and current
read boundary. An unrecorded response never removes work or opens terminal recovery.
Discovery returns before any task write, acknowledgement or workspace-table merge.

An already-cancelled review uses its validated durable proof on explicit acceptance;
it does not issue a second cancellation RPC. The normal safety backup and encrypted
selection-draft/readback requirements remain. Retiring independent work or parking
connected work now installs the current read cache, rather than leaving older writer
permissions on disk. Viewer/archive/write-pause restrictions survive relaunch.

All asynchronous backup, vault and cancellation steps capture the complete snapshot,
account, read revision and full access cache; late changes discard their result.
Single provisional-draft parking also retains this access cache. Rebase requires
current write access and keeps that same boundary in both its base and result.
Cancelled read access permits only local recovery of the exact reviewed envelope;
it grants no authority to send connected edits. Missing scope, lost cache custody,
malformed/duplicate identities or unexplained authored work keep the queue protected.

Each repo passes 742 of 743 selected Core cases, with one live shared-conversation
integration case skipped because disposable accounts are not configured. The 181
completion cases include seven new cases for actual SQL cancellation/Undo proofs,
exact cold discovery, read-only retirement, fresh rebase permissions, independent
work, encrypted authored group retention and refusal of unsafe/unrecorded contexts.
Existing per-repo SQL wire fixtures are reused; no service SQL changed or reran.
The isolated iOS app and current signed Mac test app both build.

Six actual UI cases pass on each iPhone and iPad with no runtime warnings:
four new cancelled cases (single viewer/archive and group viewer/write pause) plus
recorded individual/group viewer regressions. All cold traces contain only the
access/status reads before review, with tasks and queue unchanged. Cancelled
acceptance traces contain no completion write or repeated cancellation request.
Current restrictions and full post-acceptance snapshots survive another launch;
only knownTasks/quarantined Codable Set ordering is canonicalized. Both group
cases reopen their permanent encrypted draft and read the authored title/notes.
Core separately verifies exact encrypted snapshot/save/readback identity.

Installed app, debug-library and Info hashes match final signed products. The
individual cancelled-review and persistent iPad draft previews were visually
inspected. Actual native data uses ordinary roots and a local synthetic HTTP peer;
no hosted or native recurring-history acceptance is claimed. Mac source namespaces
and final app/runner development signatures verify, but its seven prepared UI cases
remain unrun: the native availability check still reports the Mac locked.

The Mac's seven prepared recorded-recovery UI cases remain unexecuted pending the
requested unlock. Its current-source signed host/build are retained. Native recurring
history, Mac window/keyboard/spoken checks, storage/account-race acceptance, authored
missing-incarnation/cross-table recovery, large-workload and genuine hosted acceptance
remain open. Single cancellations with unsupported connected authored work remain
protected for separate review; no action silently drops those drafts.

No SQL, hosted schema/configuration, rollout, real task/account, OAuth/provider or
user-deferred release/device work changed. See p2-terminal-completion-recovery-evidence.json
and terminal-completion-recovery/. The broader rank-6/Px goal remains active.

## 25 October 2026 — Native recurring history and Mac recovery follow-up

Three new actual native recurring cases pass on each iPhone and iPad: recorded
individual, recorded group, and already-cancelled group with a permanent saved
draft. Two ordinary cold-recovery regressions also pass on each device. All ten
cases have zero failures/skips and no runtime warnings. The tests use the actual
list checkbox/group confirmation, Undo toast and Task options → Undo & redo → Redo.

Captured snapshots independently confirm source revisions 1/2/3 and states
complete/open/complete, removal of the generated next occurrence on Undo, exactly
one next occurrence on Redo with a fresh generation/nonce, the same captured clock,
linked history identities, reset checklist children and preserved notes. A later
scoped edit to the latest occurrence is added through the reserved fixture. Cold
sync reads only the current boundary and matching status before review. Recorded
acceptance preserves the queued Undo, Redo, edit and complete task projection;
cancelled group acceptance retains the entire connected history and edited next
occurrence in a permanent encrypted draft that reopens after relaunch. All six
recurring post-acceptance snapshots survive another launch exactly, apart from
knownTasks/quarantined Codable Set ordering.

This stage changes DEBUG fixtures and acceptance tests, not the production
completion/storage/service contracts. The peer seals only the first completion's
recorded/cancelled result and returns later Undo/Redo as unrecorded. It does not
pretend to deliver that later history to a server. Existing independent SQL fixture
checks remain separately recorded; SQL and the Core suite were not rerun here.
Installed Simulator app/debug-library/Info hashes match the final signed products.
The phone recorded individual review and iPad permanent draft were visually checked.

All seven separately signed Mac cases now execute and pass with no runtime
warnings: individual/group viewer, archived-project and write-paused cold recovery,
plus current-observation refresh. The test now locates the app's separate sandbox
through the user's passwd home and sends a Finder/Dock-style Launch Services open
request after process launch, explicitly reusing the sole existing app instance.
The DEBUG screen picks up an already-discovered review on mount and avoids a second
startup sync once that review exists. The former no-window and duplicate-read
failures are retained as diagnostic evidence; production launch behavior is unchanged.
Each cold case observes exactly two recovery reads, unchanged saved queue/tables
before review, retained later edits and current read restrictions after acceptance,
full snapshot equality after relaunch and one main window. Refreshed instructions
are saved only on acceptance. Group viewer and refreshed individual previews were
visually inspected. These Mac cases use ordinary synthetic roots; Mac recurring
history and broader keyboard/spoken acceptance remain open.

Native Mac recurring gestures/history, storage/account-race acceptance, child-series
and moved-series native cases, genuine hosted later-history/multiwriter delivery,
missing-incarnation authored/cross-table recovery, large workloads and the remaining
advanced/wearable backlog stay open. User-deferred release/provider/device work stays
deferred. No real account/task or hosted schema/configuration changed. See
p2-recurring-native-recovery-evidence.json and recurring-native-recovery/ in each
platform repository. Platform sources and build inputs remain independently owned.

## 25 October 2026 — Real storage failure and safe completion-review retry

Completion reviews now give clear guidance for recognized Cocoa filesystem errors
without exposing private file details. Full-storage errors ask the user to free
space; inaccessible/corrupt file errors explain that queued work is unchanged and
ask the user to check storage access and retry. Network and sign-in failures keep
their existing specific next steps. Transactional queue/storage/transport behavior
and account/access guards are unchanged. Each independently owned repo passes all
184 completion checks: the previous 181 plus three new error/privacy/fallback cases.

Four actual native cases pass on each Mac, iPhone and iPad with no runtime warnings:
three group storage failures plus an individual viewer cold-recovery regression.
The real workspace-cache path becomes a directory during recorded acknowledgement;
the selection-draft directory becomes a file before unrecorded cancellation; and
the backup index becomes a directory after the permanent selection draft is saved.
The production file writer, backup and encrypted vault fail naturally. Every failed
review remains retryable and its complete durable snapshot equals the original.
No cancellation reaches the local peer before the required safety copies succeed.
After repair, acknowledgement retains the exact queued edit; cancellation restores
both original source rows exactly, retains unrelated rows and leaves one reusable
encrypted draft. The draft's authored notes reopen after relaunch. All nine storage
cases retain current read restrictions and complete post-retry snapshots through
another launch (only knownTasks/quarantined Codable Set order is canonicalized).

The Mac runner correctly cannot move files in the app's sandbox. Reserved DEBUG
app controls perform its own reversible filesystem setup/repair, and a journal plus
explicit cleanup launch restores prior synthetic vaults even after a test failure.
No entitlements or user permissions changed. The Mac preview assertion reads native
Text values as well as labels. Both apps and final real development signatures
verify; installed Simulator app/debug-library/Info hashes match built products.
Mac backup-failure and iPad cache-failure previews were visually inspected and show
readable, actionable guidance. Temporary test sessions finish closed.

These cases use ordinary synthetic shared roots, viewer access and the reserved
local HTTP peer. They do not prove native individual storage failures, real disk
exhaustion/hardware corruption, account-switch/asynchronous races, native Mac
recurring history, hosted delivery or release behavior. Those checks, authored
missing-incarnation/cross-table recovery, large workloads and the advanced/wearable
backlog remain open. Existing user deferrals remain unchanged. No hosted schema,
service/configuration, rollout or real account/task changed. See
p2-storage-recovery-evidence.json and storage-recovery/ for the retained evidence.


## 25 October: completion recovery owns its workspace and error

Individual and selection review actions now capture the credential incarnation as
well as the full saved snapshot, access cache, workspace generation, read revision
and exact review. Late replies and errors cannot replace a newer observation,
retire newer authored work or alter a different account. Leaving and returning to
the same account also invalidates the earlier request. Review-screen handlers check
ownership before dismissing or consuming a message; a new request gets fresh view
state. A failure receipt binds the original action to its post-rollback state, so a
real storage failure remains actionable without consuming a later unrelated error.

Each independently owned repo passes 191 completion Core cases. Fifteen native
cases pass on each Mac, iPhone Simulator and iPad Simulator with zero failures,
skips or runtime warnings: fourteen delayed-response scenarios and a real workspace
write failure/retry control. The local peer validates typed replies before holding
them. Actual Backend session transitions, Store refresh/cancel methods and saved
snapshots are exercised. Positive controls accept a current reply and present its
current timeout; a later message is neither overwritten nor consumed. Real native
review controls still show the storage error and complete retry after repair.
All 42 race proofs retain complete interleaved snapshots and match whole-workspace
relaunches; all three storage cases preserve the failed durable workspace exactly.
Only Codable Set ordering is canonicalized. See
[p2-completion-race-evidence.json](p2-completion-race-evidence.json) and
[completion-races/](completion-races/) for retained evidence and source hashes.

The fixture initiates races through reserved DEBUG controls, not the production
account-picker UI. Read-cache equality is checked at reply delivery; a fixture-only
access downgrade is not claimed durable through relaunch. Backup/vault I/O-phase
races, native individual storage failures, Mac recurring history, broader keyboard/
spoken checks, missing-incarnation authored/cross-table recovery, large workloads
and genuine hosted multiwriter delivery remain open. No hosted schema, service,
configuration, rollout or real account/task changed. User deferrals remain intact.


## 25 October: individual review storage failure and relaunch acceptance

Three additional native scenarios now pass separately on Mac, iPhone and iPad:
recorded acknowledgement cannot write the workspace; individual cancellation
cannot write its required backup index; and cancellation reaches the local peer
but cannot save its local result. The last scenario repairs storage, quits,
relaunches and reads the same cancelled request before accepting it. Its original
queue remains intact until successful acceptance; retry does not change the frozen
cancellation receipt. The recorded case preserves its exact authored tail, and
cancellation restores the entire original source row while keeping unrelated work.

All nine scenarios assert unchanged durable workspace bytes on failure and complete
snapshot equality after final relaunch. Current viewer restrictions remain in force.
The individual review's native alert is readable and dismisses correctly before
retry. Four Mac cases pass, including the existing viewer cold-recovery control;
three cases pass on each Simulator, with no failures, skips or runtime warnings.
These are new acceptance checks of the existing production implementation, not a
new user-facing feature. No production app source changed. The preceding 191 Core
checks per repo remain associated with the unchanged production source; they were
not rerun for these test-only changes.

The initial Mac run reached all three expected alerts but selected a Touch Bar
proxy for OK; the final query is scoped to the real window. An iOS test-local name
initially shadowed the cache reader and was rejected at compile time. Both issues
were corrected before the final signed native runs. Reserved test vaults are
restored after every case, and temporary sessions are closed. See
[p2-individual-storage-evidence.json](p2-individual-storage-evidence.json) and
[individual-storage/](individual-storage/) for complete retained states and counts.

The next implementation priority is preserving authored work when an incarnation
has disappeared or been replaced, then supported cross-table recovery. Remaining
acceptance includes provisional-occurrence draft-vault failures, backup/vault
I/O-phase races, native Mac recurring history, broader keyboard/spoken checks,
large workloads and genuine hosted multiwriter flows. User-deferred release,
provider and physical-device work remains deferred. No real task/account, hosted
schema/service/configuration or rollout changed.


## 25 October: keep authored edits after a recorded task incarnation disappears

Both clients now offer **Keep edits as draft** when a validated recorded result
cannot retain its connected authored task work. This covers missing source tasks
and displaced provisional occurrences, for individual and selection reviews.
The existing typed cohort reconstruction validates every connected command and
local row first. Unexplained fields, foreign scopes, indirect preferences and
unsupported mention intent continue to protect the whole queue. A current readable
team/project boundary is required; local recovery never grants editing access.

The explicit action freezes the complete review presentation, including workspace,
credential incarnation, snapshot, access cache and read revision. An obsolete click
is rejected even when the account and head task remain the same. A safety backup
and permanent encrypted draft are saved and read back before local acceptance;
failed writes leave the exact workspace/queue intact, and retry reuses the draft.
Only connected task work and valid comment drafts move out of the active queue.
Independent commands and other rows remain unchanged. Original history bodies and
nonces remain in the archive; no completion, cancellation, copy or retirement RPC
is added by this action. Ordinary sync can resume under the current access mask.

The new account/backend-bound format lives in its own **Recorded recovery** folder,
with authenticated encryption, removal fencing, bounds, explicit deletion and no
automatic eviction. Existing selection formats and readers are unchanged. Simple
provisional drafts keep their existing task-copy workflow. Saved team drafts now
also list Saved edits, with readable text, Copy/Share and a JSON review export.
The export omits the private workspace snapshot, access cache and unrelated outboxes.
An individual command is retained exactly; an ephemeral one-member analysis wrapper
is neither persisted, exported nor sent. Expensive preparation runs off the UI
thread, and list titles do not reconstruct saved queues.

Each repo passes 203 completion Core checks (12 new cases). Five distinct native cases are accepted
on each Mac, iPhone Simulator and iPad Simulator with no remaining failures, skips
or runtime warnings: individual and selection preservation/relaunch, workspace-write failure,
draft-vault failure and the existing selection-draft control. New cases exercise
stale-presentation refusal through the real Store entry point. iPhone/iPad sharing
opens and cancels safely. Mac exports through the standard Save dialog; the actual
local JSON file matches the prepared export byte for byte, and a second Cancel
leaves both the file and workspace unchanged. No external delivery is claimed. Complete retained
snapshots, archives and exports are independently checked. Native cases use ordinary
missing sources; canonical recurring replacement, mixed/deleted task cohorts and
comments also have Core coverage. See
[p2-recorded-recovery-evidence.json](p2-recorded-recovery-evidence.json) and
[recorded-recovery/](recorded-recovery/) for exact evidence and development history.

The reserved DEBUG fixture no longer reseeds a deliberately missing task on
relaunch. XCTest teardown blocks restore prior test vaults even after assertion
failure; initial interrupted fixture vaults were restored before final acceptance.
Mac uses the native Save dialog for JSON export, with scoped completion feedback
and safe cancellation. Test sessions end closed.
The Mac Save-dialog automation initially targeted the filename instead of the
folder field. No file was written in that attempt. A broad folder lookup also timed out, while
the native dialog confirmed the
correct local destination. Narrow field/control lookups resolve both test issues.
The corrected export case passes separately; the other four cases passed in the
suite. All run summaries are retained, including both automation failures.
No hosted schema, service/configuration, rollout, real task/account, release or
provider setup changed. Rank 6 and the broader Px goal remain open: supported
cross-table recovery, broader recurring/spoken/I/O-race/large-workload acceptance
and genuine hosted flows still remain, alongside the agreed user deferrals.


## 25 October: connected mention read-state recovery

Both clients now connect a saved mention read/unread marker to its comment and
exact task incarnation when preserving recorded missing-task work or a cancelled
selection as an encrypted draft. The account, recipient, comment/mention identities,
project, task generation and expected revision are validated before local removal.
Missing, foreign, duplicate, malformed or unexplained context keeps the whole
review and queue protected. An ordinary receipt or simple cancellation cannot
silently orphan a connected marker, even when it is the only remaining local work.
The explicit recorded action still requires the existing backup, encrypted archive
and read-back before persisting the reviewed result. No extra write authority or
conversation RPC is added; saved markers are never automatically replayed.

Saved draft text explains the read/unread choice and connected discussion. Exports
with markers add only their related comment/mention rows under
`conversation_context`; original intent bodies and nonces stay exact. The private
whole-snapshot archive remains separate from export, and unrelated conversations
stay in the active workspace and out of the review file. Exports without markers
are unchanged. Both independent app repositories own their implementation.

Each repo passes 236 focused Core checks, including seven new cases. Two native
cases are accepted per Mac, iPhone Simulator and iPad Simulator: the new connected
marker group recovery/relaunch/preview/export and the existing single missing-task
regression. Mac also saves the actual JSON locally and checks exact bytes; iOS
opens and cancels native sharing. Full saved snapshot, original marker/context and
cold-relaunch state are independently checked. These are synthetic signed-host
checks; cancelled selections and unread=false use Core coverage in this stage.
See [p2-mention-recovery-evidence.json](p2-mention-recovery-evidence.json).

Next is captured preference/order/pin recovery. Unsupported or absent conversation
context, single cancelled/provisional marker flows, broader native recurring/spoken
acceptance, backup/vault I/O-phase races, large workloads and genuine hosted flows
remain open. Collaboration remains default off. Hosted schema/service/configuration,
rollout, real account/task data and all user-deferred release/provider/device gates
remain unchanged.

The Mac export test now creates and removes its unique synthetic file in the
runner’s own temporary directory. Its first self-contained setup attempt was
refused by the test runner’s sandbox at `/tmp`; no app file export occurred in
that attempt. The corrected setup has a separate retained one-case result.


## 25 October: captured list-order and pinned-note recovery

Both clients now capture optional version-1 recovery evidence when writing a
supported account-owned task ordering or note pin. It binds the actual command
identity, account/backend, complete prior and projected preference row, and the
referenced task generations/projects. Missing unrelated task IDs remain explicit
unavailable references in the ordering vector; they cannot authorize a recreated
task or be inferred as a task incarnation. The evidence stays outside row fields and
ordinary HTTP write bodies. Local mode and older/unsupported captures keep their
existing behavior; no history is fabricated for an old queue.

An explicit recorded-result or cancelled-selection draft can now preserve complete
same-row choice histories, including Pin → Undo → Redo. The current row must match
the captured final projection, each transition must join exactly, and affected task
incarnations must match the reviewed cohort. The entire ordering vector is kept;
recovery restores its prior row instead of splitting a user's choice. Other list
rows and independent task edits stay unchanged. Missing/foreign/unsupported or
changed evidence keeps the review and queue protected. Plain completion receipts
and simple cancellation cannot silently strand a connected arrangement.

The existing verified backup/encrypted-archive/read-back transaction precedes local
acceptance. Draft text explains the saved order/pin choice and prior arrangement;
JSON retains all original commands, nonces and captured evidence. Preference rows
are not misrepresented as tasks, and unrelated task descriptions remain outside
export. Undo/Redo choices receive fresh local identities and capture the then-current
row. The new capture indexes task identities once; readable summaries index titles.
Current task-write validators refuse attached preference recovery metadata.

Each repo passes 257 focused Core checks (ten new cases), including real intercepted
HTTP proof that recovery metadata is absent from the normal preference body.
Two native cases pass per Mac, iPhone Simulator and iPad Simulator: combined task,
mention, list-order and pin/Undo/Redo preservation through the production capture/
history helpers, archive/read-back, cold reopen, preview and export; plus the
existing single missing-task regression. The actual Mac JSON Save bytes match the
prepared export; iOS sharing opens and cancels safely. Complete snapshots, preserved
commands, restored prior order, untouched other list row and relaunch are retained
and independently checked. See
[p2-order-recovery-evidence.json](p2-order-recovery-evidence.json).

This adds supported task `view_orders` recovery, not arbitrary `view_preferences`
fields or guessed legacy ordering history. Single cancelled/provisional recovery
paths, missing conversation context, backup/vault I/O-phase races, broader native
recurring/spoken acceptance, large-workload responsiveness and genuine hosted
acceptance remain open. Collaboration stays default off. No hosted schema/service/
configuration, rollout, real account/task or user-deferred release/provider/device
gate changed.

## 26 October: individual cancellation drafts

Both clients can now keep connected edits as a draft when cancelling an individual
queued completion or reopen action. Admission checks the exact current review,
account/session, workspace read revision, full local snapshot and readable task
incarnations. A verified safety backup and permanent encrypted preflight draft
precede the cancellation request. The actual terminal cancellation response is
then appended atomically and read back before the live queue or cache changes.
An unconfirmed draft cannot authorize local retirement. If the action already
synced, the preflight draft remains available and the whole live queue stays intact
for recorded-result review. A failed cache write can retry after cold reopen using
the same draft and confirmed response, without sending cancellation again.

Saved drafts clearly distinguish pending cancellation from confirmed cancellation.
The separate version-2 encrypted namespace preserves the actual individual command,
original read response, complete original snapshot and bounded terminal history.
Existing recorded version-1 files and their authenticated context are unchanged.
Readable exports include authored task/conversation/order choices and cancellation
status; private snapshots, permission caches and raw review/proof responses are not
exported. No synthetic collection header is saved or transmitted. The internal
one-member adapter is used only for local analysis. Unknown or unsupported work
continues to protect the whole queue; this adds no editing permission.

Each repository passes 267 focused Core checks (ten new cases). These include
recurring successor/deletion and Undo/reopen cancellation, mixed independent work,
viewer/archive/pause boundaries, malformed/foreign/unrecorded/recorded proof
refusal, exact encrypted round trips, bounded proof history and export isolation.
Native verification and retained evidence are recorded in
[p2-single-cancel-recovery-evidence.json](p2-single-cancel-recovery-evidence.json).

The remaining work includes provisional-copy cancellation and absent conversation
context, I/O-phase account/session races, broader native recurring/spoken checks,
large-workload responsiveness and genuine hosted collaboration acceptance.
Collaboration stays default off. Hosted schema, service/configuration, rollout,
real accounts/tasks and the agreed release/provider/device deferrals are unchanged.

Five native cases pass on each iPhone and iPad Simulator: successful connected
cancellation/export, cache-write failure with cold retry, vault failure before any
cancellation request, an already-recorded race, and the existing recorded-draft
regression. Full before/after/relaunch snapshots, actual command/proof/export and
one exact individual cancellation request per scenario are retained and independently
checked. Native sharing opens and cancels without replaying saved edits. Both
installed binaries matched the strictly verified real-team signed products.

The Mac build and 267 Core checks pass. Its current native suite is pending macOS’s
interactive “Enable UI Automation” approval. Two attempts failed at runner
initialization before any app test ran. The interrupted initial observation exposed
an alert selector that matched Touch Bar instead of the window; this is corrected.
The initial already-recorded expectation also incorrectly required the preserved
disk permission snapshot to change; it now checks the whole snapshot stays exact.
These failed/interrupted attempts are retained as compact evidence, not counted as
current Mac acceptance. No additional manual listening or widget checks are needed.


## 26 October: verified provisional-draft storage

The original provisional-occurrence draft vault now reads back and compares the
actual decrypted archive after saving a draft, freezing a copy request or clearing
a confirmed-cancelled copy request. A successful filesystem write alone no longer
lets these calls return success. When verification fails after the atomic write,
the authored archive and actual saved request remain on disk for review/retry;
the code does not fabricate a rollback or mint a replacement identity. Existing
Store callers await these operations before retirement, sending a copy or accepting
cancellation. No task, wire format, draft version, authenticated encryption context
or UI flow changes.

The vault now rejects linked/nonregular files and linked vault directories. Listing checks file sizes, the twenty-file bound and the 64 MB aggregate
bound before loading ciphertext or fetching a key. Direct loads check their own
file type and size first; writes also check the complete archive budget. Files are not evicted when a bound or an
unreadable archive prevents access. The account-removal fence now protects explicit
draft deletion as well as save/copy writes; already encrypted material remains
readable for recovery under the existing policy.

Each repository passes 238 selected completion-recovery Core tests. Eight new
real-filesystem cases cover read-back key loss during all three
writes, reopening and exact-request retry, stale cancellation after a newer request,
sparse oversized files, aggregate/count refusal before key access, linked paths,
blocked destination repair and deletion fencing. Current results and limits are in
[p2-provisional-vault-evidence.json](p2-provisional-vault-evidence.json). This is
storage acceptance, not new native/hosted retirement or copy-delivery acceptance.
Both app builds pass (signed isolated Mac build; iOS Simulator compile-only).
The first storage run exposed cached folder metadata after repair; fetching fresh
metadata fixes the actual retry. Compact failed-iteration evidence is retained.
Mac interactive automation remains pending user approval. Provisional connected
edit expansion, missing conversation context, I/O-phase account/session UI races,
broader native/spoken/recurring checks, large workloads and hosted rollout remain
open. Collaboration stays default off; all user deferrals remain unchanged.


## 26 October: captured discussion context for queued mention choices

Marking a mention read or unread now captures an optional version-1 device-local
context when the current workspace has one matching task, comment and mention.
It binds the complete original intent and nonce, account/backend, exact task
incarnation/project, recipient and expected mention revision. Only supported
comment/mention columns are frozen; unrelated discussion, task records, unknown
private columns and permission caches are excluded. Missing/ambiguous capture
keeps the original read-state intent without inventing historical context. A retry
with the same operation ID never replaces its original capture.

Recorded missing-task and individual/selection cancellation recovery can use this
capture if its matching cached discussion has disappeared. Historical rows are
added only to a temporary analysis copy; they are never reinserted into the live
workspace. Existing live rows take precedence and must retain matching identities;
malformed, duplicated, reassigned or older mention identities refuse recovery.
Current workspace read access is still required. A plain completion receipt cannot
silently orphan the connected read-state choice. Readable draft previews explain
“Saved comment” when relying on captured text. Explicit export includes only the
selected discussion, marking fallback rows as captured. Legacy entries are not
assigned guessed context, and unsupported metadata keeps work protected.

Both independent repos pass 284 focused Core checks, with nine new cases for
captured read/unread preservation, exact cancellation proof, current access refusal,
malformed/foreign/stale/recreated context, encrypted reopen/export isolation,
nonce immutability, missing/ambiguous capture and actual intercepted HTTP payloads.
The existing server request body is unchanged: captured context never enters it.
Native acceptance and exact source/artifact hashes are recorded in
[p2-mention-context-evidence.json](p2-mention-context-evidence.json).

This handles supported newly captured mention choices, not arbitrary missing
legacy conversation evidence or the wider provisional-copy cohort. Mac native
acceptance still awaits interactive automation approval. I/O-phase account/session
races, broader native recurring/spoken/large-workload checks and genuine hosted
collaboration remain open. Collaboration stays default off and all user-deferred
release/provider/device gates remain unchanged.

Two native cases pass on each iPhone and iPad Simulator: the new recorded-group
recovery with both live discussion caches empty, and the existing individual
recorded-draft regression. Actual before/after/relaunch/archive/export JSON is
retained and independently compared. The frozen selected discussion survives;
it is never restored into the live cache. Native sharing opens and cancels without
changing saved state. Installed binaries match the strictly verified signed
products. Debug setup uses the production enqueue/capture helper; normal public
Mark read/unread button interaction, native cancellation/unread and hosted behavior
are not claimed by these two cases. The independent Mac app/test build and strict
signature verification pass; its matching UI test awaits automation approval.


## 26 October: large saved-draft preparation

Saved task-recovery drafts now derive their display/export content once instead
of repeatedly rebuilding the same recovery plan. Task lookups use a temporary
index while retaining the former first-match behavior. Native Mac and iOS detail
screens request text and JSON together in their existing background task, sharing
one validated plan. Account/workspace result guards remain in place; no prepared
display result is reused as authority for applying recovery.

Profiling a full-size draft also identified repeated ID scans during typed replay.
For draft analysis only, affected tasks are brought to the front of a temporary
simulation copy. Every record and every existing validation stays present. The
initial/returned workspace is separately prepared from the original cache order;
analysis ordering is never persisted or exported. Ordinary acknowledgement keeps
its existing path. No task body, draft version, encryption context or server/RPC
contract changes.

A synthetic debug case with 101 related task records, 102 queued commands and
10,000 unrelated cached tasks originally spent about 14 seconds on text and 16 on
export. Final measurements prepare both outputs together in under a second. The
full 50,000-record archive fixture prepares in about 2.3 seconds; adding the full
1,000-command queue takes about 3.3–4.4 seconds across the retained runs. These are observations from this Mac,
not release/hardware performance guarantees. Original preview-text hashes and
recovered-cache order are verified; every queued command and authored historical
note is preserved, while unrelated cache content stays outside the export.

Each repository passes all 289 selected Core checks, including five new cases.
The current Core/native results, profiling evidence, before/after observations,
prepared-source/signature hashes and exact acceptance limits are retained in
[p2-draft-performance-evidence.json](p2-draft-performance-evidence.json). Two native
cases pass on each iPhone and iPad Simulator through the actual combined-preparation
screen: captured-discussion/group/order/pin recovery and the recorded single-task
regression, including encrypted reopening and native sharing cancellation. Full
snapshots and exports are independently compared. Normal-size synthetic native
checks do not establish a maximum-size live UI, archive-I/O or hosted benchmark.
The independently signed Mac app/test build passes; Mac UI automation remains
pending interactive approval.

This advances the large-selection preparation gate; it does not close wider
provisional connected-copy cohorts, unsupported legacy conversation context,
I/O-phase account/session UI races, native spoken/recurring/maximum-workload and
genuine hosted team acceptance. Collaboration stays default off. All user-deferred
release/provider/device gates remain unchanged.


## 26 October 2026 — Connected provisional task-copy drafts

Recorded individual recurring actions can now preserve connected list-order/pin
histories and supported discussion markers without losing their explicit task-copy
workflow. The complete encrypted recovery archive is saved and read back first;
the separate task draft then links to that verified archive. The existing
actor-bound retirement operation retires only the unused planned generation. Its
actual response is retained and verified before the recovered workspace is saved.
Any actual shared replacement remains intact. Saving never creates a task copy.

Saved task details provide a direct link to the connected edits and explain the
scope of copying. Optional local metadata keeps the existing draft formats,
encryption context and RPC bodies compatible. A retry reuses the saved task-copy
request rather than changing its frozen choices. Both metadata histories have
explicit bounds without automatic eviction. Account-removal fences protect these
writes. Unsupported or unreadable histories remain queued.

Verification and remaining limits are recorded in
[p2-connected-provisional-evidence.json](p2-connected-provisional-evidence.json).
The focused Core suite passes 302 checks in each repository, including 13 new
connected-draft, encrypted-I/O, removal-fence and actual transport cases. Native
acceptance is tracked separately; this does not close the broader hosted,
maximum-workload, I/O-phase race or spoken-accessibility gates. Collaboration
remains default off, and the user-deferred release/provider/device gates stay
deferred.

Three new native cases pass on each iPhone and iPad Simulator: ordinary linked
preservation, copy-vault failure with zero premature retirement calls, and a
cache-write failure followed by cold reopen and retry. A recorded single-task
regression also passes on each device. The initial six new native cases stopped
at a task-copy control below the visible scrolling form; correcting the test's
scrolling made all six pass without changing production recovery code. Full
snapshots compare equal after sorting only the cache's knownTasks/quarantined
sets; queued commands and task/table order are compared unchanged. Actual
retirement requests/replies, encrypted readback, explicit copy availability,
linked navigation and sharing/cancellation are verified. Installed app/debug/test
binaries match the signed products. The independent Mac app/test build and strict
signatures pass; native Mac acceptance still requires UI automation approval.


## 26 October 2026 — Watch workspace departure and reviewed recovery

The iOS-owned companion now clears an active workspace through the existing
revisioned empty packet. Its revision is durably saved before publication,
including when receipt-generation rotation changes phone authority. Repeated
retirement is idempotent; an exhausted revision refuses without changing the
original authority. A stale cached reconnect notice can no longer cancel every
new connection attempt on this normal departure path. No wire/archive fields,
version or mutation-receipt contract changed.

Watch retains its privacy marker when an empty update arrives. Every client
guard derives from that saved marker plus an immediate memory fence for a failed
privacy write. Only the current explicit Connect attempt can clear privacy.
A valid current reply may follow its own equal/newer same-workspace publication;
it confirms the connection without reverting the newer projection. Older,
empty or different-workspace replies cannot reopen a concealed workspace.
Superseded automatic-refresh replies cannot cancel a newer Connect attempt.

All 104 focused iOS Watch/receipt checks pass, including 16 new cases. The Mac's
unchanged receipt contract passes its nine independent compatibility checks.
Seventeen assertions pass over the actual Air/42 mm Simulator pair across nine
native Watch phases: held actual Connect reply/signout/privacy, cold relaunch,
fresh explicit reconnect with the private draft's old destination intact,
offline completion/relaunch, phone departure before delivery, explicit return,
reviewed new Inbox capture, and exact old-completion replay. The original task
stays open and unchanged, only the reviewed copy gets a mutation receipt, and
replay preserves every actual phone-cache byte. The current phone Store/driver
also passes 16 history-reset checks plus three cold checks with its OS-peer
boundary injected; those 19 checks are separate from the real paired transport.

The first two candidate paired runs kept privacy but failed reconnect; retained traces show
a fresh reply whose attempt had already been invalidated. The third verified the
numbered signout and retained private draft but caught disagreement between the
saved marker and a separate memory flag. The final run passes with the guards
using the saved state. Initial failures, full final native data, independent
comparisons, source/signature bindings and exact limits are recorded in the
iOS-owned p2-watch-boundary-evidence.json. Phone/Watch Debug and Watch Release
builds pass; final installed debug code matches the real-signed products. Release
excludes these fixture routes.

These are synthetic local-workspace checks with controlled startup preparation
and ordinary foreground WCSession delivery. They do not prove cloud-account
Auth, physical phone/reinstall, background/system launch/protected storage,
native typing/dictation/VoiceOver or wider layouts. Watch stays disabled and
unembedded in shipping inputs. Wear OS, the rest of Px and every user-deferred
release/provider/device gate remain open. The Mac gains no Watch target,
transport or iOS build dependency.


### 2026-10-26 — Task-heading contract and completion safety (rank 3 in progress)

Both repository-owned clients now recognize an explicit persisted heading type,
retain its details and refuse completion/recurring successors. Root/child mixed
completion selections reject the whole action, while an ordinary descendant
remains completable. Widget actions reject headings without success feedback and
rotate their token after a root type change. Type edits capture generation and
completion authority; Undo restores explicit ordinary type rather than removing
the field. Missing/NULL/false remains ordinary and `* ` titles remain literal.

The source-only nullable database column preserves legacy ordinary defaults and
whole-row baselines. Its invoker trigger rejects root/nested heading completion
and omission by older checklist writers. The personal patch service captures type
changes without bypassing its existing team guard, generation, merge or RLS. The
actual team completion service rejects headings while legacy ordinary team
completion still succeeds. No hosted schema or configuration changed.

Each repo passes 355 selected Core tests (one existing optional transport skip,
zero failures), 18 new heading cases, 58 real isolated PostgreSQL checks with
advisors and an arm64 Debug build-for-testing. Strict app signatures verify;
the Mac app is development signed and the iOS Simulator build is ad hoc compile
evidence only. Both disposable SQL containers were removed. Earlier harness
failures and their corrections are retained with the accepted reports.

No native/spoken heading acceptance is claimed. Mac controls still reported a
locked screen after the unlock reply; earlier UI Automation authentication also
remains pending. No temporary app was launched for this stage. Heading creation
and type controls remain unexposed; native display/editing, counts/projections,
all completion channels, portability, shared adapters/capabilities and native
acceptance remain open. See TASK_HEADINGS.md and
p2-task-headings-contract-evidence.json. Headings, rank 3, rank 6, Watch and the
full Px objective stay active. All user-deferred rollout/release/provider/device
work remains deferred.


### 2026-10-26 — Gated local heading editors and productive projections (rank 3 in progress)

Both native clients now have explicit local Task/Heading choices in an opted-in
isolated build, using their existing Save/Cancel or autosave/custody flow. Root
and nested heading rows use a text symbol and stronger title weight, retain
metadata/descendants and omit completion controls. Completion gestures and entry
points refuse headings without success feedback. Source/workspace admission is
retained; type saves additionally fence opening completion/type/generation and
revision, including compound note-pin saves. Unsupported revisions/types refuse
rather than authorizing an edit. Unrelated current notes/dates can still merge.

Productive widget rows, Inbox review, Focus choices, capacity estimates, current
project progress/attention and primary task counts exclude headings; app date
queries retain readable context. Header-only earlier dates avoid a red overdue
work count. iOS's system swipe surface explicitly disables full-swipe completion
when unavailable, so its remaining Delete button cannot become an automatic
fallback. The independently owned iOS Watch projection also excludes headings
and refuses a captured ordinary completion after conversion.

Current Core verification passes 172 cases on Mac (three existing optional
fixture skips), 157 iOS Core cases (two existing optional fixture skips) and 97
Watch cases, with zero failures. Each repo includes 29 task-kind cases. Both
current arm64 Debug test builds and strict app/runner signatures pass. Two final
installed scenarios pass on each signed isolated iPhone/iPad Simulator, covering
root Cancel, Save+pin, actual fast Inbox swipe with unchanged saved task, cold
return/conversion, nested choice, organizer Cancel, Save/relaunch and retained
ordinary descendants. Four light/dark phone/tablet images were inspected.

No new Mac native/spoken acceptance is claimed; its earlier interactive UI
Automation authentication remains pending. Normal configuration still omits the
local authoring switch. Checklist progress still counts heading nodes (visible
in the organizer background), and broader counts/history, portability, new/
completed task handling, Undo/recovery, largest/spoken/Mac acceptance and shared
type command/capability adapters remain open. See TASK_HEADINGS.md,
headings-native/ and p2-task-headings-native-evidence.json. The SQL contract is
unchanged and was not rerun/deployed in this stage. No hosted configuration,
rollout, remote reminder, distribution, provider or physical-device dependency
changed. Headings, rank 3, rank 6, Watch and the full Px goal remain active.

The owned phone/tablet app and runner installations are removed and no test app
is running. This stage removed 814.8 MiB of logical scratch files; both Core
build caches and the ready Mac host/build remain available. Existing Simulator
boot states were preserved. See headings-native/cleanup.json.


### 2026-10-26 — Heading portability and checklist progress (rank 3 in progress)

Checklist progress now excludes heading/unsupported nodes while retaining ordinary
descendants; zero-work progress is omitted. Typed workflow review counts headings
separately. Root and branch duplication, template capture/file roundtrip/fresh run,
workspace backup/restore and saved-editor Inbox copy preserve known heading flags
and notes. Typed definitions/files use explicit version 2 plus task_headings;
ordinary captures stay version 1. Unsupported types and downgraded formats refuse
before creating partial work. Normal authoring remains disabled; final Store
admission covers new roots/children and conversions. Shared v2 publication/runs
remain refused pending their command/capability support.

Both independently owned apps pass 318 scoped Core cases, with five optional
cloud-fixture skips and zero failures; 16 cases cover typed portability. Real
coordinated temporary-file reads exercise template and backup content. These are
local file-I/O checks, not provider-picker/iCloud acceptance. Both current Debug
builds and strict signatures pass. Installed iPad review/cancel/create/cold return
and nested Save/Cancel/checklist tests pass. Final iPhone evidence is recorded in
p2-task-headings-portability-evidence.json. No new native/spoken Mac acceptance is
claimed: interactive UI Automation authentication remains pending. Unfiltered
Core runs were stopped without further log progress in unrelated location-private
tests, so no full-suite pass is claimed.

Heading authoring is still local/test opt-in. Broader list/project totals and
action/history policy, Todoist/CSV/clipboard mapping, shared adapters, largest-text,
spoken, Mac and cross-device heading acceptance remain open. The library's root
row count also still uses its established task label; the typed review has separate
task/heading totals. No hosted SQL/configuration or deferred rollout, reminder,
provider, physical-device or distribution work changed. The full Px goal remains
active. See TASK_HEADINGS.md and headings-portability/ for exact evidence/limits.

Both final installed iPhone and iPad scenarios pass (two per device, zero failures
or skips); six light/dark images are inspected. Both synthetic final snapshots
retain the nested heading and ordinary descendant. Owned phone/tablet app/runner
installations are removed, with no native Mac test app launched. This stage
removed 858.7 MiB of logical scratch; both Core caches and the ready isolated
Mac host/build remain. Simulator boot states are preserved. See
headings-portability/cleanup.json.


### 2026-10-26 — Heading reminder eligibility and context counts (rank 3 in progress)

Time reminder generation and stale receipt reconstruction now require an ordinary
open task. This includes planned-time fallback, scheduled alerts and snoozes.
Focus start/resume and finish alerts refuse heading/unsupported types while
retaining the saved session. Location candidate/review/proposal and imported
receipt/recovery admission now require ordinary tasks; a type conversion retires
the old ticket, keeping saved task settings and private pins. Cancellation-only
ticket reconstruction stays available so old OS work can still be cancelled.
The native reminder screen explains paused heading delivery.

List/board/filter badges distinguish displayed headings and unknown types from
tasks, preserving compact ordinary-only counts. Typed template-library summaries
now match the complete task/subtask/heading review totals. Root project progress
retains its documented occurrence policy; these badges do not double-count
checklist descendants. Mac board overdue grouping also excludes heading context.

Both independently owned clients pass 209 scoped Core cases and all 21 private
location recovery cases: three overlap, for 227 distinct passes per repository,
zero failures/skips. Nine new cases cover eligibility, stale snooze, Focus,
private review/import recovery and displayed counts. Current Debug arm64 app
builds and strict signatures pass. One signed native iPhone and iPad scenario
each verifies template-library summary, review/Cancel/Create, cold-return group
count, paused reminder explanation and unchanged saved work after editor Cancel.
Six images and both synthetic snapshots are checked. This is Simulator/Core
acceptance, not actual post-conversion system notification delivery, physical
location delivery or native/spoken Mac acceptance. Earlier interactive Mac UI
Automation authentication remains pending.

The streamed oversize test is confirmed live in a process sample and completes
in roughly a minute; the separately rerun private-authority lock test and full
recovery class pass. No full-suite acceptance or transport performance fix is
claimed. A rejected date-sensitive trigger test is corrected to use a future DST
fold while retaining historical component checks. The additional import test's
initial compile error is retained in the verification notes. No schema, hosted
configuration, production authoring flag or user-deferred dependency changed.

Heading history, remaining productive/descendant policies, Todoist/CSV/clipboard
mapping, shared command/capability adapters, largest-text, spoken, Mac runtime and
cross-device acceptance remain open. The full Px goal remains active. See
TASK_HEADINGS.md, p2-task-headings-actions-evidence.json and headings-actions/.

Owned phone/tablet apps/runners are removed; no native Mac app was launched.
This step pruned 716.4 MiB of owned logical scratch, preserving both Core caches,
the ready Mac host/build and existing Simulator boot states.


### 2026-10-26 — Reviewed Todoist headings and owned release inputs (rank 3 in progress)

Both native repositories now independently own import-todoist source, handler,
tests and the typed import migration, based on the read-only observed deployed
version 41. The documented Todoist asterisk/space prefix maps to explicit root
and nested headings, retaining original content, notes, dates, comments, HTTPS
links and descendants. Completed source heading state is normalized open with
a preview warning and original state preserved. Empty headings and hierarchies
outside the reader limit refuse. Taskfold literals/clipboard text are unchanged.

Version-2 bundles and receipts declare task_headings. The existing invoker RPC
retains source-account locking, owner checks, RLS, stable source mappings and
atomicity while persisting the root flag. Replay preserves destination edits/
types and cannot resurrect deliberately deleted tasks. Older imported literal
copies are not silently converted; their limitation is explained before saving.

Service and client switches default off. Both are required for typed saving; the
preview separates included heading counts and availability. Changed heading
counts require a fresh preview. A heading-aware client refuses an old service
without type-review metadata, and typed receipt acknowledgement is required
before clearing the token. Unavailable and lost-response states retain source
approval for a safe retry. No edge function, schema, hosted configuration or
normal authoring setting was deployed/enabled.

Each repo passes 67 scoped Core cases (six new import cases), 14 Deno cases
(four new) and 38 actual local PostgreSQL checks consuming the real mapper's
output. Invoker/RLS/account isolation, atomic refusal, replay/edit retention,
deleted-destination protection and collection/depth bounds are checked. Local
advisors ran with seven inherited fixture notices and zero import_sources
findings. This is not a hosted advisor or genuine Todoist heading-import claim.

After the user's approval, Mac UI automation now works. The current isolated Mac
walk passes unavailable heading preview, disabled Import, supported preview,
lost-response retry and typed receipt. The same current guarded-source scenario
passes on iPhone and iPad Simulator with unchanged synthetic task tables. Three
scenarios pass, zero failures/skips, and six screenshots are inspected. Current
Debug builds and strict signatures pass. A failed Browse scrollbar test and
rejected SQL harness preparation attempts are retained in the verification notes.
No additional user interaction was needed after permission became available.

This closes the automation-permission blocker, not wider Mac heading acceptance.
Clipboard/CSV formats, explicit review for older literal-prefix copies, genuine
provider/hosted acceptance, broader action/history/keyboard/spoken/cross-device
work and shared capability/command adapters remain open. All user-deferred
release, remote delivery, old-client, provider and physical-device gates remain
unchanged. The full Px objective and headings remain active. See TASK_HEADINGS.md,
p2-task-headings-todoist-evidence.json and headings-todoist/.

Owned phone/tablet apps/runners and the isolated Mac session are closed.
This step removed 845.7 MiB of owned logical scratch, preserving both Core caches,
the ready Mac host/build and existing Simulator boot states.


## Reviewed workflow CSV and clipboard — 26 October 2026

Mac now owns its versioned workflow CSV parser/encoder, JSON/CSV native export,
explicit Copy and Paste/edit → Review → Add to templates flow. It preserves
heading types, hierarchy, notes, labels, relative plans and repeat rules; literal
`* ` titles stay ordinary. Import saves only a reusable private definition.
Pasted text survives workspace changes and requires a new bind/review. File-local
references, strict whole-definition refusal, bounded reads and spreadsheet text
escaping reuse existing template portability and workspace guards. The iOS repo
owns its independent system Paste/share-file implementation; Mac has no new iOS
build dependency. Normal heading exposure remains off.

75 Core cases pass, including 12 CSV and 16 portability cases; four optional
cloud tests skip without disposable accounts. Current isolated Debug build and
strict signature checks pass. The attempted Mac native case failed at activation
because the Mac is locked; it did not exercise clipboard controls. User unlock
has been requested, and the ready host/build are preserved for that acceptance.
The independent phone/tablet clipboard scenarios pass with task tables unchanged,
but do not establish Mac native behavior. CSV file-provider/save/share panels,
workspace-switch UI and spoken acceptance also remain open. Evidence and exact
limits are in p2-task-headings-csv-evidence.json, headings-csv/ and TASK_HEADINGS.md.
This is a scoped interoperability step; broader headings/Px and all deferred
release/provider/device gates remain active.


## Heading project work and attention — 26 October 2026

Mac and its widget now count the nearest ordinary work beneath heading-only
containers in Project pulse. Ordinary parents retain their existing checklist
policy. Child dates/priority/completion remain their own; a heading's date cannot
make its children overdue. Attention uses the same scope as progress and opens
existing hierarchical tasks, falling back to the containing root for legacy or
unavailable references. No derived row becomes a saved root task. Unknown or
unreadable branches show incomplete totals; widget progress says Review tasks
instead of displaying a complete ratio. Recorded parent events remain separate
from child current progress, and the native empty-history explanation makes
that limit clear.

Each repo passes 80 scoped Core cases with zero skips/failures, including 12 new
project-work cases. A 10,000-task heading is read in about 0.54 seconds in these
concurrent Debug checks. Current app/test-runner and owned widget-target builds
pass. The app's strict signature passes. Actual owned SwiftUI source renders
normal/incomplete small/medium/large widget layouts cleanly; this is not an
installed WidgetKit test. The new native Mac case is ready and compiled, but the
Mac remains locked, so Mac execution and the earlier CSV screen check stay open.
Normal heading exposure is unchanged. See TASK_HEADINGS.md,
p2-task-headings-project-work-evidence.json and headings-project-work/ for exact
scope, source bindings and the independently owned phone/tablet checks.

Separate child history, the other productive projections, shared/service and
cross-device acceptance, spoken/largest-text work and the full advanced backlog
remain open. All user-deferred release/provider/device gates remain deferred.

## Mac native clipboard, CSV files and project work — 26 October 2026

After the user unlocked the Mac, three distinct native scenarios pass against the
committed isolated app code: CSV clipboard review/edit/Cancel/Save/cold return;
actual native CSV file export/open/review/Cancel; and exact child navigation,
completion, Command-Z Undo, Shift-Command-Z Redo and cold project return. The
heading stays open and other saved heading/notes content remains intact. Project
totals move from 1/3 to 2/3. Clipboard Save adds only a private version-2 template;
Cancel retains work. File-panel Cancel preserves the entire saved tables set.
The real exported CSV is retained as a synthetic fixture. Four native screenshots
are inspected and scoped to the isolated app; surrounding desktop/file-picker
content is excluded from committed evidence.

Test corrections use the existing single-instance Finder/Dock-open pattern,
actual host-container path, native Switch/front-sheet scrolling and scoped
Export/Open panel controls. Earlier failures are documented rather than counted
as passes. The final test bundle builds and the app's strict signature passes.
Only test harness and evidence change in this closeout; shipping authoring flags,
services and release inputs are unchanged. See `mac-heading-acceptance/report.json`.

These scoped Mac checks supersede the earlier locked-screen blockers. Wider
heading creation/conversion, spoken/large-text, source-race, installed widget,
cloud-provider and cross-device acceptance remain open. Today/Inbox/capacity and
other descendant projections, separate child history and shared adapters still
need implementation/verification. The full Px objective remains active.

## Heading work in the day planner and capacity — 26 October 2026

The planner now shows nearest ordinary tasks beneath headings with their own
plans and estimates, real child routes and a heading breadcrumb. Dated headings
remain context, with no completion control or productive estimate/overlap credit.
Ordinary task checklists stay part of their parent work. Scheduling and completion
of projected children use the strict hierarchy selection contract and save only
the real root tree; native Undo keeps the existing durable queue/history path.

A cached productive reading excludes archived projects and is invalidated with
task/visibility changes. Planner and capacity-widget publication share child
estimates, unestimated work and carryover/overdue treatment. Unreadable branches
or missing child identities keep readable totals but withhold spare-capacity
claims; the widget says Review / Readable estimates only. Its optional
workIncomplete field is omitted when clear. Three actual SwiftUI source-view
renders (normal and review light/dark) are inspected; these are not installed
widget-host acceptance. No schema, normal-authoring or release gate changes.

82 focused Core checks pass independently in each repository, including ten new
productive-planner cases. The signed iPhone and iPad native flows pass scheduling,
Cancel, Undo, completion and cold saved-state equality. The independent Mac app,
widget and corrected test harness build; its native planner case remains pending
an unlocked run. Initial selector/navigation failures are documented as failures.
See `p2-task-headings-planner-evidence.json` and `headings-planner-work/`.

Next: Today/Upcoming and Inbox review, matching badges/primary widget rows,
reviewed containing-heading moves, wider calendar projections and child history.
These remain implementation work; this stage does not close headings or Px.

## Heading work in Today and Upcoming — 26 October 2026

Today and Upcoming now query ordinary work beneath headings using each child’s
own date, priority, search text and completion. Heading dates remain context,
including earlier dates; totals count work. The Mac Today badge uses the same
query. Heading estimate badges are hidden while their stored values are kept.
Unreadable groups show a parent-review notice. Parent captions and independent-row
membership use cached lookups.

Mac projected rows use the established hierarchy selection/edit/Undo path for
completion, details, planning, duplication and deletion; moving a child keeps its
parent’s containment rule. Printing and row gestures receive hierarchy context.
Ordinary task checklists remain expandable, while a heading does not repeat the
work already listed independently. iPhone date placement commits its real root
and view order together; a captured lift intent refuses changed workspaces, rows
or work that disappeared after a heading conversion.

190 iOS and 189 Mac focused Core checks pass (six/five new cases). Current app,
widget and UI-test builds/signatures pass. iPhone and iPad native flows pass exact
child details, Cancel, title editing, completion, Undo, cold data equality and
Upcoming membership. Final synthetic screenshots are inspected. The independent
Mac planner/Today cases remain prepared for an unlocked run; one unlock request
is already pending. Core checks do not establish real drag or spoken acceptance.
See `p2-task-headings-dated-evidence.json` and `headings-dated-work/`.

Next priorities are Inbox review/default Inbox membership with reviewed heading
moves, then matching primary widget rows/token/link authority. Wider badges,
calendar/project/label projections, child history and native/shared/cross-device
acceptance remain open. No normal-authoring, hosted or release gate changes;
this milestone does not close headings or Px.


## Heading work in Inbox and primary widgets — 26 October 2026

Default Inbox and its review cards now use the cached productive work reading.
Independent tasks beneath headings show their own details, plans and parent
context. Child completion/editing uses the strict real-root transaction path.
The Mac Inbox badge counts the same eligible work.

Moving one of these cards presents a review of the entire containing root
heading, including completed work. The review names the destination, lists the
affected tasks and warns when assignments will be cleared. Confirmation checks
the captured root, destination and workspace again; Cancel makes no change,
and one Undo restores the group. Direct synthetic-child project PATCHes are
rejected. This stage intentionally offers a whole-group move, not detachment.

Primary Today, Inbox reset, Focus, Week and planning-widget task data now
publishes independent work with exact child routes and completion authority.
Ordinary checklist children require an explicit child filter. Removing that
filter or converting a heading rejects stale completion authority. Ambiguous or
unreadable groups produce a review state rather than an empty-Inbox claim.
Five light/dark/review SwiftUI source renders use the synthetic app's saved
widget projection; these are not installed WidgetKit host acceptance.

164 iOS and 163 Mac focused Core checks pass, including seven new cases per
repo. App/widget/test builds and signatures pass. Native runtime results and
source bindings are recorded in `p2-task-headings-inbox-evidence.json` and
`headings-inbox-work/`; do not infer Mac app-flow acceptance from its build.

Next: project/label/default saved-filter projections and remaining badges,
wider calendar projections, separate child history, then broader native,
installed-widget, shared/service and cross-device acceptance. Normal heading
authoring remains disabled. This milestone does not close headings or Px,
and all user-deferred release/provider/device gates remain unchanged.

The final iPhone and iPad native scenarios both pass, with Cancel preserving the
root exactly, edited child title retained, completion/Undo, confirmed whole-group
move/Undo, published Inbox counts 2→0→2→1, and exact cold-return root equality.
Four native screenshots were inspected. The debug-only publication panel can
overlap the iPad toolbar; it is absent from normal app runs. The independent Mac
Inbox/planner/Today attempts all stop at foreground activation while the Mac
reports locked, before app-flow checks. Those remain unverified, with the prepared
Mac host preserved for a later unlocked run.


## Heading work in project, label and filter lists — 26 October 2026

Default Project, All Tasks, Completed, label and ordinary saved-filter queries now
read independent work beneath headings. Each child keeps its own labels, plans,
priority and completion. Explicit root/subtask/parent predicates retain their
existing checklist semantics, including mixed independent query sections. A
mixed filter cannot reintroduce roots from unavailable projects.

Manual project queries preserve the source outline. Existing sparse saved orders
containing only heading roots expand their anchors to retain the grouped work;
explicitly saved child positions remain respected. Project sections and widget
ordering use the same rule. Native project/label badges count productive work,
and affected badges show a lower bound when grouped data needs review. Unknown
future task types remain reachable review context without work-count credit.

Configured project, label and ordinary-filter widgets resolve primary published
children without requiring an unrelated child filter. Missing child catalog
members cannot appear as an empty ready list. Unreadable project/group data
produces an unavailable/review state; ordinary missing-root deletion tolerance
and duplicate suppression remain intact. Five actual SwiftUI source renders from
the app-published synthetic snapshot were inspected, including populated project,
label/filter and missing-child states. Installed WidgetKit action/route replay is
still a separate runtime gate.

Print capture validates the exact projected sources, retains an ordinary task's
checklist once, and avoids recursively duplicating heading work already listed.
Headings and unknown types receive no printed task total or completion box.
Default-list print keeps the existing Include checklists option; explicit
hierarchy-filter output retains its matching-only setting. The final print-review
classification and search-hidden heading-anchor corrections are Core/build
verified. Native list scenarios ran just before those two corrections; no new
native print-dialog, exported-PDF or hidden-heading search-order acceptance is
claimed by this milestone.

191 iOS and 190 Mac focused Core checks pass, including 13 new cases per repo.
App/widget/test builds and signatures pass. Both iPhone and iPad native scenarios
pass project membership, exact child details/Cancel, own-label filtering, child
editing, ordinary saved-filter membership, completion/Undo, and exact saved-root
cold return into label/Completed views. Eight native screenshots were inspected.
The Mac still reports locked; its independent project/label/filter case is built
and prepared alongside the prior Inbox/planner/Today cases, with no new native
Mac acceptance claim. See `p2-task-headings-list-evidence.json` and
`headings-list-work/` for source variants, signatures, results and exact limits.

Next: separate child activity history and broader calendar periods, then remaining
native creation/conversion/race/legacy/largest-text/spoken acceptance, installed
widgets, shared/service and cross-device adapters and generic provider mapping.
Normal heading authoring remains disabled. This does not close headings or Px;
all user-deferred release/provider/device gates remain unchanged.


### Child history recording foundation (26 October 2026)

Separate child-ledger schema, strict reader and standalone local recorder now
exist in both owned repos. 53 Core checks per app (22 new) and 49 real-PostgreSQL
checks per independent fixture pass, including actual SQL-to-Swift rows, retry,
privacy/account boundaries and 10,000-child samples. Official advisors report no
new-object findings. This stage is inactive: Store/sync/team masking/backups and
activity/Insights/Project pulse integration remain next. Hosted deployment and
normal heading authoring remain unchanged. Mac native replay was retried after
unlock, but the Mac locked before interaction; no new runtime pass is claimed.
See [the child history contract and ordered next work](TASK_NODE_ACTIVITY.md) and
`child-activity-history/evidence.json`. Px remains open.


### Child history in local edits, sync and backups (26 October 2026)

Both apps now record committed local child transitions, read the optional cloud
feed with sequence/session/epoch checks, apply team visibility masks, discard
unavailable cached history on a fresh task read, and preserve history as a
validated backup archive without replaying it. Ordinary task Undo/Redo now uses
fresh action identities; retries keep their prepared identity. Per-pass parsers
reduce a 5,000-event append validation from 2.915 seconds to about 0.14 seconds
without weakening decoding; a 5,000-distinct-root/timestamp sample takes about
0.36–0.37 seconds. 252 focused checks pass per repo, including 12 new
cases. App/test builds pass; exact native and signing scope is recorded in
`child-activity-integration/evidence.json`. Mac runtime remains unverified while
locked. No service migration or rollout flag changed.

Activity screens, Insights and Project pulse still use parent history. Next is
trustworthy historical root type/work context and a combined child activity fold,
then their UI/widget integration and broader calendar/adapters acceptance. See
[TASK_NODE_ACTIVITY_INTEGRATION.md](TASK_NODE_ACTIVITY_INTEGRATION.md) for the
contract, verification limits and ordered remaining work. Px stays active.


### Observed parent type and generation (26 October 2026)

New parent events carry optional observed type/generation metadata. Heading
events do not earn work credit, old untyped totals are preserved, and a known new
occurrence resets its counter without erasing genuine earlier credit. Typed
routes cannot open a recreated/foreign root at the same ID. The additive SQL
writer preserves the later team-custody rule and continues recording retained
parent work after Auth removal. No hosted schema or authoring flag changed.

239 Core checks, 36 PostgreSQL upgrade checks and 94 broader custody checks pass
per independent repository. App/test builds and exact native limits are recorded
in `root-activity-context/`. This is not mixed child UI/runtime acceptance.
The separate child ledger still needs team identity/role/cleanup custody alignment
before service rollout; that is now the first prerequisite for combining feeds
and wiring activity/Insights/Project pulse. See
[TASK_ROOT_ACTIVITY_CONTEXT.md](TASK_ROOT_ACTIVITY_CONTEXT.md). The full Px scope
and all user-deferred release/provider/device gates remain unchanged.


### Child custody and team read parity (26 October 2026)

Prepared child-history custody now uses stable content identities, survives Auth
author removal, keeps actual/unknown actors distinct, and follows parent-history
role/session/scope gates. Personal/account and explicit team cleanup physically
remove the appropriate child history, with file-guard rollback preserved. Existing
events and sequence IDs remain intact; guaranteed coverage advances at upgrade.
64 real-PostgreSQL and 228 focused client checks pass per repository. No hosted
change, production Swift change or new native runtime pass is claimed.

Next: adoption inspection/count/fingerprint/lock and client-review parity for the
child ledger, followed by combined history and activity/Insights/widget UI. See
[TASK_NODE_ACTIVITY_CUSTODY.md](TASK_NODE_ACTIVITY_CUSTODY.md) for the exact scope,
evidence and remaining rollout gates. Px remains open; user-deferred gates stay
deferred.


### Child history in project-transfer review — 26 October 2026

Both owned clients and prepared SQL now count/fingerprint/lock child history in
bounded transfer reviews, fence late/ABA writes and require a versioned count
contract. Native review shows task/subtask history entries. Each repo passes 35
new SQL-review checks, 55 connection-policy regression checks with the new schema,
and 64 focused Core checks. Actual old approvals become stale; existing child
rows and applied receipt/retry shapes remain intact. No hosted flag changed.

This closes bounded review coverage only. The current registry binds live task
roots, so historical-only/deleted roots and earlier project intervals still need
event-level custody, removal/read rules and acceptance before rollout. Mixed
activity/Insights/Project pulse and wider heading acceptance remain next. Mac
native replay failed to activate after the unlock reply; no UI pass is counted.
See [TASK_NODE_PROJECT_ADOPTION.md](TASK_NODE_PROJECT_ADOPTION.md) and
`node-project-adoption/`. The full Px goal remains active.


### Reviewed history survives author and task removal — 26 October 2026

Forward project transfers now assign private, per-feed/event custody to the exact
reviewed history, including deleted roots and old project intervals. This grants
no current-task authority. Every referenced state still needs current project
access; expired sessions, removed members/authors, disabled native reads and
missing/deleted projects remain closed. Separate transfers may share an immutable
event: exclusive history is removed with its team, joint history with its last
owning team. Earlier observed rows survive; guaranteed epochs conservatively
advance and no unreviewed historical repair/backfill is inferred.

Each repo passes 88 PostgreSQL custody checks plus 55 connection-policy regression
checks and 258 focused Core checks. A held real transfer proves team deletion
returns PT409 instead of acting on a stale ownership snapshot. Existing file
guards/rollback and applied receipt retry remain intact. Client wire/UI code is
unchanged; no new native build/runtime acceptance is claimed. All owned containers
are removed; hosted rollout and normal heading authoring remain unchanged.
See [TASK_REVIEWED_HISTORY_CUSTODY.md](TASK_REVIEWED_HISTORY_CUSTODY.md) and
`reviewed-history-custody/` for joint-retention semantics and exact limits.

Next: combined parent/child activity, Insights and Project pulse, then UI/widget
integration and the wider remaining heading/calendar/provider acceptance.
Retrospective orphan repair and full hosted-chain/native acceptance stay open.
The full Px goal remains active; user-deferred release/provider gates stay pending.


### Parent and child activity, Insights and Project pulse — 26 October 2026

The app now combines immutable parent/child activity with feed-specific identities
and receipt-time display order. Productive children earn corrected Insights
credit; headings, ordinary checklist details and completed imports/promotions do
not. Undo/Redo and completion-time edits keep their existing semantics, while
productive-scope conversion preserves genuine earlier work without a fake reopen.
Unknown/gap data remains partial and cannot lend current-task authority.

Project activity opens exact current children using fresh generation/owner/key
checks. Store and widgets publish the same event counts, keep current progress
separate, and show partial history without discarding verified parent counts.
Child-only local history is supported; differing recording epochs remain explicit.

Each owned repo passes 257 focused Core checks (20 new). Independent Mac Debug
app and iOS Simulator app/widget/share/UI-runner builds pass. iPhone/iPad native
flows verify child completion, 2/3 progress, one recorded event, cold saved-state
equality, exact history route and one Insights completion. Source widget renders
are inspected in partial light/dark states. Mac runtime, spoken/largest-text,
installed widgets and hosted/cross-device acceptance are not claimed. Normal
heading authoring and hosted/release configuration stay unchanged.
See [TASK_WORK_HISTORY.md](TASK_WORK_HISTORY.md) and `work-history/` for exact
source bindings/results, partial coverage rules and cleanup. Next: broader
calendar periods, remaining heading/adapters acceptance and the other Px work.
The full goal remains active; user-deferred release/provider gates stay pending.


### Calendar periods and productive work — 26 October 2026

Week, three-day, five-day, month and year calendars now project ordinary work
inside headings, using each task's own date and viewed time zone. Heading and
checklist dates do not inflate totals. Stable children use existing hierarchy
editing/completion paths; unknown identities remain non-actionable with a partial
notice. Project archive changes refresh the calendar immediately. Normal heading
authoring remains off. See [TASK_CALENDAR_WORK.md](TASK_CALENDAR_WORK.md) and
`calendar-work/` for verification, harness corrections and remaining limits.
This completes the period-projection implementation; wider native Mac,
accessibility, adapter and cross-device acceptance remains open. The full Px
goal and user-deferred release/provider gates remain active/pending respectively.


### Reviewed generic CSV workflow mapping — 26 October 2026

Both clients now accept explicitly mapped comma-separated workflows through
Templates file intake or explicit pasted text. Users choose title/notes, parent
references, exact task/heading values, dates relative to a reviewed reference
date, priority, estimate, labels, time and time zone. Unmapped columns are listed;
source account/completion/assignment/history data is not guessed or imported.
A separate full definition review precedes Add to templates; runs remain separate.
Known Taskfold files keep their strict path and normal heading authoring stays off.
Each owned repository passes 87 focused Core checks, including 12 new mapping
cases. Build/native scope, source hashes and cleanup are in
[TASK_CSV_SOURCE_MAPPING.md](TASK_CSV_SOURCE_MAPPING.md) and `source-csv-mapping/`.
This implements generic workflow mapping; provider/file handoff, flat row sharing,
shared capability adapters and wider rank-3/6/7 acceptance remain open. User-deferred
gates and the full Px goal remain unchanged.


### Reviewed flat task-row CSV — 26 October 2026

Both apps now implement Print or export → Export CSV, with row review, explicit
notes/checklist choices, native Save and guarded Share. Structured fields, status,
file-local hierarchy and complete label names survive; account/live IDs and private
non-task payloads are excluded. The explicit CSV mapper recognizes the versioned
transport without reinterpreting generic text. Source/workspace/options checks
precede handoff. Headings are counted as rows separately from productive work.
Each repo passes 64 focused Core cases; current phone/tablet cancellation and cold
preservation pass. Independent Mac build passes; native Mac, completed provider
handoff and wider source/account/accessibility acceptance stay open.
See [TASK_ROW_CSV.md](TASK_ROW_CSV.md) and task-row-csv/ for scope and evidence.
The implementation advances flat row sharing; it does not close rank 3, the wider
Px goal or user-deferred release/provider/device work.


### Reviewed older Todoist heading copies — 26 October 2026

Both apps now offer an explicit review for ordinary open rows carrying known
Todoist heading source metadata. The review separates imported and current titles,
lets the user keep or remove one leading marker, and preserves edited wording by
default. Apply rechecks the whole captured editor draft and heading availability;
the native editor retains its Save/recovery/Undo paths. Reviewed title words stay
literal rather than becoming new quick-entry date/project/priority edits.

Each owned repo passes 52 selected Core checks (7 new conversion scenarios).
Current iPhone and iPad scenarios pass review Cancel, marker choices, Apply then
parent Cancel, separate Save, exact untouched-field preservation and cold return.
Both review images were inspected. Independent Mac Debug build and strict/deep
Simulator signing checks pass. Mac native, broader live source/access races,
spoken/largest-text and shared/cloud/cross-device acceptance remain open.
Normal heading authoring and all user-deferred rollout/provider gates are unchanged.
See [TODOIST_HEADING_CONVERSION.md](TODOIST_HEADING_CONVERSION.md) and
heading-conversion/. Rank 3 and the full Px goal remain active.


### Shared type command protocol — 26 October 2026

Both independently owned clients and service sources now support negotiated root
and nested task-type edit commands. The capability defaults off and participates
in the workspace boundary token. Typed receipts, durable retry identity, explicit
Undo and root/nested completion revisions are checked. Each repo passes 158
selected Core checks, 72 isolated PostgreSQL checks/advisors and an unsigned app
build. No hosted configuration or native UI authoring gate changed.

Native Store/editor integration, creation/lifecycle, shared templates/import,
recovery/runtime and wider accessibility/cross-device acceptance are next; the
existing lifecycle whitelist still refuses typed root payloads. This does not
close shared heading editing or rank 3. See TEAM_TASK_TYPES.md and team-task-types/.


### Shared typed lifecycle — 26 October 2026

Both apps and service sources now preserve root/nested heading types through new
creation, deletion, certified restoration and atomic selection Undo. Lifecycle
transport support is advertised separately from default-off new heading authoring.
Typed acknowledgements and durable identities protect retries; known work can be
restored while new authoring is paused. The null type-column whitelist issue is
fixed. Normalized discussions retain content with fresh callback identities.

Each repo passes 179 selected Core cases, 100 isolated PostgreSQL/advisor checks
and an unsigned current-source Debug app build. No hosted or native authoring gate
changed. Native controls/recovery/races, template/import and wider cross-device/
accessibility acceptance remain open. See TEAM_TASK_TYPE_LIFECYCLE.md and
team-type-lifecycle/. Rank 3 and the broader Px goal remain active.


### Shared heading native controls — 26 October 2026

Both clients now gate root type choices and organizer type actions on captured
and live shared capabilities plus client opt-in and current edit access. Native
acceptance exposed and fixed a fresh Undo baseline missing completion context.
Five installed iPhone and five iPad scenarios now pass conversion Cancel/Save,
Undo/Redo, nested root-scoped writes, missing capability, preserved paused drafts,
creation failure/retry and cold persistence. All four images were inspected.
Each repo passes 141 selected Core checks; current app builds/signatures pass.

The Mac runtime attempt failed before test execution while Xcode tried to enable
UI automation. Its current signed harness is retained; no system setting changed.
The synthetic iOS peer pauses sync, so genuine delivery/receipt recovery, broader
native races/lifecycle/accessibility and shared template/import adapters remain
open. Normal flags and hosted rollout are unchanged. See TEAM_TASK_TYPE_NATIVE.md
and shared-heading-native/. The wider rank-3/Px goal stays active.


### Shared heading workflows and Mac runtime follow-up — 26 October 2026

Both independently owned clients and service sources now preserve headings
through reviewed shared-template publication/replacement, private copying and
shared workflow runs. Root/nested headings retain their type and child order;
review counts distinguish them from productive tasks/checklist items. Exact typed
acknowledgments preserve one encrypted request across lost replies and relaunch.
A reopened shared subtask now gets a clear save-first explanation before a type
conversion that would require a separately saved reopen.

Each repo passes 96 selected Core checks, 60 heading-specific PostgreSQL/advisor
checks and all 89 existing workflow SQL checks with the new migration installed.
Signed iPhone/iPad acceptance passes publication/copy/cold preservation and the
final heading run/lost-reply/relaunch/exact retry flow. The signed Mac runtime
also passes heading workflow review and that recovery flow. Five output images
were inspected. Earlier failures were test-harness selectors/value types/home
resolution and are retained with the final passing results.

The preceding Mac root heading editor/autosave/Undo/Redo/cold-queue test also now
passes after the user approved Xcode UI automation. Its earlier initialization
failure is resolved for that specific case. Source fingerprints, signatures,
results and limits are in SHARED_WORKFLOW_HEADINGS.md, shared-workflow-headings/
and shared-heading-native/mac-summary.json. UI acceptance uses the synthetic
HTTP peer; actual SQL acceptance is separate. Full native server delivery,
broader source/access races, accessibility/largest-text, installed widgets and
cross-device work remain open. Normal rollout and all user-deferred provider,
notification, safe-upgrade and distribution work remain unchanged. Rank 3 and
broader Px stay active.
