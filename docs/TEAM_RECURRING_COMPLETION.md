# Atomic team recurring completion

Implemented 24 October 2026. Rank 6 remains in progress. This is a guarded backend
and persisted native command foundation; native team editing remains disabled.
No hosted deployment, native runtime acceptance or distribution acceptance is claimed.

## Behavior

Completing a team task and creating its next occurrence are one transaction.
The server derives the next task from the locked source, checks the current actor,
project, series and generation, and applies the existing recurrence rules. The
client submits a frozen clock, zone, identities and source baseline, not arbitrary
successor content. Known canonical or legacy future occurrences are reused;
manual deletions are not resurrected. Concurrent completions converge on one next
occurrence. Stale source content or authority changes produce a reviewable failure.

Successors preserve authored notes, planning, portable reminder choices, opaque
fields and existing same-project file references. They reset completion, discussion
and notification state and mint fresh checklist epochs. File references retain
existing project custody; this adds no Storage grant or file-delivery acceptance.
Departed or ineligible recipients are not reassigned to the next occurrence.

Undo reopens the original occurrence and removes only its own untouched successor.
A successor with later edits, discussion or descendants is kept; the app can explain
that outcome. Durable write epochs also detect edit-and-revert cycles. Redo uses a
fresh generation and an unconsumed, actor-bound Undo receipt. Later deletion or
restoration history prevents an old Redo from silently recreating work.

Exact retries share the existing guarded command nonce namespace. Live authority is
checked even on replay. Private receipt and epoch tables expose no task text or
client write permission, and team deletion purges their metadata. Task, receipt,
generation and scope changes roll back together on failure.

## Independent native ownership

Each repo owns TeamCompletion, queue encoding, local two-row projection, Undo/Redo,
transport, reply validation and acknowledgment. Older queues still decode. Commands
bind to the original account, backend, team, project and task generation. Transport
is bounded, avoids caching/cookies and refuses redirects. Malformed commands do not
fall through to ordinary task writes.

Acknowledgment installs current authorized source/successor rows before replaying
later queued work. Offline complete → Undo → Redo is supported. If a competing
server generation would displace an edited provisional task, the complete command
and later drafts remain saved locally for dedicated review. Generic conflict and
unavailable-project cleanup cannot discard them.

## Verification and remaining acceptance

Each repo independently passes 583 disposable database checks: 131 completion,
221 checklist/planning/edit, 89 lifecycle, 72 batch and 70 discussion regressions.
Both pass 262 selected Swift tests, including 17 new completion tests, and unsigned
Debug app/embedded-extension builds. Reports contain current migration/source
hashes. Disposable containers and temporary build products are removed; no test app
was launched and no real task data changed. Database advisors report no new
warnings/errors against the fixture baseline.

Remaining rank-6 work includes dedicated conflict review and enabled native team
UI, current-role workspace refresh/privacy, structural commands, and comment,
mention, file and service adapters. A preexisting series occurrence in another
project currently fails safely rather than moving or rebinding it; cross-project
UX needs explicit acceptance. Full team privacy/recovery and runtime acceptance
remain ahead. Remote reminders, general older-client rollout safeguards and
release signing/distribution remain deferred as requested.


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
