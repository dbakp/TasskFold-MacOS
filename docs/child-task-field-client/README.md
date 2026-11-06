# Native child field requests and encrypted retry queue

29 October 2026. This completes the typed native command, durable queue and
Backend transport layer for the disabled child-field API. Both apps own their
implementation and tests. No editor calls it yet, no ordinary write gate is
introduced/enabled, and no hosted schema or real task/account was changed.
Full child migration and Px remain open.

## Completed in this stage

- [x] Capture intended account, origin, task generation/project, child key,
  incarnation and revision from a verified child-record read. Validate explicit
  supported field changes; refuse completion, structure, IDs and unknown fields.
  Preserve literal authored Unicode in equality and saved request bodies.
- [x] Bind confirmation to the original request and every target identity. Allow
  no-op or intervening disjoint-field revisions. A malformed success stays
  unconfirmed; it does not imply that the server rolled back.
- [x] Store up to 64 independent requests in an encrypted account/origin queue.
  Coalesce only unsent edits to the same target at the same captured revision,
  keeping the queued identity. A stale review cannot send/discard a merged body.
  Once attempted, both UUID and body are immutable; later edits remain separate.
- [x] Serialize disk read/modify/write across journal actors/processes and use
  account-removal fences. Persist attempted state before networking and confirmed
  proof before returning success. Do not evict recovery when the queue is full.
- [x] Keep uncertain requests after lost replies, failed receipt saves, access
  refusal or changed context. Retry the original body. Return stored confirmation
  without another service request. Earlier unconfirmed edits block later edits to
  that same target while other children can proceed.
- [x] Scope physical storage and ciphertext authentication to account/origin;
  use private atomic files excluded from backups. Reject corrupt ciphertext,
  wrong keys and symlink files. Another origin's cleanup cannot unlink this file.
- [x] Bind the sender to account/origin/workspace/session/access; suppress stale
  success and failure. The sender never writes a task cache or deletes recovery.
- [x] Backend posts only `_body`, checks the expected account/session/origin,
  disables cookies/cache/redirect following, bounds replies to 16 KiB, and
  sanitizes service refusals. No credential or server-detail message is shown.

## Verification scope

Each repository independently passes **117 selected Core cases**: 23 new command/
journal/sender/HTTP cases, 20 child-read cases, 19 existing tree cases and 55
account-transport regressions. The command tests include actual PostgreSQL-produced
request/original/replay fixtures, private encrypted-file roundtrip, corrupt/wrong-
key/symlink refusal, coalescing and frozen attempts, 64-entry retention, two actors
sharing storage, lost replies, failed disk writes and stale context outcomes.
Transport uses controlled URLProtocol responses; it is not a live hosted
PostgREST-to-database or provider acceptance test.

Each repository also reruns **95 existing PostgreSQL cases** against its own
canonical migration and exports its own command/receipt fixture. The SQL is
unchanged in this stage. Owned database containers are removed. Full isolated
Mac and iOS Simulator app/test builds pass with strict deep signature checks.
This is compilation acceptance, not native editor, layout, VoiceOver or release
acceptance. Existing unrelated warnings remain recorded in the logs.

`verification.json` binds final sources, fixture hashes and exact checks;
compressed logs retain the build/test evidence.

## Still required before exposure

- [ ] Integrate current Store/session/access admission, Keychain-backed journal
  construction and account-removal cleanup with the actual app lifecycle.
- [ ] Native pending/review/retry/discard UI and explicit acknowledgement of an
  uncertain discard; connect child editor saves and current-data refresh. Task
  caches must not present a saved receipt as a newly fetched task snapshot.
- [ ] Re-review later same-target drafts after an earlier request finishes.
  This queue deliberately does not automatically rebase or replace their UUIDs.
- [ ] Cross-process crash/reboot, real Keychain and complete Store/window/account
  acceptance; server receipt history/cap policy and quota-boundary/load checks.
- [ ] Remaining child lifecycle actions (completion/history, structure/moves,
  heading/legacy container adapters), authoritative-record migration, hosted
  compatibility and paired/cross-device acceptance.

The prior server candidate's legacy null/missing-container and team-envelope
limits still apply. User-deferred rollout, remote delivery, distribution,
provider registrations and genuine audio/location checks remain deferred.

The next [lifecycle and native-screen stage](../child-task-field-lifecycle/README.md)
now supplies source integration and controller checks. Its actual Store/native/
Keychain acceptance remains open, and ordinary write flags remain off.
