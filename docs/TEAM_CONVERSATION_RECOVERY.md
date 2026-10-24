# Team discussion recovery — disabled candidate, 24 October 2026

The guarded team task lifecycle now preserves a task's shared discussion through
delete and Undo. This replaces the preceding stage's refusal to delete a task
with shared comments. It does not enable team UI or the remaining comment-write,
assignment, service, file and workspace adapters.

## Deletion and recovery

The already-authorized task deletion locks the root, comments and mention rows,
then archives each comment and its mention state before the task FK cascade.
Each deletion has a fresh 32-byte private encryption key; archive payloads use
pgcrypto PGP symmetric encryption with AES-256. Operation receipts retain UUIDs,
digests and a recovery state, without discussion text. This is server-side
protection, not end-to-end encryption or a claim about database backup erasure.
Private keys, encrypted rows, identity tombstones and transaction scopes have RLS
and no authenticated/anonymous/service grants. There is no public trash reader.

Undo still requires the actor's matching, unconsumed deletion receipt, original
task content digest, current live session and editor role, and a new task
generation. It restores comments and mentions with fresh identities, retaining
body text, original creation/update/read times and deleted-comment tombstones.
Removed authors remain anonymous. Recipients are filtered by current project
read access, including viewers; departed recipients are omitted. The old comment
and mention callbacks remain unavailable and cannot alter the recovered thread.
Retired comment UUIDs cannot be reused through another task or personal path.

The participant Auth rows are held before the team lock, matching the existing
lock order. Root/comment/mention locks serialize an in-flight discussion update
with deletion. Narrow private scopes permit only the intended comment cascade
or restore, without enabling ordinary direct/native comment writes. A corrupt
archive or an interrupted restore rolls back the whole task, discussion, consumed
Undo and scope changes. Retrying the same successful operation does not duplicate
comments or extend its recovery window.

Recovery lasts 30 days. Expiry prevents a silent partial Undo even if physical
cleanup has not run: the app explains that discussion recovery has expired while
retaining the local task draft. A bounded hourly pg_cron job removes expired keys
and ciphertext. Cleanup locks receipts first and skips a receipt in use by Undo.
The key/ciphertext are also removed after successful Undo, deleting the actor's
account or deleting the team. Whole-team deletion retains only the existing
UUID/digest tombstones and cannot keep archived discussion content.

Restored mentions retain their original event and read timestamps; actual remote
notification delivery is not claimed and remains deferred. No operation receipt
or old authored intent is replayed against a new task generation.

## Evidence

Each repository independently passes:

- 70 real PostgreSQL recovery checks, covering encryption/private boundaries,
  current viewers/departed recipients, removed authors, new identities, consumed
  Undo, corruption and forced mid-write rollback, expiry, a locked cleanup receipt,
  a concurrent discussion update, account removal and authenticated team deletion.
- 89 lifecycle and 70 edit regressions against this new migration.
- 11 checks using a compiled pinned upstream pg_cron and its real background
  worker: actual job registration, expiry, skipping/retrying a locked receipt and
  preserving unexpired content. The production hourly schedule is tested locally
  at a one-second interval; no hosted scheduler change was made.
- 167 selected SwiftPM checks, including 4 new recovery tests and existing
  discussion, role, task, automation/email, deletion and access-recovery cases.
  The new tests consume this repo's SQL-generated fixture, verify stale-reply/cache
  and authored-draft handling, and check the native expired-recovery explanation.

There are no failures/skips or new advisor warnings/errors. Existing minimal
fixture init-plan warnings are recorded. Owned database/build containers and Cron
extension staging directories were removed. Evidence hashes identify the exact
migration, fixtures, native sources and test inputs. Xcode project lint/source
registration is checked; no new native app build, interactive UI, hosted delivery
or distribution acceptance is claimed for this stage.

The team catalog remains read-only and feature switches default off. Atomic
linked-task batches, remaining task/comment/mention/file/API/email adapters,
role/workspace refresh, premium native team administration and full privacy,
backup/activity/widget acceptance remain open. Watch/Wear OS and wider Px remain
in scope. All user deferrals remain unchanged.
