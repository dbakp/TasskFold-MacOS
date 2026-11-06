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


### 2026-10-25 — Team-owned template library service foundation

Each repository now owns a source-only library migration and isolated runner.
Owners/admins curate; accepted full members read the team-wide library; guests
and outsiders do not gain library access from project access. Both the existing
team gate and a new, default-off library gate are required. Archived libraries
are readable; changes require an active team and current database rights.

List returns at most fifty metadata rows, with no document or author identity.
Get returns the full bounded versioned definition. A continuation carries the
library revision; concurrent publication/edit/removal forces refresh. Publish,
replace and delete use stable request IDs, HMAC-bound receipts and per-template
revision checks. Replays acknowledge original outcomes without replaying edits.
Removed template IDs cannot be reused. Delete returns its last reviewed item
revision and remains available at quota or maximum item revision.

Definitions are opaque versioned storage, distinct from execution authority.
The service preserves newer definitions, enforces a two-million-byte normalized
JSONB limit, caps active templates at 200 and combined definitions at 32 MiB, and
uses the existing administration budget. Any client Use/Edit and future shared
run service must validate the complete supported workflow schema again. No task
or project write grant is created by publishing or reading a definition.

Creator account removal anonymizes creator/receipt actor links without deleting
team-owned work or freeing a used request identity. Soft team deletion purges the
library’s content, state, identity markers and receipts. RLS and revoked direct
table privileges protect the private tables; only the checked RPC mediates access.
Auth/team lock order, role recheck after a held lock, revision conflicts, retries,
quota boundaries, author removal and team deletion pass in 96 real SQL checks per
repository. No new advisor warnings/errors occur; inherited fixture policy
performance notices are retained in the report. No hosted configuration/data was
changed, no migration deployed and neither gate enabled outside owned fixtures.

Typed transport, native library and audience/contents reviews, durable private
large-definition recovery, future-version handling, team-deletion disclosure,
private copy/export and shared run destinations still require implementation or
acceptance. This is a service milestone, not a complete or shipped team library.
See `p2-team-template-library-service-evidence.json`. Reproduce with
`node Scripts/Database/test-team-template-library.mjs <report.json>`.


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
