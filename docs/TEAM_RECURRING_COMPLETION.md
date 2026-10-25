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
