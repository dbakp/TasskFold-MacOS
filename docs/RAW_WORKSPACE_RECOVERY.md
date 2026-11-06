# Unreadable workspace recovery

When a primary device workspace cannot decode, normal edits, sync, manual/daily
backup and portable export must not replace it or misrepresent an empty snapshot
as a successful backup. Account → Data & Sync presents a recovery explanation and
an explicit **Preserve file and reopen…** confirmation. Cancel changes nothing.

The action opens only the current account's cache, refuses symlinks/nonregular or
oversized files, and checks the fingerprint captured when the workspace failed to
load. It acquires the existing device backup key, then rechecks under the account
removal lock. It saves an AES-GCM encrypted copy of every original byte, with
account binding and SHA-256 integrity, and verifies its durable round trip before
atomically replacing the unreadable primary with a fresh workspace. Another
writer, unavailable key, failed archive/write, or account deletion prevents unsafe
replacement. A persisted team access fence is retained for authorized refresh.

Cloud work can sync again, or the user can restore an existing recovery/portable
backup through the normal reviewed restore flow. Unparsed pending edits are kept
in the encrypted original; they are not inferred or replayed against current
shared tasks. This is a safe escape and preservation flow, not automatic salvage
of arbitrary malformed JSON. The confirmation explains that limitation.

Preserved originals have a separate list under Backups & restore and can be
exported byte-for-byte for repair. They contain private workspace data and may
still be damaged; they are not portable Taskfold backups. Daily backup retention
does not delete them. Account removal deletes them with the account backup vault.
Account changes invalidate confirmations, asynchronous export delivery and list
presentation. No cloud deletions or hosted migrations are part of this feature.

Verification and platform acceptance are recorded independently in each repo's
`p2-raw-workspace-recovery-evidence.json`. Core file tests cover exact preservation,
encryption/account binding/tampering, changed/readable/foreign files, key and write
failure, deletion, symlinks, key waits and retention. Native acceptance is reported
separately from core tests and builds; no release or hosted acceptance is implied.
