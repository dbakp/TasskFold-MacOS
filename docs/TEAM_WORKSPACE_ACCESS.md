# Current workspace access and private refresh

Implemented 24 October 2026. Rank 6 remains in progress. Both repositories own
this source, migration, tests and evidence independently. Native team editing
remains disabled for rollout. The captured native editor bridge has isolated
iPhone/iPad title/notes and role-loss recovery acceptance; Mac runtime, broader
team interactions, hosted deployment, VoiceOver and release acceptance remain open.

## Access boundary

`taskfold_workspace_boundary` lists the current actor's personal/accepted legacy
projects separately from authorized team projects. Team entries include current
manager/editor/viewer roles, archive state and server send capability. Creator
UUIDs never imply current team authority, including after the creator's Auth row
has been removed. Native task controls remain gated independently of the server's
capability. Private/unknown projects are omitted; editable JWT metadata grants
nothing. Reading may remain available while team setup/task editing is paused.

Private per-team access epochs change for membership, project grants/custody,
team state and project archive/hierarchy changes. Access remove-and-restore is
therefore detectable. Ordinary task edits do not invalidate the access epoch,
so continuing collaboration does not force a refresh retry. Epoch writes roll
back with failed transactions. The read locks current team/config/epoch rows and
rechecks the live Auth/session after waits. Output is actor-bound and HMAC-tagged.
Epoch tables/helpers have private RLS/revoked privileges; the wrapper is
explicitly authenticated-only. Existing task/file RLS and write guards are not
widened. Native reads and task edits keep their prior default-off flags.

Native refresh reads the boundary before sending queued changes, then brackets
the normal table fetch with matching boundaries. A changed boundary discards the
entire partial fetch and retries at most three times. Rows are finally filtered
by the authorized project allowlist, including transient grants absent from the
final boundary. This guarantees a consistent access boundary, not one point-in-
time content snapshot: normal row editing remains concurrent and retains its
existing merge/incarnation/revision checks.

A genuinely legacy service can retain legacy sync only when both the boundary
and organization RPCs are explicitly absent and the device has no prior team
state or scoped queue. An existing/partially installed team service, permission
error, malformed response or known team state cannot silently fall back. Requests
are account/backend-bound with no cookies/cache/redirects and bounded response
sizes. Boundary limits are 10,000 projects, 1,000 teams and 3 MB server output;
table reads reject duplicate/repeated pages and exceedance of 100,000 rows.
Profiles paginate by their actual user_id key.

## Preserve work while withdrawing access

Historical project/task custody stores UUIDs only. It prevents a late ordinary
edit from treating an earlier team task as personal after its row was pruned.
Every queued scoped action retains its original account/backend/team/project.
Current permissions are checked before sending; the server remains authoritative.
Blocked atomic groups and dependent task intents stay together. Dependency
propagation uses a bounded-data graph rather than repeatedly rescanning the whole
queue. Personal notes merely mentioning a task UUID are not dependencies.

The full queue stays saved byte-for-byte in meaning. A full encrypted Recovery
copy precedes pruning a working snapshot that contains inaccessible work or a
newly blocked projection. Current server rows replace withheld optimistic edits;
newer local task generations are not targeted by old intents. Independent
personal/offline project capture remains visible. The sync loop stops at a blocked
head instead of busy-looping or skipping an unresolved cohort. Protected request
UUIDs prevent duplicate Recovery backups for an unchanged quarantine at the same
access boundary.

A temporary presentation mask applies immediately upon learning of an access
loss, before later data fetches or Recovery/Keychain waits. Lists, cached members,
profiles, task/assignment/activity/discussion projections, widgets and current
read-only template/portable-export sources use the filtered presentation. The
original snapshot remains intact for Recovery. Team widget completion tokens are
withheld while client editing is disabled; personal root/child actions survive.
Notification/Watch publication follows the accessible task projection. Existing
open-editor/thread/native interaction acceptance is still required below.

A small device-private .team-access-fence persists only the account/backend-bound
boundary metadata, never task text. It is written before awaiting further refresh
work, so known revoked content stays masked after a relaunch even if the larger
Recovery write could not finish. The original queue is retained while the fence is
loaded. A fresh authorized read plus durable filtered cache permits fence removal
and can repair damaged fence metadata; another backend/account's valid fence is
not removed. Account removal deletes the fence and gates late writers. An
undecodable primary workspace file stops automatic sync/editing and is retained;
the separate preserve-and-reopen flow now verifies an encrypted original before
replacement and offers byte-for-byte export for repair (RAW_WORKSPACE_RECOVERY.md).
Unparsed edits are retained in that original and are not automatically replayed.

## Verification and remaining work

Both repositories pass 57 database checks and 653 selected core tests each,
including 27 workspace tests; iOS also passes 79 Watch tests. Both complete unsigned
Debug app/extension builds pass. Each repository has independent evidence in
`p2-team-workspace-database-evidence.json` and
`p2-team-workspace-native-evidence.json`. Database tests use owned disposable
PostgreSQL only, including actual team/epoch lock waits, grant ABA and rollback,
archival/setup pause, removed creators, session/actor checks and advisors. Native
tests cover real SQL boundary fixtures, strict parsing, whole-read retries,
legacy/partial-service refusal, account isolation, queued work/cohort retention,
private projection/widget output, historical callback fences, malformed metadata,
relaunch, account cleanup and table pagination. Broader backup/reminder/capture/
widget/Watch regressions and unsigned app/extension builds validate integration.

No real task or hosted service changes. Temporary builds/containers and temporary
Mac registration are removed after verification. Full rank 6 still needs complete open-editor/thread/readonly-control invalidation and native
acceptance, other unrecorded/root/compound/batch draft reconciliation, remaining
collaboration/organization adapters and premium team UI before enablement. Wider
Px work and all existing release/provider/hardware deferrals remain unchanged.


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
with no failures. Both native Debug apps/extensions build. The isolated iPhone and
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
