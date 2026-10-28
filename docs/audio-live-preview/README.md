# Gated live audio conversation preview — 28 October 2026

Both apps now have a separately gated native path to list, download/play and explicitly remove published audio comments from the existing authenticated gateway. Ordinary draft/publishing flags remain absent/off. This is an unfinished preview, not general availability.

## Implemented

- Strict live metadata separates the current reader from the author (including a removed author), checks the exact account/task/generation/project, validates publication timestamps and descriptors, preserves literal captions, and rejects duplicate identities, unexpected fields, pending receipts and foreign targets.
- Backend requests use fixed HTTPS POST routes through the gateway, authenticated current sessions, no cookies/cache and refused redirects. Responses are bounded (640 KB metadata, 8 MB audio, 64 KB removal). Provider diagnostics are not shown. Session transitions/incarnation changes revoke responses, including after native decoding.
- Every Play makes a fresh authenticated download. The exact expected SHA-256/header/bytes/container are checked and complete native AAC decoding must succeed before playback. No downloaded recording is automatically persisted into drafts, exports or task rows; existing native decoder temporary files are cleaned.
- Removal has an explicit destructive confirmation and requires the exact operation/comment/account plus retired/purged acknowledgement. Uncertain removal keeps the row with a Refresh instruction. Private saved recordings and publication proof are unchanged. Server cleanup remains a separate retained/custody process, not an immediate physical-erasure claim.
- The in-memory controller binds current workspace/server/task/session and revokes late reads/playback after close/background/account departure. Playback callbacks lose authority immediately. Refresh clears old rows before fetching and no request is made merely by opening the task editor.
- A gated Audio comments entry point in each personal saved-root task editor opens a native grouped conversation preview with literal captions, separate playback/removal controls, empty/loading/error states and Refresh. Store admission remains at least as strict as publishing; shared/read-only task entry points are not enabled by this change.

## Verification

Each repo independently passes **178 audio Core tests**, **265 actual app-controller checks** and **24 native/gateway/PostgreSQL checks**. New coverage includes reader/author distinction, wrong account/target/session/origin, invalid media/receipt, bounded metadata, sanitized failed replies, delayed account responses, inactive/closed controller callbacks and uncertain removal.

The integration executes actual native Core/Backend/native decode against the production Deno gateway and real PostgreSQL, with controlled Auth/Storage. It proves publication recovery, retained/compact proof replay, listing, exact-byte download, a successful removal whose native reply is lost, idempotent removal retry, an empty list and denied download afterward. It also confirms no duplicate upload and preserved local confirmation. These are synthetic fixtures; owned PostgreSQL containers were removed. No hosted provider was deployed or accepted.

[Core iOS](core-ios.txt) · [Core Mac](core-mac.txt) · [Controller iOS](controller-ios.json) · [Controller Mac](controller-mac.json) · [Integration iOS](native-ios.json) · [Integration Mac](native-mac.json) · [Build metadata](builds.json) · [iOS build](app-ios.log.gz) · [Mac build](app-mac.log.gz) · [Sources](source-bindings.json).

Build metadata hashes both the executable stub and the loaded debug-code dylib. Full unsigned app compilation targets Mac arm64 and iOS Simulator arm64/x86_64. Compilation and synthetic controller proofs do not accept rendered geometry, actual app activation, native accessibility/spoken behavior, release signing or provider-backed authority. Existing SDK/concurrency warnings elsewhere remain in build logs; this is not a zero-warning claim. No app was launched or microphone/speech/speaker/system-setting check requested in this checkpoint.

Reproduce independently in either repo:

```sh
swift test --scratch-path /tmp/taskfold-audio-read-core --jobs 2 --filter AudioComment
python3 Scripts/test_audio_comment_capture.py --scratch /tmp/taskfold-audio-read-core --output /tmp/audio-read-controller.json
node Scripts/Database/test-audio-native-publication.mjs /tmp/taskfold-audio-read-core /tmp/audio-read-native.json --retain-audio
```

## Required next work

- Server pagination and native Load more: the existing gateway/database returns at most the first 20 comments in publication order. The UI labels this a preview and never claims a complete conversation. Full history is not implemented.
- Shared/read-only role-aware Store admission, author presentation, integration with shared text conversations and current membership/removal acceptance. The transport can parse a different or removed author; that is not native shared-role acceptance.
- Native runtime/visual/keyboard/largest-text/accessibility checks of the new conversation and preceding publication/recovery controls on Mac, iPhone and iPad using isolated fixtures.
- Terminal recovery for absent/corrupt uncertain uploads, legacy unbound journals and compact-history policy, real hosted provider/custody/removal acceptance, plus user-deferred genuine audio/dictation checks.

Audio and the overall Px objective remain open. The previous [private publication-copy recovery](../audio-pending-review/README.md) remains independently recorded.

Documentation consulted: [Supabase changelog](https://supabase.com/changelog) and [private Storage downloads](https://supabase.com/docs/guides/storage/serving/downloads). App reads continue through the existing authenticated gateway; no new direct Storage policy, provider dependency or schema change is introduced here.

Follow-up: [audio pagination](../audio-pagination/README.md) implements keyset pages, native Load more and a 100-recording retained task count with existing byte/author quotas. The 20-item preview limit described above is historical. Native/shared/provider acceptance remains open.
