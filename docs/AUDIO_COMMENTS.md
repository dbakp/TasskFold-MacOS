# Audio comments — implementation work in progress

Sender-only audio recovery now separates **Check original send**, **Resume original send…** and **Close original send…**. Metadata checks and explicit closure work after task deletion/access loss without uploading or granting current task/media access. Each repo passes 203 Core, 282 controller, 31 gateway, 51 database/gateway, 37 native owner-recovery, 54 terminal and 24 publication regression checks; both unsigned apps build. Native status/resume/close UI and VoiceOver acceptance, legacy/history policies and hosted/provider acceptance remain open. Ordinary flags stay off. See [sender recovery evidence](audio-owner-status/README.md).

Shared conversations now merge admitted text and published recordings in one time-ordered timeline, reusing accessible audio controls and retaining independent paging and text actions. Server microseconds, literal content and task/account isolation pass 37 selected Core tests per repo (including eight new timeline cases). Native acceptance and remaining Store/provider lifecycle limits are recorded in [mixed conversation timeline](conversation-timeline/README.md). Ordinary audio stays gated; genuine audio remains deferred.

Audio comments remain an unfinished, gated Px feature. Both repos now own private recording/recovery, publication controls and a live server conversation preview. The latest verified scope is [shared read-only conversations](audio-shared-read/README.md): 184 Core, 273 controller, 30 shared native/database/gateway and 24 publication regression checks per repo. Native UI/runtime, team publishing/removal/custody and unified timeline, real hosted provider/custody and genuine audio remain open. No ordinary flag is enabled or hosted migration deployed by this checkpoint. Earlier sections and counts are historical checkpoints.

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
  Closing or changing context clears the visible preview and stops playback.
  A bounded private recovery writer may retain an unconfirmed original-owner snapshot.
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
- [x] Connect the default-off personal-root task editor candidate to private media
  persistence, including Inbox; see the task-editor integration checkpoint below.
- [ ] Finish wider personal-cloud/shared/child and legacy admission, reviewed
  incomplete-file export, media backup and account-removal/move cleanup before
  exposure. The vault and local native scope alone do not establish that lifecycle.
- [x] Add an inactive service-only **metadata** publication ledger with exact live
  authority, immutable retries, quota serialization and custody guards. This does
  not establish Storage transfer, authenticated media read or native publishing;
  see [the coordinator scope](audio-comment-ledger/README.md).
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


## 2026-10-27 — private recovery of interrupted audio reviews

A validated review now checkpoints its recording and exact caption in a separate
account-private recovery namespace. It does not silently replace an explicitly
saved draft. Caption updates coalesce behind the serial writer; an unconfirmed
write retries the identical revision before advancing to a newer edit. These
copies share the vault's existing byte/entry quotas, file protections and strict
binary integrity checks. Complete staged recovery files retain their own format
and recover only into the recovery namespace.

Closing the editor or losing its workspace clears the visible preview and stops
media. A bounded private writer finishes the frozen owner's queued checkpoint
without consulting the new account. A failed checkpoint remains retained in this
process and can retry only for its exact owner and task incarnation. Returning to
that task offers an explicit Retry when persistence is still blocked. This is
not a promise that unsynchronized bytes survive process termination or disk
failure: keep Taskfold open while a recovery warning remains.

Interrupted reviews are listed separately and undergo full native decoding before
review. Explicit Save settles exact recovery revisions; explicit Discard removes
only this review's copy and preserves earlier saved drafts. A concurrent recovery
settlement causes an independent recovery copy, never an overwrite. A saved-draft
conflict now offers **Save as separate draft**, preserving both versions. Uncertain
acknowledgement of that copy freezes its identity and caption until retry within
the running presentation. The
model also refuses deletion while the reviewed recording has unsaved changes.

Both independently owned repos pass 55 focused Core cases and 42 executable
controller checks with real private files and synthetic drivers. These include
actual writer-lock refusal, return/retry, exact last-caption preservation after
an immediate workspace switch, recovery namespace/revision/quota checks,
coalescing after lost acknowledgement and stable conflicting-copy retries.
Native results, captures and limitations are recorded in audio-comment-recovery/.

Still required before exposure: ordinary task/conversation integration; Mac
normal-Quit coordination and mobile background execution; active/partially
recorded media and crash-leftover ownership/cleanup; fuller storage-full and
cleanup recovery; durable linkage between an explicit Save attempt and its
recovery copy across an uncertain-save relaunch; account removal and backup/export policy; private server
publication/access/custody; genuine microphone/playback/permissions/interruptions
and spoken accessibility. Source recovery and acknowledged-checkpoint cold return
do not establish those broader lifecycle guarantees. Audio comments remain gated.


Quota failure refinement: explicit recovery settlement/discard now waits only for
an already issued write, then removes one of its exact possible committed
revisions. It does not write a newer caption just to delete it. Known pre-write
quota/lock failures leave the review editable instead of misclassifying it as an
uncertain commit. A before/after executable check reproduces four failures in the
pre-fix controller and passes all 42 checks in the current controller. Full-quota
discard preserves every earlier saved recording's exact data and metadata.


Current native acceptance passes six cases each on this ARM64 Mac, iPhone Simulator
and iPad Simulator, with zero failures/skips/reported runtime warnings. This includes
ordinary reviewed save/cold return, synthetic refusal and replacement preservation,
dark review (largest mobile text), recovery after an acknowledged checkpoint and
explicit discard/cold return. See audio-comment-recovery/ for exact current sources,
commands, binary hashes, strict result summaries and inspected captures.


## 2026-10-27 — durable local Save across relaunch

An explicit local Save now writes an account-private, bounded binary intent before
writing the reviewed draft. The intent retains the exact recording, UTF-8 caption,
draft/revision/operation IDs, optimistic base and eligible recovery revisions.
A relaunch lists **Saves to finish** separately and hides the recovery copies
associated with that intent. Finish loads the current on-disk intent, performs a
full native decode, and retries the original IDs. A stale Finish after deliberate
deletion cannot recreate a draft. Deletion of a draft is refused while its Save
still needs settlement.

Save as separate draft atomically replaces the conflicted intent under its same
operation ID, retaining the exact review and its newly chosen draft ID across
another interrupted write. Different intent bytes cannot silently replace that
journal. The primary draft is synchronized before eligible recovery removals are
synchronized; only then may the intent disappear. Failed final bookkeeping can
leave/replay an intent safely. This is a local file transaction, not a cloud
publication or authenticated server receipt.

The controller binds to the disk actor's immutable raw owner before any action or
refresh. A deliberately mismatched store previously exposed draft summaries in a
controlled synthetic test; the before result is retained, and the current test
refuses those rows. Current focused evidence is 66 Core cases and 54 controller
checks per independently owned repo, using actual private files and synthetic
media. The controller checks include fresh-presentation resume, conflict-copy
resume, quota after journal preparation, stale actions after deletion, wrong
account/task generation, and a real in-flight file-write barrier during a workspace
switch. See audio-comment-save/ for native acceptance, source/binary bindings and
captures.

Still open before exposure: atomic arbitration when independent editors try to Save
the same recovered review concurrently; cancellation/management of prepared Saves
when quota cannot be freed; reviewed orphan-stage export/recovery and corrupted
metadata UX; full normal-Quit/background/raw-recording ownership; account removal
and backup/export rules; private server publication/access/custody; real microphone,
playback, permissions, interruption and spoken acceptance. These scoped guarantees
do not claim the complete multi-editor/app lifecycle. Ordinary entry points remain
gated and the user's real-audio deferral remains in force.


Current local-Save native acceptance passes four selected cases each on ARM64 Mac,
iPhone Simulator and iPad Simulator, with zero failures/skips/reported runtime
warnings. These cover ordinary Save/cold return, explicit Discard, unsaved-review
recovery and prepared-Save recovery (dark/largest text on mobile). Inspected Finish
Save captures, exact source/binary hashes, strict verifiers and cleanup are in
audio-comment-save/. Temporary Taskfold/test processes are closed and the used
Simulators are shut down. These results leave the broader lifecycle gates open.


## 2026-10-27 — concurrent recovery ownership and pending cancellation

- [x] Atomic recovered-review ownership using the actual private file lock. Equal
  reviews reuse the winning saved draft or its durable Save operation; different
  edits require an explicit separate copy and preserve both versions.
- [x] One catalog snapshot suppresses duplicate-looking pending/saved/review rows,
  coalesces identical recovery clones and preserves differently edited reviews.
- [x] Durable pending-discard phase survives lost acknowledgement and relaunch;
  stale Finish cannot turn it back into Save. Cancelling an unfinished replacement
  preserves the earlier draft; an already committed recording refuses cancellation.
- [x] Full logical entry-quota cancellation, strict v2 format with legacy v1 reads,
  exact caption/media/provenance checks and stale-deletion guards.
- [x] 79 focused Core tests and 62 executable controller checks in each independently
  owned repo; separate executable processes establish both source snapshots before
  racing through the actual file store and converge on one saved recording.
- [ ] Remaining audio gates: orphan/corrupt-file recovery, retained attempts after
  unreadable state lookup, full recording/Quit/background/removal/backup lifecycle,
  ordinary task integration and private server publication/access/custody.
- [ ] Real dictation, microphone, playback, permissions and spoken acceptance stay
  deferred by the user. No real audio permission or speaker output was requested.

Current evidence and native acceptance are in [audio-comment-claims](audio-comment-claims/README.md).
This supersedes the two concurrent-claim/cancellation gaps in earlier checkpoints;
other lifecycle requirements remain open and ordinary audio entry points stay gated.


Final acceptance: four selected native cases pass each on ARM64 Mac, iPhone
Simulator and iPad Simulator, with zero failures/skips/reported runtime warnings.
They cover ordinary reviewed Save/cold return, preserved already-committed audio
after refused pending cancellation, durable discard after acknowledgement loss
and relaunch, and exact single-draft Finish Save recovery. The last two use dark
largest mobile text. Final captures were inspected; the phone action is fully
visible after normal scrolling. Native initial failures and the Form-action/test
query corrections are recorded in audio-comment-claims/. Hardware, spoken and
full application/server lifecycle acceptance are not implied.


## 2026-10-28 — preserve an uncertain prepared audio Save

- [x] Retry keeps the original Save/copy authorization and frozen caption when
  another real file-lock holder prevents confirming the previous write.
- [x] Durability checks compare the entire stored intent, including IDs, revision,
  base, recovery references, provenance and discard phase.
- [x] A newly chosen separate copy cannot inherit its predecessor's durability.
- [x] Each independent repo passes 80 focused Core tests, 84 executable controller
  checks and the two-process ownership probe. Before-fix regressions are retained.
- [x] Isolated Mac process-loss recovery recovered one prepared Save, finished it
  and decoded the same saved recording/caption after another relaunch. This used
  synthetic media, controlled SIGTERM and native UI inspection; normal Quit was
  not accepted. Later Form-identifier and DEBUG-footer layout builds are separate compile checks.
- [x] Final native acceptance: four cases pass each on iPhone and iPad Simulators,
  with zero failures/skips/reported runtime warnings. Three new standard-text
  cases cover prepared/committed unknown retries and cold recovery; the existing
  largest-text discard/relaunch regression also passes. Earlier driver/DEBUG
  footer failures are retained separately. Current Mac acceptance is compile/sign
  plus the limited prior-binary native inspection above, not a new XCTest run.
- [x] The pre-journal workspace-return failure found in this checkpoint is
  resolved by the later exact-Save-retention follow-up below. Its original failing
  diagnostic remains preserved as historical evidence.
- [ ] Real microphone/dictation/playback and spoken acceptance remain deferred.
  Full lifecycle, ordinary task integration and private server custody remain open.

Evidence: [unknown Save checkpoint](audio-comment-unknown-save/README.md).
Ordinary audio entry points remain gated. This checkpoint does not complete Px.


## 2026-10-28 — unwritten audio Save survives a workspace change

- [x] Preserve the exact pending authorization in the existing bounded recovery
  registry when the first journal write and state lookup both fail. The original
  account/task gets one Finish saving action; discovery performs no automatic Save.
- [x] Preserve separate-copy destination IDs/revisions and replacement authorization;
  reject changed same-ID requests and foreign owners/task incarnations.
- [x] Repeated failed returns reuse the same operation/retained slot; 23 consecutive
  failures exercise the quota boundary. Explicit Finish settles the original writer.
- [x] Make process-only retention clear: keep Taskfold open and Finish saving before
  discarding. Clear the current recovery warning after a successful Finish.
- [x] 107 executable controller checks pass independently in each repo, bound to the
  final source. The before snapshot failed four of the 93 reproduction checks.
  Core/storage format is unchanged; prior 80 Core tests are not claimed as a new run.
- [x] Signed final Mac native walkthrough: failed automatic recovery, unknown Save,
  empty foreign workspace, one original-owner Finish action, exact saved caption,
  warning cleared, and the same decoded recording after controlled relaunch.
- [x] Initial iPhone/iPad suites each pass four cases without failures/skips/reported
  runtime warnings. These precede the warning polish. The final selected workspace
  journey also passes each on iPhone/iPad, with explicit assertions for one focused
  Finish action and cleared recovery warning; separate final bindings are retained.
- [ ] Still open: durable handling before normal Quit/background/process loss,
  orphan/corrupt-file recovery, full removal/backup lifecycle, ordinary integration
  and private server custody. Real audio/permission/spoken testing remains deferred.

Evidence: [workspace-return recovery](audio-comment-workspace-return/README.md).
This resolves the earlier workspace-switch pre-journal failure; it does not close
the broader audio gate or the Px objective. Ordinary audio entry points stay gated.

## 2026-10-28 — reviewed audio departure checkpoint

- [x] Preserve an already-authorized Save as an exact durable journal without completing a draft or deleting reviews.
- [x] Prevent stale automatic checkpoints from resurrecting completed Discard using a bounded persistent nonce; preserve existing-only retry constraints.
- [x] Fence directory durability before reporting prepared/settled state, including rename-acknowledgement recovery.
- [x] Preserve original-store work from closed views/workspace changes; retain busy Mac sheet protection and refuse ready-sheet Quit when recovery cannot be confirmed.
- [x] iOS inactivity playback stop and bounded background checkpoint path; explicit Finish still required after cold return.
- [x] 90 Core and 124 synthetic controller checks per repo; 12-process storage proof; one warning-free background/cold-Finish native case each on phone/tablet; final Mac native normal-Quit/refusal/cold-Finish journey.
- [ ] Busy-recording automatic Mac Quit, expired prepared-authorization recovery UX, forced-loss/orphan/removal/backup lifecycle, ordinary integration and private server custody remain open. Genuine audio/TCC/spoken testing stays deferred.

[Evidence and exact acceptance scope](audio-comment-departure/README.md).

## 2026-10-28 — removed pending audio Save recovery

- [x] Keep an existing-only Save restriction through repeated Retry, peer handoff and reopening a retained authorization. A missing lookup no longer turns it into a fresh Save.
- [x] Preserve the local review and offer an explicit independent copy with new operation/draft IDs, no old recovery claims and no mutation of other disk versions.
- [x] Verify 131 synthetic capture-controller checks per repo, including seven new removed-Save/reopen/copy cases. Six new checks fail against the preceding controller.
- [x] Current iPhone native separate-copy Close, interruption, new-ID journal readback and exact cold Finish; both app builds/signatures pass.
- [x] The same final iPad job completed the separate-copy Close/new-ID/cold-Finish case with no reported runtime warnings; repeated animation waits remain recorded.
- [ ] Final Mac Close-dialog runtime inspection waits for an unlocked desktop; the earlier direct-copy Mac scope does not accept the final dialog.
- [x] Direct expired-review discard at entry quota is implemented and verified in the next checkpoint below.
- [ ] Broader lifecycle/account interleavings remain open.

[Evidence and exact scope](audio-comment-removed-save/README.md). Ordinary audio entry points remain gated; genuine audio and release deferrals are unchanged.

## 2026-10-28 — direct discard of an expired audio review

- [x] Close offers Discard this review alongside an explicit separate copy after the prepared Save disappears/changes.
- [x] One locked storage operation refuses still-prepared/settled requests, preserves other Save claims and changed review revisions, revokes old automatic checkpoints and removes only eligible exact references without admitting a replacement payload.
- [x] Entry-quota, foreign-owner, busy-lock and lost-acknowledgement recovery; memory stays available until explicit cleanup is acknowledged.
- [x] 96 selected Core tests and 136 synthetic controller checks per repo; 16-process storage proof per repo. Two behavioral regressions fail before the controller repair.
- [x] Current iPhone Discard/cold return plus separate-copy regression (two tests); iPad Discard/cold return (one test), no reported runtime warnings. Readable dialogs/empty states visually inspected; actual private files checked.
- [ ] Mac native dialog runtime remains open while locked; broader lifecycle/concurrency/backup/orphan/corruption, ordinary integration, private server custody and genuine audio acceptance remain open. No feature/Px completion claim.

[Evidence and exact scope](audio-comment-expired-discard/README.md).


## 2026-10-28 — discover complete interrupted recording files

- [x] Discover complete private pre-rename draft/review files for the current
  account, task and task incarnation without automatically promoting them.
- [x] Offer explicit Recover recording after bounded codec validation; recovered
  reviews still need review and Save. Existing saved drafts stay separate.
- [x] Keep unreadable files with a warning while offering other readable stages.
  Unsafe filesystem entries and storage scan failures still refuse the scan.
- [x] Preserve Save/publication stage kinds and show a separate attention notice;
  this local screen cannot authorize or finish those operations.
- [x] Refuse recovery over an outstanding Save or with changed recovery provenance.
  Both cases reproduce failures against the preceding Core implementation.
- [x] 103 focused Core cases, 148 controller checks, the 16-process storage proof
  and independent concurrent-editor convergence pass in each repository.
- [x] Final-source iPhone and iPad Simulator recovery/review/explicit-Save/cold-return
  cases pass at dark Accessibility XXXL with no reported runtime warnings. Exact
  original-primary and incomplete-file bytes are preserved; all six final captures
  were visually inspected. Mac native UI acceptance remains open (build/sign only).
- [ ] Broader damaged-file repair/cleanup, conflicting-stage resolution,
  Save/publication-stage recovery, account/removal/backup lifecycle, ordinary app
  exposure and private server delivery remain open. Genuine media testing stays
  deferred by the user.

[Evidence and exact native scope](audio-interrupted-files/README.md). This advances
private recovery; it does not complete audio comments or the Px objective.


## 2026-10-28 — keep both interrupted recording versions

- [x] Full-caption Keep both review with Cancel and explicit Save separate draft;
  the newer saved recording is retained unchanged.
- [x] Durable exact-stage cleanup authorization, independent copy identity,
  original-ID retry/cold Finish, concurrent claim joining and changed-file refusal.
- [x] Preserve the source when cancelling; return to a usable list after a known
  pre-write quota refusal only while its exact source remains durable.
- [x] Block competing copies behind unpromoted Save/discard journals without
  automatically promoting or finishing those journals.
- [x] 115 Core cases, 166 controller checks and seven separate-process copy checks
  pass in each repo; both app builds and strict signatures pass.
- [x] Final-source iPhone/iPad Simulator: two native cases each, zero failures,
  skips or reported runtime warnings, at dark Accessibility XXXL. Review/Cancel,
  original-journal cold Finish and ordinary draft/review recovery pass; original
  bytes and both independent saved versions are verified. All 12 final captures
  were inspected. Mac native interaction remains open (build/sign only).
- [ ] Save/publication-stage recovery UI, damaged-file cleanup/export, broader
  lifecycle, ordinary entry points and private server media delivery remain open.
  Genuine microphone/speaker checks remain deferred by the user.

[Evidence and native scope](audio-interrupted-copy/README.md). This advances local
recording recovery; it does not complete audio comments or the Px objective.


## 2026-10-28 — bind private audio to the real task editor

- [x] Connect saved personal-root editor/inspector entry candidates to the private
  media screen and actual vault, including Inbox; normal exposure remains off.
- [x] Check current Store access, exact owner, root generation/project and server
  origin; reject unsupported/legacy/shared targets rather than inventing identity.
- [x] Separate app/server/account namespaces; prepare private, backup-excluded
  storage off the UI actor. Keep audio and captions out of task data and exports.
- [x] 123 Core cases and 170 controller checks pass per repo; both independent app
  builds/signatures pass and their normal exposure flags remain absent.
- [x] Final iPhone/iPad Simulator: task-editor Inbox/project Save/relaunch and
  synthetic other-account reset isolation pass as two cases each, no failures,
  skips or reported runtime warnings. Task-table bytes remain unchanged; all six
  final captures were inspected. Mac native runtime remains open (build/sign only).
- [ ] Personal cloud/shared/child and broader runtime, legacy admission, media
  backup/removal/move custody and server publication remain open. Genuine audio
  and permission testing stays deferred; ordinary exposure remains gated.

[Evidence and native scope](audio-task-editor/README.md). This is integration of
an unfinished candidate, not completion of audio comments or the Px goal.


## 2026-10-28 — retained recording inventory foundation

- [x] Add an account-private inventory across original task/project identities;
  moved/deleted/recreated-task classification does not retarget stored clips.
- [x] Read one locked snapshot without trimming recovery files, promoting staged
  bytes or finishing Save/publication operations. Report those categories apart.
- [x] Revalidate exact saved selections; refuse changed/deleted recordings and
  primaries covered by an unfinished Save, including lost commit acknowledgement.
- [x] 135 focused Core cases pass independently in each repository, including
  12 new inventory/selection/custody cases. Native app compilation/signature
  results are recorded in the evidence directory.
- [ ] Account-library presentation, playable/exportable orphan recovery,
  removal/backup custody, real-media and broader cloud/lifecycle acceptance remain
  open. Ordinary audio exposure remains off; microphone testing stays deferred.

[Evidence and limits](audio-saved-library/README.md). This is storage groundwork,
not a completed library feature or completion of audio comments/the Px objective.


## 2026-10-28 — read-only private recording library candidate

- [x] Add a gated Backups & restore entry and an account-scoped library with full
  caption review and Play/Stop, including recordings whose task moved or vanished.
  No task is recreated or retargeted; normal app exposure stays off.
- [x] Recheck exact scope and saved revision before/after native codec decode and
  again at Play. Clear stale previews and stop playback on scope loss/inactivity;
  safely reload after foreground return and the actual preservation hook.
- [x] Independently pass 191 actual controller/codec/vault checks (21 new), with
  zero compiler warnings; both native app builds and strict signatures pass.
- [x] Final iPhone/iPad Simulator: two cases each, zero failures/skips/reported
  runtime warnings at dark Accessibility XXXL. Task move/removal/cold return,
  read-only task/media byte preservation, playback/background return and reset
  isolation pass. All eight final captures were inspected. Initial viewport and
  fixture-driver failures are recorded explicitly, not counted as acceptance.
- [ ] Actual Settings-row activation, Mac native/spoken, cloud and genuine-media
  acceptance remain open. Export/import, account-removal custody, unfinished
  orphan recovery and server delivery are still unfinished. The user's genuine
  microphone/speaker/permission test remains deferred.

[Evidence, captures and exact scope](audio-saved-library-ui/README.md). This is a
verified gated candidate, not completion of audio comments or the full Px goal.


## 2026-10-28 — portable recording backup export candidate

- [x] Add explicit native Save export for a saved recording's exact audio/caption
  and descriptor, without structural task/account/server links. Normal audio
  exposure remains off; the JSON copy is unencrypted at its chosen destination.
- [x] Recheck exact private source and live permission at provider byte release;
  revoke on Cancel, new selection/export, manual refresh, Close or scope loss.
  Preserve an explicitly requested Save through picker focus/foreground return.
- [x] 141 Core cases and 211 actual controller/codec/vault checks pass separately
  in both repos; both native builds and strict development signatures pass.
  The maximum-size regression fails before the slash-escaping correction.
- [x] Final iPhone/iPad Simulator: one actual native case each, no failures/skips
  or reported runtime warnings, at dark Accessibility XXXL. After removing the
  synthetic task: Cancel, observed local Files Save/readback, full media/caption/
  descriptor preservation, fresh-selection feedback and cold return pass without
  recreating the task. All ten final stage captures were inspected.
- [x] Both delivered device files independently pass each repo's Core parser and
  full native AAC decoder (four file/decoder combinations); exact bytes/caption
  and integrity/duration metadata are recorded without playing sound.
- [ ] Import/review UI, bulk workspace/media backups, account-removal custody,
  unfinished orphan recovery, actual Mac Save interaction, cloud/physical/spoken
  acceptance and private server delivery remain open. Genuine audio testing
  stays deferred by the user; previously tabled rollout work remains tabled.

[Evidence and exact scope](audio-recording-export/README.md). This advances backup
custody; it does not complete audio comments or the overall Px objective.


## 2026-10-28 — reviewed recording-backup import candidate

- [x] Add a coordinated, bounded and cancellable recording-file reader plus full
  native AAC validation before review. No microphone/speaker permission is used.
- [x] Review the literal caption, then explicitly Save a separate private draft
  for the currently admitted task. A fresh editor is required; source files and
  existing recordings are preserved. Cancel and late cancelled results do not
  write the vault. Confirmation uses the existing recovery writer/Save journal.
- [x] Each independent repo passes 230 actual controller/codec/vault checks,
  including 19 new import checks, with zero compiler warnings. Both native app
  builds and strict deep development signatures pass. Core contracts are unchanged.
- [x] iPhone/iPad Simulator: one native case each at dark Accessibility XXXL,
  with no failures/skips/reported runtime warnings. Actual local Files selection,
  full-caption review, Cancel, separate Save, source/task preservation and cold
  return pass. The eight final explicit captures were inspected. Diagnostic
  driver failures are retained separately and are excluded from acceptance.
- [ ] Ordinary audio exposure, actual Mac picker/spoken, cloud/physical/genuine
  media acceptance, bulk media backup, account-removal custody, unfinished orphan
  recovery and private server delivery remain open. The user explicitly deferred
  genuine dictation/microphone/speaker/TCC testing again; no new prompt was shown.

[Evidence and exact scope](audio-recording-import/README.md). This completes the
scoped local mobile import return path, not audio comments or the overall Px goal.


## 2026-10-28 — inactive audio publication ledger

- [x] Implement a service-only, default-off metadata coordinator for immutable
  reservations, matching service attestations, current-access metadata reads,
  explicit retirement and bounded cleanup manifests. It does not upload media,
  provision Storage, write ordinary conversation rows or expose a client RPC.
- [x] Enforce live session/removal and exact task/generation/project authority;
  preserve retry IDs and literal captions. Serialize task/account quotas, block
  unreviewed identity/move/Inbox-owner/heading changes and preserve shared
  metadata with cleared authorship when its uploader leaves.
- [x] Independently pass 102 real PostgreSQL checks per repo, with baseline/final
  official advisor comparison introducing no findings. Two controlled mutation
  probes fail at their intended quota/custody assertions; fixtures are removed.
  A null-owner fixture is excluded because the existing schema forbids that row.
- [ ] Actual authenticated Edge/Storage transfer and readback, media reads,
  late-upload-safe physical cleanup, rate/aggregate budgets, native publishing /
  conversation presentation and hosted acceptance remain open. A metadata
  attestation alone is not upload proof. Ordinary audio and server config stay
  off; the migration is not deployed. All user deferrals remain in force.

[Evidence and next required work](audio-comment-ledger/README.md). This completes
the coordinator foundation, not private delivery, audio comments or the Px goal.


## 2026-10-28 — gated live audio conversation preview

- [x] Add strict reader/author-aware live metadata, authenticated fixed-route
  list/download/removal and full native decode/integrity checks before playback.
- [x] Add workspace/session-bound ephemeral conversation controllers and gated
  personal-root editor entry points with Play, explicit Remove and Refresh.
- [x] Independently pass 178 Core, 265 actual controller and 24 native/gateway/real
  PostgreSQL checks, including a lost removal reply, stable retry, empty list and
  denied download after removal; local confirmation survives and no new upload occurs.
- [ ] Complete pagination beyond the existing 20-comment preview, shared/read-only
  role admission and text-conversation integration; native UI/runtime/accessibility
  and hosted provider acceptance. Audio gates remain off; genuine audio stays deferred.

[Evidence and limits](audio-live-preview/README.md). Native compilation does not
establish visual/spoken/runtime acceptance or complete the audio/Px feature.


## 2026-10-28 — paged audio conversations

- [x] Add service-only, live-authorized keyset pages with exact timestamp/ID cursors;
  preserve order across tied timestamps, microseconds and removal of a cursor row.
- [x] Add native Load more, retry without losing loaded rows/position, terminal
  stopping and context-bound cursor clearing. Legacy list responses stay compatible.
- [x] Raise retained task count to 100 while preserving independent author/byte
  quotas. Independently pass 180 Core, 271 controller, 20 gateway, 25 database/page
  and 24 native integration checks; database advisors show no added findings.
- [ ] Shared/read-only admission and text-conversation integration; native UI/runtime/
  accessibility and real hosted provider/custody acceptance. Ordinary flags remain off.

[Evidence and limits](audio-pagination/README.md). Pagination implementation closes
the 20-comment preview gap; the full audio/Px objective remains open.


## 2026-10-28 — shared read-only audio access

- [x] Separate viewing from private draft/publishing permission. Require current
  access boundaries for project readers, including team viewers and archives;
  retain a separate Inbox owner check and deny creator-only shortcuts.
- [x] Add read entry points in shared conversations and root editors, scoped author
  presentation, independently checked removal authority and clearing on denied reads.
- [x] Keep team audio writes closed. Independently pass 184 Core, 273 controller,
  30 shared PostgreSQL/gateway/native and 24 publication regression checks per repo;
  grant revocation during a download withholds audio, with no new advisor findings.
- [ ] Native UI/runtime/visual/spoken acceptance, separately authorized team audio
  publishing/removal/custody and unified timeline; hosted provider and remaining
  recovery acceptance. Ordinary flags remain off; genuine audio stays deferred.

[Evidence and limits](audio-shared-read/README.md). Shared read implementation does
not complete all team audio operations or the overall Px feature.


## 2026-10-28 — native audio conversation controls

- [x] Make removal an explicit Cancel/Remove alert; preserve cancelled rows and
  saved private recordings. Name Play/Stop controls and provide 44-point targets
  with vertically stacked actions at accessibility sizes.
- [x] Pass five synthetic native component journeys each on iPhone and iPad:
  read-only playback/close, owner Cancel/Remove/paging, dark Accessibility XXXL and
  denied clearing, departure refusal and genuine Simulator VoiceOver output.
- [x] Verify Mac native component Play/Stop/Close, Cancel/Remove, final page,
  denied clearing and departure refusal through CUA, with 16 recorded assertions.
- [x] Visually verify Mac accessibility-size stacked actions and unchanged records.
- [ ] Full Store/shared-account
  UI integration, publisher/recovery controls, hosted media/custody and remaining
  lifecycle acceptance. Genuine audio stays deferred and ordinary gates stay off.

[Evidence and exact build phases](audio-conversation-native/README.md). This
accepts the synthetic conversation component scopes above; audio/Px remain open.

## 2026-10-28 — mixed text/audio conversation timeline

- [x] Present authorized shared text and live recordings in one chronological
  timeline; retain literal bodies/captions and stable medium-qualified row IDs.
- [x] Order text by original creation and audio by publication, preserving server
  microseconds and equivalent offset/fraction representations. Editing text does
  not move it. Keep selected-comment routes and existing text actions.
- [x] Reuse accessible audio Play/Stop/Cancel/Remove controls, with publication time
  visible. Retain each source’s independent cursor and clearly label partial loads.
- [x] Bind audio reads/playback to the current workspace, session, task generation
  and project. Clear recordings on lost access; keep separately admitted text.
- [x] Five final native iPhone/iPad cases each, including real Simulator VoiceOver
  output, preserve text after audio removal/access loss and retain mention routes.
- [ ] Mac mixed-timeline runtime and full Store/provider lifecycle remain open;
  see conversation-timeline/README.md. Ordinary audio flags stay off. Team audio
  writes/custody, uncertain-upload/legacy recovery and genuine audio remain open.

## 2026-10-28 — exact closed-publication recovery

- [x] Turn an exact expired/retired reserve/finalize response into durable closure,
  preserving original audio and stable intent. Missing objects/timeouts/conflicts
  remain uncertain; a closed operation is never silently republished.
- [x] Restore v3 closed journals beside existing v1/v2 files, keep private originals,
  allow explicit copy/compaction and retain proof. A new publication requires an
  explicitly saved new revision; no automatic IDs or upload-fence release.
- [x] Independently pass 195 Core, 282 actual controller, 25 gateway, 54 terminal
  native/gateway/PostgreSQL and 24 existing publication regression checks per repo;
  both full unsigned apps build. No new schema/exposure or hosted data changes.
- [ ] Owner status after task/access loss, absent server reservations, native closed-
  state/full Store UI, legacy/history policy and hosted provider/custody acceptance.
  Genuine audio and existing user deferrals stay pending; ordinary flags stay off.

[Evidence, exact limits and reproduction](audio-publication-closed/README.md).
This closes the exact-reservation terminal gap; the full audio/Px feature stays open.
