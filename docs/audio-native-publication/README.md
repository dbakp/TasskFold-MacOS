# Native audio publication foundation — 28 October 2026

This is implemented, independently verified client code in both repositories. It
is not connected to normal app publishing controls and is not a released audio
feature. No hosted deployment, real account/task change, microphone/speech prompt,
playback, simulator or native app session was used for this checkpoint.

## Implemented

- An atomic, device-private publication journal binds the canonical HTTPS origin,
  account, original recording ID/revision, task/generation/project and frozen
  operation/comment/asset IDs to the literal caption and exact audio bytes.
  The journal is synced before any publication request. New controllers/processes
  reuse the original operation. An earlier unconfirmed revision blocks another
  identity for that recording; an explicitly edited confirmed recording may create
  a new publication.
- The separate directory has owner-only permissions, no-follow descriptor access,
  hard-link/type/owner checks, a cross-process lock, atomic rename and directory
  sync. Precommit stages can be reclaimed under that lock; uncertain renamed
  journals are read and synced before retry. Account/server namespaces cannot
  adopt another journal. It is excluded from backup; iOS files use the same
  complete-until-first-authentication protection as the existing recording vault.
- A strict published-receipt decoder requires the matching account/author, all
  frozen IDs, target, literal caption, descriptor, state and timestamps. Echoes,
  pending replies, extra fields and foreign/mismatched receipts cannot confirm.
- Confirmation atomically replaces the journal with a compact identity/receipt
  proof, releasing its duplicate audio while leaving the saved recording intact.
  That proof prevents a subsequent restart from sending the recording again.
  A cached receipt proves historical publication, not current server visibility
  or permission to display a conversation; live reads remain independently required.
- An observable MainActor publisher binds the target and session incarnation,
  checks the live context around awaits and invalidates late presentation on
  departure. It supports explicit preparation and retry; cancellation/timeouts
  leave the durable operation intact. A late response cannot populate an invalidated
  flow or settle the new account's journal.
- The actual Backend adapter verifies account/server/session context before and
  after refresh, decode, encoding and network waits. It fully decodes bounded AAC
  natively without sound, sends only to the fixed authenticated Edge route, uses
  no cookies/cache and refuses redirects through the existing delegate. Responses
  are streamed with a 64 KB cap. Provider error bodies are not surfaced, and POST
  is not automatically repeated after an ambiguous response.
- Request encoding is deterministic and runs off the UI actor. Base64 slashes
  remain unescaped, so a valid 8 MB file cannot grow beyond the gateway's envelope
  through JSON slash escaping. Full decode tolerates the existing bounded AAC
  priming-duration difference while retaining the original frozen descriptor.

Local journal limits are 20 unconfirmed entries, 1,000 total entries and 50 MB per
account/server namespace. Confirmed entries are compact; pending audio remains
until an authenticated matching receipt. This budget is separate from the existing
saved-recording vault. Aggregate management/retention UI remains to be completed.

## Verification

Both repositories independently passed:

- **161 audio Core tests**, comprising the 141 existing tests plus 20 publication
  tests: durable-before-network ordering, process/controller return, literal caption,
  receipt compaction, changed revisions, origin/account/target/session isolation,
  invalidated late responses, unknown rename/write outcomes, fixed route/auth headers,
  response caps and sanitized failures. The maximum 8,000,000-byte test includes a
  slash-heavy base64 payload and full native AAC decode before the real Backend
  request; its envelope remains inside the gateway limit.
- **20 separate-process checks** using the actual Core/POSIX store: injected exits
  before/after rename, restart with unchanged IDs, receipt-write restart and two
  competing processes with an actual held file lock. The loser cannot mint a second
  committed operation. These are process-exit tests, not hard-power-loss acceptance.
- **14 native / gateway / PostgreSQL checks**: an actual separate Swift executable
  runs the Core flow, full native AAC decoder and Backend URLSession request. An
  owned URLProtocol maps its fixed HTTPS test route to the loopback production Deno
  gateway. Real PostgreSQL executes the audio migrations/authority/coordinator;
  controlled Auth and Storage adapters transfer actual synthetic bytes. The first
  successful reply is deliberately lost after the server publishes. A second native
  process confirms the same operation/comment without uploading again. A third
  process reads the compact proof and sends no HTTP. Caption/hash/bytes agree.
- App source registration is idempotent and both Xcode projects parse with the new
  source in exactly the Taskfold app target. Both Package manifests own the source.
  Core compilation and whitespace checks pass. New publication/probe sources have
  no compiler warnings; existing SDK Sendable warnings elsewhere remain in logs.

This is **native client code tested in Mac executables**, including the independently
owned iOS repo Core. It does not claim iPhone/iPad app runtime, SwiftUI publishing
controls, conversation rendering/VoiceOver, real Supabase Auth/Storage or hosted
HTTPS/provider acceptance. The local bridge uses controlled Auth/Storage APIs and
four audio migrations; scheduled cleanup acceptance is recorded in the previous
checkpoint, not implied by this publication test.

[Source bindings](source-bindings.json) · [iOS audio tests](core-ios.txt) ·
[Mac audio tests](core-mac.txt) · [iOS processes](process-ios.json) ·
[Mac processes](process-mac.json) · [iOS full local path](native-ios.json) ·
[Mac full local path](native-mac.json).

Reproduce with a dedicated owned scratch directory, independently per repo:

```sh
swift test --scratch-path /tmp/taskfold-publication-core --jobs 2 --filter AudioComment
python3 Scripts/test_audio_publication_processes.py --scratch /tmp/taskfold-publication-core --output /tmp/publication-process.json
node Scripts/Database/test-audio-native-publication.mjs /tmp/taskfold-publication-core /tmp/native-publication.json
python3 Scripts/configure_audio_comments.py
```

The native SQL test requires the existing owned Docker fixture and Deno. Its
containers, HTTP processes, private test files and compiled probes are removed in
`finally`. The Core scratch directory is reusable build input and can be removed
when no longer needed. The checks do not read project credentials or contact a
hosted backend. No new third-party package/client/TLS dependency was introduced.

## Next required work

1. Connect the publisher to Store admission and gated native controls: review the
   saved recording, explicitly publish/check the frozen version, preserve pending
   operations across navigation/relaunch and invalidate on account/workspace/task
   changes or inactivity. Verify fresh saved-recording revisions before preparation;
   existing unbound legacy pending records need review rather than silent adoption.
2. Add live audio-comment listing, authenticated download/native playback/removal
   and conversation presentation. Historical receipt replay is not a live permission
   proof. Complete clear progress/error/retention management and VoiceOver/runtime
   acceptance on Mac, iPhone and iPad; do not expose an unfinished publishing UI.
3. Finish terminal evidence/recovery for unknown absent/corrupt server uploads and
   real hosted Vault/pg_net/Edge/Storage/custody/removal acceptance. The previous
   [maintenance candidate](../audio-maintenance-recovery/README.md) remains gated.
4. Honor genuine microphone/dictation, release signing and all other user deferrals.
   Normal audio entry points and server feature flags stay off. This completes the
   journal/transport foundation, not audio comments or the overall Px objective.

UI follow-up: [gated publication controls](../audio-publication-controls/README.md)
now connect the foundation to saved-recording review. This foundation artifact
and source bindings describe iOS `0ca1ffe` / Mac `448a00a`; the follow-up adds local
status restoration/admission but does not claim native control runtime acceptance.
