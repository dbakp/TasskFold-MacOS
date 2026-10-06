# Backups and restore

Mac: Settings → Account → Backups & restore. iPhone/iPad: Settings → Data & Sync → Backups & restore. Each app owns its implementation and builds without the other repository.

## Portable files

**Export workspace** opens the native save dialog with a JSON file. Version 1 identifies itself as `com.taskfold.workspace` and includes a backup UUID, creation timestamp, source account, workspace tables and count of unsynced changes. It contains the visible saved work, including unsynced task edits. It contains no sign-in session, access token, device key or executable network queue. Older native exports consisting of a table dictionary remain readable.

Exports are plaintext. Store them privately. Files are limited to 256 MB and 50,000 records. Unknown versions, tables or fields fail with update guidance. Validation covers column types, real dates, time zones, fixed-instant consistency, duration/priority ranges, query documents, JSON bounds and relationships. Corrupt input cannot reach the apply step.

## Review before applying

**Restore from file** opens the native picker and then a preview with Add, Update and Keep counts, per-table counts and warnings. The default **Keep current edits** adds missing records. **Use backup values** also updates matching records with the backed-up fields. Both keep existing work absent from the file; neither is a destructive workspace replacement.

Tasks, projects, labels, sections, saved filters, favorites, view preferences and task order are restored. Matching own UUIDs are retained. Work from another workspace and shared projects become personal copies with deterministic IDs scoped to the source and recipient accounts. Task, section, label, filter and order references follow those IDs. A repeat restore maps to the same records rather than creating another copy. Unavailable collaborators are cleared from assignments, including child tasks. Missing filter targets require repair instead of matching unrelated tasks. Profile identity, invitations, authentication and calendar permissions are not transferred.

New records use create-only sync requests. If a retry finds an existing server record, the transport confirms recipient ownership without replacing that record. Explicit updates use the ordinary durable edit queue and conflict handling. The local apply is saved as one operation; remote requests drain in dependency order through the existing sync queue. Restore is not a server-wide transaction. Pending changes and sync errors remain visible in settings.

A mandatory encrypted **Before restore** checkpoint is saved before any local changes. If it fails, the restore stops. A changed account, edited workspace or concurrent sync invalidates the preview; review the latest snapshot before trying again. Ordinary undo history is cleared after a successful restore; use its recovery copy to review and recover earlier values rather than deleting records that may already have existed remotely.

## Recovery copies

**Back up now** saves a manual recovery copy. **Daily recovery copies** is enabled by default per workspace and saves on the first workspace persistence that day while the app is running. It does not wake a closed app. Turning it off affects future daily copies; existing copies remain available.

Each device keeps up to 20 recovery copies, including daily, manual and pre-restore copies. AES-GCM authenticates and encrypts the full local snapshot, including pending mutations and conflict baselines. A per-account, device-bound 256-bit key stays in Keychain. Only dates, kind and record count appear in the local index. Old ciphertext is pruned after a new file and index have been written successfully. Failure to make a daily copy does not discard a task edit; settings show a separate backup warning.

A recovery-copy menu offers **Preview restore** and **Export copy**. Preview follows the same record merge policy as file restore; it does not blindly replay the retained historical queue. Device keys and private recovery history are not synchronized. Use a portable export for another device or account. Attachment references and task metadata are preserved; remote attachment bytes and provider-side import registries are not bundled or recreated.

## Verification scope

`TaskfoldTests/BackupTests.swift` tests codecs, old exports, invalid input, fixed DST instants, graph/reference mapping, repeat restore, both matching policies, project-move assignments, recurrence dependency order, legacy list order, retained queues, authenticated encryption, tampering, account/key isolation and 20-copy retention. Transport tests assert create-only preferences and owner confirmation after a duplicate response.

`Scripts/test_restore_http.py` exercises all eight work tables against separately authenticated sessions on disposable accounts: creation/defaults, relationship and fixed-instant reads, retry after a newer edit, and foreign-account denial. The live run passed on 6 October 2026; both users and their fixture rows were deleted and cleanup counts verified as zero. This proves the transport contract, not simultaneous native Mac/iOS operation.

Native iPhone user-flow evidence and Mac build results are recorded in the platform validation files. Mac runtime, native cross-device recovery, physical device failure/recovery and online/offline replay remain separate acceptance checks until explicitly recorded.

Completion revisions are exported as historical task metadata and validated as nonnegative integer counters. They cannot be restored over a current server counter. Newly created restore rows start at zero; updates retain the existing counter and completion edits capture its baseline. Old exports without the field remain valid. Older app versions that cannot read the new field need updating before restoring such an export.

## Focus checkpoints

Portable exports save a running Focus session as a paused checkpoint. Restore preserves its elapsed time, remaps task/session IDs and guards the target account’s current revision; it does not resume an old timer or import a server counter. Keep current retains an existing session. Encrypted recovery snapshots also retain queued Focus commands. See [Focus session rules](FOCUS_SESSIONS.md).
