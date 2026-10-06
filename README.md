# Taskfold for macOS

A native SwiftUI Mac app for Taskfold. This repository owns all Mac app code, widgets, resources, configuration, tests and release tooling. A fresh clone builds independently. The iOS app lives in [dbakp/TaskFold-iOS](https://github.com/dbakp/TaskFold-iOS); both apps use the same backend and compatible data contracts. See [repository ownership and parity](docs/REPOSITORY_OWNERSHIP.md).

## Layout

```
Taskfold/             # Mac Core, native views, resources and backend configuration
TaskfoldWidgets/      # Mac widget extension
TaskfoldTests/        # Local Core and widget-model contract tests
TaskfoldUITests/      # Mac user-flow tests with isolated fixtures
Scripts/              # Project generation, tests, packaging and publishing
supabase/             # Backend migrations and isolation fixtures
```

After adding Swift files or resources, run `python3 Scripts/generate_project.py`. The generated project contains only repository-local inputs. No iOS checkout or dependency download is required.

## Run

```sh
xcodebuild -project Taskfold.xcodeproj -scheme Taskfold -configuration Debug -derivedDataPath DerivedData -allowProvisioningUpdates build
open DerivedData/Build/Products/Debug/Taskfold.app
```

Requires Xcode 26 and macOS 15. Signing uses the personal team `3UZ4C73FM2` with automatic provisioning; the app is sandboxed with network client, user-selected files, and a keychain access group.

Sign in with email/password or Google (`ASWebAuthenticationSession` with PKCE, callback `taskfold://auth/callback`), or choose **Use on this Mac without an account** for a local workspace.

## Install

`Scripts/make_dmg.sh` produces `dist/Taskfold-<version>.dmg`: a compressed disk image with the app, an Applications shortcut, and a short "How to install" note. By default it makes a **distribution build**: signed ad hoc with no provisioning profile, so it never expires and runs on any Mac. Because it is not notarized (that needs a paid Apple Developer account), the first launch is blocked with "could not verify"; open System Settings ▸ Privacy & Security and click **Open Anyway** once. Distribution builds carry sandbox, network, user-selected-file and calendar-read entitlements and leave out the widget extension, which needs a team-provisioned App Group.

`Scripts/make_dmg.sh --development` makes the team-signed build with the widget instead. It runs only on Macs registered to the team and stops launching when its seven-day provisioning profile expires, so it is for local use.

### Releases

Published distributions are available as GitHub releases with the DMG attached: [github.com/dbakp/TasskFold-MacOS/releases/latest](https://github.com/dbakp/TasskFold-MacOS/releases/latest). Development source includes unreleased P0 work tracked in [the implementation status](docs/P0_IMPLEMENTATION.md). Build and verify a candidate with `Scripts/make_dmg.sh`, then use `Scripts/publish_release.sh <notes-file>` to publish a new immutable version. Publishing requires committed sources and a matching build-input fingerprint. It refuses to replace an existing version; bump `MARKETING_VERSION` in `Scripts/generate_project.py` for a new release.

## Welcome tour

A five-page tour opens on first launch and can be skipped at any point (Skip, Escape). It is built from the app's own components: the real quick-entry chips appear as a sentence is typed, a task drifts across priority bands and snaps back with the "Stays with P3" hint, the Plan Your Day card shows the keyboard shortcuts, and the last page picks the accent and offers sign-in. ← → and Return move between pages. Help ▸ Welcome Tour and Settings ▸ General ▸ Show Welcome Tour bring it back.

## What is here

- **NavigationSplitView** with a sidebar (Today, Inbox, Upcoming, Calendar, Browse ▸ All Tasks / Completed, Projects, Labels), a content list, and a trailing **inspector** that edits the selected task in place and saves as you go. No sheets for editing.
- **Subtasks**: chevrons expand a task's subtasks directly beneath it, with one further sub-subtask level. Each nested row can be selected, edited in the inspector, completed/reopened, and undone independently. Add a subtask from the selected task's inspector; the deepest level offers no further nesting. Existing embedded subtask data is preserved, and expanded children stay attached when the parent is reordered.
- **Keyboard**: arrow keys move selection, Space completes, Return edits (focuses the inspector title), Esc clears selection, ⌫ deletes, ⌘N new task (opens and focuses the task-entry panel, which understands the shared quick-entry grammar), ⇧⌘N new project, ⌘Z / ⇧⌘Z undo and redo through the system undo manager, ⌘F search everywhere, ⌘K command finder, ⇧⌘F filter the current list, ⌘1…⌘5 sidebar sections, ⌥⌘I inspector, ⌘R sync. Every shortcut has a menu bar item.
- **Multi-select** with shift/⌘-click, right-click context menus for one or many tasks, and a **Task** menu with reschedule, move, priority, duplicate, and delete.
- **Drag and drop** with macOS drag sessions and a real drag image (title, priority ring, count badge for multi-drags). Drop between days, onto day headers, onto empty days, onto sidebar items (Today, Upcoming, Inbox, any project), and onto calendar days. Reordering within a day preserves the iOS `DayPlacement` semantics and is one undoable change. Trackpad feedback marks slot changes and drops.
- **Undo affordance**: a brief, non-blocking confirmation strip at the foot of the list ("Completed “…” · Undo ⌘Z") in addition to Edit ▸ Undo.
- **Calendar** with an hourly Day planner, 3-day, 5-day, week, month, and year modes laid out for a wide window: day columns or a month grid with equal-height weeks (overflow collapses into "+n more"), and the selected day's tasks in a side panel that appears when the window is wide enough for it. Tasks open in the inspector; ← / → move between periods; ⌘T jumps to today.
- **Ordering**: every list is arranged by priority band (P1 first) with the user's manual order inside each band, the same `DayPlacement.arranged` rule as iOS. Drops stay inside the task's band; the insertion indicator shows where the task really lands and a "Stays with P2" hint explains a snapped drop. Inbox, projects, sections, and labels reorder manually with account-owned synchronized placement keys.
- **Quick entry chips**: projects, sections, accepted project members, dates, times, priorities, labels, estimates, deadlines and basic recurrence parsed from the title appear as chips in the task-entry panel and the inspector; ✕ (or Space / Delete on a focused chip) keeps those words in the title.
- **Links**: URLs in titles and notes render as accent-coloured page titles (fetched once, cached); click opens the browser without selecting the row, hover previews the page, right-click offers Open, Copy Link, and Share.
- **Planning**: Plan Your Day (⌥⌘P) and Review This Week (⌥⌘W) triage tasks one card at a time with T, M, D, Space, and →.
- **Account**: change email or password, send a password reset, or delete the account from Settings ▸ Account. Reminders offer Complete, Remind me in 1 hour, and Move to tomorrow.
- **Shortcuts and widgets**: the shared App Intents (Add Task, What's Due Today, Complete Task) appear in Shortcuts; six widget kinds read the App Group snapshot the app publishes.
- **Layout**: task lists read in a centered column (max 860 pt) the way Todoist lays out its lists; global search remains in the sidebar, while the current-list filter and view options sit above the tasks in the upper-right corner. The toolbar plus or ⌘N opens a native task-entry panel with a prominent input, destination, parsing chips, and Add Task action. It closes after submission and preserves drafts when dismissed with Escape. Drafts can be reopened after revisiting a destination, and view options are scoped to each list.
- **Motion**: `Views/Motion.swift` keeps the iOS spring vocabulary (layout, quick, lift, settle, track) tuned shorter and subtler for the Mac; `Views/Transitions.swift` translates the [transitions.dev](https://transitions.dev) token scale (durations, easings, distances, scales, blur) into SwiftUI recipes: text-state swap, icon swap, toast open/close, panel reveal, notification-badge pop, number pop-in, stroke-drawn success check, error-state shake, skeleton reveal, shimmer text, sliding tabs, and the hover-in/hover-out asymmetry. All respect Reduce Motion.
- Light and dark mode, system text scaling, VoiceOver labels, pointer cursors, hover states, resizable columns, window state restoration, a unified toolbar with the search field, a Settings window (⌘,), notifications for due tasks, collaborators, invitations, and Todoist import.

The sidebar account menu provides direct access to sign-in, profile management, Settings, Todoist import, and invitations. Todoist import previews data before importing. In a task comment, pasting an image with ⌘V immediately saves it as an attachment while keeping your unfinished text. Click its thumbnail to open Quick Look.

## Tests

Core and widget-model tests run from this repository:

```sh
Scripts/test_core.sh
Scripts/test_core.sh -c release
```

macOS UI tests use isolated data and cover navigation, search and keyboard focus, scoped filters, account-screen access, comment image persistence, date edits, completion/undo, and day-to-day dragging:

```sh
Scripts/test_mac.sh test
```

UI testing on macOS asks once for Accessibility permission for the test runner. Passing `TEST_RUNNER_TASKFOLD_SCREENSHOTS=1` to `xcodebuild test` also renders the report screenshots (see `Screenshots/`) into the runner's temporary directory; the path is printed in the log.

Two macOS specifics worth knowing: rows use `itemProvider` (the table's own dragging) rather than `onDrag`, because a SwiftUI drag gesture on a List row swallows the click that selects it; and Space / Return / Escape are routed by `Views/KeyRouter.swift`, a local key-event monitor that steps aside whenever a text field is editing, because table-backed lists do not forward those keys to SwiftUI key handlers.

Debug-only launch arguments: `--preview` (illustrative tasks), `--uitesting` with `--day-drag-fixture`, `--priority-fixture`, `--link-fixture`, or `--navigation-fixture` (test fixtures in a separate local namespace), `--section=<key>`, `--calendar-mode=<mode>`, `--appearance=light|dark`, `--accent=<key>`, `--select-title=<title>`, `--open-settings=<tab>`, `--preview-account`, `--onboarding`, `--capture=<file>`. Release builds ignore them. Fixture launches ignore saved window state so a force-quit test run cannot restore a windowless app.

## Screenshots

| Today, light | Today, dark |
| --- | --- |
| ![Today light](Screenshots/today-light.png) | ![Today dark](Screenshots/today-dark.png) |

| Calendar week | Calendar month, dark | Calendar year |
| --- | --- | --- |
| ![Week](Screenshots/calendar-week-light.png) | ![Month](Screenshots/calendar-month-dark.png) | ![Year](Screenshots/calendar-year-light.png) |

| Quick-add with chips | Settings ▸ Account | Sky accent |
| --- | --- | --- |
| ![Chips](Screenshots/quick-add-chips.png) | ![Account](Screenshots/settings-account.png) | ![Accent](Screenshots/today-sky-accent.png) |

## macOS polish work

The implementation sequence and acceptance checks live in [the polish plan](docs/PREMIUM_MAC_PLAN.md). The comparison with the original app and remaining account/feature work live in [the parity plan](docs/FEATURE_PARITY.md).

## Collaboration

The Mac now supports task/subtask assignments, Assigned to Me, and reviewable concurrent edits. See [the collaboration implementation and next steps](docs/COLLABORATION.md).

The Mac code and release inputs are owned locally. Cross-platform changes are implemented and tested in both repositories; there is no revision pin, source fetch or sibling path in the Mac build.

The configured backend already has the collaboration migrations and the newer iOS member-profile migration `20260914091713_project_member_profiles.sql`. Do not replay the older Mac directory migration over that deployed definition. A new backend needs the current iOS schema/profile migration and the collaboration prerequisites.

Release products build in `~/Library/Caches/TaskfoldBuild` (outside synced Documents folders); the DMG lands in `dist/`. `Scripts/publish_release.sh <notes-file>` requires committed sources and verifies the DMG source fingerprint, then creates a new immutable version tag and GitHub release. Never publish until runtime verification is complete.

## Productive widgets and feature roadmap

The provisioned widget extension includes Today, Focus, Week ahead, Quick capture, Deadline radar and A small window. Today opens individual tasks and exposes +; Focus explains one selected next action; Week ahead shows seven actual task counts and opens Upcoming. Soft surfaces adapt to light/dark appearance. The ad hoc distribution DMG still excludes widgets.

See [the detailed Todoist feature plan](docs/TODOIST_PORT_PLAN.md) for the source audit, import API compatibility risk, phased backlog, estimates, data migrations and acceptance criteria. [Widget preview](docs/widget-previews/catalog.png). Run `python3 Scripts/render_widget_previews.py` to render the SwiftUI fixture views in light, dark and empty states. Rendering does not prove installed WidgetKit-host behavior.


## Quick-entry destinations and labels

`Write proposal #"Client Work" /"Next steps" +Alex @"Client notes" ~25m {2026-10-09}` selects existing project/section/member targets, a label, a time estimate and an independent deadline. Names with spaces need quotes. `+me` uses your own project membership; other people match an exact display name/email or a unique first name in the available accepted-member directory.

Known `#Name` references select projects; unknown hash names retain the older label meaning. A project/label name collision requires `#project:"Name"` for the project or `@"Name"` / `%"Name"` for the label. Parsing never creates projects or sections. Unavailable, multiple or ambiguous destinations remain in the title with feedback. Declining a different project keeps its dependent section/person references literal. Escaped references such as `\#"Client Work"`, ordinary quoted phrases, URLs, emails and file paths remain literal.

The capture panel previews the actual parsed destination. Saving a project change clears incompatible section and assignment values, including child assignments. The inspector and Shortcuts use the same account-scoped reference rules. New label edits store stable IDs compatible with iOS and web; older label names, existing IDs and unknown legacy values remain readable. Full Todoist recurrence/reminder-token grammar and autocomplete remain pending.


## Productive widgets

The widget collection includes Today, Focus, Week ahead, Quick capture, **Deadline radar** and **A small window**. Deadline radar shows missed and approaching independent deadlines, with a 7-, 14- or 30-day look-ahead. Rescheduling planned work leaves the cutoff intact. A small window suggests tasks with a known estimate within a 10-, 25- or 45-minute budget; unestimated work is counted separately. Choose Ready work (today, overdue and undated), Inbox, or All open tasks (including future dates). Each instance has its own settings. Both new widgets support small and medium sizes, Default/Rose/Lavender/Mint color choices and a preference to hide task and project names. Task rows open the native task editor.

A versioned read-only App Group snapshot carries stable project IDs, independent deadlines, estimates and fixed scheduling instants. Fixed times use the device's local day after travel; floating times retain their wall-clock date. Signed-out snapshots clear task data. Daily timeline entries use actual local midnights across daylight-saving changes; stale snapshots ask the user to refresh. Widgets use cached app data and require the app to refresh remote changes.

Selected project/label/filter scopes and direct completion are still planned. Source renders and model tests do not establish every installed host, accessibility size or distribution entitlement. See [P0_IMPLEMENTATION.md](docs/P0_IMPLEMENTATION.md) for the verified scope. The distributed ad hoc DMG currently excludes widgets; desktop installation needs an App Group-capable provisioned build.

## Backups and restore

Versioned JSON export, validated restore previews, both matching policies, encrypted manual/daily recovery copies and 20-copy retention are implemented locally in this app. See [backup behavior and verification scope](docs/BACKUPS.md). Private recovery files stay on their device; portable exports work across the native apps.

## Reviewed sync edits

Both native clients use guarded task edits and review overlapping changes before continuing. Later offline work remains queued; older edits without a baseline require review. See [sync review behavior and verification](docs/SYNC_CONFLICTS.md).

## Multiple reminders

The inspector’s Reminders screen supports fixed dates and offsets before or after planned time, per-task opt-out, device/workspace delivery permission and visible scheduling feedback. Reminder choices sync with iOS through the guarded task queue. Completion, deletion, rescheduling and account switches invalidate stale reminders and snoozes. See [behavior, the persisted contract and the remaining remote delivery plan](docs/REMINDERS.md).
