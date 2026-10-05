# Taskfold widget and Todoist feature plan

Baseline reviewed 5 October 2026. This plan compares the Taskfold source at that audit with Todoist's public documentation and turns the gaps into an ordered implementation backlog. Fix the outdated Todoist importer first; then deliver saved filters and favorites, followed by separate deadlines and task durations. Those foundations also enable more useful widgets. Estimates below are planning assumptions for one engineer delivering across Swift, Kotlin, web, and backend; they are not delivery commitments.

The iOS checkout was brought forward to current upstream before final validation, preserving its assignment/profile work and the removal of Live Activities. The source audit covers `taskfold-ios-refresh`, `TasskFold-MacOS-refresh`, `Taskfold-Android`, and `taskfold-web-reference`. The older sibling checkouts were left untouched. “Present” means found in source, not proven in a live production account. Backend deployment state and private external integrations were not audited. Reimplement the useful public behavior in Taskfold's own design; no competitor source code or assets are needed.

Implementation evidence and remaining requirements are kept current in [P0_IMPLEMENTATION.md](P0_IMPLEMENTATION.md). The capability table below records the starting gaps; it is not a statement that implemented milestones are still absent. Native repositories now own their sources and release inputs separately.

## Widget direction

The Taska reference is the iPhone/iPad app **Taska To-Do List and Widget**, by Evgenii Pestrev. Its published description emphasizes visible tasks, sticky notes, voice capture, and lightweight lists. The visual direction here uses soft rose, lavender, and mint surfaces, rounded typography, and project color marks. This is an original design inspired by those product ideas, not a claim to have tested Taska's installed widgets. [Taska listing](https://apps.apple.com/tr/app/taska-to-do-list-widget/id6739449779)

### First widget collection

| Widget | Job | Behavior | Supported surfaces |
| --- | --- | --- | --- |
| Today | See commitments and open the right task | Outstanding scheduled work includes overdue tasks, ordered by date, priority, time, and stable ID. Rows open their task; + opens capture. | iOS small/medium/large and existing Lock Screen families; Mac small/medium/large; resizable Android |
| Focus | Reduce the decision to one next action | Earliest outstanding scheduled work first, then undated P1/P2. Shows why it was selected and opens that task. Future priorities never displace current work. Empty state opens capture. | iOS/Mac small and medium; Android |
| Week ahead | Spot busy days before adding more | Seven dates starting today with actual open task counts, plus a separate overdue count. Opens Upcoming. Counts describe task volume, not hours or free capacity. | iOS/Mac medium; Android |
| Quick capture | Save a thought immediately | Opens the existing task composer. It is a capture shortcut, not an editable text field hosted in the widget. | iOS/Mac small; Android |

Apple widgets read the app's App Group snapshot. Snapshots now include undated open work and clear after sign-out; cache loading republishes the selected account. Existing snapshot fields remain compatible. Apple timelines precompute daily entries for a week, use the timeline date for selection, and prompt a refresh when the snapshot is over a day old. Android uses its encrypted repository's active workspace and refreshes on local changes and system widget updates. Neither platform promises live background sync.

Rows open tasks; they do not complete them inside the widget. Keep that distinction visible in the design. Todoist supports configurable task views and direct completion on supported Apple widget sizes, so interactive completion and configuration remain real parity work. [Todoist Apple widgets](https://www.todoist.com/help/todoist/features/use-a-todoist-widget-on-an-apple-device-ptRdme)

Mac widgets still require a provisioned App Group build. The existing ad hoc distribution DMG excludes the extension. A widget source build is not proof that the current downloadable DMG contains it.

### More ambitious productive widgets

| Proposed widget | Useful decision or action | Prerequisite | Acceptance condition |
| --- | --- | --- | --- |
| My list | Keep a shopping list, project, label, or saved filter visible | Stable project/label IDs and saved filter evaluator; per-instance configuration | Two instances can show different views and survive renamed/deleted selections without showing another account's data |
| Deadline radar | Decide what must be worked on before a hard cutoff | Separate deadline field | Shows the nearest three deadlines without treating a postponed work date as a postponed deadline |
| A small window | Pick something that fits 10, 25, or 45 minutes | Reliable duration/effort estimates and selected filter | Suggestions fit the selected time budget; unknown duration is explicitly excluded or labeled |
| Day capacity | Decide whether to accept another commitment | Duration, working hours, and calendar event overlay | Shows planned minutes and known busy time; unknown estimates are reported rather than guessed |
| Project pulse | See progress and open stalled work | Completion/reopen history and project scope | Numerator, denominator, and window are stated; project additions do not create misleading progress claims |
| Inbox reset | Turn uncategorized work into a short triage session | Inbox projection, configurable widget links, triage route | Shows an accurate count and opens review directly, without assigning arbitrary due dates |
| Pinned note | Keep instructions or an idea visible | Deliberately designed note entity or selected task description | Readable text with explicit selection and privacy preference; do not misuse task title as a note store |
| Focus session | Start a timed session attached to one task | Persisted session timestamps and pause/resume rules | Timer survives process death and restarting the phone; it does not depend on widget redraw cadence |

Defaults should be calm and useful. Offer system tint and accessibility contrast, light/dark styles, readable empty states, a hide-task-titles preference, and sizes that prioritize content over decoration. Add per-widget theme selection with the configurable collection; avoid duplicating six widget kinds just for six colors.

Deadline radar and A small window now have independent native implementations, with per-instance look-ahead/budget, built-in scopes, palette and name privacy. Their source/model checks are recorded in [P0_IMPLEMENTATION.md](P0_IMPLEMENTATION.md); installed-host verification remains separate. Selected project/label/filter scopes and direct completion are still pending.

Current implementation evidence is tracked in [P0_IMPLEMENTATION.md](P0_IMPLEMENTATION.md). The gap table below preserves the initial audit baseline; the P0 tracker records the deployed importer/planning schema and native saved-filter/organization work, its tests, and remaining acceptance gaps.

## Todoist gap audit

Priority: P0 enables daily usefulness or protects data; P1 expands planning and organization; P2 covers advanced integrations and teams. The table states Taskfold source findings; linked sources establish Todoist behavior, not Taskfold's implementation quality.

| Capability | Taskfold finding | Work to port | Priority |
| --- | --- | --- | --- |
| Inbox, Today, Upcoming, priorities, descriptions, labels, search | Present on native and web clients | Keep regression coverage; these are not missing features | Maintain |
| Projects, sections, list and board layouts | Present; device-specific polish differs | Preserve existing layouts and section collapse | Maintain |
| Subtasks, comments, file attachments | Present; embedded arrays and depth differ between clients | Stable child IDs, equivalent hierarchy/editor behavior, item-level conflict handling; audio comments and richer text are absent | P1 |
| Task quick entry | Partial: dates, times, priorities, labels, basic repeats | Project/section lookup, assignees, richer recurrence, duration/deadline/reminder tokens, consistent escaping and declined chips | P0 |
| Saved filters and favorites | Missing saved query model; native priority filtering and web combined controls exist | Query evaluator, visual builder, saved views, pinning and synchronized view settings | P0 |
| Date versus hard deadline | One `due_date`; no independent deadline | Nullable deadline, distinct editor controls, badges, queries and import | P0 |
| Task duration and calendar time blocking | Date-based calendar exists; no duration/hour-slot planner | Duration field, timed blocks, overlap handling and drag/resize undo | P0 |
| Fixed versus floating time | Device-local date/time handling; no explicit mode | Zoned instant versus wall-clock mode and consistent travel behavior | P1 |
| Advanced recurring dates | Basic daily/weekly/monthly/custom rules exist | Completion-relative repeats, yearly/ordinal rules and end/start boundaries with explicit semantics | P1 |
| Flexible reminders | Due-date local reminders and notification actions exist | Multiple absolute/relative reminders; remote delivery; location reminders and supported urgent delivery | P0/P2 |
| Configurable and interactive widgets | Four fixed views in this change; task taps open app | Project/filter/label configuration, direct complete with durable retry, privacy and appearance settings | P1 |
| Favorites, subprojects and project archive | No native favorite/hierarchy/archive model found | Stable hierarchy, cycle prevention, safe archive/restore, sidebar pinning | P1 |
| Templates and bulk capture | Duplicate task and bulk actions exist | Reusable project/section templates, multi-line task paste and task presets | P1 |
| Google and Outlook calendar integration | Calendar is currently Taskfold tasks only | Event overlay first, then explicit task mirroring and reconciliation | P1 |
| Completion history and productivity goals | Completed lists exist; no activity ledger, goals, or Insights surface | Completion/reopen events, daily/weekly targets and honest project progress | P1 |
| Collaboration and team workspaces | Project invites exist; Mac and current iOS have assignment/member UI; Mac has conflict review; Android and transport parity still need work | Align assignment UI and conflict handling, shared activity, mentions; team roles/folders/admin later | P1/P2 |
| Export, backup, restore, migration | JSON export and Todoist preview/import exist | Validated restore, versioned backups and current API/schema import; unsupported fields must be reported | P0/P1 |
| Email, browser and automation capture | Android text share and Apple intents exist; no email/API integration layer found | Share extensions, browser capture, email intake, scoped public API/webhooks | P2 |
| Voice and AI capture | Siri/Shortcuts and keyboard dictation can add single tasks | Voice-to-multiple-task review, optional breakdown and filter assistance, preview before changes | P2 |
| Watch and Wear OS | No wearable targets found | Capture, Today and durable complete, after mobile foundations | P2 |
| Rich text, uncompletable headings, print and view grouping | Mostly plain task content; sections available; limited grouping | Safe text rendering, heading flag, print/export layout, per-view grouping and customizable gestures | P2 |

Todoist's public feature catalog confirms the baseline planning, view, collaboration, platform, and capture families above. Its feature names are not a specification for Taskfold's UI. [Feature catalog](https://www.todoist.com/help/todoist/features)

Dedicated references for the most consequential gaps: [filters](https://www.todoist.com/help/todoist/features/introduction-to-filters-V98wIH), [deadlines](https://www.todoist.com/help/todoist/features/introduction-to-deadlines-in-todoist-uMqbSLM6U), [duration](https://www.todoist.com/help/todoist/features/set-a-task-duration-L1kYkZv8d), [fixed and floating times](https://www.todoist.com/help/todoist/features/set-a-fixed-time-or-floating-time-for-a-task-YUYVp27q), [recurrence](https://www.todoist.com/help/todoist/features/introduction-to-recurring-dates-YUYVJJAV), [reminders](https://www.todoist.com/help/todoist/features/introduction-to-reminders-9PezfU).

Organization references: [favorites](https://www.todoist.com/help/todoist/features/add-a-project-label-or-filter-to-favorites-in-todoist-zezDfvSK), [subprojects](https://www.todoist.com/help/todoist/features/create-a-sub-project-in-todoist-aTA15C70), [templates](https://www.todoist.com/help/todoist/features/introduction-to-templates-in-todoist-uofJ8i40M). Expanded delivery: [location reminders](https://www.todoist.com/help/todoist/features/use-location-reminders-in-todoist-uGcwH2AJ6), [urgent reminders](https://www.todoist.com/help/todoist/features/add-an-urgent-reminder-in-todoist-WeBYdY5ra), [calendar integration](https://www.todoist.com/help/todoist/integrations/use-the-calendar-integration-rCqwLCt3G).

Productivity and recovery references: [Insights](https://www.todoist.com/help/todoist/features/introduction-to-insights-mK9DieWyP), [Karma](https://www.todoist.com/help/todoist/features/introduction-to-karma-OgWkWy), [backups](https://www.todoist.com/help/account-and-billing/security/download-or-restore-backups-in-todoist-ywaJeQbN), [voice capture](https://www.todoist.com/help/todoist/todoist-and-ai/dictate-to-add-tasks-with-ramble-P1Raq7vVF).

## Implementation sequence

### Phase 0 Repair the Todoist import boundary

Estimated 3–5 engineer-days. The reviewed edge function still calls `/rest/v2/projects`, `/sections`, `/tasks`, and `/comments`. Todoist announced the shutdown of REST v2 for 10 February 2026; current documentation uses the unified API v1. This is a source-confirmed compatibility risk and the first release blocker to investigate. The deployed edge-function version was not inspected and no private token was used. [Official shutdown notice](https://groups.google.com/a/doist.com/g/todoist-api/c/brwENjfT_tk), [current API](https://developer.todoist.com/api/v1/)

- Update the importer against the current response envelopes, cursor pagination and identifiers; do not perform a URL-only replacement.
- Preserve preview-before-import and add replay-safe source ID mappings. Report unsupported deadline/duration/recurrence/attachment fields until the schema supports them.
- Validate using official response fixtures and an isolated Todoist account, then deploy the reviewed function through the established backend workflow.

Acceptance: preview lists all pages, authentication errors remain useful, labels/sections/child relationships survive mapping, and repeating an import does not duplicate tasks. Source checks do not prove the deployed importer is currently broken; verify that boundary before release.

### Phase 1 Saved filters and favorites

Estimated 2–3 engineer-weeks. Highest immediate value: users can keep “Work today,” “Waiting for,” or “Unscheduled P1” in one place.

- Add account-owned `saved_views` with stable ID, name, versioned query AST, layout, grouping, sorting, favorite order, and timestamps. Add project/label favorite metadata or a separate favorites table. Use existing durable mutation queues.
- Start with today, overdue, next N days, no date, priority, project/section, label, completion and assignee predicates, plus AND/OR/NOT and parentheses. Parse a documented subset of familiar text syntax; don't promise every Todoist query on day one.
- Build visual controls first and expose the text expression for expert editing. Validation errors never silently become an empty successful filter. Evaluate the same fixture corpus in Swift, Kotlin and TypeScript.
- Add sidebar/Browse entries, favorite reordering, missing-target fallbacks and migration from existing per-view local options.

Acceptance: `today OR overdue`, `project:Work AND p1`, `no date AND NOT label:waiting` return identical task IDs on all clients; offline edits persist; account switch removes another account's views; shared-project access revocation removes inaccessible tasks. Saved-view links use stable IDs.

### Phase 2 Deadlines and time estimates

Estimated 2–3 engineer-weeks, after the query foundation.

- Add nullable `deadline_date` and `duration_minutes` with validated bounds and backward-compatible codecs. Preserve current `due_date`/`due_time` semantics as the planned work date/time. Keep deadline unchanged when rescheduling planned work.
- Decide explicitly whether a standalone estimate is allowed without a scheduled time; recommended yes for “A small window.” A timed block additionally needs a planned date/time. Todoist's duration requires scheduled date and time; the standalone estimate is a proposed Taskfold improvement.
- Add distinct editor fields, deadline badges, deadline/date filters, bulk editing, quick-entry duration and `{deadline}` chips, recurrence copying rules, undo and import mappings.
- Use one timestamp/date policy across clients. Add `time_mode` and IANA `time_zone` before introducing travel-sensitive calendar sync; migrate existing times as floating to preserve behavior.

Acceptance: moving a task to tomorrow never moves its deadline; old caches decode; undo restores both fields; recurrence does not copy an expired one-off deadline; exports/imports preserve supported fields. Fixture travel from Copenhagen to New York keeps a fixed instant fixed and a floating 09:00 at 09:00.

### Phase 3 Reminder and recurrence reliability

Estimated 3–4 engineer-weeks; schema follows Phase 2.

- Replace opaque reminder strings with a versioned reminder specification or child table: stable ID, absolute instant or relative offset, channels and timezone semantics. Preserve unknown legacy payloads until explicitly migrated.
- Share scheduling fixtures across platforms. Retain native complete/snooze/tomorrow actions and expose reminder status and permissions in the editor.
- Add remote delivery as a separate backend worker with device registration, event IDs, idempotent deliveries and cancellation. APNs/Android push credentials and email provider setup are explicit release dependencies. Local notification fallback must not double-deliver a remote event.
- Extend recurrence with anchored versus completion-relative rules, yearly and nth-weekday patterns, start/end/count, and skipped dates. Separate the occurrence identity from the series identity. Continue deduplicating successors on retries.
- Location and urgent reminders follow as opt-in platform capabilities; verify current OS support and entitlement restrictions before promising them. Android's current alarms are inexact and should not be marketed as exact urgent alerts.

Acceptance: reminders move/cancel correctly after date edits and completion; completing a recurrence offline twice creates one successor; DST, leap year, January 31, fifth weekday, late completion and end limits pass; sign-out cancels account notifications. Test delivery on physical devices as well as unit scheduling.

### Phase 4 Configurable and interactive widgets

Estimated 2–3 engineer-weeks, after Phase 1; deadline/time-budget widgets depend on Phase 2.

- Create per-instance AppIntent configuration and Android configuration activity selecting view, appearance and privacy. Extend snapshot with stable project/label/view IDs and version. Avoid matching a project by display name.
- Route completion through the application's durable mutation queue. Apple intent execution and Android receiver work must serialize with normal edits; reconcile recurring successors in the same logical change. No separate widget-owned copy of account credentials.
- Refresh after task changes, login/logout, timezone change and due-day rollover; provide stale/offline indicators. For Android, bind pending intents to the correct active account generation so an old widget action cannot mutate a new workspace.
- Ship My list, Deadline radar and A small window; then test direct Complete, Undo and instance isolation. Keep the fixed four views as simple defaults.

Acceptance: two configured widgets remain independent; a completed recurring task advances once; process death and offline completion retain mutations; sign-out hides titles; small/large fonts and tinted widgets remain readable. Verify installed Home Screen/Desktop/Lock Screen widgets, not only rendered source previews. Restore App Group-capable Mac distribution as an explicit signing workstream.

### Phase 5 Calendar planning and integrations

Estimated 4–6 engineer-weeks; depends on duration/timezone semantics.

- Extend the existing calendar into an hourly grid with all-day lane, overlap layout, keyboard scheduling and drag/resize controls. Rescheduling is one durable undoable mutation. Never equate task count with free time.
- Add user working hours and an event overlay adapter. Apple EventKit can supply local calendars where permission is available; Google/Outlook need provider OAuth, refresh-token storage, incremental fetching and reconnect handling.
- Start read-only; separate imported events from tasks. Add opt-in task mirroring only after stable provider-event IDs, deletion policy, retry reconciliation and loop suppression are specified.
- Use visible provider identity, selected calendars and an explicit disconnect action. Persist only needed event metadata and respect event privacy. Build Day capacity from known events and estimates, labeling tasks with unknown duration.

Acceptance: all-day and timed events stay distinct; DST and travel fixtures render correctly; dragging a task preserves deadline; disconnect removes provider overlays; duplicated webhook events do not create duplicate tasks/events. Exercise real Google and Microsoft test accounts before shipping mirror writes.

### Phase 6 Organization and collaboration parity

Estimated 3–5 engineer-weeks.

- Add archived state and project parent IDs with cycle prevention, stable ordering and archive/restore. Define behavior for tasks inside archived projects in search, views, widgets and export.
- Store reusable templates with title/description, sections, task trees, relative scheduling rules and schema version. Preview creation, create fresh IDs, and preserve labels only when they resolve in the target account.
- Retain the current iOS/Mac task assignment and member identity work; audit Android assignment parity and align the remaining UI/transport behavior. Bring conflict-safe transport and conflict review to all clients before normalizing concurrent comment/subtask editing.
- Add a per-project activity ledger and mentions with permission checks. Move comments and child tasks to independently addressable records in a staged migration if concurrent edits remain a priority; retain compatibility with existing arrays until old clients retire.
- Team workspaces, folders and admin/member/guest roles form a separate advanced release, not a relabeling of existing project invites.

Acceptance: archive/restore is reversible; templates don't duplicate source IDs; parent cycles are rejected; two clients editing different comments lose neither edit; departed members disappear from assignments and cannot read or mutate the project. Multi-user fixtures must validate access rules on the server.

### Phase 7 History, Insights and recovery

Estimated 3–4 engineer-weeks.

- Add idempotent task activity events for complete, reopen, reschedule and scope changes. Capture occurrence IDs for recurring tasks. Define event timestamps and local-day bucketing before building goals or streaks.
- Implement daily/weekly goals and project progress with visible scope and time window; handle reopen and changing project scope. Offer rest days. Scoring/Karma is optional and lower value than accurate history.
- Add Project pulse, completed-work trend and factual at-risk lists based on overdue/deadline data. Any predictive health score must disclose inputs and be validated; do not present a decorative score as certainty.
- Provide versioned export, restore preview, malformed-file rejection, ID collision policy and a pre-restore backup. Add encrypted retained backups and a recovery UI with tested retention.
- Update Todoist import against current official API documentation at implementation time. Audit the existing edge function, pagination, sections, subtasks, assignees, deadline, duration, recurrence and unsupported attachment fields. Preview a migration report and deduplicate retries using source mappings.

Acceptance: reopening adjusts goals; recurring work counts occurrences once; restore is verified using an isolated account; corrupt input leaves current data intact; a repeated import creates no duplicate records. Completion timestamps alone cannot reconstruct past postponement history, so do not backfill fictional events.

### Phase 8 Capture ecosystem and advanced clients

Estimated 4–8+ engineer-weeks depending on chosen providers. Begin only after core delivery stabilizes.

- Add native share/browser capture and email-to-task intake with sender validation, quotas and source links. Add scoped API keys, revocation, idempotent writes, webhooks and developer documentation for automation.
- Add voice-to-task drafts with transcript correction and bulk preview; optional AI breakdown/filter generation uses the same task/query schema, then asks the user to apply reviewed changes. Define provider costs and data handling before enabling cloud processing.
- Add audio comments, safe rich text, non-completable headings and native print/export. Build Apple Watch/Wear OS capture and Today with durable offline completion; extend widget/session surfaces only when the same state machine can be reused.

Acceptance: share input never silently becomes an unwanted task; revoked API keys stop working; webhook retries deduplicate; voice drafts are editable before save; wearable edits converge after reconnect. Provider-specific implementation estimates need a spike before scheduling.

## Migration and release rules

Add nullable fields and tables before publishing clients; then dual-read/dual-write where a migration needs it, backfill explicitly, and remove old representations only after supported clients have migrated. Include new fields in Mac conflict baselines/RPC validation, native queues, web codecs, exports, import and widget snapshots. Each native repository owns its source and release inputs. Implement and verify relevant contract changes in both repositories independently, then commit and push each; neither app builds from the other checkout. See `REPOSITORY_OWNERSHIP.md`.

Every exposed new table needs server-side authorization, not just a hidden UI. Saved views/favorites/preferences belong to the account; shared task data uses actual project membership. Check grants separately from row policies; use security-invoker views when exposing aggregates. Validate owner/member/nonmember/removed-member cases with rolled-back fixtures. [Supabase RLS documentation](https://supabase.com/docs/guides/database/postgres/row-level-security)

Use a shared behavior-fixture corpus in JSON for Swift/Kotlin/TypeScript date parsing, filters and recurrence. Release gates include old-cache decoding, offline create/edit/relaunch, two-client edits, sign-out/account switch, widget deep links, notification cancellation, import replay, accessible layout and provider-specific smoke tests. Unit tests alone do not establish push, provider OAuth, production permissions or store distribution readiness.

Track each phase as: schema → model and queue → primary UI → other clients → widget/import/export support → integration verification → release. Ship independently useful phases; do not begin a full Todoist clone before the next daily workflow works well.

## First release backlog

1. Ship and verify the four fixed widgets, with the existing Mac signing limitation stated; repair and validate the outdated Todoist import boundary before promising migration.
2. Build shared filter fixtures, saved views, favorites and visual controls on all clients.
3. Add deadlines, duration estimates and explicit time semantics.
4. Extend reminder/recurrence reliability and configurable widgets.
5. Time-blocking and event overlay follow; then collaboration/history/recovery and advanced capture.

The complete sequence is approximately 24–37+ engineer-weeks under the one-engineer cross-platform assumption, before external-provider approvals and optional wearable/team scope. Re-estimate after Phases 1–2 with measured delivery times. The first two feature phases are the highest-value small release and should take priority over decorative widgets or gamification.
