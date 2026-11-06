# Private publication-copy recovery — 28 October 2026

Pending original recordings can now be reviewed independently of edited or removed saved drafts. Both apps own their implementation and evidence. Ordinary audio and publishing flags remain absent/off.

## Delivered

- Local-only publication-copy list and original caption/recording review, including orphaned versions. Playback requires full native decoding and rechecks the exact current journal. Account, server, workspace, selection and inactivity changes revoke private presentation and delayed playback callbacks.
- Keep a private copy preserves the original without overwriting an edited draft. Stable asset/operation IDs make repeated recovery idempotent and reconcile the original send when the copy is reopened; a pending original blocks a new send from an edited recovery copy.
- Explicit Check original publication resumes the same intent only while the original task and current session remain admitted. Opening review never sends a request. Local review also rejects session transitions before the old cached session is removed.
- App publishers retain confirmed recordings until explicit local removal. The private v2 confirmed format preserves verified audio and receipts; v1 pending and compact receipts remain readable. Pending recordings cannot be discarded here. Removing a confirmed publication copy preserves server comments, saved drafts and compact confirmation proof. Cross-window removal clears stale playable selection.
- Pending writes reserve 64 KB for confirmation metadata. Twenty other pending entries cannot prevent confirmed-copy compaction; entry and byte limits remain enforced.

## Evidence

Each repository independently passes **170 Core audio tests**, **253 actual recording-controller checks**, and **20 native-to-gateway checks**. The latter execute the native Core/Backend/codec through the production Deno gateway and real PostgreSQL with controlled Auth/Storage. They cover a lost successful reply, process restart, stable operation/receipt, retained audio, recovery-copy replay and explicit release without another HTTP request. Owned database containers were removed. All media and data are synthetic.

Both full application targets compile: Mac arm64 and iOS Simulator arm64/x86_64. Signing is disabled; built flags are absent/off. No application was launched in this checkpoint. Compilation/controller proofs do not establish native UI, visual, VoiceOver, real provider or release acceptance. No real microphone, dictation, speaker or permission check was requested.

[Builds](builds.json) · [Source bindings](source-bindings.json) · [iOS Core](core-ios.txt) · [Mac Core](core-mac.txt) · [iOS controller](controller-ios.json) · [Mac controller](controller-mac.json) · [iOS integration](native-ios.json) · [Mac integration](native-mac.json) · [iOS build](app-ios.log.gz) · [Mac build](app-mac.log.gz).

Reproduce from either independent repository with an owned scratch directory:

```sh
swift test --scratch-path /tmp/taskfold-audio-review-core --jobs 2 --filter AudioComment
python3 Scripts/test_audio_comment_capture.py --scratch /tmp/taskfold-audio-review-core --output /tmp/audio-review-controller.json
node Scripts/Database/test-audio-native-publication.mjs /tmp/taskfold-audio-review-core /tmp/audio-review-native.json --retain-audio
```

## Still open

- Native runtime/visual/accessibility review of these gated controls on Mac, iPhone and iPad, including cancellation, backgrounding and relaunch.
- Live server audio conversation listing, authenticated download/playback/removal and presentation.
- Terminal evidence/recovery for absent or corrupt uncertain uploads, reviewed legacy unbound-journal migration and compact-receipt history policy (currently bounded at 1,000 entries).
- Hosted provider/custody/removal acceptance and user-deferred genuine dictation/audio checks. Release distribution and other recorded deferrals are unchanged.

The previous [publication-controls checkpoint](../audio-publication-controls/README.md) records the earlier compiled controls. This extends recovery/retention; audio comments and the overall Px objective remain open.

Follow-up: [gated live conversation preview](../audio-live-preview/README.md) implements bounded personal-root listing, verified download/play and explicit removal. Pagination, shared/read-only integration and native/provider acceptance remain open.

Follow-up: [exact closed-publication recovery](../audio-publication-closed/README.md) adds durable terminal proof without treating missing objects or timeouts as closure. Broader owner-status and native/provider acceptance remain open.
