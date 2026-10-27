# Audio comments — implementation work in progress

Audio comments remain an unfinished Px feature. These sources are a foundation,
not an exposed audio-comment feature. Native recording/review/playback sources and
an isolated synthetic screen now exist. Ordinary task/conversation entry points
remain gated, and no server migration or production flag was changed.

## Current source

- [x] Strict task/generation/project target; private object names are derived from
  UUIDs and cannot carry an arbitrary URL, user path or filename.
- [x] Bounded AAC/M4A admission (8 MB, two minutes of decoded presentation audio),
  exact SHA-256 bytes and strict versioned descriptor/publication decoding. A
  bounded extra second in the container accommodates AAC priming/remainder;
  native frame-count decoding still rejects audio longer than two minutes.
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
- [x] Device recorder/player adapters, explicit microphone request, shared exclusive
  audio lease with dictation, input/interruption cleanup and iOS session restoration.
- [x] Native review controller and screen: stop/cancel, bounded full decode,
  replacement/refusal preservation, caption, explicit playback, private Save,
  stable uncertain-save retry, reopening and revision-checked draft deletion.
  Closing or changing context erases in-memory media and stops playback.
- [x] Synthetic controller checks and isolated native screen test implementation.
  This is not real microphone, speaker, interruption or TCC acceptance.
- [x] Independently owned app and Swift Package source registration in each repo.

## Remaining acceptance and implementation

- [ ] Complete ordinary task/conversation entry points and publishing once private
  server delivery and access checks are ready. Native source/synthetic drivers
  do not establish real recording, playback, interruption, audio routing, TCC,
  spoken accessibility or full background/window/normal-Quit preservation.
- [ ] Genuine microphone/speaker acceptance remains deferred at the user's request
  (“Later—continue other work”). Do not open permission dialogs or play sound
  to satisfy this gate until the user authorizes a new real test.
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


## 2026-10-27 — native recording and review candidate

The focused Core suites now pass 47 cases per repo, including generated two-minute
AAC with padding and a 120.1-second presentation that must refuse. Descriptors
restored from private files remain bound to exact bytes, and the native validator
computes duration from decoded presentation frames. Current controller checks use
the actual codec/file store and synthetic recorder/player: 19 pass per repo.
The shared dictation lease change also passes all 17 existing controller checks
per repo, including the actual minute deadline. Real drivers are invoked only
behind a false context or a held lease, before microphone/speaker access.

The private-draft UI remains a gated candidate. The fixture requires the exact
reserved app identity plus --team-editor-testing and --audio-comment-testing;
its recorder generates a one-second tone file and its player is silent. The
--audio-comment-reset option removes only that fixture's synthetic media folder.
Production app IDs cannot activate this screen with those flags.

Native screen results and inspected captures are recorded in audio-comment-media/.
They are scoped evidence, not completion of audio comments or the broader Px goal.


Native acceptance now covers four distinct cases each on Mac, iPhone and iPad:
review/save/cold reopening and silent playback controls, synthetic initial
permission refusal, dark review (largest text on mobile), and refusal of a
replacement while preserving the saved caption and 0:01 duration. Mac and iPad
have one four-pass run each. iPhone has three passes in the main run and the
remaining case passes in a targeted rerun after correcting the test helper's
upward navigation; the app code did not change for that rerun. The earlier
navigation failure remains recorded. Every accepted run reports no runtime
warnings. This does not close unrelated existing Mac warning investigations.

Inspected native captures show readable review controls, private-save feedback and
complete targeted caption/record controls at the largest mobile size. Compact
accessibility layouts stack status above the timer; ordinary iPad/Mac layouts
keep the timer alongside it. Offscreen content remains normally scrollable.
The refused-replacement duration bug has a failing-before/passing-after controller
check plus native checks on all three hosts.

Before ordinary exposure, finish known save-conflict recovery/fork UX, preservation
of unsaved work across access changes/normal window close/Quit/backgrounding,
crash-leftover recording-file ownership/cleanup and the account-removal lifecycle.
The current private review candidate must not be called a complete audio-comment
feature merely because its synthetic screen passes.
