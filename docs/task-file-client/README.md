# Native shared-file screens and encrypted recovery — built candidate

Reviewed 1 November 2026. Each app owns its full source, project registration, tests and SQL fixture. New publishing still defaults to Off (`TaskfoldTaskFilesEnabled` is absent/false); nothing was deployed or enabled for normal use.

## Implemented

The editors now have a gated Shared files sheet with bounded file selection, explicit sharing, status, same-operation retry, Stop, verified download/save-copy, private copy export and explicit recovery clearing. Account → Backups and restore exposes an existing saved upload independently of the new-publishing switch. Existing stored-file references can open a read-only sheet while new publication is paused. Unsupported MIME types use an opaque binary type; file names never become provider URLs. Failed journal reads report that recovery needs review rather than claiming it is absent.

A single account/origin-scoped journal freezes the target, identity, file descriptor and exact bytes before dispatch. It uses the existing encrypted file storage and account-removal/process locks. A new conditional replace operation changes queued → attempted → authenticated terminal receipt without a remove/write gap. Stale windows cannot overwrite or resurrect newer recovery. Unsent cancellation is local and conditional; attempted cancellation uses the server. Closing or changing account while waiting keeps the attempted original for authenticated recovery. Only an exact terminal receipt enables clearing; no timeout, missing reply or access failure is treated as closure. The original bytes remain until the user explicitly clears them.

The native HTTP client sends the frozen intent/bytes, and only the operation identity for status/cancellation. It checks account, origin and session before/after refresh and throughout bounded reads, refuses redirects, avoids cookies/cache and verifies download size/hash before offering a copy. Task writes use the dedicated service and never the optimistic task editor. Scope changes do not retarget the pending upload. The encrypted journal and real HTTP envelope support the full 5 MiB limit, including all-0xff files whose base64 would otherwise be doubled by JSON slash escaping; the encoding option is opt-in, preserving existing command-vault serialization.

## Verified scope

Each repo independently passes 58 focused Core tests (18 new file tests, plus existing template/organization command tests). Coverage includes its own actual SQL receipt, exact descriptor/target/identity validation, ciphertext/no-plaintext/cold read, origin isolation, stale conditional writes, durable-before-send admission, dropped replies, paused publishing, account change while awaiting, local unsent cancellation, malformed receipts, explicit terminal clearing, actual URLSession request fields, byte integrity and the maximum-size encrypted/HTTP round trip.

Both isolated current-source apps and runners build and pass strict signatures. Source equivalence after test-identity isolation and binary hashes are recorded in verification.json. The initial iOS build caught a private cache-helper reference; the corrected code uses the existing public read-access predicate. No private guard was broadened. App compilation is **not** native file-picker/export/VoiceOver acceptance. No SQL or service source changed in this batch, and their earlier database/service suites were not rerun.

## Still required before enabling

- Complete read-only/viewer entrypoints and native Mac/iPhone/iPad interaction, actual picker/export, background/cold/account/window/access behavior, keyboard/VoiceOver/largest text and durable recovery observation.
- Sender-only closure for an attempted operation that never reserved remotely or whose task/access disappeared: the current server can return unavailable. This client correctly retains its original bytes and offers private export, but one pending journal can then block choosing another file until a genuine terminal proof is available. Do not clear it on a 404 or invent a replacement operation.
- Real provider upload/readback/download, collision/timeout/reinstall behavior, permission loss and deployment configuration checks.
- Fenced provider cleanup and quota release; attachment removal/recovery, legacy migration, independent child/media files and genuine shared-account acceptance.
- Existing Px work and user rollout deferrals remain unchanged. Normal-use gates stay disabled; this is a built native candidate, not completed shared-file acceptance.

## Reproduce Core checks

```sh
python3 Scripts/check_test_storage.py --path /tmp
```

Use this repo's Swift package with an external build cache and filter `TaskFileUploadTests|TeamTemplateCommandTests|TeamOrganizationCommandTests`. Serialize heavy platform jobs; use only isolated synthetic app hosts for native checks. The SQL fixture belongs to this repo's earlier successful service run, not a shared or hosted account.
