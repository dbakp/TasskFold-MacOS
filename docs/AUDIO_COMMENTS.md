# Audio comments — implementation work in progress

Audio comments remain an unfinished Px feature. These sources are a foundation,
not an exposed recording, playback or cloud-publication feature. Neither app has
an audio-comment button yet, and no server migration or production flag was changed.

## Current source

- [x] Strict task/generation/project target; private object names are derived from
  UUIDs and cannot carry an arbitrary URL, user path or filename.
- [x] Bounded AAC/M4A container checks (8 MB, 120,000 encoded milliseconds),
  exact SHA-256 bytes and strict versioned descriptor/publication decoding.
- [x] Complete off-main AVFoundation PCM decoding before review, without playing
  audio. Mono/stereo AAC at 8–96 kHz only. Private temporary files are removed on
  success, failure and cancellation. Structural admission alone is insufficient.
- [x] Workspace-incarnation and recording-token state; late or stale callbacks
  cannot replace a newer clip. Replacement failure preserves the reviewed clip.
- [x] Frozen operation/comment/asset IDs and exact UTF-8 caption across uncertain
  retries. Semantic Unicode equality cannot confirm a different raw intent.
- [x] One bounded binary journal payload retains the frozen publication plus exact
  audio bytes. Decode checks the owning account and complete descriptor/digest.
  The account-private vault now persists this atomically; the app still needs to
  connect that store before network requests and reconcile it after relaunch.
- [x] Account-private file vault and actor adapter for both local reviewed clips and
  immutable cloud-pending intents. Exact owner keys, optimistic draft revisions,
  file/directory synchronization, nonblocking writer locks, link refusal and
  20-entry / 50 MB quotas per account. One bounded staging overhead is allowed
  while recovering an interrupted atomic replacement.
- [x] Explicit recovery of complete interrupted writes; a changed draft needs the
  current saved revision, and pending operations retain their original intent.
  Incomplete/corrupt writes stay on disk. Already committed drafts stay readable.
  No automatic cleanup, overwrite, publication or network retry is implied.
- [x] Independently owned app and Swift Package source registration in each repo.

## Remaining acceptance and implementation

- [ ] Native Record/Stop/review/replace/Cancel, permission refusal and interruption
  recovery, elapsed time, caption, explicit Publish and accessible playback.
  Handle AAC priming/trailing frames correctly at the two-minute recording limit;
  the current container limit must not become a surprise refusal at auto-stop.
- [ ] Connect local/personal media persistence to the app, including Inbox; do not
  make this a feature available only to shared projects or silently drop local clips.
  Add reviewed recovery/export for incomplete staged files and account-removal
  cleanup before exposure; the vault alone does not establish the app lifecycle.
- [ ] Private Storage reservation/finalization and authenticated reads, exact live
  task generation and membership checks, quotas and atomic idempotent receipts.
  An echoed publication intent alone is not an authenticated success receipt.
- [ ] Durable pending journal integration before upload; reconcile uncertain
  outcomes without new IDs, caption changes or duplicate comments.
- [ ] Uploader-removal custody for published team audio, draft expiry, deletion
  cleanup and task/project/team moves without silent loss or widened access.
- [ ] Stop playback and clear in-memory/private previews immediately on account,
  membership or task-generation change. No public or long-lived signed URLs.
- [ ] Backup/export/template/import rules for private media and unsupported clients.
- [ ] Genuine microphone and permission checks, Simulator/native visual, spoken,
  cancellation, relaunch/offline and account-switch acceptance; real private
  Storage transfer and authorization evidence. Source/host tests are insufficient.

## Verification of this checkpoint

Both isolated native app/test builds succeed. This is compile evidence only, not
recording or playback acceptance. See audio-comment-foundation/verification.json.

Each independently owned Core suite passes 21 focused AudioCommentTests, including
an actual full decode of a generated one-second AAC tone, refusal of damaged AAC
sample bytes, truncated/hostile containers, cancelled decoding, exact-caption
retry and corrupted/wrong-account journal refusal. Swift Package runs execute on
this Mac; they are not iPhone/iPad runtime evidence. Existing unrelated test-source
compiler warnings remain recorded in the logs. No microphone access, playback,
user tasks, hosted Storage writes or privacy settings are used by these checks.

The synthetic fixture can be regenerated with
`swift Scripts/create_audio_comment_fixture.swift /tmp/owned-test-tone.m4a`.
It encodes PCM in memory and does not capture or play sound.

AVFoundation reads use the file's processing format and stop at its known frame
length, rather than attempting a read past EOF. Reference:
[Apple AVAudioFile](https://developer.apple.com/documentation/avfaudio/avaudiofile).


## 2026-10-27 — durable file storage checkpoint

The focused suites now pass 45 cases per repo (the original 21 plus 24 storage
cases), running on this Mac. Checks cover store-instance reconstruction, exact owner
and caption identity, optimistic edits, immutable pending operations, failures
before/after rename, reviewed interrupted-write recovery, changed recovery refusal,
nonblocking lock contention, corrupt/sparse/linked files, quotas and permissions,
and the actor adapter. The actor keeps disk work away from the UI actor; the UI
must revalidate its current account/task after every await. Neither real app
recording nor Simulator playback acceptance is claimed. See audio-comment-vault/.

Four independent executable processes per repo also verify exact local/cloud-draft
and pending-intent restoration, refusal under a different process's writer lock,
unchanged bytes after that refusal, and successful read after unlocking. The probe
links each repo's actual built Core library; it does not substitute a file-store
model. Its temporary tree is removed. These are Mac process checks, not a native
app relaunch or iPhone/iPad runtime claim. Both final native app/test builds pass;
the verification manifest retains source hashes and build commands.
