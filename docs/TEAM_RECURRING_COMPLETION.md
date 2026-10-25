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
