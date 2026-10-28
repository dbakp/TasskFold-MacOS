# Closed audio publication recovery — 28 October 2026

An exact retry can now settle as **Original publication closed** when the existing
SQL reservation/finalization fence proves that operation expired or was retired.
It cannot be resumed. This is deliberately different from “never published”: a
comment may have been visible before removal. Timeouts, missing/corrupt objects,
permission errors, conflicts and generic error text remain uncertain.

## Delivered

- The gateway returns a closed envelope only from an exact reserve/finalize result
  with the matching operation ID. Existing SQL first checks live actor/session,
  target access, author and the full immutable intent hash. Unexpected fields or
  operation IDs cannot become terminal proof. No new RPC, schema, role grant,
  Storage policy, deployment or ordinary feature flag is introduced.
- Native Backend verifies the fixed authenticated endpoint/current session and
  strict closed envelope against the full frozen intent. It transports a typed
  result to the publication flow; generic HTTP failures cannot clear uncertainty.
- The v3 private journal keeps exact closure proof **and original audio** atomically.
  Existing v1 pending and v1/v2 confirmed files remain readable. Unknown, corrupt,
  contradictory or foreign files refuse rather than being dropped or republished.
- Reopening or retrying a closed source, including its stable recovery alias,
  cannot mint a new operation or make HTTP requests. Publishing again requires an
  explicitly saved new revision and the ordinary Publish action. No automatic
  new IDs, retry, media deletion or draft overwrite is introduced.
- Closed copies remain playable/recoverable in the private publication library.
  Explicit local removal compacts only the media, retaining terminal proof and
  saved drafts. Closed proof never masquerades as a published confirmation.
  Byte/entry limits remain enforced; closure stops consuming a pending-entry slot.
- A client closure does **not** settle an unresolved server upload attempt, release
  its server quota or finish cleanup. The existing late-upload fence remains intact.

## Evidence

Each independently owned repo passes:

| Check | Result | Scope |
|---|---:|---|
| Core audio cases | 195 | Includes 11 closure cases: raw intent identity, durable/cold state, quota, rename failures, contradictory proofs, media preservation and departed context. |
| Actual controllers | 282 | Includes nine closure review/copy/play/remove checks; synthetic silent player and actual codec/vault. |
| Deno gateway | 25 | Includes expired/retired proof, wrong operation/extra fields, nonterminal failures, terminal finalize and expiry before a fresh upload reservation. |
| Native → gateway → PostgreSQL | 54 | Absent and corrupt objects remain uncertain; lost terminal ACK preserves the local pending journal; subsequent exact retry closes; cold retry and compaction make no HTTP; changed captions refuse; server upload fence remains independent. |
| Existing publication regression | 24 | Lost publish/removal replies, retained/compact confirmation, stable IDs, authenticated readback/removal and private preservation. |

The integration runs execute native Core/Backend/full AAC decode in separate Mac
processes against the production gateway and real disposable PostgreSQL 17.6,
with controlled Auth/Storage HTTP boundaries. Every owned container is removed.
Baseline/final database advisor findings agree. No real account/media or hosted
provider is used. The first integration attempt exposed a test helper’s default
argument treating expected `undefined` as `true`; `Object.hasOwn` now checks the
intended absence explicitly. Product behavior did not change for that correction.

Both full app targets build unsigned. The executable stub and loaded debug-code
dylib are hashed separately. Normal audio gates stay absent/off. No app, simulator,
VoiceOver, microphone, speaker or permission dialog is launched for this checkpoint.
Compilation/controller/native-API evidence does not accept the new closed-state UI.

[Core iOS](core-ios.txt) · [Core Mac](core-mac.txt) ·
[Controllers iOS](controller-ios.json) · [Controllers Mac](controller-mac.json) ·
[Gateway iOS](gateway-ios.txt) · [Gateway Mac](gateway-mac.txt) ·
[Terminal iOS](terminal-ios.json) · [Terminal Mac](terminal-mac.json) ·
[Regression iOS](regression-ios.json) · [Regression Mac](regression-mac.json) ·
[Builds](builds.json) · [Source bindings](sources.json).

Reproduce independently in either repo:

```sh
swift test --scratch-path /tmp/taskfold-audio-closed-core --jobs 2 --filter AudioComment
python3 Scripts/test_audio_comment_capture.py --scratch /tmp/taskfold-audio-closed-core --output /tmp/audio-closed-controller.json
deno test --allow-read supabase/functions/audio-comments/handler_test.ts
node Scripts/Database/test-audio-terminal-publication.mjs /tmp/taskfold-audio-closed-core /tmp/audio-terminal.json
node Scripts/Database/test-audio-native-publication.mjs /tmp/taskfold-audio-closed-core /tmp/audio-regression.json --retain-audio
```

## Still open

- Owner-scoped status/recovery when the original task or its current access is
  unavailable, or when the server has no reservation. Those situations do not
  become terminal from absence; the original remains fenced and privately recoverable.
- Native closed-state visual/keyboard/spoken/relaunch and full signed-in Store UI
  acceptance, reviewed legacy unbound-journal migration and compact-history policy.
  History is still bounded at 1,000 entries; older clients refuse v3 files safely
  but are not accepted for a rollout involving this gated feature.
- Team audio writes/custody and real hosted provider/custody/removal acceptance.
  Genuine microphone/dictation/audible playback and all user-recorded release,
  remote-reminder, older-client and external-provider deferrals remain unchanged.

The audio/Px objective remains unfinished. See the [mixed timeline](../conversation-timeline/README.md)
and [private publication-copy review](../audio-pending-review/README.md) checkpoints
for separate earlier scopes.

References reviewed for this service work: [Supabase changelog](https://supabase.com/changelog),
[Storage access control](https://supabase.com/docs/guides/storage/security/access-control),
[PostgreSQL minor-release notice](https://supabase.com/changelog/postgres-15-19-17-11-breaking-changes)
and [TLS notice](https://supabase.com/changelog/cbc-tls-ciphers-deprecated).
The implementation reuses the existing fenced SQL commands without a schema change.
