# Reviewed copies of saved team drafts

Implemented 24 October 2026. Rank 6 remains in progress. Both repositories own
this code, migration, fixture and verification independently. Team editing stays
disabled. No hosted deployment or native runtime, visual, accessibility or
release acceptance is claimed by this stage.

## What the review does

Backups & restore → Saved team drafts → Review task copy previews a separate task
in the original project. Preview alone creates nothing. Create task copy first
saves a full Recovery backup and a frozen copy request in the encrypted draft.
The request retains its identities and choices across lost responses and relaunch.
Neither opening a draft nor relaunching sends a creation automatically.

A copy keeps the saved title, full notes, priority, planning, labels, section and
supported repeat settings, checklist order/details/checked states, certified file
references and opaque extension fields. It gets a fresh task identity/generation,
creator attribution and creation/completion clock. It is independent of the old
repeat series; the old recurrence action marker is replaced with copy provenance.
Checklist completion epochs and counters are fresh. It does not change either the
original completed task or the existing shared occurrence.

Assignments and reminders require separate review choices and default off.
Opted-in assignees must still be current, live project editors; opted-in reminder
rules must be portable. Off writes an explicit disabled planned-reminder marker,
so an empty list cannot accidentally enable the normal automatic planned alert.
Private/unknown reminders and old discussion are never silently published.
Saved comment drafts, earlier edits and the full original task stay encrypted in
the archive. Copying a draft marked for deletion has an explicit explanation.
Long note previews disclose their display limit; the copy retains the full text.
Checklist previews preserve authored order and show notes, planning and choices.

A missing section, unavailable recipient, unsupported reminder or unattested new
file/readonly extension refuses the operation; the archive is retained in full.
This review does not yet edit arbitrary saved task fields or select another
project/section. New file-upload and mixed-cohort recovery require their own
access-aware adapters. It never turns an old file reference into a new grant.

## Lost responses and changing choices

Exact retries recover the same authorized current copy, including later edits.
Deleting, moving or replacing that copy makes the old response unavailable; retry
never recreates it. Native installation will not overwrite a newer local row,
replacement generation or related task/comment intent. During an in-flight
workspace read, the result remains recoverable through the shelf rather than
inserting a row that the older read could erase.

Change copy choices cancels an unrecorded request through its durable nonce before
clearing the encrypted local attempt. A late original callback then returns the
cancellation instead of creating a task. If creation already won, cancellation
returns its actual recorded result and choices stay locked. A read-only member can
cancel their own request after losing edit access or after project archival, while
current read access, session, account and original attestation are still required.
Newly reviewed choices receive fresh identities. Archive deletion warns that a
copy may already exist and deleting the draft does not undo it.

## Authority and storage

`taskfold_copy_team_draft` accepts the original completion body, full saved row,
fresh copy identities and explicit choices. Its read-only preview, commit and
cancel modes share one actor/HMAC-bound request namespace. The original recorded
completion attests its full source baseline. Its prospective generation must be
retired and not live. Cancelled/unrecorded original completions cannot certify
arbitrary attachments or opaque data.

The server derives certified provisional content from that original baseline.
Readonly root/child files and extension data must still match; mutable authored
fields validate as new content. New checklist items cannot import file access or
history. Current session, team, project role, config, archive, section and recipient
checks precede a scoped INSERT. Auth-recipient locks precede team locks; original
and new nonce locks precede sorted task-identity locks. The private copy marker
stores only UUIDs and cancellation state; its receipt contains a keyed digest,
not task plaintext. Actor receipt cleanup cascades through the marker.

No legacy write policy, Storage permission, public table or feature-enable flag is
widened. Helpers have qualified names, empty search paths, private RLS/revoked
privileges and authenticated-only wrapper access. Preview has no task, receipt,
generation or activity writes. Server input/output and checklist depth/count are
bounded. Native transport is account/backend-bound, refuses redirects, cookies and
cache, and caps responses at 2 MB with a 25-second request timeout. Confirmation
cannot substitute another draft body under a previous visible preview.

Copy attempts use the existing AES-GCM account/backend-bound draft file and its
account-removal write gate. Preparing cannot replace a different request or a
changed/missing archive. Only a matching durable cancellation can clear an attempt;
recorded or stale proofs cannot release it to duplicate creation. Recovery rotation
cannot evict the archive, and the existing account-vault cleanup includes it.

## Verification and remaining work

Each repository independently passes 144 database checks and 481 selected native
tests (84 completion cases, including 19 new cases), plus unsigned Debug
app/extension builds. See `p2-team-draft-copy-database-evidence.json` and
`p2-team-draft-copy-native-evidence.json` in each repository. Disposable PostgreSQL
checks exercise preservation, readonly/foreign data refusal, preview purity,
retries, concurrent duplicates, cancellation/create races, real role/recipient and
identity-lock waits, interruptions, cleanup and advisors. Native tests use actual
SQL request/reply fixtures and cover full-body binding, strict proof parsing,
local-work preservation, encrypted request persistence, cancellation, account
removal, response limits and the automatic-reminder fallback.

Unsigned Debug app/extension builds check the independent Store and SwiftUI
integrations. Owned test containers and temporary build products are removed.
No production task or hosted service changes. Full rank 6 still needs the other
unrecorded/root/compound/batch draft cohorts, current-role workspace/cache refresh
and privacy, remaining team adapters/organization UI and consolidated native
acceptance before enablement. The broader Px goal and all user deferrals remain.
