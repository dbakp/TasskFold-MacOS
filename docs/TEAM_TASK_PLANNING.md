# Team task planning edits — candidate, 24 October 2026

This stage extends the guarded team task editor with assignment, labels,
same-project section moves and portable reminder choices. It does not yet expose
team editing in the app: workspace authority refresh, remaining commands and
native review flows must be completed before enabling the existing flags.

## Behavior and authority

The existing `taskfold_edit_team_task` request carries the frozen account/server,
team/project, task generation, action identity, baseline and desired fields.
No new public endpoint or direct table grant is introduced. Existing live-session,
current editor/manager, active-team and unarchived-project checks remain under
locks. Native queued intents retain all four fields through persistence, conflict
review and Undo/Redo. Failed changes stay on the device without a personal-write
fallback.

Assignments accept only current project editors/managers. Explicit recipients'
Auth rows are locked before the team, matching account-removal lock order. The
recipient's live state and role are checked before a new write. A recorded retry
can still acknowledge an applied assignment after its recipient becomes unavailable;
it returns current authorized state and cannot reassign that recipient. Changing
the payload or actor with the same request identity remains a conflict.

Sections must still exist within the original project and are held against deletion
through commit. Cross-project/task-ownership/recurrence moves remain separate
commands. A changed section baseline requires review rather than replacing another
person's move. Labels use bounded text lists; concurrent replacements require review.

Reminder choices use the reviewed portable-reminder validator. Unknown/private
choices and future extension fields already in the task are preserved. New private
choices cannot be inserted through this adapter. Validation runs both on the
submitted values and on the final merge against the current row. Two individually
valid reminder lists cannot merge beyond the twenty-choice limit: the entire edit
rolls back and leaves the remote task/receipt state unchanged. This does not enable
push delivery, request device permissions or fetch holiday calendars.

## Verification

Each independent repo passed 132 planning/edit database checks, 72 linked-batch,
89 lifecycle and 70 discussion regressions: **363 checks** with owned synthetic
PostgreSQL data. These include recipient demotion while waiting, removal of a
section while waiting, stale/replayed requests, rejected fields, reminder extension
and opaque-row preservation, and concurrent merged-list limits. Official advisors
show no new warnings/errors; known dependency-fixture init-plan warnings remain
recorded. All owned database containers are removed.

Each repo passed **182 selected Swift tests** (five new native planning cases),
using its independently generated SQL fixture. These verify the real server reply,
all four persisted fields, atomic local application/Undo, rejected local shapes,
mandatory baselines and dedicated transport. The existing session/reply/batch/
lifecycle/conversation/automation/email regressions remain included. Unsigned Debug
app and embedded-extension builds pass on macOS and iOS Simulator. Evidence hashes
identify the tested source, migration and fixture. Temporary derived builds and
Mac registration are removed after verification.

Reports: `p2-team-planning-evidence.json`, `p2-team-planning-batch-regression.json`,
`p2-team-planning-lifecycle-regression.json`,
`p2-team-planning-conversation-regression.json`, and
`p2-team-planning-native-evidence.json`.

Reproduce the planning checks with all four regression switches set to `1`:
`TASKFOLD_TEAM_LIFECYCLE_REGRESSION`, `TASKFOLD_TEAM_CONVERSATION_REGRESSION`,
`TASKFOLD_TEAM_BATCH_REGRESSION`, `TASKFOLD_TEAM_PLANNING_REGRESSION`, then run
`node Scripts/Database/test-team-task-edits.mjs <report> <native-fixture>`.
The batch/lifecycle/discussion scripts accept the planning switch after their
respective preceding layers have been selected.

No hosted deployment, real-data mutation, native team UI/runtime acceptance,
remote delivery or distribution pass is claimed. Checklist/recurrence completion,
comments/mentions/files/service integrations, current-role workspace refresh,
premium team organization/admin/review UI and full privacy/recovery acceptance
remain open. Wider Px, Watch/Wear OS and all user deferrals retain scope.


## Reviewed shared planning selections — 25 October 2026

Both repos now own a source-only `edit` variant of the existing atomic team-task
batch endpoint. It accepts 1–100 distinct tasks from one team, with complete frozen
source records, each task’s project/generation, one group nonce and immutable
member nonces. Native date/remove-date and priority selection actions enter an
explicit review in both apps, listing every task, project and requested change.
Cancel leaves tasks untouched. Save persists one queue entry and one linked Undo
intent; personal/shared, nested/root, cross-team and missing-member mixtures cannot
silently become a partial selection. Already-correct date choices remain members.

The service accepts priority, date/time/zone, deadline and estimate fields only.
Completion/recurrence, assignment, labels, moves, checklists and other content keep
their separate command contracts. The new batch validates the entire source under
canonical nonblocking task locks before applying any member through the existing
guarded task editor. A later member validation failure, trigger fault or busy row
rolls back every task and receipt. Live actor/session, team/setup switches, current
roles and all project archive states are checked before new writes and replay.
Replay confirms the original bounded identity-only receipt without rewinding a
later edit. No whole task body is stored in server receipt tables.

The private local command retains complete baselines and effects through restart.
Projection uses a copy and installs only the complete result. Undo/Redo keeps the
same task generations and renews group/member action identities; it refuses changed
source contents instead of overwriting another person’s work. Raw multi-PATCH
arrays cannot bypass the reviewed batch path. Existing delete/restore batches use
their original implementation and permissions.

This is source and scoped verification, not completed native acceptance. Database,
Core, build and cleanup evidence is in `p2-team-planning-batches-evidence.json`.
Installed iPhone/iPad/Mac review/Cancel/save/retry/Undo, keyboard/spoken/large-text
and live multi-actor acceptance remain required. Deadline and estimate bulk UI
entry, other shared bulk commands and the wider rank-6/Px backlog remain open.
No hosted schema, real task, provider, rollout or deferred release setting changed.


### Optional planning-field compatibility — 25 October 2026

A new regression reproduced Remove Date being refused for a saved task row that
omits unused clock fields. Planning validation now treats those absent optional
values as null without padding or replacing the frozen source record. The opening
row/access check, full selection baseline, bounded body and server checks remain
in force. Immediate projection and Undo retain the original field semantics.
Both independent SQL suites add sparse-row date removal, all-member date clearing
and note-preservation checks (67 cases per repo); actual SQL request/reply fixtures
are regenerated independently. No migration or hosted configuration changed.
Installed walkthrough results and exact limits are recorded separately in
`p2-team-planning-selection-native-evidence.json`.


### Installed planning review and recovery — 25 October 2026

Four distinct scenarios now pass on both iPhone 18 Pro and iPad Pro 13-inch (M5):
priority review Cancel, Save, Undo and normal app relaunch with the exact saved
queue; Tomorrow and explicit date removal; changed-source refusal of the entire
selection; and injected local-save failure followed by one-group retry. Tests
read the app’s real private cache and verify selected identities, unchanged notes,
untouched unselected work and linked edit Undo. Representative default light
review/error/refusal screenshots were visually inspected.

These installed Debug tests use the reserved synthetic team-editor host, normal
Store projection/persistence and intercepted HTTP. They prove local UI/queue and
OS relaunch behavior; they do not prove delivery to a live service or real Auth/
Keychain recovery. The first phone run passed three scenarios and stopped the
priority case on a test assertion that incorrectly searched the underlying list
behind the modal. Scoping that assertion to the review form fixed it; the corrected
priority case then passed on phone, and the final iPad run passed all four cases.
Earlier diagnostic failures are retained in evidence, not counted as passing runs.

Both repos pass 422 focused Core checks (19 batch cases), 67 current real PostgreSQL
planning checks, and independent Debug builds. No new migration or rollout changed.
See `p2-team-planning-selection-native-evidence.json` for exact runs, source hashes and cleanup.
Mac installed/window, keyboard/spoken, large-text/dark/contrast and hosted acceptance
remain open, as do bulk deadline/estimate entry and the rest of rank 6/Px. All user-
deferred release/provider/device work remains deferred.


### Bulk deadline and estimate pickers — 25 October 2026

Both apps now offer deadline and estimate pickers for shared selections before the
existing final review. A non-serializable planning admission freezes every source
row, account/server/workspace/session and access token when the picker opens.
Choosing a value never reacquires current rows as a new baseline. Changed/missing
work or access pauses the complete picker before a request can be authored.

The picker supports Set and Clear, existing-value previews, minute presets and
strict integer estimates from 1 through 10,080 minutes. Invalid values cannot
proceed. Shared Review creates one frozen selection; Edit choice returns to the
picker with its typed value intact. Cancel at either stage saves nothing. Final
Save and Undo retain the established whole-selection queue/RPC and identity rules.
Already-correct members stay in the reviewed shared cohort. Planned dates and
clocks are shown beside current deadlines, and estimates have an explicit Minutes
label. Unrelated plans, notes and unselected tasks remain unchanged.

Personal tasks also gain bulk estimates through their existing undoable personal
selection path; they do not acquire a team command or silently switch realms.
That picker captures source records and account/server/workspace/session and
rechecks current personal custody before applying. Its local save is one undoable
step, not a newly introduced atomic personal server endpoint. Personal deadlines
retain their existing editor. Mac list, inspector selection and Task menu entries
own their platform code independently.

The focused Core suite passes 493 tests in each repository (22 batch cases).
Five final installed scenarios pass independently on iPhone and iPad, covering
Set/Clear, invalid input, Back/Cancel, Save/Undo, personal custody and changed
opening sources. Final review uses the shorter “Review changes” heading.
Core/native logs, screenshots, source hashes, diagnostic corrections and cleanup
are in `p2-bulk-planning-pickers-evidence.json`. The isolated phone/tablet
walkthrough checks real Store/private-cache behavior with intercepted HTTP, not
live hosted/Auth/Keychain delivery. Mac installed/window, keyboard/spoken, larger
text/contrast/dark, broader hosted acceptance and other shared batch/history work
remain open. No schema, provider configuration or rollout changed; all user-
deferred dependencies and the full rank-6/Px backlog retain their scope.


### 2026-10-25 — Whole-selection shared assignment

The shared selection menu now offers Assign shared tasks. The picker captures the
complete existing task/access admission before reading recipients. Each distinct
selected project is queried once per refresh; only their intersection is offered.
A teammate tap rechecks every project before creating review. Partial catalogs,
foreign project/access replies, changed tasks and replaced account/workspace/session
cannot create a command. Cancel invalidates late directory replies and stops later
project reads. An already reviewed identity can remain a frozen offline intent;
non-network errors clear the choices. A confirmed loss in any refreshed project
stops immediately, so a later network error cannot revive the cached choice.
Unassigned and You need no directory.

Review lists every task and the explicit destination person or Unassigned. Edit
choice returns to the picker; Cancel saves nothing. Already-correct tasks remain
members of the frozen group. One existing edit command/RPC saves the whole cohort;
linked Undo restores each member’s own original assignment with fresh action IDs.
The UI does not turn a display name, catalog or task creator into authority.
Personal/shared mixtures, nested projections and cross-team cohorts are refused
as a whole by the shared admission rather than silently dropping members.

Each independently owned migration extends the existing private planning batch’s
strict field allowlist with assigned_to. Recipient values are validated before
casts; canonical Auth recipient locks precede team/project/task locks, matching
the guarded single editor. Every new member delegates live recipient role and
ban checks to that editor inside the same transaction. Late failure rolls back
all task writes and group/member receipts. A recorded retry only acknowledges its
original result and does not reassign tasks if a recipient later leaves or is
banned. Actor access and current project/team state are still rechecked.

Each repository passes 96 isolated database checks on the assignment-enabled
schema and 67 legacy planning checks, with no new advisor findings. The focused
Core suite passes 502 tests; the final 23-case batch rerun strengthens sparse
assignment Undo coverage. Installed phone/tablet cases separately exercise native
review/cancellation, durable Save/Undo/relaunch, clear and changed access/source.
Three final installed scenarios pass independently on iPhone and iPad. Six
standard-light review/clear/refusal screenshots are visually inspected.
The native fixture uses two tasks in one project; cross-project behavior is
verified independently by the Core intersection and real SQL transactions.

No new table, public endpoint, configuration, deployment or rollout switch is
introduced. Source-only migration, isolated SQL/advisor, Core, build and native
acceptance details and their limits are retained in
`p2-shared-bulk-assignment-evidence.json`. Reproduce the isolated database checks
with `TASKFOLD_TEST_ASSIGNMENT_BATCHES=1 node Scripts/Database/test-team-planning-batches.mjs <report.json>`.
Mac runtime, wider hosted concurrency/account/accessibility and the rest of the
ranked Px backlog remain open; all existing user deferrals retain their scope.


### 2026-10-25 — Reviewed shared-source template capture

Saving readable shared work as a template now opens a private-copy contents
review. The name can be edited; Cancel creates nothing. The preview explains
that project/task notes, portable labels and schedule rules are included, while
people, discussions, files and ownership stay with the source. No task is created
by capture. Personal source capture retains its existing direct save flow.

Shared roots and nested children use portable shared label text, independently
of personal label names, IDs and colors. Supported legacy names retain their full
length. Opaque/unsafe/future label structures refuse capture explicitly rather
than silently losing data. The original source and raw metadata remain unchanged.

The transient capture retains full selected project/section/task rows and related
manual-order rows, an opening date for relative scheduling and account/workspace/
backend-session/origin/access context. New/missing descendants, edited or moved
sources, changed access, reauthentication and account/workspace replacement pause
saving and hide the old preview. Revalidation does not replace the opening source
with a new baseline. Unrelated projects/tasks and unrelated personal catalog edits
do not invalidate a wholly shared capture. Save uses one stable private-template
identity and the existing durable owner-only template writer; Mac uses its own
native Undo registration. Existing private template export and fresh-run semantics
remain responsible for subsequent use.

Read permission is not converted into team write permission. A viewer may review
a private copy of accessible work, but this feature does not add a team-owned
template catalog or authorize runs into team projects. Those workflows, broader
live/multi-actor/Mac/spoken/layout acceptance and the rest of rank 6/Px stay open.
No schema, hosted data, provider configuration or rollout switch changed. Exact
Core/build/installed phone/tablet evidence and cleanup are recorded in
`p2-shared-template-capture-evidence.json`; all user-deferred dependencies remain.

Current capture stage: 87 focused Core checks per repository, independent app
builds, three installed scenarios per iPhone/iPad and four inspected standard-
light screenshots pass. See the stage evidence for exact limits.
