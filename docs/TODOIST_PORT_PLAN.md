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

The four original widgets open tasks. My list now adds a separate completion button, account-bound tokens, a durable credential-free handoff and private save receipts; the installed iPhone gallery, list picker and saved selection are now observed, but configured timelines and completion remain unverified because the local Simulator rejects the ad hoc app/widget team identity. [Signing evidence and remaining host gates](P0_IMPLEMENTATION.md#7-october--installed-my-list-picker-and-signing-diagnosis). Todoist supports configurable task views and direct completion on supported Apple widget sizes, so interactive completion and configuration remain real parity work. [Todoist Apple widgets](https://www.todoist.com/help/todoist/features/use-a-todoist-widget-on-an-apple-device-ptRdme)

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

Deadline radar and A small window now have independent native implementations, with per-instance look-ahead/budget, built-in scopes, palette and name privacy. Their source/model checks are recorded in [P0_IMPLEMENTATION.md](P0_IMPLEMENTATION.md); installed-host verification remains separate. Selected project/label/filter scopes and My list completion buttons are implemented; remaining host/runtime and paired-device acceptance are pending.

Current implementation evidence is tracked in [P0_IMPLEMENTATION.md](P0_IMPLEMENTATION.md). The gap table below includes implementation updates to the initial audit baseline; the P0 tracker records the deployed importer/planning schema and native saved-filter/organization work, its tests, and remaining acceptance gaps.

## Todoist gap audit

Priority: P0 enables daily usefulness or protects data; P1 expands planning and organization; P2 covers advanced integrations and teams. The table states Taskfold source findings; linked sources establish Todoist behavior, not Taskfold's implementation quality.

| Capability | Taskfold finding | Work to port | Priority |
| --- | --- | --- | --- |
| Inbox, Today, Upcoming, priorities, descriptions, labels, search | Present on native and web clients | Keep regression coverage; these are not missing features | Maintain |
| Projects, sections, list and board layouts | Present; device-specific polish differs | Preserve existing layouts and section collapse | Maintain |
| Subtasks, comments, file attachments | Present; embedded arrays and depth differ between clients | Stable child IDs, equivalent hierarchy/editor behavior, item-level conflict handling; audio comments and richer text are absent | P1 |
| Task quick entry | References, stable labels, date/time/priority, estimate/deadline, multiple reminder tokens and full-rule repeat previews implemented in both native apps; repeat phrases include weekday sets, monthly ordinals, yearly dates, completion anchoring, ISO or named start/end boundaries and count limits; cursor-local project/section/label/member suggestions retain explicitly chosen identities; planning menus preview supported date/time/repeat/reminder phrases | Named planned dates/deadlines and repeat boundaries are implemented; sub-day/multiple-monthly rules, remaining richer date grammar and native acceptance | P0 |
| Saved filters and favorites | Versioned query AST/evaluator, builder, named views, favorites, list/board choices, ordered comma-query lists and synchronized preferences/orders implemented in both native apps | Full Todoist query-language/import coverage and paired native/offline/account acceptance | P0 |
| Date versus hard deadline | Independent deadline, editor controls, filters, badges, bulk set/clear with grouped undo, import, backup and Deadline radar implemented; moving the plan preserves the cutoff | Remaining paired/device acceptance and native Mac bulk interaction | P0 |
| Task duration and calendar time blocking | Estimates and hourly Day planner, all-day lane, overlaps, drag/resize undo, DST handling and selected EventKit busy time implemented; readable large-text agenda and inline estimate validation now independently owned by both apps | Remaining Mac runtime, full calendar/tablet/VoiceOver, real calendar-permission, physical and paired-device acceptance | P0 |
| Fixed versus floating time | Floating wall-clock plans and explicit zoned instants implemented, including local-day projection and the second DST fold | Physical travel, closed-app floating reminder behavior and remaining native interaction acceptance | P1 |
| Advanced recurring dates | Daily/weekly/monthly/yearly/custom rules, weekday sets, ordinals, ISO boundaries/count limits, completion anchoring and late-completion skipping implemented with native controls and retained month/leap-day anchors | Named boundaries are implemented; multiple monthly dates, sub-day/holiday rules and paired/physical/Mac runtime acceptance | P1 |
| Flexible reminders | Multiple fixed/relative and independent calendar reminders, quick entry/suggestions, per-task opt-out, device/workspace permission feedback, guarded actions, snooze reconciliation and account-owned configurable snooze and timed-task automatic defaults implemented in both native apps; local Simulator background/closed-app/cold-action acceptance passes; physical and paired native UI evidence remains | Remote delivery activation/acceptance, assigned recipients and sub-day independent rules; location and urgent delivery later | P0/P2 |
| Configurable and interactive widgets | Twelve native kinds, including Project pulse, Day capacity, Inbox reset, Pinned note and the current-session Focus timer; My list supports project/label/filter choices and Deadline radar/A small window can narrow to a chosen list; instance-specific horizon/budget, privacy, appearance, task/list links and My list completion with durable retry | Manual grouped ordering, and remaining paired-device/all-family/privacy/installed-host acceptance | P1 |
| Favorites, subprojects and project archive | Native favorites and synchronized ordering exist; project hierarchy/archive remain absent | Stable hierarchy, cycle prevention, safe archive/restore and full favorite lifecycle acceptance | P1 |
| Templates and bulk capture | Duplicate task and bulk actions exist | Reusable project/section templates, multi-line task paste and task presets | P1 |
| Google and Outlook calendar integration | Hourly native planner and selected read-only EventKit calendars implemented; external provider OAuth/mirroring absent | Real calendar permission/provider acceptance, Google/Outlook adapters, explicit mirroring and reconciliation | P1 |
| Completion history and productivity goals | Metadata-only task transition ledger, honest Project pulse current counts/history and dedicated Project pulse widget implemented in both native apps; coverage begins at actual recording epoch | Daily/weekly goals, broader Insights and remaining native paired/device/widget-host acceptance | P1 |
| Collaboration and team workspaces | Project invites exist; Mac and current iOS have assignment/member UI; both native clients now own guarded edit transport and review; native paired-device evidence and Android parity still need work | Align assignment UI and conflict handling, shared activity, mentions; team roles/folders/admin later | P1/P2 |
| Export, backup, restore, migration | Versioned/legacy JSON export, validated restore preview, encrypted retained copies, recovery UI and current Todoist API importer implemented | Native pair/offline restore, external file-provider round trips and real provider import acceptance; preserve/report unsupported fields | P0/P1 |
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

Implementation update, 6 October: both native editors show validation beside the relevant field; board columns scroll to lower cards and widen in short views to retain readable accessibility text. iOS keyboard dismissal and board completion have explicit 44-point targets. [Current usability evidence](P0_IMPLEMENTATION.md#6-october--saved-filter-keyboard-feedback-and-board-usability) records native acceptance; full query-language coverage, Mac interaction, paired/offline/account and access-revocation acceptance remain open.

### Saved-filter query extension — 6 October

Both current native implementations support `search:`, `recurring`, `no time`, `no labels`, `no priority`, `#Project`, `#Inbox`, `%label` and the compatible `@label` alias, alongside the existing Boolean/date/priority/target/assignee/estimate conditions. The visual builder exposes Keywords, Repeating tasks, No planned time and No labels near the top of its menu. Keywords match every whitespace-separated word anywhere in the title or description, in any order, with invariant case/accent folding. Comments are excluded. Quotes protect operators and punctuation; they do not request an exact phrase. No planned time includes undated and all-day tasks. No labels tests the stored label list, including legacy names. Recurring uses the stored recurrence flag. These predicates never manufacture capture dates, times, labels or repeat rules.

Queries keep stable target IDs in the existing version-1 document. The current editors preserve unsupported documents and disable Save rather than replacing them with Today. Both repos own their sources and tests; neither app builds against its sibling. This protects the updated clients; previously shipped older clients still require upgrade/rollout acceptance before editing queries containing new fields. [Implementation and evidence](P0_IMPLEMENTATION.md#6-october--keyword-and-metadata-filters-with-query-preservation) separates local/native/stub evidence from paired-device acceptance.

The [official Todoist filter reference](https://www.todoist.com/help/todoist/features/introduction-to-filters-V98wIH), checked 6 October and dated 4 September 2026, documents `%` as the current label prefix, with `@` temporarily supported. Its `due` query uses a deadline when no planned date exists, and comma-separated queries produce separate result lists. Taskfold keeps its existing planned-date meaning for `due`, Today and Overdue. A comma outside quotes gives an explicit unsupported-section error; it is never converted to OR. Full Todoist query-language parity is still open.

The remaining port work is ordered by contract dependencies:

| Work package | Implementation plan | Acceptance gate |
| --- | --- | --- |
| Explicit planned-date and effective-due semantics | Add `date` aliases and new explicit effective-due predicates with date-first/deadline-fallback evaluation. Retain the meanings of existing stored `due`/Today/Overdue predicates. Design AST capability/version handling and a joint minimum-client rollout before adding incompatible constructs. | Planned-only, deadline-only, both and neither fixtures agree in both repos; old documents, capture defaults, deleted references, backups and widgets retain their meanings. |
| Relative date/time grammar | Reuse pure civil-day/instant resolution from the native planning core for tomorrow/yesterday/weekdays, named dates and before/after windows. Specify inclusive/exclusive boundaries, source zone, floating days, DST gaps/overlaps and next-week preferences explicitly. Keep parser suggestions free of task mutation. | Frozen-clock fixtures cover midnight, travel, half-hour DST transitions, deadlines without plans and exact time boundaries; native previews/list IDs and widget expiry agree. |
| Hierarchy, creation, wildcards and collaboration | Complete subtask/parent selection, descendant-project forms, shared/personal scope, dynamic assignee-name patterns and assigned-by metadata. Exact collaborator name/email resolution saves stable identities; Assigned/Others state conditions are implemented independently in both native apps. Dynamic project/section/label name patterns, literal stable-ID selectors and section-name shorthand are implemented in both native apps; remaining hierarchy and dynamic assignee-name grammar stays open. Creation on/before/after is now implemented; retain its recorded-metadata semantics and complete the native interoperability gate. Persist concrete identities where possible and validate access before evaluating negation. | Ambiguous/deleted/renamed names never retarget silently; hierarchy cycles are bounded; legacy timestamps/labels and shared-project revocation are covered. Real paired native account/access changes remain required. |
| Multiple query sections | Extend the AST to represent ordered result sections instead of Boolean OR. Define per-section grouping, sorting, completion behavior and capture destination; update app layouts, backups and widget projection/availability rules together in each repo. | `today, overdue` renders two distinct named lists in the chosen order; duplicates across sections are intentional; unsupported older clients preserve the document; restoration and selected widgets do not flatten it. |
| Native interoperability and polish | Exercise saved query creation/editing on one signed-in native client and read/edit on the other, then offline replay, conflicts, restart, sign-out/account switch, restore and revoked project/label access. Verify rich grammar feedback with keyboard, VoiceOver, large text, phone/tablet orientations and unlocked Mac. | Recorded user flows prove identical IDs and persistence across the two apps, with no cross-account data, silent query broadening, clipping or lost edits. Unit/HTTP stub success alone does not close this gate. |

Do the first package's compatibility design before shipping the later grammar/section work. The existing Phase 1 estimate is a foundation estimate, not a commitment for the entire Todoist language. Each package should land as independently deployable native changes plus a compatible contract and matching fixtures; update this status only after its acceptance gate passes.

### Civil-day date sources — 6 October

Implemented independently in both native repositories. The expression editor and condition builder now distinguish planned dates, deadlines, and effective due dates (planned date first, deadline only if there is no plan). This follows the date/deadline distinction in [Todoist’s current filter documentation](https://www.todoist.com/help/todoist/features/introduction-to-filters-V98wIH), while preserving Taskfold’s existing stored semantics.

| Source | On | Before | After | Version 1 predicate fields |
| --- | --- | --- | --- | --- |
| Planned day | `date:tomorrow` | `date before:today` | `date after:yesterday` | `planned_on`, `planned_before`, `planned_after` |
| Plan, otherwise deadline | `effective-due:today` | `effective-due before:tomorrow` | `effective-due after:yesterday` | `effective_due_on`, `effective_due_before`, `effective_due_after` |
| Deadline only | `deadline on:tomorrow` | `deadline before:today` | `deadline after:yesterday` | `deadline_on`, `deadline_before_day`, `deadline_after` |

All three compare civil days. Before/after exclude the boundary day; an absent candidate never matches. A task with a future plan and a deadline today is absent from `effective-due:today`, because its plan takes precedence. Existing `due:YYYY-MM-DD`, `before:YYYY-MM-DD`, Today, Overdue and Next days remain planned-only. Existing `deadline:today`, `deadline:overdue`, `deadline:nextN`, fixed `deadline:YYYY-MM-DD` and `deadline-before:YYYY-MM-DD` remain unchanged. `deadline:tomorrow` and other newly supported phrases select the new deadline-on field. Native UI explains the source choice; no silent conversion of an old document occurs.

References persist as validated lower-case strings, not a date frozen when the filter is saved. Supported references are strict ISO days, today/tomorrow/yesterday, English weekdays/abbreviations and next weekday, named English dates with optional year/ordinal, next month/year, end of month/year, `in N days` and `N days ago` (0–3650). Bare weekdays include today; next weekday is strictly future. Named dates without a year choose the next valid occurrence including today, so February 29 may resolve to a future leap year. Next month uses the same day with Gregorian calendar clamping; next year is January 1. Each daily evaluation uses the viewer’s Gregorian calendar/time zone. Fixed plans use their actual instant converted to the viewer’s day; floating plans and date-only deadlines retain their stored civil day. Relative offsets add calendar days, never 24-hour durations.

Exact day offsets are not Todoist’s multi-day window syntax. Bare `3 days`, `-3 days`, sliding sub-day windows, slash dates, configurable next week and ordered comma sections are still unsupported. Scheduled clock and explicit date-at-time conditions are implemented below; the other forms remain unsupported and rejected without task mutation. Use `in 3 days` for an exact relative day. Commas in a named date require quotes. Builder value input and expression feedback keep Save disabled for invalid values.

Capture defaults resolve explicit planned-on/deadline-on conditions to their own field on the capture day. Effective due and all before/after comparisons never invent which source to populate; negation/conflicting OR/AND retain conservative defaults. Query cache keys include the current day and viewer time zone; changing a plan or deadline invalidates results. Widget projections evaluate the same native AST separately for each of eight civil days, retain only matching IDs, and ask for refresh after projection expiry or travel. No AST, private descriptions or date phrase is added to widget data.

**Compatibility and rollout:** this adds predicate capabilities inside version 1; it adds no operator, document structure, REST column or schema migration. Both updated clients parse the same fields and canonical strings, and both own their sources/tests/release inputs. A client without these fields must preserve the complete document, show an unsupported-query state, disable editor Save/mode switching and never substitute a default predicate. The prior preservation checkpoint is the minimum safe reader baseline: iOS `c8d96f8` and Mac `362b3ad`. New capabilities may be used across devices only after both clients contain this date-source implementation. Clients predating the preservation baseline require upgrading; their behavior is not retroactively fixed. Do not bump version 1 or rewrite older predicates merely to relabel dates. Future instant windows/ordered sections require a separate capability/version and rollout design.

**Evidence and remaining gate:** both owned packages pass 429 Debug and optimized tests (four optional integration skips), including planned-only/deadline-only/both/neither, old document identity, strict boundaries, civil midnight/leap days/multi-zone DST, malformed/unsupported grammar, capture defaults, cache/queue round trip, backup account remapping and eight-day widget membership/privacy. Native UI acceptance and final release verification are recorded in `P0_IMPLEMENTATION.md`. The first work package’s core contract is implemented; actual signed-in create/read/edit on the other native client, offline/conflicts/revocation/restoration and unlocked Mac interaction remain acceptance gates. Sliding sub-day windows, configurable next week, richer grammar, hierarchy/collaboration and ordered sections remain work, and the full P0 objective stays active.

The native Store/view boundary now independently owns an observable Gregorian civil-day/viewer-zone context in both repositories. Active roots refresh at midnight, on clock notifications and on foreground activation; changing context reschedules the next wake. Lists, editor previews, capture defaults and saved-view grouping use that same context, while selected days and persisted task/query/queue fields remain unchanged. Isolated phone and tablet list/editor walks pass, including a silent timer-driven midnight and normal foreground activation; both cores pass 432 Debug/optimized tests. See [native civil-day evidence](P0_IMPLEMENTATION.md#6-october--observable-civil-day-refresh-in-native-views). Mac UI-test compilation passes, but its runtime and actual signed-in paired/account/restore/revocation checks remain open; this checkpoint does not close those native gates.

For later sub-day filters, include evaluation time in cache identity and define refresh cadence. Extend private widget membership to validity intervals/transition entries before accepting time windows: a day-only membership must never remain authoritative after an intra-day boundary. Older hosts must request refresh for an unsupported temporal projection instead of displaying zero or stale matches. Installed/physical temporal-widget acceptance and the richer grammar/ordered-section packages above remain open.

### Scheduled clocks and explicit date-at-time filters — 7 October

Both independently owned native clients now support visual **Time at/before/after** conditions and expressions such as `today & time before:2pm`. Planned/effective-due date predicates accept `today at 14:00`, with canonical source-compatible values retained through saved-view queues, cache, backups and widget membership. This adds a useful morning/evening workflow and the documented Todoist `date:today & date before:today at 2pm` shape. [Primary reference](https://www.todoist.com/help/todoist/features/introduction-to-filters-V98wIH).

Clock-only conditions use the viewer’s displayed scheduled minute on any day; combine with a day predicate to narrow them. Dated clock conditions compare the scheduled instant against a viewer-zone boundary, resolve gaps to the next valid minute and repeated boundaries to the first occurrence, and preserve a task’s chosen second fold. Before/after excludes the boundary minute. Date-only and deadline-only semantics retain their existing meaning; timed conditions require an actual plan and clock. Capture stays conservative. See [the complete contract](SCHEDULED_TIME_FILTERS.md).

These predicates are deterministic within an evaluation day and zone. They do not need intra-day timer refresh or a new temporal widget projection. Sliding `now`/`+4 hours` windows still need those capabilities; ordered comma sections still need an ordered-result AST and coordinated native layouts/backups/widget handling. Configurable next-week, richer grammar and hierarchy/collaboration queries remain open. Native acceptance evidence is recorded in `P0_IMPLEMENTATION.md`; actual signed-in paired/offline/Mac/physical/widget-host/distribution acceptance and the full P0 objective remain active.

### Phase 2 Deadlines and time estimates

Estimated 2–3 engineer-weeks, after the query foundation.

- Add nullable `deadline_date` and `duration_minutes` with validated bounds and backward-compatible codecs. Preserve current `due_date`/`due_time` semantics as the planned work date/time. Keep deadline unchanged when rescheduling planned work.
- Decide explicitly whether a standalone estimate is allowed without a scheduled time; recommended yes for “A small window.” A timed block additionally needs a planned date/time. Todoist's duration requires scheduled date and time; the standalone estimate is a proposed Taskfold improvement.
- Add distinct editor fields, deadline badges, deadline/date filters, bulk editing, quick-entry duration and `{deadline}` chips, recurrence copying rules, undo and import mappings.
- Use one timestamp/date policy across clients. Add `time_mode` and IANA `time_zone` before introducing travel-sensitive calendar sync; migrate existing times as floating to preserve behavior.

Acceptance: moving a task to tomorrow never moves its deadline; old caches decode; undo restores both fields; recurrence does not copy an expired one-off deadline; exports/imports preserve supported fields. Fixture travel from Copenhagen to New York keeps a fixed instant fixed and a floating 09:00 at 09:00.

Implementation update, 6 October: both native apps now own bulk deadline set/clear previews with grouped undo, preserved planning/reminder fields, captured selection/workspace and current-record application. iPhone cancellation, set, undo/redo, clear, relaunch and dark largest-text walks pass. Mac interaction and paired native sync remain acceptance work; see [P0 evidence](P0_IMPLEMENTATION.md#6-october-bulk-deadline-editing).

Implementation update, 7 October: both apps independently own inline bounded estimate feedback and a readable agenda at accessibility text sizes, retaining the graphical timeline as a view choice. Agenda scheduling, completion and adjustment use the existing durable mutations and undo. The iOS day header scrolls with the planner in short/large-text layouts, all-day links reveal the actual scheduling control, and the estimate keyboard has an explicit Done action. Targeted phone/tablet acceptance and remaining gates are tracked in [P0 evidence](P0_IMPLEMENTATION.md#7-october--readable-planner-and-reachable-scheduling). Complete calendar/VoiceOver, real provider, physical, paired and Mac runtime checks remain required; this checkpoint does not complete Phase 2 or P0.

### Phase 3 Reminder and recurrence reliability

Estimated 3–4 engineer-weeks; schema follows Phase 2.

- Implemented in both native repos: version 1 `reminder_specs` with stable IDs, fixed instants or planned-time offsets, explicit opt-out, retained future fields and per-workspace/device delivery controls. Relative reminders follow task recurrence; one-off fixed reminders stop at that occurrence. Legacy opaque strings remain unchanged. See [reminder behavior and the detailed remote delivery plan](REMINDERS.md).
- Both native repos now own scheduling fixtures, complete/snooze/tomorrow actions, status/error feedback and permission controls. Remaining acceptance includes native Mac interaction, physical/background delivery, closed-app floating-time travel and complete account-switch walks.
- Remote delivery remains P0. Register owner-scoped devices, reconcile per-reminder occurrences, claim private delivery jobs with leases/retries, connect APNs and email, and choose one delivery authority per event/device. Match worker/native signatures and cancellation semantics before enabling it. APNs/Android push credentials and email provider setup are release dependencies. The existing due-minute OneSignal worker needs this occurrence model.
- Implemented in each native repository: scheduled versus completion-relative task rules, yearly and nth/last-weekday patterns, ISO start/end/count, missed-date skipping and retained month/leap-day anchors. Completion retains the existing stable create-only successor identity and guarded retry transport. [Repeat syntax and semantics](RECURRENCE.md) defines the supported subset. Named boundaries are implemented. Independent calendar reminders and their quick-entry suggestions are implemented. Multiple monthly dates and sub-day/holiday rules remain work; native paired/offline and Mac runtime acceptance are still required.
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

Add nullable fields and tables before publishing clients; then dual-read/dual-write where a migration needs it, backfill explicitly, and remove old representations only after supported clients have migrated. Include new fields in both native conflict baselines/RPC validation, native queues, web codecs, exports, import and widget snapshots. Each native repository owns its source and release inputs. Implement and verify relevant contract changes in both repositories independently, then commit and push each; neither app builds from the other checkout. See `REPOSITORY_OWNERSHIP.md`.

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


## 6 October: safe completion prerequisite

The independently owned native completion engines now converge on one create-only successor per parent/day, preserve fixed-zone recurrence after travel, renew nested checklist identities/plans and guard undo/deletion against newer remote work. Both apps review changed deletions before sync can remove the row. The deployed guard preserves RLS and rejects edits made during review. See [the implementation evidence](P0_IMPLEMENTATION.md#6-october-recurrence-identity-and-guarded-deletion) for the 195-test suites, three iPhone user walks and rolled-back backend tests. This closes recurrence/deletion prerequisites for interactive My list actions. The widget completion intent, durable offline requests, stale/account-bound tap rejection, installed-host checks and the broader P0 acceptance backlog remain to be delivered.

## 6 October update: durable My list actions

Both independent native repositories now own completion intents, locked credential-free action files, account-cache receipts and version-tolerant widget projections. Four isolated iPhone app-intent walks pass for recurring completion/retry/undo, queued relaunch, failed-save recovery and another workspace rejection. These call the actual app intent; they do not prove WidgetKit’s system execution routing. [Evidence and next gates](P0_IMPLEMENTATION.md#6-october-durable-my-list-completion).

Before calling this distributed completion safe, add an additive server-owned completion revision. It must change when completion/reopen state changes, survive exports and old-cache upgrades, enter guarded native completion baselines and reject an old queued tap when another device completed and reopened the task while this device was offline. Test the exact cycle with two sessions, retry after lost acknowledgement, legacy queues, and a later edited recurring successor. Conflict resolution must preserve subsequent user edits when canceling an unaccepted derived successor. App-local tokens detect observed state changes; the current server baseline cannot detect an unseen complete/reopen cycle. This is required data-parity work, alongside installed-host routing, account switching, privacy and physical-device acceptance.

## 6 October update: completion-cycle revisions

The server revision work above is now deployed as `20261006031648_completion_revision`, with owned migration/test copies in both native repositories and a backend mirror in the web repo. It counts completion/timestamp changes from this migration forward and cannot be reset by client writes. The guarded RPC compares new native queue baselines, accepts only the immediately following identical-state retry, and rejects later cycles. Explicit offline timestamps are preserved. Legacy deployed clients remain compatible; old native queues without a revision require review in the new clients.

Both native cores predict local revisions, reconcile returned rows before replaying later offline edits, invalidate widget tokens when the server cycle changes, and rebase reviewed completion choices. “Use synced” cancels an unedited, unsent successor if the server task is open; an edited successor keeps its work as an independent task/series. Create-only replay no longer replaces a newer remote successor in the cache. Export/restore accepts the revision and treats it as server-owned metadata. Independent Debug/optimized 216-test suites pass with two optional skips; both run the live two-session native HTTP completion-cycle/retry cases against a disposable account. Rolled-back owner/outsider SQL fixtures pass, and fixture cleanup is verified. [Current runtime evidence](P0_IMPLEMENTATION.md) records the remaining native UI and host gates. Full P0, productive widget follow-ons and paired/offline/physical acceptance remain active.


Final follow-up evidence adds stale-editor completion baselines and completion-cycle notification/snooze cancellation. Both native Debug/optimized suites pass 218 tests with three optional skips, while the earlier live 216-test runs retain the native HTTP evidence above. Eight unique iPhone app-intent/review paths pass; the final largest-text comparison is inspected and checked for full values above the action area. Native Release and signed Mac test-target compilation pass. [Detailed current evidence](P0_IMPLEMENTATION.md#6-october-completion-cycle-revisions-and-retained-offline-work) records host, pair/offline/physical, provider and remaining widget/P0 gates.


### 6 October: Day capacity implementation progress

Day capacity now has independently owned iOS/Mac Today/Tomorrow widgets, palette/privacy, whole-day estimates/working hours/selected-calendar totals and honest unknown/incomplete/expired states. Its native links, iPhone settings/completion/relaunch and largest-text planner/menu walks pass; 228-test Debug/optimized suites and app/extension builds pass. [Current evidence](P0_IMPLEMENTATION.md#6-october-day-capacity-and-accessible-planning) retains the installed-host, real-calendar, physical and paired/offline gates. Project pulse, Pinned note and Focus session remain planned; this milestone does not complete P0 or the full widget collection.


### Inbox reset implementation update, 6 October

Both native apps independently own an Inbox count widget with five/ten/all review batches, palette/privacy and a direct account-bound review route. Review supports project moves, task editing, completion, keeping and latest-decision Undo. Keep preserves Inbox membership; moving preserves task planning/deadline/reminder fields. New arrivals stay outside the captured batch; Review more reaches unreviewed tasks before kept work, and Review again explicitly restarts when only reviewed tasks remain. The final count includes all remaining Inbox work. Decisions use the existing durable queue. [Current evidence and remaining gates](P0_IMPLEMENTATION.md#6-october-inbox-reset-and-native-review) distinguish model/source/app checks from installed WidgetKit, Mac runtime and paired/offline acceptance. Project pulse, Pinned note, Focus session, remote reminders and the full P0 objective remain active.


### 6 October: Pinned note implementation checkpoint

Pinned note now uses explicitly selected task descriptions in independently owned iOS/Mac widgets with small/medium/large sizes, palette/privacy, account-bound identity and exact cached-expiry timelines. Both apps own a catalogue, full-text reader, editing and non-destructive unpinning. Independent owner rows keep different pins from replacing a shared list, and backup restore remaps their task identities. [Current implementation and evidence](P0_IMPLEMENTATION.md#6-october-pinned-notes-and-private-widget-excerpts) covers 251-test Debug/optimized suites, seven note iPhone walks, two creation regressions, source renders and rolled-back backend isolation. Installed hosts, Mac/pair/offline/physical/restore acceptance remain open. Project pulse and Focus session remain planned; remote reminders and all remaining P0 requirements retain their original scope.


Implementation update, 6 October: both native repositories now own richer repeat parsing and controls, including weekday sets, yearly/monthly ordinals, completion anchoring and ISO start/end/count limits. Declined/invalid phrases remain whole and literal; scheduled late completion skips past dates and preserves month/leap-day anchors. [Verified scope](P0_IMPLEMENTATION.md#6-october-richer-repeat-rules-and-native-controls) records 270-test Debug/optimized suites, five distinct recurrence iPhone walks, two editor regressions, a corrected touch-target failure and Mac compile-only acceptance. The unsupported grammar and full P0/runtime gates remain in scope.


Implementation update, 6 October: both native repositories now own cursor-local reference suggestions in capture and title editing. Project/label collisions have explicit typed choices, and sections/members use the selected project. Draft identity choices are revalidated, while persisted tasks use existing stable IDs. Mac Day capture uses the same panel; inspector choices apply through normal autosave while other parsing feedback remains available. [Behavior](QUICK_ENTRY_SUGGESTIONS.md) preserves literal text, surrounding title content and normal Save/More flows. [Verification](P0_IMPLEMENTATION.md#6-october-cursor-local-reference-suggestions) records 287-test core suites, five distinct new iPhone walks, three regressions and final native builds, with Mac runtime still pending. Date/repeat/reminder suggestion menus, richer grammar, native Mac/hardware keyboard, paired/offline/account/physical/iPad and the full P0/widget gates remain active.


Implementation update, 6 October: supported date/time/repeat/reminder phrases now have cursor-local native suggestions in both repositories. Previews use the actual parser and inherited draft fields. Adding a time retains an existing future plan, and keeping a partial reminder leaves earlier reminders accepted. [Verification and limits](P0_IMPLEMENTATION.md#6-october-planning-suggestions-and-preserved-plans) records independent 304-test core suites, six distinct planning iPhone walks, two reference regressions and final native builds; Mac runtime, richer grammar/independent reminders and the remaining full P0/widget/device acceptance stay open.


### 6 October: Focus persistence foundation

Both native apps now own a durable task-bound timer and conflict review backed by deployed account-scoped guarded state. Timestamp clocks survive app process death; portable backups freeze running sessions as paused checkpoints and restore against the target revision. Authenticated request/retry/refresh and queued mutation scopes reject stale accounts. [Implementation evidence](P0_IMPLEMENTATION.md#6-october-durable-native-focus-sessions-and-account-scoped-transport) and [Focus contract](FOCUS_SESSIONS.md) separate passing core/SQL/iPhone fixtures from remaining acceptance. The existing ten-widget collection has no dedicated session timer yet. Implement that widget's privacy/palette, owner-bound routes and timestamp rendering, add finish delivery and improve duplicate/large-task selection before installed-host and paired native acceptance. Project pulse, remote reminders and the full P0 scope remain active.


### 6 October: Focus session widget implementation

The dedicated current-session widget is now independently implemented in both native repositories, bringing the collection to eleven kinds. Small/medium timers use UTC state and bounded system timer text, per-instance palette/privacy, explicit freshness/conflict/unavailable states and account-bound native session routes. The existing Focus suggestion remains useful for choosing the next task. [Current verification and limits](P0_IMPLEMENTATION.md#6-october-focus-session-widget-and-native-routes) records 330-test core suites, native app route/publication fixtures, an installed iPhone small-widget background countdown/open/pause/remove walk and final builds. This narrows the Focus widget backlog; multiple-instance/configuration/account/physical/reboot/closed-app and Mac host acceptance remain open. Finish delivery, Project pulse, native paired/offline acceptance, remote reminder delivery and full P0 retain their original scope.


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

Remote delivery remains unavailable. Before provider integration, resolve restored task identities/accepted-event history and initial-enable/import/backdated catch-up eligibility, then implement native lifecycle/entitlements/opt-in, the scheduled provider worker and local/remote authority. Cold/physical/paired/Mac and all other P0 acceptance gates remain active.


### Task recreation and reminder eligibility — 6 October

The earlier restored-ID/counter-reset gate is resolved by a durable task generation, generation-aware native actions/edit baselines, fresh missing-task restore and retained accepted reminder receipts. The server rejects delayed creations for deleted generations. Catch-up now requires opt-in and server schedule acceptance before fire time, so imports/backdated edits/restores/re-enabling do not generate an old-alert backlog. Both repos own and validate this contract independently. Current editor drafts refuse saving onto a recreated task; explicit conflict review can apply the saved older draft after adopting the new generation.

The independent core suites, 31 native/SQL vectors, actual role fixtures and separate live native Auth/restore tests pass. Release builds and signed Mac test compilation pass; the final focused iPhone checkpoint passes all seven paths. Remaining remote-delivery work is lifecycle/entitlements/explicit per-device opt-in, scheduled provider delivery, authority/deduplication and provider/device acceptance. Native paired/offline/account/restore, physical/cold/Mac/iPad, installed-widget/privacy/distribution and all other P0 acceptance remain required. [Evidence](P0_IMPLEMENTATION.md#6-october--task-generations-restore-safety-and-catch-up-eligibility) distinguishes current implementation from rollout readiness.


### 6 October — APNs worker implementation, delivery disabled

Mac and iOS independently own the APNs adapter, bounded service worker, two exact deployed migrations, actual-role SQL fixtures and credential-free test script. Each script passes 23 tests with both entrypoints typechecking. JWT signature verification, scoped sandbox/production keys, headers/4-KiB payloads, large-title/private-note bounds, stale leases/held receipts, lost acknowledgements, retry floors and provider failure behavior are covered. Rolled-back queue tests retain all 31 projection fixtures and verify service-only new retry receipts and 15-minute server retry floors. Deployed HTTP authorization/method/disabled checks pass; cleanup confirms zero users/devices/jobs from fixtures. No APNs request, native app mutation, installed Mac replacement or release was made.

Remote delivery remains unavailable. Native lifecycle/entitlements/explicit opt-in, local/remote authority, durable cursor scheduling, credentials, hosted HTTP/2/APNs and physical/closed-app/paired/Mac acceptance remain open. Backend adapter implementation is now complete for this checkpoint; rollout acceptance is not. [Contract/evidence](REMOTE_REMINDER_DELIVERY.md#apns-adapter-and-disabled-worker--6-october) and [operations](APNS_WORKER_OPERATIONS.md) distinguish them.


### 6 October — inactive native reminder registration

Mac independently owns fresh APNs callbacks, public signed-entitlement detection, the inactive coordinator, secure retirement before sign-out and native setup feedback. It shares a compatible contract, not a source/build dependency, with iOS. Both repos pass 394 Debug/optimized core tests (four optional integration skips) and final Release app/widget builds. Mac app/widgets include both architectures; the signed Mac UI-test target compiles only. Three isolated iPhone permission/settings/largest-text flows pass. No Mac GUI, installation, provider or physical push delivery was exercised. [Evidence](P0_IMPLEMENTATION.md#6-october--inactive-native-reminder-registration) and [lifecycle contract](REMOTE_REMINDER_DELIVERY.md#inactive-native-registration-lifecycle--6-october) retain explicit opt-in, authority/deduplication, cursor scheduling, credentials and signed physical/paired/closed-app acceptance gates. Remote delivery stays disabled and the full P0 objective remains active.


### 6 October — durable reminder sweep, inactive scheduler

Both repositories own the deployed durable cursor/lease, current-sweep payload fence, inactive 30-second cron and Vault-backed service configuration. Interrupted runs retain unfinished devices; stale receipts cannot rewind later progress. Both 32-check Deno scripts, real 45-device/grant/expiry/payload SQL checks, marked concurrent database transactions and existing queue/registration regressions pass. Worker v5 and migration hashes match owned source; authenticated HTTP remains disabled and no APNs request occurs. [Evidence and remaining gates](REMOTE_REMINDER_DELIVERY.md#durable-sweep-coordinator-and-inactive-cron--6-october) retain volume/operational acceptance, explicit opt-in, one delivery authority, credentials, signed physical/paired/closed-app/Mac and the full P0 objective. Native app inputs were unchanged; no installed/public release was made.


### 7 October — independent calendar reminder port

The independently recurring calendar reminder gap is implemented in both owned native repositories: version-2 local rows, undated-task schedules, source-zone clocks, inclusive start/end/count limits, native editor and `!every` capture/autocomplete. Historical occurrences consume the original finite limit; task successors do not restart it. Unknown extensions, durable edits and portable restore retain the contract. [Behavior](REMINDERS.md#independent-calendar-schedules--7-october) and [verification](P0_IMPLEMENTATION.md#7-october--independent-calendar-reminder-schedules) distinguish 443-test suites, phone/tablet local runtime/background evidence, real rolled-back guarded transport and native builds from acceptance still required.

Remaining reminder work: hourly/minutely schedules, assigned recipients, configurable automatic offsets/snooze, native paired/offline/Mac/physical runtime, and remote activation. Extend the disabled server’s calendar occurrence/signature vectors, provider payloads and delivery authority before enabling version-2 remote delivery; do not interpret local Simulator delivery or JSON transport as remote readiness. The full P0 objective, provider-account/calendar/import, richer filters and installed/provisioned widget/distribution gates stay active.


### 7 October — calendar projection port checkpoint

Canonical SQL calendar occurrences, shared r5 vectors, original-occurrence payloads and disabled APNs transport are now implemented. Both native civil-day engines agree with Postgres across DST, missing civil days, historical dates, anchored intervals and original finite limits. [Evidence](P0_IMPLEMENTATION.md#7-october--portable-civil-day-and-backend-reminder-validation) records 445-test suites, 33 calendar vectors, native builds/runtime evidence and actual-role backend checks.

Next reminder steps remain one delivery authority with snooze/offline/deduplication recovery; explicit acknowledged per-device opt-in; private signing credentials, hosted HTTP/2 and real physical/closed-app provider acceptance; actual paired native/Mac use; and full-account/device-cohort performance/operations acceptance. Hourly/minutely recurrence, assigned recipients and configurable automatic offsets/snooze remain gaps. Preserve all other P0 and richer filter/widget/distribution requirements; the new source support does not enable remote delivery.

### Creation-date query source — 7 October

Both independently owned native apps now support Created on, Created before and Created after in the condition builder and `created:`, `created before:` and `created after:` in expressions. `created on:` is also accepted. Todoist-style negative day offsets, such as `created before:-30 days`, canonicalize to bounded exact relative days; other date predicates keep their existing grammar and meanings. Recorded creation instants use the viewer's civil day; date-only legacy creation metadata retains its day. Before/after exclude the boundary day. Missing or malformed metadata never falls back to a plan, deadline or the current clock. Capture defaults do not set creation metadata.

[Creation-date contract and rollout](CREATION_DATE_FILTERS.md) specifies strict values, day/zone refresh, DST and leap-day behavior, unknown-date negation, backup preservation, private eight-day widget IDs and the minimum safe unsupported-query reader baseline. This is an additive predicate capability within version 1, with no database migration or sibling repository dependency. The creation-date source portion of the hierarchy/creation work package is implemented; hierarchy, target wildcards, collaboration/creation-author predicates, sliding time windows, configurable next week and ordered result sections remain open. Source/build/native evidence is recorded in [P0 verification](P0_IMPLEMENTATION.md); real paired native/account/offline/access changes remain required.


### Productive Focus selection — 7 October

The app entry point for the Focus session widget now has a searchable task sheet in both owned repositories. It distinguishes equal titles with project, section and parent context, searches full notes as well as titles/context, retains stable UUID/generation selection, and rejects a removed, completed or recreated selection before starting. Cancel keeps the previous task; current and conflicting sessions show context. Natural result ordering, wrapped labels and a clear search control improve larger directories and accessibility text. [Contract and remaining acceptance](FOCUS_SESSIONS.md#searchable-task-selection) and [verification](P0_IMPLEMENTATION.md) distinguish native iOS evidence from Mac compilation.

This closes the title-only Focus selection usability gap. It leaves the existing Todoist query, collaboration, calendar, import, reminder/provider, installed-widget, physical-device and actual paired-account work packages active. Search changes no saved task or session schema and adds no deployment dependency between the repositories.

### Calendar whole-account performance prerequisite — 7 October

Both repositories own deployed migration `20261007055145_reminder_calendar_cohort_budget.sql` and reproducible actual-role cohort/reference tests. Indexed exact named-zone validation and bounded historical count batching replace repeated catalog scans and per-date loops. A five-zone 160-task/3,010-setting fixture reconciles two active platform bindings below four seconds each, with matching occurrences and retry/account/opt-out isolation; both owned SQL and worker suites pass. [Contract and limits](REMOTE_REMINDER_DELIVERY.md#whole-account-calendar-budget--7-october) and [P0 evidence](P0_IMPLEMENTATION.md#7-october--whole-account-calendar-reminder-budget) record this prerequisite separately from production operations.

Next remain one local/remote authority with snooze/offline/ambiguous-acceptance recovery, explicit acknowledged per-device opt-in, hosted/private credentials and real APNs/physical/closed-app/paired/Mac acceptance, then monitored full sweeps at real enrolled volume. Hourly/minutely rules, assigned recipients and configurable automatic offsets/snooze remain gaps. Preserve the other P0, richer filters and installed/provisioned widget/release work; SQL budget success does not activate remote delivery.


### 7 October — Simulator system snooze acceptance

The corresponding iOS implementation now passes six final phone/tablet user flows: light and largest-text settings/relaunch, plus actual OS 5-minute snooze actions, retained delivery after relaunch/settings changes, current 15-minute actions and correct task opening. [Detailed acceptance](REMINDER_SNOOZE.md#7-october--actual-system-snooze-action-and-retained-delivery) and own retained evidence distinguish iOS/iPadOS runtime from previous Mac compilation. Mac production sources and release inputs are unchanged. Physical/provisioned and cold-process delivery, paired native account/offline/restore, Mac runtime, remote authority/APNs/provider and broader full P0 gates remain open.

The older reminder checkpoints above list configurable snooze as a gap at their historical baselines. The synchronized configurable-snooze implementation and subsequent Simulator OS acceptance supersede that item. Automatic reminder offsets, hourly/minutely rules and assigned recipients remain implementation gaps; physical/paired/Mac/remote acceptance remains separate.


### 7 October — saved startup actions and closed-app local delivery

Both independently owned app delegates register the saved snooze choice at launch. Two final iOS 26.5 phone/tablet Simulator walks pass with the app terminated before both original and retained delivery; actual OS actions and task opening start new processes without test arguments. [Closed-app contract and evidence](REMINDER_SNOOZE.md#closed-app-notification-acceptance--7-october) distinguishes runtime acceptance from own universal Mac compilation. Physical/provisioned/locked, actual paired account/offline/restore, Mac runtime, remote/APNs/provider and broader P0 gates remain open. No Mac GUI or installed replacement occurs.


7 October — [Automatic timed-task defaults](AUTOMATIC_REMINDERS.md) are implemented in each native repo, with owner-scoped semantic sync, ordinary relative task rows, manual-choice preservation and native capture previews. The existing all-day 8 AM behavior remains. Release, Core, SQL and final native evidence are recorded with the feature. Full P0 and paired/physical/Mac runtime acceptance remain open.


## 7 October — per-device delivery handoff

Both independently owned apps now implement explicit per-device consent, serialized local drain, nonce/cutoff activation, durable pending/offline/restart recovery and exact off/retirement confirmation before future local originals resume. Missing or mismatched secure installation/consent state fails closed. Existing snoozes and Focus stay local; consent is excluded from workspaces and backups. The two authority migrations are deployed with availability false and no pilots. Each owned Core suite passes 501 tests with four existing optional integration skips; ten owned actual-role SQL suites pass and roll back. Owned Release app/widget and Debug app/widget/test-target compilation passes, including both Mac architectures. See [contract, scoped verification and rollout gates](REMINDER_AUTHORITY.md). Eight final isolated iOS Simulator flows pass across iPhone and iPad, including handoff/relaunch/lost-response recovery and light/maximum-accessibility-dark presentation; this does not establish Mac runtime or real provider/paired-device acceptance. Provider ambiguity/privacy, provisioned/physical/Mac runtime, paired/offline/access-revocation, reinstall management and production-volume/operations acceptance remain open. Full P0 remains in progress.


Implementation update, 7 October: dynamic project, section and label name patterns are implemented independently in both apps, including builder, expression editing, account-catalog cache invalidation, offline/backup preservation and matching widget projections. Four isolated iPhone/iPad native flows pass in light and dark largest text. This closes the name-pattern implementation subset; hierarchy, named assignees, ordered sections, richer grammar and real paired native/Mac runtime acceptance remain open. [Contract and verification](NAME_PATTERN_FILTERS.md). Full P0 remains in progress.

### Assignment query extension — 7 October

Both native apps implement Assigned/Others and exact accepted collaborator names/emails that persist as stable identities. The visual condition picker groups all 45 choices into nine categories and uses a scrollable chooser at accessibility text sizes. The [assignment contract](ASSIGNMENT_FILTERS.md) records unsupported dynamic person patterns, assigned-by metadata, shared/personal scope and hierarchy. Owned checks and remaining native/paired/physical/rollout acceptance are tracked in [P0_IMPLEMENTATION.md](P0_IMPLEMENTATION.md); this extension does not close full filter-language or full P0 acceptance.

### Ordered query lists — 7 October

Both native apps now retain top-level comma query order and display separate lists/board columns, including overlap and empty sections. Completion visibility belongs to each query; manual query/group order keys remap during restore. Widgets keep flat, unique open-task projections and their existing selected-view ranking. [Contract](QUERY_SECTIONS.md) and [verification record](query-sections-evidence.json). Remaining grammar, hierarchy, import and full paired/device/widget-host acceptance remain open.

## 7 October: source-bound native Todoist import review

Both repositories independently implement token/workspace-bound preview approval, strict six-count preview and ten-count confirmed receipt validation, warnings before import, readable receipts and source-bound retry after a lost response. Input changes, workspace changes and leaving preview discard approval; successful receipt clears the token. [Contract](TODOIST_IMPORT_REVIEW.md) and [current evidence](todoist-import-review-evidence.json).

Each own Core suite passes 524 tests with four optional skips. Own Debug/Release builds pass; Mac includes both architectures and its import UI test compiles without a Mac runtime run. Current owner/foreign/anonymous receipt SQL fixtures pass and roll back to zero fixture users/tasks/mappings. Four final iPhone/iPad response-state walks pass with 16 inspected unmodified captures; these do not call Todoist or import task data. The current edge function was observed active as version 41, without deployment changes. Largest phone text uses scrolling and initial title truncation; source-unlocated frame warnings remain recorded. Real isolated provider-account import/persistence/retry, Mac runtime, paired native/offline/restore, physical/provisioned widgets and full P0 acceptance remain active.
